import Foundation
import AppKit
#if !VEIL_STANDALONE_TESTS
import XCTest
@testable import VeilStudio
#endif

extension EditorTests {
    // Hundreds of random edits must never leave an invalid project, a non-finite duration or crash.
    @MainActor func testRandomEditingStaysValid() async throws {
        _ = NSApplication.shared
        struct Rng { var s: UInt64; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }; mutating func unit() -> Double { Double(next() % 10_000)/10_000 }; mutating func pick(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) } }
        var rng = Rng(s:0x9E3779B97F4A7C15)
        var base = timelineProject(); base.sourcePath = "/tmp/veil-stress-a.mov"; base.fps = 30
        var second = MediaSource(); second.path = "/tmp/veil-stress-b.mov"; second.duration = 6; second.width = 720; second.height = 1280; second.fps = 30
        base.media.append(second); base.normalizeSources()
        base.captions = [Caption(start:0.5,end:2,text:"가"),Caption(start:3,end:5,text:"나")]
        base.regions = [ManualRegion(name:"r",start:0,end:4,rect:NormalRect(x:0.1,y:0.1,width:0.2,height:0.2))]
        let store = EditorStore(); store.automaticRecoveryEnabled = false; store.setProject(base)
        var failures = 0
        for step in 0..<700 {
            let duration = max(0.1,store.project.editedDuration)
            store.playhead = rng.unit()*duration
            let clips = store.project.clips
            if let c = clips.isEmpty ? nil : clips[rng.pick(clips.count)] { store.selectClip(c.id,extending:rng.pick(5) == 0) }
            switch rng.pick(22) {
            case 0: store.split()
            case 1: store.deleteClip()
            case 2: store.copyClips(); store.pasteClips()
            case 3: store.moveSelected(rng.pick(2) == 0 ? -1 : 1)
            case 4: store.setSpeed([0.25,0.5,1,2,3,8][rng.pick(6)])
            case 5: store.setTransition([TransitionKind.dissolve,.dipToBlack,.wipe,.slide][rng.pick(4)],duration:0.2+rng.unit())
            case 6: store.setTransition(nil)
            case 7: store.addFreezeFrame(length:0.5+rng.unit()*2)
            case 8: if let c = store.selectedClip { store.trimClip(c,start:rng.unit()*10) }
            case 9: if let c = store.selectedClip { store.trimClip(c,end:rng.unit()*12) }
            case 10: store.undo()
            case 11: store.redo()
            case 12: if let c = store.selectedClip { store.moveItem(c,to:.video,lane:rng.pick(3),at:rng.unit()*duration) }
            case 13: if let g = store.project.gaps(in:rng.pick(2)).first { store.closeGap(g,lane:0) }
            case 14: store.setExportRange(start:rng.unit()*duration,end:rng.unit()*duration); store.deleteMarkedRange()
            case 15: if let id = store.project.media.randomElement()?.id { store.appendToTimeline(id) }
            case 16: if let id = store.project.media.last?.id { store.connectAtPlayhead(id) }
            case 17: store.addTitle(text:"t\(step)"); store.split()
            case 18: store.addMarker(); store.jumpMarker(-1)
            case 19: if let c = store.project.captions.first { store.editOverlayTime(id:c.id,kind:.captions,original:TimelineRange(start:c.start,end:c.end),delta:rng.unit()*4-2,edge:rng.pick(3)-1) }
            case 20: store.updateClips { $0.transform = ClipTransform(scale:0.2+rng.unit()*2,x:rng.unit()-0.5,y:rng.unit()-0.5,rotation:rng.unit()*90); $0.volume = rng.unit()*2 }
            default: if let id = store.selectedClip, store.project.source(store.project.clips.first { $0.id == id }?.source)?.hasAudio == true { store.detachAudio() }
            }
            let p = store.project
            do { try p.validate() } catch { failures += 1; if failures < 5 { XCTFail("step \(step): \(error.localizedDescription)") } }
            XCTAssertTrue(p.editedDuration.isFinite && p.editedDuration >= 0)
            XCTAssertTrue(p.timeline.allSatisfy { $0.start.isFinite && $0.end >= $0.start })
            _ = p.visibleTimeline; _ = p.clips(in:TimelineRange(start:0,end:p.editedDuration)); _ = p.outputCaptions()
            if step % 35 == 0, p.editedDuration > 0 {
                // Composition layout and frame rendering on the edited timeline (media offline: slates).
                let built = try await CompositionBuilder.buildTimeline(p,muted:false,allowMissing:true)
                let (video,plan) = CompositionBuilder.videoComposition(built,project:p,purpose:.preview,renderer:store.renderer,cancellation:nil,stills:StillCache(),previewEdge:320)
                XCTAssertEqual(video.instructions.first?.timeRange.start.value,0)
                XCTAssertEqual(video.instructions.last?.timeRange.end.value,built.totalTicks)
                for (a,b) in zip(video.instructions,video.instructions.dropFirst()) { XCTAssertEqual(a.timeRange.end,b.timeRange.start) }
                if let instruction = video.instructions.randomElement() as? VeilInstruction {
                    let image = plan.frame(at:instruction.timeRange.start.seconds+0.001,layers:instruction.layers) { _ in nil }
                    XCTAssertEqual(image.extent.size,plan.renderSize)
                }
            }
            if store.project.clips.isEmpty { store.setProject(base) }
        }
        XCTAssertEqual(failures,0)
        let data = try JSONEncoder().encode(store.project); XCTAssertEqual(try JSONDecoder().decode(Project.self,from:data),store.project)
        store.pause()
    }
    // A long timeline keeps timeline maths fast enough for interactive editing.
    func testLongTimelinePerformance() throws {
        var p = timelineProject(); p.duration = 3600; p.fps = 30
        var clips: [Clip] = []
        for i in 0..<1500 {
            let s = Double(i%3500)
            var c = Clip(start:s,end:s+0.9)
            if i % 7 == 0 { c.transition = Transition(duration:0.2) }
            clips.append(c)
        }
        p.clips = clips
        p.captions = (0..<2000).map { Caption(start:Double($0)*0.6,end:Double($0)*0.6+0.5,text:"자막") }
        var track = FaceTrack(name:"f",samples:[]); track.samples = (0..<108_000).map { FaceSample(time:Double($0)/30,rect:NormalRect(x:0.4,y:0.4,width:0.1,height:0.1)) }
        p.faces = [track]
        let start = Date()
        for _ in 0..<20 { _ = p.timeline; _ = p.editedDuration }
        _ = p.visibleTimeline; p.separateOverlappingOverlays()
        for t in stride(from:0.0,to:3600,by:0.5) { _ = track.rect(at:t,bridge:1,hold:0.25) }
        let data = try JSONEncoder().encode(p); let back = try JSONDecoder().decode(Project.self,from:data)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(back.faces[0].samples.count,108_000)
        XCTAssertLessThan(elapsed,6)
        print(String(format:"Long timeline: 1500 cuts, 2000 captions, 108k face samples · %.2fs · project %.1f MB",elapsed,Double(data.count)/1_000_000))
    }
}

extension EditorTests {
    // Analysis and speech run in the background: editing continues and results land afterwards.
    @MainActor func testBackgroundAnalysisWhileEditing() async throws {
        _ = NSApplication.shared
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at:dir) }
        let a = dir.appendingPathComponent("a.mov"); try await makeVideo(a)
        let store = EditorStore(); store.automaticRecoveryEnabled = false; store.autoCaptions = false
        store.addMedia([a],newProject:true)
        for _ in 0..<200 { if !store.busy && store.loaded { break }; try await Task.sleep(nanoseconds:20_000_000) }
        store.analysisMode = .fast
        store.analyze()
        XCTAssertFalse(store.busy); XCTAssertEqual(store.backgroundTasks.count,1); XCTAssertTrue(store.canEditTimeline)
        XCTAssertTrue(store.isAnalyzing(store.project.media[0].id))
        store.analyze(); XCTAssertEqual(store.backgroundTasks.count,1)          // no duplicate run
        store.seek(1); store.split(); store.addTitle(text:"편집 중"); store.addMarker()   // editing continues
        for _ in 0..<500 { if store.backgroundTasks.isEmpty { break }; try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertTrue(store.backgroundTasks.isEmpty)
        XCTAssertTrue(store.project.media[0].analysisComplete)
        XCTAssertEqual(store.project.clips.count,2); XCTAssertEqual(store.project.titles.count,1); XCTAssertEqual(store.project.markers.count,1)
        // Cancelling keeps the previous result; opening another project cancels running work.
        store.analyze(); let id = store.backgroundTasks[0].id; store.cancelBackground(id)
        for _ in 0..<300 { if store.backgroundTasks.isEmpty { break }; try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertTrue(store.backgroundTasks.isEmpty); XCTAssertTrue(store.project.media[0].analysisComplete)
        store.analyze(); store.setProject(store.project)
        XCTAssertTrue(store.backgroundTasks.isEmpty)
        try await Task.sleep(nanoseconds:500_000_000)
        XCTAssertTrue(store.backgroundTasks.isEmpty)
        store.pause()
    }
}
