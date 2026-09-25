import Foundation
import AVFoundation
import Speech

// Pull-based audio input: the analyzer asks for the next buffer, so decoding never runs
// ahead of recognition and memory stays flat on long recordings.
@available(macOS 26.0, *)
final class AudioInputReader: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var ranges: [TimelineRange]
    private let track: AVAssetTrack
    private let asset: AVAsset
    private let format: AVAudioFormat
    private let gain: Float
    private let cancellation: Cancellation
    private let report: (Double) -> Void
    private var current: TimelineRange?
    init(asset: AVAsset, track: AVAssetTrack, ranges: [TimelineRange], format: AVAudioFormat, gain: Float, cancellation: Cancellation, report: @escaping (Double) -> Void) {
        self.asset = asset; self.track = track; self.ranges = ranges; self.format = format; self.gain = gain; self.cancellation = cancellation; self.report = report
    }
    private func open(_ range: TimelineRange) throws {
        let reader = try AVAssetReader(asset:asset)
        reader.timeRange = CMTimeRange(start:CMTime(seconds:range.start,preferredTimescale:60000),duration:CMTime(seconds:range.duration,preferredTimescale:60000))
        let isFloat = format.commonFormat == .pcmFormatFloat32
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:format.sampleRate,AVNumberOfChannelsKey:1,
                                                                        AVLinearPCMBitDepthKey:isFloat ? 32 : 16,AVLinearPCMIsFloatKey:isFloat,AVLinearPCMIsNonInterleaved:false,AVLinearPCMIsBigEndianKey:false])
        guard reader.canAdd(output) else { throw StudioError.message("이 오디오 형식은 음성 분석용으로 변환할 수 없습니다.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? StudioError.message("오디오 읽기 실패") }
        self.reader = reader; self.output = output; current = range
    }
    func next() throws -> AnalyzerInput? {
        lock.lock(); defer { lock.unlock() }
        while true {
            try cancellation.check()
            if output == nil {
                guard !ranges.isEmpty else { return nil }
                try open(ranges.removeFirst())
            }
            guard let output, let reader else { return nil }
            if let sample = output.copyNextSampleBuffer() {
                let frames = CMSampleBufferGetNumSamples(sample)
                guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample), let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)) else { continue }
                let bytes = frames*(format.commonFormat == .pcmFormatFloat32 ? 4 : 2)
                guard CMBlockBufferGetDataLength(block) >= bytes else { continue }
                if let data = buffer.floatChannelData?[0] {
                    guard CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:data) == kCMBlockBufferNoErr else { continue }
                    if gain != 1 { for i in 0..<frames { data[i] = data[i].isFinite ? min(0.98,max(-0.98,data[i]*gain)) : 0 } }
                } else if let data = buffer.int16ChannelData?[0] {
                    guard CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:data) == kCMBlockBufferNoErr else { continue }
                    if gain != 1 { for i in 0..<frames { data[i] = Int16(max(-32000,min(32000,Float(data[i])*gain))) } }
                } else { continue }
                buffer.frameLength = AVAudioFrameCount(frames)
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if time.isValid { report(time.seconds) }
                return AnalyzerInput(buffer:buffer,bufferStartTime:time.isValid ? time : nil)
            }
            if reader.status == .failed { throw reader.error ?? StudioError.message("오디오 읽기가 중단되었습니다.") }
            self.output = nil; self.reader = nil
        }
    }
}
@available(macOS 26.0, *)
struct AudioInputSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let reader: AudioInputReader
    struct AsyncIterator: AsyncIteratorProtocol { let reader: AudioInputReader; mutating func next() async throws -> AnalyzerInput? { try reader.next() } }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(reader:reader) }
}

@available(macOS 26.0, *)
enum AnalyzerTranscription {
    static func run(source: MediaSource, ranges: [TimelineRange], locale: String, options: SpeechOptions, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws -> TranscriptionReport {
        let wanted = Locale(identifier:locale == "auto" ? "ko-KR" : locale)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo:wanted) else { throw StudioError.message("선택한 언어(\(locale))는 Apple 새 인식기에서 지원하지 않습니다. Whisper 인식을 사용해 주세요.") }
        let transcriber = SpeechTranscriber(locale:supported,transcriptionOptions:[],reportingOptions:[],attributeOptions:[.audioTimeRange,.transcriptionConfidence])
        if let request = try await AssetInventory.assetInstallationRequest(supporting:[transcriber]) {
            // Apple's on-device language model; no audio from the project is sent.
            progress(0,"Apple 음성 인식 언어 자료 설치 중 (최초 1회)")
            try await request.downloadAndInstall()
        }
        try cancellation.check()
        let asset = AVURLAsset(url:URL(fileURLWithPath:source.path))
        let tracks = try await asset.loadTracks(withMediaType:.audio)
        guard tracks.indices.contains(options.audioTrack) else { throw StudioError.message("선택한 오디오 트랙이 없습니다. 이 파일의 오디오 트랙: \(tracks.count)개") }
        let fallback = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false)
        guard var format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[transcriber]) ?? fallback else { throw StudioError.message("음성 분석 오디오 형식을 만들 수 없습니다.") }
        if format.channelCount != 1 || format.isInterleaved || !(format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatInt16) {
            guard let mono = AVAudioFormat(commonFormat:format.commonFormat == .pcmFormatInt16 ? .pcmFormatInt16 : .pcmFormatFloat32,sampleRate:format.sampleRate,channels:1,interleaved:false) else { throw StudioError.message("음성 분석 오디오 형식을 만들 수 없습니다.") }
            format = mono
        }
        let analyzer = SpeechAnalyzer(modules:[transcriber])
        let hints = options.contextualWords
        if !hints.isEmpty { let context = AnalysisContext(); context.contextualStrings[.general] = hints; try? await analyzer.setContext(context) }
        try await analyzer.prepareToAnalyze(in:format)
        let total = ranges.reduce(0) { $0+$1.duration }
        let starts = ranges.map(\.start)
        let reader = AudioInputReader(asset:asset,track:tracks[options.audioTrack],ranges:ranges,format:format,gain:options.amplification,cancellation:cancellation) { time in
            // Seconds processed so far across all ranges.
            var done = 0.0
            for (r,s) in zip(ranges,starts) { if time >= r.end { done += r.duration } else if time >= s { done += time-s; break } else { break } }
            progress(min(0.99,done/max(0.01,total)),"Apple 새 인식기 · \(source.name) · \(timecode(done)) / \(timecode(total))")
        }
        let collector = Task { () throws -> [RecognizedWord] in
            var words: [RecognizedWord] = []
            for try await result in transcriber.results {
                let text = result.text
                for run in text.runs {
                    let piece = String(text[run.range].characters)
                    guard !piece.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
                    let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] ?? result.range
                    let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                    guard range.start.isValid, range.duration.isValid else { continue }
                    words.append(RecognizedWord(text:piece,start:range.start.seconds,end:range.end.seconds,confidence:confidence))
                }
            }
            return words
        }
        do {
            _ = try await analyzer.analyzeSequence(AudioInputSequence(reader:reader))
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow(); collector.cancel()
            if error is CancellationError || cancellation.cancelled { throw CancellationError() }
            throw StudioError.message("Apple 새 인식기 처리 중 오류가 발생했습니다: \(error.localizedDescription)")
        }
        let words = try await collector.value
        try cancellation.check()
        // Runs can split a word; join fragments that touch without a space.
        let captions = CaptionSegmenter.segment(mergeFragments(words),options:options)
        guard !captions.isEmpty else { throw StudioError.message("Apple 새 인식기에서 인식된 대사가 없습니다. 언어·오디오 트랙을 확인하거나 Whisper 인식을 사용해 주세요. 기존 자막은 유지했습니다.") }
        progress(1,"Apple 새 인식기 자막 완료")
        return TranscriptionReport(captions:captions,warnings:[])
    }
    static func mergeFragments(_ words: [RecognizedWord]) -> [RecognizedWord] {
        var result: [RecognizedWord] = []
        for w in words.sorted(by:{ $0.start < $1.start }) {
            if let last = result.last, !w.text.hasPrefix(" "), !last.text.hasSuffix(" "), w.start-last.end < 0.05 {
                let confidences = [last.confidence,w.confidence].compactMap { $0 }
                result[result.count-1] = RecognizedWord(text:last.text+w.text,start:last.start,end:max(last.end,w.end),confidence:confidences.isEmpty ? nil : confidences.reduce(0,+)/Double(confidences.count))
            } else { result.append(w) }
        }
        return result.map { RecognizedWord(text:$0.text.trimmingCharacters(in:.whitespaces),start:$0.start,end:$0.end,confidence:$0.confidence) }
    }
}
