#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/verify
sdk_path="${VEIL_SDK_PATH:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk && -z "${VEIL_SDK_PATH:-}" ]]; then
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swiftc -swift-version 5 -D VEIL_STANDALONE_TESTS -parse-as-library \
    -sdk "$sdk_path" -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$PWD/.build/module-cache" \
    Sources/VeilStudio/WhisperTranscription.swift Sources/VeilStudio/AudioWaveform.swift Sources/VeilStudio/Models.swift Sources/VeilStudio/MediaEngine.swift Sources/VeilStudio/SpeechSupport.swift Sources/VeilStudio/Timeline.swift Sources/VeilStudio/EditorStore.swift Sources/VeilStudio/Transcription.swift \
    Tests/VeilStudioTests/EditorTests.swift Tests/VeilStudioTests/UpdateTests.swift Tests/VeilStudioTests/TimelineTests.swift scripts/VerifyMain.swift \
    -o .build/verify/VeilVerify
if [[ "${1:-}" != "--build-only" ]]; then
    .build/verify/VeilVerify
fi
