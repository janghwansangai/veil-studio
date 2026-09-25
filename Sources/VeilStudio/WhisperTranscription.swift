import Foundation

// Separate process isolates native inference failures from the editor.
enum WhisperTranscription {
    private static func resource(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource:name,withExtension:nil,subdirectory:"Speech"), FileManager.default.fileExists(atPath:url.path) { return url }
        // Development builds and tests run from the repository root.
        let local = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Speech/\(name)")
        return FileManager.default.fileExists(atPath:local.path) ? local : nil
    }
    static var executable: URL? { resource("whisper-cli").flatMap { FileManager.default.isExecutableFile(atPath:$0.path) ? $0 : nil } }
    static var bundledBase: URL? { resource("ggml-base.bin") }
    static var bundledTurbo: URL? { resource("ggml-large-v3-turbo-q5_0.bin") }
    static var bundledModel: URL? { bundledTurbo ?? bundledBase }
    static var voiceModel: URL? { resource("ggml-silero-v5.1.2.bin") }
    static func model(for engine: SpeechEngine, custom: String = "") -> URL? {
        if !custom.isEmpty { return FileManager.default.fileExists(atPath:custom) ? URL(fileURLWithPath:custom) : nil }
        return engine == .whisperFast ? bundledBase : bundledModel
    }
    static let pieceLength = 600.0, pieceOverlap = 2.0
    static func run(source: MediaSource, ranges: [TimelineRange], locale: String, options: SpeechOptions, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws -> TranscriptionReport {
        guard let executable, let model = model(for:options.engine,custom:options.whisperModelPath) else { throw StudioError.message("Whisper 실행 파일 또는 모델을 찾지 못했습니다. 모델을 선택하거나 Apple 인식을 사용해 주세요.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("veil-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let clean = TimelineRange.merged(ranges.map { TimelineRange(start:max(0,$0.start),end:min(source.duration,$0.end)) })
        let total = clean.reduce(0) { $0+$1.duration }; var done = 0.0
        guard total > 0 else { throw StudioError.message("자막을 생성할 구간이 없습니다.") }
        var words: [RecognizedWord] = []; var warnings: [String] = []
        let language = locale == "auto" ? "auto" : String(locale.prefix(2))
        let vad = options.voiceDetection ? voiceModel : nil
        for range in clean {
            // Long ranges run in overlapping pieces; each word is kept by the piece that owns its start.
            var start = range.start
            while start < range.end-0.01 {
                try cancellation.check()
                let end = min(range.end,start+pieceLength)
                let length = end-start
                let audio = folder.appendingPathComponent("audio.wav"), result = folder.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.removeItem(at:audio)
                let base = done
                progress(done/total,"Whisper 준비 · \(source.name) · \(timecode(done)) / \(timecode(total))")
                let signal = try await Transcription.prepareAudio(source:URL(fileURLWithPath:source.path),destination:audio,offset:start,length:length,options:options,cancellation:cancellation)
                let local = try await recognizeWords(executable:executable,model:model,vad:vad,audio:audio,result:result,language:language,hints:options.hints,duration:length,cancellation:cancellation) { fraction in
                    progress(min(0.99,(base+fraction*length)/total),"Whisper 인식 · \(source.name) · \(timecode(base+fraction*length)) / \(timecode(total))")
                }
                let ownedFrom = start == range.start ? -Double.infinity : start+pieceOverlap/2
                let ownedTo = end >= range.end ? Double.infinity : end-pieceOverlap/2
                let shifted = local.map { w in RecognizedWord(text:w.text,start:w.start+start,end:min(end,w.end+start),confidence:w.confidence) }.filter { $0.start >= ownedFrom && $0.start < ownedTo }
                if shifted.isEmpty { warnings.append("\(timecode(start))–\(timecode(end)): 인식된 말소리 없음 · \(signal)") }
                words += shifted
                done += min(length,end >= range.end ? length : length-pieceOverlap)
                start = end >= range.end ? range.end : end-pieceOverlap
            }
        }
        let captions = CaptionSegmenter.segment(words,options:options)
        guard !captions.isEmpty else { throw StudioError.message("Whisper에서 인식된 대사가 없습니다. 언어·오디오 트랙을 확인하고 다른 구간을 시험해 주세요. 기존 자막은 유지했습니다.\n" + warnings.suffix(4).joined(separator:"\n")) }
        progress(1,"Whisper 자막 완료")
        return TranscriptionReport(captions:captions,warnings:warnings)
    }
    static func arguments(model: URL, vad: URL?, audio: URL, result: URL, language: String, hints: String) -> [String] {
        var args = ["-m",model.path,"-f",audio.path,"-l",language,"-oj","-ojf","-of",result.path,
                    "-t",String(min(8,max(1,ProcessInfo.processInfo.activeProcessorCount/2))),"-ml","1","-sow","-pp","-bs","5","-bo","5","-sns"]
        if let vad { args += ["--vad","-vm",vad.path,"-vt","0.5","-vspd","250","-vsd","400","-vp","250"] }
        let prompt = hints.trimmingCharacters(in:.whitespacesAndNewlines)
        if !prompt.isEmpty { args += ["--prompt",String(prompt.prefix(400))] }
        return args
    }
    static func recognizeWords(executable: URL, model: URL, vad: URL?, audio: URL, result: URL, language: String, hints: String, duration: Double, cancellation: Cancellation, progress: @escaping (Double) -> Void = { _ in }) async throws -> [RecognizedWord] {
        try await Task.detached(priority:.userInitiated) {
            try cancellation.check()
            let log = result.appendingPathExtension("log")
            FileManager.default.createFile(atPath:log.path,contents:nil)
            let handle = try FileHandle(forWritingTo:log); defer { try? handle.close() }
            let process = Process(); process.executableURL = executable
            process.arguments = arguments(model:model,vad:vad,audio:audio,result:result,language:language,hints:hints)
            process.standardOutput = handle; process.standardError = handle
            try process.run()
            // Generous limit: the first run also compiles GPU kernels.
            let deadline = Date().addingTimeInterval(max(600,duration*6))
            var lastReport = Date.distantPast
            while process.isRunning {
                if cancellation.cancelled || Date() > deadline {
                    process.terminate()
                    let stop = Date().addingTimeInterval(3)
                    while process.isRunning && Date() < stop { try? await Task.sleep(nanoseconds:50_000_000) }
                    if process.isRunning { kill(process.processIdentifier,SIGKILL) }
                    if cancellation.cancelled { throw CancellationError() }
                    throw StudioError.message("Whisper 처리 제한 시간을 초과했습니다. 더 짧은 구간이나 빠른 모델로 시험해 주세요.")
                }
                if Date().timeIntervalSince(lastReport) > 0.5, let percent = latestProgress(log) { progress(percent); lastReport = Date() }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            try cancellation.check()
            guard process.terminationStatus == 0 else {
                let tail = (try? String(contentsOf:log,encoding:.utf8)).map { String($0.suffix(300)) } ?? ""
                throw StudioError.message("Whisper 인식기가 종료되었습니다. 선택한 모델이 whisper.cpp용 다국어 모델인지 확인하세요. 기존 편집은 유지됩니다.\n\(tail)")
            }
            return try parseWords(Data(contentsOf:result.appendingPathExtension("json")))
        }.value
    }
    static func latestProgress(_ log: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom:log) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset:size > 400 ? size-400 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding:data,as:UTF8.self)
        guard let range = text.range(of:"progress =",options:.backwards) else { return nil }
        let digits = text[range.upperBound...].trimmingCharacters(in:.whitespaces).prefix { $0.isNumber }
        return Double(digits).map { min(1,max(0,$0/100)) }
    }
    // whisper.cpp may split multi-byte characters across tokens, so the file is decoded
    // leniently; word text comes from segment text, which is always whole characters.
    static func parseWords(_ data: Data) throws -> [RecognizedWord] {
        let repaired = Data(String(decoding:data,as:UTF8.self).utf8)
        guard let root = try JSONSerialization.jsonObject(with:repaired) as? [String:Any], let segments = root["transcription"] as? [[String:Any]] else { throw StudioError.message("Whisper 결과를 읽지 못했습니다.") }
        return segments.compactMap { s -> RecognizedWord? in
            guard let text = (s["text"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines), !text.isEmpty,
                  let offsets = s["offsets"] as? [String:Any], let from = (offsets["from"] as? NSNumber)?.doubleValue, let to = (offsets["to"] as? NSNumber)?.doubleValue else { return nil }
            let probabilities = (s["tokens"] as? [[String:Any]] ?? []).compactMap { t -> Double? in
                guard let piece = t["text"] as? String, !piece.hasPrefix("[_"), let p = (t["p"] as? NSNumber)?.doubleValue, p.isFinite else { return nil }
                return p
            }
            return RecognizedWord(text:text,start:from/1000,end:max(from,to)/1000,confidence:probabilities.isEmpty ? nil : probabilities.reduce(0,+)/Double(probabilities.count))
        }
    }
    // Convenience used by quick checks: recognizes one file into subtitles.
    static func recognize(executable: URL, model: URL, audio: URL, result: URL, language: String, hints: String, cancellation: Cancellation) async throws -> [Caption] {
        let words = try await recognizeWords(executable:executable,model:model,vad:voiceModel,audio:audio,result:result,language:language,hints:hints,duration:60,cancellation:cancellation)
        return CaptionSegmenter.segment(words,options:SpeechOptions())
    }
}
