import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum MediaEngine {
    // Reads one file into a media item without changing any project.
    static func probe(_ url: URL) async throws -> MediaSource {
        let info = try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.isRegularFileKey])
        guard info.isRegularFile != false else { throw StudioError.message("파일이 아닙니다: \(url.lastPathComponent)") }
        var m = MediaSource(); m.path = url.path; m.fileSize = Int64(info.fileSize ?? 0); m.modified = info.contentModificationDate
        if let source = CGImageSourceCreateWithURL(url as CFURL,nil), CGImageSourceGetCount(source) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Double, let h = properties[kCGImagePropertyPixelHeight] as? Double {
            guard w*h <= 120_000_000 else { throw StudioError.message("이미지는 최대 1억 2천만 화소까지 지원합니다. 먼저 크기를 줄여 주세요: \(url.lastPathComponent)") }
            guard CGImageSourceGetCount(source) == 1 else { throw StudioError.message("애니메이션·다중 페이지 이미지는 현재 지원하지 않습니다. 단일 프레임 PNG/JPEG로 변환해 주세요: \(url.lastPathComponent)") }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            m.kind = .image; m.hasAudio = false; m.width = (5...8).contains(orientation) ? h : w; m.height = (5...8).contains(orientation) ? w : h
            return m
        }
        let asset = AVURLAsset(url:url,options:[AVURLAssetPreferPreciseDurationAndTimingKey:true])
        let videos = try await asset.loadTracks(withMediaType:.video), audios = try await asset.loadTracks(withMediaType:.audio)
        m.duration = try await asset.load(.duration).seconds
        guard m.duration.isFinite, m.duration > 0 else { throw StudioError.message("영상·오디오 길이를 읽을 수 없습니다: \(url.lastPathComponent)") }
        m.hasAudio = !audios.isEmpty
        if let track = videos.first {
            let size = try await track.load(.naturalSize); let transform = try await track.load(.preferredTransform)
            let oriented = orientedTransform(transform,natural:size)
            m.width = oriented.size.width; m.height = oriented.size.height; m.fps = max(1,Double(try await track.load(.nominalFrameRate)))
            guard m.width > 0, m.height > 0 else { throw StudioError.message("영상 크기를 읽을 수 없습니다: \(url.lastPathComponent)") }
            guard (try? await track.load(.isDecodable)) ?? true else { throw StudioError.message("이 Mac에서 해독할 수 없는 영상 코덱입니다: \(url.lastPathComponent). MP4(H.264/HEVC)나 MOV로 변환해 주세요.") }
            m.kind = .video
        } else if !audios.isEmpty { m.kind = .audio; m.width = 0; m.height = 0 }
        else { throw StudioError.message("읽을 수 있는 영상·이미지·오디오가 아닙니다: \(url.lastPathComponent). MP4, MOV, M4A, JPEG, PNG, HEIC 등을 사용해 주세요.") }
        return m
    }
    // Opens a file as a new project (a photo project for images).
    static func load(_ url: URL) async throws -> Project {
        let m = try await probe(url)
        var p = Project(); p.media = [m]
        switch m.kind {
        case .image: p.isImage = true; p.width = m.width; p.height = m.height
        case .video: p.width = m.width; p.height = m.height; p.fps = m.fps; p.clips = [Clip(start:0,end:m.duration)]
        case .audio: p.width = 1920; p.height = 1080; p.fps = 30; p.audioClips = [AudioClip(source:m.id,start:0,end:m.duration,position:0)]
        }
        try p.validate(); return p
    }
    static func stillImage(_ url: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf:url,options:[.applyOrientationProperty:true]) else { throw StudioError.message("이미지를 읽을 수 없습니다: \(url.lastPathComponent)") }
        return image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
    }
    // First-media analysis over the ranges used on the timeline (kept for single-source callers).
    static func analyze(_ project: Project, mode: FaceAnalysisMode = .standard, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws -> [FaceTrack] {
        guard let source = project.primary else { return [] }
        if source.isImage { return try await FaceAnalyzer.analyze(source:source,mode:mode,cancellation:cancellation,progress:progress).tracks }
        let ranges = project.analysisRanges
        guard !ranges.isEmpty else { throw StudioError.message("분석할 영상 컷이 없습니다.") }
        return try await FaceAnalyzer.analyze(source:source,ranges:ranges,mode:mode,cancellation:cancellation,progress:progress).tracks
    }
    // Rough upper bound of the encoded size, used to refuse exports that cannot fit on disk.
    static func estimatedBytes(_ p: Project) -> Int64 {
        let size = p.export.outputSize(p.size)
        let bitsPerPixel = p.export.hevc ? 0.18 : 0.3
        let video = size.width*size.height*min(120,max(1,p.fps))*bitsPerPixel/8*p.exportDuration
        return Int64(video+p.exportDuration*40_000)+50_000_000
    }
    static func ensureDiskSpace(for p: Project, at destination: URL) throws {
        guard !p.isImage, let values = try? destination.deletingLastPathComponent().resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return }
        let needed = estimatedBytes(p)*11/10
        if free < needed {
            throw StudioError.message("저장 위치의 여유 공간이 부족할 수 있습니다. 필요 예상 \(ByteCountFormatter.string(fromByteCount:needed,countStyle:.file)), 남은 공간 \(ByteCountFormatter.string(fromByteCount:free,countStyle:.file)). 다른 디스크를 선택하거나 공간을 확보해 주세요.")
        }
    }
    static func export(_ p: Project, to destination: URL, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws {
        var prepared = p
        try prepared.repairFaceBounds(); try prepared.validate(); try cancellation.check()
        try ensureDiskSpace(for:prepared,at:destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".veil-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at:temporary) }
        let renderer = MaskRenderer()
        if prepared.isImage {
            let p = prepared.projectForExport
            let image = try stillImage(URL(fileURLWithPath:p.sourcePath)); let rendered = renderer.render(image,project:p,time:0,crop:true)
            guard let cg = renderer.context.createCGImage(rendered,from:rendered.extent), let target = CGImageDestinationCreateWithURL(temporary as CFURL,p.export.resolvedImageFormat.typeIdentifier as CFString,1,nil) else { throw StudioError.message("이미지 저장을 시작할 수 없습니다.") }
            // Export fresh pixels only: source EXIF/GPS metadata is deliberately omitted.
            CGImageDestinationAddImage(target,cg,[kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
            guard CGImageDestinationFinalize(target) else { throw StudioError.message("이미지 저장에 실패했습니다.") }
        } else {
            // Legacy source-time overlays are placed on the timeline once before rendering.
            if prepared.overlaysOnTimeline != true { prepared.migrateOverlayTimeline() }
            guard !prepared.clips.isEmpty || !prepared.audioClips.isEmpty else { throw StudioError.message("내보낼 컷이 없습니다.") }
            progress(0,"합성 준비 중")
            let built = try await CompositionBuilder.buildTimeline(prepared,muted:prepared.export.muted,allowMissing:false)
            try cancellation.check()
            let (video,_) = CompositionBuilder.videoComposition(built,project:prepared,purpose:.export,renderer:renderer,cancellation:cancellation,stills:StillCache())
            guard let session = AVAssetExportSession(asset:built.composition,presetName:prepared.export.hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality) else { throw StudioError.message("이 Mac에서 선택한 인코더를 사용할 수 없습니다.") }
            let fileType: AVFileType = prepared.export.videoFormat == .mov ? .mov : .mp4
            guard session.supportedFileTypes.contains(fileType) else { throw StudioError.message("이 Mac의 인코더가 선택한 영상 형식을 지원하지 않습니다.") }
            session.outputURL = temporary; session.outputFileType = fileType; session.videoComposition = video; session.shouldOptimizeForNetworkUse = true; session.metadata = []
            session.audioMix = CompositionBuilder.audioMix(built,project:prepared); session.audioTimePitchAlgorithm = .spectral
            if let range = prepared.exportRange {
                session.timeRange = CMTimeRange(start:tickTime(ticks(range.start)),end:tickTime(min(built.totalTicks,ticks(range.end))))
            }
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
