import Foundation
import AVFoundation
import AppKit
import CoreImage
import ImageIO
import Speech
#if !VEIL_STANDALONE_TESTS
import XCTest
@testable import VeilStudio
#endif

extension EditorTests {
    func timelineProject() -> Project {
        var p = Project(); p.width = 1920; p.height = 1080; p.duration = 10
        p.clips = [Clip(start:0,end:2),Clip(start:5,end:7),Clip(start:8,end:10)]
        return p
    }
    func testRippleDeleteMovePasteAndDuplicate() throws {
        var p = timelineProject(); let last = p.clips[2].id
        p.removeTimelineClips([p.clips[1].id])
        XCTAssertEqual(p.timeline.map(\.start),[0,2]); XCTAssertEqual(p.editedDuration,4)
        XCTAssertEqual(p.sourceTime(for:2.5),8.5)
        p.moveTimelineClip(last,before:p.clips[0].id)
        XCTAssertEqual(p.sourceTime(for:0.5),8.5); XCTAssertEqual(p.sourceTime(for:2.5),0.5)
        let copied = [p.clips[0]]
        let ids = p.insertTimelineClips(copied,at:1)
        XCTAssertEqual(p.editedDuration,6); XCTAssertEqual(p.clips.count,4)
        XCTAssertEqual(p.timeline.map(\.start),[0,1,3,4]); XCTAssertEqual(p.sourceTime(for:1.5),8.5)
        XCTAssertEqual(p.sourceTime(for:3.5),9.5); XCTAssertEqual(Set(p.clips.map(\.id)).count,p.clips.count)
        XCTAssertEqual(ids.count,1); XCTAssertNoThrow(try p.validate())
        p.removeTimelineClips(Set(p.clips.map(\.id))); XCTAssertTrue(p.clips.isEmpty)
        _ = p.insertTimelineClips(copied,at:0); XCTAssertEqual(p.editedDuration,2)
    }
    func testSelectionRangeSlicesCutsAndCaptions() throws {
        var p = timelineProject(); p.sourcePath = "/tmp/veil-unit-source.mov"
        p.captions = [Caption(start:1,end:2,text:"A"),Caption(start:5,end:7,text:"B"),Caption(start:8,end:10,text:"C")]
        p.exportRange = TimelineRange(start:1.5,end:4.5)
        try p.validate()
        let output = p.projectForExport
        XCTAssertEqual(output.clips.map(\.start),[1.5,5,8]); XCTAssertEqual(output.clips.map(\.end),[2,7,8.5]); XCTAssertEqual(output.editedDuration,3)
        XCTAssertEqual(p.outputCaptions().map(\.start),[0,0.5,2.5]); XCTAssertEqual(p.outputCaptions().map(\.end),[0.5,2.5,3])
        XCTAssertEqual(p.outputCaptions(respectExportRange:false).map(\.start),[1,2,4])
        let saved = try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)); XCTAssertEqual(saved.exportRange,p.exportRange)
        p.deleteTimelineRange(p.exportRange!); XCTAssertEqual(p.editedDuration,3)
        XCTAssertEqual(p.clips.map(\.start),[0,8.5]); XCTAssertEqual(p.clips.map(\.end),[1.5,10]); XCTAssertNil(p.exportRange)
    }
    func testReorderedSelectedExportPixels() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let source = dir.appendingPathComponent("source.mov"); try await makeVideo(source)
        var p = try await MediaEngine.load(source)
        p.clips = [Clip(start:1,end:2),Clip(start:0,end:1)] // Blue first, red second.
        p.exportRange = TimelineRange(start:0.5,end:1.5)
        p.export.resolution = .original
        p.captions = [Caption(start:0,end:1,text:"RED"),Caption(start:1,end:2,text:"BLUE")]
        let target = dir.appendingPathComponent("selected.mp4")
        try await MediaEngine.export(p,to:target,cancellation:Cancellation(),progress:{_,_ in})
        let output = try await MediaEngine.load(target); XCTAssertEqual(output.duration,1,accuracy:0.05)
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:target)); generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at:CMTime(seconds:0.2,preferredTimescale:600)).image
        let last = try await generator.image(at:CMTime(seconds:0.7,preferredTimescale:600)).image
        let context = CIContext()
        XCTAssertGreaterThan(pixel(CIImage(cgImage:first),200,100,context:context)[2],190)
        XCTAssertGreaterThan(pixel(CIImage(cgImage:last),200,100,context:context)[0],190)
        XCTAssertEqual(p.outputCaptions().map(\.text),["BLUE","RED"])
        XCTAssertEqual(p.outputCaptions().map(\.start),[0,0.5])
    }
    @MainActor func testEditorCommandsAndComposedPreview() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("source.mov"); try await makeVideo(url)
        var p = try await MediaEngine.load(url); p.clips = [Clip(start:1,end:2),Clip(start:0,end:0.5)]
        let store = EditorStore(); store.automaticRecoveryEnabled = false; store.setProject(p)
        for _ in 0..<100 { if store.previewReady { break }; try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertTrue(store.previewReady)
        let compositionDuration = try await store.player.currentItem!.asset.load(.duration).seconds
        XCTAssertEqual(compositionDuration,1.5,accuracy:0.01)
        store.seek(0.25); XCTAssertEqual(store.sourcePlayhead,1.25,accuracy:0.001)
        store.selectClip(p.clips[0].id); store.copyClips(); store.cutClips()
        XCTAssertEqual(store.project.editedDuration,0.5); XCTAssertEqual(store.project.timeline.first!.start,0)
        store.pasteClips(); XCTAssertEqual(store.project.editedDuration,1.5)
        store.undo(); XCTAssertEqual(store.project.editedDuration,0.5)
        store.redo(); XCTAssertEqual(store.project.editedDuration,1.5)
        store.selectAllClips(); store.deleteClip(); XCTAssertTrue(store.project.clips.isEmpty)
        store.pasteClips(); XCTAssertEqual(store.project.editedDuration,1)
        var edit = p; edit.overlaysOnTimeline = true
        edit.captions = [Caption(start:0.2,end:0.7,text:"caption",horizontal:0.2,vertical:0.8,boxWidth:0.5)]
        edit.regions = [ManualRegion(name:"region",start:0.1,end:0.8,rect:NormalRect(x:0.1,y:0.1,width:0.2,height:0.3),keyframes:[RegionKeyframe(time:0.2,rect:NormalRect(x:0.2,y:0.2,width:0.2,height:0.3))])]
        store.setProject(edit)
        let rid = edit.regions[0].id, cid = edit.captions[0].id
        store.beginTimelineGesture()
        store.editOverlayTime(id:rid,region:true,original:TimelineRange(start:0.1,end:0.8),delta:0.4,edge:0)
        store.editOverlayTime(id:rid,region:true,original:TimelineRange(start:0.1,end:0.8),delta:0.5,edge:0)
        store.endTimelineGesture()
        XCTAssertEqual(store.project.regions[0].start,0.6,accuracy:0.001)
        XCTAssertEqual(store.project.regions[0].keyframes[0].time,0.7,accuracy:0.001)
        XCTAssertEqual(store.undoStack.count,1)
        store.undo(); XCTAssertEqual(store.project.regions[0].start,0.1)
        store.editOverlayTime(id:cid,region:false,original:TimelineRange(start:0.2,end:0.7),delta:0.3,edge:1)
        XCTAssertEqual(store.project.captions[0].end,1,accuracy:0.001)
        store.editRegionRect(rid,rect:NormalRect(x:0.4,y:0.4,width:0.2,height:0.2))
        XCTAssertEqual(store.project.regions[0].rect(at:store.overlayTime).x,0.4)
        let decoded = try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(store.project))
        XCTAssertEqual(decoded.captions[0].vertical,0.8)
        XCTAssertEqual(decoded.captions[0].boxWidth,0.5)
        XCTAssertFalse(decoded.overlayItems(regionsOnly:false).isEmpty)
        store.pause()
    }
    @MainActor func testIndependentOverlayTracks() throws {
        _ = NSApplication.shared
        var invalid = Project(); invalid.captions = [Caption(start:58.13,end:4,text:"repair")]
        XCTAssertEqual(invalid.repairEditableTimes(),1)
        XCTAssertGreaterThan(invalid.captions[0].end,58.13)
        XCTAssertEqual(invalid.captions[0].start,58.13)
        var p = timelineProject(); p.sourcePath = "/tmp/veil-unit-source.mov"
        p.captions = [Caption(start:0.5,end:1.5,text:"A"),Caption(start:5,end:6,text:"B")]
        p.regions = [ManualRegion(name:"M",start:0,end:10,rect:NormalRect(x:0.2,y:0.2,width:0.3,height:0.3))]
        p.migrateOverlayTimeline()
        XCTAssertEqual(p.captions.map(\.start),[0.5,2])
        XCTAssertEqual(p.regions.count,3)
        let saved = p
        p.migrateOverlayTimeline(); XCTAssertEqual(p,saved)
        let store = EditorStore(); store.automaticRecoveryEnabled = false; store.project = p
        store.selectOverlay(p.captions[0].id,region:false); store.playhead = 1
        store.split(); XCTAssertEqual(store.project.captions.count,3); XCTAssertEqual(store.project.clips,p.clips); XCTAssertEqual(store.project.regions,p.regions)
        store.editSelection("delete"); XCTAssertEqual(store.project.captions.count,2); XCTAssertEqual(store.project.clips,p.clips)
        store.undo(); XCTAssertEqual(store.project.captions.count,3)
        let cid = store.project.captions[0].id
        store.editOverlayTime(id:cid,region:false,original:TimelineRange(start:0.5,end:1),delta:3,edge:0)
        XCTAssertEqual(store.project.captions[0].start,3.5); XCTAssertEqual(store.project.captions[0].end,4)
        let before = store.project.captions
        store.selectClip(p.clips[0].id); store.deleteClip(); XCTAssertEqual(store.project.captions,before)
        store.project = p
        store.selectOverlay(p.regions[0].id,region:true); store.playhead = 1; store.split()
        XCTAssertEqual(store.project.regions.count,4); XCTAssertEqual(store.project.captions,p.captions); XCTAssertEqual(store.project.clips,p.clips)
        store.project.exportRange = TimelineRange(start:0.5,end:1.5)
        let output = store.project.projectForExport
        XCTAssertEqual(output.captions[0].start,0); XCTAssertEqual(output.captions[0].end,1)
        XCTAssertEqual(output.regions[0].start,0)
        let untouchedCaptions = store.project.captions
        let untouchedClips = store.project.clips
        store.deleteMarkedRange()
        XCTAssertEqual(store.project.captions,untouchedCaptions); XCTAssertEqual(store.project.clips,untouchedClips)
        XCTAssertTrue(store.project.regions.allSatisfy { $0.end <= 0.5 || $0.start >= 1.5 })
        store.project = p
        store.selectOverlay(p.captions[0].id,region:false); store.editSelection("copy")
        store.addLane(.captions); let destinationLane = store.selectedLane
        XCTAssertFalse(store.selectionAvailable)
        store.playhead = 3; store.editSelection("paste")
        XCTAssertEqual(store.project.captions.last?.lane,destinationLane)
        store.addLane(.video); let clipsBeforeEmptySplit = store.project.clips
        store.playhead = 1; store.split(); XCTAssertEqual(store.project.clips,clipsBeforeEmptySplit)
        var renderProject = p
        renderProject.regions = [ManualRegion(name:"red",start:0,end:1,rect:NormalRect(x:0.1,y:0.1,width:0.3,height:0.3))]
        var red = MaskDesign(); red.effect = .solid; red.shape = .rectangle; red.red = 1; red.green = 0; red.blue = 0
        renderProject.regionDesign = red; renderProject.export.burnCaptions = false
        let renderer = MaskRenderer(); let source = CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:100,height:100))
        let visible = renderer.render(source,project:renderProject,time:8,crop:false,overlayTime:0.5)
        let hidden = renderer.render(source,project:renderProject,time:0.5,crop:false,overlayTime:2)
        XCTAssertGreaterThan(pixel(visible,20,20,context:renderer.context)[0],240)
        XCTAssertLessThan(pixel(hidden,20,20,context:renderer.context)[0],10)
        try store.project.validate()
    }

    func testOverlayLanesAndAnalysisRanges() throws {
        var p = timelineProject()
        p.clips += [Clip(start:1,end:3),Clip(start:5.5,end:6)]
        XCTAssertEqual(p.analysisRanges,[TimelineRange(start:0,end:3),TimelineRange(start:5,end:7),TimelineRange(start:8,end:10)])
        p.captions = [Caption(start:0,end:2,text:"A"),Caption(start:1,end:3,text:"B"),Caption(start:3,end:4,text:"C")]
        p.regions = [ManualRegion(name:"A",start:0,end:2,rect:NormalRect(x:0,y:0,width:0.5,height:0.5)),ManualRegion(name:"B",start:1,end:3,rect:NormalRect(x:0,y:0,width:0.5,height:0.5))]
        p.separateOverlappingOverlays()
        XCTAssertEqual(p.captions.map { $0.lane ?? 0 },[0,1,0]); XCTAssertEqual(p.regionLaneCount,2)
        let saved = p; p.separateOverlappingOverlays(); XCTAssertEqual(p,saved)
        let decoded = try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)); XCTAssertEqual(decoded,saved)
    }
    func testLayeredVideoExport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("source.mov"); try await makeVideo(url)
        var p = try await MediaEngine.load(url); p.videoLaneCount = 2
        p.clips = [Clip(start:0,end:2,lane:0,position:0),Clip(start:1,end:1.5,lane:1,position:0.25)]
        XCTAssertEqual(p.editedDuration,2)
        XCTAssertEqual(p.sourceTime(for:0.3),1.05,accuracy:0.001)
        XCTAssertEqual(p.sourceTime(for:0.8),0.8,accuracy:0.001)
        XCTAssertEqual(mappedSourceTime(p.visibleTimeline,at:0.3),1.05,accuracy:0.001)
        let before = p.clips[1].id
        _ = p.splitTimeline(at:0.5,clipID:before)
        XCTAssertEqual(p.clips.count,3)
        XCTAssertEqual(p.clips[0].end,2)
        try p.validate()
        let dest = dir.appendingPathComponent("layers.mp4")
        try await MediaEngine.export(p,to:dest,cancellation:Cancellation(),progress:{_,_ in})
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:dest)); generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let context = CIContext()
        let blue = try await generator.image(at:CMTime(seconds:0.4,preferredTimescale:600)).image
        let red = try await generator.image(at:CMTime(seconds:0.9,preferredTimescale:600)).image
        XCTAssertGreaterThan(pixel(CIImage(cgImage:blue),200,100,context:context)[2],190)
        XCTAssertGreaterThan(pixel(CIImage(cgImage:red),200,100,context:context)[0],190)
        p.clips = [Clip(start:0,end:0.5,lane:0,position:0),Clip(start:1,end:1.5,lane:1,position:1)]
        let gap = dir.appendingPathComponent("gap.mp4")
        try await MediaEngine.export(p,to:gap,cancellation:Cancellation(),progress:{_,_ in})
        let g = AVAssetImageGenerator(asset:AVURLAsset(url:gap)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let blank = try await g.image(at:CMTime(seconds:0.75,preferredTimescale:600)).image
        XCTAssertLessThan(pixel(CIImage(cgImage:blank),200,100,context:context)[0],20)
    }

}

extension EditorTests {
    @MainActor func testProjectSaveAndStaleControls() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let source = dir.appendingPathComponent("source.mov"); try await makeVideo(source)
        var p = try await MediaEngine.load(source)
        p.regions = [ManualRegion(name:"A",start:0,end:1,rect:NormalRect(x:0.1,y:0.1,width:0.3,height:0.3)),ManualRegion(name:"B",start:1,end:2,rect:NormalRect(x:0.2,y:0.2,width:0.3,height:0.3))]
        p.captions = [Caption(start:0,end:1,text:"A"),Caption(start:1,end:2,text:"B")]
        let store = EditorStore(); store.automaticRecoveryEnabled = false
        XCTAssertFalse(store.hasUnsavedChanges)
        store.setProject(p); XCTAssertTrue(store.hasUnsavedChanges)
        let url = dir.appendingPathComponent("saved.veilproject")
        XCTAssertTrue(store.save(to:url)); XCTAssertFalse(store.hasUnsavedChanges)
        store.project.captions[0].text = "edit"; XCTAssertTrue(store.hasUnsavedChanges)
        store.undo(); XCTAssertFalse(store.hasUnsavedChanges)
        store.redo(); XCTAssertTrue(store.hasUnsavedChanges)
        let originalURL = store.projectURL
        XCTAssertFalse(store.save(to:dir.appendingPathComponent("missing/file.veilproject")))
        XCTAssertEqual(store.projectURL,originalURL); XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertFalse(store.save(to:source))
        var saves = 0
        XCTAssertFalse(store.resolveLeave(.cancel,save:{ saves += 1; return true }))
        XCTAssertTrue(store.resolveLeave(.discard,save:{ saves += 1; return true }))
        XCTAssertEqual(saves,0)
        XCTAssertFalse(store.resolveLeave(.save,save:{ false }))
        XCTAssertTrue(store.resolveLeave(.save,save:{ store.save(to:url) }))
        let region = store.itemBinding(\.regions,item:store.project.regions[1])
        let caption = store.itemBinding(\.captions,item:store.project.captions[1])
        store.project.regions.removeFirst(); store.project.captions.removeFirst()
        region.wrappedValue.name = "moved index"; caption.wrappedValue.text = "moved index"
        XCTAssertEqual(store.project.regions[0].name,"moved index")
        XCTAssertEqual(store.project.captions[0].text,"moved index")
        store.project.regions.removeAll(); store.project.captions.removeAll()
        _ = region.wrappedValue.name; region.wrappedValue.name = "late write"
        _ = caption.wrappedValue.text; caption.wrappedValue.text = "late write"
        XCTAssertTrue(store.project.regions.isEmpty); XCTAssertTrue(store.project.captions.isEmpty)
        // Even re-opening the same project (same item UUIDs) must reject old controls.
        store.setProject(p); region.wrappedValue.name = "stale"; caption.wrappedValue.text = "stale"
        XCTAssertEqual(store.project.regions[1].name,"B"); XCTAssertEqual(store.project.captions[1].text,"B")
        for _ in 0..<20 {
            store.setProject(p)
            let old = store.itemBinding(\.regions,item:store.project.regions[1])
            store.setProject(try await MediaEngine.load(source))
            old.wrappedValue.name = "late"
            XCTAssertTrue(store.project.regions.isEmpty)
        }
        try await Task.sleep(nanoseconds:300_000_000)
        XCTAssertTrue(store.previewReady)
        XCTAssertNil(store.selectedRegion); XCTAssertNil(store.selectedCaption)
        XCTAssertTrue(store.clipboardRegions.isEmpty); XCTAssertTrue(store.clipboardCaptions.isEmpty)
    }
}

extension EditorTests {
    func testSpeechPCMAndAdditionalFormats() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let audio = dir.appendingPathComponent("tone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:88200)!; buffer.frameLength = 88200
        for i in 0..<88200 { buffer.floatChannelData![0][i] = Float(sin(Double(i)*2*Double.pi*440/44100)*0.1) }
        do { let file = try AVAudioFile(forWriting:audio,settings:format.settings); try file.write(from:buffer) }
        var options = SpeechOptions(); options.gain = 2; options.hints = " 로디, ,편집\n학교 "
        XCTAssertEqual(options.contextualWords,["로디","편집","학교"])
        options.chunkSeconds = 100; XCTAssertEqual(options.chunkLength,45)
        let pcm = dir.appendingPathComponent("speech.wav")
        let diagnostic = try await Transcription.prepareAudio(source:audio,destination:pcm,offset:0.5,length:0.75,options:options,cancellation:Cancellation())
        XCTAssertTrue(diagnostic.contains("dBFS"))
        let file = try AVAudioFile(forReading:pcm)
        XCTAssertEqual(file.processingFormat.sampleRate,16000); XCTAssertEqual(file.processingFormat.channelCount,1)
        XCTAssertEqual(Double(file.length)/16000,0.75,accuracy:0.02)
        let result = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!; try file.read(into:result)
        var peak: Float = 0
        for i in 0..<Int(result.frameLength) { peak = max(peak,abs(result.floatChannelData![0][i])) }
        XCTAssertEqual(Double(peak),0.2,accuracy:0.015)
        let wave = try await AudioWaveform.read(source:audio,duration:2,ranges:[TimelineRange(start:0.5,end:1.25)],cancellation:Cancellation())
        XCTAssertTrue(wave.hasAudio); XCTAssertEqual(wave.peaks.count,200)
        XCTAssertEqual(Double(wave.peak(from:0.6,to:0.7)),0.1,accuracy:0.01)
        XCTAssertEqual(wave.peak(from:0,to:0.2),0)
        XCTAssertEqual(wave.peak(from:1.5,to:1.8),0)
        XCTAssertTrue(wave.covers([TimelineRange(start:0.7,end:1)]))
        XCTAssertFalse(wave.covers([TimelineRange(start:0.1,end:1)]))
        options.audioTrack = 9
        do { _ = try await Transcription.prepareAudio(source:audio,destination:dir.appendingPathComponent("bad.wav"),offset:0,length:1,options:options,cancellation:Cancellation()); XCTFail("Invalid track accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("트랙")) }
        let source = dir.appendingPathComponent("source.png")
        let context = CIContext(); let image = CIImage(color:.red).cropped(to:CGRect(x:0,y:0,width:320,height:180))
        try context.writePNGRepresentation(of:image,to:source,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        var p = try await MediaEngine.load(source)
        for format in ImageOutput.allCases {
            p.export.imageFormat = format
            let target = dir.appendingPathComponent("export.\(format.rawValue)")
            try await MediaEngine.export(p,to:target,cancellation:Cancellation(),progress:{_,_ in})
            let loaded = try await MediaEngine.load(target)
            XCTAssertTrue(loaded.isImage); XCTAssertEqual(loaded.width,320); XCTAssertEqual(loaded.height,180)
            let cgSource = CGImageSourceCreateWithURL(target as CFURL,nil)!
            XCTAssertEqual(CGImageSourceGetType(cgSource) as String?,format.typeIdentifier)
        }
        let video = dir.appendingPathComponent("video.mov"); try await makeVideo(video)
        p = try await MediaEngine.load(video); p.export.videoFormat = .mov
        let target = dir.appendingPathComponent("export.mov")
        try await MediaEngine.export(p,to:target,cancellation:Cancellation(),progress:{_,_ in})
        XCTAssertEqual(try await MediaEngine.load(target).duration,2,accuracy:0.1)
        let decoded = try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p))
        XCTAssertEqual(decoded.export.videoFormat,.mov)
        var legacy = ExportOptions(); legacy.jpeg = true
        XCTAssertEqual(legacy.resolvedImageFormat,.jpeg); XCTAssertEqual(legacy.fileExtension,"mp4")
    }
}


extension EditorTests {
    func testSpeechPermissionCancellationAndTimeout() async throws {
        let allowed = try await Transcription.requestPermission(cancellation:Cancellation(),request:{ $0(.authorized) })
        XCTAssertEqual(allowed,.authorized)
        let token = Cancellation(); token.cancel()
        do { _ = try await Transcription.requestPermission(cancellation:token,request:{ _ in }); XCTFail("Cancelled permission wait succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        var delayed: ((SFSpeechRecognizerAuthorizationStatus) -> Void)?
        do { _ = try await Transcription.requestPermission(cancellation:Cancellation(),timeout:0.01,request:{ delayed = $0 }); XCTFail("Missing callback did not time out") } catch { XCTAssertTrue(error.localizedDescription.contains("권한")) }
        delayed?(.authorized) // A late system callback must not resume twice.
        delayed?(.denied)
    }
}


extension EditorTests {
    @MainActor func testWaveformTimelineAndWheel() async throws {
        XCTAssertEqual(timelineWheelDestination(current:5,delta:4,precise:false,fine:false,duration:10),4)
        XCTAssertEqual(timelineWheelDestination(current:5,delta:4,precise:false,fine:true,duration:10),4.9,accuracy:0.001)
        XCTAssertEqual(timelineWheelDestination(current:5,delta:10,precise:true,fine:false,duration:10),4.8,accuracy:0.001)
        XCTAssertEqual(timelineWheelDestination(current:0,delta:20,precise:false,fine:false,duration:10),0)
        XCTAssertEqual(timelineWheelDestination(current:10,delta:-20,precise:false,fine:false,duration:10),10)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let source = dir.appendingPathComponent("silent.mov"); try await makeVideo(source)
        let p = try await MediaEngine.load(source)
        let wave = try await AudioWaveform.read(source:source,duration:p.duration,ranges:p.analysisRanges,cancellation:Cancellation())
        XCTAssertFalse(wave.hasAudio); XCTAssertTrue(wave.peaks.isEmpty)
        let store = EditorStore(); store.automaticRecoveryEnabled = false; store.setProject(p)
        XCTAssertTrue(store.timelineRows.contains { $0.kind == .audio })
        store.seek(1); store.selectLane(.audio,lane:0); XCTAssertTrue(store.selectionAvailable)
        store.split(); XCTAssertEqual(store.project.clips.count,2)
        XCTAssertEqual(store.project.editedDuration,2,accuracy:0.01)
        store.undo(); XCTAssertEqual(store.project.clips.count,1)
    }
}

extension EditorTests {
    @MainActor func testLinkedSetsAndGapClose() throws {
        let store = EditorStore(); store.automaticRecoveryEnabled = false
        var p = timelineProject(); p.sourcePath = "/tmp/veil-gap-test.mov"; p.videoLaneCount = 2
        p.clips = [Clip(start:0,end:2,lane:0,position:0),Clip(start:5,end:7,lane:0,position:4),Clip(start:8,end:9,lane:1,position:7)]
        store.setProject(p)
        XCTAssertEqual(store.project.gaps(in:0),[TimelineRange(start:2,end:4)])
        XCTAssertEqual(store.timelineRows.filter{$0.kind == .audio}.map(\.lane),[1,0])
        XCTAssertEqual(store.timelineRows.filter{$0.kind == .faces}.map(\.lane),[1,0])
        let id = store.project.clips[1].id
        store.moveItem(id,to:.audio,lane:1,at:3)
        XCTAssertEqual(store.project.clips[1].lane,1); XCTAssertEqual(store.project.clips[1].position,3)
        store.undo(); XCTAssertEqual(store.project.clips[1].lane,0)
        store.closeGap(TimelineRange(start:2,end:4),lane:0)
        XCTAssertEqual(store.project.clips[1].position,2)
        XCTAssertEqual(store.project.clips[2].position,7)
        XCTAssertEqual(store.project.clips[1].start,5)
        XCTAssertTrue(store.project.gaps(in:0).isEmpty)
        store.undo(); XCTAssertEqual(store.project.clips[1].position,4)
    }
    func testWhisperLocalEngine() async throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let executable = root.appendingPathComponent("Resources/Speech/whisper-cli")
        guard FileManager.default.fileExists(atPath:executable.path) else { print("SKIP Whisper executable not installed"); return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let model = root.appendingPathComponent("Resources/Speech/ggml-base.bin")
        let sample = root.appendingPathComponent(".build/whisper-src/samples/jfk.wav")
        let captions = try await WhisperTranscription.recognize(executable:executable,model:model,audio:sample,result:dir.appendingPathComponent("english"),language:"en",hints:"",cancellation:Cancellation())
        XCTAssertFalse(captions.isEmpty); XCTAssertTrue(captions.map(\.text).joined().lowercased().contains("country"))
        if let path = ProcessInfo.processInfo.environment["VEIL_SPEECH_PROJECT"] {
            let p = try JSONDecoder().decode(Project.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
            if let range = p.analysisRanges.first {
                let audio = dir.appendingPathComponent("test.wav")
                _ = try await Transcription.prepareAudio(source:URL(fileURLWithPath:p.sourcePath),destination:audio,offset:range.start,length:min(15,range.duration),options:SpeechOptions(),cancellation:Cancellation())
                let local = try await WhisperTranscription.recognize(executable:executable,model:model,audio:audio,result:dir.appendingPathComponent("korean"),language:"ko",hints:"",cancellation:Cancellation())
                XCTAssertFalse(local.isEmpty); print("Current video Whisper trial: \(local.count) subtitle segments; accuracy needs manual review")
            }
        }
    }
}
