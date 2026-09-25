import SwiftUI
import AppKit

@main struct VeilStudioApp: App {
    @StateObject private var store = EditorStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some Scene {
        WindowGroup {
            EditorView().environmentObject(store).preferredColorScheme(.dark)
                .frame(minWidth:1240,minHeight:760)
                .background(WindowCloseGuard(store:store,appDelegate:delegate))
                .onAppear { delegate.store = store; delegate.offerRecoveryIfNeeded() }
        }
        .windowStyle(.hiddenTitleBar).defaultSize(width:1540,height:980)
        Window("타임라인",id:DetachedWindow.timeline) { DetachedTimelineView().environmentObject(store).preferredColorScheme(.dark) }
            .defaultSize(width:1500,height:460)
        Window("인물 선택",id:DetachedWindow.faces) { DetachedFacesView().environmentObject(store).preferredColorScheme(.dark) }
            .defaultSize(width:980,height:760)
        .commands {
            let typing = store.editingText
            let editable = store.canEditTimeline && !typing
            CommandGroup(replacing:.newItem) {
                Button("미디어로 새 프로젝트…",action:store.openMedia).keyboardShortcut("o").disabled(store.busy)
                Button("미디어 가져오기…",action:store.importMedia).keyboardShortcut("i").disabled(store.busy)
                Button("프로젝트 열기…") { store.openProject() }.keyboardShortcut("o",modifiers:[.command,.shift]).disabled(store.busy)
                Divider()
                Button("프로젝트 저장",action:store.saveProject).keyboardShortcut("s").disabled(!store.loaded || store.busy)
                Button("다른 이름으로 저장…",action:store.saveProjectAs).keyboardShortcut("s",modifiers:[.command,.shift]).disabled(!store.loaded || store.busy)
                Button("최근 자동 저장 복구") { store.openProject(recovery:true) }.disabled(store.busy)
                Divider()
                Button("내보내기…") { store.exportSheet = true }.keyboardShortcut("e").disabled(!store.loaded || store.busy)
                Button("SRT 자막 저장…",action:store.exportSRT).disabled(store.project.captions.isEmpty)
                Button("작업 목록 열기") { store.tab = .queue }.keyboardShortcut("9",modifiers:[.command])
            }
            CommandGroup(replacing:.undoRedo) {
                Button("실행 취소") { store.editCommand("undo") }.keyboardShortcut("z").disabled((!typing && store.undoStack.isEmpty) || store.busy)
                Button("다시 실행") { store.editCommand("redo") }.keyboardShortcut("z",modifiers:[.command,.shift]).disabled((!typing && store.redoStack.isEmpty) || store.busy)
            }
            CommandGroup(replacing:.pasteboard) {
                Button("잘라내기") { store.editCommand("cut") }.keyboardShortcut("x").disabled(store.busy || (!typing && !store.selectionAvailable))
                Button("복사") { store.editCommand("copy") }.keyboardShortcut("c").disabled(store.busy || (!typing && !store.selectionAvailable))
                Button("붙여넣기") { store.editCommand("paste") }.keyboardShortcut("v").disabled(store.busy || (!typing && (!store.canEditTimeline || !store.pasteAvailable)))
                Button("삭제") { store.editCommand("delete") }.keyboardShortcut(.delete,modifiers:[]).disabled(store.busy || (!typing && !store.selectionAvailable))
                Button("전체 선택") { store.editCommand("selectAll") }.keyboardShortcut("a").disabled(store.busy || (!typing && !store.canEditTimeline))
            }
            CommandMenu("재생") {
                Button("재생 / 일시정지",action:store.togglePlay).keyboardShortcut(.space,modifiers:[]).disabled(!store.loaded || store.project.isImage || store.busy || typing)
                Button("되감기 (J)") { store.shuttle(-1) }.keyboardShortcut("j",modifiers:[]).disabled(!editable)
                Button("정지 (K)") { store.shuttle(0) }.keyboardShortcut("k",modifiers:[]).disabled(!editable)
                Button("빨리 재생 (L)") { store.shuttle(1) }.keyboardShortcut("l",modifiers:[]).disabled(!editable)
                Divider()
                Button("1프레임 뒤로") { store.step(frames:-1) }.keyboardShortcut(.leftArrow,modifiers:[]).disabled(!editable)
                Button("1프레임 앞으로") { store.step(frames:1) }.keyboardShortcut(.rightArrow,modifiers:[]).disabled(!editable)
                Button("10프레임 뒤로") { store.step(frames:-10) }.keyboardShortcut(.leftArrow,modifiers:[.shift]).disabled(!editable)
                Button("10프레임 앞으로") { store.step(frames:10) }.keyboardShortcut(.rightArrow,modifiers:[.shift]).disabled(!editable)
                Button("이전 편집 지점") { store.jumpEdit(-1) }.keyboardShortcut(.upArrow,modifiers:[]).disabled(!editable)
                Button("다음 편집 지점") { store.jumpEdit(1) }.keyboardShortcut(.downArrow,modifiers:[]).disabled(!editable)
                Button("처음으로") { store.pause(); store.seek(0) }.keyboardShortcut(.home,modifiers:[]).disabled(!editable)
                Button("끝으로") { store.pause(); store.seek(store.project.editedDuration) }.keyboardShortcut(.end,modifiers:[]).disabled(!editable)
                Divider()
                Button("마커 추가",action:store.addMarker).keyboardShortcut("m",modifiers:[]).disabled(!editable)
                Button("이전 마커") { store.jumpMarker(-1) }.keyboardShortcut(";",modifiers:[.control]).disabled(!editable)
                Button("다음 마커") { store.jumpMarker(1) }.keyboardShortcut("'",modifiers:[.control]).disabled(!editable)
            }
            CommandMenu("타임라인") {
                Button("재생 위치에서 분할",action:store.split).keyboardShortcut("b").disabled(!store.canEditTimeline)
                Button("선택 도구") { store.tool = .select }.keyboardShortcut("a",modifiers:[]).disabled(!editable)
                Button("자르기 도구") { store.tool = .blade }.keyboardShortcut("b",modifiers:[]).disabled(!editable)
                Button(store.snapping ? "스냅 끄기" : "스냅 켜기") { store.snapping.toggle() }.keyboardShortcut("n",modifiers:[]).disabled(typing)
                Divider()
                Button("선택 미디어를 끝에 추가") { if let id = store.selectedMedia { store.appendToTimeline(id) } }.keyboardShortcut("e",modifiers:[]).disabled(!editable || store.selectedMedia == nil || store.tab != .media)
                Button("선택 미디어를 재생 위치에 삽입") { if let id = store.selectedMedia { store.insertAtPlayhead(id) } }.keyboardShortcut("w",modifiers:[]).disabled(!editable || store.selectedMedia == nil || store.tab != .media)
                Button("선택 미디어를 위 트랙에 연결") { if let id = store.selectedMedia { store.connectAtPlayhead(id) } }.keyboardShortcut("q",modifiers:[]).disabled(!editable || store.selectedMedia == nil || store.tab != .media)
                Divider()
                Button("앞으로 이동") { store.moveSelected(-1) }.keyboardShortcut(.leftArrow,modifiers:[.command,.option]).disabled(!store.selectionAvailable)
                Button("뒤로 이동") { store.moveSelected(1) }.keyboardShortcut(.rightArrow,modifiers:[.command,.option]).disabled(!store.selectionAvailable)
                Divider()
                Button("확대") { store.viewport.zoom(by:1.5,around:store.playhead) }.keyboardShortcut("=",modifiers:[.command])
                Button("축소") { store.viewport.zoom(by:1/1.5,around:store.playhead) }.keyboardShortcut("-",modifiers:[.command])
                Button("전체 보기") { store.viewport.fit() }.keyboardShortcut("z",modifiers:[.shift]).disabled(typing)
                Divider()
                Button("내보내기 시작 지정",action:store.markIn).keyboardShortcut("i",modifiers:[]).disabled(!editable)
                Button("내보내기 종료 지정",action:store.markOut).keyboardShortcut("o",modifiers:[]).disabled(!editable)
                Button("선택 항목 범위로 지정",action:store.exportSelectedClips).disabled(!store.selectionAvailable)
                Button("내보내기 범위 해제") { store.project.exportRange = nil }.disabled(store.project.exportRange == nil)
                Button("지정 범위 삭제 후 붙이기",action:store.deleteMarkedRange).disabled(!store.canEditTimeline || store.project.exportRange == nil)
            }
            CommandMenu("클립") {
                Menu("속도") { ForEach([0.25,0.5,1,2,4],id:\.self) { s in Button("\(Int(s*100))%") { store.setSpeed(s) } } }.disabled(!store.canDeleteClips)
                Button("정지 화면 추가") { store.addFreezeFrame() }.keyboardShortcut("f",modifiers:[.option]).disabled(!store.canEditTimeline)
                Button("크로스 디졸브 추가") { store.setTransition(.dissolve) }.keyboardShortcut("t").disabled(!store.canDeleteClips)
                Button("전환 제거") { store.setTransition(nil) }.disabled(!store.canDeleteClips)
                Button("오디오 분리",action:store.detachAudio).keyboardShortcut("s",modifiers:[.control,.shift]).disabled(!store.canDeleteClips)
                Divider()
                Button("타이틀 추가") { store.addTitle() }.keyboardShortcut("t",modifiers:[.control]).disabled(!store.canEditTimeline)
                Button("얼굴 분석") { store.analyze() }.keyboardShortcut("f",modifiers:[.command,.shift]).disabled(!store.loaded || store.busy)
                Button("자동 자막") { store.transcribe() }.keyboardShortcut("r",modifiers:[.command,.shift]).disabled(!store.loaded || store.busy || store.project.isImage)
            }
            CommandMenu("창") {
                Button(store.timelineDetached ? "타임라인 다시 합치기" : "타임라인 창 분리") { if store.timelineDetached { dismissWindow(id:DetachedWindow.timeline) } else { openWindow(id:DetachedWindow.timeline) } }.keyboardShortcut("t",modifiers:[.command,.option])
                Button(store.facesDetached ? "인물 선택 창 닫기" : "인물 선택 창 열기") { if store.facesDetached { dismissWindow(id:DetachedWindow.faces) } else { openWindow(id:DetachedWindow.faces) } }.keyboardShortcut("p",modifiers:[.command,.option])
            }
            CommandGroup(replacing:.appInfo) { Button("Veil Studio 정보") { store.helpSheet = true } }
            CommandGroup(replacing:.help) {
                Button("사용 안내 · 단축키") { store.helpSheet = true }
                Button("오류 기록 폴더 열기") { NSWorkspace.shared.open(Log.folder) }
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: EditorStore?
    var approvedWindowClose = false
    private var crashedLastTime = false
    private var offered = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        crashedLastTime = SessionGuard.begin()
        NSSetUncaughtExceptionHandler { exception in Log.error("uncaught exception: \(exception.name.rawValue) \(exception.reason ?? "")") }
        Log.info("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if approvedWindowClose { return .terminateNow }
        return store?.confirmLeaving() == false ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { store?.pause(); SessionGuard.end(); Log.info("quit") }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    // Files dropped on the Dock icon or opened with "Open With": projects open, media is added.
    private var pendingOpen: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpen += urls
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [weak self] in self?.flushOpen() }
    }
    private func flushOpen() {
        guard let store, !pendingOpen.isEmpty else { if !pendingOpen.isEmpty { DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [weak self] in self?.flushOpen() } }; return }
        let urls = pendingOpen; pendingOpen = []
        if let project = urls.first(where:{ $0.pathExtension == "veilproject" }) { store.openProject(url:project); return }
        guard !store.busy else { store.error = "진행 중인 작업을 마친 뒤 다시 열어 주세요."; return }
        store.addMedia(urls,newProject:!store.loaded)
    }
    // After an unexpected exit, offer the autosaved project once.
    func offerRecoveryIfNeeded() {
        guard crashedLastTime, !offered, let store, FileManager.default.fileExists(atPath:store.recoveryURL.path) else { return }
        offered = true
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6) { [weak store] in
            guard let store else { return }
            let alert = NSAlert(); alert.messageText = "이전 작업이 정상적으로 종료되지 않았습니다"
            alert.informativeText = "자동 저장된 마지막 편집 상태를 복구할까요? 복구하지 않아도 파일 메뉴의 ‘최근 자동 저장 복구’로 나중에 열 수 있습니다."
            alert.addButton(withTitle:"복구"); alert.addButton(withTitle:"나중에")
            if alert.runModal() == .alertFirstButtonReturn { store.openProject(recovery:true) }
        }
    }
}

// Preserve SwiftUI's other window delegate behavior while intercepting close.
struct WindowCloseGuard: NSViewRepresentable {
    let store: EditorStore
    let appDelegate: AppDelegate
    func makeNSView(context: Context) -> GuardView { let view = GuardView(); view.store = store; view.appDelegate = appDelegate; return view }
    func updateNSView(_ view: GuardView, context: Context) { view.window?.isDocumentEdited = store.hasUnsavedChanges }
    @MainActor final class GuardView: NSView, NSWindowDelegate {
        weak var store: EditorStore?
        weak var appDelegate: AppDelegate?
        weak var previousDelegate: NSWindowDelegate?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== self else { return }
            previousDelegate = window.delegate; window.delegate = self
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to:selector) || (previousDelegate?.responds(to:selector) ?? false) }
        override func forwardingTarget(for selector: Selector!) -> Any? { previousDelegate }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard store?.confirmLeaving() != false else { return false }
            let accepted = previousDelegate?.windowShouldClose?(sender) ?? true
            if accepted { appDelegate?.approvedWindowClose = true }
            return accepted
        }
    }
}
