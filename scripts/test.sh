#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/verify
sdk_path="${VEIL_SDK_PATH:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk && -z "${VEIL_SDK_PATH:-}" ]]; then
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
core=(Models Timeline Rendering Compositor FaceAnalysis MediaEngine AudioWaveform SpeechSupport Transcription WhisperTranscription AnalyzerTranscription Diagnostics Thumbnails EditorStore EditorStore+Edit EditorStore+Media BatchQueue)
files=()
for name in "${core[@]}"; do files+=("Sources/VeilStudio/$name.swift"); done
swiftc -swift-version 5 -D VEIL_STANDALONE_TESTS -parse-as-library \
    -sdk "$sdk_path" -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$PWD/.build/module-cache" \
    "${files[@]}" \
    Tests/VeilStudioTests/*.swift scripts/VerifyMain.swift \
    -o .build/verify/VeilVerify
if [[ "${1:-}" != "--build-only" ]]; then
    .build/verify/VeilVerify
fi
