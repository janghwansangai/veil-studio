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
        return warnings.isEmpty ? "자막 \(count)개 생성 완료 · 내용을 검토하세요" : "자막 \(count)개 생성 · 검토할 구간 \(warnings.count)개"
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
        let valid = chunk.captions.map { Caption(start:max(offset,$0.start+offset),end:min(duration,offset+length,$0.end+offset),text:$0.text) }.filter { $0.end > $0.start && !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        report.captions += valid
        if let warning = chunk.warning { report.warnings.append("\(timecode(offset))–\(timecode(min(duration,offset+length))): \(warning)") }
        else if valid.isEmpty { report.warnings.append("\(timecode(offset))–\(timecode(min(duration,offset+length))): 인식된 말소리 없음") }
    }
}

enum SpeechEngine: String, CaseIterable { case whisper = "Whisper · 기기 내", apple = "Apple · 기기 내" }
struct SpeechOptions {
    var engine: SpeechEngine = WhisperTranscription.executable == nil ? .apple : .whisper
    var whisperModelPath = ""
    var chunkSeconds = 20.0
    var gain = 1.0
    var hints = ""
    var audioTrack = 0
    var chunkLength: Double { chunkSeconds.isFinite ? min(45,max(5,chunkSeconds)) : 20 }
    var amplification: Float { Float(gain.isFinite ? min(4,max(0.25,gain)) : 1) }
    var contextualWords: [String] { Array(hints.components(separatedBy:CharacterSet(charactersIn:",\n")).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(50)) }
}
