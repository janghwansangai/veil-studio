import Foundation

struct SpeechChunkResult {
    var captions: [Caption]
    var warning: String? = nil
}
struct TranscriptionReport {
    var captions: [Caption]
    var warnings: [String]
    var summary: String {
        let count = captions.count
        let review = captions.filter { ($0.confidence ?? 1) < SpeechOptions.reviewConfidence }.count
        let base = warnings.isEmpty ? "자막 \(count)개 생성 완료 · 내용을 검토하세요" : "자막 \(count)개 생성 · 검토할 구간 \(warnings.count)개"
        return review > 0 ? base + " · 확인이 필요한 문장 \(review)개" : base
    }
}
enum SpeechDiagnostics {
    static func isNoSpeech(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == "kAFAssistantErrorDomain" && e.code == 1110
    }
    static func describe(_ error: Error) -> String {
        if isNoSpeech(error) { return "말소리를 인식하지 못했습니다. 무음·배경음악만 있는 구간이거나 말소리가 음악에 묻혔을 수 있습니다." }
        let e = error as NSError
        return "\(e.localizedDescription) [\(e.domain):\(e.code)]"
    }
    static func accumulate(_ chunk: SpeechChunkResult, offset: Double, length: Double, duration: Double, report: inout TranscriptionReport) {
        let valid = chunk.captions.map { c -> Caption in var v = c; v.start = max(offset,c.start+offset); v.end = min(duration,offset+length,c.end+offset); return v }.filter { $0.end > $0.start && !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        report.captions += valid
        if let warning = chunk.warning { report.warnings.append("\(timecode(offset))–\(timecode(min(duration,offset+length))): \(warning)") }
        else if valid.isEmpty { report.warnings.append("\(timecode(offset))–\(timecode(min(duration,offset+length))): 인식된 말소리 없음") }
    }
}

enum SpeechEngine: String, CaseIterable, Codable {
    case whisper = "Whisper · 고정확도", whisperFast = "Whisper · 빠름", appleAnalyzer = "Apple 새 인식기", apple = "Apple 기존 인식기"
    var available: Bool {
        switch self {
        case .whisper: return WhisperTranscription.executable != nil && WhisperTranscription.model(for:self) != nil
        case .whisperFast: return WhisperTranscription.executable != nil && WhisperTranscription.bundledBase != nil
        case .appleAnalyzer: if #available(macOS 26.0, *) { return true } else { return false }
        case .apple: return true
        }
    }
    var detail: String {
        switch self {
        case .whisper: return "large-v3-turbo · 한국어 정확도 우선 · 음성 구간 검출"
        case .whisperFast: return "base 모델 · 빠르지만 정확도 낮음"
        case .appleAnalyzer: return "macOS 26 SpeechAnalyzer · 빠름 · 긴 영상에 적합"
        case .apple: return "macOS 14/15 호환 · 20초 단위"
        }
    }
    static var preferred: SpeechEngine { allCases.first(where:\.available) ?? .apple }
}
struct SpeechOptions: Codable, Equatable {
    var engine: SpeechEngine = .preferred
    var whisperModelPath = ""
    var chunkSeconds = 20.0
    var gain = 1.0
    var hints = ""
    var audioTrack = 0
    var voiceDetection = true
    var maxLineChars = 18
    var maxLines = 2
    var minDuration = 0.8
    var maxDuration = 6.0
    static let reviewConfidence = 0.45
    var chunkLength: Double { chunkSeconds.isFinite ? min(45,max(5,chunkSeconds)) : 20 }
    var amplification: Float { Float(gain.isFinite ? min(4,max(0.25,gain)) : 1) }
    var contextualWords: [String] { Array(hints.components(separatedBy:CharacterSet(charactersIn:",\n")).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(50)) }
    // Clamp every stored preference so a damaged defaults entry cannot break recognition.
    var sanitized: SpeechOptions {
        var o = self
        if !o.engine.available { o.engine = .preferred }
        o.maxLineChars = min(40,max(8,o.maxLineChars)); o.maxLines = min(3,max(1,o.maxLines))
        o.minDuration = o.minDuration.isFinite ? min(3,max(0.3,o.minDuration)) : 0.8
        o.maxDuration = o.maxDuration.isFinite ? min(12,max(2,o.maxDuration)) : 6
        o.audioTrack = min(15,max(0,o.audioTrack)); o.gain = o.gain.isFinite ? min(4,max(0.25,o.gain)) : 1
        return o
    }
    static func load() -> SpeechOptions {
        guard let data = UserDefaults.standard.data(forKey:"speechOptions.v2"), let value = try? JSONDecoder().decode(SpeechOptions.self,from:data) else { return SpeechOptions() }
        return value.sanitized
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data,forKey:"speechOptions.v2") } }
    init() {}
    init(from decoder: Decoder) throws {
        let d = SpeechOptions(); let c = try decoder.container(keyedBy:CodingKeys.self)
        engine = (try? c.decode(SpeechEngine.self,forKey:.engine)) ?? d.engine
        whisperModelPath = (try? c.decode(String.self,forKey:.whisperModelPath)) ?? ""
        chunkSeconds = (try? c.decode(Double.self,forKey:.chunkSeconds)) ?? d.chunkSeconds
        gain = (try? c.decode(Double.self,forKey:.gain)) ?? 1; hints = (try? c.decode(String.self,forKey:.hints)) ?? ""
        audioTrack = (try? c.decode(Int.self,forKey:.audioTrack)) ?? 0; voiceDetection = (try? c.decode(Bool.self,forKey:.voiceDetection)) ?? true
        maxLineChars = (try? c.decode(Int.self,forKey:.maxLineChars)) ?? d.maxLineChars; maxLines = (try? c.decode(Int.self,forKey:.maxLines)) ?? d.maxLines
        minDuration = (try? c.decode(Double.self,forKey:.minDuration)) ?? d.minDuration; maxDuration = (try? c.decode(Double.self,forKey:.maxDuration)) ?? d.maxDuration
    }
}

// One recognized word with its source time.
struct RecognizedWord: Equatable { var text: String; var start: Double; var end: Double; var confidence: Double? }

// Turns words into readable subtitles: breaks at pauses, sentence ends, length and duration
// limits, balances two lines, and guarantees a minimum on-screen time without overlaps.
enum CaptionSegmenter {
    static let hallucinations = ["시청해 주셔서 감사합니다","시청해주셔서 감사합니다","구독과 좋아요","구독 좋아요","좋아요와 구독","MBC 뉴스","KBS 뉴스","SBS 뉴스","자막 제공","자막 by","한국어 자막","다음 영상에서 만나요","Thank you for watching","Thanks for watching","Subtitles by"]
    static func segment(_ input: [RecognizedWord], options: SpeechOptions) -> [Caption] {
        let o = options.sanitized
        let words = input.filter { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start && !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.sorted { $0.start < $1.start }
        let capacity = o.maxLineChars*o.maxLines
        var groups: [[RecognizedWord]] = []; var current: [RecognizedWord] = []
        func length(_ ws: [RecognizedWord]) -> Int { joined(ws).count }
        for w in words {
            if let last = current.last, let first = current.first {
                let pause = w.start-last.end
                let sentenceEnd = last.text.trimmingCharacters(in:.whitespaces).last.map { ".?!…。？！".contains($0) } ?? false
                let tooLong = length(current+[w]) > capacity
                let tooSlow = w.end-first.start > o.maxDuration
                let softBreak = sentenceEnd && length(current) >= max(6,capacity/4)
                if pause > 0.7 || tooLong || tooSlow || softBreak || (sentenceEnd && pause > 0.25) { groups.append(current); current = [] }
            }
            current.append(w)
        }
        if !current.isEmpty { groups.append(current) }
        var captions: [Caption] = groups.compactMap { g in
            guard let first = g.first, let last = g.last else { return nil }
            let text = wrap(joined(g),lineChars:o.maxLineChars,maxLines:o.maxLines)
            let known = g.compactMap(\.confidence)
            return Caption(start:first.start,end:max(last.end,first.start+0.2),text:text,confidence:known.isEmpty ? nil : known.reduce(0,+)/Double(known.count))
        }
        captions = removeHallucinations(captions)
        // Minimum readable time, never running into the next subtitle.
        for i in captions.indices {
            let limit = i+1 < captions.count ? captions[i+1].start-0.04 : captions[i].start+o.minDuration
            if captions[i].end-captions[i].start < o.minDuration { captions[i].end = max(captions[i].end,min(limit,captions[i].start+o.minDuration)) }
            if i+1 < captions.count, captions[i].end > captions[i+1].start { captions[i].end = max(captions[i].start+0.1,captions[i+1].start-0.01) }
        }
        return captions.filter { $0.end > $0.start }
    }
    static func joined(_ words: [RecognizedWord]) -> String {
        var text = ""
        for w in words {
            let piece = w.text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let attach = piece.first.map { ".,?!…:;)]}%。、，？！".contains($0) } ?? false
            text += (text.isEmpty || attach) ? piece : " "+piece
        }
        return text
    }
    // Splits into up to `maxLines` lines of similar length at spaces.
    static func wrap(_ text: String, lineChars: Int, maxLines: Int) -> String {
        guard text.count > lineChars, maxLines > 1 else { return text }
        let words = text.split(separator:" ").map(String.init)
        guard words.count > 1 else { return text }
        let lines = min(maxLines,Int(ceil(Double(text.count)/Double(lineChars))))
        let target = Double(text.count)/Double(lines)
        var result: [String] = []; var line = ""
        for w in words {
            if !line.isEmpty, Double((line+" "+w).count) > target+Double(lineChars)*0.25, result.count < lines-1 { result.append(line); line = w }
            else { line = line.isEmpty ? w : line+" "+w }
        }
        if !line.isEmpty { result.append(line) }
        return result.joined(separator:"\n")
    }
    static func removeHallucinations(_ captions: [Caption]) -> [Caption] {
        var result: [Caption] = []
        for c in captions {
            let flat = c.text.replacingOccurrences(of:"\n",with:" ").trimmingCharacters(in:.whitespaces)
            let lowered = flat.lowercased()
            if hallucinations.contains(where:{ lowered.contains($0.lowercased()) }) && (c.confidence ?? 0) < 0.8 { continue }
            // Decoder loops repeat the same line; keep the first.
            if let last = result.last, last.text.replacingOccurrences(of:"\n",with:" ") == flat, c.start-last.end < 1.5 { result[result.count-1].end = c.end; continue }
            result.append(c)
        }
        return result
    }
}
