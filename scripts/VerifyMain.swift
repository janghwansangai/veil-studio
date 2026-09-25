import Foundation

class XCTestCase {}
var failures = 0
var assertions = 0
func record(_ ok: Bool,_ message: String,file: StaticString = #filePath,line: UInt = #line) {
    assertions += 1
    if !ok { failures += 1; print("FAIL \(file):\(line): \(message)") }
}
func XCTAssertEqual<T: Equatable>(_ a: T,_ b: T,file: StaticString = #filePath,line: UInt = #line) { record(a == b,"\(a) != \(b)",file:file,line:line) }
func XCTAssertEqual(_ a: Double,_ b: Double,accuracy: Double,file: StaticString = #filePath,line: UInt = #line) { record(abs(a-b) <= accuracy,"\(a) != \(b) ± \(accuracy)",file:file,line:line) }
func XCTAssertTrue(_ a: Bool,file: StaticString = #filePath,line: UInt = #line) { record(a,"Expected true",file:file,line:line) }
func XCTAssertFalse(_ a: Bool,file: StaticString = #filePath,line: UInt = #line) { record(!a,"Expected false",file:file,line:line) }
func XCTAssertNil<T>(_ a: T?,file: StaticString = #filePath,line: UInt = #line) { record(a == nil,"Expected nil",file:file,line:line) }
func XCTAssertNotNil<T>(_ a: T?,file: StaticString = #filePath,line: UInt = #line) { record(a != nil,"Expected value",file:file,line:line) }
func XCTAssertGreaterThan<T: Comparable>(_ a: T,_ b: T,file: StaticString = #filePath,line: UInt = #line) { record(a > b,"\(a) is not > \(b)",file:file,line:line) }
func XCTAssertLessThan<T: Comparable>(_ a: T,_ b: T,file: StaticString = #filePath,line: UInt = #line) { record(a < b,"\(a) is not < \(b)",file:file,line:line) }
func XCTAssertNotEqual<T: Equatable>(_ a: T,_ b: T,file: StaticString = #filePath,line: UInt = #line) { record(a != b,"\(a) == \(b)",file:file,line:line) }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T,_ b: T,file: StaticString = #filePath,line: UInt = #line) { record(a <= b,"\(a) is not <= \(b)",file:file,line:line) }
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: T,_ b: T,file: StaticString = #filePath,line: UInt = #line) { record(a >= b,"\(a) is not >= \(b)",file:file,line:line) }
func XCTFail(_ message: String,file: StaticString = #filePath,line: UInt = #line) { record(false,message,file:file,line:line) }
func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T,file: StaticString = #filePath,line: UInt = #line) { do { _ = try body(); record(false,"Expected error",file:file,line:line) } catch { record(true,"",file:file,line:line) } }
func XCTAssertNoThrow<T>(_ body: @autoclosure () throws -> T,file: StaticString = #filePath,line: UInt = #line) { do { _ = try body(); record(true,"",file:file,line:line) } catch { record(false,error.localizedDescription,file:file,line:line) } }

@main struct Verify {
    static func main() async {
        setbuf(stdout,nil)
        let suite = EditorTests()
        let tests: [(String,() async throws -> Void)] = [
            ("Save safety / stale controls / repeated media switch", { try await suite.testProjectSaveAndStaleControls() }),
            ("Speech PCM / TIFF HEIC MOV exports", { try await suite.testSpeechPCMAndAdditionalFormats() }),
            ("Speech permission cancellation / timeout", { try await suite.testSpeechPermissionCancellationAndTimeout() }),
            ("Waveform track / wheel / linked cut", { try await suite.testWaveformTimelineAndWheel() }),
            ("Linked track sets / gap close", { try await suite.testLinkedSetsAndGapClose() }),
            ("Local Whisper English / Korean trial", { try await suite.testWhisperLocalEngine() }),
            ("Timeline / captions", { suite.testTimelineMapsCutsAndCaptions() }),
            ("SRT parsing / roundtrip", { suite.testSubtitleRoundtripAndMalformedInput() }),
            ("Face disappearance / interpolation", { suite.testFaceInterpolationDoesNotBridgeDisappearance() }),
            ("Keyframes / crop geometry", { suite.testKeyframesAndCropGeometry() }),
            ("Project validation", { suite.testInvalidProjectsRejected() }),
            ("All mask shapes / effects", { suite.testMaskPixelsAndUnselectedFace() }),
            ("Image export / cancellation", { try await suite.testImageExportCropAndCancellation() }),
            ("Video export / cuts / masks / captions", { try await suite.testVideoExportBurnsMaskCutsCropAndSubtitles() }),
            ("Portrait transform export", { try await suite.testPortraitOrientation() }),
            ("Audio preservation / mute", { try await suite.testAudioPreservationAndMute() }),
            ("Reference image face detection", { try await suite.testReferenceImageFaces() }),
            ("Moving face masking across video", { try await suite.testMovingFaceIsMaskedThroughoutVideo() }),
            ("Independent face / region designs and legacy projects", { try suite.testIndependentMaskDesignsAndMigration() }),
            ("Offscreen face coordinate repair", { try suite.testOffscreenFaceRepair() }),
            ("No-speech intro continues to later dialogue", { suite.testNoSpeechChunkContinuesAndKeepsTimeline() }),
            ("Existing project recovery", { try suite.testExistingUserProjectRecovery() }),
            ("Legacy out-of-bounds project MP4 export", { try await suite.testLegacyProjectVideoExport() }),
            ("Ripple delete / move / paste / duplicate", { try suite.testRippleDeleteMovePasteAndDuplicate() }),
            ("Export selection / subtitle clipping", { try suite.testSelectionRangeSlicesCutsAndCaptions() }),
            ("Reordered selected MP4 pixels", { try await suite.testReorderedSelectedExportPixels() }),
            ("Overlay lanes / retained analysis ranges", { try suite.testOverlayLanesAndAnalysisRanges() }),
            ("Layered video / gaps MP4", { try await suite.testLayeredVideoExport() }),
            ("Independent overlay tracks / migration / split", { try await suite.testIndependentOverlayTracks() }),
            ("Editor commands / composed preview / undo", { try await suite.testEditorCommandsAndComposedPreview() }),
            ("v0.8 rotated video matches system player", { try await suite.testOrientationMatchesSystemPlayer() }),
            ("v0.8 multi-source / speed / freeze / dissolve / PiP / colour / title", { try await suite.testMultiSourceSpeedFreezeTransitionAndLayers() }),
            ("v0.8 independent audio / volume / music tail", { try await suite.testIndependentAudioAndVolume() }),
            ("v0.8 timeline speed / transition editing", { try suite.testTimelineSpeedTransitionEditing() }),
            ("v0.8 project v2 coding / v1 migration / saved projects", { try suite.testProjectV2CodingAndLegacyMigration() }),
            ("v0.8 face matching / grouping / gap bridging", { suite.testFaceAssociationGroupingAndBridging() }),
            ("v0.8 caption segmenter / timeline mapping", { suite.testCaptionSegmenterAndTimelineMapping() }),
            ("v0.8 multi-source store / batch queue", { try await suite.testMultiSourceStoreAndBatchQueue() }),
            ("v0.8 Korean speech accuracy with noise", { try await suite.testKoreanSpeechAccuracyWithNoise() }),
            ("v0.8 700 random edits stay valid", { try await suite.testRandomEditingStaysValid() }),
            ("v0.8 long timeline performance", { try suite.testLongTimelinePerformance() }),
            ("v0.8.1 background analysis while editing", { try await suite.testBackgroundAnalysisWhileEditing() })
        ]
        for (name,run) in tests {
            let start = Date(); let before = failures
            do { try await run() } catch { XCTFail("\(name): \(error)") }
            print("\(before == failures ? "PASS" : "FAIL") \(name) (\(String(format:"%.2f",Date().timeIntervalSince(start)))s)")
        }
        print("\(tests.count) tests, \(assertions) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
