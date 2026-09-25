import AppKit
import AVFoundation
import Vision
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

final class MaskRenderer: @unchecked Sendable {
    let context = CIContext(options: [.cacheIntermediates: false])
    private let cache = NSCache<NSString, CIImage>()
    func shapeMask(_ shape: MaskShape) -> CIImage {
        let key = shape.rawValue as NSString
        if let image = cache.object(forKey:key) { return image }
        let n = 256.0
        let ctx = CGContext(data:nil,width:256,height:256,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray:1,alpha:1)); let r = CGRect(x:0,y:0,width:n,height:n)
        switch shape {
        case .oval: ctx.fillEllipse(in:r)
        case .rectangle: ctx.fill(r)
        case .rounded: ctx.addPath(CGPath(roundedRect:r,cornerWidth:42,cornerHeight:42,transform:nil)); ctx.fillPath()
        case .heart:
            ctx.move(to:CGPoint(x:128,y:10)); ctx.addCurve(to:CGPoint(x:12,y:158),control1:CGPoint(x:25,y:90),control2:CGPoint(x:12,y:115))
            ctx.addCurve(to:CGPoint(x:128,y:203),control1:CGPoint(x:12,y:247),control2:CGPoint(x:90,y:267))
            ctx.addCurve(to:CGPoint(x:244,y:158),control1:CGPoint(x:166,y:267),control2:CGPoint(x:244,y:247))
            ctx.addCurve(to:CGPoint(x:128,y:10),control1:CGPoint(x:244,y:115),control2:CGPoint(x:230,y:90)); ctx.fillPath()
        case .star:
            for i in 0..<10 { let a = Double(i)*Double.pi/5+Double.pi/2; let radius = i%2 == 0 ? 127.0 : 65.0
                let p = CGPoint(x:128+cos(a)*radius,y:128+sin(a)*radius); if i == 0 { ctx.move(to:p) } else { ctx.addLine(to:p) } }; ctx.closePath(); ctx.fillPath()
        }
        let image = CIImage(cgImage:ctx.makeImage()!); cache.setObject(image,forKey:key); return image
    }
    func textImage(_ text: String, width: Int, height: Int, fontSize: Double, background: Bool) -> CIImage? {
        let key = "\(text)|\(width)|\(height)|\(fontSize)|\(background)" as NSString
        if let image = cache.object(forKey:key) { return image }
        guard width > 0, height > 0, let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if background { ctx.setFillColor(CGColor(gray:0,alpha:0.72)); ctx.addPath(CGPath(roundedRect:CGRect(x:0,y:0,width:width,height:height),cornerWidth:Double(height)*0.1,cornerHeight:Double(height)*0.1,transform:nil)); ctx.fillPath() }
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:fontSize,weight:.semibold),.foregroundColor:NSColor.white,.paragraphStyle:style])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let padding = background ? fontSize*0.3 : 0
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(location:0,length:0),nil,CGSize(width:Double(width)-padding*2,height:Double(height)),nil)
        let rect = CGRect(x:padding,y:max(0,(Double(height)-measured.height)/2),width:Double(width)-padding*2,height:min(Double(height),measured.height+4))
        CTFrameDraw(CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:rect,transform:nil),nil),ctx)
        guard let cg = ctx.makeImage() else { return nil }; let image = CIImage(cgImage:cg); cache.setObject(image,forKey:key); return image
    }
    func render(_ source: CIImage, project: Project, time: Double, crop: Bool, overlayTime: Double? = nil) -> CIImage {
        var image = source.transformed(by:CGAffineTransform(translationX:-source.extent.minX,y:-source.extent.minY))
        let extent = image.extent; let size = extent.size
        if !project.isImage && time < 0 { image = CIImage(color:.black).cropped(to:extent) }
        let faceDesign = project.effectiveFaceDesign; let regionDesign = project.effectiveRegionDesign
        var masks: [(NormalRect,MaskDesign)] = []
        if project.maskApplied {
            masks += project.faces.filter(\.selected).compactMap { face in
                face.rect(at:time,still:project.isImage,tolerance:max(0.06,1.5/project.fps)).map { ($0.expanded(faceDesign.margin),faceDesign) }
            }
        }
        let overlayTime = project.overlaysOnTimeline == true ? (overlayTime ?? time) : time
        masks += project.regions.sorted(by:{($0.lane ?? 0) < ($1.lane ?? 0)}).filter { $0.enabled && (project.isImage || (overlayTime >= $0.start && overlayTime < $0.end)) }.map { ($0.rect(at:overlayTime),regionDesign) }
        for (normal,d) in masks {
            let r = normal.scaled(to:size).intersection(extent); guard r.width > 1, r.height > 1 else { continue }
            let mask = shapeMask(d.shape).transformed(by:CGAffineTransform(scaleX:r.width/256,y:r.height/256)).transformed(by:CGAffineTransform(translationX:r.minX,y:r.minY))
            var effect: CIImage
            switch d.effect {
            case .pixel: effect = image.clampedToExtent().applyingFilter("CIPixellate",parameters:[kCIInputScaleKey:max(6,min(r.width,r.height)*(0.07+d.strength*0.25)),kCIInputCenterKey:CIVector(x:r.midX,y:r.midY)])
            case .blur: effect = image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(8,min(r.width,r.height)*(0.06+d.strength*0.22))])
            case .solid, .sticker: effect = CIImage(color:CIColor(red:d.red,green:d.green,blue:d.blue)).cropped(to:r)
            }
            if d.effect == .sticker, let emoji = textImage(d.sticker,width:256,height:256,fontSize:180,background:false) {
                let placed = emoji.transformed(by:CGAffineTransform(scaleX:r.width/256,y:r.height/256)).transformed(by:CGAffineTransform(translationX:r.minX,y:r.minY))
                effect = placed.composited(over:effect)
            }
            image = effect.cropped(to:r).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:mask]).cropped(to:extent)
        }
        if crop {
            let rect = project.export.cropRect(size); let target = project.export.outputSize(size,even:!project.isImage)
            image = image.cropped(to:rect).transformed(by:CGAffineTransform(translationX:-rect.minX,y:-rect.minY)).transformed(by:CGAffineTransform(scaleX:target.width/rect.width,y:target.height/rect.height))
        }
        for c in project.captions.sorted(by:{($0.lane ?? 0) < ($1.lane ?? 0)}) where project.export.burnCaptions && overlayTime >= c.start && overlayTime < c.end && !c.text.isEmpty {
            let s = image.extent.size; let font = max(12,min(s.width,s.height)*project.export.captionSize)
            let width = Int(s.width*max(0.1,min(1,c.boxWidth ?? 0.86))); let lineCount = max(1,min(5,Int(ceil(Double(c.text.count)*font*0.8/Double(max(1,width)))) + c.text.filter({$0 == "\n"}).count))
            if let text = textImage(c.text,width:width,height:Int(font*(Double(lineCount)*1.35+0.7)),fontSize:font,background:true) {
                image = text.transformed(by:CGAffineTransform(translationX:(s.width-Double(width))*max(0,min(1,c.horizontal ?? 0.5)),y:max(0,s.height-Double(text.extent.height))*max(0,min(1,c.vertical ?? (s.height*0.055/max(1,s.height-text.extent.height)))))).composited(over:image)
            }
        }
        return image
    }
}

enum MediaEngine {
    static func load(_ url: URL) async throws -> Project {
        let info = try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.contentTypeKey])
        var p = Project(); p.sourcePath = url.path; p.fileSize = Int64(info.fileSize ?? 0); p.modified = info.contentModificationDate
        if let source = CGImageSourceCreateWithURL(url as CFURL,nil), let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Double, let h = properties[kCGImagePropertyPixelHeight] as? Double {
            guard w*h <= 120_000_000 else { throw StudioError.message("이미지는 최대 1억 2천만 화소까지 지원합니다. 먼저 크기를 줄여 주세요.") }
            guard CGImageSourceGetCount(source) == 1 else { throw StudioError.message("애니메이션·다중 페이지 이미지는 현재 지원하지 않습니다. 단일 프레임 PNG/JPEG로 변환해 주세요.") }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            p.isImage = true; p.width = (5...8).contains(orientation) ? h : w; p.height = (5...8).contains(orientation) ? w : h
            return p
        }
        let asset = AVURLAsset(url:url)
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw StudioError.message("읽을 수 있는 영상이나 이미지가 아닙니다. MP4, MOV, JPEG, PNG, HEIC 등을 사용해 주세요.") }
        let size = try await track.load(.naturalSize); let transform = try await track.load(.preferredTransform); let box = CGRect(origin:.zero,size:size).applying(transform)
        p.width = abs(box.width); p.height = abs(box.height); p.duration = try await asset.load(.duration).seconds; p.fps = max(1,Double(try await track.load(.nominalFrameRate)))
        guard p.duration.isFinite, p.duration > 0 else { throw StudioError.message("영상 길이를 읽을 수 없습니다.") }
        p.clips = [Clip(start:0,end:p.duration)]; try p.validate(); return p
    }
    static func stillImage(_ url: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf:url,options:[.applyOrientationProperty:true]) else { throw StudioError.message("이미지를 읽을 수 없습니다.") }
        return image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
    }
    static func analyze(_ project: Project, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws -> [FaceTrack] {
        let context = CIContext(options:[.cacheIntermediates:false]); var tracks: [FaceTrack] = []
        var prints: [UUID:VNFeaturePrintObservation] = [:]
        var lastPrintTime: [UUID:Double] = [:]
        func process(_ source: CIImage, time: Double) throws {
            try cancellation.check()
            let source = source.transformed(by:CGAffineTransform(translationX:-source.extent.minX,y:-source.extent.minY))
            let scale = min(1,(project.isImage ? 2400.0 : 960.0)/max(source.extent.width,source.extent.height)); let small = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            guard let cg = context.createCGImage(small,from:small.extent) else { throw StudioError.message("분석 프레임을 읽지 못했습니다.") }
            let request = VNDetectFaceRectanglesRequest(); try VNImageRequestHandler(cgImage:cg).perform([request])
            var detections = (request.results ?? []).map(\.boundingBox)
            // Overlapping tiles improve small-face detection in high-resolution still images.
            if project.isImage {
                for y in [0.0,0.275,0.55] { for x in [0.0,0.275,0.55] {
                    try cancellation.check()
                    let tile = CGRect(x:x*small.extent.width,y:y*small.extent.height,width:small.extent.width*0.45,height:small.extent.height*0.45).integral.intersection(small.extent)
                    guard let tileCG = context.createCGImage(small,from:tile) else { continue }
                    let tileRequest = VNDetectFaceRectanglesRequest(); try VNImageRequestHandler(cgImage:tileCG).perform([tileRequest])
                    for face in tileRequest.results ?? [] {
                        let b = face.boundingBox
                        let mapped = CGRect(x:(tile.minX+b.minX*tile.width)/small.extent.width,y:(tile.minY+b.minY*tile.height)/small.extent.height,width:b.width*tile.width/small.extent.width,height:b.height*tile.height/small.extent.height)
                        let duplicate = detections.contains { old in
                            let overlap = old.intersection(mapped)
                            return !overlap.isNull && overlap.width*overlap.height / min(old.width*old.height,mapped.width*mapped.height) > 0.65
                        }
                        if !duplicate { detections.append(mapped) }
                    }
                } }
            }
            var assigned = Set<UUID>()
            for box in detections.sorted(by: {$0.minX < $1.minX}) {
                guard let rect = NormalRect(box).clippedToImage else { continue }
                let crop = rect.expanded(0.15).scaled(to:small.extent.size).integral.intersection(small.extent)
                guard let faceCG = context.createCGImage(small,from:crop) else { continue }
                let feature = VNGenerateImageFeaturePrintRequest(); try VNImageRequestHandler(cgImage:faceCG).perform([feature]); let printValue = feature.results?.first
                var best: Int?; var bestScore = Double.infinity
                for i in tracks.indices where !assigned.contains(tracks[i].id) {
                    guard let last = tracks[i].samples.last else { continue }
                    let gap = time-last.time; let a = last.rect.cg; let b = rect.cg
                    let intersection = a.intersection(b); let iou = intersection.isNull ? 0 : intersection.width*intersection.height / max(0.00001,a.width*a.height+b.width*b.height-intersection.width*intersection.height)
                    var distance: Float = 2
                    if let printValue, let old = prints[tracks[i].id] { try? printValue.computeDistance(&distance,to:old) }
                    // Generic appearance similarity is only a candidate grouping aid, never identity proof.
                    let continuous = gap <= max(0.15,2/project.fps) && iou > 0.18 && distance < 0.8
                    let reentry = gap < 8 && distance < 0.32
                    guard continuous || reentry else { continue }
                    let score = Double(distance)+(continuous ? (1-iou)*0.25 : 0.35)
                    if score < bestScore { best = i; bestScore = score }
                }
                if let i = best {
                    tracks[i].samples.append(FaceSample(time:time,rect:rect)); assigned.insert(tracks[i].id)
                    if time - (lastPrintTime[tracks[i].id] ?? 0) > 0.5 { prints[tracks[i].id] = printValue; lastPrintTime[tracks[i].id] = time }
                } else {
                    let rep = NSBitmapImageRep(cgImage:faceCG); let thumb = rep.representation(using:.jpeg,properties:[.compressionFactor:0.8])
                    let track = FaceTrack(name:"인물 후보 \(tracks.count+1)",thumbnail:thumb,samples:[FaceSample(time:time,rect:rect)])
                    tracks.append(track); prints[track.id] = printValue; lastPrintTime[track.id] = time; assigned.insert(track.id)
                }
            }
        }
        if project.isImage { try process(stillImage(URL(fileURLWithPath:project.sourcePath)),time:0); progress(1,"얼굴 분석 완료"); return tracks }
        let asset = AVURLAsset(url:URL(fileURLWithPath:project.sourcePath)); guard let track = try await asset.loadTracks(withMediaType:.video).first else { return [] }
        let transform = try await track.load(.preferredTransform)
        let ranges = project.analysisRanges
        let total = ranges.reduce(0) { $0+$1.duration }
        guard total > 0 else { throw StudioError.message("분석할 영상 컷이 없습니다.") }
        var completed = 0.0
        for range in ranges {
        try cancellation.check()
        let reader = try AVAssetReader(asset:asset)
        reader.timeRange = CMTimeRange(start:CMTime(seconds:range.start,preferredTimescale:60000),duration:CMTime(seconds:range.duration,preferredTimescale:60000))
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]); output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StudioError.message("이 영상 코덱은 분석할 수 없습니다.") }; reader.add(output)
        guard reader.startReading() else { throw reader.error ?? StudioError.message("영상 읽기를 시작하지 못했습니다.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var lastProgress = -1.0
        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            try autoreleasepool {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard time >= range.start, time < range.end else { return }
                try process(CIImage(cvPixelBuffer:buffer).transformed(by:transform),time:time)
                if time-lastProgress >= 0.25 { progress(min(0.99,(completed+time-range.start)/total),"남은 컷 분석 · \(timecode(completed+time-range.start)) / \(timecode(total)) · 후보 \(tracks.count)명"); lastProgress = time }
            }
        }
        if reader.status == .failed { throw reader.error ?? StudioError.message("영상 분석 중 읽기 오류가 발생했습니다.") }
        completed += range.duration
        }
        try cancellation.check(); progress(1,"얼굴 분석 완료"); return tracks
    }
    static func composition(for p: Project) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url:URL(fileURLWithPath:p.sourcePath)); let c = AVMutableComposition()
        guard let video = try await asset.loadTracks(withMediaType:.video).first,
              let v = c.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw StudioError.message("영상 트랙을 읽을 수 없습니다.") }
        v.preferredTransform = try await video.load(.preferredTransform)
        let audio = p.export.muted ? nil : try await asset.loadTracks(withMediaType:.audio).first
        let a = audio == nil ? nil : c.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        let audioRange = try await audio?.load(.timeRange)
        for entry in p.visibleTimeline where entry.clip.duration > 0 {
            let clip = entry.clip
            let at = CMTime(seconds:entry.start,preferredTimescale:60000)
            if at > cursor {
                // Empty AVComposition segments can hold the previous decoded frame.
                // A stretched carrier frame ensures the filter runs throughout the gap;
                // source-time mapping marks it -1 and the renderer paints it black.
                let frame = CMTime(seconds:min(p.duration,1/max(1,p.fps)),preferredTimescale:60000)
                try v.insertTimeRange(CMTimeRange(start:.zero,duration:frame),of:video,at:cursor)
                v.scaleTimeRange(CMTimeRange(start:cursor,duration:frame),toDuration:at-cursor)
            }
            cursor = at
            let range = CMTimeRange(start:CMTime(seconds:clip.start,preferredTimescale:60000),duration:CMTime(seconds:clip.duration,preferredTimescale:60000))
            try v.insertTimeRange(range,of:video,at:cursor)
            if let audio, let a, let audioRange {
                let overlap = CMTimeRangeGetIntersection(range,otherRange:audioRange)
                if overlap.duration.seconds > 0 { try a.insertTimeRange(overlap,of:audio,at:cursor + (overlap.start-range.start)) }
            }
            cursor = cursor + range.duration
        }
        return c
    }
    static func export(_ p: Project, to destination: URL, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws {
        var prepared = p
        try prepared.repairFaceBounds(); try prepared.validate(); try cancellation.check()
        let p = prepared.projectForExport
        let renderer = MaskRenderer()
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".veil-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at:temporary) }
        if p.isImage {
            let image = try stillImage(URL(fileURLWithPath:p.sourcePath)); let rendered = renderer.render(image,project:p,time:0,crop:true)
            guard let cg = renderer.context.createCGImage(rendered,from:rendered.extent), let target = CGImageDestinationCreateWithURL(temporary as CFURL,p.export.resolvedImageFormat.typeIdentifier as CFString,1,nil) else { throw StudioError.message("이미지 저장을 시작할 수 없습니다.") }
            // Export fresh pixels only: source EXIF/GPS metadata is deliberately omitted.
            CGImageDestinationAddImage(target,cg,[kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
            guard CGImageDestinationFinalize(target) else { throw StudioError.message("이미지 저장에 실패했습니다.") }
        } else {
            guard !p.clips.isEmpty else { throw StudioError.message("내보낼 컷이 없습니다.") }
            let composition = try await composition(for:p)
            let sourceMapping = p.visibleTimeline
            let videoComposition = AVMutableVideoComposition(asset:composition,applyingCIFiltersWithHandler: { request in
                if cancellation.cancelled { request.finish(with:CancellationError()); return }
                let result = renderer.render(request.sourceImage,project:p,time:mappedSourceTime(sourceMapping,at:request.compositionTime.seconds),crop:true,overlayTime:request.compositionTime.seconds)
                request.finish(with:result,context:renderer.context)
            })
            videoComposition.renderSize = p.export.outputSize(p.size)
            videoComposition.frameDuration = CMTime(seconds:1/min(120,p.fps),preferredTimescale:60000)
            guard let session = AVAssetExportSession(asset:composition,presetName:p.export.hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality) else { throw StudioError.message("이 Mac에서 선택한 인코더를 사용할 수 없습니다.") }
            let fileType: AVFileType = p.export.videoFormat == .mov ? .mov : .mp4
            guard session.supportedFileTypes.contains(fileType) else { throw StudioError.message("이 Mac의 인코더가 선택한 영상 형식을 지원하지 않습니다.") }
            session.outputURL = temporary; session.outputFileType = fileType; session.videoComposition = videoComposition; session.shouldOptimizeForNetworkUse = true; session.metadata = []
            let monitor = Task {
                while !Task.isCancelled { if cancellation.cancelled { session.cancelExport(); return }; progress(Double(session.progress),"편집 영상 내보내는 중"); try? await Task.sleep(nanoseconds:200_000_000) }
            }
            await session.export(); monitor.cancel()
            try cancellation.check()
            guard session.status == .completed else { throw session.error ?? StudioError.message("내보내기에 실패했습니다.") }
        }
        try cancellation.check()
        if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:temporary) }
        else { try FileManager.default.moveItem(at:temporary,to:destination) }
        progress(1,"내보내기 완료")
    }
}
