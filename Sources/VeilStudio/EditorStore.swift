import SwiftUI
import AVKit
import UniformTypeIdentifiers

enum EditorTab: String, CaseIterable {
    case media = "미디어", faces = "얼굴 마스킹", regions = "영역 마스킹", captions = "자막 편집", titles = "타이틀", queue = "작업 목록"
    var icon: String {
        switch self {
        case .media: return "photo.on.rectangle.angled"; case .faces: return "person.crop.rectangle"; case .regions: return "viewfinder"
        case .captions: return "captions.bubble"; case .titles: return "textformat"; case .queue: return "list.bullet.rectangle"
        }
    }
}
enum EditTool: String { case select = "선택", blade = "자르기" }
enum InspectorTab: String, CaseIterable { case clip = "클립", mask = "마스크", output = "출력" }

@MainActor final class EditorStore: ObservableObject {
    @Published var project = Project() {
        didSet {
            guard !restoring, project != oldValue else { return }
            if timelineGestureStart == nil, !oldValue.media.isEmpty {
                let now = Date()
                // Continuous edits (sliders, typing) with the same key form one undo step.
                let coalesced = pendingCoalesce != nil && pendingCoalesce == lastCoalesce && now.timeIntervalSince(lastCoalesceTime) < 1.2
                if !coalesced { undoStack.append(oldValue); if undoStack.count > 60 { undoStack.removeFirst() }; redoStack = [] }
                lastCoalesce = pendingCoalesce; lastCoalesceTime = now
            }
            pendingCoalesce = nil
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
    @Published var inspector = InspectorTab.clip
    @Published var drawMode = false
    @Published var tool = EditTool.select
    @Published var snapping = true
    @Published var selectedTrack = EditTrack.video
    @Published var selectedLane = 0
    @Published var selectedCaption: UUID?
    @Published var selectedRegion: UUID?
    @Published var selectedTitle: UUID?
    @Published var selectedAudioClip: UUID?
    @Published var selectedMarker: UUID?
    @Published var selectedClip: UUID?
    @Published var selectedClips = Set<UUID>()
    @Published var selectedMedia: UUID?
    @Published var wholeOverlayTrack = false
    @Published var clipboardClips: [Clip] = []
    var clipboardCaptions: [Caption] = []
    var clipboardRegions: [ManualRegion] = []
    var clipboardTitles: [TitleItem] = []
    var clipboardAudio: [AudioClip] = []
    @Published var editingText = false
    @Published var previewReady = false
    @Published var waveforms: [UUID:AudioWaveform] = [:]
    @Published var waveformStatus = ""
    @Published var waveformRevision = 0
    var waveformTasks: [UUID:Task<Void,Never>] = [:]
    var waveformRequested: [UUID:[TimelineRange]] = [:]
    @Published var faceCoverage: [UUID:[TimelineRange]] = [:]
    @Published var offlineMedia = Set<UUID>()
    @Published var changedMedia = Set<UUID>()
    @Published var exportSheet = false
    @Published var helpSheet = false
    @Published var settingsSheet = false
    @Published var autoCaptions = true
    @Published var speechOptions = SpeechOptions.load() { didSet { if speechOptions != oldValue { speechOptions.save() } } }
    @Published var language = UserDefaults.standard.string(forKey:"speechLanguage") ?? "ko-KR" { didSet { UserDefaults.standard.set(language,forKey:"speechLanguage") } }
    @Published var analysisMode = FaceAnalysisMode(rawValue:UserDefaults.standard.string(forKey:"faceAnalysisMode") ?? "") ?? .precise { didSet { UserDefaults.standard.set(analysisMode.rawValue,forKey:"faceAnalysisMode") } }
    @Published var speechNotes: [String] = []
    @Published var lastExport: URL?
    @Published var projectURL: URL?
    @Published var undoStack: [Project] = []
    @Published var redoStack: [Project] = []
    @Published var queueRunning = false
    @Published var queueCurrent: UUID?
    @Published var thumbnailRevision = 0
    let thumbnails = ThumbnailCache()
    let viewport = TimelineViewport()
    var automaticRecoveryEnabled = true
    var cancellation = Cancellation()
    var restoring = false
    private var observer: Any?
    var previewTask: Task<Void,Never>?
    private var recoveryTask: Task<Void,Never>?
    private var shuttleTask: Task<Void,Never>?
    let renderer = MaskRenderer()
    let stills = StillCache()
    var built: BuiltTimeline?
    var previewRevision = 0
    var timelineGestureStart: Project?
    var pendingCoalesce: String?
    private var lastCoalesce: String?
    private var lastCoalesceTime = Date.distantPast
    private let activity = ActivityToken()
    private(set) var sessionID = UUID()
    @Published var savedProject: Project?
    @Published var backgroundTasks: [BackgroundTask] = []
    @Published var timelineDetached = false
    @Published var facesDetached = false
    var activityCount = 0
    let activityToken = ActivityToken()
    @Published var shuttleRate = 0.0

    var overlayTime: Double { project.overlaysOnTimeline == true ? playhead : sourcePlayhead }
    var canEditTimeline: Bool { loaded && !project.isImage && !busy }
    var canDeleteClips: Bool { canEditTimeline && project.clips.contains { selectedClips.contains($0.id) && ($0.lane ?? 0) == selectedLane } }
    var sourcePlayhead: Double { project.isImage ? 0 : project.sourceTime(for:playhead) }
    var hasUnsavedChanges: Bool { loaded && project != savedProject }
    var loaded: Bool { !project.media.isEmpty && !project.sourcePath.isEmpty }
    var fileName: String {
        if let projectURL { return projectURL.deletingPathExtension().lastPathComponent }
        guard loaded else { return "새 프로젝트" }
        return project.media.count > 1 ? "\(project.sourcePath.isEmpty ? "프로젝트" : URL(fileURLWithPath:project.sourcePath).deletingPathExtension().lastPathComponent) 외 \(project.media.count-1)개" : URL(fileURLWithPath:project.sourcePath).lastPathComponent
    }
    var recoveryURL: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VeilStudio/Recovery.veilproject") }
    var selectionAvailable: Bool {
        switch selectedTrack {
        case .video, .audio, .faces: return canDeleteClips
        case .regions: return project.regions.contains { $0.id == selectedRegion && ($0.lane ?? 0) == selectedLane }
        case .captions: return project.captions.contains { $0.id == selectedCaption && ($0.lane ?? 0) == selectedLane }
        case .titles: return project.titles.contains { $0.id == selectedTitle && ($0.lane ?? 0) == selectedLane }
        case .music: return project.audioClips.contains { $0.id == selectedAudioClip && $0.lane == selectedLane }
        }
    }
    var pasteAvailable: Bool {
        switch selectedTrack {
        case .video, .audio, .faces: return !clipboardClips.isEmpty
        case .regions: return !clipboardRegions.isEmpty
        case .captions: return !clipboardCaptions.isEmpty
        case .titles: return !clipboardTitles.isEmpty
        case .music: return !clipboardAudio.isEmpty
        }
    }
    // The media whose faces the face panel shows: explicit choice, then the clip being edited.
    var faceSource: MediaSource? {
        if let id = selectedMedia, let m = project.media.first(where:{ $0.id == id }), m.isVisual { return m }
        if let id = selectedClip, let clip = project.clips.first(where:{ $0.id == id }) { return project.source(clip.source) }
        if let entry = project.entry(at:playhead) { return project.source(entry.clip.source) }
        return project.media.first(where:\.isVisual)
    }

    // Resolve identity on every access; old SwiftUI controls can outlive their project.
    func itemBinding<Item: Identifiable>(_ path: WritableKeyPath<Project,[Item]>, item: Item, coalesce: String? = nil) -> Binding<Item> {
        let session = sessionID
        return Binding(get: { [weak self] in
            guard let self, self.sessionID == session else { return item }
            return self.project[keyPath:path].first { $0.id == item.id } ?? item
        }, set: { [weak self] value in
            guard let self, self.sessionID == session,
                  let index = self.project[keyPath:path].firstIndex(where: { $0.id == item.id }) else { return }
            self.pendingCoalesce = coalesce.map { "\($0)-\(item.id)" }
            self.project[keyPath:path][index] = value
        })
    }
    // Binding for inspector controls; a drag of one control becomes one undo step.
    func projectBinding<T: Equatable>(_ path: WritableKeyPath<Project,T>, coalesce key: String) -> Binding<T> {
        let session = sessionID
        return Binding(get: { [weak self] in self?.project[keyPath:path] ?? Project()[keyPath:path] },
                       set: { [weak self] value in
            guard let self, self.sessionID == session, self.project[keyPath:path] != value else { return }
            self.pendingCoalesce = key; self.project[keyPath:path] = value
        })
    }
    enum LeaveChoice { case save, discard, cancel }
    func resolveLeave(_ choice: LeaveChoice, save: () -> Bool) -> Bool {
        switch choice { case .save: return save(); case .discard: return true; case .cancel: return false }
    }
    func confirmLeaving() -> Bool {
        focusTimeline(); endTimelineGesture(); pause()
        guard !busy else { error = "진행 중인 작업을 취소하거나 완료한 후 다시 시도해 주세요."; return false }
        if !backgroundTasks.isEmpty {
            let alert = NSAlert(); alert.messageText = "진행 중인 작업 \(backgroundTasks.count)개를 취소할까요?"
            alert.informativeText = backgroundTasks.map(\.title).prefix(4).joined(separator:"\n") + "\n계속하면 이 작업들은 취소되고 결과가 저장되지 않습니다."
            alert.addButton(withTitle:"작업 취소하고 계속"); alert.addButton(withTitle:"돌아가기")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            cancelAllBackground()
        }
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert(); alert.messageText = "변경한 프로젝트를 저장하시겠습니까?"
        alert.informativeText = "저장하지 않고 계속하면 현재 변경 사항을 잃을 수 있습니다."
        alert.addButton(withTitle:"저장"); alert.addButton(withTitle:"저장하지 않음"); alert.addButton(withTitle:"취소")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        let response = alert.runModal()
        return resolveLeave(response == .alertFirstButtonReturn ? .save : response == .alertSecondButtonReturn ? .discard : .cancel,save:saveProjectIfPossible)
    }
    init() {
        observer = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.05,preferredTimescale:600),queue:.main) { [weak self] t in
            Task { @MainActor in
                guard let self, self.previewReady, t.seconds.isFinite else { return }
                self.playhead = min(self.project.editedDuration,max(0,t.seconds))
                if self.playing && t.seconds >= self.project.editedDuration-0.015 { self.pause() }
            }
        }
    }
    func setProject(_ p: Project) {
        cancelAllBackground(); backgroundTasks = []; activityCount = 0; activityToken.end(); queueRunning = false; queueCurrent = nil
        pause(); previewTask?.cancel(); recoveryTask?.cancel(); previewRevision += 1
        previewReady = false; player.currentItem?.cancelPendingSeeks(); player.replaceCurrentItem(with:nil)
        built = nil; stillPreview = nil
        for task in waveformTasks.values { task.cancel() }; waveformTasks = [:]; waveforms = [:]; waveformRequested = [:]; waveformStatus = ""
        thumbnails.reset(); faceCoverage = [:]
        sessionID = UUID(); savedProject = nil; projectURL = nil; timelineGestureStart = nil
        clipboardCaptions = []; clipboardRegions = []; clipboardTitles = []; clipboardAudio = []; wholeOverlayTrack = false; drawMode = false; tool = .select
        var p = p; p.repairEditableTimes(); p.migrateOverlayTimeline(); p.separateOverlappingOverlays(); p.sanitizeQueue(); selectedTrack = .video; selectedLane = 0; selectedCaption = nil; selectedTitle = nil; selectedAudioClip = nil; selectedMarker = nil
        speechNotes = []; restoring = true; project = p; restoring = false; undoStack = []; redoStack = []; playhead = 0; selectedClip = p.clips.first?.id; selectedRegion = nil; lastExport = nil
        selectedClips = Set(p.clips.prefix(1).map(\.id)); clipboardClips = []; selectedMedia = nil
        refreshMediaStatus()
        previewReady = false; player.replaceCurrentItem(with:nil)
        refreshPreview(); scheduleRecovery()
    }
    func begin(_ message: String) { busy = true; progress = 0; status = message; cancellation = Cancellation(); pause(); activity.begin(message); Log.info("begin: \(message)") }
    func finish() { busy = false; activity.end() }
    func fail(_ e: Error) {
        busy = false; activity.end()
        if e is CancellationError { status = "작업이 취소되었습니다" }
        else { error = e.localizedDescription; status = "작업을 완료하지 못했습니다"; Log.error(e.localizedDescription) }
    }
    func cancel() { cancellation.cancel(); status = "작업 취소 중…" }
    func report(_ message: String) { status = message }

    // MARK: Source checks
    func refreshMediaStatus() {
        var offline = Set<UUID>(), changed = Set<UUID>()
        for m in project.media {
            guard let info = try? URL(fileURLWithPath:m.path).resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) else { offline.insert(m.id); continue }
            if Int64(info.fileSize ?? -1) != m.fileSize || (m.modified != nil && info.contentModificationDate != m.modified) { changed.insert(m.id) }
        }
        offlineMedia = offline; changedMedia = changed
    }
    func verifySource(_ id: UUID? = nil) throws {
        guard let m = project.source(id) else { throw StudioError.message("미디어가 없습니다.") }
        let url = URL(fileURLWithPath:m.path)
        guard let info = try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) else { throw StudioError.message("원본 파일을 찾을 수 없습니다: \(m.name)\n미디어 패널에서 ‘다시 연결’을 눌러 파일 위치를 지정하세요.") }
        guard Int64(info.fileSize ?? -1) == m.fileSize, info.contentModificationDate == m.modified else { throw StudioError.message("원본 파일이 변경되었습니다: \(m.name)\n미디어 패널에서 다시 연결한 뒤 얼굴 분석을 다시 하세요.") }
    }
    func verifyUsedSources() throws {
        let used = Set(project.clips.compactMap { project.sourceID(of:$0) } + project.audioClips.map(\.source))
        for id in used { try verifySource(id) }
    }

    // MARK: Playback
    func seek(_ time: Double) {
        guard time.isFinite else { return }
        playhead = min(project.editedDuration,max(0,time))
        if previewReady { player.seek(to:CMTime(seconds:playhead,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero) }
    }
    func seekSource(_ time: Double, source: UUID? = nil) {
        if let t = project.timelineTime(forSource:time,preferredClip:selectedClip,source:source) { seek(t) }
        else { status = "이 원본 시점은 현재 편집 타임라인에 포함되어 있지 않습니다" }
    }
    func pause() { player.pause(); playing = false; shuttleTask?.cancel(); shuttleTask = nil; shuttleRate = 0 }
    func togglePlay() {
        guard canEditTimeline, previewReady, project.editedDuration > 0 else { return }
        if playing { pause() } else { if playhead >= project.editedDuration-0.015 { seek(0) }; playing = true; shuttleRate = 1; player.rate = 1 }
    }
    // J/K/L: L speeds up forward play, J steps backwards faster each press, K stops.
    func shuttle(_ direction: Int) {
        guard canEditTimeline, previewReady, project.editedDuration > 0 else { return }
        if direction == 0 { pause(); return }
        if direction > 0 {
            shuttleTask?.cancel(); shuttleTask = nil
            let next = shuttleRate > 0 ? min(8,shuttleRate*2) : 1
            if playhead >= project.editedDuration-0.015 { seek(0) }
            shuttleRate = next; playing = true; player.rate = Float(next)
        } else {
            player.pause(); playing = true
            shuttleRate = shuttleRate < 0 ? max(-8,shuttleRate*2) : -1
            guard shuttleTask == nil else { return }
            shuttleTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let next = self.playhead+self.shuttleRate*0.1
                    self.seek(next)
                    if next <= 0 { self.pause(); return }
                    try? await Task.sleep(nanoseconds:100_000_000)
                }
            }
        }
    }
    func step(frames: Int) { pause(); seek(playhead+Double(frames)/max(1,project.fps)) }
    func jumpEdit(_ direction: Int) {
        pause()
        let points = project.editPoints
        if direction > 0 { seek(points.first { $0 > playhead+0.001 } ?? project.editedDuration) }
        else { seek(points.last { $0 < playhead-0.001 } ?? 0) }
    }
    func focusTimeline() { NSApplication.shared.keyWindow?.makeFirstResponder(nil); editingText = false }

    // MARK: Undo
    func beginTimelineGesture() { if timelineGestureStart == nil { timelineGestureStart = project } }
    func endTimelineGesture() {
        if let initial = timelineGestureStart, initial != project { undoStack.append(initial); if undoStack.count > 60 { undoStack.removeFirst() }; redoStack = [] }
        project.separateOverlappingOverlays(); synchronizeSelectedLane(); timelineGestureStart = nil; schedulePreview(); scheduleRecovery()
    }
    func commitTimeline(_ p: Project, seekTo: Double? = nil) {
        pause(); project = p
        selectedClips.formIntersection(Set(p.clips.map(\.id)))
        if !p.clips.contains(where:{$0.id == selectedClip}) { selectedClip = p.clips.first?.id }
        playhead = min(p.editedDuration,max(0,seekTo ?? playhead))
    }
    func undo() { focusTimeline(); guard let p = undoStack.popLast() else { return }; redoStack.append(project); restoreHistory(p) }
    func redo() { focusTimeline(); guard let p = redoStack.popLast() else { return }; undoStack.append(project); restoreHistory(p) }
    private func restoreHistory(_ p: Project) {
        pause(); restoring = true; project = p; restoring = false; lastCoalesce = nil
        playhead = min(playhead,p.editedDuration); selectedClips.formIntersection(Set(p.clips.map(\.id)))
        selectedClip = selectedClips.first
        selectedLane = max(0,min(selectedLane,laneCount(selectedTrack)-1))
        if !p.regions.contains(where:{$0.id == selectedRegion}) { selectedRegion = p.regions.first?.id }
        if !p.captions.contains(where:{$0.id == selectedCaption}) { selectedCaption = p.captions.first?.id }
        if !p.titles.contains(where:{$0.id == selectedTitle}) { selectedTitle = nil }
        if !p.audioClips.contains(where:{$0.id == selectedAudioClip}) { selectedAudioClip = nil }
        refreshPreview(); scheduleRecovery()
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

    // MARK: Preview
    func schedulePreview() { previewTask?.cancel(); previewTask = Task { try? await Task.sleep(nanoseconds:130_000_000); guard !Task.isCancelled else { return }; refreshPreview() } }
    func refreshPreview() {
        guard loaded else { return }
        refreshWaveforms(); refreshFaceCoverage()
        previewTask?.cancel(); previewRevision += 1; let revision = previewRevision
        let p = project; let renderer = renderer
        if p.isImage {
            previewReady = false
            previewTask = Task {
                let image: NSImage? = await Task.detached {
                    guard let source = try? MediaEngine.stillImage(URL(fileURLWithPath:p.sourcePath)) else { return nil }
                    let scale = min(1,1600/max(source.extent.width,source.extent.height)); let small = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    let result = renderer.render(small,project:p,time:0,crop:false)
                    return renderer.context.createCGImage(result,from:result.extent).map { NSImage(cgImage:$0,size:.zero) }
                }.value
                if !Task.isCancelled, revision == previewRevision { stillPreview = image; previewReady = true }
            }
            return
        }
        guard p.editedDuration > 0 else { player.replaceCurrentItem(with:nil); built = nil; previewReady = false; return }
        let resume = playing
        previewTask = Task {
            do {
                var preview = p; preview.export.muted = false
                let key = CompositionKey(preview)
                let timeline: BuiltTimeline
                let reuse = built != nil && built?.key == key && player.currentItem != nil
                if let built, reuse { timeline = built }
                else {
                    if resume { pause() }; previewReady = false
                    timeline = try await CompositionBuilder.buildTimeline(preview,muted:false,allowMissing:true)
                    guard !Task.isCancelled, revision == previewRevision else { return }
                    built = timeline
                }
                let (video,_) = CompositionBuilder.videoComposition(timeline,project:preview,purpose:.preview,renderer:renderer,cancellation:nil,stills:stills,previewEdge:1600)
                let mix = CompositionBuilder.audioMix(timeline,project:preview)
                guard !Task.isCancelled, revision == previewRevision else { return }
                if reuse, let item = player.currentItem {
                    // Same cuts: swap render instructions in place, keeping position and playback.
                    item.videoComposition = video; item.audioMix = mix
                    if !playing { player.seek(to:CMTime(seconds:playhead,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero) { _ in } }
                } else {
                    let item = AVPlayerItem(asset:timeline.composition)
                    item.videoComposition = video; item.audioMix = mix; item.audioTimePitchAlgorithm = .spectral
                    player.replaceCurrentItem(with:item); player.isMuted = p.export.muted; previewReady = true
                    seek(playhead); if resume { playing = true; player.play() }
                }
                player.isMuted = p.export.muted; previewReady = true
            } catch { if !Task.isCancelled, revision == previewRevision { status = "미리보기 준비 확인: " + error.localizedDescription; Log.error("preview: \(error.localizedDescription)") } }
        }
    }
    func refreshFaceCoverage() {
        var result: [UUID:[TimelineRange]] = [:]
        for m in project.media where m.maskApplied {
            let tolerance = max(0.06,1.5/max(1,m.fps))
            var spans: [TimelineRange] = []
            for face in m.faces where face.selected {
                for s in face.samples { spans.append(TimelineRange(start:s.time-tolerance,end:s.time+tolerance)) }
            }
            result[m.id] = TimelineRange.merged(spans)
        }
        if result != faceCoverage { faceCoverage = result }
    }

    // MARK: Project files
    func saveProject() { _ = saveProjectIfPossible() }
    func saveProjectAs() {
        let previous = projectURL; projectURL = nil
        if !saveProjectIfPossible() { projectURL = previous }
    }
    func saveProjectIfPossible() -> Bool {
        focusTimeline(); endTimelineGesture()
        guard loaded, !busy else { return false }
        if let url = projectURL { return save(to:url) }
        let panel = NSSavePanel(); panel.nameFieldStringValue = fileName.replacingOccurrences(of:"/",with:"-") + ".veilproject"; panel.allowedContentTypes = [UTType(filenameExtension:"veilproject") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return save(to:url)
    }
    @discardableResult func save(to url: URL) -> Bool { do {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !project.media.contains(where:{ URL(fileURLWithPath:$0.path).standardizedFileURL.resolvingSymlinksInPath().path == target }) else { throw StudioError.message("원본 미디어 파일에는 프로젝트를 덮어쓸 수 없습니다.") }
        var cleaned = project; let repaired = try cleaned.repairFaceBounds(); try cleaned.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; try encoder.encode(cleaned).write(to:url,options:.atomic)
        if repaired > 0 { project = cleaned }
        projectURL = url; savedProject = project
        status = repaired > 0 ? "프로젝트 저장 완료 · 가장자리 얼굴 좌표 \(repaired)개 보정" : "프로젝트 저장 완료"
        Log.info("saved project")
        return true
    } catch { self.error = error.localizedDescription; Log.error("save: \(error.localizedDescription)"); return false } }
    func scheduleRecovery() {
        guard automaticRecoveryEnabled else { return }
        recoveryTask?.cancel(); recoveryTask = Task {
            try? await Task.sleep(nanoseconds:1_500_000_000); guard !Task.isCancelled, loaded else { return }
            let snapshot = project, url = recoveryURL
            do { try await RecoveryWriter.shared.write(snapshot,to:url) } catch { status = "자동 복구 저장 실패 · 프로젝트를 직접 저장해 주세요"; Log.error("autosave: \(error.localizedDescription)") }
        }
    }
    func openProject(recovery: Bool = false, url preset: URL? = nil) {
        guard !busy else { return }
        var url = preset
        if recovery { url = recoveryURL } else if url == nil { let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension:"veilproject") ?? .json]; if panel.runModal() == .OK { url = panel.url } }
        guard let url else { return }
        do {
            var p = try JSONDecoder().decode(Project.self,from:Data(contentsOf:url)); let repaired = try p.repairFaceBounds(); let timingRepairs = p.repairEditableTimes(); try p.validate()
            guard confirmLeaving() else { return }
            pause(); setProject(p); projectURL = recovery ? nil : url; if !recovery { savedProject = project }
            var notes: [String] = []
            if repaired > 0 { notes.append("가장자리 좌표 \(repaired)개 보정") }
            if timingRepairs > 0 { notes.append("뒤집힌 자막 \(timingRepairs)개를 최소 1프레임으로 보정: 시간 재확인 필요") }
            if !offlineMedia.isEmpty { notes.append("찾을 수 없는 원본 \(offlineMedia.count)개 · 미디어 패널에서 다시 연결하세요") }
            if !changedMedia.isEmpty { notes.append("변경된 원본 \(changedMedia.count)개 · 얼굴 분석을 다시 확인하세요") }
            status = (recovery ? "자동 저장한 작업 복구 완료" : "프로젝트 열기 완료") + (notes.isEmpty ? "" : " · " + notes.joined(separator:" · "))
            if !offlineMedia.isEmpty { tab = .media }
            Log.info("opened project (\(p.media.count) media)")
        } catch { self.error = error.localizedDescription; Log.error("open: \(error.localizedDescription)") }
    }
}
