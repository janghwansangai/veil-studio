import SwiftUI
import UniformTypeIdentifiers

extension EditorStore {
    static let mediaTypes: [UTType] = [.movie,.video,.image,.audio,.folder]
    // MARK: Opening and importing
    func openMedia() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = Self.mediaTypes; panel.allowsOtherFileTypes = true; panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        panel.message = "새 프로젝트로 열 영상·사진·오디오를 선택하세요. 여러 개를 고르면 순서대로 타임라인에 이어 붙입니다. 원본은 변경하지 않습니다."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard !busy, confirmLeaving() else { return }
        addMedia(panel.urls,newProject:true)
    }
    func load(_ url: URL) { guard !busy, confirmLeaving() else { return }; addMedia([url],newProject:true) }
    func importMedia() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = Self.mediaTypes; panel.allowsOtherFileTypes = true; panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        panel.message = "프로젝트에 추가할 영상·사진·오디오를 선택하세요. 폴더를 고르면 안의 미디어를 모두 가져옵니다."
        if panel.runModal() == .OK { addMedia(panel.urls,newProject:!loaded) }
    }
    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true {
                let items = (try? FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles])) ?? []
                result += items.filter { (try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else { result.append(url) }
        }
        var seen = Set<String>(); return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
    // Probes files off the main actor, then adds them. A new project puts every picture on the
    // timeline in order; an open project keeps them in the media list until placed.
    func addMedia(_ input: [URL], newProject: Bool) {
        guard !busy else { return }
        let urls = Self.expand(input)
        guard !urls.isEmpty else { return }
        begin("미디어 확인 중 · 0 / \(urls.count)")
        let token = cancellation
        Task {
            var probed: [MediaSource] = []; var failures: [String] = []
            for (i,url) in urls.enumerated() {
                if token.cancelled { break }
                progress = Double(i)/Double(urls.count); status = "미디어 확인 중 · \(i+1) / \(urls.count) · \(url.lastPathComponent)"
                do { probed.append(try await MediaEngine.probe(url)) }
                catch { failures.append(error.localizedDescription) }
            }
            finish()
            guard !probed.isEmpty else { error = failures.isEmpty ? "가져올 수 있는 미디어가 없습니다." : failures.prefix(6).joined(separator:"\n"); status = "미디어를 가져오지 못했습니다"; return }
            if newProject || !loaded { startProject(with:probed) } else { appendMedia(probed) }
            if !failures.isEmpty { error = "일부 파일을 가져오지 못했습니다 (\(failures.count)개)\n" + failures.prefix(6).joined(separator:"\n") }
            Log.info("imported \(probed.count) media, \(failures.count) failed")
        }
    }
    private func startProject(with items: [MediaSource]) {
        var p = Project(); p.media = items
        let visuals = items.filter(\.isVisual)
        if items.count == 1, let only = items.first, only.isImage {
            p.isImage = true; p.width = only.width; p.height = only.height
        } else {
            let base = visuals.first(where:{ $0.kind == .video }) ?? visuals.first
            p.width = base?.width ?? 1920; p.height = base?.height ?? 1080; p.fps = visuals.first(where:{ $0.kind == .video })?.fps ?? 30
            if p.width <= 0 || p.height <= 0 { p.width = 1920; p.height = 1080 }
            p.clips = visuals.map { m in Clip(start:0,end:m.isImage ? 5 : m.duration,source:items.count == 1 ? nil : m.id) }
            for m in items where m.kind == .audio { p.audioClips.append(AudioClip(source:m.id,start:0,end:m.duration,position:0)) }
            p.separateOverlappingOverlays()
        }
        setProject(p)
        tab = items.count > 1 ? .media : .faces
        status = items.count == 1 ? "파일 준비 완료 · 얼굴 분석을 시작하세요" : "미디어 \(items.count)개로 새 프로젝트를 만들었습니다 · 영상은 순서대로 이어 붙였습니다"
    }
    private func appendMedia(_ items: [MediaSource]) {
        var p = project
        let existing = Set(p.media.map { URL(fileURLWithPath:$0.path).standardizedFileURL.path })
        let fresh = items.filter { !existing.contains(URL(fileURLWithPath:$0.path).standardizedFileURL.path) }
        guard !fresh.isEmpty else { status = "이미 프로젝트에 있는 미디어입니다"; return }
        if p.isImage {
            // A photo project becomes a timeline project; the photo becomes a 5-second shot.
            p.isImage = false; p.fps = fresh.first(where:{ $0.kind == .video })?.fps ?? 30
            p.clips = [Clip(start:0,end:5)]
        }
        p.normalizeSources()
        p.media += fresh
        project = p; refreshMediaStatus()
        tab = .media; selectedMedia = fresh.first?.id
        status = "미디어 \(fresh.count)개 추가 · 미디어 패널에서 타임라인에 넣거나 작업 목록에 추가하세요" + (items.count > fresh.count ? " · 중복 \(items.count-fresh.count)개 제외" : "")
    }
    // MARK: Placing media
    private func newClip(for m: MediaSource) -> Clip { Clip(start:0,end:m.isImage ? 5 : m.duration,source:m.id) }
    func appendToTimeline(_ id: UUID) {
        guard canEditTimeline, let m = project.media.first(where:{ $0.id == id }) else { return }
        guard m.isVisual else { addAudio(id); return }
        var p = project; p.normalizeSources()
        var clip = newClip(for:m)
        if p.clips.contains(where:{ $0.position != nil }) {
            clip.lane = 0; clip.position = p.timeline.filter { $0.lane == 0 }.map(\.end).max() ?? 0
        }
        p.clips.append(clip); p.exportRange = nil
        commitTimeline(p,seekTo:p.timeline.first(where:{ $0.id == clip.id })?.start); selectClip(clip.id)
        status = "\(m.name) · 타임라인 끝에 추가"
    }
    func insertAtPlayhead(_ id: UUID) {
        guard canEditTimeline, let m = project.media.first(where:{ $0.id == id }), m.isVisual else { return }
        var p = project; p.normalizeSources()
        let clip = newClip(for:m)
        if p.clips.contains(where:{ $0.position != nil }) {
            var c = clip; c.lane = selectedTrack.linkedToVideo ? selectedLane : 0; c.position = playhead
            p.clips.append(c)
            guard p.positionedCollision == nil else { status = "재생 위치에 다른 컷이 있습니다. 빈 곳이나 위 트랙 연결을 사용하세요."; return }
            commitTimeline(p); selectClip(c.id)
        } else {
            let ids = p.insertTimelineClips([clip],at:playhead)
            commitTimeline(p); if let first = ids.first { selectClip(first) }
        }
        status = "\(m.name) · 재생 위치에 삽입"
    }
    // Places the media on a free lane above, like a connected clip (picture-in-picture, B-roll).
    func connectAtPlayhead(_ id: UUID) {
        guard canEditTimeline, let m = project.media.first(where:{ $0.id == id }), m.isVisual else { return }
        var p = project; p.normalizeSources(); p.enableVideoLanes()
        var c = newClip(for:m); c.position = playhead
        let end = playhead+c.timelineDuration
        let lanes = max(p.videoLaneCount ?? 1,(p.clips.map { $0.lane ?? 0 }.max() ?? 0)+1)
        let lane = (1..<max(2,lanes+1)).first { lane in !p.timeline.contains { $0.lane == lane && $0.start < end && $0.end > playhead } } ?? lanes
        guard lane < 64 else { status = "영상 트랙이 너무 많습니다"; return }
        c.lane = lane; p.videoLaneCount = max(lanes,lane+1); p.clips.append(c); p.exportRange = nil
        commitTimeline(p); selectClip(c.id)
        status = "\(m.name) · 영상 \(lane+1) 트랙에 연결 · 오른쪽 클립 검사기에서 크기·위치를 조절하세요"
    }
    func addAudio(_ id: UUID) {
        guard canEditTimeline, let m = project.media.first(where:{ $0.id == id }), m.hasAudio else { status = "오디오가 없는 미디어입니다"; return }
        var p = project; p.normalizeSources()
        let end = playhead+m.duration
        let lanes = max(p.audioLaneCount ?? 1,(p.audioClips.map(\.lane).max() ?? 0)+1)
        let lane = (0..<lanes+1).first { lane in !p.audioClips.contains { $0.lane == lane && $0.position < end && $0.timelineEnd > playhead } } ?? lanes
        let clip = AudioClip(source:m.id,start:0,end:m.duration,position:playhead,lane:lane)
        p.audioClips.append(clip); p.audioLaneCount = max(lanes,lane+1)
        project = p; selectAudioClip(clip.id)
        status = "\(m.name) · 독립 오디오 트랙에 추가"
    }
    func removeMedia(_ id: UUID) {
        guard !busy, let m = project.media.first(where:{ $0.id == id }) else { return }
        guard project.media.count > 1 else { status = "마지막 미디어는 제거할 수 없습니다. 새 프로젝트를 여세요."; return }
        var p = project; p.normalizeSources()
        let clips = p.clips.filter { $0.source == id }.count, audio = p.audioClips.filter { $0.source == id }.count
        if clips+audio > 0 {
            let alert = NSAlert(); alert.messageText = "\(m.name)을(를) 프로젝트에서 제거할까요?"
            alert.informativeText = "타임라인에서 이 미디어를 쓰는 컷 \(clips)개와 오디오 \(audio)개도 함께 삭제됩니다. 원본 파일은 지워지지 않습니다."
            alert.addButton(withTitle:"제거"); alert.addButton(withTitle:"취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        p.clips.removeAll { $0.source == id }; p.audioClips.removeAll { $0.source == id }; p.queue.removeAll { $0.source == id }
        p.media.removeAll { $0.id == id }; p.exportRange = nil
        if selectedMedia == id { selectedMedia = nil }
        commitTimeline(p); refreshMediaStatus(); status = "\(m.name) 제거 · 원본 파일은 그대로입니다"
    }
    func relinkMedia(_ id: UUID) {
        guard !busy, let m = project.media.first(where:{ $0.id == id }) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = Self.mediaTypes; panel.allowsOtherFileTypes = true
        panel.message = "\(m.name)의 새 위치를 선택하세요. 같은 파일이어야 얼굴 분석 결과를 그대로 쓸 수 있습니다."
        panel.directoryURL = URL(fileURLWithPath:m.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let fresh = try await MediaEngine.probe(url)
                guard fresh.kind == m.kind else { throw StudioError.message("미디어 종류가 다릅니다. 같은 파일을 선택해 주세요.") }
                let same = abs(fresh.duration-m.duration) < 0.1 && abs(fresh.width-m.width) < 1 && abs(fresh.height-m.height) < 1
                if !same {
                    let alert = NSAlert(); alert.messageText = "길이나 크기가 다른 파일입니다"
                    alert.informativeText = "원래 \(timecode(m.duration)) · \(Int(m.width))×\(Int(m.height)), 선택 \(timecode(fresh.duration)) · \(Int(fresh.width))×\(Int(fresh.height)).\n계속하면 이 미디어의 얼굴 분석 결과를 지우고 컷을 새 길이에 맞춥니다."
                    alert.addButton(withTitle:"계속"); alert.addButton(withTitle:"취소")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                guard let i = project.media.firstIndex(where:{ $0.id == id }) else { return }
                var p = project
                p.media[i].path = fresh.path; p.media[i].fileSize = fresh.fileSize; p.media[i].modified = fresh.modified; p.media[i].hasAudio = fresh.hasAudio
                if !same {
                    p.media[i].duration = fresh.duration; p.media[i].width = fresh.width; p.media[i].height = fresh.height; p.media[i].fps = fresh.fps
                    p.media[i].faces = []; p.media[i].analysisComplete = false; p.media[i].maskApplied = false; p.media[i].reviewRanges = []; p.media[i].transcript = nil
                    for c in p.clips.indices where p.sourceID(of:p.clips[c]) == id && !fresh.isImage { p.clips[c].end = min(p.clips[c].end,fresh.duration); if p.clips[c].start >= p.clips[c].end { p.clips[c].start = max(0,p.clips[c].end-1) } }
                    for a in p.audioClips.indices where p.audioClips[a].source == id { p.audioClips[a].end = min(p.audioClips[a].end,fresh.duration); if p.audioClips[a].start >= p.audioClips[a].end { p.audioClips[a].start = max(0,p.audioClips[a].end-1) } }
                }
                project = p; refreshMediaStatus(); built = nil; refreshPreview()
                status = same ? "\(m.name) 다시 연결 완료 · 분석 결과 유지" : "\(m.name) 다시 연결 · 얼굴을 다시 분석하세요"
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Faces
    func runFaceAnalysis(_ source: MediaSource, token: Cancellation) async throws -> (FaceAnalyzer.Output,[TimelineRange]) {
        let used = project.analysisRanges(for:source.id)
        let ranges = source.isImage ? [] : (used.isEmpty ? [TimelineRange(start:0,end:source.duration)] : used)
        let mode = analysisMode
        let output = try await FaceAnalyzer.analyze(source:source,ranges:ranges,mode:mode,cancellation:token) { [weak self = self] value,message in Task { @MainActor in guard let self, !token.cancelled else { return }; self.progress = value; self.status = message } }
        return (output,ranges)
    }
    func storeAnalysis(_ output: FaceAnalyzer.Output, ranges: [TimelineRange], source id: UUID) {
        guard let i = project.media.firstIndex(where:{ $0.id == id }) else { return }
        var p = project
        p.media[i].faces = output.tracks; p.media[i].analysisComplete = true; p.media[i].maskApplied = false
        p.media[i].analyzedRanges = ranges; p.media[i].reviewRanges = output.review
        project = p; refreshFaceCoverage()
    }
    func analyze(_ id: UUID? = nil) {
        guard loaded, !busy, let source = id.flatMap({ i in project.media.first { $0.id == i } }) ?? faceSource, source.isVisual else { return }
        do { try verifySource(source.id) } catch { self.error = error.localizedDescription; return }
        begin("\(source.name) · 얼굴 분석 준비 중"); let token = cancellation
        Task {
            do {
                let (output,ranges) = try await runFaceAnalysis(source,token:token)
                storeAnalysis(output,ranges:ranges,source:source.id); selectedMedia = source.id
                let persons = Set(output.tracks.map(\.groupID)).count
                status = "인물 \(persons)명 발견 (추적 조각 \(output.tracks.count)개)" + (output.review.isEmpty ? "" : " · 검토 권장 구간 \(output.review.count)개") + " · 확인 후 마스킹 적용"
                finish(); Log.info("face analysis: \(output.frames) frames, \(output.tracks.count) tracks, \(persons) persons")
                if autoCaptions && !project.isImage && project.captions.isEmpty && source.hasAudio { transcribe() }
            } catch { fail(error) }
        }
    }
    func applyMasks() {
        guard let id = faceSource?.id, let i = project.media.firstIndex(where:{ $0.id == id }) else { return }
        project.media[i].maskApplied = true
        status = "선택한 인물 \(Set(project.media[i].faces.filter(\.selected).map(\.groupID)).count)명에 마스킹 적용 · \(project.media[i].name)"
    }
    func toggleFace(_ id: UUID, selected: Bool) {
        guard let m = project.media.firstIndex(where:{ $0.faces.contains { $0.id == id } }), let face = project.media[m].faces.first(where:{ $0.id == id }) else { return }
        var p = project
        let legacyGroup = face.name.contains("· 병합 그룹")
        for i in p.media[m].faces.indices where p.media[m].faces[i].id == id || (face.group != nil && p.media[m].faces[i].group == face.group) || (legacyGroup && p.media[m].faces[i].name == face.name) { p.media[m].faces[i].selected = selected }
        project = p
    }
    func setGroupSelection(_ ids: [UUID], selected: Bool) {
        guard let first = ids.first, let m = project.media.firstIndex(where:{ $0.faces.contains { $0.id == first } }) else { return }
        let set = Set(ids); var p = project
        for i in p.media[m].faces.indices where set.contains(p.media[m].faces[i].id) { p.media[m].faces[i].selected = selected }
        project = p
    }
    func toggleFaceMember(_ id: UUID, selected: Bool) {
        guard let m = project.media.firstIndex(where:{ $0.faces.contains { $0.id == id } }), let i = project.media[m].faces.firstIndex(where:{ $0.id == id }) else { return }
        project.media[m].faces[i].selected = selected
    }
    func setAllFaces(selected: Bool) {
        guard let id = faceSource?.id, let m = project.media.firstIndex(where:{ $0.id == id }) else { return }
        var p = project; for i in p.media[m].faces.indices { p.media[m].faces[i].selected = selected }; project = p
    }
    // Joins persons into one; each fragment keeps its own boxes.
    func groupFaces(_ ids: Set<UUID>) {
        guard ids.count >= 2, let m = project.media.firstIndex(where:{ $0.faces.contains { ids.contains($0.id) } }) else { return }
        var p = project
        let members = p.media[m].faces.filter { ids.contains($0.id) }
        let groups = Set(members.map(\.groupID))
        guard let first = members.first else { return }
        let group = first.group ?? UUID(), name = first.name
        for i in p.media[m].faces.indices where groups.contains(p.media[m].faces[i].groupID) { p.media[m].faces[i].group = group; p.media[m].faces[i].name = name }
        project = p; status = "\(groups.count)명을 ‘\(name)’으로 묶었습니다 · 모든 검출 영역은 유지됩니다"
    }
    func mergeSelected() {
        guard let source = faceSource else { return }
        let ids = Set(source.faces.filter(\.selected).map(\.id))
        guard Set(source.faces.filter { ids.contains($0.id) }.map(\.groupID)).count >= 2 else { return }
        groupFaces(ids)
    }
    func ungroupFace(_ id: UUID) {
        guard let m = project.media.firstIndex(where:{ $0.faces.contains { $0.id == id } }), let i = project.media[m].faces.firstIndex(where:{ $0.id == id }) else { return }
        var p = project; p.media[m].faces[i].group = UUID(); p.media[m].faces[i].name = p.media[m].faces[i].name + " · 분리"
        project = p; status = "인물 그룹에서 분리했습니다"
    }
    func renameFaceGroup(_ group: UUID, name: String) {
        guard let m = project.media.firstIndex(where:{ $0.faces.contains { $0.groupID == group } }) else { return }
        var p = project; for i in p.media[m].faces.indices where p.media[m].faces[i].groupID == group { p.media[m].faces[i].name = name }
        pendingCoalesce = "rename-\(group)"; project = p
    }

    // MARK: Speech
    // Source ranges whose sound reaches the output.
    var speechJobs: [(UUID,[TimelineRange])] {
        var jobs: [UUID:[TimelineRange]] = [:]; var order: [UUID] = []
        for e in project.timeline.sorted(by:{ $0.start < $1.start }) where e.clip.gain > 0 && e.clip.freeze == nil {
            guard let s = project.source(e.clip.source), s.hasAudio, s.kind == .video else { continue }
            if jobs[s.id] == nil { order.append(s.id) }; jobs[s.id, default:[]].append(TimelineRange(start:e.clip.start,end:e.clip.end))
        }
        for a in project.audioClips.sorted(by:{ $0.position < $1.position }) where a.gain > 0 {
            if jobs[a.source] == nil { order.append(a.source) }; jobs[a.source, default:[]].append(TimelineRange(start:a.start,end:a.end))
        }
        return order.map { ($0,TimelineRange.merged(jobs[$0] ?? [])) }
    }
    var speechSignature: String { "\(speechOptions.engine.rawValue)|\(speechOptions.whisperModelPath)|\(speechOptions.maxLineChars)|\(speechOptions.maxLines)|\(speechOptions.voiceDetection)|\(speechOptions.gain)|\(speechOptions.audioTrack)|\(speechOptions.hints)" }
    func transcribe(testOnly: Bool = false, force: Bool = false) {
        guard loaded, !project.isImage, !busy else { return }
        speechNotes = []
        let locale = language, options = speechOptions
        if testOnly {
            guard let entry = project.visibleTimeline.first(where:{ playhead >= $0.start && playhead < $0.end }), let source = project.source(entry.clip.source), entry.clip.freeze == nil else { status = "테스트할 영상 컷 안에 재생 헤드를 놓아 주세요."; return }
            do { try verifySource(source.id) } catch { self.error = error.localizedDescription; return }
            let start = entry.sourceTime(at:playhead), end = min(entry.clip.end,start+15)
            guard end > start+0.2 else { status = "시험할 구간이 너무 짧습니다"; return }
            begin("시험 인식 준비 중"); let token = cancellation
            Task {
                do {
                    let report = try await Transcription.transcribe(source:source,ranges:[TimelineRange(start:start,end:end)],locale:locale,options:options,cancellation:token) { [weak self = self] v,s in Task { @MainActor in self?.progress = v; self?.status = s } }
                    speechNotes = report.warnings + report.captions.map { "\(timecode($0.start)) · \($0.text.replacingOccurrences(of:"\n",with:" "))" + (($0.confidence ?? 1) < SpeechOptions.reviewConfidence ? " · 확인 필요" : "") }
                    status = "15초 이내 인식 테스트 완료 · 기존 자막은 유지됩니다"; finish()
                } catch { fail(error) }
            }
            return
        }
        let jobs = speechJobs
        guard !jobs.isEmpty else { error = "소리가 있는 컷이 타임라인에 없습니다."; return }
        do { for (id,_) in jobs { try verifySource(id) } } catch { self.error = error.localizedDescription; return }
        begin("자동 자막 준비 중"); let token = cancellation; let signature = speechSignature + "|\(locale)"
        Task {
            var results: [UUID:[Caption]] = [:]; var warnings: [String] = []; var failures: [String] = []
            for (n,(id,ranges)) in jobs.enumerated() {
                guard !token.cancelled, let source = project.media.first(where:{ $0.id == id }) else { break }
                var cached = source.transcript?.engine == signature && !force ? source.transcript : nil
                let missing = cached.map { TimelineRange.subtracting(ranges,$0.ranges) } ?? ranges
                if !missing.isEmpty {
                    do {
                        let report = try await Transcription.transcribe(source:source,ranges:missing,locale:locale,options:options,cancellation:token) { [weak self = self] v,s in
                            Task { @MainActor in guard let self, !token.cancelled else { return }; self.progress = (Double(n)+v)/Double(jobs.count); self.status = jobs.count > 1 ? "[\(n+1)/\(jobs.count)] " + s : s }
                        }
                        warnings += report.warnings.map { "\(source.name) · \($0)" }
                        let kept = (cached?.captions ?? []).filter { c in !missing.contains { $0.contains(c.start) } }
                        cached = SourceTranscript(engine:signature,language:locale,ranges:TimelineRange.merged((cached?.ranges ?? [])+missing),captions:(kept+report.captions).sorted { $0.start < $1.start })
                        if let i = project.media.firstIndex(where:{ $0.id == id }) { restoring = true; project.media[i].transcript = cached; restoring = false }
                    } catch is CancellationError { fail(CancellationError()); return }
                    catch { failures.append("\(source.name): \(error.localizedDescription)"); continue }
                }
                results[id] = cached?.captions ?? []
            }
            if token.cancelled { fail(CancellationError()); return }
            let captions = project.timelineCaptions(from:results)
            guard !captions.isEmpty else { fail(StudioError.message(failures.isEmpty ? "인식된 대사가 없습니다. 기존 자막은 유지했습니다." : failures.joined(separator:"\n"))); return }
            var p = project; p.captions = captions; p.separateOverlappingOverlays(); project = p
            speechNotes = failures + warnings
            let review = captions.filter { ($0.confidence ?? 1) < SpeechOptions.reviewConfidence }.count
            status = "자막 \(captions.count)개 생성" + (review > 0 ? " · 확인이 필요한 문장 \(review)개" : "") + (failures.isEmpty ? "" : " · 실패한 미디어 \(failures.count)개") + " · 내용을 검토하세요"
            tab = .captions; finish(); Log.info("transcribed \(jobs.count) sources, \(captions.count) captions")
        }
    }
    func importSRT() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension:"srt") ?? .plainText,.plainText]
        if panel.runModal() == .OK, let url = panel.url { do {
            let data = try Data(contentsOf:url)
            let text = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) ?? String(decoding:data,as:UTF8.self)
            let captions = Subtitles.parse(text); guard !captions.isEmpty else { throw StudioError.message("유효한 SRT 자막이 없습니다.") }
            project.captions = captions; project.separateOverlappingOverlays(); tab = .captions; status = "SRT 자막 \(captions.count)개 가져옴"
        } catch { self.error = error.localizedDescription } }
    }
    func exportSRT() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "자막.srt"
        if panel.runModal() == .OK, let url = panel.url { do { try Subtitles.srt(project.outputCaptions()).write(to:url,atomically:true,encoding:.utf8); status = "컷 편집을 반영한 SRT 저장 완료" } catch { self.error = error.localizedDescription } }
    }
    func exportMedia() {
        do { try verifyUsedSources() } catch { self.error = error.localizedDescription; return }
        let ext = project.isImage ? project.export.resolvedImageFormat.rawValue : project.export.fileExtension
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension:ext) ?? .data]; panel.nameFieldStringValue = fileName.replacingOccurrences(of:"/",with:"-") + "_편집." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !project.media.contains(where:{ URL(fileURLWithPath:$0.path).standardizedFileURL.resolvingSymlinksInPath().path == target }) else { error = "원본을 보호하기 위해 다른 파일 이름으로 저장해 주세요."; return }
        exportSheet = false; begin("내보내기 준비 중"); let p = project; let token = cancellation
        Task { do {
            try await MediaEngine.export(p,to:url,cancellation:token) { [weak self = self] v,s in Task { @MainActor in self?.progress = v; self?.status = s } }
            lastExport = url; status = "내보내기 완료 · \(url.lastPathComponent)"; finish(); Log.info("exported \(url.lastPathComponent)")
        } catch { fail(error) } }
    }

    // MARK: Waveforms (per source, only the used ranges)
    func refreshWaveforms() {
        guard loaded, !project.isImage else { return }
        var needed: [UUID:[TimelineRange]] = [:]
        for clip in project.clips where clip.freeze == nil {
            guard let id = project.sourceID(of:clip), let s = project.source(id), s.kind == .video, s.hasAudio else { continue }
            needed[id, default:[]].append(TimelineRange(start:clip.start,end:clip.end))
        }
        for a in project.audioClips { needed[a.source, default:[]].append(TimelineRange(start:a.start,end:a.end)) }
        for (id,list) in needed {
            let ranges = TimelineRange.merged(list)
            guard waveforms[id]?.covers(ranges) != true, waveformRequested[id] != ranges, let source = project.media.first(where:{ $0.id == id }) else { continue }
            let union = TimelineRange.merged(ranges+(waveforms[id]?.ranges ?? []))
            waveformTasks[id]?.cancel(); waveformRequested[id] = ranges
            let session = sessionID, url = URL(fileURLWithPath:source.path), duration = source.duration
            waveformTasks[id] = Task { [weak self] in
                let token = Cancellation()
                do {
                    let data = try await withTaskCancellationHandler { try await AudioWaveform.read(source:url,duration:duration,ranges:union,cancellation:token) } onCancel:{ token.cancel() }
                    guard let self, !Task.isCancelled, self.sessionID == session else { return }
                    self.waveforms[id] = data; self.waveformRevision += 1
                } catch {
                    guard let self, !Task.isCancelled, self.sessionID == session else { return }
                    self.waveformStatus = "파형을 읽지 못했습니다"
                }
            }
        }
    }
}

extension Project {
    // Gives clips without an explicit source the first media's id, so later media changes
    // cannot silently re-point them.
    mutating func normalizeSources() {
        guard let first = media.first?.id else { return }
        for i in clips.indices where clips[i].source == nil { clips[i].source = first }
    }
    // Places source-time captions under every audible clip that plays them.
    func timelineCaptions(from sources: [UUID:[Caption]]) -> [Caption] {
        var result: [Caption] = []
        func place(_ c: Caption, from a: Double, to b: Double, at timeline: (Double) -> Double) {
            let visible = b-a
            // Captions mostly cut away by an edit are dropped instead of flashing briefly.
            guard visible >= min(0.5,(c.end-c.start)*0.4) else { return }
            var v = c; v.id = UUID(); v.lane = nil; v.start = timeline(a); v.end = timeline(b)
            if v.end > v.start { result.append(v) }
        }
        for e in timeline where e.clip.gain > 0 && e.clip.freeze == nil {
            guard let id = sourceID(of:e.clip), let list = sources[id] else { continue }
            for c in list {
                let a = max(c.start,e.clip.start), b = min(c.end,e.clip.end); guard b > a else { continue }
                place(c,from:a,to:b) { e.start+e.clip.offset(forSource:$0) }
            }
        }
        for clip in audioClips where clip.gain > 0 {
            guard let list = sources[clip.source] else { continue }
            for c in list {
                let a = max(c.start,clip.start), b = min(c.end,clip.end); guard b > a else { continue }
                place(c,from:a,to:b) { clip.position+$0-clip.start }
            }
        }
        return result.sorted { $0.start < $1.start }
    }
}
