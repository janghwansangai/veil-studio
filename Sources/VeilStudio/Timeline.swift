import Foundation

struct TimelineRange: Codable, Equatable {
    var start: Double
    var end: Double
    var duration: Double { max(0,end-start) }
}
struct TimelineEntry: Identifiable {
    var clip: Clip
    var index: Int
    var start: Double
    var end: Double { start + clip.duration }
    var id: UUID { clip.id }
}
extension Project {
    var timeline: [TimelineEntry] {
        var cursor = 0.0
        return clips.enumerated().map { i,clip in
            defer { cursor += clip.duration }
            return TimelineEntry(clip:clip,index:i,start:clip.position ?? cursor)
        }
    }
    var exportDuration: Double { exportRange?.duration ?? editedDuration }
    func timelineTime(forSource time: Double, preferredClip: UUID? = nil) -> Double? {
        let matches = timeline.filter { time >= $0.clip.start && time <= $0.clip.end }
        guard let entry = matches.first(where: { $0.id == preferredClip }) ?? matches.first else { return nil }
        return entry.start + time-entry.clip.start
    }
    func clips(in range: TimelineRange) -> [Clip] {
        timeline.compactMap { entry in
            let start = max(range.start,entry.start); let end = min(range.end,entry.end)
            guard end-start > 0.000001 else { return nil }
            return Clip(start:entry.clip.start+start-entry.start,end:entry.clip.start+end-entry.start,lane:entry.clip.lane,position:entry.clip.position == nil ? nil : start-range.start)
        }
    }
    var projectForExport: Project {
        var p = self
        if !isImage, let range = exportRange {
            p.clips = clips(in:range)
            if overlaysOnTimeline == true {
                p.captions = outputCaptions()
                p.regions = regions.compactMap { r in
                    guard min(r.end,range.end) > max(r.start,range.start) else { return nil }
                    var v = r; v.start = max(r.start,range.start)-range.start; v.end = min(r.end,range.end)-range.start
                    v.keyframes = r.keyframes.map { k in var x = k; x.time -= range.start; return x }; return v
                }
            }
        }
        p.exportRange = nil
        return p
    }
    @discardableResult mutating func splitTimeline(at time: Double, clipID: UUID? = nil) -> UUID? {
        let threshold = max(0.001,0.5/fps)
        guard let entry = timeline.first(where:{(clipID == nil || $0.id == clipID) && time > $0.start+threshold && time < $0.end-threshold}) else { return nil }
        let source = entry.clip.start + time-entry.start
        let second = Clip(start:source,end:entry.clip.end,lane:entry.clip.lane,position:entry.clip.position == nil ? nil : time)
        clips[entry.index].end = source; clips.insert(second,at:entry.index+1)
        return second.id
    }
    mutating func removeTimelineClips(_ ids: Set<UUID>) {
        clips.removeAll { ids.contains($0.id) }; exportRange = nil
    }
    @discardableResult mutating func insertTimelineClips(_ source: [Clip], at time: Double) -> [UUID] {
        let t = max(0,min(editedDuration,time))
        _ = splitTimeline(at:t)
        let index = timeline.firstIndex(where:{$0.start >= t-0.000001}) ?? clips.count
        let copies = source.map { Clip(start:$0.start,end:$0.end) }
        clips.insert(contentsOf:copies,at:index); exportRange = nil
        return copies.map(\.id)
    }
    mutating func moveTimelineClip(_ id: UUID, before destination: UUID?) {
        guard id != destination, let old = clips.firstIndex(where:{$0.id == id}) else { return }
        let clip = clips.remove(at:old)
        let next = destination.flatMap { target in clips.firstIndex(where:{$0.id == target}) } ?? clips.count
        clips.insert(clip,at:next); exportRange = nil
    }
    mutating func deleteTimelineRange(_ range: TimelineRange) {
        let left = clips(in:TimelineRange(start:0,end:range.start))
        let right = clips(in:TimelineRange(start:range.end,end:editedDuration))
        clips = left + right; exportRange = nil
    }
}

// Each visible occurrence retains its source identity when cuts repeat.
struct OverlayTimelineItem: Identifiable {
    var id: String { sourceID.uuidString }
    var sourceID: UUID
    var clip: TimelineEntry
    var start: Double
    var end: Double
    var title: String
    var region: Bool
}
extension Project {
    func overlayItems(regionsOnly: Bool) -> [OverlayTimelineItem] {
        if overlaysOnTimeline == true {
            let entry = TimelineEntry(clip:Clip(start:0,end:editedDuration),index:0,start:0)
            let values: [(UUID,Double,Double,String)] = regionsOnly ? regions.map { ($0.id,$0.start,$0.end,$0.name) } : captions.map { ($0.id,$0.start,$0.end,$0.text) }
            return values.map { OverlayTimelineItem(sourceID:$0.0,clip:entry,start:$0.1,end:$0.2,title:$0.3,region:regionsOnly) }
        }
        return timeline.flatMap { entry in
            let values: [(UUID,Double,Double,String)] = regionsOnly
                ? regions.map { ($0.id,$0.start,$0.end,$0.name) }
                : captions.map { ($0.id,$0.start,$0.end,$0.text) }
            return values.compactMap { id,start,end,title -> OverlayTimelineItem? in
                let a = max(start,entry.clip.start), b = min(end,entry.clip.end)
                guard b > a else { return nil }
                return OverlayTimelineItem(sourceID:id,clip:entry,start:entry.start+a-entry.clip.start,end:entry.start+b-entry.clip.start,title:title,region:regionsOnly)
            }
        }
    }
}

extension Project {
    mutating func migrateOverlayTimeline() {
        guard !isImage, overlaysOnTimeline != true else { return }
        captions = outputCaptions(respectExportRange:false)
        let old = regions
        regions = timeline.flatMap { entry in old.compactMap { r -> ManualRegion? in
            let a = max(r.start,entry.clip.start), b = min(r.end,entry.clip.end)
            guard b > a else { return nil }
            var v = r; v.id = UUID(); v.start = entry.start+a-entry.clip.start; v.end = entry.start+b-entry.clip.start
            v.rect = r.rect(at:a)
            v.keyframes = [RegionKeyframe(time:v.start,rect:r.rect(at:a))] + r.keyframes.filter { $0.time > a && $0.time < b }.map { RegionKeyframe(time:entry.start+$0.time-entry.clip.start,rect:$0.rect) } + [RegionKeyframe(time:v.end,rect:r.rect(at:b))]
            if r.keyframes.isEmpty { v.keyframes = [] }; return v
        } }
        overlaysOnTimeline = true
    }
}

extension Project {
    @discardableResult mutating func repairEditableTimes() -> Int {
        var count = 0
        let frame = 1/max(1,fps)
        for i in captions.indices where captions[i].start.isFinite && captions[i].end.isFinite {
            if captions[i].start < 0 { captions[i].start = 0; count += 1 }
            if captions[i].end <= captions[i].start { captions[i].end = captions[i].start+frame; count += 1 }
        }
        return count
    }
}

extension Project {
    var visibleTimeline: [TimelineEntry] {
        guard (videoLaneCount ?? 1) > 1 else { return timeline }
        let entries = timeline
        let edges = Array(Set(entries.flatMap { [$0.start,$0.end] })).sorted()
        return zip(edges,edges.dropFirst()).compactMap { a,b in
            guard b > a, let top = entries.filter({$0.start <= a && $0.end >= b}).max(by:{($0.clip.lane ?? 0) < ($1.clip.lane ?? 0)}) else { return nil }
            var c = top.clip; c.start += a-top.start; c.end = c.start+b-a; c.position = a
            return TimelineEntry(clip:c,index:top.index,start:a)
        }
    }
    var analysisRanges: [TimelineRange] {
        let ranges = clips.map { TimelineRange(start:$0.start,end:$0.end) }.sorted { $0.start < $1.start }
        var result: [TimelineRange] = []
        for r in ranges {
            if let last = result.last, r.start <= last.end { result[result.count-1].end = max(last.end,r.end) }
            else { result.append(r) }
        }
        return result
    }
    mutating func enableVideoLanes() {
        let entries = timeline
        for entry in entries { clips[entry.index].position = entry.start }
    }
    mutating func separateOverlappingOverlays() {
        var ends: [Int:Double] = [:]
        for index in captions.indices.sorted(by:{captions[$0].start < captions[$1].start}) {
            var lane = captions[index].lane ?? 0
            if (ends[lane] ?? -1) > captions[index].start {
                lane = (0...captions.count).first { (ends[$0] ?? -1) <= captions[index].start } ?? lane
            }
            captions[index].lane = lane; ends[lane] = captions[index].end
        }
        captionLaneCount = max(captionLaneCount ?? 1,(ends.keys.max() ?? 0)+1)
        ends = [:]
        for index in regions.indices.sorted(by:{regions[$0].start < regions[$1].start}) {
            var lane = regions[index].lane ?? 0
            if (ends[lane] ?? -1) > regions[index].start {
                lane = (0...regions.count).first { (ends[$0] ?? -1) <= regions[index].start } ?? lane
            }
            regions[index].lane = lane; ends[lane] = regions[index].end
        }
        regionLaneCount = max(regionLaneCount ?? 1,(ends.keys.max() ?? 0)+1)
    }
}

struct TimelineRow: Identifiable {
    var kind: EditTrack
    var lane: Int
    var id: String { "\(kind.rawValue)-\(lane)" }
    var title: String { (kind == .faces || kind == .audio) ? "\(kind == .audio ? "오디오" : "얼굴 마스크") \(lane+1) · 연결" : "\(kind.rawValue) \(lane+1)" }
}

func mappedSourceTime(_ entries: [TimelineEntry], at time: Double) -> Double {
    var low = 0, high = entries.count
    while low < high { let mid = (low+high)/2; if entries[mid].end <= time { low = mid+1 } else { high = mid } }
    if low < entries.count, time >= entries[low].start { return entries[low].clip.start+time-entries[low].start }
    if let last = entries.last, time >= last.end { return last.clip.end }
    return -1
}

extension Project {
    func gaps(in lane: Int) -> [TimelineRange] {
        var cursor = 0.0; var result: [TimelineRange] = []
        for entry in timeline.filter({($0.clip.lane ?? 0) == lane}).sorted(by:{$0.start < $1.start}) {
            if entry.start-cursor > 0.000001 { result.append(TimelineRange(start:cursor,end:entry.start)) }
            cursor = max(cursor,entry.end)
        }
        return result
    }
}
