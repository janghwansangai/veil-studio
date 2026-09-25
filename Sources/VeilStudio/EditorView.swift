import SwiftUI
import AVKit
import UniformTypeIdentifiers

extension Color {
    static let base = Color(red:0.055,green:0.063,blue:0.079)
    static let panel = Color(red:0.085,green:0.096,blue:0.12)
    static let raised = Color(red:0.12,green:0.135,blue:0.165)
    static let ink = Color(red:0.92,green:0.94,blue:0.97)
    static let muted = Color(red:0.52,green:0.56,blue:0.63)
    static let accent = Color(red:0.70,green:0.62,blue:1)
    static let mint = Color(red:0.73,green:0.92,blue:0.61)
}
struct ActionStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View { ActionBody(configuration:configuration,primary:primary) }
    private struct ActionBody: View {
        let configuration: ButtonStyleConfiguration
        let primary: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.font(.system(size:12,weight:.semibold)).padding(.horizontal,11).padding(.vertical,7)
                .foregroundStyle(primary ? Color.base : Color.ink)
                .background(primary ? Color.mint.opacity(hovering && enabled ? 0.85 : 1) : Color.raised.opacity(hovering && enabled ? 1 : 0.8),in:RoundedRectangle(cornerRadius:7))
                .overlay(RoundedRectangle(cornerRadius:7).stroke(Color.white.opacity(hovering && enabled ? 0.18 : 0),lineWidth:1))
                .opacity(configuration.isPressed ? 0.65 : enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .hoverCursor(enabled ? .pointingHand : .arrow)
        }
    }
}
struct SectionLabel: View { var title: String; var detail: String = ""; var body: some View { HStack { Text(title).font(.system(size:12,weight:.semibold)).lineLimit(1); Spacer(); Text(detail).font(.system(size:10)).foregroundStyle(Color.muted) }.padding(.bottom,4) } }
struct EmptyHint: View { var icon: String; var title: String; var text: String; var body: some View { VStack(spacing:12) { Image(systemName:icon).font(.system(size:29,weight:.light)).foregroundStyle(Color.accent); Text(title).font(.system(size:13,weight:.semibold)); Text(text).font(.system(size:11)).foregroundStyle(Color.muted).multilineTextAlignment(.center).lineSpacing(4) }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity) } }

struct EditorView: View {
    @AppStorage("timelineHeight") private var timelineHeight = 330.0
    @State private var resizeStart: Double?
    @EnvironmentObject var store: EditorStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        VStack(spacing:0) {
            header
            Divider().overlay(Color.white.opacity(0.04))
            HStack(spacing:0) {
                navigation.frame(width:158)
                Divider()
                VStack(spacing:0) {
                    toolBar
                    Divider()
                    if store.tab == .queue {
                        QueueView()
                    } else {
                        HStack(spacing:0) {
                            library.frame(width:268)
                            Divider()
                            VStack(spacing:0) { PreviewPane(); transport }.frame(maxWidth:.infinity,maxHeight:.infinity)
                            Divider()
                            InspectorPanel().frame(width:268)
                        }.frame(maxHeight:.infinity)
                        if store.timelineDetached {
                            HStack(spacing:10) {
                                Image(systemName:"rectangle.split.1x2").foregroundStyle(Color.accent)
                                Text("타임라인이 별도 창에 열려 있습니다").font(.system(size:11))
                                Text(frameTimecode(store.playhead,fps:store.project.fps)).font(.system(size:10,design:.monospaced)).foregroundStyle(Color.muted)
                                Spacer()
                                Button { openWindow(id:DetachedWindow.timeline) } label: { Label("타임라인 창 보기",systemImage:"macwindow") }.buttonStyle(ActionStyle()).help("분리된 타임라인 창을 앞으로 가져옵니다")
                                Button { dismissWindow(id:DetachedWindow.timeline) } label: { Label("다시 합치기",systemImage:"rectangle.bottomhalf.inset.filled") }.buttonStyle(ActionStyle()).help("타임라인을 이 창 아래로 돌려놓습니다 (⌥⌘T)")
                            }.padding(.horizontal,18).frame(height:40).background(Color.panel)
                        } else {
                        Rectangle().fill(Color.raised).frame(height:8)
                            .overlay(Capsule().fill(Color.muted).frame(width:44,height:3))
                            .hoverCursor(.resizeUpDown)
                            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.global).onChanged { value in
                                if resizeStart == nil { resizeStart = timelineHeight }
                                let maximum = max(240,(NSApp.keyWindow?.contentView?.bounds.height ?? 800)-300)
                                timelineHeight = min(maximum,max(200,(resizeStart ?? 330)-value.translation.height))
                            }.onEnded { _ in resizeStart = nil })
                            .help("위아래로 드래그하여 타임라인 높이 조절")
                        TimelineView(viewport:store.viewport).frame(height:timelineHeight)
                        }
                    }
                }
            }.disabled(store.busy)
            statusBar
        }.background(Color.base).foregroundStyle(Color.ink).tint(Color.accent)
        .onReceive(NotificationCenter.default.publisher(for:NSControl.textDidBeginEditingNotification)) { _ in store.editingText = true }
        .onReceive(NotificationCenter.default.publisher(for:NSControl.textDidEndEditingNotification)) { _ in store.editingText = false }
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.didUpdateNotification)) { _ in
            let active = NSApp.keyWindow?.firstResponder is NSTextView
            if store.editingText != active { store.editingText = active }
        }
        .sheet(isPresented:$store.exportSheet) { ExportSheet().environmentObject(store) }
        .sheet(isPresented:$store.helpSheet) { HelpSheet() }
        .alert("작업 안내",isPresented:Binding(get:{store.error != nil},set:{if !$0 { store.error = nil }})) { Button("확인") { store.error = nil } } message: { Text(store.error ?? "") }
        .onDrop(of:[.fileURL],isTargeted:nil) { providers in
            guard !store.busy, !providers.isEmpty else { return false }
            let collector = DropCollector(count:providers.count) { urls in
                Task { @MainActor in
                    guard !urls.isEmpty else { return }
                    if store.loaded { store.addMedia(urls,newProject:false) }
                    else { store.addMedia(urls,newProject:true) }
                }
            }
            for provider in providers {
                _ = provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier) { data,_ in
                    collector.add(data.flatMap { URL(dataRepresentation:$0,relativeTo:nil) })
                }
            }
            return true
        }
    }
    var header: some View {
        HStack(spacing:12) {
            HStack(spacing:9) { Image(systemName:"circle.hexagongrid.fill").font(.system(size:25)).foregroundStyle(Color.mint); Text("veil").font(.system(size:24,weight:.bold,design:.rounded)); Text("STUDIO").font(.system(size:9,weight:.semibold)).tracking(2).foregroundStyle(Color.muted) }.frame(width:150,alignment:.leading)
            Rectangle().fill(Color.white.opacity(0.09)).frame(width:1,height:22)
            VStack(alignment:.leading,spacing:3) {
                Text(store.fileName + (store.hasUnsavedChanges ? " · 편집됨" : "")).font(.system(size:12,weight:.medium)).lineLimit(1)
                Text(store.loaded ? "캔버스 \(Int(store.project.width)) × \(Int(store.project.height))  ·  미디어 \(store.project.media.count)개  ·  \(timecode(store.project.editedDuration))  ·  원본 보호" : "프라이버시를 위한 영상 · 이미지 편집기").font(.system(size:10)).foregroundStyle(Color.muted)
            }
            Spacer()
            Label("기기 내 처리",systemImage:"lock.shield").font(.system(size:10)).foregroundStyle(Color.mint).padding(7).background(Color.mint.opacity(0.07),in:Capsule())
            Button { store.importMedia() } label: { Label("가져오기",systemImage:"plus") }.buttonStyle(ActionStyle()).help("미디어 가져오기 ⌘I").disabled(store.busy)
            Button { store.saveProject() } label: { Image(systemName:"square.and.arrow.down") }.buttonStyle(ActionStyle()).help("프로젝트 저장 ⌘S").disabled(!store.loaded || store.busy)
            Button { store.exportSheet = true } label: { Label("내보내기",systemImage:"arrow.up.right") }.help("편집 결과를 새 영상·사진 파일로 저장합니다 (⌘E)").buttonStyle(ActionStyle(primary:true)).disabled(!store.loaded || store.busy)
        }.padding(.horizontal,18).padding(.top,20).padding(.bottom,14)
    }
    var navigation: some View {
        VStack(alignment:.leading,spacing:6) {
            Text("WORKSPACE").font(.system(size:9,weight:.semibold)).tracking(1.6).foregroundStyle(Color.muted).padding(.horizontal,12).padding(.top,20).padding(.bottom,8)
            ForEach(EditorTab.allCases,id:\.self) { tab in
                Button { store.tab = tab; store.drawMode = false; if tab == .regions || tab == .faces { store.inspector = .mask } } label: {
                    HStack(spacing:9) {
                        Image(systemName:tab.icon).frame(width:18); Text(tab.rawValue); Spacer()
                        if tab == .queue, store.project.queue.contains(where:{ !$0.state.finished && $0.state != .queued }) || store.queueRunning { Circle().fill(Color.yellow).frame(width:6,height:6) }
                        else if store.tab == tab { Circle().fill(Color.accent).frame(width:5,height:5) }
                    }
                        .font(.system(size:12,weight:store.tab == tab ? .semibold : .regular)).padding(.vertical,11).padding(.horizontal,10)
                        .foregroundStyle(store.tab == tab ? Color.accent : Color.muted)
                        .background(store.tab == tab ? Color.accent.opacity(0.10) : .clear,in:RoundedRectangle(cornerRadius:8))
                        .contentShape(Rectangle())
                }.buttonStyle(.hover)
            }
            Rectangle().fill(Color.white.opacity(0.07)).frame(height:1).padding(.vertical,12)
            Button { store.openMedia() } label: { Label("새 프로젝트",systemImage:"doc.badge.plus").font(.system(size:11)) }.help("파일을 골라 새 프로젝트를 만듭니다 (⌘O)").buttonStyle(.hover).padding(.horizontal,10).padding(.vertical,6)
            Button { store.openProject() } label: { Label("프로젝트 열기",systemImage:"square.stack").font(.system(size:11)) }.help("저장한 .veilproject 파일을 엽니다 (⇧⌘O)").buttonStyle(.hover).padding(.horizontal,10).padding(.vertical,6)
            Spacer()
            VStack(alignment:.leading,spacing:8) {
                Image(systemName:"shield.lefthalf.filled").font(.system(size:18)).foregroundStyle(Color.mint)
                Text("안심하고, 표현하세요.").font(.system(size:11,weight:.semibold))
                Text("사진과 영상은 이 Mac에서\n처리됩니다. 원본은 그대로.").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(4)
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.raised.opacity(0.6),in:RoundedRectangle(cornerRadius:10))
            Button { store.helpSheet = true } label: { Label("사용 안내 · 단축키",systemImage:"questionmark.circle").font(.system(size:10)) }.help("기능 안내와 단축키를 봅니다").buttonStyle(.hover).foregroundStyle(Color.muted).padding(.vertical,12).padding(.horizontal,8)
            Text("제작자 다있쌤 로디").font(.system(size:10,weight:.medium)).foregroundStyle(Color.mint).padding(.horizontal,8)
            Text("VEIL STUDIO   /   0.8.1").font(.system(size:8,weight:.medium,design:.monospaced)).foregroundStyle(Color.muted.opacity(0.65)).padding(.horizontal,8).padding(.bottom,12)
        }.padding(.horizontal,8).background(Color.panel.opacity(0.6))
    }
    var toolBar: some View {
        HStack(spacing:10) {
            Text(store.tab.rawValue).font(.system(size:14,weight:.semibold))
            Text(subtitle).font(.system(size:11)).foregroundStyle(Color.muted).lineLimit(1)
            Spacer()
            switch store.tab {
            case .media:
                Button { store.importMedia() } label: { Label("미디어 가져오기",systemImage:"plus") }.help("영상·사진·오디오 파일이나 폴더를 프로젝트에 추가합니다 (⌘I)").buttonStyle(ActionStyle())
            case .faces:
                if !store.project.isImage { Toggle("분석 후 자동 자막",isOn:$store.autoCaptions).font(.system(size:10)).toggleStyle(.checkbox) }
                Button { store.analyze() } label: { Label(store.faceSource?.analysisComplete == true ? "다시 분석" : "얼굴 분석",systemImage:"sparkle.viewfinder") }.help("선택한 미디어의 얼굴을 찾아 인물별로 묶습니다 (⇧⌘F)").buttonStyle(ActionStyle()).disabled(!store.loaded || store.faceSource == nil || store.isAnalyzing(store.faceSource?.id))
            case .regions:
                Button { store.drawMode.toggle() } label: { Label(store.drawMode ? "그리기 취소" : "영역 그리기",systemImage:"plus.viewfinder") }.help("미리보기 위를 끌어 가릴 영역을 그립니다").buttonStyle(ActionStyle(primary:store.drawMode)).disabled(!store.loaded)
            case .captions:
                Button(action:store.importSRT) { Text("SRT 가져오기") }.help("SRT 자막 파일을 불러와 현재 자막을 바꿉니다").buttonStyle(ActionStyle()).disabled(!store.loaded || store.project.isImage)
                Button(action:{ store.transcribe() }) { Label(store.speechRunning ? "인식 중…" : "자동 자막",systemImage:"waveform") }.help("타임라인의 모든 소리를 인식해 자막을 만듭니다. 기존 자막은 교체됩니다 (⇧⌘R)").buttonStyle(ActionStyle()).disabled(!store.loaded || store.project.isImage)
            case .titles:
                Button { store.addTitle() } label: { Label("타이틀 추가",systemImage:"plus") }.help("재생 위치에 3초짜리 타이틀을 추가합니다 (⌃T)").buttonStyle(ActionStyle()).disabled(!store.canEditTimeline)
            case .queue: EmptyView()
            }
        }.padding(.horizontal,18).frame(height:52)
    }
    var subtitle: String {
        switch store.tab {
        case .media: return "여러 영상·사진·오디오를 모아 타임라인에 배치합니다."
        case .faces: return "선택한 얼굴에만, 모든 장면에서."
        case .regions: return "가리고 싶은 부분을 직접 지정하세요."
        case .captions: return "말을 자막으로. 원하는 문장으로."
        case .titles: return "화면에 제목과 설명을 올립니다."
        case .queue: return "여러 영상을 차례로 마스킹합니다."
        }
    }
    @ViewBuilder var library: some View {
        switch store.tab {
        case .media: MediaLibrary()
        case .faces: FaceLibrary()
        case .regions: RegionLibrary()
        case .captions: CaptionLibrary()
        case .titles: TitleLibrary()
        case .queue: EmptyView()
        }
    }
    var transport: some View {
        HStack(spacing:12) {
            Text(store.project.isImage ? "STILL IMAGE" : "EDITED PREVIEW").font(.system(size:8,weight:.semibold,design:.monospaced)).tracking(1).foregroundStyle(Color.muted)
            Spacer()
            if !store.project.isImage {
                Button { store.jumpEdit(-1) } label: { Image(systemName:"backward.end.fill") }.buttonStyle(.hover).help("이전 편집 지점 ↑")
                Button { store.step(frames:-1) } label: { Image(systemName:"chevron.left") }.buttonStyle(.hover).help("1프레임 뒤로 ←")
                Button { store.shuttle(-1) } label: { Image(systemName:"backward.fill") }.buttonStyle(.hover).help("되감기 J")
                Button(action:store.togglePlay) { Image(systemName:store.playing && store.shuttleRate >= 0 ? "pause.fill" : "play.fill").font(.system(size:14)).frame(width:32,height:32).background(Color.raised,in:Circle()) }.buttonStyle(.hover).help("재생/일시정지 Space")
                Button { store.shuttle(1) } label: { Image(systemName:"forward.fill") }.buttonStyle(.hover).help("빨리 재생 L (누를수록 빨라짐)")
                Button { store.step(frames:1) } label: { Image(systemName:"chevron.right") }.buttonStyle(.hover).help("1프레임 앞으로 →")
                Button { store.jumpEdit(1) } label: { Image(systemName:"forward.end.fill") }.buttonStyle(.hover).help("다음 편집 지점 ↓")
                if store.shuttleRate != 0 && store.shuttleRate != 1 { Text("\(store.shuttleRate > 0 ? "" : "◀ ")\(Int(abs(store.shuttleRate)))×").font(.system(size:10,weight:.bold)).foregroundStyle(.yellow) }
            }
            Spacer()
            Text("\(frameTimecode(store.playhead,fps:store.project.fps)) / \(frameTimecode(store.project.editedDuration,fps:store.project.fps))").font(.system(size:10,design:.monospaced)).foregroundStyle(Color.muted)
        }.padding(.horizontal,18).frame(height:46).disabled(!store.loaded || store.project.isImage)
    }
    var statusBar: some View {
        HStack(spacing:10) {
            Circle().fill(store.busy || !store.backgroundTasks.isEmpty ? Color.accent : Color.mint).frame(width:5,height:5)
            Text(store.status).font(.system(size:10)).lineLimit(1)
            if store.busy { ProgressView(value:max(0,min(1,store.progress))).frame(width:150); Text("\(Int(max(0,min(1,store.progress))*100))%").font(.system(size:10,design:.monospaced)); Button("취소",action:store.cancel).buttonStyle(.hover).foregroundStyle(Color.accent) }
            ForEach(store.backgroundTasks.prefix(3)) { task in
                HStack(spacing:6) {
                    ProgressView().controlSize(.mini)
                    Text(task.title).font(.system(size:10,weight:.medium)).lineLimit(1)
                    ProgressView(value:task.progress).frame(width:80)
                    Text("\(Int(task.progress*100))%").font(.system(size:9,design:.monospaced)).foregroundStyle(Color.muted)
                    Button { store.cancelBackground(task.id) } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.hover).foregroundStyle(Color.muted).help("이 작업 취소")
                }.padding(.horizontal,8).padding(.vertical,3).background(Color.accent.opacity(0.12),in:Capsule()).help(task.message)
            }
            if store.backgroundTasks.count > 3 { Text("+\(store.backgroundTasks.count-3)").font(.system(size:10)).foregroundStyle(Color.muted) }
            Spacer()
            if let url = store.lastExport { Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.help("마지막으로 내보낸 파일을 Finder에서 보여 줍니다").buttonStyle(.hover).foregroundStyle(Color.mint) }
            Text("⌘I 가져오기 · ⌘S 저장 · ⌘B 분할 · J/K/L · M 마커").font(.system(size:9)).foregroundStyle(Color.muted)
        }.padding(.horizontal,18).frame(height:30).background(Color.panel)
    }
}

// Gathers file URLs delivered asynchronously by several drag providers.
final class DropCollector: @unchecked Sendable {
    private let lock = NSLock(); private var urls: [URL] = []; private var remaining: Int
    private let done: ([URL]) -> Void
    init(count: Int, done: @escaping ([URL]) -> Void) { remaining = count; self.done = done }
    func add(_ url: URL?) {
        lock.lock(); if let url { urls.append(url) }; remaining -= 1; let finished = remaining == 0; let result = urls; lock.unlock()
        if finished { done(result) }
    }
}
