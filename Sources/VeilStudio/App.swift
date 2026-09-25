import SwiftUI
import AppKit

@main struct VeilStudioApp: App {
    @StateObject private var store = EditorStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            EditorView().environmentObject(store).preferredColorScheme(.dark)
                .frame(minWidth:1180,minHeight:740)
                .background(WindowCloseGuard(store:store,appDelegate:delegate))
                .onAppear { delegate.store = store }
        }
        .windowStyle(.hiddenTitleBar).defaultSize(width:1480,height:940)
        .commands {
            CommandGroup(replacing:.newItem) {
                Button("미디어 열기…",action:store.openMedia).keyboardShortcut("o").disabled(store.busy)
                Button("프로젝트 열기…") { store.openProject() }.keyboardShortcut("o",modifiers:[.command,.shift]).disabled(store.busy)
                Button("프로젝트 저장",action:store.saveProject).keyboardShortcut("s").disabled(!store.loaded || store.busy)
                Button("최근 자동 저장 복구") { store.openProject(recovery:true) }.disabled(store.busy)
                Divider()
                Button("내보내기…") { store.exportSheet = true }.keyboardShortcut("e").disabled(!store.loaded || store.busy)
            }
            CommandGroup(replacing:.undoRedo) {
                Button("실행 취소") { store.editCommand("undo") }.keyboardShortcut("z").disabled((!store.editingText && store.undoStack.isEmpty) || store.busy)
                Button("다시 실행") { store.editCommand("redo") }.keyboardShortcut("z",modifiers:[.command,.shift]).disabled((!store.editingText && store.redoStack.isEmpty) || store.busy)
            }
            CommandGroup(replacing:.pasteboard) {
                Button("잘라내기") { store.editCommand("cut") }.keyboardShortcut("x").disabled(store.busy || (!store.editingText && !store.selectionAvailable))
                Button("복사") { store.editCommand("copy") }.keyboardShortcut("c").disabled(store.busy || (!store.editingText && !store.selectionAvailable))
                Button("붙여넣기") { store.editCommand("paste") }.keyboardShortcut("v").disabled(store.busy || (!store.editingText && (!store.canEditTimeline || !store.pasteAvailable)))
                Button("삭제") { store.editCommand("delete") }.keyboardShortcut(.delete,modifiers:[]).disabled(store.busy || (!store.editingText && !store.selectionAvailable))
                Button("전체 선택") { store.editCommand("selectAll") }.keyboardShortcut("a").disabled(store.busy || (!store.editingText && !store.canEditTimeline))
            }
            CommandMenu("타임라인") {
                Button("재생 / 일시정지",action:store.togglePlay).keyboardShortcut(.space,modifiers:[]).disabled(!store.loaded || store.project.isImage || store.busy)
                Button("재생 위치에서 분할",action:store.split).keyboardShortcut("b").disabled(!store.canEditTimeline)
                Button("컷 앞으로 이동") { store.moveSelected(-1) }.keyboardShortcut(.leftArrow,modifiers:[.command,.option]).disabled(!store.selectionAvailable)
                Button("컷 뒤로 이동") { store.moveSelected(1) }.keyboardShortcut(.rightArrow,modifiers:[.command,.option]).disabled(!store.selectionAvailable)
                Divider()
                Button("내보내기 시작 지정",action:store.markIn).keyboardShortcut("i",modifiers:[]).disabled(!store.canEditTimeline || store.editingText)
                Button("내보내기 종료 지정",action:store.markOut).keyboardShortcut("o",modifiers:[]).disabled(!store.canEditTimeline || store.editingText)
                Button("선택한 컷 범위 내보내기",action:store.exportSelectedClips).disabled(!store.selectionAvailable)
                Button("내보내기 범위 해제") { store.project.exportRange = nil }.disabled(store.project.exportRange == nil)
                Button("지정 범위 삭제 후 붙이기",action:store.deleteMarkedRange).disabled(!store.canEditTimeline || store.project.exportRange == nil)
            }
            CommandGroup(replacing:.appInfo) {
                Button("Veil Studio 정보") { store.helpSheet = true }
            }
            CommandGroup(replacing:.help) { Button("지원 형식과 처리 용량") { store.helpSheet = true } }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: EditorStore?
    var approvedWindowClose = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if approvedWindowClose { return .terminateNow }
        return store?.confirmLeaving() == false ? .terminateCancel : .terminateNow
    }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
