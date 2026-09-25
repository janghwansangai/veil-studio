import SwiftUI

enum DetachedWindow { static let timeline = "timeline", faces = "faces" }

// Timeline in its own window (e.g. on a second monitor).
struct DetachedTimelineView: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Label("타임라인 · 분리된 창",systemImage:"rectangle.split.1x2").font(.system(size:11,weight:.semibold))
                Text(store.fileName).font(.system(size:10)).foregroundStyle(Color.muted).lineLimit(1)
                Spacer()
                Text(frameTimecode(store.playhead,fps:store.project.fps)).font(.system(size:10,design:.monospaced)).foregroundStyle(Color.muted)
                Button { store.togglePlay() } label: { Image(systemName:store.playing ? "pause.fill" : "play.fill") }.buttonStyle(.hover).help("재생 / 일시정지 (Space)")
                Button { dismissWindow(id:DetachedWindow.timeline) } label: { Label("메인 창으로 합치기",systemImage:"rectangle.bottomhalf.inset.filled") }.buttonStyle(ActionStyle()).help("이 창을 닫고 타임라인을 메인 창 아래로 돌려놓습니다")
            }.padding(.horizontal,14).padding(.vertical,8).background(Color.panel)
            if store.loaded { TimelineView(viewport:store.viewport) } else { EmptyHint(icon:"film",title:"프로젝트가 없습니다",text:"메인 창에서 미디어를 불러오세요.") }
        }
        .background(Color.base).foregroundStyle(Color.ink).tint(Color.accent)
        .disabled(store.busy)
        .onAppear { store.timelineDetached = true }
        .onDisappear { store.timelineDetached = false }
    }
}

// Person picker in its own window with enlargeable faces (1–4×).
struct DetachedFacesView: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("faceWindowZoom") private var zoom = 2.0
    @AppStorage("faceWindowSort") private var sort = 0
    @State private var picked = Set<UUID>()
    @State private var filter = 0
    var body: some View {
        let source = store.faceSource
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:10) {
                Picker("미디어",selection:Binding(get:{ source?.id },set:{ store.selectedMedia = $0 })) {
                    ForEach(store.project.media.filter(\.isVisual)) { m in Text(m.name).tag(UUID?.some(m.id)) }
                }.frame(maxWidth:320)
                Picker("분석",selection:$store.analysisMode) { ForEach(FaceAnalysisMode.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.frame(width:190).help(store.analysisMode.detail)
                Button { store.analyze(source?.id) } label: { Label(source?.analysisComplete == true ? "다시 분석" : "얼굴 분석",systemImage:"sparkle.viewfinder") }.buttonStyle(ActionStyle()).disabled(source == nil || store.isAnalyzing(source?.id)).help("이 미디어의 얼굴을 찾아 인물별로 묶습니다")
                Spacer()
                Button { dismissWindow(id:DetachedWindow.faces) } label: { Label("메인 창으로 합치기",systemImage:"sidebar.left") }.buttonStyle(ActionStyle()).help("이 창을 닫고 인물 목록을 메인 창 왼쪽으로 돌려놓습니다")
            }.font(.system(size:11))
            if let task = store.analysisTask(for:source?.id) {
                HStack { ProgressView(value:task.progress).frame(width:220); Text("분석 중 \(Int(task.progress*100))% · \(task.message)").font(.system(size:10)).foregroundStyle(Color.muted).lineLimit(1); Button("취소") { store.cancelBackground(task.id) }.buttonStyle(.hover).help("분석을 멈춥니다") }
            }
            if let source {
                let all = PersonGroup.make(source.faces)
                let groups = sorted(all.filter { filter == 0 || (filter == 1 ? $0.anySelected : !$0.allSelected) })
                HStack(spacing:12) {
                    Text("인물 \(all.count)명 · 가림 \(all.filter(\.anySelected).count)명").font(.system(size:12,weight:.semibold))
                    Picker("",selection:$filter) { Text("전체").tag(0); Text("가리는 인물").tag(1); Text("보이는 인물").tag(2) }.pickerStyle(.segmented).frame(width:250).labelsHidden().help("목록에 보일 인물을 고릅니다")
                    Picker("정렬",selection:$sort) { Text("처음 등장 순").tag(0); Text("오래 나온 순").tag(1) }.frame(width:170).help("인물 정렬 기준")
                    Spacer()
                    Image(systemName:"minus.magnifyingglass").foregroundStyle(Color.muted)
                    Slider(value:$zoom,in:1...4,step:0.5).frame(width:150).help("얼굴 썸네일 크기 \(String(format:"%.1f",zoom))배")
                    Image(systemName:"plus.magnifyingglass").foregroundStyle(Color.muted)
                    Text(String(format:"%.1f×",zoom)).font(.system(size:10,design:.monospaced)).frame(width:34)
                }.font(.system(size:11))
                HStack(spacing:14) {
                    Button("전체 선택") { store.setAllFaces(selected:true) }.help("모든 인물을 가립니다")
                    Button("전체 해제") { store.setAllFaces(selected:false) }.help("모든 인물을 드러냅니다")
                    Button("선택 인물 묶기 \(picked.count > 1 ? "(\(picked.count))" : "")") { store.groupFaces(Set(source.faces.filter { picked.contains($0.groupID) }.map(\.id))); picked = [] }.disabled(picked.count < 2).help("⌘클릭으로 고른 인물들을 한 사람으로 묶습니다")
                    if !picked.isEmpty { Button("고르기 해제") { picked = [] }.help("⌘클릭으로 고른 표시를 지웁니다") }
                    Spacer()
                    Button(action:store.applyMasks) { Label(source.maskApplied ? "마스킹 적용됨 · 다시 적용" : "마스킹 적용",systemImage:"checkmark.shield") }.buttonStyle(ActionStyle(primary:true)).help("체크한 인물의 얼굴에 마스크를 적용합니다")
                }.buttonStyle(.hover).font(.system(size:11))
                if all.isEmpty {
                    EmptyHint(icon:"person.crop.square.badge.camera",title:source.analysisComplete ? "검출된 얼굴이 없어요" : "아직 분석하지 않았습니다",text:"위의 ‘얼굴 분석’을 눌러 주세요.")
                } else {
                    ScrollView {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:62*zoom+24),spacing:10)],spacing:10) {
                            ForEach(groups) { g in PersonCard(group:g,source:source,zoom:zoom,picked:$picked) }
                        }.padding(4)
                    }
                }
                Text("클릭: 처음 등장한 장면으로 이동 · ⌘클릭: 묶을 인물로 고르기 · 체크 해제: 그 인물의 모든 조각이 드러납니다").font(.system(size:10)).foregroundStyle(Color.muted)
            } else { EmptyHint(icon:"photo.on.rectangle",title:"미디어가 없습니다",text:"메인 창에서 영상이나 사진을 가져오세요.") }
        }
        .padding(16).frame(minWidth:620,minHeight:420)
        .background(Color.base).foregroundStyle(Color.ink).tint(Color.accent)
        .onAppear { store.facesDetached = true }
        .onDisappear { store.facesDetached = false }
    }
    func sorted(_ g: [PersonGroup]) -> [PersonGroup] { sort == 1 ? g.sorted { $0.frames > $1.frames } : g }
}

struct PersonCard: View {
    @EnvironmentObject var store: EditorStore
    let group: PersonGroup
    let source: MediaSource
    let zoom: Double
    @Binding var picked: Set<UUID>
    @State private var showMembers = false
    var body: some View {
        let side = 62*zoom
        VStack(spacing:5) {
            ZStack(alignment:.topLeading) {
                if let data = group.members.max(by:{ $0.samples.count < $1.samples.count })?.thumbnail ?? group.members.first?.thumbnail, let image = NSImage(data:data) {
                    Image(nsImage:image).resizable().interpolation(.high).scaledToFill().frame(width:side,height:side*1.1).clipShape(RoundedRectangle(cornerRadius:8))
                } else { RoundedRectangle(cornerRadius:8).fill(Color.raised).frame(width:side,height:side*1.1) }
                Toggle("",isOn:Binding(get:{ group.allSelected },set:{ store.setGroupSelection(group.members.map(\.id),selected:$0) })).labelsHidden().toggleStyle(.checkbox).padding(5)
                    .background(Color.black.opacity(0.45),in:RoundedRectangle(cornerRadius:5)).padding(4).help(group.allSelected ? "가리는 중 · 해제하면 이 인물이 드러납니다" : "드러나는 중 · 체크하면 가립니다")
                if !group.anySelected { Text("보임").font(.system(size:9,weight:.bold)).padding(.horizontal,5).padding(.vertical,2).background(Color.orange,in:Capsule()).foregroundStyle(.black).padding(6).frame(width:side,height:side*1.1,alignment:.bottomTrailing) }
            }
            Text(group.name).font(.system(size:10+min(3,zoom),weight:.medium)).lineLimit(1).frame(width:side+14)
            HStack(spacing:4) {
                Text("\(group.frames)프레임").font(.system(size:9)).foregroundStyle(Color.muted)
                if group.members.count > 1 {
                    Button("조각 \(group.members.count)") { showMembers.toggle() }.buttonStyle(.hover).font(.system(size:9)).foregroundStyle(Color.accent).help("이 인물로 묶인 조각을 하나씩 확인합니다")
                        .popover(isPresented:$showMembers) { MemberList(group:group,source:source).environmentObject(store) }
                }
            }
        }
        .padding(8)
        .background(picked.contains(group.id) ? Color.yellow.opacity(0.18) : group.anySelected ? Color.accent.opacity(0.08) : Color.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
        .overlay(RoundedRectangle(cornerRadius:10).stroke(picked.contains(group.id) ? Color.yellow : .clear,lineWidth:1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true { if picked.contains(group.id) { picked.remove(group.id) } else { picked.insert(group.id) }; return }
            if let t = group.members.compactMap({ $0.samples.first?.time }).min() { store.seekSource(t,source:source.id) }
        }
        .hoverCursor(.pointingHand)
        .help("\(group.name) · 처음 \(timecode(group.first)) · 클릭하면 그 장면으로 이동, ⌘클릭으로 묶을 인물 고르기")
    }
}
struct MemberList: View {
    @EnvironmentObject var store: EditorStore
    let group: PersonGroup
    let source: MediaSource
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Text("\(group.name) · 조각 \(group.members.count)개").font(.system(size:11,weight:.semibold))
            ScrollView { VStack(alignment:.leading,spacing:5) {
                ForEach(group.members) { m in
                    HStack(spacing:8) {
                        Toggle("",isOn:Binding(get:{ m.selected },set:{ store.toggleFaceMember(m.id,selected:$0) })).labelsHidden().toggleStyle(.checkbox).help("이 조각만 가리기/드러내기")
                        if let data = m.thumbnail, let image = NSImage(data:data) { Image(nsImage:image).resizable().scaledToFill().frame(width:48,height:52).clipShape(RoundedRectangle(cornerRadius:5)) }
                        Button("\(timecode(m.samples.first?.time ?? 0))–\(timecode(m.samples.last?.time ?? 0)) · \(m.samples.count)") { if let t = m.samples.first?.time { store.seekSource(t,source:source.id) } }.buttonStyle(.hover).font(.system(size:10,design:.monospaced)).help("이 조각이 처음 나오는 장면으로 이동")
                        Spacer()
                        Button("분리") { store.ungroupFace(m.id) }.buttonStyle(.hover).font(.system(size:10)).help("다른 사람이면 이 조각을 그룹에서 떼어냅니다")
                    }
                }
            } }.frame(maxHeight:360)
        }.padding(12).frame(width:360)
    }
}
