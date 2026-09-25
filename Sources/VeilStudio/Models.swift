import Foundation
import CoreGraphics

struct NormalRect: Codable, Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var center: CGPoint { CGPoint(x: x + width/2, y: y + height/2) }
    func scaled(to size: CGSize) -> CGRect { CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height) }
    func expanded(_ margin: Double) -> NormalRect { NormalRect(cg.insetBy(dx: -width * margin / 2, dy: -height * margin / 2).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))) }
    static func interpolate(_ a: NormalRect, _ b: NormalRect, _ t: Double) -> NormalRect {
        NormalRect(x: a.x + (b.x-a.x)*t, y: a.y + (b.y-a.y)*t, width: a.width + (b.width-a.width)*t, height: a.height + (b.height-a.height)*t)
    }
}
// predicted: the box came from motion tracking or gap filling, not a direct detection.
struct FaceSample: Equatable { var time: Double; var rect: NormalRect; var predicted = false }
struct FaceTrack: Identifiable, Equatable {
    var id = UUID(); var name: String; var selected = true; var thumbnail: Data?; var samples: [FaceSample]
    var group: UUID?     // fragments of the same person share a group
    var groupID: UUID { group ?? id }
    // Binary search keeps preview/export independent of source duration.
    // bridge: interpolate across detection gaps up to this many seconds (missed frames stay covered).
    // hold: keep the first/last box on screen this long before/after the track so entries and exits stay masked.
    func rect(at time: Double, still: Bool = false, tolerance: Double = 0.12, bridge: Double = 0, hold: Double = 0) -> NormalRect? {
        guard !samples.isEmpty else { return nil }
        if still { return samples.first?.rect }
        var low = 0; var high = samples.count
        while low < high { let mid = (low + high) / 2; if samples[mid].time < time { low = mid + 1 } else { high = mid } }
        let next = low < samples.count ? samples[low] : nil
        let prev = low > 0 ? samples[low - 1] : nil
        if let a = prev, let b = next, b.time > a.time {
            let gap = b.time - a.time
            // Long gaps are bridged only when the face is still near the same place, so a
            // mask never sweeps across the frame between two appearances.
            let near = FaceAssociation.distance(a.rect, b.rect) <= 2.5
            if gap <= tolerance * 2 || (gap <= bridge && near) { return .interpolate(a.rect, b.rect, (time - a.time) / gap) }
        }
        let edge = max(tolerance, hold)
        if let b = next, abs(b.time - time) <= (prev == nil ? edge : tolerance) { return b.rect }
        if let a = prev, abs(a.time - time) <= (next == nil ? edge : tolerance) { return a.rect }
        return nil
    }
    var detectedCount: Int { samples.reduce(0) { $0 + ($1.predicted ? 0 : 1) } }
    var span: TimelineRange? { samples.first.map { TimelineRange(start: $0.time, end: samples.last?.time ?? $0.time) } }
}
// Face samples are stored packed (time,x,y,w,h as little-endian Float64) to keep
// long projects small and fast to autosave. The legacy array form is still read.
extension FaceTrack: Codable {
    private enum Keys: String, CodingKey { case id, name, selected, thumbnail, samples, packed, predicted, group }
    private struct LegacySample: Codable { var time: Double; var rect: NormalRect }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.value(.id, UUID()); name = try c.value(.name, "인물 후보"); selected = try c.value(.selected, true)
        thumbnail = try c.decodeIfPresent(Data.self, forKey: .thumbnail); group = try c.decodeIfPresent(UUID.self, forKey: .group)
        if let packed = try c.decodeIfPresent(Data.self, forKey: .packed) {
            guard packed.count % 40 == 0 else { throw StudioError.message("얼굴 분석 데이터가 손상되었습니다.") }
            let flags = try c.decodeIfPresent(Data.self, forKey: .predicted) ?? Data()
            var values = [Double](repeating: 0, count: packed.count / 8)
            _ = values.withUnsafeMutableBytes { packed.copyBytes(to: $0) }
            samples = stride(from: 0, to: values.count, by: 5).map { i in
                let n = i / 5; let flagged = n / 8 < flags.count && flags[n / 8] & (1 << UInt8(n % 8)) != 0
                return FaceSample(time: Double(bitPattern: UInt64(littleEndian: values[i].bitPattern)),
                                  rect: NormalRect(x: Double(bitPattern: UInt64(littleEndian: values[i+1].bitPattern)), y: Double(bitPattern: UInt64(littleEndian: values[i+2].bitPattern)),
                                                   width: Double(bitPattern: UInt64(littleEndian: values[i+3].bitPattern)), height: Double(bitPattern: UInt64(littleEndian: values[i+4].bitPattern))),
                                  predicted: flagged)
            }
        } else {
            samples = try c.value(.samples, [LegacySample]()).map { FaceSample(time: $0.time, rect: $0.rect) }
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(selected, forKey: .selected)
        try c.encodeIfPresent(thumbnail, forKey: .thumbnail); try c.encodeIfPresent(group, forKey: .group)
        var values: [Double] = []; values.reserveCapacity(samples.count * 5)
        var flags = Data(count: (samples.count + 7) / 8)
        for (n, s) in samples.enumerated() {
            for v in [s.time, s.rect.x, s.rect.y, s.rect.width, s.rect.height] { values.append(Double(bitPattern: v.bitPattern.littleEndian)) }
            if s.predicted { flags[n / 8] |= 1 << UInt8(n % 8) }
        }
        try c.encode(values.withUnsafeBytes { Data($0) }, forKey: .packed)
        if samples.contains(where: \.predicted) { try c.encode(flags, forKey: .predicted) }
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
        guard let first = sorted.first, let last = sorted.last else { return rect }
        if time <= first.time { return first.rect }
        for (a,b) in zip(sorted, sorted.dropFirst()) where time <= b.time {
            return .interpolate(a.rect, b.rect, (time-a.time)/max(0.001,b.time-a.time))
        }
        return last.rect
    }
}
struct Caption: Identifiable, Codable, Equatable {
    var id = UUID(); var start: Double; var end: Double; var text: String; var lane: Int?; var horizontal: Double?; var vertical: Double?; var boxWidth: Double?
    // Recognition confidence 0...1 when known; low values are shown for review.
    var confidence: Double?
}

// MARK: - Clip editing properties (v2)

enum TransitionKind: String, Codable, CaseIterable { case dissolve = "크로스 디졸브", dipToBlack = "검은 화면 전환", wipe = "와이프", slide = "슬라이드" }
struct Transition: Codable, Equatable { var kind: TransitionKind = .dissolve; var duration = 0.5 }
struct ClipTransform: Codable, Equatable {
    var scale = 1.0; var x = 0.0; var y = 0.0; var rotation = 0.0; var opacity = 1.0
    var cropLeft = 0.0; var cropRight = 0.0; var cropTop = 0.0; var cropBottom = 0.0
    var fill = false
    var isIdentity: Bool { self == ClipTransform() }
}
struct ColorAdjust: Codable, Equatable {
    var exposure = 0.0; var brightness = 0.0; var contrast = 1.0; var saturation = 1.0; var temperature = 0.0; var tint = 0.0
    var isIdentity: Bool { self == ColorAdjust() }
}
struct Clip: Identifiable, Codable, Equatable {
    var id = UUID(); var start: Double; var end: Double; var lane: Int?; var position: Double?
    var source: UUID?          // nil: the project's first media item
    var speed: Double?         // playback rate, nil = 1
    var freeze: Double?        // freeze-frame length on the timeline
    var volume: Double?        // linear gain, nil = 1
    var audioMuted: Bool?
    var audioFadeIn: Double?; var audioFadeOut: Double?
    var videoFadeIn: Double?; var videoFadeOut: Double?
    var transition: Transition?
    var transform: ClipTransform?
    var color: ColorAdjust?
    var duration: Double { max(0,end-start) }   // source length
    var rate: Double { freeze != nil ? 0 : min(Clip.maxSpeed,max(Clip.minSpeed,speed ?? 1)) }
    var timelineDuration: Double { if let freeze { return max(0,freeze) }; return duration/max(Clip.minSpeed,rate) }
    func sourceTime(offset: Double) -> Double { freeze != nil ? start : min(end,max(start,start+offset*rate)) }
    func offset(forSource time: Double) -> Double { freeze != nil ? 0 : (time-start)/max(Clip.minSpeed,rate) }
    var gain: Double { audioMuted == true ? 0 : min(4,max(0,volume ?? 1)) }
    static let minSpeed = 0.1, maxSpeed = 16.0
    // Copies keep the look and sound of the clip but never its placement or transition.
    func duplicate() -> Clip { var c = self; c.id = UUID(); c.lane = nil; c.position = nil; c.transition = nil; return c }
}
struct AudioClip: Identifiable, Codable, Equatable {
    var id = UUID(); var source: UUID; var start: Double; var end: Double; var position: Double; var lane = 0
    var volume = 1.0; var fadeIn = 0.0; var fadeOut = 0.0; var muted = false
    var duration: Double { max(0,end-start) }
    var timelineEnd: Double { position+duration }
    var gain: Double { muted ? 0 : min(4,max(0,volume)) }
}
struct TitleItem: Identifiable, Codable, Equatable {
    var id = UUID(); var text = "제목"; var start: Double; var end: Double; var lane: Int?
    var x = 0.5; var y = 0.5; var size = 0.08
    var red = 1.0; var green = 1.0; var blue = 1.0
    var bold = true; var background = false; var fadeIn = 0.3; var fadeOut = 0.3
    func opacity(at time: Double) -> Double {
        guard time >= start, time < end else { return 0 }
        var value = 1.0
        if fadeIn > 0 { value = min(value,(time-start)/fadeIn) }
        if fadeOut > 0 { value = min(value,(end-time)/fadeOut) }
        return max(0,min(1,value))
    }
}
struct Marker: Identifiable, Codable, Equatable { var id = UUID(); var time: Double; var name = "마커" }

// MARK: - Media sources (v2)

enum MediaKind: String, Codable { case video, image, audio }
enum FaceAnalysisMode: String, Codable, CaseIterable {
    case fast = "빠름", standard = "표준", precise = "정밀 · 작은 얼굴"
    var detail: String {
        switch self {
        case .fast: return "2프레임마다 검출하고 사이는 추적으로 보완 · 가장 빠름 · 큰 얼굴 위주"
        case .standard: return "모든 프레임 검출 · 가까운 얼굴 위주 · 실시간의 약 5배 속도"
        case .precise: return "모든 프레임 + 화면 4분할 정밀 검출 · 멀리 있는 작은 얼굴까지 · 실시간의 약 2배 속도 (권장)"
        }
    }
}
struct SourceTranscript: Codable, Equatable { var engine: String; var language: String; var ranges: [TimelineRange]; var captions: [Caption] }
struct MediaSource: Identifiable, Equatable {
    var id = UUID(); var path = ""; var fileSize: Int64 = 0; var modified: Date?
    var kind: MediaKind = .video
    var duration = 0.0; var width = 0.0; var height = 0.0; var fps = 30.0; var hasAudio = true
    var faces: [FaceTrack] = []
    var analysisComplete = false; var maskApplied = false
    var analyzedRanges: [TimelineRange] = []
    var reviewRanges: [TimelineRange] = []      // source-time spans that may hide missed faces
    var transcript: SourceTranscript?
    var name: String { path.isEmpty ? "미디어" : URL(fileURLWithPath:path).lastPathComponent }
    var isImage: Bool { kind == .image }
    var isVisual: Bool { kind != .audio }
    var size: CGSize { CGSize(width:width,height:height) }
}
extension MediaSource: Codable {
    private enum Keys: String, CodingKey { case id, path, fileSize, modified, kind, duration, width, height, fps, hasAudio, faces, analysisComplete, maskApplied, analyzedRanges, reviewRanges, transcript }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:Keys.self)
        id = try c.value(.id,UUID()); path = try c.value(.path,""); fileSize = try c.value(.fileSize,0); modified = try c.decodeIfPresent(Date.self,forKey:.modified)
        kind = try c.value(.kind,.video); duration = try c.value(.duration,0); width = try c.value(.width,0); height = try c.value(.height,0); fps = try c.value(.fps,30); hasAudio = try c.value(.hasAudio,true)
        faces = try c.value(.faces,[]); analysisComplete = try c.value(.analysisComplete,false); maskApplied = try c.value(.maskApplied,false)
        analyzedRanges = try c.value(.analyzedRanges,[]); reviewRanges = try c.value(.reviewRanges,[]); transcript = try c.decodeIfPresent(SourceTranscript.self,forKey:.transcript)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy:Keys.self)
        try c.encode(id,forKey:.id); try c.encode(path,forKey:.path); try c.encode(fileSize,forKey:.fileSize); try c.encodeIfPresent(modified,forKey:.modified)
        try c.encode(kind,forKey:.kind); try c.encode(duration,forKey:.duration); try c.encode(width,forKey:.width); try c.encode(height,forKey:.height); try c.encode(fps,forKey:.fps); try c.encode(hasAudio,forKey:.hasAudio)
        try c.encode(faces,forKey:.faces); try c.encode(analysisComplete,forKey:.analysisComplete); try c.encode(maskApplied,forKey:.maskApplied)
        try c.encode(analyzedRanges,forKey:.analyzedRanges); try c.encode(reviewRanges,forKey:.reviewRanges); try c.encodeIfPresent(transcript,forKey:.transcript)
    }
}

// MARK: - Batch face-masking queue

enum BatchMode: String, Codable, CaseIterable { case review = "검토 후 출력", automatic = "자동 출력" }
enum BatchState: String, Codable {
    case queued = "대기", analyzing = "분석 중", review = "검토 대기", approved = "출력 대기", exporting = "내보내는 중", done = "완료", failed = "실패", cancelled = "취소됨"
    var finished: Bool { self == .done || self == .failed || self == .cancelled }
}
struct BatchJob: Identifiable, Codable, Equatable {
    var id = UUID(); var source: UUID; var mode: BatchMode = .review; var state: BatchState = .queued
    var message = ""; var output: String?; var progress = 0.0
}
struct BatchSettings: Codable, Equatable {
    var folder = ""; var suffix = "_마스킹"; var analysis: FaceAnalysisMode = .precise
    var videoFormat: VideoOutput = .mp4; var hevc = false; var resolution: OutputResolution = .original
}

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
        let crop = cropRect(size); let factor = min(1, (resolution.edge ?? max(crop.width,crop.height)) / max(1,max(crop.width,crop.height)))
        let step = even ? 2.0 : 1.0
        return CGSize(width: max(step, floor(crop.width * factor / step) * step), height: max(step, floor(crop.height * factor / step) * step))
    }
}

// MARK: - Project

struct Project: Equatable {
    static let currentVersion = 2
    var version = Project.currentVersion
    var media: [MediaSource] = []
    // isImage: single-photo project without a timeline. width/height/fps: the canvas.
    var isImage = false
    var width = 0.0; var height = 0.0; var fps = 30.0
    var overlaysOnTimeline: Bool?
    var videoLaneCount: Int?; var regionLaneCount: Int?; var captionLaneCount: Int?; var audioLaneCount: Int?; var titleLaneCount: Int?
    var regions: [ManualRegion] = []; var captions: [Caption] = []; var clips: [Clip] = []
    var audioClips: [AudioClip] = []; var titles: [TitleItem] = []; var markers: [Marker] = []
    // Legacy design is retained for existing project files.
    var design = MaskDesign()
    var faceDesign: MaskDesign?
    var regionDesign: MaskDesign?
    // Seconds of missed detections bridged by interpolation, and entry/exit hold time.
    var faceBridge = 1.0; var faceHold = 0.25
    var exportRange: TimelineRange?
    var export = ExportOptions()
    var queue: [BatchJob] = []
    var batch = BatchSettings()
    var effectiveFaceDesign: MaskDesign { get { faceDesign ?? design } set { faceDesign = newValue } }
    var effectiveRegionDesign: MaskDesign { get { regionDesign ?? design } set { regionDesign = newValue } }
    var size: CGSize { CGSize(width: width, height: height) }

    // MARK: First-media accessors. Single-source code paths and v1 files address the first media item.
    private mutating func ensurePrimary() { if media.isEmpty { media.append(MediaSource()) } }
    var primary: MediaSource? { media.first }
    var sourcePath: String { get { media.first?.path ?? "" } set { ensurePrimary(); media[0].path = newValue } }
    var fileSize: Int64 { get { media.first?.fileSize ?? 0 } set { ensurePrimary(); media[0].fileSize = newValue } }
    var modified: Date? { get { media.first?.modified } set { ensurePrimary(); media[0].modified = newValue } }
    var duration: Double { get { media.first?.duration ?? 0 } set { ensurePrimary(); media[0].duration = newValue } }
    var faces: [FaceTrack] { get { media.first?.faces ?? [] } set { ensurePrimary(); media[0].faces = newValue } }
    var analysisComplete: Bool { get { media.first?.analysisComplete ?? false } set { ensurePrimary(); media[0].analysisComplete = newValue } }
    var maskApplied: Bool { get { media.first?.maskApplied ?? false } set { ensurePrimary(); media[0].maskApplied = newValue } }

    func source(_ id: UUID?) -> MediaSource? { id.flatMap { i in media.first { $0.id == i } } ?? media.first }
    func sourceIndex(_ id: UUID?) -> Int? { id.flatMap { i in media.firstIndex { $0.id == i } } ?? (media.isEmpty ? nil : 0) }
    func sourceID(of clip: Clip) -> UUID? { clip.source ?? media.first?.id }
    var allFaces: [FaceTrack] { media.flatMap(\.faces) }

    var editedDuration: Double { max(timeline.map(\.end).max() ?? 0,audioClips.map(\.timelineEnd).max() ?? 0) }
    func sourceTime(for output: Double) -> Double {
        if let entry = visibleTimeline.first(where:{output >= $0.start && output < $0.end}) { return entry.clip.sourceTime(offset:output-entry.start) }
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
        // Legacy source-time captions: place each caption under every cut that shows it.
        var result: [Caption] = []
        for entry in (respectExportRange ? projectForExport.visibleTimeline : visibleTimeline) {
            let clip = entry.clip
            for c in captions { let start = max(c.start, clip.start); let end = min(c.end, clip.end)
                if end > start { var v = c; v.id = UUID(); v.start = entry.start+clip.offset(forSource:start); v.end = entry.start+clip.offset(forSource:end); result.append(v) }
            }
        }
        return result.sorted { $0.start < $1.start }
    }
    // Vision can return valid detections partly beyond the image boundary.
    // Repair only finite, positive rectangles that overlap the visible frame.
    @discardableResult mutating func repairFaceBounds() throws -> Int {
        var count = 0
        for m in media.indices {
            for i in media[m].faces.indices {
                for j in media[m].faces[i].samples.indices {
                    let rect = media[m].faces[i].samples[j].rect
                    guard let clipped = rect.clippedToImage else { throw StudioError.message("얼굴 분석 좌표가 손상되었습니다: \(media[m].faces[i].name), \(timecode(media[m].faces[i].samples[j].time)). 이 후보를 다시 분석해 주세요.") }
                    if clipped != rect { media[m].faces[i].samples[j].rect = clipped; count += 1 }
                }
            }
        }
        return count
    }
    func validate() throws {
        guard version == Project.currentVersion, width.isFinite, height.isFinite, width > 0, height > 0, width * height <= 120_000_000,
              fps.isFinite, fps > 0, fps <= 240 else { throw StudioError.message("올바른 프로젝트 파일이 아닙니다.") }
        guard Set(media.map(\.id)).count == media.count, Set(clips.map(\.id)).count == clips.count else { throw StudioError.message("미디어 또는 컷 식별자가 중복되었습니다.") }
        for m in media {
            guard m.duration.isFinite, m.duration >= 0, m.width.isFinite, m.height.isFinite, m.width >= 0, m.height >= 0, m.width*m.height <= 120_000_000,
                  m.fps.isFinite, m.fps > 0 else { throw StudioError.message("미디어 정보가 손상되었습니다: \(m.name)") }
            for f in m.faces {
                var previous = -Double.infinity
                for sample in f.samples { guard sample.time.isFinite, sample.time >= 0, sample.time <= m.duration + 0.1, sample.time >= previous, sample.rect.valid else { throw StudioError.message("얼굴 분석 데이터가 손상되었습니다: \(m.name)") }; previous = sample.time }
            }
        }
        guard [videoLaneCount,regionLaneCount,captionLaneCount,audioLaneCount,titleLaneCount].allSatisfy({ $0 == nil || (1...64).contains($0!) }),
              clips.allSatisfy({ ($0.lane ?? 0) >= 0 && ($0.lane ?? 0) < 64 && ($0.position == nil || ($0.position!.isFinite && $0.position! >= 0)) }),
              regions.allSatisfy({ (0..<64).contains($0.lane ?? 0) }), captions.allSatisfy({ (0..<64).contains($0.lane ?? 0) }),
              titles.allSatisfy({ (0..<64).contains($0.lane ?? 0) }), audioClips.allSatisfy({ (0..<64).contains($0.lane) }) else { throw StudioError.message("트랙 번호 또는 영상 배치 시간이 잘못되었습니다.") }
        for clip in clips {
            guard let source = source(clip.source), clip.source == nil || source.id == clip.source, source.kind != .audio else { throw StudioError.message("컷이 가리키는 미디어가 프로젝트에 없습니다.") }
            let limit = source.isImage ? max(source.duration,clip.end) : source.duration
            guard clip.start.isFinite, clip.end.isFinite, clip.start >= 0, clip.end <= limit + 0.01, clip.duration > 0 else { throw StudioError.message("각 컷의 시작·끝은 원본 범위 안에 있어야 합니다.") }
            guard [clip.speed,clip.freeze,clip.volume,clip.audioFadeIn,clip.audioFadeOut,clip.videoFadeIn,clip.videoFadeOut].allSatisfy({ $0 == nil || ($0!.isFinite && $0! >= 0) }),
                  (clip.speed ?? 1) >= Clip.minSpeed, (clip.speed ?? 1) <= Clip.maxSpeed, (clip.freeze ?? 1) > 0, (clip.freeze ?? 0) <= 3600, (clip.volume ?? 1) <= 4 else { throw StudioError.message("컷 속도·음량 설정이 허용 범위를 벗어났습니다.") }
            if let t = clip.transition { guard t.duration.isFinite, t.duration >= 0, t.duration <= 10 else { throw StudioError.message("전환 효과 길이가 잘못되었습니다.") } }
            if let t = clip.transform {
                guard [t.scale,t.x,t.y,t.rotation,t.opacity,t.cropLeft,t.cropRight,t.cropTop,t.cropBottom].allSatisfy(\.isFinite), (0.05...10).contains(t.scale), (0...1).contains(t.opacity),
                      [t.cropLeft,t.cropRight,t.cropTop,t.cropBottom].allSatisfy({ (0...0.45).contains($0) }), abs(t.x) <= 2, abs(t.y) <= 2 else { throw StudioError.message("컷 화면 변형 설정이 허용 범위를 벗어났습니다.") }
            }
            if let c = clip.color {
                guard [c.exposure,c.brightness,c.contrast,c.saturation,c.temperature,c.tint].allSatisfy(\.isFinite), abs(c.exposure) <= 3, abs(c.brightness) <= 1,
                      (0...3).contains(c.contrast), (0...3).contains(c.saturation), abs(c.temperature) <= 1, abs(c.tint) <= 1 else { throw StudioError.message("색 보정 설정이 허용 범위를 벗어났습니다.") }
            }
        }
        for a in audioClips {
            guard let source = media.first(where:{$0.id == a.source}), source.hasAudio else { throw StudioError.message("오디오 클립의 원본이 프로젝트에 없습니다.") }
            guard [a.start,a.end,a.position,a.volume,a.fadeIn,a.fadeOut].allSatisfy(\.isFinite), a.start >= 0, a.end <= source.duration+0.01, a.duration > 0, a.position >= 0,
                  (0...4).contains(a.volume), a.fadeIn >= 0, a.fadeOut >= 0 else { throw StudioError.message("오디오 클립 설정이 잘못되었습니다.") }
        }
        if let range = exportRange {
            guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end <= editedDuration+0.000001, range.end > range.start else { throw StudioError.message("내보내기 구간이 편집 타임라인 범위를 벗어났습니다.") }
        }
        for r in regions { guard r.rect.valid, r.start.isFinite, r.end.isFinite, r.start >= 0, r.end >= r.start, (overlaysOnTimeline == true || r.end <= duration + 0.01), r.keyframes.allSatisfy({ $0.time.isFinite && $0.time >= 0 && (overlaysOnTimeline == true || $0.time <= duration) && $0.rect.valid }) else { throw StudioError.message("영역 마스크 데이터가 손상되었습니다.") } }
        guard titles.allSatisfy({ t in [t.start,t.end,t.x,t.y,t.size,t.red,t.green,t.blue,t.fadeIn,t.fadeOut].allSatisfy(\.isFinite) && t.start >= 0 && t.end > t.start && (0.01...0.5).contains(t.size) && t.fadeIn >= 0 && t.fadeOut >= 0 }),
              markers.allSatisfy({ $0.time.isFinite && $0.time >= 0 }) else { throw StudioError.message("타이틀 또는 마커 데이터가 손상되었습니다.") }
        guard captions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }),
              [design.strength,design.margin,design.red,design.green,design.blue,export.cropX,export.cropY,export.captionSize].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 2 }) else { throw StudioError.message("편집 설정이 손상되었습니다.") }
        for mask in [effectiveFaceDesign,effectiveRegionDesign] {
            guard [mask.strength,mask.margin,mask.red,mask.green,mask.blue].allSatisfy(\.isFinite),
                  (0...1).contains(mask.strength), (0...1.5).contains(mask.margin),
                  [mask.red,mask.green,mask.blue].allSatisfy({ (0...1).contains($0) }) else { throw StudioError.message("마스크 디자인 설정이 허용 범위를 벗어났습니다.") }
        }
        guard (0...1).contains(design.strength), (0...1.5).contains(design.margin),
              [design.red,design.green,design.blue,export.cropX,export.cropY].allSatisfy({ (0...1).contains($0) }),
              (0.01...0.2).contains(export.captionSize), faceBridge.isFinite, (0...5).contains(faceBridge), faceHold.isFinite, (0...2).contains(faceHold) else { throw StudioError.message("마스크·크롭 설정이 허용 범위를 벗어났습니다.") }
    }
}

// MARK: Project coding. Every field decodes with a fallback so older and partially
// written files open; v1 files (single source fields at the top level) migrate to media[0].
extension Project: Codable {
    private enum Keys: String, CodingKey {
        case version, media, isImage, width, height, fps, overlaysOnTimeline, videoLaneCount, regionLaneCount, captionLaneCount, audioLaneCount, titleLaneCount
        case regions, captions, clips, audioClips, titles, markers, design, faceDesign, regionDesign, faceBridge, faceHold, exportRange, export, queue, batch
        case sourcePath, fileSize, modified, duration, faces, maskApplied, analysisComplete
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:Keys.self)
        let fileVersion = try c.value(.version,1)
        guard (1...Project.currentVersion).contains(fileVersion) else { throw StudioError.message("이 프로젝트는 더 새로운 버전의 Veil Studio에서 저장되었습니다. 앱을 업데이트해 주세요.") }
        isImage = try c.value(.isImage,false); width = try c.value(.width,0); height = try c.value(.height,0); fps = try c.value(.fps,30)
        overlaysOnTimeline = try c.decodeIfPresent(Bool.self,forKey:.overlaysOnTimeline)
        videoLaneCount = try c.decodeIfPresent(Int.self,forKey:.videoLaneCount); regionLaneCount = try c.decodeIfPresent(Int.self,forKey:.regionLaneCount)
        captionLaneCount = try c.decodeIfPresent(Int.self,forKey:.captionLaneCount); audioLaneCount = try c.decodeIfPresent(Int.self,forKey:.audioLaneCount); titleLaneCount = try c.decodeIfPresent(Int.self,forKey:.titleLaneCount)
        regions = try c.value(.regions,[]); captions = try c.value(.captions,[]); clips = try c.value(.clips,[])
        audioClips = try c.value(.audioClips,[]); titles = try c.value(.titles,[]); markers = try c.value(.markers,[])
        design = try c.value(.design,MaskDesign()); faceDesign = try c.decodeIfPresent(MaskDesign.self,forKey:.faceDesign); regionDesign = try c.decodeIfPresent(MaskDesign.self,forKey:.regionDesign)
        faceBridge = try c.value(.faceBridge,1); faceHold = try c.value(.faceHold,0.25)
        exportRange = try c.decodeIfPresent(TimelineRange.self,forKey:.exportRange); export = try c.value(.export,ExportOptions())
        queue = try c.value(.queue,[]); batch = try c.value(.batch,BatchSettings())
        if c.contains(.media) { media = try c.value(.media,[]) }
        else if let path = try c.decodeIfPresent(String.self,forKey:.sourcePath) {
            var m = MediaSource(); m.path = path; m.fileSize = try c.value(.fileSize,0); m.modified = try c.decodeIfPresent(Date.self,forKey:.modified)
            m.kind = isImage ? .image : .video; m.duration = try c.value(.duration,0); m.width = width; m.height = height; m.fps = fps
            m.faces = try c.value(.faces,[]); m.maskApplied = try c.value(.maskApplied,false); m.analysisComplete = try c.value(.analysisComplete,false)
            media = [m]
        }
        version = Project.currentVersion
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy:Keys.self)
        try c.encode(version,forKey:.version); try c.encode(media,forKey:.media); try c.encode(isImage,forKey:.isImage)
        try c.encode(width,forKey:.width); try c.encode(height,forKey:.height); try c.encode(fps,forKey:.fps)
        try c.encodeIfPresent(overlaysOnTimeline,forKey:.overlaysOnTimeline)
        try c.encodeIfPresent(videoLaneCount,forKey:.videoLaneCount); try c.encodeIfPresent(regionLaneCount,forKey:.regionLaneCount); try c.encodeIfPresent(captionLaneCount,forKey:.captionLaneCount)
        try c.encodeIfPresent(audioLaneCount,forKey:.audioLaneCount); try c.encodeIfPresent(titleLaneCount,forKey:.titleLaneCount)
        try c.encode(regions,forKey:.regions); try c.encode(captions,forKey:.captions); try c.encode(clips,forKey:.clips)
        try c.encode(audioClips,forKey:.audioClips); try c.encode(titles,forKey:.titles); try c.encode(markers,forKey:.markers)
        try c.encode(design,forKey:.design); try c.encodeIfPresent(faceDesign,forKey:.faceDesign); try c.encodeIfPresent(regionDesign,forKey:.regionDesign)
        try c.encode(faceBridge,forKey:.faceBridge); try c.encode(faceHold,forKey:.faceHold)
        try c.encodeIfPresent(exportRange,forKey:.exportRange); try c.encode(export,forKey:.export); try c.encode(queue,forKey:.queue); try c.encode(batch,forKey:.batch)
    }
}
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key,_ fallback: @autoclosure () -> T) throws -> T { try decodeIfPresent(T.self,forKey:key) ?? fallback() }
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
func frameTimecode(_ seconds: Double, fps: Double) -> String {
    guard seconds.isFinite, fps.isFinite, fps > 0 else { return "00:00:00:00" }
    let s = max(0,seconds); let rate = max(1,Int(fps.rounded())); let total = Int((s*Double(rate)).rounded(.down))
    return String(format:"%02d:%02d:%02d:%02d",total/(rate*3600),(total/(rate*60))%60,(total/rate)%60,total%rate)
}
enum Subtitles {
    static func timestamp(_ time: Double) -> String { let ms = Int((max(0,time)*1000).rounded()); return String(format:"%02d:%02d:%02d,%03d",ms/3600000,(ms/60000)%60,(ms/1000)%60,ms%1000) }
    static func srt(_ captions: [Caption]) -> String { captions.enumerated().map { "\($0.offset+1)\n\(timestamp($0.element.start)) --> \(timestamp($0.element.end))\n\($0.element.text)\n" }.joined(separator:"\n") }
    static func parse(_ text: String) -> [Caption] {
        let normalized = text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").replacingOccurrences(of:"\u{FEFF}",with:"")
        func seconds(_ s: String) -> Double? {
            let clean = s.trimmingCharacters(in:.whitespaces).split(separator:" ").first.map(String.init) ?? ""
            let p = clean.replacingOccurrences(of:",",with:".").split(separator:":").compactMap { Double($0) }
            if p.count == 3 { return p[0]*3600+p[1]*60+p[2] }; if p.count == 2 { return p[0]*60+p[1] }; return nil
        }
        return normalized.components(separatedBy:"\n\n").compactMap { block in
            let lines = block.components(separatedBy:"\n"); guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[i].components(separatedBy:"-->"); guard times.count == 2, let a = seconds(times[0]), let b = seconds(times[1]), a.isFinite, b.isFinite, b > a, a >= 0 else { return nil }
            let content = lines.dropFirst(i+1).joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
            return content.isEmpty ? nil : Caption(start:a,end:b,text:content)
        }.sorted { $0.start < $1.start }
    }
}
