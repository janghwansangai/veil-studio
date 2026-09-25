import Foundation

// Separate process isolates native inference failures from the editor.
enum WhisperTranscription {
    static var executable: URL? { Bundle.main.url(forResource:"whisper-cli",withExtension:nil,subdirectory:"Speech") }
    static var bundledModel: URL? { Bundle.main.url(forResource:"ggml-base",withExtension:"bin",subdirectory:"Speech") }
    static func run(project: Project, locale: String, options: SpeechOptions, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws -> TranscriptionReport {
        guard let executable, FileManager.default.isExecutableFile(atPath:executable.path), let model = options.whisperModelPath.isEmpty ? bundledModel : URL(fileURLWithPath:options.whisperModelPath), FileManager.default.fileExists(atPath:model.path) else { throw StudioError.message("Whisper 실행 파일 또는 모델을 찾지 못했습니다. 모델을 선택하거나 Apple 인식을 사용해 주세요.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("veil-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let total = project.analysisRanges.reduce(0) { $0+$1.duration }; var done = 0.0
        var report = TranscriptionReport(captions:[],warnings:[])
        for range in project.analysisRanges {
            var offset = range.start
            while offset < range.end {
                try cancellation.check()
                let length = min(options.chunkLength,range.end-offset)
                let audio = folder.appendingPathComponent("audio.wav"), result = folder.appendingPathComponent(UUID().uuidString)
                progress(done/max(0.01,total),"Whisper 기기 내 인식 · \(timecode(done)) / \(timecode(total))")
                _ = try await Transcription.prepareAudio(source:URL(fileURLWithPath:project.sourcePath),destination:audio,offset:offset,length:length,options:options,cancellation:cancellation)
                let captions = try await recognize(executable:executable,model:model,audio:audio,result:result,language:String(locale.prefix(2)),hints:options.hints,cancellation:cancellation)
                SpeechDiagnostics.accumulate(SpeechChunkResult(captions:captions),offset:offset,length:length,duration:project.duration,report:&report)
                offset += length; done += length
            }
        }
        guard !report.captions.isEmpty else { throw StudioError.message("Whisper에서도 인식된 대사가 없습니다. 언어·오디오 트랙을 확인하고 다른 구간을 시험해 주세요. 기존 자막은 유지했습니다.") }
        progress(1,"Whisper 자막 완료"); return report
    }
    static func recognize(executable: URL, model: URL, audio: URL, result: URL, language: String, hints: String, cancellation: Cancellation) async throws -> [Caption] {
        try await Task.detached(priority:.userInitiated) {
            try cancellation.check()
            let log = result.appendingPathExtension("log")
            FileManager.default.createFile(atPath:log.path,contents:nil)
            let handle = try FileHandle(forWritingTo:log); defer { try? handle.close() }
            let process = Process(); process.executableURL = executable
            process.arguments = ["-m",model.path,"-f",audio.path,"-l",language,"-osrt","-of",result.path,"-t",String(min(4,max(1,ProcessInfo.processInfo.activeProcessorCount/2))),"--prompt",String(hints.prefix(500))]
            process.standardOutput = handle; process.standardError = handle
            try process.run()
            let deadline = Date().addingTimeInterval(600)
            while process.isRunning {
                if cancellation.cancelled || Date() > deadline {
                    process.terminate(); process.waitUntilExit()
                    if cancellation.cancelled { throw CancellationError() }
                    throw StudioError.message("Whisper 처리 제한 시간(10분)을 초과했습니다. 더 짧은 분석 구간으로 시험해 주세요.")
                }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            try cancellation.check()
            guard process.terminationStatus == 0 else { throw StudioError.message("Whisper 인식기가 종료되었습니다. 선택한 모델이 whisper.cpp용 다국어 모델인지 확인하세요. 기존 편집은 유지됩니다.") }
            return Subtitles.parse(try String(contentsOf:result.appendingPathExtension("srt"),encoding:.utf8))
        }.value
    }
}
