import Foundation
import CoreGraphics

struct NormalRect: Codable, Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    func scaled(to size: CGSize) -> CGRect { CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height) }
    func expanded(_ margin: Double) -> NormalRect { NormalRect(cg.insetBy(dx: -width * margin / 2, dy: -height * margin / 2).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))) }
    static func interpolate(_ a: NormalRect, _ b: NormalRect, _ t: Double) -> NormalRect {
        NormalRect(x: a.x + (b.x-a.x)*t, y: a.y + (b.y-a.y)*t, width: a.width + (b.width-a.width)*t, height: a.height + (b.height-a.height)*t)
    }
}
struct FaceSample: Codable, Equatable { var time: Double; var rect: NormalRect }
struct FaceTrack: Identifiable, Codable, Equatable {
    var id = UUID(); var name: String; var selected = true; var thumbnail: Data?; var samples: [FaceSample]
    // Binary search keeps preview/export independent of source duration.
    func rect(at time: Double, still: Bool = false, tolerance: Double = 0.12) -> NormalRect? {
        guard !samples.isEmpty else { return nil }
        if still { return samples.first?.rect }
        var low = 0; var high = samples.count
        while low < high { let mid = (low + high) / 2; if samples[mid].time < time { low = mid + 1 } else { high = mid } }
        let next = low < samples.count ? samples[low] : nil
        let prev = low > 0 ? samples[low - 1] : nil
        if let a = prev, let b = next, b.time - a.time <= tolerance * 2, b.time > a.time {
            return .interpolate(a.rect, b.rect, (time - a.time) / (b.time - a.time))
        }
        if let b = next, abs(b.time - time) <= tolerance { return b.rect }
        if let a = prev, abs(a.time - time) <= tolerance { return a.rect }
        return nil
    }
}
enum MaskEffect: String, Codable, CaseIterable { case pixel = "모자이크", blur = "블러", solid = "단색", sticker = "스티커" }
enum MaskShape: String, Codable, CaseIterable { case oval = "타원", rectangle = "사각형", rounded = "둥근 사각형", heart = "하트", star = "별" }
struct MaskDesign: Codable, Equatable {
    var effect: MaskEffect = .pixel; var shape: MaskShape = .oval
    var strength = 0.65; var margin = 0.35; var red = 0.30; var green = 0.33; var blue = 0.94
    var sticker = "🙂"
}
struct RegionKeyframe: Codable, Equatable, Identifiable { var id = UUID(); var time: Double; var rect: NormalRect }
struct ManualRegion: Identifiable, Codable, Equatable {
    var id = UUID(); var name: String; var enabled = true; var start: Double; var end: Double; var rect: NormalRect
    var lane: Int?
    var keyframes: [RegionKeyframe] = []
    func rect(at time: Double) -> NormalRect {
        let sorted = keyframes.sorted { $0.time < $1.time }
        guard let first = sorted.first else { return rect }
        if time <= first.time { return first.rect }
        for (a,b) in zip(sorted, sorted.dropFirst()) where time <= b.time {
            return .interpolate(a.rect, b.rect, (time-a.time)/max(0.001,b.time-a.time))
        }
        return sorted.last!.rect
    }
}
struct Caption: Identifiable, Codable, Equatable { var id = UUID(); var start: Double; var end: Double; var text: String; var lane: Int?; var horizontal: Double?; var vertical: Double?; var boxWidth: Double? }
struct Clip: Identifiable, Codable, Equatable { var id = UUID(); var start: Double; var end: Double; var lane: Int?; var position: Double?; var duration: Double { max(0,end-start) } }
enum CropRatio: String, Codable, CaseIterable {
    case original = "원본", wide = "16:9", portrait = "9:16", square = "1:1", classic = "4:3"
    var value: Double? { switch self { case .original: return nil; case .wide: return 16/9; case .portrait: return 9/16; case .square: return 1; case .classic: return 4/3 } }
}
enum OutputResolution: String, Codable, CaseIterable {
    case original = "원본 크기", uhd = "4K · 2160p", fullHD = "Full HD · 1080p", hd = "HD · 720p"
    var edge: Double? { switch self { case .original:return nil; case .uhd:return 3840; case .fullHD:return 1920; case .hd:return 1280 } }
}
enum ImageOutput: String, Codable, CaseIterable { case png, jpeg = "jpg", tiff, heic
    var typeIdentifier: String { switch self { case .png:return "public.png"; case .jpeg:return "public.jpeg"; case .tiff:return "public.tiff"; case .heic:return "public.heic" } }
}
enum VideoOutput: String, Codable, CaseIterable { case mp4, mov }
struct ExportOptions: Codable, Equatable {
    var ratio: CropRatio = .original; var resolution: OutputResolution = .fullHD; var cropX = 0.5; var cropY = 0.5
    var hevc = false; var muted = false; var burnCaptions = true; var captionSize = 0.045; var jpeg = false
    var imageFormat: ImageOutput?
    var videoFormat: VideoOutput?
    var resolvedImageFormat: ImageOutput { imageFormat ?? (jpeg ? .jpeg : .png) }
    var fileExtension: String { (videoFormat ?? .mp4).rawValue }
    func cropRect(_ size: CGSize) -> CGRect {
        guard let ratio = ratio.value else { return CGRect(origin: .zero, size: size) }
        let width = min(size.width, size.height * ratio); let height = min(size.height, size.width / ratio)
        return CGRect(x: (size.width - width) * cropX, y: (size.height - height) * cropY, width: width, height: height)
    }
    func outputSize(_ size: CGSize, even: Bool = true) -> CGSize {
        let crop = cropRect(size); let factor = min(1, (resolution.edge ?? max(crop.width,crop.height)) / max(crop.width,crop.height))
        let step = even ? 2.0 : 1.0
        return CGSize(width: max(step, floor(crop.width * factor / step) * step), height: max(step, floor(crop.height * factor / step) * step))
    }
}
struct Project: Codable, Equatable {
    var version = 1; var sourcePath = ""; var fileSize: Int64 = 0; var modified: Date?; var isImage = false
    var duration = 0.0; var width = 0.0; var height = 0.0; var fps = 30.0
    var overlaysOnTimeline: Bool?
    var videoLaneCount: Int?; var regionLaneCount: Int?; var captionLaneCount: Int?
    var faces: [FaceTrack] = []; var regions: [ManualRegion] = []; var captions: [Caption] = []; var clips: [Clip] = []
    // Legacy design is retained for existing project files.
    var design = MaskDesign()
    var faceDesign: MaskDesign?
    var regionDesign: MaskDesign?
    var effectiveFaceDesign: MaskDesign { get { faceDesign ?? design } set { faceDesign = newValue } }
    var effectiveRegionDesign: MaskDesign { get { regionDesign ?? design } set { regionDesign = newValue } }
    var exportRange: TimelineRange?
    var export = ExportOptions(); var maskApplied = false; var analysisComplete = false
    var size: CGSize { CGSize(width: width, height: height) }
    var editedDuration: Double { timeline.map(\.end).max() ?? 0 }
    func sourceTime(for output: Double) -> Double {
        if let entry = visibleTimeline.first(where:{output >= $0.start && output < $0.end}) { return entry.clip.start+output-entry.start }
        if output >= editedDuration { return visibleTimeline.last?.clip.end ?? output }
        return -1

    }
    func outputCaptions(respectExportRange: Bool = true) -> [Caption] {
        if overlaysOnTimeline == true {
            let range = respectExportRange ? (exportRange ?? TimelineRange(start:0,end:editedDuration)) : TimelineRange(start:0,end:editedDuration)
            return captions.compactMap { c in
                let a = max(range.start,c.start), b = min(range.end,c.end)
                guard b > a else { return nil }; var result = c; result.start = a-range.start; result.end = b-range.start; return result
            }.sorted { $0.start < $1.start }
        }
        var result: [Caption] = []; var offset = 0.0
        for entry in (respectExportRange ? projectForExport.visibleTimeline : visibleTimeline) {
            let clip = entry.clip; offset = entry.start
            for c in captions { let start = max(c.start, clip.start); let end = min(c.end, clip.end)
                if end > start { var v = c; v.id = UUID(); v.start = offset+start-clip.start; v.end = offset+end-clip.start; result.append(v) }
            }; offset += clip.duration
        }
        return result.sorted { $0.start < $1.start }
    }
    // Vision can return valid detections partly beyond the image boundary.
    // Repair only finite, positive rectangles that overlap the visible frame.
    @discardableResult mutating func repairFaceBounds() throws -> Int {
        var count = 0
        for i in faces.indices {
            for j in faces[i].samples.indices {
                let rect = faces[i].samples[j].rect
                guard let clipped = rect.clippedToImage else { throw StudioError.message("얼굴 분석 좌표가 손상되었습니다: \(faces[i].name), \(timecode(faces[i].samples[j].time)). 이 후보를 다시 분석해 주세요.") }
                if clipped != rect { faces[i].samples[j].rect = clipped; count += 1 }
            }
        }
        return count
    }
    func validate() throws {
        guard version == 1, width.isFinite, height.isFinite, width > 0, height > 0, width * height <= 120_000_000,
              duration.isFinite, duration >= 0, fps.isFinite, fps > 0 else { throw StudioError.message("올바른 프로젝트 파일이 아닙니다.") }
        guard Set(clips.map(\.id)).count == clips.count else { throw StudioError.message("컷 식별자가 중복되었습니다.") }
        guard [videoLaneCount,regionLaneCount,captionLaneCount].allSatisfy({ $0 == nil || (1...64).contains($0!) }),
              clips.allSatisfy({ ($0.lane ?? 0) >= 0 && ($0.lane ?? 0) < 64 && ($0.position == nil || ($0.position!.isFinite && $0.position! >= 0)) }),
              regions.allSatisfy({ (0..<64).contains($0.lane ?? 0) }), captions.allSatisfy({ (0..<64).contains($0.lane ?? 0) }) else { throw StudioError.message("트랙 번호 또는 영상 배치 시간이 잘못되었습니다.") }
        for clip in clips {
            guard clip.start.isFinite, clip.end.isFinite, clip.start >= 0, clip.end <= duration + 0.01, clip.duration > 0 else { throw StudioError.message("각 컷의 시작·끝은 원본 범위 안에 있어야 합니다.") }
        }
        if let range = exportRange {
            guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end <= editedDuration+0.000001, range.end > range.start else { throw StudioError.message("내보내기 구간이 편집 타임라인 범위를 벗어났습니다.") }
        }
        for f in faces {
            var previous = -Double.infinity
            for sample in f.samples { guard sample.time.isFinite, sample.time >= 0, sample.time <= duration + 0.1, sample.time >= previous, sample.rect.valid else { throw StudioError.message("얼굴 분석 데이터가 손상되었습니다.") }; previous = sample.time }
        }
        for r in regions { guard r.rect.valid, r.start.isFinite, r.end.isFinite, r.start >= 0, r.end >= r.start, (overlaysOnTimeline == true || r.end <= duration + 0.01), r.keyframes.allSatisfy({ $0.time.isFinite && $0.time >= 0 && (overlaysOnTimeline == true || $0.time <= duration) && $0.rect.valid }) else { throw StudioError.message("영역 마스크 데이터가 손상되었습니다.") } }
        guard captions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }),
              [design.strength,design.margin,design.red,design.green,design.blue,export.cropX,export.cropY,export.captionSize].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 2 }) else { throw StudioError.message("편집 설정이 손상되었습니다.") }
        for mask in [effectiveFaceDesign,effectiveRegionDesign] {
            guard [mask.strength,mask.margin,mask.red,mask.green,mask.blue].allSatisfy(\.isFinite),
                  (0...1).contains(mask.strength), (0...1.5).contains(mask.margin),
                  [mask.red,mask.green,mask.blue].allSatisfy({ (0...1).contains($0) }) else { throw StudioError.message("마스크 디자인 설정이 허용 범위를 벗어났습니다.") }
        }
        guard (0...1).contains(design.strength), (0...1.5).contains(design.margin),
              [design.red,design.green,design.blue,export.cropX,export.cropY].allSatisfy({ (0...1).contains($0) }),
              (0.01...0.2).contains(export.captionSize) else { throw StudioError.message("마스크·크롭 설정이 허용 범위를 벗어났습니다.") }
    }
}
extension NormalRect {
    var clippedToImage: NormalRect? {
        guard [x,y,width,height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        if x >= 0, y >= 0, x+width <= 1, y+height <= 1 { return self }
        let clipped = cg.intersection(CGRect(x:0,y:0,width:1,height:1))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return NormalRect(clipped)
    }
    var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x+width <= 1.001 && y+height <= 1.001 } }
enum StudioError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let s) = self { return s }; return nil } }
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func check() throws { if cancelled { throw CancellationError() } }
}
func timecode(_ seconds: Double) -> String { guard seconds.isFinite else { return "00:00.0" }; let s = max(0,seconds); return String(format:"%02d:%04.1f", Int(s)/60,s.truncatingRemainder(dividingBy:60)) }
enum Subtitles {
    static func timestamp(_ time: Double) -> String { let ms = Int((max(0,time)*1000).rounded()); return String(format:"%02d:%02d:%02d,%03d",ms/3600000,(ms/60000)%60,(ms/1000)%60,ms%1000) }
    static func srt(_ captions: [Caption]) -> String { captions.enumerated().map { "\($0.offset+1)\n\(timestamp($0.element.start)) --> \(timestamp($0.element.end))\n\($0.element.text)\n" }.joined(separator:"\n") }
    static func parse(_ text: String) -> [Caption] {
        let normalized = text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        func seconds(_ s: String) -> Double? {
            let clean = s.trimmingCharacters(in:.whitespaces).split(separator:" ").first.map(String.init) ?? ""
            let p = clean.replacingOccurrences(of:",",with:".").split(separator:":").compactMap { Double($0) }
            if p.count == 3 { return p[0]*3600+p[1]*60+p[2] }; if p.count == 2 { return p[0]*60+p[1] }; return nil
        }
        return normalized.components(separatedBy:"\n\n").compactMap { block in
            let lines = block.components(separatedBy:"\n"); guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[i].components(separatedBy:"-->"); guard times.count == 2, let a = seconds(times[0]), let b = seconds(times[1]), b > a, a >= 0 else { return nil }
            let content = lines.dropFirst(i+1).joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
            return content.isEmpty ? nil : Caption(start:a,end:b,text:content)
        }.sorted { $0.start < $1.start }
    }
}
