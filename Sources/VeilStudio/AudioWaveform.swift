import Foundation
import AVFoundation

struct AudioWaveform {
    var peaks: [Float]
    var duration: Double
    var ranges: [TimelineRange]
    var hasAudio: Bool
    func peak(from start: Double, to end: Double) -> Float {
        guard !peaks.isEmpty, duration > 0, start >= 0, start < duration else { return 0 }
        let a = max(0,min(peaks.count-1,Int(start/duration*Double(peaks.count))))
        let b = max(a+1,min(peaks.count,Int(ceil(end/duration*Double(peaks.count)))))
        return peaks[a..<b].max() ?? 0
    }
    func covers(_ requested: [TimelineRange]) -> Bool {
        requested.allSatisfy { r in ranges.contains { $0.start <= r.start && $0.end >= r.end } }
    }
    static func read(source: URL, duration: Double, ranges: [TimelineRange], cancellation: Cancellation) async throws -> AudioWaveform {
        try await Task.detached(priority:.utility) {
            let asset = AVURLAsset(url:source)
            guard let track = try await asset.loadTracks(withMediaType:.audio).first else { return AudioWaveform(peaks:[],duration:duration,ranges:ranges,hasAudio:false) }
            let count = max(1,min(120_000,Int(ceil(min(duration,1200)*100))))
            var peaks = [Float](repeating:0,count:count)
            for range in ranges {
                try cancellation.check()
                let reader = try AVAssetReader(asset:asset)
                reader.timeRange = CMTimeRange(start:CMTime(seconds:range.start,preferredTimescale:60000),duration:CMTime(seconds:range.duration,preferredTimescale:60000))
                let output = AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false,AVLinearPCMIsBigEndianKey:false])
                guard reader.canAdd(output) else { throw StudioError.message("오디오 파형 변환을 지원하지 않는 형식입니다.") }
                reader.add(output); defer { reader.cancelReading() }
                guard reader.startReading() else { throw reader.error ?? StudioError.message("파형 읽기 실패") }
                while let sample = output.copyNextSampleBuffer() {
                    try cancellation.check()
                    try autoreleasepool {
                        let n = CMSampleBufferGetNumSamples(sample)
                        guard n > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return }
                        var values = [Float](repeating:0,count:n)
                        let result = values.withUnsafeMutableBytes { raw in CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:n*MemoryLayout<Float>.size,destination:raw.baseAddress!) }
                        guard result == kCMBlockBufferNoErr else { throw StudioError.message("파형 샘플 읽기 실패") }
                        let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        guard start.isFinite else { return }
                        for i in 0..<n {
                            let time = start+Double(i)/16000
                            guard time >= range.start, time < range.end, time < duration, values[i].isFinite else { continue }
                            let index = max(0,min(count-1,Int(time/duration*Double(count))))
                            peaks[index] = max(peaks[index],min(1,abs(values[i])))
                        }
                    }
                }
                guard reader.status == .completed else { throw reader.error ?? StudioError.message("파형 읽기 중단") }
            }
            try cancellation.check()
            return AudioWaveform(peaks:peaks,duration:duration,ranges:ranges,hasAudio:true)
        }.value
    }
}

func timelineWheelDestination(current: Double, delta: Double, precise: Bool, fine: Bool, duration: Double) -> Double {
    guard delta.isFinite, current.isFinite, duration.isFinite else { return current }
    let step = (precise ? 0.02 : 0.25)*(fine ? 0.1 : 1)
    return min(max(0,duration),max(0,current-delta*step))
}
