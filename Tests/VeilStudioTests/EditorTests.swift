#if !VEIL_STANDALONE_TESTS
import XCTest
#endif
import AVFoundation
import CoreImage
import ImageIO
#if !VEIL_STANDALONE_TESTS
@testable import VeilStudio
#endif

final class EditorTests: XCTestCase {
    func testTimelineMapsCutsAndCaptions() {
        var p = Project(); p.clips = [Clip(start:2,end:5),Clip(start:8,end:10)]
        p.captions = [Caption(start:1,end:3,text:"첫 문장"),Caption(start:4,end:9,text:"두 번째")]
        XCTAssertEqual(p.editedDuration,5); XCTAssertEqual(p.sourceTime(for:3.5),8.5)
        let c = p.outputCaptions(); XCTAssertEqual(c.count,3)
        XCTAssertEqual(c[0].start,0); XCTAssertEqual(c[0].end,1)
        XCTAssertEqual(c[1].start,2); XCTAssertEqual(c[1].end,3)
        XCTAssertEqual(c[2].start,3); XCTAssertEqual(c[2].end,4)
    }
    func testSubtitleRoundtripAndMalformedInput() {
        let c = [Caption(start:0.123,end:65.25,text:"안녕하세요\n두 번째 줄"),Caption(start:72,end:74.5,text:"Hello")]
        let parsed = Subtitles.parse(Subtitles.srt(c)); XCTAssertEqual(parsed.map(\.text),c.map(\.text)); XCTAssertEqual(parsed.map(\.start),c.map(\.start))
        XCTAssertTrue(Subtitles.parse("1\nwrong --> time\nbad").isEmpty)
        XCTAssertTrue(Subtitles.parse("1\n00:00:05,000 --> 00:00:01,000\nbad").isEmpty)
    }
    func testFaceInterpolationDoesNotBridgeDisappearance() {
        let a = NormalRect(x:0.1,y:0.2,width:0.2,height:0.3), b = NormalRect(x:0.3,y:0.2,width:0.2,height:0.3)
        let track = FaceTrack(name:"test",samples:[FaceSample(time:0,rect:a),FaceSample(time:0.1,rect:b),FaceSample(time:5,rect:a)])
        XCTAssertEqual(track.rect(at:0.05)!.x,0.2,accuracy:0.001); XCTAssertNil(track.rect(at:2)); XCTAssertEqual(track.rect(at:99,still:true),a)
    }
    func testKeyframesAndCropGeometry() {
        var r = ManualRegion(name:"r",start:0,end:10,rect:NormalRect(x:0,y:0,width:0.1,height:0.1))
        r.keyframes = [RegionKeyframe(time:0,rect:r.rect),RegionKeyframe(time:10,rect:NormalRect(x:0.5,y:0.5,width:0.3,height:0.3))]
        XCTAssertEqual(r.rect(at:5).x,0.25,accuracy:0.001)
        var options = ExportOptions(); options.ratio = .portrait
        let crop = options.cropRect(CGSize(width:1920,height:1080)); XCTAssertEqual(crop.width,607.5); XCTAssertEqual(crop.midX,960)
        let output = options.outputSize(CGSize(width:1920,height:1080)); XCTAssertEqual(output.width.truncatingRemainder(dividingBy:2),0)
        options.resolution = .uhd; XCTAssertEqual(options.outputSize(CGSize(width:320,height:180)).height,180)
    }
    func testInvalidProjectsRejected() {
        var p = Project(); p.width = 1920; p.height = 1080; p.duration = 10; p.clips = [Clip(start:0,end:11)]
        XCTAssertThrowsError(try p.validate()); p.clips = [Clip(start:0,end:10)]; XCTAssertNoThrow(try p.validate())
        p.faces = [FaceTrack(name:"bad",samples:[FaceSample(time:2,rect:NormalRect(x:-0.2,y:0,width:0.2,height:0.2))])]; XCTAssertThrowsError(try p.validate())
    }
    func pixel(_ image: CIImage,_ x: Int,_ y: Int,context: CIContext) -> [UInt8] {
        var bytes = [UInt8](repeating:0,count:4)
        context.render(image,toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        return bytes
    }
    func testMaskPixelsAndUnselectedFace() {
        let renderer = MaskRenderer(); let original = CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:200,height:100))
        var p = Project(); p.isImage = true; p.width = 200; p.height = 100; p.maskApplied = true
        p.design.effect = .solid; p.design.shape = .rectangle; p.design.red = 0; p.design.green = 0; p.design.blue = 1; p.design.margin = 0
        p.faces = [FaceTrack(name:"A",samples:[FaceSample(time:0,rect:NormalRect(x:0.1,y:0.2,width:0.2,height:0.6))]),FaceTrack(name:"B",selected:false,samples:[FaceSample(time:0,rect:NormalRect(x:0.7,y:0.2,width:0.2,height:0.6))])]
        let result = renderer.render(original,project:p,time:0,crop:false)
        XCTAssertGreaterThan(pixel(result,40,50,context:renderer.context)[2],230)
        XCTAssertGreaterThan(pixel(result,160,50,context:renderer.context)[0],230)
        XCTAssertGreaterThan(pixel(result,5,5,context:renderer.context)[0],230)
        for shape in MaskShape.allCases { p.design.shape = shape; for effect in MaskEffect.allCases { p.design.effect = effect; let image = renderer.render(original,project:p,time:0,crop:false); XCTAssertNotNil(renderer.context.createCGImage(image,from:image.extent)) } }
    }
    func testImageExportCropAndCancellation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let source = dir.appendingPathComponent("source.png"); let context = CIContext()
        let image = CIImage(color:.red).cropped(to:CGRect(x:0,y:0,width:320,height:180))
        try context.writePNGRepresentation(of:image,to:source,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        var p = try await MediaEngine.load(source); p.export.ratio = .square; p.export.resolution = .original; p.design.effect = .solid; p.design.shape = .rectangle
        p.regions = [ManualRegion(name:"test",start:0,end:0,rect:NormalRect(x:0,y:0,width:1,height:1))]
        let target = dir.appendingPathComponent("output.png"); try await MediaEngine.export(p,to:target,cancellation:Cancellation(),progress:{_,_ in})
        let loaded = try await MediaEngine.load(target); XCTAssertEqual(loaded.width,180); XCTAssertEqual(loaded.height,180)
        let exported = try MediaEngine.stillImage(target); XCTAssertLessThan(pixel(exported,50,50,context:context)[0],150)
        let cancel = Cancellation(); cancel.cancel()
        do { try await MediaEngine.export(p,to:dir.appendingPathComponent("cancel.png"),cancellation:cancel,progress:{_,_ in}); XCTFail("Cancellation should throw") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent("cancel.png").path))
    }
    func makeVideo(_ url: URL, transform: CGAffineTransform = .identity) async throws {
        let writer = try AVAssetWriter(outputURL:url,fileType:.mov)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:320,AVVideoHeightKey:180]); input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:320,kCVPixelBufferHeightKey as String:180,kCVPixelBufferIOSurfacePropertiesKey as String:[:] as [String:Any]])
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? StudioError.message("Test video writer failed to start") }; writer.startSession(atSourceTime:.zero)
        let context = CIContext()
        for n in 0..<60 {
            let waitStart = Date()
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed || Date().timeIntervalSince(waitStart) > 10 { throw writer.error ?? StudioError.message("Test writer timed out") }
                try await Task.sleep(nanoseconds:1_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? StudioError.message("Pixel buffer pool unavailable") }
            var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)
            guard let buffer else { throw StudioError.message("Test pixel allocation failed") }
            let base = CIImage(color:CIColor(red:n < 30 ? 1 : 0,green:0,blue:n < 30 ? 0 : 1)).cropped(to:CGRect(x:0,y:0,width:320,height:180))
            let band = CIImage(color:CIColor(red:0,green:1,blue:0)).cropped(to:CGRect(x:0,y:0,width:80,height:180)).composited(over:base)
            context.render(band,to:buffer); XCTAssertTrue(adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(n),timescale:30)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status,.completed)
    }
    func testVideoExportBurnsMaskCutsCropAndSubtitles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veil-integration-\(UUID().uuidString)"); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let source = dir.appendingPathComponent("input.mov"); try await makeVideo(source)
        var p = try await MediaEngine.load(source); p.clips = [Clip(start:0.5,end:1),Clip(start:1.5,end:2)]; p.export.ratio = .square; p.export.resolution = .original
        p.design.effect = .solid; p.design.shape = .rectangle; p.design.red = 1; p.design.green = 1; p.design.blue = 1
        p.regions = [ManualRegion(name:"test",start:0,end:2,rect:NormalRect(x:0.45,y:0.4,width:0.1,height:0.2))]
        p.captions = [Caption(start:0,end:2,text:"한글 자막 테스트")]
        let target = dir.appendingPathComponent("output.mp4"); try await MediaEngine.export(p,to:target,cancellation:Cancellation(),progress:{_,_ in})
        let output = try await MediaEngine.load(target); XCTAssertEqual(output.width,180); XCTAssertEqual(output.height,180); XCTAssertEqual(output.duration,1,accuracy:0.08)
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:target)); generator.appliesPreferredTrackTransform = true; generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at:CMTime(seconds:0.2,preferredTimescale:600)).image
        let ci = CIImage(cgImage:frame); let context = CIContext()
        let center = pixel(ci,90,90,context:context); XCTAssertGreaterThan(center[0],210); XCTAssertGreaterThan(center[1],210); XCTAssertGreaterThan(center[2],210)
        var subtitlePixels = [UInt8](repeating:0,count:180*40*4)
        context.render(ci,toBitmap:&subtitlePixels,rowBytes:180*4,bounds:CGRect(x:0,y:0,width:180,height:40),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        let whiteTextPixels = stride(from:0,to:subtitlePixels.count,by:4).filter { subtitlePixels[$0] > 190 && subtitlePixels[$0+1] > 190 && subtitlePixels[$0+2] > 190 }.count
        XCTAssertGreaterThan(whiteTextPixels,10)
        let red = pixel(ci,130,110,context:context); XCTAssertGreaterThan(red[0],190); XCTAssertLessThan(red[2],60)
        let later = try await generator.image(at:CMTime(seconds:0.7,preferredTimescale:600)).image
        let blue = pixel(CIImage(cgImage:later),130,110,context:context); XCTAssertGreaterThan(blue[2],190); XCTAssertLessThan(blue[0],60)
        let faces = try await MediaEngine.analyze(p,cancellation:Cancellation(),progress:{_,_ in}); XCTAssertTrue(faces.isEmpty)
    }
    func testPortraitOrientation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let source = dir.appendingPathComponent("rotated.mov"); try await makeVideo(source,transform:CGAffineTransform(a:0,b:1,c:-1,d:0,tx:180,ty:0))
        var p = try await MediaEngine.load(source); XCTAssertEqual(p.width,180); XCTAssertEqual(p.height,320); p.export.resolution = .original
        let target = dir.appendingPathComponent("portrait.mp4"); try await MediaEngine.export(p,to:target,cancellation:Cancellation(),progress:{_,_ in})
        let loaded = try await MediaEngine.load(target); XCTAssertEqual(loaded.width,180); XCTAssertEqual(loaded.height,320)
    }

    func testAudioPreservationAndMute() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let silent = dir.appendingPathComponent("silent.mov"); try await makeVideo(silent)
        let audioURL = dir.appendingPathComponent("tone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:88200)!; buffer.frameLength = 88200
        for i in 0..<88200 { buffer.floatChannelData![0][i] = Float(sin(Double(i)*2*Double.pi*440/44100)*0.2) }
        do { let audioFile = try AVAudioFile(forWriting:audioURL,settings:format.settings); try audioFile.write(from:buffer) }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url:silent); let audioAsset = AVURLAsset(url:audioURL)
        let videoTrack = try await videoAsset.loadTracks(withMediaType:.video)[0]
        let audioTrack = try await audioAsset.loadTracks(withMediaType:.audio)[0]
        let range = CMTimeRange(start:.zero,duration:CMTime(seconds:2,preferredTimescale:600))
        try composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(range,of:videoTrack,at:.zero)
        try composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(range,of:audioTrack,at:.zero)
        let source = dir.appendingPathComponent("with-audio.mov")
        let session = AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality)!
        session.outputURL = source; session.outputFileType = .mov; await session.export()
        guard session.status == .completed else { throw session.error ?? StudioError.message("Audio fixture export failed") }
        var p = try await MediaEngine.load(source); p.clips = [Clip(start:0.25,end:0.75),Clip(start:1.25,end:1.75)]
        let target = dir.appendingPathComponent("sound.mp4")
        try await MediaEngine.export(p,to:target,cancellation:Cancellation(),progress:{_,_ in})
        let exported = AVURLAsset(url:target)
        let audioTracks = try await exported.loadTracks(withMediaType:.audio)
        XCTAssertEqual(audioTracks.count,1)
        let reader = try AVAssetReader(asset:exported)
        let output = AVAssetReaderTrackOutput(track:audioTracks[0],outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() { sampleCount += CMSampleBufferGetNumSamples(sample) }
        XCTAssertGreaterThan(sampleCount,40000)
        p.export.muted = true
        let muted = dir.appendingPathComponent("muted.mp4")
        try await MediaEngine.export(p,to:muted,cancellation:Cancellation(),progress:{_,_ in})
        let mutedTracks = try await AVURLAsset(url:muted).loadTracks(withMediaType:.audio)
        XCTAssertEqual(mutedTracks.count,0)
    }
    func testReferenceImageFaces() async throws {
        guard let path = ProcessInfo.processInfo.environment["VEIL_FACE_FIXTURE"] else { print("SKIP reference face fixture (set VEIL_FACE_FIXTURE)"); return }
        let p = try await MediaEngine.load(URL(fileURLWithPath:path))
        let tracks = try await MediaEngine.analyze(p,cancellation:Cancellation(),progress:{_,_ in})
        XCTAssertGreaterThan(tracks.count,0)
        XCTAssertTrue(tracks.allSatisfy { $0.thumbnail != nil && $0.samples.first?.rect.valid == true })
        print("Reference image: \(tracks.count) face candidates")
    }

    func testMovingFaceIsMaskedThroughoutVideo() async throws {
        guard let path = ProcessInfo.processInfo.environment["VEIL_FACE_FIXTURE"] else { print("SKIP moving-face fixture (set VEIL_FACE_FIXTURE)"); return }
        // The reference's central faces are already pixelated. Use its unmasked
        // first thumbnail, with surrounding head context, as the motion fixture.
        let referenceImage = try MediaEngine.stillImage(URL(fileURLWithPath:path))
        let thumbnailRect = CGRect(x:referenceImage.extent.width*0.127,y:referenceImage.extent.height*0.681,width:referenceImage.extent.width*0.034,height:referenceImage.extent.height*0.065).integral
        let cropped = referenceImage.cropped(to:thumbnailRect)
        let face = cropped.transformed(by:CGAffineTransform(translationX:-thumbnailRect.minX,y:-thumbnailRect.minY))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("moving-face.mov")
        let writer = try AVAssetWriter(outputURL:url,fileType:.mov)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:640,AVVideoHeightKey:360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:640,kCVPixelBufferHeightKey as String:360,kCVPixelBufferIOSurfacePropertiesKey as String:[:] as [String:Any]])
        writer.add(input); guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime:.zero)
        let context = CIContext(); let scale = 180/max(face.extent.width,face.extent.height)
        for n in 0..<24 {
            let started = Date()
            while !input.isReadyForMoreMediaData { if writer.status == .failed || Date().timeIntervalSince(started) > 10 { throw writer.error ?? StudioError.message("Fixture timeout") }; try await Task.sleep(nanoseconds:1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw StudioError.message("No pixel pool") }
            var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)
            guard let buffer else { throw StudioError.message("No pixel buffer") }
            let placed = face.transformed(by:CGAffineTransform(scaleX:scale,y:scale)).transformed(by:CGAffineTransform(translationX:50+Double(n)*8,y:80))
            let frame = placed.composited(over:CIImage(color:CIColor(red:0.08,green:0.08,blue:0.08)).cropped(to:CGRect(x:0,y:0,width:640,height:360)))
            context.render(frame,to:buffer); XCTAssertTrue(adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(n),timescale:12)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status,.completed)
        var p = try await MediaEngine.load(url)
        p.faces = try await MediaEngine.analyze(p,cancellation:Cancellation(),progress:{_,_ in})
        XCTAssertGreaterThan(p.faces.count,0)
        XCTAssertGreaterThan(p.faces.map { $0.samples.count }.max() ?? 0,16)
        p.maskApplied = true; p.design.effect = .solid; p.design.shape = .rectangle; p.design.red = 1; p.design.green = 0; p.design.blue = 1; p.export.resolution = .original
        let exported = folder.appendingPathComponent("masked.mp4")
        try await MediaEngine.export(p,to:exported,cancellation:Cancellation(),progress:{_,_ in})
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:exported)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for t in [0.0,0.5,1.0,1.5] {
            guard let rect = p.faces.compactMap({ $0.rect(at:t,tolerance:0.13) }).first else { XCTFail("Missing tracked face at \(t)"); continue }
            let frame = try await generator.image(at:CMTime(seconds:t,preferredTimescale:600)).image
            let pixel = pixel(CIImage(cgImage:frame),Int(rect.cg.midX*640),Int(rect.cg.midY*360),context:context)
            XCTAssertGreaterThan(pixel[0],200); XCTAssertGreaterThan(pixel[2],200); XCTAssertLessThan(pixel[1],50)
        }
        var partial = p; partial.clips = [Clip(start:0.5,end:1),Clip(start:0.5,end:1)]
        let limited = try await MediaEngine.analyze(partial,cancellation:Cancellation(),progress:{_,_ in})
        XCTAssertFalse(limited.isEmpty)
        XCTAssertTrue(limited.flatMap(\.samples).allSatisfy { $0.time >= 0.5 && $0.time < 1 })
        XCTAssertLessThan(limited.flatMap(\.samples).count,12)
        print("Moving face: \(p.faces.count) candidates, \(p.faces.map { $0.samples.count }.max() ?? 0) frames in longest track")
    }
}
