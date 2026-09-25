import Foundation
import CoreImage
#if !VEIL_STANDALONE_TESTS
import XCTest
@testable import VeilStudio
#endif

extension EditorTests {
    func testIndependentMaskDesignsAndMigration() throws {
        var p = Project(); p.isImage = true; p.width = 200; p.height = 100; p.maskApplied = true
        var face = MaskDesign(); face.effect = .solid; face.shape = .rectangle; face.red = 0; face.green = 0; face.blue = 1; face.margin = 0
        var region = face; region.red = 0; region.green = 1; region.blue = 0; region.shape = .oval
        p.effectiveFaceDesign = face; p.effectiveRegionDesign = region
        p.faces = [FaceTrack(name:"Face",samples:[FaceSample(time:0,rect:NormalRect(x:0.1,y:0.2,width:0.2,height:0.6))])]
        p.regions = [ManualRegion(name:"Region",start:0,end:0,rect:NormalRect(x:0.7,y:0.2,width:0.2,height:0.6))]
        let renderer = MaskRenderer(); let source = CIImage(color:.red).cropped(to:CGRect(x:0,y:0,width:200,height:100))
        let result = renderer.render(source,project:p,time:0,crop:false)
        XCTAssertGreaterThan(pixel(result,40,50,context:renderer.context)[2],230)
        XCTAssertGreaterThan(pixel(result,160,50,context:renderer.context)[1],230)
        XCTAssertLessThan(pixel(result,160,50,context:renderer.context)[2],20)
        let saved = try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p))
        XCTAssertEqual(saved.effectiveFaceDesign,face); XCTAssertEqual(saved.effectiveRegionDesign,region)
        var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
        legacy.removeValue(forKey:"faceDesign"); legacy.removeValue(forKey:"regionDesign")
        var migrated = try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertEqual(migrated.effectiveFaceDesign,migrated.design); XCTAssertEqual(migrated.effectiveRegionDesign,migrated.design)
        let oldFace = migrated.effectiveFaceDesign; migrated.effectiveRegionDesign = region
        XCTAssertEqual(migrated.effectiveFaceDesign,oldFace)
    }
    func testOffscreenFaceRepair() throws {
        var p = Project(); p.width = 1920; p.height = 1080; p.duration = 3
        p.faces = [FaceTrack(name:"Edge",samples:[FaceSample(time:1,rect:NormalRect(x:-0.01,y:0.4,width:0.06,height:0.1)),FaceSample(time:2,rect:NormalRect(x:0.98,y:0.95,width:0.1,height:0.1))])]
        XCTAssertThrowsError(try p.validate())
        XCTAssertEqual(try p.repairFaceBounds(),2); XCTAssertNoThrow(try p.validate())
        XCTAssertEqual(p.faces[0].samples.count,2)
        XCTAssertEqual(p.faces[0].samples[0].rect.x,0); XCTAssertEqual(p.faces[0].samples[0].rect.width,0.05,accuracy:0.00001)
        XCTAssertEqual(try p.repairFaceBounds(),0)
        p.faces[0].samples[0].rect.width = -1; XCTAssertThrowsError(try p.repairFaceBounds())
    }
    func testNoSpeechChunkContinuesAndKeepsTimeline() {
        XCTAssertTrue(SpeechDiagnostics.isNoSpeech(NSError(domain:"kAFAssistantErrorDomain",code:1110)))
        XCTAssertFalse(SpeechDiagnostics.isNoSpeech(NSError(domain:"OtherError",code:1110)))
        XCTAssertFalse(SpeechDiagnostics.isNoSpeech(NSError(domain:"kAFAssistantErrorDomain",code:1101)))
        var report = TranscriptionReport(captions:[],warnings:[])
        SpeechDiagnostics.accumulate(SpeechChunkResult(captions:[],warning:"No speech"),offset:0,length:45,duration:90,report:&report)
        SpeechDiagnostics.accumulate(SpeechChunkResult(captions:[Caption(start:2,end:5,text:"대사")]),offset:45,length:45,duration:90,report:&report)
        XCTAssertEqual(report.captions.count,1); XCTAssertEqual(report.captions[0].start,47); XCTAssertEqual(report.captions[0].end,50); XCTAssertEqual(report.warnings.count,1)
        SpeechDiagnostics.accumulate(SpeechChunkResult(captions:[Caption(start:0,end:20,text:"마지막")],warning:"부분 복구"),offset:89,length:1,duration:90,report:&report)
        XCTAssertEqual(report.captions.last!.end,90); XCTAssertEqual(report.warnings.count,2)
    }
    func testExistingUserProjectRecovery() throws {
        guard let path = ProcessInfo.processInfo.environment["VEIL_PROJECT_FIXTURE"] else { print("SKIP existing project fixture"); return }
        var p = try JSONDecoder().decode(Project.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let oldFaces = p.faces.count; let oldSamples = p.faces.reduce(0) { $0 + $1.samples.count }; let selection = p.faces.map(\.selected)
        let oldCaptions = p.captions; let oldRegions = p.regions
        let repaired = try p.repairFaceBounds(); try p.validate()
        XCTAssertEqual(p.faces.count,oldFaces); XCTAssertEqual(p.faces.reduce(0) { $0 + $1.samples.count },oldSamples)
        XCTAssertEqual(p.faces.map(\.selected),selection); XCTAssertEqual(p.captions,oldCaptions); XCTAssertEqual(p.regions,oldRegions)
        if let destination = ProcessInfo.processInfo.environment["VEIL_RECOVERED_PROJECT"] {
            try JSONEncoder().encode(p).write(to:URL(fileURLWithPath:destination),options:.atomic)
        }
        print("Existing project: \(repaired) edge coordinates repaired; all \(oldSamples) samples retained")
    }
    func testLegacyProjectVideoExport() async throws {
        guard let path = ProcessInfo.processInfo.environment["VEIL_PROJECT_FIXTURE"] else { print("SKIP legacy project export"); return }
        var p = try JSONDecoder().decode(Project.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let start = min(78,max(0,p.duration-1)); p.clips = [Clip(start:start,end:min(p.duration,start+1))]; p.export.resolution = .hd
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("veil-edge-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at:url) }
        // Pass the original out-of-bounds data to export, exercising automatic repair.
        try await MediaEngine.export(p,to:url,cancellation:Cancellation(),progress:{_,_ in})
        let output = try await MediaEngine.load(url)
        XCTAssertEqual(output.duration,1,accuracy:0.08); XCTAssertEqual(output.width,1280)
    }

}
