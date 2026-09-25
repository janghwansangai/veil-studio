import SwiftUI
import AVKit
import UniformTypeIdentifiers

@MainActor final class EditorStore: ObservableObject {
    @Published var project = Project() {
        didSet {
            guard !restoring, project != oldValue else { return }
            if timelineGestureStart == nil, !oldValue.sourcePath.isEmpty { undoStack.append(oldValue); if undoStack.count > 40 { undoStack.removeFirst() }; redoStack = [] }
            if timelineGestureStart == nil { schedulePreview(); scheduleRecovery() }
        }
    }
    @Published var player = AVPlayer()
    @Published var stillPreview: NSImage?
    @Published var playhead = 0.0
    @Published var playing = false
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = "파일을 불러와 편집을 시작하세요"
    @Published var error: String?
    @Published var tab = EditorTab.faces
    @Published var drawMode = false
    @Published var selectedTrack = EditTrack.video
    @Published var selectedLane = 0
    @Published var selectedCaption: UUID?
    @Published var wholeOverlayTrack = false
    var clipboardCaptions: [Caption] = []
    var clipboardRegions: [ManualRegion] = []
    var overlayTime: Double { project.overlaysOnTimeline == true ? playhead : sourcePlayhead }
    var selectionAvailable: Bool {
        if selectedTrack.linkedToVideo { return canDeleteClips }
        if selectedTrack == .regions { return project.regions.contains { $0.id == selectedRegion && ($0.lane ?? 0) == selectedLane } }
        return project.captions.contains { $0.id == selectedCaption && ($0.lane ?? 0) == selectedLane }
    }
    var pasteAvailable: Bool { selectedTrack.linkedToVideo ? !clipboardClips.isEmpty : selectedTrack == .regions ? !clipboardRegions.isEmpty : !clipboardCaptions.isEmpty }
    @Published var selectedRegion: UUID?
    @Published var selectedClip: UUID?
    @Published var selectedClips = Set<UUID>()
    @Published var clipboardClips: [Clip] = []
    @Published var editingText = false
    @Published var previewReady = false
    @Published var waveform: AudioWaveform?
    @Published var waveformStatus = ""
    @Published var waveformRevision = 0
    private var waveformTask: Task<Void,Never>?
    private var waveformCancellation: Cancellation?
    private var waveformRequested: [TimelineRange] = []
    @Published var faceSourceCoverage: [TimelineRange] = []
    @Published var faceCoverage: [TimelineRange] = []
    private var cachedComposition: AVMutableComposition?
    private var cachedClips: [Clip] = []
    private var cachedSource = ""
    private var previewRevision = 0
    private var timelineGestureStart: Project?
    var canEditTimeline: Bool { loaded && !project.isImage && !busy }
    var canDeleteClips: Bool { canEditTimeline && project.clips.contains { selectedClips.contains($0.id) && ($0.lane ?? 0) == selectedLane } }
    var sourcePlayhead: Double { project.isImage ? 0 : project.sourceTime(for:playhead) }
    @Published var exportSheet = false
    @Published var helpSheet = false
    @Published var autoCaptions = true
    @Published var speechOptions = SpeechOptions()
    @Published var language = "ko-KR"
    @Published var speechNotes: [String] = []
    @Published var lastExport: URL?
    @Published var projectURL: URL?
    @Published var undoStack: [Project] = []
    @Published var redoStack: [Project] = []
    var automaticRecoveryEnabled = true
    var cancellation = Cancellation()
    private var restoring = false
    private var observer: Any?
    private var previewTask: Task<Void,Never>?
    private var recoveryTask: Task<Void,Never>?
    private let renderer = MaskRenderer()
    private(set) var sessionID = UUID()
    @Published private var savedProject: Project?
    var hasUnsavedChanges: Bool { loaded && project != savedProject }
    // Resolve identity on every access; old SwiftUI controls can outlive their project.
    func itemBinding<Item: Identifiable>(_ path: WritableKeyPath<Project,[Item]>, item: Item) -> Binding<Item> {
        let session = sessionID
        return Binding(get: { [weak self] in
            guard let self, self.sessionID == session else { return item }
            return self.project[keyPath:path].first { $0.id == item.id } ?? item
        }, set: { [weak self] value in
            guard let self, self.sessionID == session,
                  let index = self.project[keyPath:path].firstIndex(where: { $0.id == item.id }) else { return }
            self.project[keyPath:path][index] = value
        })
    }
    enum LeaveChoice { case save, discard, cancel }
    func resolveLeave(_ choice: LeaveChoice, save: () -> Bool) -> Bool {
        switch choice { case .save: return save(); case .discard: return true; case .cancel: return false }
    }
    func confirmLeaving() -> Bool {
        focusTimeline(); endTimelineGesture(); pause()
        guard !busy else { error = "진행 중인 작업을 취소하거나 완료한 후 다시 시도해 주세요."; return false }
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert(); alert.messageText = "변경한 프로젝트를 저장하시겠습니까?"
        alert.informativeText = "저장하지 않고 계속하면 현재 변경 사항을 잃을 수 있습니다."
        alert.addButton(withTitle:"저장"); alert.addButton(withTitle:"저장하지 않음"); alert.addButton(withTitle:"취소")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        let response = alert.runModal()
        return resolveLeave(response == .alertFirstButtonReturn ? .save : response == .alertSecondButtonReturn ? .discard : .cancel,save:saveProjectIfPossible)
    }
    var loaded: Bool { !project.sourcePath.isEmpty }
    var fileName: String { loaded ? URL(fileURLWithPath:project.sourcePath).lastPathComponent : "새 프로젝트" }
    var recoveryURL: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VeilStudio/Recovery.veilproject") }
    init() {
        observer = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.05,preferredTimescale:600),queue:.main) { [weak self] t in
            Task { @MainActor in
                guard let self, self.previewReady, t.seconds.isFinite else { return }
                self.playhead = min(self.project.editedDuration,max(0,t.seconds))
                if self.playing && t.seconds >= self.project.editedDuration-0.015 { self.pause() }
            }
        }
    }
    func openMedia() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie,.video,.image]; panel.allowsOtherFileTypes = true; panel.allowsMultipleSelection = false
        panel.message = "편집할 동영상 또는 이미지를 선택하세요. 원본은 변경하지 않습니다."
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL) {
        guard !busy, confirmLeaving() else { return }; pause(); begin("파일 정보 읽는 중")
        Task {
            do { let p = try await MediaEngine.load(url); setProject(p); projectURL = nil; status = "파일 준비 완료 · 얼굴 분석을 시작하세요"; finish() }
            catch { fail(error) }
        }
    }
    func setProject(_ p: Project) {
        pause(); previewTask?.cancel(); recoveryTask?.cancel(); previewRevision += 1
        previewReady = false; player.currentItem?.cancelPendingSeeks(); player.replaceCurrentItem(with:nil)
        cachedComposition = nil; cachedClips = []; cachedSource = ""; stillPreview = nil
        waveformCancellation?.cancel(); waveformTask?.cancel(); waveform = nil; waveformRequested = []; waveformStatus = ""
        sessionID = UUID(); savedProject = nil; projectURL = nil; timelineGestureStart = nil
        clipboardCaptions = []; clipboardRegions = []; wholeOverlayTrack = false; drawMode = false
        var p = p; p.repairEditableTimes(); p.migrateOverlayTimeline(); p.separateOverlappingOverlays(); selectedTrack = .video; selectedLane = 0; selectedCaption = nil
        speechNotes = []; restoring = true; project = p; restoring = false; undoStack = []; redoStack = []; playhead = 0; selectedClip = p.clips.first?.id; selectedRegion = nil; lastExport = nil
        selectedClips = Set(p.clips.prefix(1).map(\.id)); clipboardClips = []
        previewReady = false; player.replaceCurrentItem(with:nil)
        refreshPreview(); scheduleRecovery()
    }
    func begin(_ message: String) { busy = true; progress = 0; status = message; cancellation = Cancellation(); pause() }
    func finish() { busy = false }
    func fail(_ e: Error) { busy = false; if e is CancellationError { status = "작업이 취소되었습니다" } else { error = e.localizedDescription; status = "작업을 완료하지 못했습니다" } }
    func cancel() { cancellation.cancel(); status = "작업 취소 중…" }
    func verifySource() throws {
        let url = URL(fileURLWithPath:project.sourcePath); let info = try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        guard Int64(info.fileSize ?? -1) == project.fileSize, info.contentModificationDate == project.modified else { throw StudioError.message("원본 파일이 변경되었거나 이동했습니다. 파일을 다시 불러와 분석하세요.") }
    }
    func analyze() {
        guard loaded, !busy else { return }
        do { try verifySource() } catch { self.error = error.localizedDescription; return }
        begin("남은 영상 컷 얼굴 분석 준비 중"); let snapshot = project; let token = cancellation
        Task {
            do {
                let faces = try await MediaEngine.analyze(snapshot,cancellation:token) { [weak self = self] value,message in Task { @MainActor in self?.progress = value; self?.status = message } }
                project.faces = faces; project.analysisComplete = true; project.maskApplied = false
                status = "인물 후보 \(faces.count)개 발견 · 선택 후 마스킹 적용"; finish()
                if autoCaptions && !project.isImage && project.captions.isEmpty { transcribe() }
            } catch { fail(error) }
        }
    }
    func transcribe(testOnly: Bool = false) {
        guard loaded, !project.isImage, !busy else { return }; do { try verifySource() } catch { self.error = error.localizedDescription; return }; speechNotes = []; begin("자동 자막 준비 중"); var snapshot = project; let token = cancellation; let locale = language; let options = speechOptions
        if testOnly {
            guard let entry = project.visibleTimeline.first(where:{playhead >= $0.start && playhead < $0.end}) else { finish(); status = "테스트할 영상 컷 안에 재생 헤드를 놓아 주세요."; return }
            let start = entry.clip.start+playhead-entry.start
            snapshot.clips = [Clip(start:start,end:min(entry.clip.end,start+15))]; snapshot.videoLaneCount = nil
        }
        Task {
            do {
                let report = try await Transcription.run(project:snapshot,locale:locale,options:options,cancellation:token) { [weak self = self] v,s in Task { @MainActor in self?.progress = v; self?.status = s } }
                if testOnly { speechNotes = report.warnings + report.captions.map { "\(timecode($0.start)) · \($0.text)" }; status = "15초 이내 인식 테스트 완료 · 기존 자막은 유지됩니다"; finish(); return }
                var mapped = project; mapped.overlaysOnTimeline = nil; mapped.captions = report.captions; project.captions = mapped.outputCaptions(respectExportRange:false); project.separateOverlappingOverlays(); speechNotes = report.warnings; status = report.summary; tab = .captions; finish()
            } catch { fail(error) }
        }
    }
    func applyMasks() { project.maskApplied = true; status = "선택한 인물 후보 \(project.faces.filter(\.selected).count)개에 마스킹 적용" }
    func mergeSelected() {
        let faces = project.faces.filter(\.selected); guard faces.count >= 2, var first = faces.first else { return }
        // Keep simultaneous detections as separate tracks: merging identities must not lose a box.
        let name = "\(first.name) · 병합 그룹"; let ids = Set(faces.map(\.id))
        first.name = name
        var p = project
        for i in p.faces.indices where ids.contains(p.faces[i].id) { p.faces[i].name = name }
        project = p; status = "선택한 후보를 같은 이름의 그룹으로 묶었습니다. 모든 검출 영역은 유지됩니다."
    }
    func toggleFace(_ id: UUID, selected: Bool) {
        guard let face = project.faces.first(where: {$0.id == id}) else { return }
        var p = project
        for i in p.faces.indices where p.faces[i].id == id || (face.name.contains("· 병합 그룹") && p.faces[i].name == face.name) { p.faces[i].selected = selected }
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
    func seek(_ time: Double) {
        guard time.isFinite else { return }
        playhead = min(project.editedDuration,max(0,time))
        if previewReady { player.seek(to:CMTime(seconds:playhead,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero) }
    }
    func seekSource(_ time: Double) {
        if let t = project.timelineTime(forSource:time,preferredClip:selectedClip) { seek(t) }
        else { status = "이 원본 시점은 현재 편집 타임라인에 포함되어 있지 않습니다" }
    }
    func pause() { player.pause(); playing = false }
    func togglePlay() {
        guard canEditTimeline, previewReady, !project.clips.isEmpty else { return }
        if playing { pause() } else { if playhead >= project.editedDuration-0.015 { seek(0) }; playing = true; player.play() }
    }
    func focusTimeline() { NSApplication.shared.keyWindow?.makeFirstResponder(nil); editingText = false }
    func selectClip(_ id: UUID, extending: Bool = false) {
        focusTimeline(); selectedTrack = .video; selectedLane = project.clips.first(where:{$0.id == id})?.lane ?? 0; selectedClip = id
        if extending { if selectedClips.contains(id) { selectedClips.remove(id) } else { selectedClips.insert(id) } }
        else { selectedClips = [id] }
    }
    func beginTimelineGesture() { if timelineGestureStart == nil { timelineGestureStart = project } }
    func endTimelineGesture() {
        if let initial = timelineGestureStart, initial != project { undoStack.append(initial); if undoStack.count > 40 { undoStack.removeFirst() }; redoStack = [] }
        project.separateOverlappingOverlays(); synchronizeSelectedLane(); timelineGestureStart = nil; schedulePreview(); scheduleRecovery()
    }
    func commitTimeline(_ p: Project, seekTo: Double? = nil) {
        pause(); previewReady = false; project = p
        selectedClips.formIntersection(Set(p.clips.map(\.id)))
        if !p.clips.contains(where:{$0.id == selectedClip}) { selectedClip = p.clips.first?.id }
        playhead = min(p.editedDuration,max(0,seekTo ?? playhead))
    }
    func split() {
        guard canEditTimeline else { return }
        if selectedTrack == .regions || selectedTrack == .captions { splitOverlay(); return }
        guard canEditTimeline else { return }; var p = project
        guard let entry = p.timeline.first(where:{ ($0.clip.lane ?? 0) == selectedLane && playhead > $0.start && playhead < $0.end }), let id = p.splitTimeline(at:playhead,clipID:entry.id) else { status = "분할할 컷 안쪽으로 재생 헤드를 이동하세요"; return }
        commitTimeline(p); selectClip(id); status = "현재 위치에서 컷 분할"
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
            let copies = clipboardClips.map { c -> Clip in defer { cursor += c.duration }; return Clip(start:c.start,end:c.end,lane:selectedLane,position:cursor) }
            guard !p.timeline.contains(where:{($0.clip.lane ?? 0) == selectedLane && $0.start < cursor && $0.end > playhead}) else { status = "붙여넣을 위치에 컷이 있습니다. 빈 영상 트랙을 선택하세요."; return }
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
    func selectAllClips() { guard canEditTimeline else { return }
        if selectedTrack == .captions { wholeOverlayTrack = true; selectedCaption = project.captions.first(where:{($0.lane ?? 0) == selectedLane})?.id; return }
        if selectedTrack == .regions { wholeOverlayTrack = true; selectedRegion = project.regions.first(where:{($0.lane ?? 0) == selectedLane})?.id; return }
        selectedTrack = .video; selectedClips = Set(project.clips.filter { ($0.lane ?? 0) == selectedLane }.map(\.id)); selectedClip = project.clips.first?.id; focusTimeline() }
    func moveClip(_ id: UUID, before target: UUID?) {
        if (project.videoLaneCount ?? 1) > 1 {
            let entry = project.timeline.first(where:{$0.id == target})
            moveItem(id,to:.video,lane:entry?.clip.lane ?? selectedLane,at:entry?.start ?? project.editedDuration); return
        }
        guard canEditTimeline else { return }; var p = project; p.moveTimelineClip(id,before:target)
        let t = p.timeline.first(where:{$0.id == id})?.start ?? 0
        commitTimeline(p,seekTo:t); selectClip(id); status = "컷 순서 변경"
    }
    func moveSelected(_ direction: Int) {
        if selectedTrack == .captions, let c = project.captions.first(where:{$0.id == selectedCaption}) { editOverlayTime(id:c.id,region:false,original:TimelineRange(start:c.start,end:c.end),delta:Double(direction)/project.fps,edge:0); return }
        if selectedTrack == .regions, let r = project.regions.first(where:{$0.id == selectedRegion}) { editOverlayTime(id:r.id,region:true,original:TimelineRange(start:r.start,end:r.end),delta:Double(direction)/project.fps,edge:0); return }
        if (project.videoLaneCount ?? 1) > 1, let id = selectedClip, let entry = project.timeline.first(where:{$0.id == id}) { moveItem(id,to:.video,lane:entry.clip.lane ?? 0,at:entry.start+Double(direction)/project.fps); return }
        guard let id = selectedClip, let index = project.clips.firstIndex(where:{$0.id == id}) else { return }
        if direction < 0, index > 0 { moveClip(id,before:project.clips[index-1].id) }
        if direction > 0, index < project.clips.count-1 { moveClip(id,before:index+2 < project.clips.count ? project.clips[index+2].id : nil) }
    }
    func trimClip(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard canEditTimeline, let index = project.clips.firstIndex(where:{$0.id == id}) else { return }
        var p = project; let minimum = min(1/project.fps,p.duration)
        if let start, start.isFinite { p.clips[index].start = max(0,min(p.clips[index].end-minimum,start)) }
        if let end, end.isFinite { p.clips[index].end = min(p.duration,max(p.clips[index].start+minimum,end)) }
        if let position = project.clips[index].position {
            let old = project.clips[index]
            let lane = old.lane ?? 0
            let prev = project.timeline.filter { $0.id != id && ($0.clip.lane ?? 0) == lane && $0.end <= position }.map(\.end).max() ?? 0
            let next = project.timeline.filter { $0.id != id && ($0.clip.lane ?? 0) == lane && $0.start >= position+old.duration }.map(\.start).min() ?? .infinity
            p.clips[index].start = max(p.clips[index].start,old.start-(position-prev))
            p.clips[index].position = position+p.clips[index].start-old.start
            p.clips[index].end = min(p.clips[index].end,old.start+next-position)
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
        if selectedTrack == .captions, let c = project.captions.first(where:{$0.id == selectedCaption}) { setExportRange(start:c.start,end:c.end); return }
        if selectedTrack == .regions, let r = project.regions.first(where:{$0.id == selectedRegion}) { setExportRange(start:r.start,end:r.end); return }
        let entries = project.timeline.filter { selectedClips.contains($0.id) }
        guard let first = entries.first, let last = entries.last else { return }
        setExportRange(start:first.start,end:last.end)
    }
    func deleteMarkedRange() {
        guard canEditTimeline, let range = project.exportRange else { return }
        if selectedTrack == .captions || selectedTrack == .regions {
            var p = project
            if selectedTrack == .captions {
                p.captions = p.captions.flatMap { c -> [Caption] in
                    guard (c.lane ?? 0) == selectedLane, c.end > range.start, c.start < range.end else { return [c] }
                    var parts: [Caption] = []
                    if c.start < range.start { var left = c; left.end = range.start; parts.append(left) }
                    if c.end > range.end { var right = c; right.id = UUID(); right.start = range.end; parts.append(right) }; return parts
                }
            } else {
                p.regions = p.regions.flatMap { r -> [ManualRegion] in
                    guard (r.lane ?? 0) == selectedLane, r.end > range.start, r.start < range.end else { return [r] }
                    var parts: [ManualRegion] = []
                    if r.start < range.start { var left = r; left.end = range.start; parts.append(left) }
                    if r.end > range.end { var right = r; right.id = UUID(); right.start = range.end; parts.append(right) }; return parts
                }
            }
            project = p; status = "선택 트랙의 지정 구간만 삭제했습니다"; return
        }
        if (project.videoLaneCount ?? 1) > 1 {
            var p = project
            p.clips = p.timeline.flatMap { entry -> [Clip] in
                guard (entry.clip.lane ?? 0) == selectedLane, entry.end > range.start, entry.start < range.end else { return [entry.clip] }
                var parts: [Clip] = []
                if entry.start < range.start { var left = entry.clip; left.end = left.start+range.start-entry.start; parts.append(left) }
                if entry.end > range.end { var right = entry.clip; right.id = UUID(); right.start += range.end-entry.start; right.position = range.end; parts.append(right) }; return parts
            }
            p.exportRange = nil; commitTimeline(p); return
        }
        var p = project; p.deleteTimelineRange(range); commitTimeline(p,seekTo:range.start)
        selectedClips = []; selectedClip = nil; status = "지정 구간 삭제 · 뒤의 컷을 앞으로 붙였습니다"
    }
    func editOverlayTime(id: UUID, region: Bool, original: TimelineRange, delta: Double, edge: Int) {
        guard delta.isFinite else { return }
        let minimum = min(1/max(1,project.fps),original.duration)
        var a = original.start, b = original.end
        if edge == 0 {
            let shift = max(-a,min(max(project.editedDuration,original.end)-b,delta)); a += shift; b += shift
        } else if edge < 0 { a = max(0,min(b-minimum,a+delta)) }
        else { b = min(max(project.editedDuration,original.end),max(a+minimum,b+delta)) }
        var p = project
        if region, let i = p.regions.firstIndex(where:{$0.id == id}) {
            let shift = a-p.regions[i].start
            if edge == 0 {
                p.regions[i].keyframes = p.regions[i].keyframes.map { key in
                    var k = key; k.time = max(0,k.time+shift); return k
                }
            }
            p.regions[i].start = a; p.regions[i].end = b
        } else if !region, let i = p.captions.firstIndex(where:{$0.id == id}) {
            p.captions[i].start = a; p.captions[i].end = b
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
    func editCommand(_ command: String) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            if command == "undo" { text.undoManager?.undo() }
            else if command == "redo" { text.undoManager?.redo() }
            else { _ = NSApp.sendAction(NSSelectorFromString(command == "delete" ? "deleteBackward:" : command+":"),to:text,from:nil) }
            return
        }
        switch command { case "cut":editSelection("cut"); case "copy":editSelection("copy"); case "paste":editSelection("paste"); case "delete":editSelection("delete"); case "selectAll":selectAllClips(); case "undo":undo(); case "redo":redo(); default:break }
    }
    func undo() { focusTimeline(); guard let p = undoStack.popLast() else { return }; redoStack.append(project); restoreHistory(p) }
    func redo() { focusTimeline(); guard let p = redoStack.popLast() else { return }; undoStack.append(project); restoreHistory(p) }
    private func restoreHistory(_ p: Project) {
        pause(); previewReady = false; restoring = true; project = p; restoring = false
        playhead = min(playhead,p.editedDuration); selectedClips.formIntersection(Set(p.clips.map(\.id)))
        selectedClip = selectedClips.first
        selectedLane = max(0,min(selectedLane,laneCount(selectedTrack)-1))
        if !p.regions.contains(where:{$0.id == selectedRegion}) { selectedRegion = p.regions.first?.id }
        if !p.captions.contains(where:{$0.id == selectedCaption}) { selectedCaption = p.captions.first?.id }
        refreshPreview(); scheduleRecovery()
    }
    func schedulePreview() { previewTask?.cancel(); previewTask = Task { try? await Task.sleep(nanoseconds:130_000_000); guard !Task.isCancelled else { return }; refreshPreview() } }
    func refreshPreview() {
        guard loaded else { return }
        refreshWaveform()
        previewTask?.cancel(); previewRevision += 1; let revision = previewRevision
        let p = project; let renderer = renderer
        var spans: [TimelineRange] = []
        if p.maskApplied {
            let times = p.faces.filter(\.selected).flatMap { $0.samples.map(\.time) }.sorted()
            let tolerance = max(0.06,1.5/p.fps)
            for time in times {
                if let last = spans.last, time-tolerance <= last.end { spans[spans.count-1].end = max(last.end,time+tolerance) }
                else { spans.append(TimelineRange(start:time-tolerance,end:time+tolerance)) }
            }
        }
        faceSourceCoverage = spans
        faceCoverage = p.visibleTimeline.flatMap { entry in spans.compactMap { span -> TimelineRange? in
            let a = max(span.start,entry.clip.start), b = min(span.end,entry.clip.end)
            return b > a ? TimelineRange(start:entry.start+a-entry.clip.start,end:entry.start+b-entry.clip.start) : nil
        } }
        let resume = playing; pause(); previewReady = false
        if p.isImage {
            previewTask = Task {
                let image: NSImage? = await Task.detached {
                    guard let source = try? MediaEngine.stillImage(URL(fileURLWithPath:p.sourcePath)) else { return nil }
                    let scale = min(1,1600/max(source.extent.width,source.extent.height)); let small = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    let result = renderer.render(small,project:p,time:0,crop:false)
                    return renderer.context.createCGImage(result,from:result.extent).map { NSImage(cgImage:$0,size:.zero) }
                }.value
                if !Task.isCancelled, revision == previewRevision { stillPreview = image; previewReady = true }
            }
        } else {
            if p.clips.isEmpty { player.replaceCurrentItem(with:nil); return }
            previewTask = Task {
                do {
                    // Preview and export share the same concatenated composition.
                    try p.validate()
                    var previewProject = p; previewProject.export.muted = false
                    let composition: AVMutableComposition
                    if let cachedComposition, cachedClips == p.clips, cachedSource == p.sourcePath { composition = cachedComposition }
                    else {
                        composition = try await MediaEngine.composition(for:previewProject)
                        guard !Task.isCancelled, revision == previewRevision else { return }
                        cachedComposition = composition; cachedClips = p.clips; cachedSource = p.sourcePath
                    }
                    guard !Task.isCancelled, revision == previewRevision else { return }
                    let item = AVPlayerItem(asset:composition)
                    let sourceMapping = p.visibleTimeline
                    item.videoComposition = AVVideoComposition(asset:composition,applyingCIFiltersWithHandler: { request in
                        let sourceTime = mappedSourceTime(sourceMapping,at:request.compositionTime.seconds)
                        let image = renderer.render(request.sourceImage,project:p,time:sourceTime,crop:false,overlayTime:request.compositionTime.seconds)
                        request.finish(with:image,context:renderer.context)
                    })
                    player.replaceCurrentItem(with:item); player.isMuted = p.export.muted; previewReady = true
                    seek(playhead); if resume { playing = true; player.play() }
                } catch { if !Task.isCancelled, revision == previewRevision { status = "미리보기 설정 확인: " + error.localizedDescription } }
            }
        }
    }
    func saveProject() { _ = saveProjectIfPossible() }
    func saveProjectIfPossible() -> Bool {
        focusTimeline(); endTimelineGesture()
        guard loaded, !busy else { return false }
        if let url = projectURL { return save(to:url) }
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath:fileName).deletingPathExtension().lastPathComponent + ".veilproject"; panel.allowedContentTypes = [UTType(filenameExtension:"veilproject") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return save(to:url)
    }
    @discardableResult func save(to url: URL) -> Bool { do {
        guard url.standardizedFileURL.resolvingSymlinksInPath().path != URL(fileURLWithPath:project.sourcePath).standardizedFileURL.resolvingSymlinksInPath().path else { throw StudioError.message("원본 파일에는 프로젝트를 덮어쓸 수 없습니다.") }
        var cleaned = project; let repaired = try cleaned.repairFaceBounds(); try cleaned.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; try encoder.encode(cleaned).write(to:url,options:.atomic)
        if repaired > 0 { project = cleaned }
        projectURL = url; savedProject = project
        status = repaired > 0 ? "프로젝트 저장 완료 · 가장자리 얼굴 좌표 \(repaired)개 보정" : "프로젝트 저장 완료"
        return true
    } catch { self.error = error.localizedDescription; return false } }
    func scheduleRecovery() {
        guard automaticRecoveryEnabled else { return }
        recoveryTask?.cancel(); recoveryTask = Task {
            try? await Task.sleep(nanoseconds:1_000_000_000); guard !Task.isCancelled, loaded else { return }
            do { let url = recoveryURL; try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try JSONEncoder().encode(project).write(to:url,options:.atomic) } catch { status = "자동 복구 저장 실패 · 프로젝트를 직접 저장해 주세요" }
        }
    }
    func openProject(recovery: Bool = false) {
        guard !busy else { return }
        var url: URL?
        if recovery { url = recoveryURL } else { let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension:"veilproject") ?? .json]; if panel.runModal() == .OK { url = panel.url } }
        guard let url else { return }
        do {
            var p = try JSONDecoder().decode(Project.self,from:Data(contentsOf:url)); let repaired = try p.repairFaceBounds(); let timingRepairs = p.repairEditableTimes(); try p.validate()
            let info = try URL(fileURLWithPath:p.sourcePath).resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            guard Int64(info.fileSize ?? -1) == p.fileSize, info.contentModificationDate == p.modified else { throw StudioError.message("프로젝트의 원본이 없거나 변경되었습니다. 원래 위치에 원본을 복구한 뒤 다시 열어 주세요.") }
            guard confirmLeaving() else { return }
            pause(); setProject(p); projectURL = recovery ? nil : url; if !recovery { savedProject = project }; status = (recovery ? "자동 저장한 작업 복구 완료" : "프로젝트 열기 완료") + (repaired > 0 ? " · 가장자리 좌표 \(repaired)개 보정" : "") + (timingRepairs > 0 ? " · 뒤집힌 자막 \(timingRepairs)개를 최소 1프레임으로 보정: 시간 재확인 필요" : "")
        } catch { self.error = error.localizedDescription }
    }
    func importSRT() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension:"srt") ?? .plainText,.plainText]
        if panel.runModal() == .OK, let url = panel.url { do {
            let captions = Subtitles.parse(try String(contentsOf:url,encoding:.utf8)); guard !captions.isEmpty else { throw StudioError.message("유효한 UTF-8 SRT 자막이 없습니다.") }; project.captions = captions; project.separateOverlappingOverlays(); tab = .captions
        } catch { self.error = error.localizedDescription } }
    }
    func exportSRT() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "자막.srt"
        if panel.runModal() == .OK, let url = panel.url { do { try Subtitles.srt(project.outputCaptions()).write(to:url,atomically:true,encoding:.utf8); status = "컷 편집을 반영한 SRT 저장 완료" } catch { self.error = error.localizedDescription } }
    }
    func exportMedia() {
        do { try verifySource() } catch { self.error = error.localizedDescription; return }
        let ext = project.isImage ? project.export.resolvedImageFormat.rawValue : project.export.fileExtension
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension:ext)!]; panel.nameFieldStringValue = URL(fileURLWithPath:fileName).deletingPathExtension().lastPathComponent + "_편집." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL.resolvingSymlinksInPath().path != URL(fileURLWithPath:project.sourcePath).standardizedFileURL.resolvingSymlinksInPath().path else { error = "원본을 보호하기 위해 다른 파일 이름으로 저장해 주세요."; return }
        exportSheet = false; begin("내보내기 준비 중"); let p = project; let token = cancellation
        Task { do {
            try await MediaEngine.export(p,to:url,cancellation:token) { [weak self = self] v,s in Task { @MainActor in self?.progress = v; self?.status = s } }
            lastExport = url; status = "내보내기 완료 · \(url.lastPathComponent)"; finish()
        } catch { fail(error) } }
    }
}
enum EditorTab: String, CaseIterable { case faces = "얼굴 마스킹", regions = "영역 마스킹", captions = "자막 편집"; var icon: String { switch self { case .faces:return "person.crop.rectangle"; case .regions:return "viewfinder"; case .captions:return "captions.bubble" } } }

enum EditTrack: String, CaseIterable { case video = "영상", audio = "오디오 · 영상 연결", faces = "얼굴 · 영상 연결", regions = "영역 마스크", captions = "자막"
    var linkedToVideo: Bool { self == .video || self == .faces || self == .audio }
}
extension EditorStore {
    func selectOverlay(_ id: UUID, region: Bool) {
        focusTimeline(); wholeOverlayTrack = false; selectedTrack = region ? .regions : .captions
        if region { selectedRegion = id; selectedLane = project.regions.first(where:{$0.id == id})?.lane ?? 0; tab = .regions } else { selectedCaption = id; selectedLane = project.captions.first(where:{$0.id == id})?.lane ?? 0; tab = .captions }
    }
    func splitOverlay() {
        if wholeOverlayTrack {
            wholeOverlayTrack = false
            let ids = selectedTrack == .captions ? project.captions.filter { ($0.lane ?? 0) == selectedLane }.map(\.id) : project.regions.filter { ($0.lane ?? 0) == selectedLane }.map(\.id)
            beginTimelineGesture()
            for id in ids { if selectedTrack == .captions { selectedCaption = id } else { selectedRegion = id }; splitOverlay() }
            endTimelineGesture(); return
        }
        let t = playhead
        var p = project
        if selectedTrack == .captions, let i = p.captions.firstIndex(where:{$0.id == selectedCaption}), t > p.captions[i].start, t < p.captions[i].end {
            var right = p.captions[i]; right.id = UUID(); right.start = t; p.captions[i].end = t; p.captions.insert(right,at:i+1); selectedCaption = right.id
        } else if selectedTrack == .regions, let i = p.regions.firstIndex(where:{$0.id == selectedRegion}), t > p.regions[i].start, t < p.regions[i].end {
            var right = p.regions[i]; right.id = UUID(); right.start = t; p.regions[i].end = t; p.regions.insert(right,at:i+1); selectedRegion = right.id
        } else { status = "선택한 블록 안쪽에 재생 헤드를 놓으세요"; return }
        project = p; status = "선택한 트랙만 분할했습니다"
    }
    func editSelection(_ action: String) {
        guard canEditTimeline else { return }
        if selectedTrack.linkedToVideo {
            switch action { case "copy":copyClips(); case "cut":cutClips(); case "paste":pasteClips(); case "delete":deleteClip(); default:break }; return
        }
        var p = project
        if action == "copy" || action == "cut" {
            if selectedTrack == .captions { clipboardCaptions = p.captions.filter { (wholeOverlayTrack && ($0.lane ?? 0) == selectedLane) || $0.id == selectedCaption } }
            else { clipboardRegions = p.regions.filter { (wholeOverlayTrack && ($0.lane ?? 0) == selectedLane) || $0.id == selectedRegion } }
            objectWillChange.send()
        }
        if action == "delete" || action == "cut" {
            if selectedTrack == .captions { p.captions.removeAll { (wholeOverlayTrack && ($0.lane ?? 0) == selectedLane) || $0.id == selectedCaption }; selectedCaption = nil }
            else { p.regions.removeAll { (wholeOverlayTrack && ($0.lane ?? 0) == selectedLane) || $0.id == selectedRegion }; selectedRegion = nil }
        }
        if action == "paste" {
            if selectedTrack == .captions, let start = clipboardCaptions.map(\.start).min() {
                for original in clipboardCaptions { var c = original; c.id = UUID(); c.lane = selectedLane; c.start += playhead-start; c.end += playhead-start; p.captions.append(c); selectedCaption = c.id }
            }
            if selectedTrack == .regions, let start = clipboardRegions.map(\.start).min() {
                for original in clipboardRegions { var r = original; r.id = UUID(); r.lane = selectedLane; let shift = playhead-start; r.start += shift; r.end += shift; r.keyframes = r.keyframes.map { k in var v = k; v.time = max(0,v.time+shift); return v }; p.regions.append(r); selectedRegion = r.id }
            }
            wholeOverlayTrack = false
        }
        p.separateOverlappingOverlays(); project = p; synchronizeSelectedLane()
    }
}

extension EditorStore {
    func laneCount(_ kind: EditTrack) -> Int {
        switch kind {
        case .video: return max(project.videoLaneCount ?? 1,(project.clips.map {$0.lane ?? 0}.max() ?? 0)+1)
        case .regions: return max(project.regionLaneCount ?? 1,(project.regions.map {$0.lane ?? 0}.max() ?? 0)+1)
        case .captions: return max(project.captionLaneCount ?? 1,(project.captions.map {$0.lane ?? 0}.max() ?? 0)+1)
        case .faces, .audio: return laneCount(.video)
        }
    }
    var timelineRows: [TimelineRow] {
        (0..<laneCount(.video)).reversed().flatMap { lane in [.video,.audio,.faces].map { TimelineRow(kind:$0,lane:lane) } } +
        [EditTrack.regions,.captions].flatMap { kind in (0..<laneCount(kind)).reversed().map { TimelineRow(kind:kind,lane:$0) } }
    }
    func addLane(_ kind: EditTrack) {
        var p = project; let count = laneCount(kind)
        guard count < 64 else { status = "종류별 트랙은 최대 64개입니다"; return }
        switch kind {
        case .video: p.enableVideoLanes(); p.videoLaneCount = count+1
        case .regions: p.regionLaneCount = count+1
        case .captions: p.captionLaneCount = count+1
        case .faces, .audio: return
        }
        project = p; selectLane(kind,lane:count)
    }
    func moveItem(_ id: UUID, to kind: EditTrack, lane: Int, at time: Double? = nil) {
        var p = project
        if kind.linkedToVideo, let i = p.clips.firstIndex(where:{$0.id == id}) {
            p.enableVideoLanes(); p.videoLaneCount = max(2,laneCount(.video),lane+1)
            let at = max(0,time ?? p.clips[i].position ?? 0), end = at+p.clips[i].duration
            guard !p.timeline.contains(where:{$0.id != id && ($0.clip.lane ?? 0) == lane && $0.start < end && $0.end > at}) else { status = "같은 영상 트랙의 컷과 겹칩니다. 빈 트랙으로 이동하세요."; return }
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
        } else { return }
        p.separateOverlappingOverlays(); project = p; selectedTrack = kind; selectedLane = lane; synchronizeSelectedLane(); focusTimeline()
    }
}

extension EditorStore {
    func selectLane(_ kind: EditTrack, lane: Int) {
        focusTimeline(); wholeOverlayTrack = false; selectedTrack = kind; selectedLane = lane
        if kind.linkedToVideo { selectedClip = nil; selectedClips = [] }
        if kind == .regions { selectedRegion = nil; tab = .regions }
        if kind == .captions { selectedCaption = nil; tab = .captions }
        if (kind == .faces || kind == .audio), let top = project.timeline.first(where:{($0.clip.lane ?? 0) == lane && playhead >= $0.start && playhead < $0.end}) {
            selectedClip = top.id; selectedClips = [top.id]; selectedLane = top.clip.lane ?? 0
        }
    }
}

extension EditorStore {
    func synchronizeSelectedLane() {
        if selectedTrack == .regions, let r = project.regions.first(where:{$0.id == selectedRegion}) { selectedLane = r.lane ?? 0 }
        if selectedTrack == .captions, let c = project.captions.first(where:{$0.id == selectedCaption}) { selectedLane = c.lane ?? 0 }
    }
}


extension EditorStore {
    func refreshWaveform() {
        guard loaded, !project.isImage else { return }
        let ranges = project.analysisRanges
        guard waveform?.covers(ranges) != true, waveformRequested != ranges else { return }
        waveformCancellation?.cancel(); waveformTask?.cancel()
        waveformRequested = ranges; let token = Cancellation(); waveformCancellation = token
        let session = sessionID, source = URL(fileURLWithPath:project.sourcePath), duration = project.duration
        waveformStatus = "파형 생성 중…"
        waveformTask = Task { [weak self] in
            do {
                let data = try await AudioWaveform.read(source:source,duration:duration,ranges:ranges,cancellation:token)
                guard let self, !Task.isCancelled, self.sessionID == session, !token.cancelled else { return }
                self.waveform = data; self.waveformRevision += 1
                self.waveformStatus = data.hasAudio ? "" : "오디오 없음"
            } catch {
                guard let self, !Task.isCancelled, self.sessionID == session, !token.cancelled else { return }
                self.waveformStatus = "파형을 읽지 못했습니다"
            }
        }
    }
}

extension EditorStore {
    func closeGap(_ range: TimelineRange,lane: Int) {
        guard canEditTimeline, project.gaps(in:lane).contains(range) else { return }
        var p = project; p.enableVideoLanes()
        for i in p.clips.indices where (p.clips[i].lane ?? 0) == lane && (p.clips[i].position ?? 0) >= range.end-0.000001 { p.clips[i].position = max(0,(p.clips[i].position ?? 0)-range.duration) }
        p.exportRange = nil; commitTimeline(p,seekTo:range.start)
        status = "빈 구간 삭제 · 영상·오디오·얼굴 마스크 세트를 붙였습니다"
    }
}
