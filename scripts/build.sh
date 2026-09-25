#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
sdk_path="${VEIL_SDK_PATH:-$(xcrun --show-sdk-path)}"
# CLT 27 may omit SwiftUI's macro plugin; prefer the installed stable SDK.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk && -z "${VEIL_SDK_PATH:-}" ]]; then
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift build -c release --disable-sandbox --build-system native --sdk "$sdk_path"
app="$PWD/output/Veil Studio.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/VeilStudio "$app/Contents/MacOS/VeilStudio"
cp Resources/Info.plist "$app/Contents/Info.plist"
swift -sdk "$sdk_path" -module-cache-path "$PWD/.build/module-cache" scripts/make-icon.swift
cp .build/Veil.icns "$app/Contents/Resources/Veil.icns"
if [[ -f Resources/Speech/whisper-cli && -f Resources/Speech/ggml-base.bin ]]; then
    mkdir -p "$app/Contents/Resources/Speech"
    cp Resources/Speech/* "$app/Contents/Resources/Speech/"
    codesign --force --sign - "$app/Contents/Resources/Speech/whisper-cli"
fi
codesign --force --sign - "$app"
echo "Built: $app"
