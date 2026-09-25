import SwiftUI

extension EditorStore {
    // MARK: Selection
    func selectClip(_ id: UUID, extending: Bool = false) {
        focusTimeline(); selectedTrack = .video; selectedLane = project.clips.first(where:{$0.id == id})?.lane ?? 0; selectedClip = id
        if extending { if selectedClips.contains(id) { selectedClips.remove(id) } else { selectedClips.insert(id) } }
        else { selectedClips = [id] }
        inspector = .clip
    }
    func selectOverlay(_ id: UUID, region: Bool) {
        focusTimeline(); wholeOverlayTrack = false; selectedTrack = region ? .regions : .captions
        if region { selectedRegion = id; selectedLane = project.regions.first(where:{$0.id == id})?.lane ?? 0; tab = .regions } else { selectedCaption = id; selectedLane = project.captions.first(where:{$0.id == id})?.lane ?? 0; tab = .captions }
    }
    func selectTitle(_ id: UUID) {
        focusTimeline(); wholeOverlayTrack = false; selectedTrack = .titles; selectedTitle = id
        selectedLane = project.titles.first(where:{$0.id == id})?.lane ?? 0; tab = .titles; inspector = .clip
    }
    func selectAudioClip(_ id: UUID) {
        focusTimeline(); wholeOverlayTrack = false; selectedTrack = .music; selectedAudioClip = id
        selectedLane = project.audioClips.first(where:{$0.id == id})?.lane ?? 0; inspector = .clip
    }
    func selectLane(_ kind: EditTrack, lane: Int) {
        focusTimeline(); wholeOverlayTrack = false; selectedTrack = kind; selectedLane = lane
        if kind.linkedToVideo { selectedClip = nil; selectedClips = [] }
        if kind == .regions { selectedRegion = nil; tab = .regions }
        if kind == .captions { selectedCaption = nil; tab = .captions }
        if kind == .titles { selectedTitle = nil; tab = .titles }
        if kind == .music { selectedAudioClip = nil }
        if (kind == .faces || kind == .audio), let top = project.timeline.first(where:{$0.lane == lane && playhead >= $0.start && playhead < $0.end}) {
            selectedClip = top.id; selectedClips = [top.id]; selectedLane = top.lane
        }
    }
    func synchronizeSelectedLane() {
        switch selectedTrack {
        case .regions: if let r = project.regions.first(where:{$0.id == selectedRegion}) { selectedLane = r.lane ?? 0 }
        case .captions: if let c = project.captions.first(where:{$0.id == selectedCaption}) { selectedLane = c.lane ?? 0 }
        case .titles: if let t = project.titles.first(where:{$0.id == selectedTitle}) { selectedLane = t.lane ?? 0 }
        case .music: if let a = project.audioClips.first(where:{$0.id == selectedAudioClip}) { selectedLane = a.lane }
        default: break
        }
    }
    func selectAllClips() { guard canEditTimeline else { return }
        switch selectedTrack {
        case .captions: wholeOverlayTrack = true; selectedCaption = project.captions.first(where:{($0.lane ?? 0) == selectedLane})?.id
        case .regions: wholeOverlayTrack = true; selectedRegion = project.regions.first(where:{($0.lane ?? 0) == selectedLane})?.id
        case .titles: wholeOverlayTrack = true; selectedTitle = project.titles.first(where:{($0.lane ?? 0) == selectedLane})?.id
        case .music: wholeOverlayTrack = true; selectedAudioClip = project.audioClips.first(where:{$0.lane == selectedLane})?.id
        default: selectedTrack = .video; selectedClips = Set(project.clips.filter { ($0.lane ?? 0) == selectedLane }.map(\.id)); selectedClip = project.clips.first?.id; focusTimeline()
        }
    }

    // MARK: Lanes
    func laneCount(_ kind: EditTrack) -> Int {
        switch kind {
        case .video: return max(project.videoLaneCount ?? 1,(project.clips.map {$0.lane ?? 0}.max() ?? 0)+1)
        case .regions: return max(project.regionLaneCount ?? 1,(project.regions.map {$0.lane ?? 0}.max() ?? 0)+1)
        case .captions: return max(project.captionLaneCount ?? 1,(project.captions.map {$0.lane ?? 0}.max() ?? 0)+1)
        case .titles: return max(project.titleLaneCount ?? 1,(project.titles.map {$0.lane ?? 0}.max() ?? 0)+1)
        case .music: return max(project.audioLaneCount ?? 1,(project.audioClips.map(\.lane).max() ?? 0)+1)
        case .faces, .audio: return laneCount(.video)
        }
    }
    var timelineRows: [TimelineRow] {
        (0..<laneCount(.titles)).reversed().map { TimelineRow(kind:.titles,lane:$0) } +
        (0..<laneCount(.video)).reversed().flatMap { lane in [.video,.audio,.faces].map { TimelineRow(kind:$0,lane:lane) } } +
        [EditTrack.regions,.captions,.music].flatMap { kind in (0..<laneCount(kind)).reversed().map { TimelineRow(kind:kind,lane:$0) } }
    }
    func addLane(_ kind: EditTrack) {
        var p = project; let count = laneCount(kind)
        guard count < 64 else { status = "종류별 트랙은 최대 64개입니다"; return }
        switch kind {
        case .video: p.enableVideoLanes(); p.videoLaneCount = count+1
        case .regions: p.regionLaneCount = count+1
        case .captions: p.captionLaneCount = count+1
        case .titles: p.titleLaneCount = count+1
        case .music: p.audioLaneCount = count+1
        case .faces, .audio: return
        }
        project = p; selectLane(kind,lane:count)
    }

    // MARK: Cuts
    func split() {
        guard canEditTimeline else { return }
        if selectedTrack.overlay || selectedTrack == .music { splitOverlay(); return }
        var p = project
        guard let entry = p.timeline.first(where:{ $0.lane == selectedLane && playhead > $0.start && playhead < $0.end }), let id = p.splitTimeline(at:playhead,clipID:entry.id) else { status = "분할할 컷 안쪽으로 재생 헤드를 이동하세요 · 전환 효과 구간은 나눌 수 없습니다"; return }
        commitTimeline(p); selectClip(id); status = "현재 위치에서 컷 분할"
    }
    // Blade tool: cut whatever sits under the pointer on that row.
    func blade(at time: Double, row: TimelineRow) {
        guard canEditTimeline else { return }
        seek(time)
        selectedTrack = row.kind == .audio || row.kind == .faces ? .video : row.kind; selectedLane = row.lane
        switch row.kind {
        case .regions: if let r = project.regions.first(where:{ ($0.lane ?? 0) == row.lane && time > $0.start && time < $0.end }) { selectedRegion = r.id; splitOverlay() }
        case .captions: if let c = project.captions.first(where:{ ($0.lane ?? 0) == row.lane && time > $0.start && time < $0.end }) { selectedCaption = c.id; splitOverlay() }
        case .titles: if let t = project.titles.first(where:{ ($0.lane ?? 0) == row.lane && time > $0.start && time < $0.end }) { selectedTitle = t.id; splitOverlay() }
        case .music: if let a = project.audioClips.first(where:{ $0.lane == row.lane && time > $0.position && time < $0.timelineEnd }) { selectedAudioClip = a.id; splitOverlay() }
        default: split()
        }
    }
    func copyClips() {
        guard canDeleteClips else { return }
        clipboardClips = project.clips.filter { selectedClips.contains($0.id) }; status = "컷 \(clipboardClips.count)개 복사 · 재생 위치에 붙여넣을 수 있습니다"
    }
    func cutClips() { guard canDeleteClips else { return }; copyClips(); deleteClip() }
    func pasteClips() {
        guard canEditTimeline, !clipboardClips.isEmpty else { return }; var p = project
        let ids: [UUID]
        if (p.videoLaneCount ?? 1) > 1 {
            var cursor = playhead
            let copies = clipboardClips.map { c -> Clip in var v = c.duplicate(); v.lane = selectedLane; v.position = cursor; cursor += c.timelineDuration; return v }
            guard !p.timeline.contains(where:{$0.lane == selectedLane && $0.start < cursor && $0.end > playhead}) else { status = "붙여넣을 위치에 컷이 있습니다. 빈 영상 트랙을 선택하세요."; return }
            p.clips += copies; p.exportRange = nil; ids = copies.map(\.id)
        } else { ids = p.insertTimelineClips(clipboardClips,at:playhead) }
        commitTimeline(p)
        selectedClips = Set(ids); selectedClip = ids.first; focusTimeline(); status = "재생 위치에 컷 붙여넣기 · 빈 공간 없이 연결"
    }
    func deleteClip() {
        guard canDeleteClips else { return }
        let destination = project.timeline.first(where:{selectedClips.contains($0.id)})?.start ?? playhead
        var p = project; p.removeTimelineClips(selectedClips); commitTimeline(p,seekTo:destination)
        selectedClips = []; selectedClip = nil; status = "선택 컷 삭제 · 뒤의 컷을 앞으로 붙였습니다"
    }
    func moveClip(_ id: UUID, before target: UUID?) {
        if (project.videoLaneCount ?? 1) > 1 {
            let entry = project.timeline.first(where:{$0.id == target})
            moveItem(id,to:.video,lane:entry?.lane ?? selectedLane,at:entry?.start ?? project.editedDuration); return
        }
        guard canEditTimeline else { return }; var p = project; p.moveTimelineClip(id,before:target)
        let t = p.timeline.first(where:{$0.id == id})?.start ?? 0
        commitTimeline(p,seekTo:t); selectClip(id); status = "컷 순서 변경"
    }
    func moveSelected(_ direction: Int) {
        let frame = Double(direction)/max(1,project.fps)
        switch selectedTrack {
        case .captions: if let c = project.captions.first(where:{$0.id == selectedCaption}) { editOverlayTime(id:c.id,kind:.captions,original:TimelineRange(start:c.start,end:c.end),delta:frame,edge:0) }; return
        case .regions: if let r = project.regions.first(where:{$0.id == selectedRegion}) { editOverlayTime(id:r.id,kind:.regions,original:TimelineRange(start:r.start,end:r.end),delta:frame,edge:0) }; return
        case .titles: if let t = project.titles.first(where:{$0.id == selectedTitle}) { editOverlayTime(id:t.id,kind:.titles,original:TimelineRange(start:t.start,end:t.end),delta:frame,edge:0) }; return
        case .music: if let a = project.audioClips.first(where:{$0.id == selectedAudioClip}) { editOverlayTime(id:a.id,kind:.music,original:TimelineRange(start:a.position,end:a.timelineEnd),delta:frame,edge:0) }; return
        default: break
        }
        if (project.videoLaneCount ?? 1) > 1, let id = selectedClip, let entry = project.timeline.first(where:{$0.id == id}) { moveItem(id,to:.video,lane:entry.lane,at:entry.start+frame); return }
        guard let id = selectedClip, let index = project.clips.firstIndex(where:{$0.id == id}) else { return }
        if direction < 0, index > 0 { moveClip(id,before:project.clips[index-1].id) }
        if direction > 0, index < project.clips.count-1 { moveClip(id,before:index+2 < project.clips.count ? project.clips[index+2].id : nil) }
    }
    func trimClip(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard canEditTimeline, let index = project.clips.firstIndex(where:{$0.id == id}) else { return }
        var p = project; let old = project.clips[index]
        let sourceDuration = project.source(old.source).map { $0.isImage ? max($0.duration,3600) : $0.duration } ?? old.end
        let minimum = min(1/max(1,project.fps),old.duration)
        if old.freeze != nil {
            // A freeze frame's length is its time on the timeline.
            if let end, end.isFinite { p.clips[index].freeze = max(minimum,(old.freeze ?? 1)+(end-old.end)) }
            p.exportRange = nil; commitTimeline(p); return
        }
        if let start, start.isFinite { p.clips[index].start = max(0,min(p.clips[index].end-minimum,start)) }
        if let end, end.isFinite { p.clips[index].end = min(sourceDuration,max(p.clips[index].start+minimum,end)) }
        if let position = old.position {
            let lane = old.lane ?? 0
            let prev = project.timeline.filter { $0.id != id && $0.lane == lane && $0.end <= position+0.000001 }.map(\.end).max() ?? 0
            let next = project.timeline.filter { $0.id != id && $0.lane == lane && $0.start >= position+old.timelineDuration-0.000001 }.map(\.start).min() ?? .infinity
            p.clips[index].start = max(p.clips[index].start,old.start-(position-prev)*old.rate)
            p.clips[index].position = position+(p.clips[index].start-old.start)/max(Clip.minSpeed,old.rate)
            p.clips[index].end = min(p.clips[index].end,old.start+(next-position)*old.rate)
        }
        p.exportRange = nil; commitTimeline(p)
    }
    func markIn() { setExportRange(start:playhead,end:project.exportRange?.end ?? project.editedDuration) }
    func markOut() { setExportRange(start:project.exportRange?.start ?? 0,end:playhead) }
    func setExportRange(start: Double, end: Double) {
        guard canEditTimeline, project.editedDuration > 0, start.isFinite, end.isFinite else { return }
        let a = max(0,min(start,project.editedDuration)); let b = max(0,min(end,project.editedDuration))
        guard b-a >= min(1/project.fps,project.editedDuration) else { status = "종료 지점은 시작 지점보다 최소 한 프레임 뒤여야 합니다"; return }
        project.exportRange = TimelineRange(start:a,end:b)
    }
    func exportSelectedClips() {
        switch selectedTrack {
        case .captions: if let c = project.captions.first(where:{$0.id == selectedCaption}) { setExportRange(start:c.start,end:c.end) }; return
        case .regions: if let r = project.regions.first(where:{$0.id == selectedRegion}) { setExportRange(start:r.start,end:r.end) }; return
        case .titles: if let t = project.titles.first(where:{$0.id == selectedTitle}) { setExportRange(start:t.start,end:t.end) }; return
        case .music: if let a = project.audioClips.first(where:{$0.id == selectedAudioClip}) { setExportRange(start:a.position,end:a.timelineEnd) }; return
        default: break
        }
        let entries = project.timeline.filter { selectedClips.contains($0.id) }
        guard let first = entries.map(\.start).min(), let last = entries.map(\.end).max() else { return }
        setExportRange(start:first,end:last)
    }
    func deleteMarkedRange() {
        guard canEditTimeline, let range = project.exportRange else { return }
        if selectedTrack.overlay || selectedTrack == .music {
            var p = project
            func cut<T>(_ items: [T], lane: (T) -> Int, span: (T) -> TimelineRange, set: (inout T, Double, Double) -> Void, fresh: (inout T) -> Void) -> [T] {
                items.flatMap { item -> [T] in
                    let s = span(item)
                    guard lane(item) == selectedLane, s.end > range.start, s.start < range.end else { return [item] }
                    var parts: [T] = []
                    if s.start < range.start { var left = item; set(&left,s.start,range.start); parts.append(left) }
                    if s.end > range.end { var right = item; fresh(&right); set(&right,range.end,s.end); parts.append(right) }
                    return parts
                }
            }
            switch selectedTrack {
            case .captions: p.captions = cut(p.captions,lane:{ $0.lane ?? 0 },span:{ TimelineRange(start:$0.start,end:$0.end) },set:{ $0.start = $1; $0.end = $2 },fresh:{ $0.id = UUID() })
            case .regions: p.regions = cut(p.regions,lane:{ $0.lane ?? 0 },span:{ TimelineRange(start:$0.start,end:$0.end) },set:{ $0.start = $1; $0.end = $2 },fresh:{ $0.id = UUID() })
            case .titles: p.titles = cut(p.titles,lane:{ $0.lane ?? 0 },span:{ TimelineRange(start:$0.start,end:$0.end) },set:{ $0.start = $1; $0.end = $2 },fresh:{ $0.id = UUID() })
            default: p.audioClips = cut(p.audioClips,lane:{ $0.lane },span:{ TimelineRange(start:$0.position,end:$0.timelineEnd) },set:{ a,s,e in a.start += s-a.position; a.end = a.start+e-s; a.position = s },fresh:{ $0.id = UUID() })
            }
            project = p; status = "선택 트랙의 지정 구간만 삭제했습니다"; return
        }
        if (project.videoLaneCount ?? 1) > 1 {
            var p = project
            p.clips = p.timeline.flatMap { entry -> [Clip] in
                guard entry.lane == selectedLane, entry.end > range.start, entry.start < range.end else { return [entry.clip] }
                var parts: [Clip] = []
                if entry.start < range.start { var left = entry.clip; if left.freeze != nil { left.freeze = range.start-entry.start } else { left.end = entry.sourceTime(at:range.start) }; left.videoFadeOut = nil; left.audioFadeOut = nil; parts.append(left) }
                if entry.end > range.end { var right = entry.clip; right.id = UUID(); if right.freeze != nil { right.freeze = entry.end-range.end } else { right.start = entry.sourceTime(at:range.end) }; right.position = range.end; right.transition = nil; right.videoFadeIn = nil; right.audioFadeIn = nil; parts.append(right) }; return parts
            }
            p.exportRange = nil; commitTimeline(p); return
        }
        var p = project; p.deleteTimelineRange(range); commitTimeline(p,seekTo:range.start)
        selectedClips = []; selectedClip = nil; status = "지정 구간 삭제 · 뒤의 컷을 앞으로 붙였습니다"
    }

    // MARK: Overlay timing (regions, captions, titles, independent audio)
    func editOverlayTime(id: UUID, region: Bool, original: TimelineRange, delta: Double, edge: Int) {
        editOverlayTime(id:id,kind:region ? .regions : .captions,original:original,delta:delta,edge:edge)
    }
    func editOverlayTime(id: UUID, kind: EditTrack, original: TimelineRange, delta: Double, edge: Int) {
        guard delta.isFinite else { return }
        let minimum = min(1/max(1,project.fps),original.duration)
        var a = original.start, b = original.end
        let limit = kind == .music ? .infinity : max(project.editedDuration,original.end)
        if edge == 0 {
            let shift = max(-a,min(limit-b,delta)); a += shift; b += shift
        } else if edge < 0 { a = max(0,min(b-minimum,a+delta)) }
        else { b = min(limit,max(a+minimum,b+delta)) }
        var p = project
        switch kind {
        case .regions:
            guard let i = p.regions.firstIndex(where:{$0.id == id}) else { return }
            let shift = a-p.regions[i].start
            if edge == 0 { p.regions[i].keyframes = p.regions[i].keyframes.map { key in var k = key; k.time = max(0,k.time+shift); return k } }
            p.regions[i].start = a; p.regions[i].end = b
        case .captions:
            guard let i = p.captions.firstIndex(where:{$0.id == id}) else { return }
            p.captions[i].start = a; p.captions[i].end = b
        case .titles:
            guard let i = p.titles.firstIndex(where:{$0.id == id}) else { return }
            p.titles[i].start = a; p.titles[i].end = b
        case .music:
            guard let i = p.audioClips.firstIndex(where:{$0.id == id}), let source = p.media.first(where:{ $0.id == p.audioClips[i].source }) else { return }
            var clip = p.audioClips[i]
            if edge == 0 { clip.position = a }
            else if edge < 0 {
                let newStart = max(0,min(clip.end-minimum,clip.start+(a-clip.position)))
                clip.position += newStart-clip.start; clip.start = newStart
            } else { clip.end = min(source.duration,max(clip.start+minimum,clip.start+(b-clip.position))) }
            p.audioClips[i] = clip
        default: return
        }
        if timelineGestureStart == nil { p.separateOverlappingOverlays() }; project = p; synchronizeSelectedLane()
    }
    func editRegionRect(_ id: UUID, rect: NormalRect) {
        guard let i = project.regions.firstIndex(where:{$0.id == id}) else { return }
        var p = project
        if p.regions[i].keyframes.isEmpty { p.regions[i].rect = rect }
        else {
            let time = overlayTime
            p.regions[i].keyframes.removeAll { abs($0.time-time) < 0.02 }
            p.regions[i].keyframes.append(RegionKeyframe(time:time,rect:rect))
        }
        project = p
    }
    func addRegion(_ rect: NormalRect) {
        guard rect.width > 0.008, rect.height > 0.008 else { return }
        let r = ManualRegion(name:"영역 \(project.regions.count+1)",start:0,end:project.isImage ? project.duration : project.editedDuration,rect:rect)
        project.regions.append(r); project.separateOverlappingOverlays(); selectOverlay(r.id,region:true); drawMode = false; tab = .regions
    }
    func addKeyframe() {
        guard let i = project.regions.firstIndex(where:{$0.id == selectedRegion}) else { return }
        let source = overlayTime; let rect = project.regions[i].rect(at:source); var p = project; p.regions[i].keyframes.removeAll { abs($0.time-source) < 0.02 }; p.regions[i].keyframes.append(RegionKeyframe(time:source,rect:rect)); project = p
    }
    func splitOverlay() {
        if wholeOverlayTrack {
            wholeOverlayTrack = false
            let ids: [UUID]
            switch selectedTrack {
            case .captions: ids = project.captions.filter { ($0.lane ?? 0) == selectedLane }.map(\.id)
            case .regions: ids = project.regions.filter { ($0.lane ?? 0) == selectedLane }.map(\.id)
            case .titles: ids = project.titles.filter { ($0.lane ?? 0) == selectedLane }.map(\.id)
            default: ids = project.audioClips.filter { $0.lane == selectedLane }.map(\.id)
            }
            beginTimelineGesture()
            for id in ids {
                switch selectedTrack { case .captions: selectedCaption = id; case .regions: selectedRegion = id; case .titles: selectedTitle = id; default: selectedAudioClip = id }
                splitOverlay()
            }
            endTimelineGesture(); return
        }
        let t = playhead
        var p = project
        if selectedTrack == .captions, let i = p.captions.firstIndex(where:{$0.id == selectedCaption}), t > p.captions[i].start, t < p.captions[i].end {
            var right = p.captions[i]; right.id = UUID(); right.start = t; p.captions[i].end = t; p.captions.insert(right,at:i+1); selectedCaption = right.id
        } else if selectedTrack == .regions, let i = p.regions.firstIndex(where:{$0.id == selectedRegion}), t > p.regions[i].start, t < p.regions[i].end {
            var right = p.regions[i]; right.id = UUID(); right.start = t; p.regions[i].end = t; p.regions.insert(right,at:i+1); selectedRegion = right.id
        } else if selectedTrack == .titles, let i = p.titles.firstIndex(where:{$0.id == selectedTitle}), t > p.titles[i].start, t < p.titles[i].end {
            var right = p.titles[i]; right.id = UUID(); right.start = t; p.titles[i].end = t; p.titles.insert(right,at:i+1); selectedTitle = right.id
        } else if selectedTrack == .music, let i = p.audioClips.firstIndex(where:{$0.id == selectedAudioClip}), t > p.audioClips[i].position, t < p.audioClips[i].timelineEnd {
            var right = p.audioClips[i]; right.id = UUID()
            let cut = p.audioClips[i].start+t-p.audioClips[i].position
            right.start = cut; right.position = t; right.fadeIn = 0; p.audioClips[i].end = cut; p.audioClips[i].fadeOut = 0
            p.audioClips.insert(right,at:i+1); selectedAudioClip = right.id
        } else { status = "선택한 블록 안쪽에 재생 헤드를 놓으세요"; return }
        project = p; status = "선택한 트랙만 분할했습니다"
    }
    func editSelection(_ action: String) {
        guard canEditTimeline else { return }
        if selectedTrack.linkedToVideo {
            switch action { case "copy":copyClips(); case "cut":cutClips(); case "paste":pasteClips(); case "delete":deleteClip(); default:break }; return
        }
        var p = project
        let whole = wholeOverlayTrack, lane = selectedLane
        if action == "copy" || action == "cut" {
            switch selectedTrack {
            case .captions: clipboardCaptions = p.captions.filter { (whole && ($0.lane ?? 0) == lane) || $0.id == selectedCaption }
            case .regions: clipboardRegions = p.regions.filter { (whole && ($0.lane ?? 0) == lane) || $0.id == selectedRegion }
            case .titles: clipboardTitles = p.titles.filter { (whole && ($0.lane ?? 0) == lane) || $0.id == selectedTitle }
            default: clipboardAudio = p.audioClips.filter { (whole && $0.lane == lane) || $0.id == selectedAudioClip }
            }
            objectWillChange.send()
        }
        if action == "delete" || action == "cut" {
            switch selectedTrack {
            case .captions: p.captions.removeAll { (whole && ($0.lane ?? 0) == lane) || $0.id == selectedCaption }; selectedCaption = nil
            case .regions: p.regions.removeAll { (whole && ($0.lane ?? 0) == lane) || $0.id == selectedRegion }; selectedRegion = nil
            case .titles: p.titles.removeAll { (whole && ($0.lane ?? 0) == lane) || $0.id == selectedTitle }; selectedTitle = nil
            default: p.audioClips.removeAll { (whole && $0.lane == lane) || $0.id == selectedAudioClip }; selectedAudioClip = nil
            }
        }
        if action == "paste" {
            switch selectedTrack {
            case .captions: if let start = clipboardCaptions.map(\.start).min() {
                for original in clipboardCaptions { var c = original; c.id = UUID(); c.lane = lane; c.start += playhead-start; c.end += playhead-start; p.captions.append(c); selectedCaption = c.id } }
            case .regions: if let start = clipboardRegions.map(\.start).min() {
                for original in clipboardRegions { var r = original; r.id = UUID(); r.lane = lane; let shift = playhead-start; r.start += shift; r.end += shift; r.keyframes = r.keyframes.map { k in var v = k; v.time = max(0,v.time+shift); return v }; p.regions.append(r); selectedRegion = r.id } }
            case .titles: if let start = clipboardTitles.map(\.start).min() {
                for original in clipboardTitles { var t = original; t.id = UUID(); t.lane = lane; t.start += playhead-start; t.end += playhead-start; p.titles.append(t); selectedTitle = t.id } }
            default: if let start = clipboardAudio.map(\.position).min() {
                for original in clipboardAudio { var a = original; a.id = UUID(); a.lane = lane; a.position += playhead-start; p.audioClips.append(a); selectedAudioClip = a.id } }
            }
            wholeOverlayTrack = false
        }
        p.separateOverlappingOverlays(); project = p; synchronizeSelectedLane()
    }
    func moveItem(_ id: UUID, to kind: EditTrack, lane: Int, at time: Double? = nil) {
        var p = project
        if kind.linkedToVideo, let i = p.clips.firstIndex(where:{$0.id == id}) {
            p.enableVideoLanes(); p.videoLaneCount = max(2,laneCount(.video),lane+1)
            let at = max(0,time ?? p.clips[i].position ?? 0), end = at+p.clips[i].timelineDuration
            let allowance = p.clips[i].transition?.duration ?? 0
            guard !p.timeline.contains(where:{$0.id != id && $0.lane == lane && $0.start < end-0.000001 && $0.end > at+allowance+0.000001}) else { status = "같은 영상 트랙의 컷과 겹칩니다. 빈 트랙으로 이동하세요."; return }
            p.clips[i].lane = lane; p.clips[i].position = at; p.exportRange = nil
            selectedClip = id; selectedClips = [id]
        } else if kind == .regions, let i = p.regions.firstIndex(where:{$0.id == id}) {
            p.regions[i].lane = lane
            if let time { let d = max(0,time)-p.regions[i].start; p.regions[i].start += d; p.regions[i].end += d; p.regions[i].keyframes = p.regions[i].keyframes.map { k in var v = k; v.time = max(0,k.time+d); return v } }
            selectedRegion = id; tab = .regions
        } else if kind == .captions, let i = p.captions.firstIndex(where:{$0.id == id}) {
            p.captions[i].lane = lane
            if let time { let d = max(0,time)-p.captions[i].start; p.captions[i].start += d; p.captions[i].end += d }
            selectedCaption = id; tab = .captions
        } else if kind == .titles, let i = p.titles.firstIndex(where:{$0.id == id}) {
            p.titles[i].lane = lane
            if let time { let d = max(0,time)-p.titles[i].start; p.titles[i].start += d; p.titles[i].end += d }
            selectedTitle = id
        } else if kind == .music, let i = p.audioClips.firstIndex(where:{$0.id == id}) {
            p.audioClips[i].lane = lane
            if let time { p.audioClips[i].position = max(0,time) }
            selectedAudioClip = id
        } else { return }
        p.separateOverlappingOverlays(); project = p; selectedTrack = kind; selectedLane = lane; synchronizeSelectedLane(); focusTimeline()
    }
    func closeGap(_ range: TimelineRange,lane: Int) {
        guard canEditTimeline, project.gaps(in:lane).contains(range) else { return }
        var p = project; p.enableVideoLanes()
        for i in p.clips.indices where (p.clips[i].lane ?? 0) == lane && (p.clips[i].position ?? 0) >= range.end-0.000001 { p.clips[i].position = max(0,(p.clips[i].position ?? 0)-range.duration) }
        p.exportRange = nil; commitTimeline(p,seekTo:range.start)
        status = "빈 구간 삭제 · 영상·오디오·얼굴 마스크 세트를 붙였습니다"
    }

    // MARK: Clip properties (speed, freeze, transitions, look, sound)
    var selectedClipIDs: Set<UUID> { selectedClips.isEmpty ? Set([selectedClip].compactMap { $0 }) : selectedClips }
    // Applies a change to the selected clips, refusing it if positioned clips would collide.
    @discardableResult func updateClips(coalesce: String? = nil, _ change: (inout Clip) -> Void) -> Bool {
        let ids = selectedClipIDs; guard canEditTimeline, !ids.isEmpty else { return false }
        var p = project
        for i in p.clips.indices where ids.contains(p.clips[i].id) { change(&p.clips[i]) }
        let timingChanged = zip(p.clips,project.clips).contains { $0.timelineDuration != $1.timelineDuration || $0.transition != $1.transition }
        if timingChanged {
            if p.positionedCollision != nil { status = "같은 트랙의 다음 컷과 겹쳐 적용하지 않았습니다. 뒤의 컷을 옮긴 뒤 다시 시도하세요."; return false }
            p.exportRange = nil
        }
        pendingCoalesce = coalesce; project = p; return true
    }
    func setSpeed(_ speed: Double) {
        let value = min(Clip.maxSpeed,max(Clip.minSpeed,speed))
        if updateClips(coalesce:"speed",{ c in if c.freeze == nil { c.speed = abs(value-1) < 0.0001 ? nil : value } }) { status = "속도 \(Int((value*100).rounded()))% 적용 · 음높이는 유지됩니다" }
    }
    func addFreezeFrame(length: Double = 2) {
        guard canEditTimeline, let entry = project.entry(at:playhead,lane:selectedLane) ?? project.entry(at:playhead), entry.clip.freeze == nil else { status = "정지 화면을 만들 영상 컷 위에 재생 헤드를 놓으세요"; return }
        guard let source = project.source(entry.clip.source), !source.isImage else { status = "사진 컷은 이미 정지 화면입니다"; return }
        var p = project
        let frame = 1/max(1,source.fps)
        let sourceTime = min(entry.clip.end-frame,entry.sourceTime(at:playhead))
        var freeze = entry.clip.duplicate(); freeze.start = max(0,sourceTime); freeze.end = freeze.start+frame; freeze.freeze = length; freeze.speed = nil
        freeze.videoFadeIn = nil; freeze.videoFadeOut = nil; freeze.audioFadeIn = nil; freeze.audioFadeOut = nil
        if entry.clip.position == nil {
            let secondID = playhead > entry.start+entry.overlap+0.01 ? p.splitTimeline(at:playhead,clipID:entry.id) : nil
            let index = secondID.flatMap { id in p.clips.firstIndex(where:{ $0.id == id }) } ?? entry.index
            p.clips.insert(freeze,at:index)
        } else {
            let lane = entry.lane
            let secondID = p.splitTimeline(at:playhead,clipID:entry.id)
            for i in p.clips.indices where (p.clips[i].lane ?? 0) == lane && (p.clips[i].position ?? 0) >= playhead-0.000001 { p.clips[i].position = (p.clips[i].position ?? 0)+length }
            freeze.lane = lane; freeze.position = playhead
            let index = secondID.flatMap { id in p.clips.firstIndex(where:{ $0.id == id }) } ?? p.clips.count
            p.clips.insert(freeze,at:index)
        }
        p.exportRange = nil; commitTimeline(p); selectClip(freeze.id); status = "정지 화면 \(timecode(length)) 추가"
    }
    func setTransition(_ kind: TransitionKind?, duration: Double = 0.5) {
        let ids = selectedClipIDs; guard canEditTimeline, !ids.isEmpty else { return }
        var p = project
        let entries = p.timeline
        for id in ids {
            guard let entry = entries.first(where:{ $0.id == id }), let i = p.clips.firstIndex(where:{ $0.id == id }) else { continue }
            let previous = entries.filter { $0.lane == entry.lane && $0.id != id && abs($0.end-entry.start-entry.overlap) < 0.05 && $0.start < entry.start }.max { $0.end < $1.end }
            if entry.clip.position != nil {
                // Positioned clips slide left under the previous clip to make room for the blend.
                let old = entry.overlap
                let new = kind == nil || previous == nil ? 0 : min(duration,previous!.clip.timelineDuration/2,entry.clip.timelineDuration/2)
                let shift = new-old
                if abs(shift) > 0.000001 {
                    for j in p.clips.indices where (p.clips[j].lane ?? 0) == entry.lane && (p.clips[j].position ?? -1) >= entry.start-0.000001 { p.clips[j].position = max(0,(p.clips[j].position ?? 0)-shift) }
                }
            }
            p.clips[i].transition = kind.map { Transition(kind:$0,duration:min(5,max(0.1,duration))) }
        }
        p.exportRange = nil; pendingCoalesce = "transition"; project = p
        status = kind.map { "\($0.rawValue) 전환 적용 · \(String(format:"%.1f",duration))초" } ?? "전환 효과 제거"
    }
    func detachAudio() {
        guard canEditTimeline, let id = selectedClip, let entry = project.timeline.first(where:{ $0.id == id }) else { return }
        guard let source = project.source(entry.clip.source), source.hasAudio, entry.clip.freeze == nil, entry.clip.audioMuted != true else { status = "분리할 오디오가 없습니다"; return }
        guard entry.clip.rate == 1 else { status = "속도를 바꾼 컷은 오디오를 분리할 수 없습니다. 속도를 100%로 바꾼 뒤 시도하세요."; return }
        var p = project
        let audio = AudioClip(source:source.id,start:entry.clip.start,end:entry.clip.end,position:entry.start,lane:0,volume:entry.clip.volume ?? 1,fadeIn:entry.clip.audioFadeIn ?? 0,fadeOut:entry.clip.audioFadeOut ?? 0)
        p.audioClips.append(audio)
        if let i = p.clips.firstIndex(where:{ $0.id == id }) { p.clips[i].audioMuted = true }
        p.separateOverlappingOverlays(); project = p; selectAudioClip(audio.id); status = "오디오를 독립 트랙으로 분리했습니다 · 영상 컷의 소리는 꺼졌습니다"
    }

    // MARK: Titles and markers
    func addTitle(text: String = "제목을 입력하세요") {
        guard loaded, !project.isImage else { return }
        let start = min(playhead,max(0,project.editedDuration-0.5))
        let title = TitleItem(text:text,start:start,end:min(max(project.editedDuration,start+0.5),start+3),lane:selectedTrack == .titles ? selectedLane : nil)
        project.titles.append(title); project.separateOverlappingOverlays(); selectTitle(title.id); status = "타이틀 추가 · 오른쪽 검사기에서 글자와 위치를 바꾸세요"
    }
    func addMarker() {
        guard canEditTimeline else { return }
        if let existing = project.markers.first(where:{ abs($0.time-playhead) < 0.5/max(1,project.fps) }) { selectedMarker = existing.id; return }
        let marker = Marker(time:playhead,name:"마커 \(project.markers.count+1)")
        project.markers.append(marker); project.markers.sort { $0.time < $1.time }; selectedMarker = marker.id; status = "마커 추가 · \(timecode(playhead))"
    }
    func jumpMarker(_ direction: Int) {
        let times = project.markers.map(\.time).sorted()
        if direction > 0, let next = times.first(where:{ $0 > playhead+0.001 }) { seek(next) }
        if direction < 0, let prev = times.last(where:{ $0 < playhead-0.001 }) { seek(prev) }
    }
    // Snaps to nearby edit points, markers, overlay edges and the playhead (8 px).
    func snapTime(_ time: Double, pixelsPerSecond: Double, excluding: UUID? = nil) -> Double {
        guard snapping, time.isFinite, pixelsPerSecond > 0 else { return time }
        var candidates = [playhead,0,project.editedDuration] + project.markers.map(\.time)
        for e in project.timeline where e.id != excluding { candidates += [e.start,e.end] }
        for c in project.captions where c.id != excluding { candidates += [c.start,c.end] }
        for r in project.regions where r.id != excluding { candidates += [r.start,r.end] }
        for t in project.titles where t.id != excluding { candidates += [t.start,t.end] }
        for a in project.audioClips where a.id != excluding { candidates += [a.position,a.timelineEnd] }
        let threshold = 8/pixelsPerSecond
        guard let best = candidates.min(by:{ abs($0-time) < abs($1-time) }), abs(best-time) <= threshold else { return time }
        return best
    }
}
