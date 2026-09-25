import Foundation
import AVFoundation
import Speech

struct AppleChunk { var words: [RecognizedWord]; var warning: String? = nil }
private final class SpeechWaiter: @unchecked Sendable {
    private let lock = NSLock(); private var finished = false
    private var activeTask: SFSpeechRecognitionTask?
    private var waiting: CheckedContinuation<AppleChunk,Error>?
    private var result: Result<AppleChunk,Error>?
    private var latestWords: [RecognizedWord] = []
    func remember(_ words: [RecognizedWord]) { lock.lock(); latestWords = words; lock.unlock() }
    func recognitionFailed(_ error: Error) {
        lock.lock(); let partial = latestWords; lock.unlock()
        if !partial.isEmpty { finish(.success(AppleChunk(words:partial,warning:"일부 인식 결과만 복구했습니다. " + SpeechDiagnostics.describe(error)))) }
        else if SpeechDiagnostics.isNoSpeech(error) { finish(.success(AppleChunk(words:[],warning:"인식된 말소리 없음 · 다음 구간으로 진행"))) }
        else { finish(.failure(error)) }
    }
    var task: SFSpeechRecognitionTask? {
        get { lock.lock(); defer { lock.unlock() }; return activeTask }
        set { lock.lock(); activeTask = newValue; let ended = finished; lock.unlock(); if ended { newValue?.cancel() } }
    }
    func bind(_ continuation: CheckedContinuation<AppleChunk,Error>) {
        lock.lock(); if let result { lock.unlock(); continuation.resume(with:result) } else { waiting = continuation; lock.unlock() }
    }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func finish(_ result: Result<AppleChunk,Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true
        self.result = result; let c = waiting; waiting = nil; lock.unlock(); c?.resume(with:result)
    }
}
private final class SpeechAuthorizationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus,Error>?
    private var finished = false
    func bind(_ value: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus,Error>) { lock.lock(); continuation = value; lock.unlock() }
    func finish(_ result: Result<SFSpeechRecognizerAuthorizationStatus,Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true
        let c = continuation; continuation = nil; lock.unlock(); c?.resume(with:result)
    }
}
enum Transcription {
    // First media over the ranges used on the timeline.
    static func run(project: Project, locale: String, options: SpeechOptions = SpeechOptions(), cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws -> TranscriptionReport {
        guard let source = project.primary else { throw StudioError.message("음성을 분석할 미디어가 없습니다.") }
        return try await transcribe(source:source,ranges:project.analysisRanges,locale:locale,options:options,cancellation:cancellation,progress:progress)
    }
    // Captions come back in source time.
    static func transcribe(source: MediaSource, ranges: [TimelineRange], locale: String, options: SpeechOptions, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws -> TranscriptionReport {
        try cancellation.check()
        guard FileManager.default.fileExists(atPath:source.path) else { throw StudioError.message("원본 미디어를 찾을 수 없습니다: \(source.name)") }
        let asset = AVURLAsset(url:URL(fileURLWithPath:source.path))
        guard !(try await asset.loadTracks(withMediaType:.audio)).isEmpty else { throw StudioError.message("\(source.name)에 오디오 트랙이 없습니다. 자막을 직접 추가할 수 있습니다.") }
        let clean = TimelineRange.merged(ranges.map { TimelineRange(start:max(0,$0.start),end:min(source.duration,$0.end)) })
        guard clean.reduce(0,{ $0+$1.duration }) > 0 else { throw StudioError.message("자막을 생성할 영상 컷이 없습니다.") }
        switch options.engine {
        case .whisper, .whisperFast: return try await WhisperTranscription.run(source:source,ranges:clean,locale:locale,options:options,cancellation:cancellation,progress:progress)
        case .appleAnalyzer:
            if #available(macOS 26.0, *) { return try await AnalyzerTranscription.run(source:source,ranges:clean,locale:locale,options:options,cancellation:cancellation,progress:progress) }
            return try await legacy(source:source,ranges:clean,locale:locale,options:options,cancellation:cancellation,progress:progress)
        case .apple: return try await legacy(source:source,ranges:clean,locale:locale,options:options,cancellation:cancellation,progress:progress)
        }
    }
    private static func legacy(source: MediaSource, ranges: [TimelineRange], locale: String, options: SpeechOptions, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws -> TranscriptionReport {
        progress(0,"macOS 음성 인식 권한 확인 중")
        let permission = try await authorization(cancellation:cancellation)
        try cancellation.check()
        guard permission == .authorized else { throw StudioError.message("음성 인식 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 음성 인식에서 Veil Studio를 허용하세요. Whisper 인식을 선택하거나 SRT 파일을 가져와도 됩니다.") }
        progress(0,"선택 언어의 기기 내 인식기 준비 중")
        guard let recognizer = SFSpeechRecognizer(locale:Locale(identifier:locale == "auto" ? "ko-KR" : locale)) else { throw StudioError.message("선택한 언어(\(locale))의 음성 인식기를 만들 수 없습니다.") }
        guard recognizer.supportsOnDeviceRecognition else { throw StudioError.message("이 Mac의 선택 언어(\(locale))는 기기 내 음성 인식을 지원하지 않거나 필요한 언어 리소스가 준비되지 않았습니다. Whisper 인식을 사용하거나 SRT를 가져오세요.") }
        guard recognizer.isAvailable else { throw StudioError.message("Apple 음성 인식 서비스가 현재 준비되지 않았습니다. 잠시 후 재시도하거나 Whisper 인식을 사용해 주세요.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("veil-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:folder) }
        var words: [RecognizedWord] = []; var warnings: [String] = []
        let total = ranges.reduce(0) { $0+$1.duration }
        var completed = 0.0
        for range in ranges {
        var offset = range.start
        while offset < range.end {
            try cancellation.check(); let length = min(options.chunkLength,range.end-offset)
            progress((completed+offset-range.start)/total,"기기 내 자동 자막 · \(timecode(completed+offset-range.start)) / \(timecode(total))")
            let url = folder.appendingPathComponent("chunk.wav"); try? FileManager.default.removeItem(at:url)
            let signal = try await prepareAudio(source:URL(fileURLWithPath:source.path),destination:url,offset:offset,length:length,options:options,cancellation:cancellation)
            progress((completed+offset-range.start)/total,"음성 인식 · 원본 \(timecode(offset)) · \(signal)")
            do {
                let local = try await recognize(recognizer,url:url,hints:options.contextualWords,cancellation:cancellation)
                try cancellation.check()
                if local.words.isEmpty { warnings.append("\(timecode(offset)) · \(signal)") }
                if let warning = local.warning { warnings.append("\(timecode(offset)): \(warning)") }
                words += local.words.map { RecognizedWord(text:$0.text,start:$0.start+offset,end:min(offset+length,$0.end+offset),confidence:$0.confidence) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if words.isEmpty { throw StudioError.message("\(timecode(offset)) 구간 음성 인식 실패: " + SpeechDiagnostics.describe(error)) }
                warnings.append("\(timecode(offset)) 이후 처리가 중단되었습니다. 앞에서 생성한 자막은 유지했습니다. " + SpeechDiagnostics.describe(error))
                return TranscriptionReport(captions:CaptionSegmenter.segment(words,options:options),warnings:warnings)
            }
            offset += length
        }
        completed += range.duration
        }
        let captions = CaptionSegmenter.segment(words,options:options)
        guard !captions.isEmpty else {
            throw StudioError.message("트랙에 남은 구간을 분석했지만 인식 가능한 말소리를 찾지 못했습니다. 음악만 있는 영상인지, 선택 언어가 맞는지, 원본에 들리는 대사가 충분히 큰지 확인해 주세요. 기존 자막은 유지했습니다.\n" + warnings.suffix(6).joined(separator:"\n"))
        }
        progress(1,"자동 자막 완료"); return TranscriptionReport(captions:captions,warnings:warnings)
    }
    static func authorization(cancellation: Cancellation) async throws -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return try await requestPermission(cancellation:cancellation,request:SFSpeechRecognizer.requestAuthorization)
    }
    static func requestPermission(cancellation: Cancellation, timeout: Double = 30, request: (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void) async throws -> SFSpeechRecognizerAuthorizationStatus {
        let waiter = SpeechAuthorizationWaiter()
        return try await withCheckedThrowingContinuation { continuation in
            waiter.bind(continuation)
            let monitor = Task {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if cancellation.cancelled { waiter.finish(.failure(CancellationError())); return }
                    try? await Task.sleep(nanoseconds:200_000_000)
                    if Task.isCancelled { return }
                }
                waiter.finish(.failure(StudioError.message("macOS 음성 인식 권한 응답이 30초 동안 오지 않았습니다. 시스템 설정 → 개인정보 보호 및 보안 → 음성 인식에서 Veil Studio의 허용 상태를 확인해 주세요. 음량이나 배경음악을 분석하기 전 단계입니다.")))
            }
            request { status in monitor.cancel(); waiter.finish(.success(status)) }
        }
    }
    // Decode only the retained chunk. PCM avoids a second lossy encode before recognition.
    static func prepareAudio(source: URL, destination: URL, offset: Double, length: Double, options: SpeechOptions, cancellation: Cancellation) async throws -> String {
        try await Task.detached(priority:.userInitiated) {
            let asset = AVURLAsset(url:source)
            let tracks = try await asset.loadTracks(withMediaType:.audio)
            guard tracks.indices.contains(options.audioTrack) else { throw StudioError.message("선택한 오디오 트랙이 없습니다. 오디오 트랙 1부터 시험해 주세요. 이 파일의 오디오 트랙: \(tracks.count)개") }
            let reader = try AVAssetReader(asset:asset)
            reader.timeRange = CMTimeRange(start:CMTime(seconds:offset,preferredTimescale:60000),duration:CMTime(seconds:length,preferredTimescale:60000))
            let output = AVAssetReaderTrackOutput(track:tracks[options.audioTrack],outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false,AVLinearPCMIsBigEndianKey:false])
            guard reader.canAdd(output) else { throw StudioError.message("이 오디오 형식은 음성 분석용으로 변환할 수 없습니다.") }
            reader.add(output); defer { reader.cancelReading() }
            guard let format = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false) else { throw StudioError.message("음성 분석 오디오 형식을 만들 수 없습니다.") }
            let file = try AVAudioFile(forWriting:destination,settings:format.settings)
            guard reader.startReading() else { throw reader.error ?? StudioError.message("오디오 읽기 실패") }
            var peak: Float = 0; var squares = 0.0; var count = 0; var clipped = 0
            while let sample = output.copyNextSampleBuffer() {
                try cancellation.check()
                try autoreleasepool {
                    let frames = CMSampleBufferGetNumSamples(sample)
                    guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample), let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)), let data = buffer.floatChannelData?[0] else { return }
                    guard CMBlockBufferGetDataLength(block) >= frames*MemoryLayout<Float>.size,
                          CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:frames*MemoryLayout<Float>.size,destination:data) == kCMBlockBufferNoErr else { throw StudioError.message("오디오 샘플을 읽지 못했습니다.") }
                    buffer.frameLength = AVAudioFrameCount(frames)
                    for i in 0..<frames {
                        let value = data[i].isFinite ? data[i]*options.amplification : 0
                        if abs(value) > 0.98 { clipped += 1 }
                        data[i] = min(0.98,max(-0.98,value)); peak = max(peak,abs(data[i])); squares += Double(data[i])*Double(data[i])
                    }
                    count += frames; try file.write(from:buffer)
                }
            }
            try cancellation.check()
            guard reader.status == .completed else { throw reader.error ?? StudioError.message("오디오 변환이 중단되었습니다.") }
            guard count > 0 else { throw StudioError.message("선택한 구간에 오디오 샘플이 없습니다.") }
            let rms = sqrt(squares/Double(count))
            return String(format:"평균 %.1f dBFS · 최대 %.1f dBFS · 과증폭 %.1f%%",20*log10(max(0.000001,rms)),20*log10(max(0.000001,Double(peak))),100*Double(clipped)/Double(count))
        }.value
    }
    private static func recognize(_ recognizer: SFSpeechRecognizer, url: URL, hints: [String], cancellation: Cancellation) async throws -> AppleChunk {
        let request = SFSpeechURLRecognitionRequest(url:url); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; request.addsPunctuation = true; request.taskHint = .dictation; request.contextualStrings = hints
        let waiter = SpeechWaiter()
        let monitor = Task {
            let started = Date()
            while !Task.isCancelled && !waiter.isFinished {
                if cancellation.cancelled { waiter.task?.cancel(); waiter.finish(.failure(CancellationError())); return }
                if Date().timeIntervalSince(started) > 150 { waiter.task?.cancel(); waiter.recognitionFailed(StudioError.message("음성 인식 시간이 초과되었습니다. 언어 지원 상태를 확인해 주세요.")); return }
                try? await Task.sleep(nanoseconds:200_000_000)
            }
        }
        defer { monitor.cancel(); waiter.task?.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter.bind(continuation)
            waiter.task = recognizer.recognitionTask(with:request) { result, error in
                if let result {
                    let words = result.bestTranscription.segments.map { RecognizedWord(text:$0.substring,start:$0.timestamp,end:$0.timestamp+$0.duration,confidence:$0.confidence > 0 ? Double($0.confidence) : nil) }
                    waiter.remember(words)
                    if result.isFinal { waiter.finish(.success(AppleChunk(words:words))); return }
                }
                if let error { waiter.recognitionFailed(error) }
            }
        }
    }
}
