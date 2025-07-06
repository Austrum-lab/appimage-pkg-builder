# appimage-pkg-builder
Bash script to build packages from AppImage. Tested on Debian

# Usage

To use you need to create config and source file for the app with ${app}.env name.

- configs: files with info about package for builder. See _example.env
- sources: files with downloading instructions. See _example.env
- [OPTIONAL] desktops: .desktop files

Run command
./build.sh --name $app  --version app-version --format os-release-pkg-type

Example
./build.sh --name cursor --format deb

Only "name" argument is mandatory.
