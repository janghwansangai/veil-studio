import Foundation
import AVFoundation
import AppKit
import CoreImage
#if !VEIL_STANDALONE_TESTS
import XCTest
@testable import VeilStudio
#endif

// v0.8: multi-source editing, compositor effects, face tracking helpers, speech, batch queue.
extension EditorTests {
    func tempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veil-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); return dir
    }
    // Solid-colour clip of any size, optional transform and frame count.
    func makeSolidVideo(_ url: URL, width: Int, height: Int, color: CIColor, frames: Int = 30, transform: CGAffineTransform = .identity) async throws {
        let writer = try AVAssetWriter(outputURL:url,fileType:.mov)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height]); input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height])
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? StudioError.message("writer") }; writer.startSession(atSourceTime:.zero)
        let context = CIContext()
        for n in 0..<frames {
            let started = Date()
            while !input.isReadyForMoreMediaData { if Date().timeIntervalSince(started) > 10 { throw StudioError.message("writer timeout") }; try await Task.sleep(nanoseconds:1_000_000) }
            var buffer: CVPixelBuffer?; guard let pool = adaptor.pixelBufferPool else { throw StudioError.message("pool") }; CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)
            guard let buffer else { throw StudioError.message("buffer") }
            context.render(CIImage(color:color).cropped(to:CGRect(x:0,y:0,width:width,height:height)),to:buffer)
            adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(n),timescale:30))
        }
        input.markAsFinished(); await writer.finishWriting()
    }
    func makeTone(_ url: URL, seconds: Double = 2, amplitude: Double = 0.2) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:1)!
        let frames = AVAudioFrameCount(44100*seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames)!; buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i)*2*Double.pi*440/44100)*amplitude) }
        let file = try AVAudioFile(forWriting:url,settings:format.settings); try file.write(from:buffer)
    }
    func frame(_ url: URL, at seconds: Double) async throws -> CIImage {
        let g = AVAssetImageGenerator(asset:AVURLAsset(url:url)); g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        return CIImage(cgImage:try await g.image(at:CMTime(seconds:seconds,preferredTimescale:600)).image)
    }
    func greenShare(_ image: CIImage, rows: ClosedRange<Double>, context: CIContext) -> Double {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var count = 0, total = 0
        for y in stride(from:Int(Double(h)*rows.lowerBound),to:Int(Double(h)*rows.upperBound),by:4) { for x in stride(from:0,to:w,by:4) {
            let p = pixel(image,x,y,context:context); total += 1; if p[1] > 150 && p[0] < 100 { count += 1 }
        } }
        return Double(count)/Double(max(1,total))
    }

    func testOrientationMatchesSystemPlayer() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at:dir) }
        let context = CIContext()
        // Both quarter turns: the green band must land where AVFoundation's own player shows it.
        for (n,t) in [CGAffineTransform(a:0,b:1,c:-1,d:0,tx:180,ty:0),CGAffineTransform(a:0,b:-1,c:1,d:0,tx:0,ty:320)].enumerated() {
            let source = dir.appendingPathComponent("rot\(n).mov"); try await makeVideo(source,transform:t)
            let truth = try await frame(source,at:0.2)
            var p = try await MediaEngine.load(source); p.export.resolution = .original
            XCTAssertEqual(p.width,180); XCTAssertEqual(p.height,320)
            let out = dir.appendingPathComponent("rot\(n).mp4"); try await MediaEngine.export(p,to:out,cancellation:Cancellation(),progress:{_,_ in})
            let ours = try await frame(out,at:0.2)
            let truthTop = greenShare(truth,rows:0.75...1,context:context), truthBottom = greenShare(truth,rows:0...0.25,context:context)
            let oursTop = greenShare(ours,rows:0.75...1,context:context), oursBottom = greenShare(ours,rows:0...0.25,context:context)
            XCTAssertTrue(abs(truthTop-truthBottom) > 0.3)
            XCTAssertEqual(truthTop > truthBottom,oursTop > oursBottom)
            XCTAssertEqual(oursTop,truthTop,accuracy:0.15)
        }
    }

    func testMultiSourceSpeedFreezeTransitionAndLayers() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at:dir) }
        let context = CIContext()
        let a = dir.appendingPathComponent("a.mov"); try await makeVideo(a)                       // 2 s: red then blue, green band left
        let b = dir.appendingPathComponent("b.mov"); try await makeSolidVideo(b,width:180,height:320,color:CIColor(red:1,green:1,blue:0))
        var p = try await MediaEngine.load(a)
        let second = try await MediaEngine.probe(b); p.media.append(second); p.normalizeSources()
        let aID = p.media[0].id
        // Multi-source + letterboxing of a portrait clip in a landscape canvas.
        p.clips = [Clip(start:0,end:1,source:aID),Clip(start:0,end:1,source:second.id)]
        p.export.resolution = .original; p.overlaysOnTimeline = true
        var out = dir.appendingPathComponent("multi.mp4"); try await MediaEngine.export(p,to:out,cancellation:Cancellation(),progress:{_,_ in})
        var img = try await frame(out,at:1.5)
        XCTAssertGreaterThan(pixel(img,160,90,context:context)[0],200); XCTAssertGreaterThan(pixel(img,160,90,context:context)[1],200)
        XCTAssertLessThan(pixel(img,20,90,context:context)[0],30)
        XCTAssertEqual(try await MediaEngine.load(out).duration,2,accuracy:0.08)
        // Speed: 2 s of source at 200 % lasts 1 s.
        p.clips = [Clip(start:0,end:2,source:aID,speed:2)]
        out = dir.appendingPathComponent("speed.mp4"); try await MediaEngine.export(p,to:out,cancellation:Cancellation(),progress:{_,_ in})
        XCTAssertEqual(try await MediaEngine.load(out).duration,1,accuracy:0.08)
        XCTAssertGreaterThan(pixel(try await frame(out,at:0.25),250,90,context:context)[0],190)
        XCTAssertGreaterThan(pixel(try await frame(out,at:0.75),250,90,context:context)[2],190)
        // Freeze frame holds the red picture for its length.
        p.clips = [Clip(start:0,end:0.5,source:aID),Clip(start:0.4,end:0.4+1/30,source:aID,freeze:1),Clip(start:1.5,end:2,source:aID)]
        XCTAssertEqual(p.editedDuration,2,accuracy:0.001)
        out = dir.appendingPathComponent("freeze.mp4"); try await MediaEngine.export(p,to:out,cancellation:Cancellation(),progress:{_,_ in})
        XCTAssertEqual(try await MediaEngine.load(out).duration,2,accuracy:0.08)
        XCTAssertGreaterThan(pixel(try await frame(out,at:1.2),250,90,context:context)[0],190)
        XCTAssertGreaterThan(pixel(try await frame(out,at:1.8),250,90,context:context)[2],190)
        // Cross dissolve: the second clip overlaps the first; halfway shows both colours.
        p.clips = [Clip(start:0,end:1,source:aID),Clip(start:1,end:2,source:aID,transition:Transition(kind:.dissolve,duration:0.5))]
        XCTAssertEqual(p.editedDuration,1.5,accuracy:0.001); XCTAssertEqual(p.timeline[1].overlap,0.5,accuracy:0.001)
        out = dir.appendingPathComponent("dissolve.mp4"); try await MediaEngine.export(p,to:out,cancellation:Cancellation(),progress:{_,_ in})
        let mid = pixel(try await frame(out,at:0.75),250,90,context:context)
        XCTAssertGreaterThan(mid[0],60); XCTAssertLessThan(mid[0],200); XCTAssertGreaterThan(mid[2],60); XCTAssertLessThan(mid[2],200)
        XCTAssertGreaterThan(pixel(try await frame(out,at:0.3),250,90,context:context)[0],190)
        XCTAssertGreaterThan(pixel(try await frame(out,at:1.3),250,90,context:context)[2],190)
        // Picture-in-picture on an upper lane, colour grade and a title.
        p.videoLaneCount = 2
        var pip = Clip(start:0,end:1,lane:1,position:0,source:second.id); pip.transform = ClipTransform(scale:0.5,x:0.25,y:0)
        var base = Clip(start:0,end:1,lane:0,position:0,source:aID); base.color = ColorAdjust(saturation:0)
        p.clips = [base,pip]
        p.titles = [TitleItem(text:"TITLE",start:0,end:1,x:0.5,y:0.2,size:0.2)]
        out = dir.appendingPathComponent("layers.mp4"); try await MediaEngine.export(p,to:out,cancellation:Cancellation(),progress:{_,_ in})
        img = try await frame(out,at:0.5)
        let grey = pixel(img,110,120,context:context); XCTAssertLessThan(abs(Int(grey[0])-Int(grey[2])),30)   // red desaturated
        let inset = pixel(img,240,90,context:context); XCTAssertGreaterThan(inset[0],200); XCTAssertGreaterThan(inset[1],200)  // yellow PiP right of centre
        var bright = 0
        for x in stride(from:100,to:220,by:2) { for y in stride(from:20,to:55,by:2) { let v = pixel(img,x,y,context:context); if v[0] > 220 && v[1] > 220 && v[2] > 220 { bright += 1 } } }
        XCTAssertGreaterThan(bright,15)
    }

    func testIndependentAudioAndVolume() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at:dir) }
        let video = dir.appendingPathComponent("v.mov"); try await makeVideo(video)
        let tone = dir.appendingPathComponent("tone.caf"); try makeTone(tone)
        var p = try await MediaEngine.load(video); p.export.resolution = .original
        let music = try await MediaEngine.probe(tone); XCTAssertEqual(music.kind,.audio)
        p.media.append(music); p.normalizeSources()
        p.audioClips = [AudioClip(source:music.id,start:0,end:2,position:0,fadeIn:0.5,fadeOut:0.5)]
        try p.validate()
        let out = dir.appendingPathComponent("music.mp4"); try await MediaEngine.export(p,to:out,cancellation:Cancellation(),progress:{_,_ in})
        XCTAssertEqual(try await AVURLAsset(url:out).loadTracks(withMediaType:.audio).count,1)
        p.audioClips[0].volume = 0
        let silent = dir.appendingPathComponent("silent.mp4"); try await MediaEngine.export(p,to:silent,cancellation:Cancellation(),progress:{_,_ in})
        XCTAssertEqual(try await AVURLAsset(url:silent).loadTracks(withMediaType:.audio).count,0)
        // Music longer than the picture extends the programme with black frames.
        p.audioClips = [AudioClip(source:music.id,start:0,end:2,position:1)]
        XCTAssertEqual(p.editedDuration,3,accuracy:0.001)
        let longer = dir.appendingPathComponent("longer.mp4"); try await MediaEngine.export(p,to:longer,cancellation:Cancellation(),progress:{_,_ in})
        XCTAssertEqual(try await MediaEngine.load(longer).duration,3,accuracy:0.1)
    }

    func testTimelineSpeedTransitionEditing() throws {
        var p = timelineProject()
        p.clips = [Clip(start:0,end:4,speed:2),Clip(start:5,end:7)]
        XCTAssertEqual(p.editedDuration,4); XCTAssertEqual(p.sourceTime(for:1),2); XCTAssertEqual(p.sourceTime(for:2.5),5.5)
        let id = p.splitTimeline(at:1)
        XCTAssertNotNil(id); XCTAssertEqual(p.clips[0].end,2); XCTAssertEqual(p.clips[1].start,2); XCTAssertEqual(p.clips[1].speed,2)
        XCTAssertEqual(p.editedDuration,4)
        // A split inside a transition is refused rather than changing the blend.
        p.clips = [Clip(start:0,end:2),Clip(start:5,end:7,transition:Transition(duration:1))]
        XCTAssertEqual(p.editedDuration,3)
        XCTAssertNil(p.splitTimeline(at:1.5))
        XCTAssertNotNil(p.splitTimeline(at:2.5))
        // Ripple range delete keeps the transition when it survives intact.
        p.clips = [Clip(start:0,end:2),Clip(start:5,end:7,transition:Transition(duration:1)),Clip(start:8,end:10)]
        p.deleteTimelineRange(TimelineRange(start:3.5,end:4))
        XCTAssertEqual(p.editedDuration,4.5,accuracy:0.0001); XCTAssertNotNil(p.clips[1].transition)
        // Positioned clips may overlap only as far as a transition allows.
        p.videoLaneCount = 2; p.clips = [Clip(start:0,end:2,lane:0,position:0),Clip(start:0,end:2,lane:0,position:1.6)]
        XCTAssertNotNil(p.positionedCollision)
        p.clips[1].transition = Transition(duration:0.5); XCTAssertNil(p.positionedCollision); XCTAssertEqual(p.timeline[1].overlap,0.4,accuracy:0.0001)
        XCTAssertNoThrow(try p.validate())
        p.clips[0].speed = 99; XCTAssertThrowsError(try p.validate())
    }

    func testProjectV2CodingAndLegacyMigration() throws {
        var p = timelineProject(); p.sourcePath = "/tmp/a.mov"
        var track = FaceTrack(name:"A",samples:(0..<500).map { FaceSample(time:Double($0)/30,rect:NormalRect(x:0.1,y:0.2,width:0.1,height:0.15),predicted:$0 % 7 == 0) })
        track.group = UUID(); p.faces = [track]
        p.titles = [TitleItem(text:"t",start:1,end:2)]; p.markers = [Marker(time:3)]
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Project.self,from:data)
        XCTAssertEqual(decoded,p)
        XCTAssertEqual(decoded.faces[0].samples.filter(\.predicted).count,track.samples.filter(\.predicted).count)
        // Packed samples are much smaller than the v1 array of objects.
        let legacyFaces = try JSONEncoder().encode(track.samples.map { ["time":$0.time,"x":$0.rect.x,"y":$0.rect.y,"width":$0.rect.width,"height":$0.rect.height] })
        XCTAssertLessThan(data.count,legacyFaces.count)
        // A v1 file: single source at the top level.
        let v1: [String:Any] = ["version":1,"sourcePath":"/tmp/old.mov","fileSize":10,"isImage":false,"duration":10,"width":1920,"height":1080,"fps":30,
                                "faces":[["id":UUID().uuidString,"name":"F","selected":true,"samples":[["time":1,"rect":["x":0.1,"y":0.1,"width":0.2,"height":0.2]]]]],
                                "regions":[],"captions":[["id":UUID().uuidString,"start":1,"end":2,"text":"자막"]],"clips":[["id":UUID().uuidString,"start":0,"end":10]],
                                "design":["effect":"모자이크","shape":"타원","strength":0.65,"margin":0.35,"red":0.3,"green":0.33,"blue":0.94,"sticker":"🙂"],
                                "export":["ratio":"원본","resolution":"Full HD · 1080p","cropX":0.5,"cropY":0.5,"hevc":false,"muted":false,"burnCaptions":true,"captionSize":0.045,"jpeg":false],
                                "maskApplied":true,"analysisComplete":true]
        let old = try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:v1))
        XCTAssertEqual(old.version,Project.currentVersion); XCTAssertEqual(old.media.count,1); XCTAssertEqual(old.sourcePath,"/tmp/old.mov")
        XCTAssertEqual(old.faces.count,1); XCTAssertEqual(old.faces[0].samples.count,1); XCTAssertTrue(old.maskApplied); XCTAssertEqual(old.captions.count,1)
        XCTAssertNoThrow(try old.validate())
        var future = v1; future["version"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:future)))
        // The user's saved v0.x projects, when present, open with every face sample intact.
        let folder = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output")
        let files = ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).filter { $0.pathExtension == "veilproject" }
        for file in files {
            let raw = try Data(contentsOf:file)
            let json = try JSONSerialization.jsonObject(with:raw) as? [String:Any] ?? [:]
            let faces = json["faces"] as? [[String:Any]] ?? []
            let samples = faces.reduce(0) { $0+(($1["samples"] as? [Any])?.count ?? 0) }
            var project = try JSONDecoder().decode(Project.self,from:raw)
            XCTAssertEqual(project.faces.count,faces.count); XCTAssertEqual(project.faces.reduce(0) { $0+$1.samples.count },samples)
            XCTAssertEqual(project.captions.count,(json["captions"] as? [Any])?.count ?? 0)
            _ = try project.repairFaceBounds(); project.repairEditableTimes(); XCTAssertNoThrow(try project.validate())
            let again = try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project)); XCTAssertEqual(again,project)
        }
        if !files.isEmpty { print("Migrated \(files.count) saved projects") }
    }

    func testFaceAssociationGroupingAndBridging() {
        let a = NormalRect(x:0.1,y:0.1,width:0.1,height:0.1), b = NormalRect(x:0.12,y:0.1,width:0.1,height:0.1), far = NormalRect(x:0.7,y:0.7,width:0.1,height:0.1)
        XCTAssertGreaterThan(FaceAssociation.iou(a,b),0.6); XCTAssertEqual(FaceAssociation.iou(a,far),0)
        let pairs = FaceAssociation.assign(tracks:[a,far],detections:[NormalRect(x:0.71,y:0.7,width:0.1,height:0.1),b])
        XCTAssertEqual(pairs.count,2); XCTAssertTrue(pairs.contains { $0.track == 0 && $0.detection == 1 }); XCTAssertTrue(pairs.contains { $0.track == 1 && $0.detection == 0 })
        XCTAssertTrue(FaceAssociation.assign(tracks:[a],detections:[far]).isEmpty)
        XCTAssertEqual(FaceAssociation.deduplicate([a,b,far]).count,2)
        // Fragments seen at the same time are never grouped, however similar they look.
        let spans: [TimelineRange?] = [TimelineRange(start:0,end:2),TimelineRange(start:1,end:3),TimelineRange(start:4,end:5)]
        let groups = FaceAssociation.group(spans:spans,distance:{ _,_ in 0.1 },threshold:0.4)
        XCTAssertNotEqual(groups[0],groups[1]); XCTAssertTrue(groups[2] == groups[0] || groups[2] == groups[1])
        XCTAssertEqual(Set(FaceAssociation.group(spans:spans,distance:{ _,_ in 0.9 },threshold:0.4)).count,3)
        // Missed detections are bridged only when the face stays nearby.
        let track = FaceTrack(name:"t",samples:[FaceSample(time:0,rect:a),FaceSample(time:0.8,rect:b),FaceSample(time:1.4,rect:far)])
        XCTAssertNotNil(track.rect(at:0.4,bridge:1)); XCTAssertNil(track.rect(at:0.4))
        XCTAssertNil(track.rect(at:1.1,bridge:1))
        XCTAssertNotNil(track.rect(at:1.6,hold:0.25)); XCTAssertNil(track.rect(at:1.8,hold:0.25))
        XCTAssertEqual(FaceAnalyzer.visionOrientation(CGAffineTransform(a:0,b:1,c:-1,d:0,tx:0,ty:0)),.right)
        XCTAssertEqual(FaceAnalyzer.visionOrientation(.identity),.up)
    }

    func testCaptionSegmenterAndTimelineMapping() {
        var words: [RecognizedWord] = []
        let text = "오늘은 우리 반 친구들과 함께 과학 실험을 했습니다. 선생님께서 이유를 설명해 주셨어요."
        for (i,w) in text.split(separator:" ").enumerated() { words.append(RecognizedWord(text:String(w),start:Double(i)*0.4,end:Double(i)*0.4+0.35,confidence:0.9)) }
        words.append(RecognizedWord(text:"다음",start:10,end:10.2,confidence:0.2))
        var options = SpeechOptions(); options.maxLineChars = 12; options.maxLines = 2
        let captions = CaptionSegmenter.segment(words,options:options)
        XCTAssertGreaterThan(captions.count,2)
        for c in captions {
            XCTAssertTrue(c.text.split(separator:"\n").allSatisfy { $0.count <= 12+6 }); XCTAssertLessThanOrEqual(c.text.split(separator:"\n").count,2)
            XCTAssertGreaterThanOrEqual(c.end-c.start,0.2)
        }
        XCTAssertTrue(captions.contains { $0.text.hasSuffix("했습니다.") })
        for (x,y) in zip(captions,captions.dropFirst()) { XCTAssertLessThanOrEqual(x.end,y.start+0.0001) }
        XCTAssertEqual(captions.last?.end ?? 0,10.8,accuracy:0.01)   // stretched to the minimum reading time
        XCTAssertLessThan(captions.last?.confidence ?? 1,SpeechOptions.reviewConfidence)
        let hallucinated = CaptionSegmenter.segment([RecognizedWord(text:"시청해",start:0,end:0.5,confidence:0.3),RecognizedWord(text:"주셔서",start:0.5,end:1,confidence:0.3),RecognizedWord(text:"감사합니다",start:1,end:1.5,confidence:0.3)],options:SpeechOptions())
        XCTAssertTrue(hallucinated.isEmpty)
        // Source captions follow speed changes and repeats on the timeline.
        var p = timelineProject(); let src = p.media[0].id
        p.clips = [Clip(start:2,end:6,speed:2),Clip(start:2,end:6)]
        let placed = p.timelineCaptions(from:[src:[Caption(start:3,end:4,text:"A")]])
        XCTAssertEqual(placed.count,2)
        XCTAssertEqual(placed[0].start,0.5,accuracy:0.0001); XCTAssertEqual(placed[0].end,1,accuracy:0.0001)
        XCTAssertEqual(placed[1].start,3,accuracy:0.0001); XCTAssertEqual(placed[1].end,4,accuracy:0.0001)
        XCTAssertEqual(TimelineRange.subtracting([TimelineRange(start:0,end:10)],[TimelineRange(start:2,end:3),TimelineRange(start:5,end:12)]),[TimelineRange(start:0,end:2),TimelineRange(start:3,end:5)])
        let stored = SpeechOptions.load(); XCTAssertTrue(stored.engine.available)
    }

    @MainActor func testMultiSourceStoreAndBatchQueue() async throws {
        _ = NSApplication.shared
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at:dir) }
        let a = dir.appendingPathComponent("a.mov"); try await makeVideo(a)
        let b = dir.appendingPathComponent("b.mov"); try await makeSolidVideo(b,width:180,height:320,color:CIColor(red:0,green:1,blue:0))
        let store = EditorStore(); store.automaticRecoveryEnabled = false
        store.addMedia([a,b],newProject:true)
        for _ in 0..<200 { if !store.busy && store.loaded { break }; try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertEqual(store.project.media.count,2); XCTAssertEqual(store.project.clips.count,2)
        XCTAssertEqual(store.project.width,320); XCTAssertEqual(store.project.editedDuration,3,accuracy:0.05)
        for _ in 0..<150 { if store.previewReady { break }; try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertTrue(store.previewReady)
        XCTAssertEqual(try await store.player.currentItem!.asset.load(.duration).seconds,3,accuracy:0.05)
        let second = store.project.media[1].id
        store.seek(0.5); store.connectAtPlayhead(second)
        XCTAssertEqual(store.project.clips.last?.lane,1); XCTAssertEqual(store.project.clips.last?.position ?? 0,0.5,accuracy:0.001)
        store.undo(); XCTAssertEqual(store.project.clips.count,2)
        store.selectClip(store.project.clips[0].id); store.setSpeed(2)
        XCTAssertEqual(store.project.editedDuration,2,accuracy:0.05)
        store.setTransition(.dissolve,duration:0.4)
        XCTAssertNotNil(store.project.clips[0].transition)
        store.seek(0.5); store.addMarker(); XCTAssertEqual(store.project.markers.count,1)
        store.addTitle(text:"안녕"); XCTAssertEqual(store.project.titles.count,1)
        store.seek(0.2); store.selectClip(store.project.clips[0].id); store.addFreezeFrame(length:1)
        XCTAssertTrue(store.project.clips.contains { $0.freeze == 1 })
        XCTAssertNoThrow(try store.project.validate())
        // Batch: analyse both, export the automatic one to the chosen folder.
        let outFolder = dir.appendingPathComponent("out"); try FileManager.default.createDirectory(at:outFolder,withIntermediateDirectories:true)
        store.project.batch.folder = outFolder.path; store.project.batch.analysis = .fast
        store.enqueue(store.project.media.map(\.id))
        store.setJobMode(store.project.queue[1].id,.automatic)
        store.runQueue()
        for _ in 0..<1500 { if !store.queueRunning { break }; try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertFalse(store.queueRunning)
        XCTAssertEqual(store.project.queue.map(\.state),[.review,.done])
        let written = try FileManager.default.contentsOfDirectory(atPath:outFolder.path)
        XCTAssertEqual(written,["b_마스킹.mov"].map { $0.replacingOccurrences(of:".mov",with:".\(store.project.batch.videoFormat.rawValue)") })
        XCTAssertEqual(try await MediaEngine.load(outFolder.appendingPathComponent(written[0])).duration,1,accuracy:0.08)
        store.approveJob(store.project.queue[0].id); XCTAssertEqual(store.project.queue[0].state,.approved)
        store.exportApproved()
        for _ in 0..<1500 { if !store.queueRunning { break }; try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertEqual(store.project.queue[0].state,.done)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:outFolder.path).count,2)
        // Output names never overwrite: a second run gets a numbered name.
        let next = store.outputURL(for:store.project.media[1],folder:outFolder)
        XCTAssertTrue(next.lastPathComponent.contains("(2)"))
        var interrupted = store.project; interrupted.queue[0].state = .analyzing; interrupted.sanitizeQueue(); XCTAssertEqual(interrupted.queue[0].state,.queued)
        store.pause()
    }

    // Korean speech with background noise: the bundled turbo model must stay accurate.
    func testKoreanSpeechAccuracyWithNoise() async throws {
        guard let executable = WhisperTranscription.executable, let turbo = WhisperTranscription.bundledTurbo else { print("SKIP Whisper turbo model not installed"); return }
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at:dir) }
        let sentence = "오늘은 우리 반 친구들과 함께 과학 실험을 했습니다 선생님께서 물과 기름이 섞이지 않는 이유를 설명해 주셨어요"
        let voice = dir.appendingPathComponent("voice.aiff")
        let say = Process(); say.executableURL = URL(fileURLWithPath:"/usr/bin/say"); say.arguments = ["-v","Yuna","-o",voice.path,sentence]
        try say.run(); say.waitUntilExit()
        guard say.terminationStatus == 0, FileManager.default.fileExists(atPath:voice.path) else { print("SKIP Korean voice unavailable"); return }
        // Mix in steady noise about 12 dB below the voice.
        let input = try AVAudioFile(forReading:voice)
        let buffer = AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:AVAudioFrameCount(input.length))!; try input.read(into:buffer)
        var rng = SystemRandomNumberGenerator()
        for c in 0..<Int(buffer.format.channelCount) { for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] += Float.random(in:-0.05...0.05,using:&rng) } }
        let noisy = dir.appendingPathComponent("noisy.caf")
        do { let file = try AVAudioFile(forWriting:noisy,settings:buffer.format.settings); try file.write(from:buffer) }
        let wav = dir.appendingPathComponent("noisy.wav")
        _ = try await Transcription.prepareAudio(source:noisy,destination:wav,offset:0,length:60,options:SpeechOptions(),cancellation:Cancellation())
        func errorRate(_ text: String) -> Double {
            let a = Array(sentence.filter { !$0.isWhitespace }), b = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
            var d = Array(0...b.count)
            for i in 1...a.count { var prev = d[0]; d[0] = i; for j in 1...max(1,b.count) where !b.isEmpty { let t = d[j]; d[j] = min(d[j]+1,d[j-1]+1,prev+(a[i-1] == b[j-1] ? 0 : 1)); prev = t } }
            return Double(b.isEmpty ? a.count : d[b.count])/Double(a.count)
        }
        let words = try await WhisperTranscription.recognizeWords(executable:executable,model:turbo,vad:WhisperTranscription.voiceModel,audio:wav,result:dir.appendingPathComponent("turbo"),language:"ko",hints:"",duration:10,cancellation:Cancellation())
        let turboRate = errorRate(words.map(\.text).joined())
        var baseRate = -1.0
        if let base = WhisperTranscription.bundledBase {
            let baseWords = try await WhisperTranscription.recognizeWords(executable:executable,model:base,vad:nil,audio:wav,result:dir.appendingPathComponent("base"),language:"ko",hints:"",duration:10,cancellation:Cancellation())
            baseRate = errorRate(baseWords.map(\.text).joined())
        }
        print(String(format:"Korean noisy speech character error: turbo %.1f%%, base %.1f%%",turboRate*100,baseRate*100))
        XCTAssertLessThan(turboRate,0.12)
        XCTAssertFalse(words.isEmpty); XCTAssertTrue(words.allSatisfy { $0.end >= $0.start })
    }
}
