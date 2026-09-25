import AppKit
import AVFoundation
import CoreImage
import Vision

// Pure geometry used for matching detections to tracks (kept separate for testing).
enum FaceAssociation {
    static func iou(_ a: NormalRect, _ b: NormalRect) -> Double {
        let i = a.cg.intersection(b.cg); guard !i.isNull else { return 0 }
        let inter = i.width*i.height
        return inter/max(0.0000001,a.width*a.height+b.width*b.height-inter)
    }
    // Centre distance in units of face size.
    static func distance(_ a: NormalRect, _ b: NormalRect) -> Double {
        let dx = a.center.x-b.center.x, dy = a.center.y-b.center.y
        return sqrt(dx*dx+dy*dy)/max(0.0001,sqrt(max(a.width*a.height,b.width*b.height)))
    }
    static func cost(_ predicted: NormalRect, _ detection: NormalRect) -> Double? {
        let overlap = iou(predicted,detection), d = distance(predicted,detection)
        let ratio = sqrt(detection.width*detection.height)/max(0.0001,sqrt(predicted.width*predicted.height))
        guard ratio > 0.45, ratio < 2.2, overlap >= 0.12 || d <= 0.9 else { return nil }
        return (1-overlap)+0.5*min(2,d)+abs(log(ratio))*0.3
    }
    // Globally cheapest pairs first; each track and detection is used once.
    static func assign(tracks: [NormalRect], detections: [NormalRect]) -> [(track: Int, detection: Int)] {
        var pairs: [(Double,Int,Int)] = []
        for (t,p) in tracks.enumerated() { for (d,r) in detections.enumerated() { if let c = cost(p,r) { pairs.append((c,t,d)) } } }
        var usedT = Set<Int>(), usedD = Set<Int>(); var result: [(Int,Int)] = []
        for (_,t,d) in pairs.sorted(by:{ $0.0 < $1.0 }) where !usedT.contains(t) && !usedD.contains(d) { usedT.insert(t); usedD.insert(d); result.append((t,d)) }
        return result.map { (track:$0.0,detection:$0.1) }
    }
    // Removes duplicate detections (tile results overlapping the full-frame result).
    static func deduplicate(_ boxes: [NormalRect]) -> [NormalRect] {
        var kept: [NormalRect] = []
        for box in boxes.sorted(by:{ $0.width*$0.height > $1.width*$1.height }) {
            let duplicate = kept.contains { old in
                let i = old.cg.intersection(box.cg); guard !i.isNull else { return false }
                return i.width*i.height/max(0.0000001,min(old.width*old.height,box.width*box.height)) > 0.5
            }
            if !duplicate { kept.append(box) }
        }
        return kept
    }
    // Groups track fragments that are probably the same person. Fragments that are on screen
    // at the same time are never grouped, so a group can never hide a second person.
    static func group(spans: [TimelineRange?], distance: (Int,Int) -> Double?, threshold: Double) -> [Int] {
        var parent = Array(spans.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        var members: [Int:[Int]] = Dictionary(uniqueKeysWithValues:spans.indices.map { ($0,[$0]) })
        var candidates: [(Double,Int,Int)] = []
        for a in spans.indices { for b in spans.indices where b > a { if let d = distance(a,b), d < threshold { candidates.append((d,a,b)) } } }
        for (_,a,b) in candidates.sorted(by:{ $0.0 < $1.0 }) {
            let ra = root(a), rb = root(b); guard ra != rb else { continue }
            let clash = (members[ra] ?? []).contains { x in (members[rb] ?? []).contains { y in
                guard let s = spans[x], let t = spans[y] else { return false }
                return min(s.end,t.end)-max(s.start,t.start) > -0.05
            } }
            guard !clash else { continue }
            parent[rb] = ra; members[ra, default:[]] += members[rb] ?? []; members[rb] = nil
        }
        return spans.indices.map(root)
    }
}

enum FaceAnalyzer {
    struct Output { var tracks: [FaceTrack]; var review: [TimelineRange]; var frames: Int }
    static let groupThreshold = 0.42
    static func analyze(source: MediaSource, ranges: [TimelineRange]? = nil, mode: FaceAnalysisMode = .standard, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws -> Output {
        try await Task.detached(priority:.userInitiated) {
            if source.isImage { return try analyzeImage(source:source,cancellation:cancellation,progress:progress) }
            return try await analyzeVideo(source:source,ranges:ranges ?? [TimelineRange(start:0,end:source.duration)],mode:mode,cancellation:cancellation,progress:progress)
        }.value
    }
    static func visionOrientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = atan2(t.b,t.a)*180/Double.pi
        let mirrored = t.a*t.d-t.b*t.c < 0
        switch (Int((angle/90).rounded())+4)%4 {
        case 1: return mirrored ? .leftMirrored : .right
        case 2: return mirrored ? .upMirrored : .down
        case 3: return mirrored ? .rightMirrored : .left
        default: return mirrored ? .upMirrored : .up
        }
    }
    static func detect(_ handler: VNImageRequestHandler, tiles: Bool, tileGrid: Int = 2) throws -> [NormalRect] {
        var requests = [VNDetectFaceRectanglesRequest()]
        var rois: [CGRect] = [CGRect(x:0,y:0,width:1,height:1)]
        if tiles {
            let size = tileGrid == 3 ? 0.45 : 0.6, step = tileGrid == 3 ? 0.275 : 0.4
            for y in 0..<tileGrid { for x in 0..<tileGrid {
                let roi = CGRect(x:Double(x)*step,y:Double(y)*step,width:size,height:size)
                let r = VNDetectFaceRectanglesRequest(); r.regionOfInterest = roi; requests.append(r); rois.append(roi)
            } }
        }
        try handler.perform(requests)
        var boxes: [NormalRect] = []
        for (r,roi) in zip(requests,rois) {
            for face in r.results ?? [] {
                let b = face.boundingBox
                let mapped = CGRect(x:roi.minX+b.minX*roi.width,y:roi.minY+b.minY*roi.height,width:b.width*roi.width,height:b.height*roi.height)
                if let rect = NormalRect(mapped).clippedToImage, rect.width > 0.002, rect.height > 0.002 { boxes.append(rect) }
            }
        }
        return FaceAssociation.deduplicate(boxes)
    }

    // Per-run state. Used from one thread only.
    private final class Builder {
        struct State { var index: Int; var last: NormalRect; var lastTime: Double; var lastDetected: Double; var vx = 0.0; var vy = 0.0; var tracker: VNTrackObjectRequest?; var printTime = -Double.infinity }
        var tracks: [FaceTrack] = []
        var prints: [[VNFeaturePrintObservation]] = []
        var states: [State] = []
        var review: [TimelineRange] = []
        let fps: Double; let size: CGSize; let hold: Double
        let context = CIContext(options:[.cacheIntermediates:false])
        let sequence = VNSequenceRequestHandler()
        init(fps: Double, size: CGSize, hold: Double) { self.fps = fps; self.size = size; self.hold = hold }
        func crop(_ image: CIImage, _ rect: NormalRect, margin: Double, edge: Double) -> CGImage? {
            let r = rect.expanded(margin).scaled(to:size).integral.intersection(CGRect(origin:.zero,size:size))
            guard r.width >= 4, r.height >= 4 else { return nil }
            let scale = min(1,edge/max(r.width,r.height))
            let cropped = image.cropped(to:r).transformed(by:CGAffineTransform(translationX:-r.minX,y:-r.minY)).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            return context.createCGImage(cropped,from:CGRect(x:0,y:0,width:floor(r.width*scale),height:floor(r.height*scale)))
        }
        func featurePrint(_ cg: CGImage?) -> VNFeaturePrintObservation? {
            guard let cg else { return nil }
            let request = VNGenerateImageFeaturePrintRequest(); request.imageCropAndScaleOption = .scaleFill
            try? VNImageRequestHandler(cgImage:cg).perform([request])
            return request.results?.first
        }
        func minDistance(_ a: [VNFeaturePrintObservation], _ b: [VNFeaturePrintObservation]) -> Double? {
            var best: Double?
            for x in a { for y in b { var d: Float = 0; if (try? x.computeDistance(&d,to:y)) != nil { best = min(best ?? .infinity,Double(d)) } } }
            return best
        }
        func process(buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, image: () -> CIImage, time: Double, detections: [NormalRect]) throws {
            let frame = 1/max(1,fps)
            let continuity = max(0.35,4*frame)
            var lazyImage: CIImage?
            func oriented() -> CIImage { if let lazyImage { return lazyImage }; let v = image(); lazyImage = v; return v }
            // 1. Match detections to tracks seen recently, using motion-predicted boxes.
            let active = states.indices.filter { time-states[$0].lastTime <= continuity }
            let predicted = active.map { i -> NormalRect in
                let s = states[i], dt = time-s.lastTime
                var r = s.last; r.x += s.vx*dt; r.y += s.vy*dt; return r
            }
            let pairs = FaceAssociation.assign(tracks:predicted,detections:detections)
            var matchedStates = Set<Int>(), matchedDetections = Set<Int>()
            for pair in pairs {
                let i = active[pair.track], rect = detections[pair.detection]
                append(state:i,rect:rect,time:time,detected:true)
                matchedStates.insert(i); matchedDetections.insert(pair.detection)
                if time-states[i].printTime > 1.0, prints[states[i].index].count < 6, let p = featurePrint(crop(oriented(),rect,margin:0.15,edge:160)) { prints[states[i].index].append(p); states[i].printTime = time }
            }
            // 2. New detections: resume a recently lost track that looks the same, or start a new one.
            for (d,rect) in detections.enumerated() where !matchedDetections.contains(d) {
                let printValue = featurePrint(crop(oriented(),rect,margin:0.15,edge:160))
                var resumed: Int?
                if let printValue {
                    var bestDistance = 0.3
                    for i in states.indices where !matchedStates.contains(i) && time-states[i].lastTime > continuity && time-states[i].lastTime < 5 {
                        if let dist = minDistance([printValue],prints[states[i].index]), dist < bestDistance { bestDistance = dist; resumed = i }
                    }
                }
                if let i = resumed {
                    append(state:i,rect:rect,time:time,detected:true); matchedStates.insert(i)
                } else {
                    var thumb: Data?
                    if let cg = crop(oriented(),rect,margin:0.45,edge:180) { thumb = NSBitmapImageRep(cgImage:cg).representation(using:.jpeg,properties:[.compressionFactor:0.8]) }
                    tracks.append(FaceTrack(name:"인물 후보 \(tracks.count+1)",thumbnail:thumb,samples:[FaceSample(time:time,rect:rect)]))
                    prints.append(printValue.map { [$0] } ?? [])
                    states.append(State(index:tracks.count-1,last:rect,lastTime:time,lastDetected:time,printTime:printValue == nil ? -Double.infinity : time))
                    matchedStates.insert(states.count-1)
                }
            }
            // 3. Tracks the detector lost this frame: follow them with the object tracker for a short time.
            var requests: [(Int,VNTrackObjectRequest)] = []
            for i in active where !matchedStates.contains(i) && time-states[i].lastDetected <= hold {
                if states[i].tracker == nil {
                    guard requests.count+states.filter({ $0.tracker != nil }).count < 10 else { continue }
                    let seed = VNDetectedObjectObservation(boundingBox:states[i].last.cg)
                    let request = VNTrackObjectRequest(detectedObjectObservation:seed); request.trackingLevel = .accurate
                    states[i].tracker = request
                }
                if let request = states[i].tracker { requests.append((i,request)) }
            }
            if !requests.isEmpty {
                do { try sequence.perform(requests.map(\.1),on:buffer,orientation:orientation) }
                catch { for (i,_) in requests { states[i].tracker = nil }; requests = [] }
                for (i,request) in requests {
                    guard let result = request.results?.first as? VNDetectedObjectObservation, result.confidence >= 0.35,
                          let rect = NormalRect(result.boundingBox).clippedToImage else { states[i].tracker = nil; continue }
                    let base = states[i].last, grow = (rect.width*rect.height)/max(0.0000001,base.width*base.height)
                    guard grow > 0.35, grow < 2.8, FaceAssociation.distance(base,rect) < 1.5 else { states[i].tracker = nil; continue }
                    request.inputObservation = result
                    append(state:i,rect:rect,time:time,detected:false)
                }
            }
            for i in states.indices where states[i].tracker != nil && time-states[i].lastDetected > hold { states[i].tracker = nil }
        }
        private func append(state i: Int, rect: NormalRect, time: Double, detected: Bool) {
            let dt = time-states[i].lastTime
            if detected, dt > 0.0001, dt < 0.6 {
                // Smoothed velocity keeps predictions steady through short misses.
                let vx = (rect.center.x-states[i].last.center.x)/dt, vy = (rect.center.y-states[i].last.center.y)/dt
                states[i].vx = states[i].vx*0.6+vx*0.4; states[i].vy = states[i].vy*0.6+vy*0.4
            }
            if detected { states[i].lastDetected = time; states[i].tracker = nil }
            states[i].last = rect; states[i].lastTime = time
            let t = states[i].index
            if let last = tracks[t].samples.last, time <= last.time { return }
            tracks[t].samples.append(FaceSample(time:time,rect:rect,predicted:!detected))
        }
        // Person-level grouping and spans worth a second look.
        func finish(bridge: Double) -> [FaceTrack] {
            // Tracks made only of tracker guesses are dropped: nothing was ever detected there.
            let keep = tracks.indices.filter { tracks[$0].detectedCount > 0 }
            var result = keep.map { tracks[$0] }; let keptPrints = keep.map { prints[$0] }
            let spans = result.map { $0.span }
            let groups = FaceAssociation.group(spans:spans,distance:{ a,b in self.minDistance(keptPrints[a],keptPrints[b]) },threshold:FaceAnalyzer.groupThreshold)
            // Name persons in order of first appearance; a group shares one id and name.
            var order: [Int] = []
            for i in result.indices.sorted(by:{ (result[$0].samples.first?.time ?? 0) < (result[$1].samples.first?.time ?? 0) }) where !order.contains(groups[i]) { order.append(groups[i]) }
            var ids: [Int:UUID] = [:]
            for (n,g) in order.enumerated() { ids[g] = UUID(); let name = "인물 \(n+1)"; for i in result.indices where groups[i] == g { result[i].name = name } }
            for i in result.indices { result[i].group = ids[groups[i]] }
            // Unbridged gaps where the face stayed in roughly the same place: probably missed frames.
            for t in result {
                for (a,b) in zip(t.samples,t.samples.dropFirst()) where b.time-a.time > max(bridge,0.3) && b.time-a.time < 8 && FaceAssociation.distance(a.rect,b.rect) < 3 {
                    review.append(TimelineRange(start:a.time,end:b.time))
                }
            }
            return result.sorted { ($0.samples.first?.time ?? 0) < ($1.samples.first?.time ?? 0) }
        }
        // A body that is still on screen where a face track just ended.
        func checkBodies(_ bodies: [NormalRect], time: Double, bridge: Double) {
            for body in bodies {
                let head = NormalRect(x:body.x,y:body.y+body.height*0.45,width:body.width,height:body.height*0.55)
                let vanished = states.contains { s in
                    time-s.lastTime > max(0.25,bridge*0.5) && time-s.lastTime < 2 && head.cg.contains(s.last.center)
                }
                let covered = states.contains { s in abs(time-s.lastTime) <= 0.2 && head.cg.intersects(s.last.cg) }
                if vanished && !covered { review.append(TimelineRange(start:max(0,time-0.5),end:time+0.5)) }
            }
        }
    }

    private static func analyzeVideo(source: MediaSource, ranges: [TimelineRange], mode: FaceAnalysisMode, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) async throws -> Output {
        let asset = AVURLAsset(url:URL(fileURLWithPath:source.path),options:[AVURLAssetPreferPreciseDurationAndTimingKey:true])
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw StudioError.message("분석할 영상 트랙이 없습니다: \(source.name)") }
        let transform = try await track.load(.preferredTransform), natural = try await track.load(.naturalSize)
        let geometry = orientedTransform(transform,natural:natural)
        let orientation = visionOrientation(transform)
        let fps = max(1,Double(try await track.load(.nominalFrameRate)))
        let clean = TimelineRange.merged(ranges.map { TimelineRange(start:max(0,$0.start),end:min(source.duration,$0.end)) })
        let total = clean.reduce(0) { $0+$1.duration }
        guard total > 0 else { throw StudioError.message("분석할 영상 구간이 없습니다.") }
        let builder = Builder(fps:fps,size:geometry.size,hold:1.5)
        let stride = mode == .fast ? 2 : 1
        let tiles = mode == .precise
        var completed = 0.0, frames = 0, counter = 0
        var lastBodyCheck = -Double.infinity
        for range in clean {
            try cancellation.check()
            let reader = try AVAssetReader(asset:asset)
            reader.timeRange = CMTimeRange(start:CMTime(seconds:range.start,preferredTimescale:60000),duration:CMTime(seconds:range.duration,preferredTimescale:60000))
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw StudioError.message("이 영상 코덱은 분석할 수 없습니다: \(source.name)") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? StudioError.message("영상 읽기를 시작하지 못했습니다.") }
            defer { if reader.status == .reading { reader.cancelReading() } }
            var lastProgress = -1.0
            while let sample = output.copyNextSampleBuffer() {
                try cancellation.check()
                try autoreleasepool {
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard time.isFinite, time >= range.start, time < range.end else { return }
                    counter += 1; guard counter % stride == 0 else { return }
                    let handler = VNImageRequestHandler(cvPixelBuffer:buffer,orientation:orientation,options:[:])
                    let detections = try detect(handler,tiles:tiles)
                    try builder.process(buffer:buffer,orientation:orientation,image:{
                        let raw = CIImage(cvPixelBuffer:buffer).transformed(by:geometry.transform)
                        return raw.transformed(by:CGAffineTransform(translationX:-raw.extent.minX,y:-raw.extent.minY))
                    },time:time,detections:detections)
                    frames += 1
                    if time-lastBodyCheck >= 0.5 {
                        lastBodyCheck = time
                        let body = VNDetectHumanRectanglesRequest(); body.upperBodyOnly = true
                        if (try? handler.perform([body])) != nil {
                            builder.checkBodies((body.results ?? []).compactMap { NormalRect($0.boundingBox).clippedToImage },time:time,bridge:1)
                        }
                    }
                    if time-lastProgress >= 0.25 {
                        lastProgress = time
                        progress(min(0.99,(completed+time-range.start)/total),"\(source.name) · 얼굴 분석 \(timecode(completed+time-range.start)) / \(timecode(total)) · 후보 \(builder.tracks.count)")
                    }
                }
            }
            if reader.status == .failed { throw reader.error ?? StudioError.message("영상 분석 중 읽기 오류가 발생했습니다.") }
            completed += range.duration
        }
        try cancellation.check()
        progress(0.995,"\(source.name) · 인물 묶는 중")
        let tracks = builder.finish(bridge:1)
        progress(1,"얼굴 분석 완료")
        return Output(tracks:tracks,review:TimelineRange.merged(builder.review),frames:frames)
    }
    private static func analyzeImage(source: MediaSource, cancellation: Cancellation, progress: @escaping (Double,String) -> Void) throws -> Output {
        let full = try MediaEngine.stillImage(URL(fileURLWithPath:source.path))
        let scale = min(1,2400/max(full.extent.width,full.extent.height))
        let small = full.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let context = CIContext(options:[.cacheIntermediates:false])
        guard let cg = context.createCGImage(small,from:small.extent) else { throw StudioError.message("분석 이미지를 읽지 못했습니다.") }
        try cancellation.check()
        let boxes = try detect(VNImageRequestHandler(cgImage:cg),tiles:true,tileGrid:3)
        let image = CIImage(cgImage:cg)
        var tracks: [FaceTrack] = []
        for rect in boxes.sorted(by:{ $0.x < $1.x }) {
            try cancellation.check()
            let r = rect.expanded(0.45).scaled(to:image.extent.size).integral.intersection(image.extent)
            var thumb: Data?
            if r.width >= 4, r.height >= 4, let face = context.createCGImage(image,from:r) { thumb = NSBitmapImageRep(cgImage:face).representation(using:.jpeg,properties:[.compressionFactor:0.8]) }
            tracks.append(FaceTrack(name:"인물 후보 \(tracks.count+1)",thumbnail:thumb,samples:[FaceSample(time:0,rect:rect)]))
        }
        progress(1,"얼굴 분석 완료")
        return Output(tracks:tracks,review:[],frames:1)
    }
}
