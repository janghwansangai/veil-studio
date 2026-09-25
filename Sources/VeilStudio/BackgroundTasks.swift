import SwiftUI

// Long jobs (face analysis, speech, batch queue, export) run while editing continues.
// Each works on a snapshot and writes its result back only if the same project is still open.
final class BackgroundTask: Identifiable, @unchecked Sendable {
    enum Kind { case faces, speech, speechTest, queue, export }
    let id = UUID()
    let kind: Kind
    let title: String
    let source: UUID?
    let token = Cancellation()
    var message = ""
    var progress = 0.0
    init(kind: Kind, title: String, source: UUID?) { self.kind = kind; self.title = title; self.source = source }
}

extension EditorStore {
    func startBackground(_ kind: BackgroundTask.Kind, title: String, source: UUID? = nil) -> BackgroundTask {
        let task = BackgroundTask(kind:kind,title:title,source:source)
        backgroundTasks.append(task); activityCount += 1; activityToken.begin(title)
        Log.info("background start: \(title)")
        return task
    }
    func reportBackground(_ id: UUID, _ progress: Double, _ message: String) {
        guard let task = backgroundTasks.first(where:{ $0.id == id }), !task.token.cancelled else { return }
        task.progress = max(0,min(1,progress)); task.message = message
        objectWillChange.send()
    }
    func endBackground(_ id: UUID) {
        guard backgroundTasks.contains(where:{ $0.id == id }) else { return }
        backgroundTasks.removeAll { $0.id == id }
        activityCount = max(0,activityCount-1); if activityCount == 0 { activityToken.end() }
    }
    func failBackground(_ id: UUID, _ e: Error) {
        let title = backgroundTasks.first(where:{ $0.id == id })?.title ?? "작업"
        endBackground(id)
        if e is CancellationError { status = "\(title) · 취소됨" }
        else { error = "\(title)\n\(e.localizedDescription)"; status = "\(title) · 완료하지 못했습니다"; Log.error("\(title): \(e.localizedDescription)") }
    }
    func cancelBackground(_ id: UUID) {
        backgroundTasks.first(where:{ $0.id == id })?.token.cancel(); status = "취소하는 중…"
    }
    func cancelAllBackground() { for t in backgroundTasks { t.token.cancel() } }
    func isAnalyzing(_ source: UUID?) -> Bool {
        guard let source else { return false }
        return backgroundTasks.contains { $0.kind == .faces && $0.source == source } || (queueRunning && project.queue.contains { $0.source == source && $0.state == .analyzing })
    }
    func analysisTask(for source: UUID?) -> BackgroundTask? { backgroundTasks.first { $0.kind == .faces && $0.source == source } }
    var speechRunning: Bool { backgroundTasks.contains { $0.kind == .speech || $0.kind == .speechTest } }
}
