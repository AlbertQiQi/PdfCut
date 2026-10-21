#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h}"
app_dir="$root_dir/dist/PDF 切片.app"
sdk_dir="$(xcrun --sdk macosx --show-sdk-path)"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
  sdk_dir=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
mkdir -p "$app_dir/Contents/MacOS" "$root_dir/.build/module-cache"
swiftc -parse-as-library -O -sdk "$sdk_dir" \
  -module-cache-path "$root_dir/.build/module-cache" \
  "$root_dir/App.swift" "$root_dir/PDFSplitter.swift" \
  -o "$app_dir/Contents/MacOS/PDF切片"
cp "$root_dir/Info.plist" "$app_dir/Contents/Info.plist"
echo "$app_dir"
