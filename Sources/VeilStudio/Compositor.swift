import AVFoundation
import CoreImage

// Composition time uses integer ticks so consecutive clips meet exactly on the same track.
let compositionTimescale: CMTimeScale = 60000
func ticks(_ seconds: Double) -> Int64 { Int64((max(0,seconds)*Double(compositionTimescale)).rounded()) }
func tickTime(_ value: Int64) -> CMTime { CMTime(value:value,timescale:compositionTimescale) }

struct SourceGeometry { var transform: CGAffineTransform; var size: CGSize }
struct LayerSpan {
    var entry: TimelineEntry
    var trackID: CMPersistentTrackID
    var source: UUID
    var kind: MediaKind
    var startTick: Int64
    var endTick: Int64
    var missing = false
}
struct AudioSegment { var trackID: CMPersistentTrackID; var clipID: UUID; var linked: Bool; var startTick: Int64; var endTick: Int64 }

// Result of the expensive part of composition building. Reused while cut timing is unchanged,
// so effect, mask and title edits only rebuild the (cheap) render instructions.
final class BuiltTimeline: @unchecked Sendable {
    let composition: AVMutableComposition
    let spans: [LayerSpan]
    let audio: [AudioSegment]
    let geometry: [UUID:SourceGeometry]
    let totalTicks: Int64
    let missing: Set<UUID>
    let key: CompositionKey
    init(composition: AVMutableComposition, spans: [LayerSpan], audio: [AudioSegment], geometry: [UUID:SourceGeometry], totalTicks: Int64, missing: Set<UUID>, key: CompositionKey) {
        self.composition = composition; self.spans = spans; self.audio = audio; self.geometry = geometry; self.totalTicks = totalTicks; self.missing = missing; self.key = key
    }
    var duration: Double { Double(totalTicks)/Double(compositionTimescale) }
}
// Everything that changes which media sits where on the composition's tracks.
struct CompositionKey: Equatable {
    struct Cut: Equatable { var id: UUID; var start: Double; var end: Double; var position: Double?; var lane: Int?; var source: UUID?; var speed: Double?; var freeze: Double?; var transition: Transition?; var silent: Bool }
    var cuts: [Cut]; var audio: [AudioClip]; var muted: Bool; var paths: [String]
    init(_ p: Project) {
        cuts = p.clips.map { Cut(id:$0.id,start:$0.start,end:$0.end,position:$0.position,lane:$0.lane,source:$0.source,speed:$0.speed,freeze:$0.freeze,transition:$0.transition,silent:$0.gain == 0) }
        audio = p.audioClips.map { var a = $0; a.volume = 0; a.fadeIn = 0; a.fadeOut = 0; a.muted = false; return a }
        muted = p.export.muted; paths = p.media.map(\.path)
    }
}

final class StillCache: @unchecked Sendable {
    private let lock = NSLock(); private var images: [String:CIImage] = [:]
    func image(path: String, maxEdge: Double) -> CIImage? {
        let key = "\(path)|\(Int(maxEdge))"
        lock.lock(); if let hit = images[key] { lock.unlock(); return hit }; lock.unlock()
        guard let full = try? MediaEngine.stillImage(URL(fileURLWithPath:path)) else { return nil }
        let scale = min(1,maxEdge/max(1,max(full.extent.width,full.extent.height)))
        var image = scale < 1 ? full.transformed(by:CGAffineTransform(scaleX:scale,y:scale)) : full
        image = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        // Rasterize once so every frame does not decode the file again.
        if let cg = CIContext(options:[.cacheIntermediates:false]).createCGImage(image,from:image.extent) { image = CIImage(cgImage:cg) }
        lock.lock(); images[key] = image; lock.unlock()
        return image
    }
}

final class RenderPlan: @unchecked Sendable {
    enum Purpose { case preview, export }
    let project: Project
    let renderer: MaskRenderer
    let spans: [LayerSpan]
    let geometry: [UUID:SourceGeometry]
    let canvas: CGSize
    let renderSize: CGSize
    let crop: Bool
    let stills: StillCache
    let cancellation: Cancellation?
    let colorSpace = CGColorSpace(name:CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    private let sources: [UUID:MediaSource]
    private let previousIndex: [UUID:Int]
    init(project: Project, renderer: MaskRenderer, built: BuiltTimeline, purpose: Purpose, previewEdge: Double, cancellation: Cancellation?, stills: StillCache) {
        self.project = project; self.renderer = renderer; spans = built.spans; geometry = built.geometry
        canvas = project.size; self.cancellation = cancellation; self.stills = stills
        crop = purpose == .export
        if purpose == .export { renderSize = project.export.outputSize(project.size) }
        else {
            let scale = min(1,previewEdge/max(1,max(project.width,project.height)))
            renderSize = CGSize(width:max(2,floor(project.width*scale/2)*2),height:max(2,floor(project.height*scale/2)*2))
        }
        sources = Dictionary(project.media.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        var previous: [UUID:Int] = [:]
        for (i,s) in built.spans.enumerated() { previous[s.entry.id] = i }
        previousIndex = previous
    }
    private enum Role { case normal, outgoing(TransitionKind,Double), incoming(TransitionKind,Double), fadeFromBlack(Double) }
    func frame(at time: Double, layers: [Int], sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let canvasRect = CGRect(origin:.zero,size:canvas)
        var image = CIImage(color:.black).cropped(to:canvasRect)
        var roles: [Int:Role] = [:]
        for index in layers {
            let span = spans[index]; let entry = span.entry
            guard let t = entry.clip.transition, t.duration > 0 else { continue }
            if let prev = entry.previous, entry.overlap > 0 {
                guard time < entry.start+entry.overlap, let a = previousIndex[prev], layers.contains(a) else { continue }
                let p = max(0,min(1,(time-entry.start)/entry.overlap))
                roles[index] = .incoming(t.kind,p); roles[a] = .outgoing(t.kind,p)
            } else if entry.overlap == 0, time < entry.start+t.duration {
                roles[index] = .fadeFromBlack(max(0,min(1,(time-entry.start)/t.duration)))
            }
        }
        for index in layers {
            let span = spans[index]
            guard var layer = layerImage(span,time:time,sourceFrame:sourceFrame) else { continue }
            var opacity = (span.entry.clip.transform?.opacity ?? 1)*fade(span.entry,time:time)
            switch roles[index] ?? .normal {
            case .normal: break
            case .outgoing(let kind,let p):
                if kind == .dipToBlack { if p >= 0.5 { continue }; layer = renderer.dim(layer,1-2*p) }
            case .incoming(let kind,let p):
                switch kind {
                case .dissolve: opacity *= p
                case .dipToBlack: if p < 0.5 { continue }; layer = renderer.dim(layer,2*p-1)
                case .wipe: layer = layer.cropped(to:CGRect(x:0,y:0,width:canvas.width*p,height:canvas.height))
                case .slide: layer = layer.transformed(by:CGAffineTransform(translationX:canvas.width*(1-p),y:0)).cropped(to:canvasRect)
                }
            case .fadeFromBlack(let p):
                if span.entry.lane == 0 { layer = renderer.dim(layer,p) } else { opacity *= p }
            }
            image = renderer.composite(layer,over:image,opacity:max(0,min(1,opacity)))
        }
        image = renderer.applyRegions(image,project:project,time:time)
        if crop {
            let rect = project.export.cropRect(canvas)
            image = image.cropped(to:rect).transformed(by:CGAffineTransform(translationX:-rect.minX,y:-rect.minY)).transformed(by:CGAffineTransform(scaleX:renderSize.width/max(1,rect.width),y:renderSize.height/max(1,rect.height)))
        } else if renderSize != canvas {
            image = image.transformed(by:CGAffineTransform(scaleX:renderSize.width/max(1,canvas.width),y:renderSize.height/max(1,canvas.height)))
        }
        image = image.cropped(to:CGRect(origin:.zero,size:renderSize))
        if project.export.burnCaptions { image = renderer.drawCaptions(image,captions:project.captions,time:time,sizeFraction:project.export.captionSize) }
        image = renderer.drawTitles(image,titles:project.titles,time:time)
        return image
    }
    private func fade(_ entry: TimelineEntry, time: Double) -> Double {
        var value = 1.0
        if let f = entry.clip.videoFadeIn, f > 0 { value = min(value,(time-entry.start)/f) }
        if let f = entry.clip.videoFadeOut, f > 0 { value = min(value,(entry.end-time)/f) }
        return max(0,min(1,value))
    }
    private func layerImage(_ span: LayerSpan, time: Double, sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage? {
        guard let source = sources[span.source] else { return nil }
        var image: CIImage
        if span.missing {
            let size = geometry[span.source]?.size ?? canvas
            image = CIImage(color:CIColor(red:0.25,green:0.05,blue:0.08)).cropped(to:CGRect(origin:.zero,size:size))
            if let label = renderer.textImage("미디어 없음 · \(source.name)",width:Int(max(40,size.width*0.8)),height:Int(max(20,size.height*0.12)),fontSize:max(10,size.height*0.05),background:true) {
                image = label.transformed(by:CGAffineTransform(translationX:size.width*0.1,y:size.height*0.44)).composited(over:image)
            }
        } else if span.kind == .image {
            guard let still = stills.image(path:source.path,maxEdge:max(canvas.width,canvas.height)*max(1,span.entry.clip.transform?.scale ?? 1)) else { return nil }
            image = still
        } else {
            guard span.trackID != kCMPersistentTrackID_Invalid, let buffer = sourceFrame(span.trackID), let g = geometry[span.source] else { return nil }
            image = CIImage(cvPixelBuffer:buffer).transformed(by:g.transform)
            image = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        }
        if source.maskApplied, !span.missing {
            // Masks are drawn in the source picture before it is scaled, so they follow the clip transform.
            image = renderer.applyFaceMasks(image,faces:source.faces,time:span.entry.sourceTime(at:time),still:source.isImage,fps:source.fps,design:project.effectiveFaceDesign,bridge:project.faceBridge,hold:project.faceHold)
        }
        image = renderer.applyColor(image,span.entry.clip.color)
        return placeLayer(image,canvas:canvas,transform:span.entry.clip.transform)
    }
}

final class VeilInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [Int]
    let plan: RenderPlan
    init(timeRange: CMTimeRange, layers: [Int], tracks: [CMPersistentTrackID], plan: RenderPlan) {
        self.timeRange = timeRange; self.layers = layers; self.plan = plan
        requiredSourceTrackIDs = tracks.isEmpty ? nil : tracks.map { NSNumber(value:$0) }
    }
}

final class VeilCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label:"studio.veil.compositor",qos:.userInitiated)
    private let lock = NSLock(); private var generation = 0
    private static let attributes: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[String:Int]()]
    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.attributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.attributes }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock(); let token = generation; lock.unlock()
        queue.async { [self] in
            lock.lock(); let stale = token != generation; lock.unlock()
            if stale { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? VeilInstruction else { request.finish(with:StudioError.message("합성 지시를 읽을 수 없습니다.")); return }
            let plan = instruction.plan
            if plan.cancellation?.cancelled == true { request.finish(with:CancellationError()); return }
            guard let output = request.renderContext.newPixelBuffer() else { request.finish(with:StudioError.message("프레임 버퍼를 만들 수 없습니다. 메모리가 부족할 수 있습니다.")); return }
            autoreleasepool {
                let image = plan.frame(at:request.compositionTime.seconds,layers:instruction.layers) { request.sourceFrame(byTrackID:$0) }
                CVBufferSetAttachment(output,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
                CVBufferSetAttachment(output,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
                CVBufferSetAttachment(output,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
                plan.renderer.context.render(image,to:output,bounds:CGRect(origin:.zero,size:plan.renderSize),colorSpace:plan.colorSpace)
            }
            request.finish(withComposedVideoFrame:output)
        }
    }
    func cancelAllPendingVideoCompositionRequests() { lock.lock(); generation += 1; lock.unlock() }
}

// A tiny black clip stretched under the whole timeline. It gives the composition its full
// length (gaps, photos, title-only or audio-only tails) so every frame reaches the compositor.
actor CarrierVideo {
    static let shared = CarrierVideo()
    private var ready: URL?
    func url() async throws -> URL {
        if let ready, FileManager.default.fileExists(atPath:ready.path) { return ready }
        let folder = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("VeilStudio",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let url = folder.appendingPathComponent("carrier-v1.mov")
        if FileManager.default.fileExists(atPath:url.path), (try? await AVURLAsset(url:url).load(.duration).seconds) ?? 0 >= 0.99 { ready = url; return url }
        let temporary = folder.appendingPathComponent("carrier-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at:temporary) }
        let writer = try AVAssetWriter(outputURL:temporary,fileType:.mov)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:64])
        guard writer.canAdd(input) else { throw StudioError.message("기본 영상 트랙을 만들 수 없습니다.") }
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? StudioError.message("기본 영상 트랙을 만들 수 없습니다.") }
        writer.startSession(atSourceTime:.zero)
        for n in 0..<10 {
            let started = Date()
            while !input.isReadyForMoreMediaData { if writer.status == .failed || Date().timeIntervalSince(started) > 10 { throw writer.error ?? StudioError.message("기본 영상 트랙 생성 시간 초과") }; try await Task.sleep(nanoseconds:2_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer) == kCVReturnSuccess, let buffer else { throw StudioError.message("기본 영상 버퍼를 만들 수 없습니다.") }
            CVPixelBufferLockBaseAddress(buffer,[]); if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base,0,CVPixelBufferGetDataSize(buffer)) }; CVPixelBufferUnlockBaseAddress(buffer,[])
            adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(n),timescale:10))
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StudioError.message("기본 영상 트랙 저장 실패") }
        try? FileManager.default.removeItem(at:url); try FileManager.default.moveItem(at:temporary,to:url)
        ready = url; return url
    }
}

enum CompositionBuilder {
    // Keeps the asset alive: an AVAssetTrack does not retain its asset, and inserting from a
    // track whose asset was released fails.
    struct LoadedSource { var asset: AVAsset?; var video: AVAssetTrack?; var audio: AVAssetTrack?; var videoRange: CMTimeRange; var audioRange: CMTimeRange; var geometry: SourceGeometry }
    static func loadSource(_ source: MediaSource) async throws -> LoadedSource {
        let asset = AVURLAsset(url:URL(fileURLWithPath:source.path),options:[AVURLAssetPreferPreciseDurationAndTimingKey:true])
        let video = try await asset.loadTracks(withMediaType:.video).first
        let audio = try await asset.loadTracks(withMediaType:.audio).first
        var geometry = SourceGeometry(transform:.identity,size:source.size)
        var videoRange = CMTimeRange.zero, audioRange = CMTimeRange.zero
        if let video {
            let natural = try await video.load(.naturalSize); let transform = try await video.load(.preferredTransform)
            let oriented = orientedTransform(transform,natural:natural); geometry = SourceGeometry(transform:oriented.transform,size:oriented.size)
            videoRange = try await video.load(.timeRange)
        }
        if let audio { audioRange = try await audio.load(.timeRange) }
        return LoadedSource(asset:asset,video:video,audio:audio,videoRange:videoRange,audioRange:audioRange,geometry:geometry)
    }
    static func buildTimeline(_ p: Project, muted: Bool, allowMissing: Bool) async throws -> BuiltTimeline {
        let composition = AVMutableComposition()
        let entries = p.timeline.sorted { ($0.start,$0.lane) < ($1.start,$1.lane) }
        let total = ticks(p.editedDuration)
        guard total > 0 else { throw StudioError.message("내보낼 컷이 없습니다.") }
        var loaded: [UUID:LoadedSource] = [:]; var missing = Set<UUID>()
        let needed = Set(p.clips.compactMap { p.sourceID(of:$0) } + p.audioClips.map(\.source))
        for id in needed {
            guard let source = p.source(id) else { continue }
            guard FileManager.default.fileExists(atPath:source.path) else {
                if allowMissing { missing.insert(id); continue }
                throw StudioError.message("원본 미디어를 찾을 수 없습니다: \(source.name)\n원래 위치로 되돌리거나 미디어 패널에서 다시 연결해 주세요.")
            }
            if source.kind == .image { loaded[id] = LoadedSource(asset:nil,video:nil,audio:nil,videoRange:.zero,audioRange:.zero,geometry:SourceGeometry(transform:.identity,size:source.size)); continue }
            do { loaded[id] = try await loadSource(source) }
            catch {
                if allowMissing { missing.insert(id); continue }
                throw StudioError.message("미디어를 읽을 수 없습니다: \(source.name) · \(error.localizedDescription)")
            }
        }
        // Pooled tracks: a clip goes to the first track that is free when it starts.
        var videoPool: [(track: AVMutableCompositionTrack, end: Int64)] = []
        func videoTrack(from start: Int64) throws -> AVMutableCompositionTrack {
            if let i = videoPool.firstIndex(where:{ $0.end <= start }) {
                if videoPool[i].end < start { videoPool[i].track.insertEmptyTimeRange(CMTimeRange(start:tickTime(videoPool[i].end),end:tickTime(start))) }
                return videoPool[i].track
            }
            guard let t = composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw StudioError.message("영상 트랙을 만들 수 없습니다.") }
            if start > 0 { t.insertEmptyTimeRange(CMTimeRange(start:.zero,end:tickTime(start))) }
            videoPool.append((t,start)); return t
        }
        var audioPool: [(track: AVMutableCompositionTrack, end: Int64)] = []
        func audioTrack(from start: Int64) throws -> AVMutableCompositionTrack {
            if let i = audioPool.firstIndex(where:{ $0.end <= start }) {
                if audioPool[i].end < start { audioPool[i].track.insertEmptyTimeRange(CMTimeRange(start:tickTime(audioPool[i].end),end:tickTime(start))) }
                return audioPool[i].track
            }
            guard let t = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw StudioError.message("오디오 트랙을 만들 수 없습니다.") }
            if start > 0 { t.insertEmptyTimeRange(CMTimeRange(start:.zero,end:tickTime(start))) }
            audioPool.append((t,start)); return t
        }
        // Inserts source media so it fills exactly [start,end) on the timeline.
        func place(_ track: AVMutableCompositionTrack, of assetTrack: AVAssetTrack, range available: CMTimeRange, clip: Clip, start: Int64, end: Int64, fps: Double) throws -> Bool {
            let length = end-start; guard length > 0 else { return false }
            let rangeStart = ticks(available.start.seconds), rangeEnd = ticks(available.end.seconds)
            var from = min(max(ticks(clip.start),rangeStart),max(rangeStart,rangeEnd-1))
            var span: Int64
            if clip.freeze != nil { span = max(1,min(ticks(1/max(1,fps)),rangeEnd-from)) }
            else if clip.rate == 1 { span = min(length,rangeEnd-from) }
            else { span = min(ticks(clip.end),rangeEnd)-from }
            if span <= 0 { from = max(rangeStart,rangeEnd-ticks(1/max(1,fps))); span = rangeEnd-from }
            guard span > 0 else { return false }
            try track.insertTimeRange(CMTimeRange(start:tickTime(from),duration:tickTime(span)),of:assetTrack,at:tickTime(start))
            if span != length { track.scaleTimeRange(CMTimeRange(start:tickTime(start),duration:tickTime(span)),toDuration:tickTime(length)) }
            return true
        }
        var spans: [LayerSpan] = []; var audio: [AudioSegment] = []
        for entry in entries {
            guard let id = p.sourceID(of:entry.clip), let source = p.source(id) else { continue }
            let start = ticks(entry.start), end = min(total,ticks(entry.end)); guard end > start else { continue }
            var span = LayerSpan(entry:entry,trackID:kCMPersistentTrackID_Invalid,source:id,kind:source.kind,startTick:start,endTick:end)
            if missing.contains(id) { span.missing = true; spans.append(span); continue }
            if source.kind == .video, let l = loaded[id], let video = l.video {
                let track = try videoTrack(from:start)
                if try place(track,of:video,range:l.videoRange,clip:entry.clip,start:start,end:end,fps:source.fps) {
                    span.trackID = track.trackID
                    if let i = videoPool.firstIndex(where:{ $0.track === track }) { videoPool[i].end = end }
                }
            }
            spans.append(span)
            if !muted, entry.clip.freeze == nil, entry.clip.gain > 0, let l = loaded[id], let sound = l.audio {
                let track = try audioTrack(from:start)
                if try place(track,of:sound,range:l.audioRange,clip:entry.clip,start:start,end:end,fps:source.fps) {
                    if let i = audioPool.firstIndex(where:{ $0.track === track }) { audioPool[i].end = end }
                    audio.append(AudioSegment(trackID:track.trackID,clipID:entry.id,linked:true,startTick:start,endTick:end))
                }
            }
        }
        if !muted {
            for a in p.audioClips.sorted(by:{ $0.position < $1.position }) where a.gain > 0 {
                guard let l = loaded[a.source], let sound = l.audio else { continue }
                let start = ticks(a.position), end = min(total,ticks(a.timelineEnd)); guard end > start else { continue }
                let track = try audioTrack(from:start)
                if try place(track,of:sound,range:l.audioRange,clip:Clip(start:a.start,end:a.end),start:start,end:end,fps:30) {
                    if let i = audioPool.firstIndex(where:{ $0.track === track }) { audioPool[i].end = end }
                    audio.append(AudioSegment(trackID:track.trackID,clipID:a.id,linked:false,startTick:start,endTick:end))
                }
            }
        }
        let carrierAsset = AVURLAsset(url:try await CarrierVideo.shared.url())
        defer { withExtendedLifetime(carrierAsset) {}; withExtendedLifetime(loaded) {} }
        guard let carrierSource = try await carrierAsset.loadTracks(withMediaType:.video).first,
              let carrier = composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw StudioError.message("기본 영상 트랙을 준비하지 못했습니다.") }
        let carrierRange = try await carrierSource.load(.timeRange)
        try carrier.insertTimeRange(carrierRange,of:carrierSource,at:.zero)
        carrier.scaleTimeRange(CMTimeRange(start:.zero,duration:carrierRange.duration),toDuration:tickTime(total))
        var geometry: [UUID:SourceGeometry] = [:]
        for (id,l) in loaded { geometry[id] = l.geometry }
        for id in missing { if let s = p.source(id) { geometry[id] = SourceGeometry(transform:.identity,size:s.width > 0 ? s.size : p.size) } }
        return BuiltTimeline(composition:composition,spans:spans,audio:audio,geometry:geometry,totalTicks:total,missing:missing,key:CompositionKey(p))
    }
    static func videoComposition(_ built: BuiltTimeline, project: Project, purpose: RenderPlan.Purpose, renderer: MaskRenderer, cancellation: Cancellation?, stills: StillCache, previewEdge: Double = 1920) -> (AVMutableVideoComposition,RenderPlan) {
        let plan = RenderPlan(project:project,renderer:renderer,built:built,purpose:purpose,previewEdge:previewEdge,cancellation:cancellation,stills:stills)
        var edges = Set<Int64>([0,built.totalTicks])
        for s in built.spans { edges.insert(min(built.totalTicks,s.startTick)); edges.insert(min(built.totalTicks,s.endTick)) }
        let sorted = edges.sorted()
        var instructions: [VeilInstruction] = []
        for (a,b) in zip(sorted,sorted.dropFirst()) where b > a {
            let active = built.spans.indices.filter { built.spans[$0].startTick <= a && built.spans[$0].endTick >= b }
                .sorted { (built.spans[$0].entry.lane,built.spans[$0].entry.start) < (built.spans[$1].entry.lane,built.spans[$1].entry.start) }
            let tracks = Array(Set(active.map { built.spans[$0].trackID }.filter { $0 != kCMPersistentTrackID_Invalid })).sorted()
            instructions.append(VeilInstruction(timeRange:CMTimeRange(start:tickTime(a),end:tickTime(b)),layers:active,tracks:tracks,plan:plan))
        }
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = VeilCompositor.self
        video.instructions = instructions
        video.renderSize = plan.renderSize
        video.frameDuration = CMTime(seconds:1/min(120,max(1,project.fps)),preferredTimescale:compositionTimescale)
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2; video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2; video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return (video,plan)
    }
    // Clip gain, fades and transition cross-fades read from the current project, so volume
    // edits do not need a new composition.
    static func audioMix(_ built: BuiltTimeline, project: Project) -> AVMutableAudioMix? {
        guard !built.audio.isEmpty else { return nil }
        let entries = project.timeline
        let clips = Dictionary(entries.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        let crossOut = Dictionary(entries.compactMap { e -> (UUID,Double)? in e.previous.map { ($0,e.overlap) } },uniquingKeysWith:max)
        let audioClips = Dictionary(project.audioClips.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        var parameters: [CMPersistentTrackID:AVMutableAudioMixInputParameters] = [:]
        for segment in built.audio.sorted(by:{ $0.startTick < $1.startTick }) {
            let param = parameters[segment.trackID] ?? { let p = AVMutableAudioMixInputParameters(); p.trackID = segment.trackID; parameters[segment.trackID] = p; return p }()
            var gain = 1.0, fadeIn = 0.0, fadeOut = 0.0
            if segment.linked, let e = clips[segment.clipID] { gain = e.clip.gain; fadeIn = max(e.clip.audioFadeIn ?? 0,e.overlap); fadeOut = max(e.clip.audioFadeOut ?? 0,crossOut[e.id] ?? 0) }
            else if let a = audioClips[segment.clipID] { gain = a.gain; fadeIn = a.fadeIn; fadeOut = a.fadeOut }
            let length = segment.endTick-segment.startTick
            let inTicks = min(ticks(fadeIn),length/2), outTicks = min(ticks(fadeOut),length/2)
            let volume = Float(gain)
            if inTicks > 0 { param.setVolumeRamp(fromStartVolume:0,toEndVolume:volume,timeRange:CMTimeRange(start:tickTime(segment.startTick),duration:tickTime(inTicks))) }
            else { param.setVolume(volume,at:tickTime(segment.startTick)) }
            if outTicks > 0 { param.setVolumeRamp(fromStartVolume:volume,toEndVolume:0,timeRange:CMTimeRange(start:tickTime(segment.endTick-outTicks),duration:tickTime(outTicks))) }
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = Array(parameters.values); return mix
    }
}
