import SwiftUI
import AVKit

struct QueueView: View {
    @EnvironmentObject var store: EditorStore
    @State private var reviewing: UUID?
    var body: some View {
        let queue = store.project.queue
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:10) {
                VStack(alignment:.leading,spacing:4) {
                    Text("순차 얼굴 마스킹 작업 목록").font(.system(size:18,weight:.semibold))
                    Text("대기 \(queue.filter { $0.state == .queued }.count) · 검토 대기 \(queue.filter { $0.state == .review }.count) · 출력 대기 \(queue.filter { $0.state == .approved }.count) · 완료 \(queue.filter { $0.state == .done }.count) · 실패 \(queue.filter { $0.state == .failed }.count)").font(.system(size:11)).foregroundStyle(Color.muted)
                }
                Spacer()
                Button { store.importMedia() } label: { Label("미디어 가져오기",systemImage:"plus") }.help("영상·사진·오디오 파일이나 폴더를 프로젝트에 추가합니다 (⌘I)").buttonStyle(ActionStyle()).disabled(store.busy)
                Button { store.enqueueAllMedia() } label: { Label("모든 미디어 추가",systemImage:"text.badge.plus") }.help("프로젝트의 모든 영상·사진을 얼굴 마스킹 작업 목록에 넣습니다").buttonStyle(ActionStyle()).disabled(store.busy || !store.project.media.contains(where:\.isVisual))
                if store.queueRunning { Button { store.stopQueue() } label: { Label("중지",systemImage:"stop.fill") }.help("실행 중인 작업을 멈춥니다").buttonStyle(ActionStyle()) }
                else {
                    Button { store.exportApproved() } label: { Label("승인 항목 출력",systemImage:"square.and.arrow.up") }.help("승인한 항목만 저장 폴더에 내보냅니다").buttonStyle(ActionStyle()).disabled(store.busy || !queue.contains { $0.state == .approved })
                    Button { store.runQueue() } label: { Label("순차 실행",systemImage:"play.fill") }.help("대기 중인 항목을 차례로 분석하고, 자동 출력 항목은 바로 저장합니다").buttonStyle(ActionStyle(primary:true)).disabled(store.busy || !queue.contains { $0.state == .queued || $0.state == .approved })
                }
            }
            settings
            if queue.isEmpty {
                EmptyHint(icon:"list.bullet.rectangle",title:"작업할 영상을 추가하세요",text:"미디어 패널에서 ‘작업 목록’ 또는 ‘모든 미디어 추가’를 누르세요.\n각 항목은 ‘검토 후 출력’ 또는 ‘자동 출력’으로 처리됩니다.")
            } else {
                ScrollView { LazyVStack(spacing:8) {
                    ForEach(Array(queue.enumerated()),id:\.element.id) { n,job in JobRow(job:job,index:n,reviewing:$reviewing) }
                } }
            }
            Text("‘자동 출력’은 찾은 얼굴을 모두 가린 뒤 바로 저장합니다. 아이 영상은 ‘검토 후 출력’으로 누락을 확인하는 것을 권장합니다. 실행 중에는 편집이 잠기며, 실패한 항목은 건너뛰고 다음 항목을 계속합니다.").font(.system(size:10)).foregroundStyle(Color.muted)
        }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(Color.base)
        .sheet(item:Binding(get:{ reviewing.map { ReviewTarget(id:$0) } },set:{ reviewing = $0?.id })) { target in ReviewSheet(jobID:target.id).environmentObject(store) }
    }
    var settings: some View {
        HStack(alignment:.top,spacing:18) {
            VStack(alignment:.leading,spacing:6) {
                Text("저장 폴더").font(.system(size:10,weight:.semibold))
                HStack {
                    Text(store.project.batch.folder.isEmpty ? "선택하지 않음" : store.project.batch.folder).font(.system(size:10)).foregroundStyle(store.project.batch.folder.isEmpty ? Color.orange : Color.muted).lineLimit(1).truncationMode(.middle)
                    Button("선택") { _ = store.chooseBatchFolder() }.help("마스킹한 파일을 저장할 폴더를 고릅니다").buttonStyle(ActionStyle()).font(.system(size:9))
                    if !store.project.batch.folder.isEmpty { Button("열기") { NSWorkspace.shared.open(URL(fileURLWithPath:store.project.batch.folder)) }.help("저장 폴더를 Finder에서 엽니다").buttonStyle(ActionStyle()).font(.system(size:9)) }
                }
                HStack { Text("이름 뒤에 붙일 말").font(.system(size:10)); TextField("_마스킹",text:$store.project.batch.suffix).textFieldStyle(.roundedBorder).frame(width:110) }
            }.frame(maxWidth:360,alignment:.leading)
            VStack(alignment:.leading,spacing:6) {
                Picker("분석 모드",selection:$store.project.batch.analysis) { ForEach(FaceAnalysisMode.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Text(store.project.batch.analysis.detail).font(.system(size:9)).foregroundStyle(Color.muted).lineLimit(2)
            }.frame(width:260)
            VStack(alignment:.leading,spacing:6) {
                Picker("형식",selection:$store.project.batch.videoFormat) { ForEach(VideoOutput.allCases,id:\.self) { Text($0.rawValue.uppercased()).tag($0) } }
                Picker("코덱",selection:$store.project.batch.hevc) { Text("H.264").tag(false); Text("HEVC").tag(true) }
                Picker("해상도",selection:$store.project.batch.resolution) { ForEach(OutputResolution.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            }.frame(width:220)
        }.font(.system(size:10)).padding(12).background(Color.panel,in:RoundedRectangle(cornerRadius:10)).disabled(store.busy)
    }
}
struct ReviewTarget: Identifiable { var id: UUID }

struct JobRow: View {
    @EnvironmentObject var store: EditorStore
    let job: BatchJob
    let index: Int
    @Binding var reviewing: UUID?
    var body: some View {
        let _ = store.thumbnailRevision
        let media = store.project.media.first(where:{ $0.id == job.source })
        HStack(spacing:12) {
            Text("\(index+1)").font(.system(size:11,design:.monospaced)).foregroundStyle(Color.muted).frame(width:22)
            ZStack { RoundedRectangle(cornerRadius:5).fill(Color.black); if let m = media, let poster = store.thumbnails.poster(m) { Image(decorative:poster,scale:1).resizable().scaledToFit() } }.frame(width:72,height:42).clipShape(RoundedRectangle(cornerRadius:5))
            VStack(alignment:.leading,spacing:4) {
                Text(media?.name ?? "없는 미디어").font(.system(size:12,weight:.medium)).lineLimit(1)
                HStack(spacing:6) {
                    Text(job.state.rawValue).font(.system(size:9,weight:.semibold)).padding(.horizontal,6).padding(.vertical,2).background(stateColor.opacity(0.2),in:Capsule()).foregroundStyle(stateColor)
                    Text(job.message).font(.system(size:10)).foregroundStyle(job.state == .failed ? Color.red : Color.muted).lineLimit(2)
                }
                if job.state == .analyzing || job.state == .exporting { ProgressView(value:job.progress).frame(maxWidth:260) }
            }
            Spacer()
            Picker("",selection:Binding(get:{ job.mode },set:{ store.setJobMode(job.id,$0) })) { ForEach(BatchMode.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width:120).disabled(store.queueRunning)
            if job.state == .review || (job.state == .done && media?.analysisComplete == true) { Button("검토") { reviewing = job.id }.help("마스크를 적용한 상태로 재생하며 인물을 확인합니다").buttonStyle(ActionStyle()) }
            if job.state == .review { Button("승인") { store.approveJob(job.id) }.help("검토 완료로 표시합니다. ‘승인 항목 출력’ 때 저장됩니다").buttonStyle(ActionStyle(primary:true)) }
            if job.state == .failed || job.state == .cancelled || job.state == .done { Button(job.state == .done ? "다시" : "재시도") { store.retryJob(job.id) }.help("이 항목을 다시 대기 상태로 돌립니다").buttonStyle(ActionStyle()).disabled(store.queueRunning) }
            if let output = job.output, job.state == .done { Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:output)]) } label: { Image(systemName:"folder") }.buttonStyle(ActionStyle()).help(output) }
            VStack(spacing:2) {
                Button { store.moveJob(job.id,by:-1) } label: { Image(systemName:"chevron.up") }.help("위로 이동")
                Button { store.moveJob(job.id,by:1) } label: { Image(systemName:"chevron.down") }.help("아래로 이동")
            }.buttonStyle(.hover).foregroundStyle(Color.muted).disabled(store.queueRunning)
            Button { store.removeJob(job.id) } label: { Image(systemName:"xmark") }.help("작업 목록에서 뺍니다").buttonStyle(.hover).foregroundStyle(Color.muted).disabled(store.queueRunning)
        }.font(.system(size:10)).padding(10)
            .background(store.queueCurrent == job.id ? Color.accent.opacity(0.14) : Color.panel,in:RoundedRectangle(cornerRadius:10))
    }
    var stateColor: Color {
        switch job.state {
        case .done: return .mint; case .failed: return .red; case .review: return .yellow; case .approved: return .cyan
        case .analyzing, .exporting: return Color.accent; case .queued, .cancelled: return Color.muted
        }
    }
}

// Plays one media item with its current face masks, independent of the timeline.
@MainActor final class ReviewModel: ObservableObject {
    let player = AVPlayer()
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var ready = false
    @Published var still: NSImage?
    @Published var message = ""
    private var built: BuiltTimeline?
    private let renderer = MaskRenderer(), stills = StillCache()
    private var observer: Any?
    private var task: Task<Void,Never>?
    init() {
        observer = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.05,preferredTimescale:600),queue:.main) { [weak self] t in
            Task { @MainActor in guard let self, t.seconds.isFinite else { return }; self.time = t.seconds; if self.playing && t.seconds >= self.duration-0.02 { self.player.pause(); self.playing = false } }
        }
    }
    func update(_ project: Project) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds:120_000_000); guard !Task.isCancelled else { return }
            if project.isImage {
                let p = project, renderer = renderer
                let image: NSImage? = await Task.detached {
                    guard let source = try? MediaEngine.stillImage(URL(fileURLWithPath:p.sourcePath)) else { return nil }
                    let scale = min(1,1600/max(source.extent.width,source.extent.height)); let small = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    let result = renderer.render(small,project:p,time:0,crop:false)
                    return renderer.context.createCGImage(result,from:result.extent).map { NSImage(cgImage:$0,size:.zero) }
                }.value
                if !Task.isCancelled { still = image; ready = true }
                return
            }
            do {
                let key = CompositionKey(project)
                let timeline: BuiltTimeline
                if let built, built.key == key, player.currentItem != nil { timeline = built }
                else { timeline = try await CompositionBuilder.buildTimeline(project,muted:false,allowMissing:false); built = timeline; duration = timeline.duration }
                guard !Task.isCancelled else { return }
                let (video,_) = CompositionBuilder.videoComposition(timeline,project:project,purpose:.preview,renderer:renderer,cancellation:nil,stills:stills,previewEdge:1600)
                if let item = player.currentItem, item.asset === timeline.composition {
                    item.videoComposition = video
                    if !playing { player.seek(to:CMTime(seconds:time,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero) { _ in } }
                } else {
                    let item = AVPlayerItem(asset:timeline.composition); item.videoComposition = video
                    item.audioMix = CompositionBuilder.audioMix(timeline,project:project)
                    player.replaceCurrentItem(with:item)
                }
                ready = true
            } catch { message = error.localizedDescription }
        }
    }
    func seek(_ t: Double) { time = max(0,min(duration,t)); player.seek(to:CMTime(seconds:time,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero) }
    func toggle() { if playing { player.pause(); playing = false } else { if time >= duration-0.05 { seek(0) }; player.play(); playing = true } }
    func stop() { task?.cancel(); player.pause(); player.replaceCurrentItem(with:nil); if let observer { player.removeTimeObserver(observer) }; observer = nil }
}

struct ReviewSheet: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) var dismiss
    let jobID: UUID
    @StateObject private var model = ReviewModel()
    @State private var expanded = Set<UUID>()
    @State private var picked = Set<UUID>()
    var job: BatchJob? { store.project.queue.first { $0.id == jobID } }
    var source: MediaSource? { job.flatMap { j in store.project.media.first { $0.id == j.source } } }
    var body: some View {
        let reviewProject = job.flatMap { store.project.singleSourceProject($0.source) }
        HStack(spacing:0) {
            VStack(spacing:10) {
                HStack { Text(source?.name ?? "").font(.system(size:14,weight:.semibold)).lineLimit(1); Spacer(); Text("검토 · 마스크 적용 미리보기").font(.system(size:10)).foregroundStyle(Color.muted) }
                ZStack {
                    Color.black
                    if reviewProject?.isImage == true { if let still = model.still { Image(nsImage:still).resizable().scaledToFit() } }
                    else { PlayerView(player:model.player) }
                    if !model.ready { ProgressView().controlSize(.small) }
                }.aspectRatio(max(0.3,(source?.width ?? 16)/max(1,source?.height ?? 9)),contentMode:.fit).frame(maxWidth:.infinity,maxHeight:.infinity)
                if reviewProject?.isImage != true {
                    HStack(spacing:10) {
                        Button { model.toggle() } label: { Image(systemName:model.playing ? "pause.fill" : "play.fill") }.help("재생 / 일시정지 (Space)").buttonStyle(.hover).keyboardShortcut(.space,modifiers:[])
                        Slider(value:Binding(get:{ model.time },set:{ model.seek($0) }),in:0...max(0.01,model.duration))
                        Text("\(timecode(model.time)) / \(timecode(model.duration))").font(.system(size:10,design:.monospaced)).foregroundStyle(Color.muted)
                    }
                }
                if !model.message.isEmpty { Text(model.message).font(.system(size:10)).foregroundStyle(.red) }
            }.padding(18).frame(minWidth:560)
            Divider()
            VStack(alignment:.leading,spacing:10) {
                if let source {
                    let groups = PersonGroup.make(source.faces)
                    SectionLabel(title:"인물 \(groups.count)명",detail:"선택 \(groups.filter(\.anySelected).count)명 가림")
                    HStack {
                        Button("전체 선택") { store.setGroupSelection(source.faces.map(\.id),selected:true) }
                        Button("전체 해제") { store.setGroupSelection(source.faces.map(\.id),selected:false) }
                        Spacer()
                        Button("묶기") { store.groupFaces(Set(source.faces.filter { picked.contains($0.groupID) }.map(\.id))); picked = [] }.help("⌘클릭으로 고른 인물들을 한 사람으로 묶습니다").disabled(picked.count < 2)
                    }.buttonStyle(.hover).font(.system(size:10)).foregroundStyle(Color.muted)
                    if groups.isEmpty { EmptyHint(icon:"person.crop.square.badge.questionmark",title:"검출된 얼굴이 없습니다",text:"영상을 끝까지 재생해 얼굴이 정말 없는지\n확인한 뒤 승인하세요.") }
                    else { ScrollView { LazyVStack(spacing:6) { ForEach(groups) { g in PersonRow(group:g,source:source,expanded:$expanded,picked:$picked,onSeek:{ model.seek($0) }) } } } }
                    if !source.reviewRanges.isEmpty {
                        Text("검토 권장 구간 \(source.reviewRanges.count)곳").font(.system(size:10,weight:.semibold)).foregroundStyle(.orange)
                        ScrollView { VStack(alignment:.leading,spacing:3) { ForEach(Array(source.reviewRanges.enumerated()),id:\.offset) { _,r in Button("\(timecode(r.start)) – \(timecode(r.end))") { model.seek(r.start) }.help("이 구간으로 이동해 얼굴이 가려졌는지 확인하세요").buttonStyle(.hover).font(.system(size:10,design:.monospaced)).foregroundStyle(.orange) } } }.frame(maxHeight:100)
                    }
                    Text("놓친 얼굴이 있으면 이 영상을 타임라인에 넣고 영역 마스크로 보완하거나, 정밀 모드로 다시 실행하세요.").font(.system(size:9)).foregroundStyle(Color.muted)
                }
                HStack {
                    Button("닫기") { dismiss() }.help("창을 닫습니다").buttonStyle(ActionStyle())
                    Spacer()
                    if job?.state == .review { Button("승인하고 닫기") { store.approveJob(jobID); dismiss() }.help("검토를 마쳤습니다. ‘승인 항목 출력’ 때 이 영상을 저장합니다").buttonStyle(ActionStyle(primary:true)) }
                }
            }.padding(16).frame(width:320)
        }.frame(width:1100,height:700).background(Color.panel).foregroundStyle(Color.ink).tint(Color.accent)
            .onAppear { if let reviewProject { model.update(reviewProject) } }
            .onChange(of:reviewProject) { if let reviewProject { model.update(reviewProject) } }
            .onDisappear { model.stop() }
    }
}
