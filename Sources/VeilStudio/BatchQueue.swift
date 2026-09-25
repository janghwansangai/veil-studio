import SwiftUI

extension Project {
    // A stand-alone project that renders one media item with its face masks, for batch output.
    func singleSourceProject(_ id: UUID) -> Project? {
        guard var source = media.first(where:{ $0.id == id }), source.isVisual else { return nil }
        source.maskApplied = true
        var p = Project(); p.media = [source]; p.isImage = source.isImage
        p.width = source.width; p.height = source.height; p.fps = source.isImage ? 30 : source.fps
        p.clips = source.isImage ? [] : [Clip(start:0,end:source.duration)]
        p.overlaysOnTimeline = true
        p.design = design; p.faceDesign = effectiveFaceDesign; p.regionDesign = effectiveRegionDesign
        p.faceBridge = faceBridge; p.faceHold = faceHold
        p.export = ExportOptions(); p.export.ratio = .original; p.export.resolution = batch.resolution; p.export.hevc = batch.hevc
        p.export.videoFormat = batch.videoFormat; p.export.burnCaptions = false
        p.export.imageFormat = source.isImage ? .png : nil
        return p
    }
    // Jobs interrupted by a crash or quit go back to waiting.
    mutating func sanitizeQueue() {
        let ids = Set(media.map(\.id))
        queue.removeAll { !ids.contains($0.source) }
        for i in queue.indices where queue[i].state == .analyzing || queue[i].state == .exporting {
            queue[i].state = queue[i].state == .exporting ? .approved : .queued; queue[i].message = "중단된 작업 · 다시 실행하세요"; queue[i].progress = 0
        }
    }
}

extension EditorStore {
    func enqueue(_ ids: [UUID], mode: BatchMode? = nil) {
        var p = project; var added = 0
        for id in ids {
            guard let m = p.media.first(where:{ $0.id == id }), m.isVisual else { continue }
            if let i = p.queue.firstIndex(where:{ $0.source == id }) {
                if p.queue[i].state.finished { p.queue[i].state = .queued; p.queue[i].message = ""; p.queue[i].progress = 0; added += 1 }
                if let mode { p.queue[i].mode = mode }
                continue
            }
            p.queue.append(BatchJob(source:id,mode:mode ?? .review)); added += 1
        }
        project = p; tab = .queue
        status = added > 0 ? "작업 목록에 \(added)개 추가 · ‘순차 실행’을 누르세요" : "이미 작업 목록에 있는 미디어입니다"
    }
    func enqueueAllMedia() { enqueue(project.media.filter(\.isVisual).map(\.id)) }
    func stopQueue() { if let t = backgroundTasks.first(where:{ $0.kind == .queue }) { cancelBackground(t.id) } }
    func removeJob(_ id: UUID) { guard !queueRunning else { return }; project.queue.removeAll { $0.id == id } }
    func moveJob(_ id: UUID, by offset: Int) {
        guard !queueRunning, let i = project.queue.firstIndex(where:{ $0.id == id }) else { return }
        let j = max(0,min(project.queue.count-1,i+offset)); guard i != j else { return }
        var q = project.queue; let job = q.remove(at:i); q.insert(job,at:j); project.queue = q
    }
    func setJobMode(_ id: UUID, _ mode: BatchMode) {
        guard let i = project.queue.firstIndex(where:{ $0.id == id }) else { return }
        project.queue[i].mode = mode
        if mode == .automatic && project.queue[i].state == .review { project.queue[i].state = .approved }
    }
    func retryJob(_ id: UUID) {
        guard !queueRunning, let i = project.queue.firstIndex(where:{ $0.id == id }) else { return }
        project.queue[i].state = .queued; project.queue[i].message = ""; project.queue[i].progress = 0
    }
    func approveJob(_ id: UUID) {
        guard let i = project.queue.firstIndex(where:{ $0.id == id }), project.queue[i].state == .review || project.queue[i].state == .done else { return }
        var p = project
        p.queue[i].state = .approved; p.queue[i].message = "검토 완료 · 출력 대기"
        if let m = p.media.firstIndex(where:{ $0.id == p.queue[i].source }) { p.media[m].maskApplied = true }
        project = p
    }
    private func updateJob(_ id: UUID, _ change: (inout BatchJob) -> Void) {
        guard let i = project.queue.firstIndex(where:{ $0.id == id }) else { return }
        restoring = true; change(&project.queue[i]); restoring = false
        objectWillChange.send(); scheduleRecovery()
    }
    func chooseBatchFolder() -> Bool {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "마스킹한 파일을 저장할 폴더를 선택하세요. 원본은 변경하지 않습니다."
        if !project.batch.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath:project.batch.folder) }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        project.batch.folder = url.path; return true
    }
    private func batchFolderReady() -> Bool {
        var isDirectory: ObjCBool = false
        if !project.batch.folder.isEmpty, FileManager.default.fileExists(atPath:project.batch.folder,isDirectory:&isDirectory), isDirectory.boolValue,
           FileManager.default.isWritableFile(atPath:project.batch.folder) { return true }
        return chooseBatchFolder()
    }
    func outputURL(for source: MediaSource, folder: URL) -> URL {
        let base = URL(fileURLWithPath:source.path).deletingPathExtension().lastPathComponent + project.batch.suffix
        let ext = source.isImage ? "png" : project.batch.videoFormat.rawValue
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext); var n = 2
        let protected = Set(project.media.map { URL(fileURLWithPath:$0.path).standardizedFileURL.path })
        while FileManager.default.fileExists(atPath:url.path) || protected.contains(url.standardizedFileURL.path) {
            url = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext); n += 1
        }
        return url
    }
    // Runs waiting jobs one after another: analyse, then export automatic ones. A failure
    // marks that job and moves on; cancelling stops after the current step.
    func runQueue(onlyApproved: Bool = false) {
        guard loaded, !queueRunning else { return }
        let waiting = project.queue.filter { $0.state == .approved || (!onlyApproved && $0.state == .queued) }
        guard !waiting.isEmpty else { status = "실행할 작업이 없습니다"; return }
        if waiting.contains(where:{ $0.mode == .automatic || $0.state == .approved }) { guard batchFolderReady() else { return } }
        let task = startBackground(.queue,title:"작업 목록 · \(waiting.count)개"); queueRunning = true; let token = task.token; let session = sessionID
        status = "작업 목록을 실행합니다 · 그동안 계속 편집할 수 있습니다"
        Task {
            var done = 0, failed = 0
            let total = waiting.count
            for (n,job) in waiting.enumerated() {
                if token.cancelled || sessionID != session { break }
                guard let source = project.media.first(where:{ $0.id == job.source }) else { continue }
                queueCurrent = job.id
                let prefix = "[\(n+1)/\(total)] \(source.name)"
                do {
                    try verifySource(source.id)
                    var state = project.queue.first(where:{ $0.id == job.id })?.state ?? job.state
                    if state == .queued {
                        updateJob(job.id) { $0.state = .analyzing; $0.message = "얼굴 분석 중"; $0.progress = 0 }
                        let ranges = source.isImage ? [] : [TimelineRange(start:0,end:source.duration)]
                        let output = try await FaceAnalyzer.analyze(source:source,ranges:ranges,mode:project.batch.analysis,cancellation:token) { [weak self = self] v,s in
                            Task { @MainActor in guard let self, !token.cancelled else { return }; self.reportBackground(task.id,(Double(n)+v*0.7)/Double(total),"\(prefix) · \(s)"); self.updateJob(job.id) { $0.progress = v*0.7 } }
                        }
                        guard sessionID == session else { break }
                        storeAnalysis(output,ranges:ranges,source:source.id)
                        let persons = Set(output.tracks.map(\.groupID)).count
                        if job.mode == .automatic {
                            if let m = project.media.firstIndex(where:{ $0.id == source.id }) { project.media[m].maskApplied = true }
                            state = .approved
                            updateJob(job.id) { $0.state = .approved; $0.message = "인물 \(persons)명 · 전원 마스킹 후 출력" }
                        } else {
                            updateJob(job.id) { $0.state = .review; $0.progress = 1; $0.message = "인물 \(persons)명" + (output.review.isEmpty ? "" : " · 검토 권장 \(output.review.count)곳") + " · 검토 후 승인하세요" }
                        }
                    }
                    if state == .approved {
                        try await exportJob(job.id,source:source.id,token:token,index:n,total:total,task:task.id)
                    }
                    done += 1
                } catch is CancellationError {
                    updateJob(job.id) { $0.state = .cancelled; $0.message = "취소됨"; $0.progress = 0 }
                    break
                } catch {
                    failed += 1
                    updateJob(job.id) { $0.state = .failed; $0.message = error.localizedDescription; $0.progress = 0 }
                    Log.error("batch \(source.name): \(error.localizedDescription)")
                }
            }
            endBackground(task.id)
            guard sessionID == session else { return }
            queueCurrent = nil; queueRunning = false
            if token.cancelled { status = "작업 목록 실행을 멈췄습니다 · 완료 \(done)개" }
            else { status = "작업 목록 완료 · 처리 \(done)개" + (failed > 0 ? " · 실패 \(failed)개 (목록에서 이유 확인)" : "") }
        }
    }
    private func exportJob(_ id: UUID, source sourceID: UUID, token: Cancellation, index: Int, total: Int, task: UUID) async throws {
        guard var p = project.singleSourceProject(sourceID), let source = project.media.first(where:{ $0.id == sourceID }) else { throw StudioError.message("출력할 미디어를 찾을 수 없습니다.") }
        if !source.isImage { p.export.resolution = project.batch.resolution }
        let folder = URL(fileURLWithPath:project.batch.folder)
        let url = outputURL(for:source,folder:folder)
        updateJob(id) { $0.state = .exporting; $0.message = "내보내는 중"; $0.progress = 0.7 }
        try await MediaEngine.export(p,to:url,cancellation:token) { [weak self = self] v,_ in
            Task { @MainActor in guard let self, !token.cancelled else { return }; self.reportBackground(task,(Double(index)+0.7+v*0.3)/Double(total),"[\(index+1)/\(total)] \(source.name) · 내보내는 중 \(Int(v*100))%"); self.updateJob(id) { $0.progress = 0.7+v*0.3 } }
        }
        updateJob(id) { $0.state = .done; $0.output = url.path; $0.message = "완료 · \(url.lastPathComponent)"; $0.progress = 1 }
        lastExport = url
    }
    // Exports every approved job without analysing again.
    func exportApproved() {
        guard project.queue.contains(where:{ $0.state == .approved }) else { status = "승인된 작업이 없습니다 · 검토 후 ‘승인’을 누르세요"; return }
        runQueue(onlyApproved:true)
    }
}
