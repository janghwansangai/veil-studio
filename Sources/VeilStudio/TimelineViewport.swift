import SwiftUI

// Visible window of the timeline: seconds at the left edge and zoom in pixels per second.
// Kept apart from the store so scrolling does not redraw the whole editor.
@MainActor final class TimelineViewport: ObservableObject {
    @Published var pixelsPerSecond = 60.0
    @Published var offset = 0.0
    @Published var width = 800.0
    @Published var fitted = true
    var duration = 1.0
    static let minPPS = 0.5, maxPPS = 1200.0
    func x(_ time: Double) -> Double { (time-offset)*pixelsPerSecond }
    func time(_ x: Double) -> Double { offset+x/max(0.0001,pixelsPerSecond) }
    var visible: TimelineRange { TimelineRange(start:offset,end:offset+width/max(0.0001,pixelsPerSecond)) }
    func update(width: Double, duration: Double) {
        let w = max(100,width), d = max(0.5,duration)
        let changed = abs(w-self.width) > 0.5 || abs(d-self.duration) > 0.0001
        self.width = w; self.duration = d
        if fitted { fit() } else if changed { clamp() }
    }
    func fit() {
        fitted = true
        let pps = min(Self.maxPPS,max(Self.minPPS,width*0.97/max(0.5,duration)))
        if abs(pps-pixelsPerSecond) > 0.0001 { pixelsPerSecond = pps }
        if offset != 0 { offset = 0 }
    }
    func zoom(by factor: Double, around anchor: Double? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        let t = anchor ?? (offset+width/pixelsPerSecond/2)
        let ax = x(t)
        pixelsPerSecond = min(Self.maxPPS,max(Self.minPPS,pixelsPerSecond*factor))
        offset = t-ax/pixelsPerSecond; fitted = false; clamp()
    }
    // Slider position 0...1 on a logarithmic scale.
    var zoomLevel: Double {
        get { log(pixelsPerSecond/Self.minPPS)/log(Self.maxPPS/Self.minPPS) }
        set { let pps = Self.minPPS*pow(Self.maxPPS/Self.minPPS,max(0,min(1,newValue))); zoom(by:pps/pixelsPerSecond) }
    }
    func scroll(seconds: Double) { guard seconds.isFinite else { return }; offset += seconds; fitted = false; clamp() }
    func clamp() {
        let span = width/max(0.0001,pixelsPerSecond)
        let maxOffset = max(0,duration+span*0.25-span)
        offset = min(maxOffset,max(0,offset))
    }
    // Keeps the playhead on screen while playing, paging like an editor does.
    func follow(_ time: Double) {
        let v = visible
        if time > v.end-(v.end-v.start)*0.03 || time < v.start { offset = max(0,time-(v.end-v.start)*0.1); fitted = false; clamp() }
    }
    // Tick spacing for the ruler: major ticks at least ~90 px apart.
    var tickSteps: (major: Double, minor: Double) {
        let candidates: [Double] = [1.0/30,0.1,0.2,0.5,1,2,5,10,15,30,60,120,300,600,1200,1800,3600]
        let major = candidates.first { $0*pixelsPerSecond >= 90 } ?? 3600
        let minor = major >= 60 ? major/6 : major >= 1 ? major/5 : major/2
        return (major,minor)
    }
}

func rulerLabel(_ seconds: Double, step: Double) -> String {
    guard seconds.isFinite else { return "" }
    let s = max(0,seconds)
    if step < 1 { return String(format:"%d:%04.1f",Int(s)/60,s.truncatingRemainder(dividingBy:60)) }
    if s >= 3600 { return String(format:"%d:%02d:%02d",Int(s)/3600,(Int(s)/60)%60,Int(s)%60) }
    return String(format:"%d:%02d",Int(s)/60,Int(s)%60)
}
