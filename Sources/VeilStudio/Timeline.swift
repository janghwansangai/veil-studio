import Foundation

struct TimelineRange: Codable, Equatable {
    var start: Double
    var end: Double
    var duration: Double { max(0,end-start) }
    func contains(_ time: Double) -> Bool { time >= start && time < end }
    func intersects(_ other: TimelineRange) -> Bool { min(end,other.end) > max(start,other.start) }
}
struct TimelineEntry: Identifiable {
    var clip: Clip
    var index: Int
    var start: Double
    // Portion at the start of this entry that overlaps `previous` for a transition.
    var overlap = 0.0
    var previous: UUID?
    var end: Double { start + clip.timelineDuration }
    var id: UUID { clip.id }
    var lane: Int { clip.lane ?? 0 }
    func sourceTime(at time: Double) -> Double { clip.sourceTime(offset:time-start) }
}
enum EditTrack: String, CaseIterable {
    case video = "영상", audio = "오디오 · 영상 연결", faces = "얼굴 · 영상 연결", regions = "영역 마스크", captions = "자막", titles = "타이틀", music = "오디오"
    var linkedToVideo: Bool { self == .video || self == .faces || self == .audio }
    var overlay: Bool { self == .regions || self == .captions || self == .titles }
}
extension Project {
    // Sequential clips (position == nil) form a magnetic storyline; a transition pulls the
    // incoming clip over the tail of the previous one. Positioned clips keep their time.
    var timeline: [TimelineEntry] {
        var cursor = 0.0
        var result: [TimelineEntry] = []; result.reserveCapacity(clips.count)
        for (i,clip) in clips.enumerated() {
            if let position = clip.position {
                result.append(TimelineEntry(clip:clip,index:i,start:position)); cursor += clip.timelineDuration; continue
            }
            var entry = TimelineEntry(clip:clip,index:i,start:cursor)
            if i > 0, clips[i-1].position == nil, let previous = result.last {
                entry.previous = previous.id
                if let t = clip.transition, t.duration > 0 {
                    let overlap = max(0,min(t.duration,previous.clip.timelineDuration/2,clip.timelineDuration/2))
                    entry.start -= overlap; entry.overlap = overlap
                }
            }
            result.append(entry); cursor = entry.end
        }
        // Positioned clips blend with the clip they overlap on the same lane.
        if clips.contains(where:{ $0.position != nil && $0.transition != nil }) {
            let byLane = Dictionary(grouping:result.indices.filter { result[$0].clip.position != nil },by:{ result[$0].lane })
            for (_,indices) in byLane {
                let sorted = indices.sorted { result[$0].start < result[$1].start }
                for (a,b) in zip(sorted,sorted.dropFirst()) where result[b].clip.transition != nil {
                    let overlap = result[a].end-result[b].start
                    if overlap > 0.000001 { result[b].overlap = min(overlap,result[b].clip.timelineDuration); result[b].previous = result[a].id }
                }
            }
        }
        return result
    }
    var exportDuration: Double { exportRange?.duration ?? editedDuration }
    func timelineTime(forSource time: Double, preferredClip: UUID? = nil, source: UUID? = nil) -> Double? {
        let id = source ?? media.first?.id
        let matches = timeline.filter { sourceID(of:$0.clip) == id && time >= $0.clip.start && time <= $0.clip.end && $0.clip.freeze == nil }
        guard let entry = matches.first(where: { $0.id == preferredClip }) ?? matches.first else { return nil }
        return entry.start + entry.clip.offset(forSource:time)
    }
    func entry(at time: Double, lane: Int? = nil) -> TimelineEntry? {
        timeline.filter { (lane == nil || $0.lane == lane) && time >= $0.start && time < $0.end }.max { ($0.lane,$0.start) < ($1.lane,$1.start) }
    }
    func clips(in range: TimelineRange) -> [Clip] {
        let entries = timeline
        return entries.enumerated().compactMap { n,entry in
            var start = max(range.start,entry.start); let end = min(range.end,entry.end)
            // A sequential transition region belongs to the outgoing clip once the cut starts inside it.
            if entry.clip.position == nil, entry.overlap > 0, start > entry.start+0.000001 {
                start = max(start,entry.start+entry.overlap)
                if end <= start+0.000001 { return nil }
            }
            if entry.clip.position == nil, entry.overlap > 0, start <= entry.start+0.000001, end <= entry.start+entry.overlap+0.000001, n > 0 { return nil }
            guard end-start > 0.000001 else { return nil }
            var c = entry.clip; c.id = UUID()
            if c.freeze != nil { c.freeze = end-start } else { c.start = entry.sourceTime(at:start); c.end = entry.sourceTime(at:end) }
            c.position = entry.clip.position == nil ? nil : start-range.start
            if start > entry.start+0.000001 { c.transition = nil; c.videoFadeIn = nil; c.audioFadeIn = nil }
            if end < entry.end-0.000001 { c.videoFadeOut = nil; c.audioFadeOut = nil }
            return c.duration > 0 || c.freeze != nil ? c : nil
        }
    }
    var projectForExport: Project {
        var p = self
        if !isImage, let range = exportRange {
            p.clips = clips(in:range)
            p.audioClips = audioClips.compactMap { a in
                let s = max(range.start,a.position), e = min(range.end,a.timelineEnd)
                guard e-s > 0.000001 else { return nil }
                var v = a; v.start += s-a.position; v.end = v.start+e-s; v.position = s-range.start
                if s > a.position { v.fadeIn = 0 }; if e < a.timelineEnd { v.fadeOut = 0 }; return v
            }
            p.markers = markers.filter { range.contains($0.time) }.map { var m = $0; m.time -= range.start; return m }
            p.titles = titles.compactMap { t in
                guard min(t.end,range.end) > max(t.start,range.start) else { return nil }
                var v = t; v.start = max(t.start,range.start)-range.start; v.end = min(t.end,range.end)-range.start; return v
            }
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
    // Cuts inside a transition would silently change the overlap, so they are refused.
    @discardableResult mutating func splitTimeline(at time: Double, clipID: UUID? = nil) -> UUID? {
        let threshold = max(0.001,0.5/fps)
        let entries = timeline
        guard let entry = entries.first(where:{(clipID == nil || $0.id == clipID) && time > $0.start+$0.overlap+threshold && time < $0.end-threshold}) else { return nil }
        if let next = entries.first(where:{ $0.previous == entry.id && $0.overlap > 0 }), time > next.start-threshold { return nil }
        let offset = time-entry.start
        var first = entry.clip, second = entry.clip; second.id = UUID()
        if let freeze = entry.clip.freeze { first.freeze = offset; second.freeze = freeze-offset }
        else { let source = entry.sourceTime(at:time); first.end = source; second.start = source }
        guard first.freeze != nil || (first.duration > 0 && second.duration > 0) else { return nil }
        second.position = entry.clip.position == nil ? nil : time
        second.transition = nil; second.videoFadeIn = nil; second.audioFadeIn = nil
        first.videoFadeOut = nil; first.audioFadeOut = nil
        clips[entry.index] = first; clips.insert(second,at:entry.index+1)
        return second.id
    }
    mutating func removeTimelineClips(_ ids: Set<UUID>) {
        clips.removeAll { ids.contains($0.id) }; exportRange = nil
    }
    @discardableResult mutating func insertTimelineClips(_ source: [Clip], at time: Double) -> [UUID] {
        let t = max(0,min(editedDuration,time))
        _ = splitTimeline(at:t)
        let index = timeline.firstIndex(where:{$0.start+$0.overlap >= t-0.000001}) ?? clips.count
        let copies = source.map { $0.duplicate() }
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
            let entry = TimelineEntry(clip:Clip(start:0,end:max(0.001,editedDuration)),index:0,start:0)
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
                return OverlayTimelineItem(sourceID:id,clip:entry,start:entry.start+entry.clip.offset(forSource:a),end:entry.start+entry.clip.offset(forSource:b),title:title,region:regionsOnly)
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
            var v = r; v.id = UUID(); v.start = entry.start+entry.clip.offset(forSource:a); v.end = entry.start+entry.clip.offset(forSource:b)
            v.rect = r.rect(at:a)
            v.keyframes = [RegionKeyframe(time:v.start,rect:r.rect(at:a))] + r.keyframes.filter { $0.time > a && $0.time < b }.map { RegionKeyframe(time:entry.start+entry.clip.offset(forSource:$0.time),rect:$0.rect) } + [RegionKeyframe(time:v.end,rect:r.rect(at:b))]
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
        for i in titles.indices where titles[i].start.isFinite && titles[i].end.isFinite {
            if titles[i].start < 0 { titles[i].start = 0; count += 1 }
            if titles[i].end <= titles[i].start { titles[i].end = titles[i].start+frame; count += 1 }
        }
        return count
    }
}

extension Project {
    // Topmost clip per time segment; in a transition the incoming clip is on top.
    var visibleTimeline: [TimelineEntry] {
        let entries = timeline
        guard (videoLaneCount ?? 1) > 1 || entries.contains(where:{ $0.overlap > 0 || $0.clip.position != nil }) else { return entries }
        let edges = Array(Set(entries.flatMap { [$0.start,$0.end] })).sorted()
        return zip(edges,edges.dropFirst()).compactMap { a,b in
            guard b > a, let top = entries.filter({$0.start <= a && $0.end >= b}).max(by:{ ($0.lane,$0.start) < ($1.lane,$1.start) }) else { return nil }
            var c = top.clip
            if c.freeze != nil { c.freeze = b-a } else { c.start = top.sourceTime(at:a); c.end = top.sourceTime(at:b) }
            c.position = a
            return TimelineEntry(clip:c,index:top.index,start:a)
        }
    }
    func analysisRanges(for source: UUID?) -> [TimelineRange] {
        let id = source ?? media.first?.id
        let ranges = clips.filter { sourceID(of:$0) == id }.map { TimelineRange(start:$0.start,end:$0.end) }.sorted { $0.start < $1.start }
        return TimelineRange.merged(ranges)
    }
    var analysisRanges: [TimelineRange] { analysisRanges(for:nil) }
    // Sources whose picture reaches the timeline, in first-use order.
    var usedVisualSources: [UUID] {
        var seen = Set<UUID>(); var result: [UUID] = []
        for clip in clips { if let id = sourceID(of:clip), seen.insert(id).inserted { result.append(id) } }
        return result
    }
    mutating func enableVideoLanes() {
        let entries = timeline
        for entry in entries { clips[entry.index].position = entry.start }
    }
    mutating func separateOverlappingOverlays() {
        func assign(_ items: [(start: Double, end: Double, lane: Int)]) -> [Int] {
            var ends: [Int:Double] = [:]; var lanes = items.map(\.lane)
            for index in items.indices.sorted(by:{ items[$0].start < items[$1].start }) {
                var lane = items[index].lane
                if (ends[lane] ?? -1) > items[index].start + 0.000001 {
                    lane = (0...items.count).first { (ends[$0] ?? -1) <= items[index].start + 0.000001 } ?? lane
                }
                lanes[index] = lane; ends[lane] = max(ends[lane] ?? -1,items[index].end)
            }
            return lanes
        }
        let captionLanes = assign(captions.map { ($0.start,$0.end,$0.lane ?? 0) })
        for i in captions.indices { captions[i].lane = captionLanes[i] }
        captionLaneCount = max(captionLaneCount ?? 1,(captionLanes.max() ?? 0)+1)
        let regionLanes = assign(regions.map { ($0.start,$0.end,$0.lane ?? 0) })
        for i in regions.indices { regions[i].lane = regionLanes[i] }
        regionLaneCount = max(regionLaneCount ?? 1,(regionLanes.max() ?? 0)+1)
        if !titles.isEmpty {
            let titleLanes = assign(titles.map { ($0.start,$0.end,$0.lane ?? 0) })
            for i in titles.indices { titles[i].lane = titleLanes[i] }
            titleLaneCount = max(titleLaneCount ?? 1,(titleLanes.max() ?? 0)+1)
        }
        if !audioClips.isEmpty {
            let audioLanes = assign(audioClips.map { ($0.position,$0.timelineEnd,$0.lane) })
            for i in audioClips.indices { audioClips[i].lane = audioLanes[i] }
            audioLaneCount = max(audioLaneCount ?? 1,(audioLanes.max() ?? 0)+1)
        }
    }
}
extension TimelineRange {
    static func merged(_ input: [TimelineRange]) -> [TimelineRange] {
        var result: [TimelineRange] = []
        for r in input.sorted(by:{ $0.start < $1.start }) where r.end > r.start {
            if let last = result.last, r.start <= last.end { result[result.count-1].end = max(last.end,r.end) }
            else { result.append(r) }
        }
        return result
    }
    // Parts of `ranges` not covered by `covered`.
    static func subtracting(_ ranges: [TimelineRange], _ covered: [TimelineRange]) -> [TimelineRange] {
        var result: [TimelineRange] = []
        let cover = merged(covered)
        for r in merged(ranges) {
            var cursor = r.start
            for c in cover where c.end > cursor && c.start < r.end {
                if c.start > cursor { result.append(TimelineRange(start:cursor,end:c.start)) }
                cursor = max(cursor,c.end)
            }
            if cursor < r.end { result.append(TimelineRange(start:cursor,end:r.end)) }
        }
        return result.filter { $0.duration > 0.0005 }
    }
}

struct TimelineRow: Identifiable {
    var kind: EditTrack
    var lane: Int
    var id: String { "\(kind.rawValue)-\(lane)" }
    var title: String {
        switch kind {
        case .audio: return "오디오 \(lane+1) · 연결"
        case .faces: return "얼굴 마스크 \(lane+1) · 연결"
        case .music: return "독립 오디오 \(lane+1)"
        default: return "\(kind.rawValue) \(lane+1)"
        }
    }
}

func mappedSourceTime(_ entries: [TimelineEntry], at time: Double) -> Double {
    var low = 0, high = entries.count
    while low < high { let mid = (low+high)/2; if entries[mid].end <= time { low = mid+1 } else { high = mid } }
    if low < entries.count, time >= entries[low].start { return entries[low].sourceTime(at:time) }
    if let last = entries.last, time >= last.end { return last.clip.end }
    return -1
}

extension Project {
    func gaps(in lane: Int) -> [TimelineRange] {
        var cursor = 0.0; var result: [TimelineRange] = []
        for entry in timeline.filter({$0.lane == lane}).sorted(by:{$0.start < $1.start}) {
            if entry.start-cursor > 0.000001 { result.append(TimelineRange(start:cursor,end:entry.start)) }
            cursor = max(cursor,entry.end)
        }
        return result
    }
    // First pair of positioned clips on one lane that overlap more than a transition allows.
    var positionedCollision: (UUID,UUID)? {
        let lanes = Dictionary(grouping:timeline.filter { $0.clip.position != nil },by:\.lane)
        for (_,list) in lanes {
            let sorted = list.sorted { $0.start < $1.start }
            for (a,b) in zip(sorted,sorted.dropFirst()) {
                let allowed = b.clip.transition.map { min($0.duration,a.clip.timelineDuration/2,b.clip.timelineDuration/2) } ?? 0
                if a.end-b.start > allowed+0.001 { return (a.id,b.id) }
            }
        }
        return nil
    }
    // Edit points for navigation and snapping.
    var editPoints: [Double] {
        Array(Set(timeline.flatMap { [$0.start,$0.end] } + audioClips.flatMap { [$0.position,$0.timelineEnd] } + markers.map(\.time) + [0,editedDuration])).sorted()
    }
}
