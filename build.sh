#!/bin/bash

# set -x

cd "$(dirname "$0")"

REQUIRED_TOOLS="jq curl"

ARGS=(
  "name:PACKAGE_NAME:true"
  "version:VERSION:false"
  "format:FORMAT:false"
)

log() {
  local c
  case $1 in
    success) c=32 ;; error) c=31 ;; warning) c=33 ;;
    *) c=0 ;; # для info и всего остального без цвета
  esac
  echo -e "\033[1;${c}m$2\033[0m"
}

require() {
  for pkg in "$@"; do
    if ! command -v "${pkg}" &>/dev/null; then
      log error "'${pkg}' package is required but not found"
      exit 1
    fi
  done
}

arguments_parser() {
  while [[ $# -gt 0 ]]; do
    for def in "${ARGS[@]}"; do
      IFS=":" read -r flag var required <<< "${def}"
      case "$1" in
        --"${flag}"=*)
          eval "${var}=\"\${1#--"${flag}"=}\""
          break
          ;;
        --"${flag}")
          [[ $# -lt 2 ]] && { log error "Missing value for --${flag}"; exit 1; }
          eval "${var}=\"$2\""
          shift
          break
          ;;
      esac
    done
    shift
  done

  for def in "${ARGS[@]}"; do
    IFS=":" read -r flag var required <<< "${def}"
    [[ "${required,,}" == "true" && -z "${!var:-}" ]] && { log error "${flag} argument is required!"; exit 1; }
  done

}

parse_target_formats() {
  if [[ -n "${FORMAT:-}" ]]; then
    [[ "${FORMAT}" == "all" ]] && echo "deb rpm arch" || echo "${FORMAT}"
  else
    [[ ! -f /etc/os-release ]] && { log error "Cannot determine distribution: /etc/os-release not found"; exit 1; }
    case "$(awk -F= '/^ID=/{gsub("\"", "", $2); print $2}' /etc/os-release)" in
      debian|ubuntu) echo "deb" ;;
      fedora|rhel|centos) echo "rpm" ;;
      arch) echo "arch" ;;
      *) log warn "Unknown distribution, defaulting to deb"; echo "deb" ;;
    esac
  fi
}

download_appimage() {

  case "${DOWNLOAD_TYPE}" in
    RAW)
      log info "Using RAW (direct) method to download AppImage"
      [[ -z "${BASE_URL:-}" ]] && { log error "BASE_URL is not set"; exit 1; }
      APPIMAGE_URL="${BASE_URL}"
      ;;
    API)
      log info "Fetching AppImage via API"
      json=$(curl -fsSL "${BASE_URL}?${API_PATH}") || { log error "Failed to fetch JSON data"; exit 1; }
      APPIMAGE_URL=$(jq -r ".[\"${DOWNLOAD_KEY}\"]" <<< "$json") || { log error "Failed to parse JSON key: ${DOWNLOAD_KEY}"; exit 1; }
      [[ -z "${APPIMAGE_URL}" ]] && { log error "API returned empty URL"; exit 1; }
      ;;
    *)
      log error "Unsupported DOWNLOAD_TYPE: ${DOWNLOAD_TYPE}"
      exit 1
      ;;
  esac
  [[ -z "${APPIMAGE_URL}" ]] && { log error "Failed to get AppImage URL"; exit 1; }

  FILENAME=$(basename "${APPIMAGE_URL}")

  [[ -z "${VERSION}" ]] && VERSION=$(echo "${FILENAME}" | sed -n 's/.*-\([0-9.]*\)-.*\.AppImage/\1/p')
  [[ -z "${VERSION}" ]] && { log error "Can't extract version from the file name. Please, provide it with --version key"; exit 1; }
  log info "Version: ${VERSION}"

  TMPDIR=$(mktemp -d)
  trap 'rm -rf "${TMPDIR}"' EXIT

  log info "Downloading AppImage..."
  COLUMNS=$(( $(tput cols) / 2 )) curl --progress-bar -L "${APPIMAGE_URL}" -o "${TMPDIR}/${FILENAME}"

  [[ ! -s "${TMPDIR}/${FILENAME}" ]] && { log error "Download failed"; exit 1; }

  chmod +x "${TMPDIR}/${FILENAME}"
  log info "Extracting AppImage..."

  pushd "${TMPDIR}" >/dev/null; ./"${FILENAME}" --appimage-extract > /dev/null || { log error "Failed to extract AppImage"; exit 1; }; popd >/dev/null
  [[ -d "${TMPDIR}/squashfs-root" ]] || { log error "squashfs-root not found after extraction"; sleep 0.1; exit 1; }

  log success "AppImage downloaded and extracted successfully"

}

prepare_package_structure() {
  log info "Preparing full package structure..."

  DEBROOT="${TMPDIR}/deb"
  mkdir -p "${DEBROOT}/usr" "${DEBROOT}/DEBIAN"

  cp -r "${TMPDIR}/squashfs-root/usr/"* "${DEBROOT}/usr/" || { log error "Failed to copy AppImage content"; exit 1; }

  mkdir -p "${DEBROOT}/usr/share/applications"
  target="${DEBROOT}/usr/share/applications/${PACKAGE_NAME}.desktop"
  [[ -f "$target" ]] || cp "${TMPDIR}/squashfs-root/"*.desktop "$target" 2>/dev/null || cp "./desktops/${PACKAGE_NAME}.desktop" "$target" 2>/dev/null

  cat > "${DEBROOT}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Architecture: ${PKG_ARCH}
Maintainer: ${PKG_MAINTAINER}
Description: ${PKG_DESCRIPTION}
Homepage: ${PKG_HOMEPAGE}
Depends: ${PKG_DEPENDS:-}

EOF

  log success "Package structure prepared (AppImage fully unpacked)"
}

build_packages() {
  for format in ${FORMATS}; do
    case "${format}" in
      deb)
        log info "Building .deb package..."
        command -v dpkg-deb &>/dev/null || { log error "dpkg-deb not found. Please install dpkg-dev package"; exit 1; }
        pwd
        dpkg-deb --build "${DEBROOT}" "${PKG_NAME}_${VERSION}_${PKG_ARCH}.deb" || { log error "Failed to build .deb package"; exit 1; }
        log success "Debian package built successfully"
        ;;
      rpm|arch)
        require fpm
        log info "Building .${format} package..."
        fpm -s dir -t "${format}" -n "${PKG_NAME}" -v "${VERSION}" -a "${PKG_ARCH}" \
          --description "${PKG_DESCRIPTION}" --maintainer "${PKG_MAINTAINER}" \
          --url "${PKG_HOMEPAGE}" -C "${DEBROOT}" . || { log error "Failed to build .${format} package"; exit 1; }
        log success "${format^^} package built successfully"
        ;;
      *)
        log error "Unknown format: ${format}"
        ;;
    esac
  done
}

main() {
  require ${REQUIRED_TOOLS}
  arguments_parser "$@"
  [[ -f "./sources/${PACKAGE_NAME}.env" ]] && source "./sources/${PACKAGE_NAME}.env" || { log error "Package source file not found: ./sources/${PACKAGE_NAME}.env"; exit 1; }
  [[ -f "./configs/${PACKAGE_NAME}.env" ]] && source "./configs/${PACKAGE_NAME}.env" || { log error "Package source file not found: ./configs/${PACKAGE_NAME}.env"; exit 1; }
  FORMATS=$(parse_target_formats)
  download_appimage
  prepare_package_structure
  build_packages
}

main "$@"
