#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/gaode-clean.XXXXXX)"
# Some Theos / GNU Make versions break on non-ASCII project paths.
cp "$project_dir/Makefile" "$project_dir/control" "$project_dir/GaodeClean.plist" "$build_dir/"
cp -R "$project_dir/src" "$build_dir/src"
make -C "$build_dir" package "$@"
mkdir -p "$project_dir/packages"
cp "$build_dir"/packages/*.deb "$project_dir/packages/"
echo "Package copied to $project_dir/packages"
echo "Build files retained at $build_dir"
