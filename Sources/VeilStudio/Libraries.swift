import SwiftUI

struct SliderRow: View {
    var label: String; @Binding var value: Double; var range: ClosedRange<Double> = 0...1
    var body: some View { VStack(spacing:5) { HStack { Text(label); Spacer(); Text("\(Int(value*100))%").foregroundStyle(Color.muted).monospacedDigit() }.font(.system(size:10)); Slider(value:$value,in:range).controlSize(.small) } }
}

// MARK: Media
struct MediaLibrary: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            SectionLabel(title:"미디어",detail:"\(store.project.media.count)")
            HStack(spacing:6) {
                Button { store.importMedia() } label: { Label("가져오기",systemImage:"plus") }.help("영상·사진·오디오 파일이나 폴더를 프로젝트에 추가합니다 (⌘I)").buttonStyle(ActionStyle(primary:true))
                Button { store.enqueueAllMedia() } label: { Label("모두 작업 목록에",systemImage:"list.bullet.rectangle") }.help("프로젝트의 모든 영상·사진을 얼굴 마스킹 작업 목록에 넣습니다").buttonStyle(ActionStyle()).disabled(!store.project.media.contains(where:\.isVisual))
            }.font(.system(size:10))
            ScrollView {
                LazyVStack(spacing:6) {
                    ForEach(store.project.media) { m in MediaRow(media:m) }
                }
            }
            if let id = store.selectedMedia, let m = store.project.media.first(where:{ $0.id == id }) {
                VStack(alignment:.leading,spacing:6) {
                    Text(m.name).font(.system(size:10,weight:.semibold)).lineLimit(1)
                    if m.isVisual {
                        HStack(spacing:5) {
                            Button("끝에 추가") { store.appendToTimeline(id) }.help("타임라인 끝에 이어 붙이기 (E)")
                            Button("삽입") { store.insertAtPlayhead(id) }.help("재생 위치에 끼워 넣기 (W)")
                            Button("위 트랙") { store.connectAtPlayhead(id) }.help("재생 위치 위 트랙에 연결 · 화면 속 화면 (Q)")
                        }
                    }
                    HStack(spacing:5) {
                        if m.hasAudio { Button("오디오로") { store.addAudio(id) }.help("독립 오디오 트랙에 추가") }
                        if m.isVisual { Button("얼굴") { store.tab = .faces }; Button("작업 목록") { store.enqueue([id]) }.help("이 미디어를 순차 얼굴 마스킹 작업 목록에 넣습니다") }
                    }
                    HStack(spacing:5) {
                        Button("다시 연결") { store.relinkMedia(id) }.help("옮겨지거나 이름이 바뀐 원본 파일의 새 위치를 지정합니다")
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:m.path)]) }.help("원본 파일 위치를 Finder에서 엽니다").disabled(store.offlineMedia.contains(id))
                        Button("제거") { store.removeMedia(id) }.help("프로젝트에서 이 미디어를 뺍니다. 원본 파일은 지워지지 않습니다").foregroundStyle(.red)
                    }
                }.buttonStyle(ActionStyle()).font(.system(size:9)).padding(8).background(Color.raised.opacity(0.4),in:RoundedRectangle(cornerRadius:8))
            }
            Text("미디어를 타임라인으로 끌어다 놓을 수도 있습니다. 원본 파일은 변경하지 않습니다.").font(.system(size:9)).foregroundStyle(Color.muted)
        }.padding(12).frame(maxHeight:.infinity,alignment:.top).background(Color.panel.opacity(0.4))
    }
}
struct MediaRow: View {
    @EnvironmentObject var store: EditorStore
    let media: MediaSource
    var body: some View {
        let _ = store.thumbnailRevision
        let offline = store.offlineMedia.contains(media.id), changed = store.changedMedia.contains(media.id)
        let uses = store.project.clips.filter { store.project.sourceID(of:$0) == media.id }.count + store.project.audioClips.filter { $0.source == media.id }.count
        HStack(spacing:8) {
            ZStack {
                RoundedRectangle(cornerRadius:5).fill(Color.black)
                if let poster = store.thumbnails.poster(media) { Image(decorative:poster,scale:1).resizable().scaledToFit() }
                else { Image(systemName:media.kind == .audio ? "music.note" : media.kind == .image ? "photo" : "film").foregroundStyle(Color.muted) }
            }.frame(width:56,height:34).clipShape(RoundedRectangle(cornerRadius:5))
            VStack(alignment:.leading,spacing:3) {
                Text(media.name).font(.system(size:10,weight:.medium)).lineLimit(1)
                Text(detail).font(.system(size:8)).foregroundStyle(Color.muted).lineLimit(1)
                HStack(spacing:4) {
                    if offline { badge("없음",.red) } else if changed { badge("변경됨",.orange) }
                    if uses > 0 { badge("사용 \(uses)",Color.accent) }
                    if media.isVisual { media.analysisComplete ? badge("인물 \(Set(media.faces.map(\.groupID)).count)",Color.mint) : badge("미분석",Color.muted) }
                    if media.maskApplied { badge("마스킹",Color.mint) }
                }
            }
            Spacer(minLength:0)
        }.padding(6).background(store.selectedMedia == media.id ? Color.accent.opacity(0.16) : Color.raised.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
            .contentShape(Rectangle())
            .onTapGesture(count:2) { store.selectedMedia = media.id; if media.isVisual { store.appendToTimeline(media.id) } else { store.addAudio(media.id) } }
            .onTapGesture { store.selectedMedia = media.id }
            .draggable("media:\(media.id.uuidString)")
            .contextMenu {
                if media.isVisual {
                    Button("타임라인 끝에 추가") { store.appendToTimeline(media.id) }
                    Button("재생 위치에 삽입") { store.insertAtPlayhead(media.id) }
                    Button("위 트랙에 연결") { store.connectAtPlayhead(media.id) }
                    Button("얼굴 분석") { store.selectedMedia = media.id; store.analyze(media.id) }
                    Button("작업 목록에 추가") { store.enqueue([media.id]) }
                }
                if media.hasAudio { Button("독립 오디오로 추가") { store.addAudio(media.id) } }
                Divider()
                Button("다시 연결…") { store.relinkMedia(media.id) }
                Button("프로젝트에서 제거") { store.removeMedia(media.id) }
            }
            .help(media.path)
    }
    var detail: String {
        switch media.kind {
        case .image: return "사진 · \(Int(media.width))×\(Int(media.height))"
        case .audio: return "오디오 · \(timecode(media.duration))"
        case .video: return "\(timecode(media.duration)) · \(Int(media.width))×\(Int(media.height)) · \(Int(media.fps.rounded()))fps" + (media.hasAudio ? "" : " · 무음")
        }
    }
    func badge(_ text: String,_ color: Color) -> some View { Text(text).font(.system(size:8,weight:.medium)).padding(.horizontal,5).padding(.vertical,1).background(color.opacity(0.18),in:Capsule()).foregroundStyle(color) }
}

// MARK: Faces
struct FaceLibrary: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var expanded = Set<UUID>()
    @State private var picked = Set<UUID>()
    var body: some View {
        let source = store.faceSource
        VStack(alignment:.leading,spacing:10) {
            if store.project.media.filter(\.isVisual).count > 1 {
                Picker("미디어",selection:Binding(get:{ source?.id },set:{ store.selectedMedia = $0 })) {
                    ForEach(store.project.media.filter(\.isVisual)) { m in Text(m.name).tag(UUID?.some(m.id)) }
                }.font(.system(size:10))
            }
            HStack {
                Button { openWindow(id:DetachedWindow.faces) } label: { Label(store.facesDetached ? "인물 선택 창 보기" : "인물 목록 창으로 분리",systemImage:"macwindow.on.rectangle") }.buttonStyle(ActionStyle()).font(.system(size:10)).help("인물 목록을 큰 별도 창으로 엽니다. 다른 모니터로 옮기고 얼굴을 최대 4배로 키울 수 있습니다 (⌥⌘P)")
                if store.facesDetached { Button("합치기") { dismissWindow(id:DetachedWindow.faces) }.buttonStyle(.hover).font(.system(size:10)).help("분리된 인물 선택 창을 닫습니다") }
            }
            Picker("분석 모드",selection:$store.analysisMode) { ForEach(FaceAnalysisMode.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.font(.system(size:10)).help(store.analysisMode.detail)
            Text(store.analysisMode.detail).font(.system(size:9)).foregroundStyle(Color.muted)
            if let task = store.analysisTask(for:source?.id) {
                VStack(alignment:.leading,spacing:5) {
                    HStack { ProgressView().controlSize(.mini); Text("얼굴 분석 중 \(Int(task.progress*100))%").font(.system(size:10,weight:.semibold)); Spacer(); Button("취소") { store.cancelBackground(task.id) }.buttonStyle(.hover).font(.system(size:10)).help("분석을 멈춥니다. 기존 결과는 유지됩니다") }
                    ProgressView(value:task.progress)
                    Text("분석하는 동안 다른 편집을 계속할 수 있습니다. 끝나면 이 목록이 새 결과로 바뀝니다.").font(.system(size:9)).foregroundStyle(Color.muted)
                }.padding(8).background(Color.accent.opacity(0.1),in:RoundedRectangle(cornerRadius:8))
            }
            if let source {
                let groups = PersonGroup.make(source.faces)
                SectionLabel(title:"인물",detail:source.analysisComplete ? "\(groups.count)명 · 선택 \(groups.filter(\.anySelected).count)" : "미분석")
                if source.faces.isEmpty {
                    EmptyHint(icon:"person.crop.square.badge.camera",title:source.analysisComplete ? "검출된 얼굴이 없어요" : "어떤 얼굴을 가릴까요?",text:source.analysisComplete ? "작거나 가려진 얼굴은 영역 마스크로\n보완하세요. 정밀 모드로 다시 분석해 보세요." : "‘얼굴 분석’을 누르면 인물별\n썸네일이 표시됩니다.")
                } else {
                    HStack {
                        Button("전체 선택") { store.setAllFaces(selected:true) }
                        Button("전체 해제") { store.setAllFaces(selected:false) }
                        Spacer()
                        Button("묶기 \(picked.count > 1 ? "(\(picked.count))" : "")") { store.groupFaces(Set(source.faces.filter { picked.contains($0.groupID) }.map(\.id))); picked = [] }.disabled(picked.count < 2).help("⌘클릭으로 고른 인물을 한 사람으로 묶기")
                    }.buttonStyle(.hover).font(.system(size:10)).foregroundStyle(Color.muted)
                    if store.facesDetached {
                        EmptyHint(icon:"macwindow.on.rectangle",title:"인물 목록이 별도 창에 있습니다",text:"‘인물 선택’ 창에서 얼굴을 크게 보며\n선택·묶기를 할 수 있습니다.").frame(maxHeight:200)
                    } else {
                    ScrollView {
                        LazyVStack(spacing:6) {
                            ForEach(groups) { group in PersonRow(group:group,source:source,expanded:$expanded,picked:$picked) }
                        }
                    }
                    }
                    if !source.reviewRanges.isEmpty {
                        DisclosureGroup("검토 권장 구간 \(source.reviewRanges.count)곳") {
                            ScrollView { VStack(alignment:.leading,spacing:4) {
                                ForEach(Array(source.reviewRanges.enumerated()),id:\.offset) { _,range in
                                    Button("\(timecode(range.start)) – \(timecode(range.end))") { store.seekSource(range.start,source:source.id) }.help("이 구간으로 이동해 얼굴이 가려졌는지 확인하세요").buttonStyle(.hover).font(.system(size:10,design:.monospaced)).foregroundStyle(.orange)
                                }
                            } }.frame(maxHeight:110)
                        }.font(.system(size:10)).foregroundStyle(.orange).help("얼굴이 있었는데 검출이 끊긴 것으로 보이는 구간입니다. 재생해 확인하고 필요하면 영역 마스크를 추가하세요.")
                    }
                    Text("같은 시간에 함께 나온 얼굴은 서로 다른 인물로 둡니다. 선택을 해제하면 그 인물의 모든 조각이 드러나므로 썸네일을 꼭 확인하세요.").font(.system(size:9)).foregroundStyle(Color.muted).lineSpacing(3)
                    Button(action:store.applyMasks) { HStack { Image(systemName:"checkmark.shield"); Text(source.maskApplied ? "마스킹 적용됨 · 다시 적용" : "마스킹 적용"); Spacer(); Text("\(groups.filter(\.anySelected).count)명") } }.help("체크한 인물의 얼굴에 마스크를 적용합니다. 미리보기와 출력에 반영됩니다").buttonStyle(ActionStyle(primary:true))
                }
            } else { EmptyHint(icon:"photo.on.rectangle",title:"미디어가 없습니다",text:"영상이나 사진을 가져오세요.") }
        }.padding(12).frame(maxHeight:.infinity,alignment:.top).background(Color.panel.opacity(0.4))
    }
}
struct PersonGroup: Identifiable {
    var id: UUID
    var name: String
    var members: [FaceTrack]
    var anySelected: Bool { members.contains(where:\.selected) }
    var allSelected: Bool { members.allSatisfy(\.selected) }
    var frames: Int { members.reduce(0) { $0+$1.samples.count } }
    var first: Double { members.compactMap { $0.samples.first?.time }.min() ?? 0 }
    static func make(_ faces: [FaceTrack]) -> [PersonGroup] {
        var order: [UUID] = []; var map: [UUID:[FaceTrack]] = [:]
        for f in faces {
            let key = f.groupID
            if map[key] == nil { order.append(key) }; map[key, default:[]].append(f)
        }
        return order.compactMap { key in map[key].map { PersonGroup(id:key,name:$0.first?.name ?? "인물",members:$0) } }.sorted { $0.first < $1.first }
    }
}
struct PersonRow: View {
    @EnvironmentObject var store: EditorStore
    let group: PersonGroup
    let source: MediaSource
    @Binding var expanded: Set<UUID>
    @Binding var picked: Set<UUID>
    var onSeek: ((Double) -> Void)? = nil
    func go(_ t: Double) { if let onSeek { onSeek(t) } else { store.seekSource(t,source:source.id) } }
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(spacing:8) {
                Toggle("",isOn:Binding(get:{ group.allSelected },set:{ v in store.setGroupSelection(group.members.map(\.id),selected:v) })).labelsHidden().toggleStyle(.checkbox)
                    .overlay { if group.anySelected && !group.allSelected { Rectangle().fill(Color.accent).frame(width:7,height:2).allowsHitTesting(false) } }
                if let data = group.members.first(where:{ $0.thumbnail != nil })?.thumbnail, let image = NSImage(data:data) { Image(nsImage:image).resizable().scaledToFill().frame(width:40,height:44).clipShape(RoundedRectangle(cornerRadius:6)) }
                VStack(alignment:.leading,spacing:3) {
                    TextField("이름",text:Binding(get:{ group.name },set:{ store.renameFaceGroup(group.id,name:$0) })).textFieldStyle(.plain).font(.system(size:11,weight:.medium))
                    Text("\(group.frames) 프레임" + (group.members.count > 1 ? " · 조각 \(group.members.count)" : "") + " · \(timecode(group.first))").font(.system(size:9)).foregroundStyle(Color.muted)
                }
                Spacer(minLength:0)
                if group.members.count > 1 {
                    Button { if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) } } label: { Image(systemName:expanded.contains(group.id) ? "chevron.up" : "chevron.down") }.help("이 인물의 조각을 펼쳐 봅니다").buttonStyle(.hover).foregroundStyle(Color.muted)
                }
            }
            if expanded.contains(group.id) {
                ForEach(group.members) { m in
                    HStack(spacing:6) {
                        Toggle("",isOn:Binding(get:{ m.selected },set:{ store.toggleFaceMember(m.id,selected:$0) })).labelsHidden().toggleStyle(.checkbox)
                        if let data = m.thumbnail, let image = NSImage(data:data) { Image(nsImage:image).resizable().scaledToFill().frame(width:26,height:28).clipShape(RoundedRectangle(cornerRadius:4)) }
                        Button("\(timecode(m.samples.first?.time ?? 0))–\(timecode(m.samples.last?.time ?? 0)) · \(m.samples.count)") { if let t = m.samples.first?.time { go(t) } }.help("이 조각이 처음 나오는 위치로 이동").buttonStyle(.hover).font(.system(size:9,design:.monospaced))
                        Spacer(minLength:0)
                        Button("분리") { store.ungroupFace(m.id) }.help("이 조각을 인물 그룹에서 떼어 따로 관리합니다").buttonStyle(.hover).font(.system(size:9)).foregroundStyle(Color.muted)
                    }.padding(.leading,24)
                }
            }
        }.padding(7)
            .background(picked.contains(group.id) ? Color.yellow.opacity(0.16) : group.anySelected ? Color.accent.opacity(0.08) : Color.raised.opacity(0.4),in:RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(picked.contains(group.id) ? Color.yellow.opacity(0.7) : .clear,lineWidth:1))
            .contentShape(Rectangle())
            .onTapGesture {
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true { if picked.contains(group.id) { picked.remove(group.id) } else { picked.insert(group.id) }; return }
                if let t = group.members.compactMap({ $0.samples.first?.time }).min() { go(t) }
            }
            .help("클릭: 처음 등장 위치로 이동 · ⌘클릭: 묶을 인물로 선택")
    }
}

// MARK: Regions
struct RegionLibrary: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            SectionLabel(title:"직접 지정한 영역",detail:"\(store.project.regions.count)")
            if store.project.regions.isEmpty { EmptyHint(icon:"rectangle.dashed",title:"범위를 직접 그리세요",text:"영역 그리기를 누른 뒤 미리보기에서\n드래그하세요. 얼굴·이름·번호판 등\n원하는 곳을 가릴 수 있습니다.") }
            else {
                ScrollViewReader { proxy in ScrollView { VStack(spacing:8) {
                    ForEach(store.project.regions) { item in
                        let region = store.itemBinding(\.regions,item:item,coalesce:"region")
                        HStack { Toggle("",isOn:region.enabled).labelsHidden(); Button { store.selectOverlay(region.wrappedValue.id,region:true) } label: { Text(region.wrappedValue.name).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.hover); Button { store.project.regions.removeAll { $0.id == region.wrappedValue.id } } label: { Image(systemName:"trash") }.help("이 영역을 삭제합니다").buttonStyle(.hover).foregroundStyle(Color.muted) }
                            .font(.system(size:11)).padding(10).background(store.selectedRegion == region.wrappedValue.id ? Color.accent.opacity(0.15) : Color.raised,in:RoundedRectangle(cornerRadius:8))
                    }
                    if let region = store.project.regions.first(where: { $0.id == store.selectedRegion }) { RegionControls(region:store.itemBinding(\.regions,item:region,coalesce:"region")).id("region-details") }
                } }.onChange(of:store.selectedRegion) { if store.selectedRegion != nil { proxy.scrollTo("region-details",anchor:.top) } } }
            }
            Text("영역 모양과 효과는 오른쪽 ‘마스크’ 탭에서 조정합니다. 키프레임 사이의 위치·크기는 부드럽게 연결됩니다.").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(3)
        }.padding(12).frame(maxHeight:.infinity,alignment:.top).background(Color.panel.opacity(0.4))
    }
}
struct RegionControls: View {
    @EnvironmentObject var store: EditorStore; @Binding var region: ManualRegion
    func binding(_ key: WritableKeyPath<NormalRect,Double>) -> Binding<Double> {
        Binding(get:{region.rect(at:store.overlayTime)[keyPath:key]},set:{ value in
            var updated = region
            var rect = updated.rect(at:store.overlayTime); rect[keyPath:key] = value
            rect.width = min(rect.width,1-rect.x); rect.height = min(rect.height,1-rect.y)
            updated.rect = rect
            if !updated.keyframes.isEmpty {
                updated.keyframes.removeAll { abs($0.time-store.overlayTime) < 0.02 }
                updated.keyframes.append(RegionKeyframe(time:store.overlayTime,rect:rect))
            }
            region = updated
        })
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Divider().padding(.vertical,4)
            TextField("영역 이름",text:$region.name).textFieldStyle(.roundedBorder)
            SliderRow(label:"가로 위치",value:binding(\.x),range:0...0.95)
            SliderRow(label:"세로 위치 (아래 기준)",value:binding(\.y),range:0...0.95)
            SliderRow(label:"너비",value:binding(\.width),range:0.01...max(0.01,1-region.rect(at:store.overlayTime).x))
            SliderRow(label:"높이",value:binding(\.height),range:0.01...max(0.01,1-region.rect(at:store.overlayTime).y))
            if !store.project.isImage {
                number("시작 (초)",edge:-1)
                number("종료 (초)",edge:1)
                Button(action:store.addKeyframe) { Label("현재 위치에 키프레임 저장",systemImage:"diamond") }.help("지금 시간의 영역 위치·크기를 키프레임으로 기록합니다").buttonStyle(ActionStyle())
                Text("첫 키프레임을 저장한 후, 다른 시간에서 위치·크기를 바꾸면 키프레임이 자동 추가됩니다.").font(.system(size:9)).foregroundStyle(Color.muted)
                ForEach(region.keyframes.sorted(by:{$0.time < $1.time})) { key in
                    HStack { Button(timecode(key.time)) { store.seek(key.time) }.buttonStyle(.hover); Spacer(); Button { region.keyframes.removeAll { $0.id == key.id } } label: { Image(systemName:"xmark") }.help("이 키프레임을 지웁니다").buttonStyle(.hover) }.font(.system(size:10))
                }
            }
        }
    }
    func number(_ label: String,edge: Int) -> some View {
        HStack { Text(label); TimeField(title:label,value:edge < 0 ? $region.start : $region.end) { time in
            let r = region
            store.editOverlayTime(id:r.id,kind:.regions,original:TimelineRange(start:r.start,end:r.end),delta:time-(edge < 0 ? r.start : r.end),edge:edge)
        }.frame(width:82,height:22) }.font(.system(size:10))
    }
}

// MARK: Captions
struct CaptionLibrary: View {
    @EnvironmentObject var store: EditorStore
    @State private var reviewOnly = false
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            SectionLabel(title:"자막",detail:"\(store.project.captions.count)")
            if !store.speechNotes.isEmpty {
                DisclosureGroup("인식 결과 · 참고 \(store.speechNotes.count)개") {
                    ScrollView { VStack(alignment:.leading,spacing:6) { ForEach(Array(store.speechNotes.enumerated()),id:\.offset) { _,note in Text(note).font(.system(size:10)).fixedSize(horizontal:false,vertical:true) } } }.frame(maxHeight:120)
                }.font(.system(size:10)).foregroundStyle(Color.orange)
            }
            DisclosureGroup("인식 설정") {
                VStack(alignment:.leading,spacing:8) {
                    Picker("언어",selection:$store.language) { Text("한국어").tag("ko-KR"); Text("English").tag("en-US"); Text("日本語").tag("ja-JP"); Text("자동 감지 (Whisper)").tag("auto") }
                    Picker("인식 엔진",selection:$store.speechOptions.engine) { ForEach(SpeechEngine.allCases.filter(\.available),id:\.self) { Text($0.rawValue).tag($0) } }
                    Text(store.speechOptions.engine.detail).foregroundStyle(Color.muted)
                    if store.speechOptions.engine == .whisper || store.speechOptions.engine == .whisperFast {
                        Toggle("음성 구간만 인식 (음악·무음의 가짜 문장 억제)",isOn:$store.speechOptions.voiceDetection)
                        HStack {
                            Text(store.speechOptions.whisperModelPath.isEmpty ? "기본 모델" : URL(fileURLWithPath:store.speechOptions.whisperModelPath).lastPathComponent).lineLimit(1)
                            Button("모델 선택") { let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { store.speechOptions.whisperModelPath = url.path } }.help("whisper.cpp 형식의 다른 모델 파일(.bin)을 고릅니다")
                            Button("기본") { store.speechOptions.whisperModelPath = "" }.help("앱에 포함된 기본 모델로 되돌립니다")
                        }
                    }
                    Stepper("한 줄 최대 \(store.speechOptions.maxLineChars)자",value:$store.speechOptions.maxLineChars,in:8...40)
                    Stepper("최대 \(store.speechOptions.maxLines)줄",value:$store.speechOptions.maxLines,in:1...3)
                    HStack { Text("음성 증폭"); Slider(value:$store.speechOptions.gain,in:0.25...4,step:0.25); Text(String(format:"%.2f×",store.speechOptions.gain)) }
                    Stepper("오디오 트랙 \(store.speechOptions.audioTrack+1)",value:$store.speechOptions.audioTrack,in:0...15)
                    TextField("고유명사·전문용어 (쉼표로 구분)",text:$store.speechOptions.hints).textFieldStyle(.roundedBorder)
                    if store.speechOptions.engine == .apple { HStack { Text("분석 구간"); Picker("분석 구간",selection:$store.speechOptions.chunkSeconds) { Text("10초").tag(10.0); Text("20초").tag(20.0); Text("45초").tag(45.0) }.labelsHidden() } }
                    HStack {
                        Button("현재 위치 15초 시험") { store.transcribe(testOnly:true) }.help("재생 위치부터 최대 15초만 인식해 결과를 미리 봅니다. 자막은 바뀌지 않습니다").buttonStyle(ActionStyle()).disabled(!store.canEditTimeline)
                        Button("처음부터 다시 인식") { store.transcribe(force:true) }.help("기억해 둔 인식 결과를 쓰지 않고 전체를 다시 인식합니다").buttonStyle(ActionStyle()).disabled(!store.canEditTimeline)
                    }
                    Text("같은 설정으로 인식한 구간은 기억해 두었다가 다시 쓰므로, 컷을 바꾼 뒤 ‘자동 자막’을 누르면 새 구간만 인식합니다. 시험 인식은 기존 자막을 바꾸지 않습니다.").foregroundStyle(Color.muted)
                }.font(.system(size:10))
            }.font(.system(size:11)).disabled(store.busy)
            let review = store.project.captions.filter { ($0.confidence ?? 1) < SpeechOptions.reviewConfidence }
            if !review.isEmpty { Toggle("확인이 필요한 자막만 보기 (\(review.count))",isOn:$reviewOnly).font(.system(size:10)).foregroundStyle(.yellow) }
            if store.project.captions.isEmpty { EmptyHint(icon:"text.bubble",title:"말을 담는 또 하나의 방법",text:"자동 자막을 생성하거나 SRT 파일을\n가져오세요. 문장과 표시 시간을\n직접 바꿀 수 있습니다.") }
            else { ScrollViewReader { proxy in ScrollView { LazyVStack(spacing:8) {
                ForEach(reviewOnly ? review : store.project.captions) { item in
                    CaptionRow(caption:store.itemBinding(\.captions,item:item,coalesce:"caption"))
                }
            } }.onChange(of:store.selectedCaption) { if let id = store.selectedCaption { proxy.scrollTo(id,anchor:.center) } } } }
            HStack { Button { let a = min(store.playhead,max(0,store.project.editedDuration-0.5)); let c = Caption(start:a,end:min(store.project.editedDuration,a+3),text:"새 자막",lane:store.selectedTrack == .captions ? store.selectedLane : nil); store.project.captions.append(c); store.project.separateOverlappingOverlays(); store.selectOverlay(c.id,region:false) } label: { Label("추가",systemImage:"plus") }; Spacer(); Button("SRT 저장",action:store.exportSRT).help("편집한 자막을 SRT 파일로 저장합니다").disabled(store.project.captions.isEmpty) }.buttonStyle(.hover).font(.system(size:11)).disabled(!store.loaded || store.project.isImage)
        }.padding(12).frame(maxHeight:.infinity,alignment:.top).background(Color.panel.opacity(0.4))
    }
}
struct CaptionRow: View {
    @EnvironmentObject var store: EditorStore
    @Binding var caption: Caption
    var body: some View {
        let low = (caption.confidence ?? 1) < SpeechOptions.reviewConfidence
        VStack(alignment:.leading,spacing:7) {
            HStack {
                Button(timecode(caption.start)) { store.selectOverlay(caption.id,region:false); store.seek(caption.start) }.help("이 자막 위치로 이동").buttonStyle(.hover).foregroundStyle(Color.accent)
                if low { Label("확인 필요",systemImage:"exclamationmark.circle.fill").foregroundStyle(.yellow).font(.system(size:9)) }
                Spacer()
                Button { store.project.captions.removeAll {$0.id == caption.id} } label: { Image(systemName:"xmark") }.help("이 자막을 삭제합니다").buttonStyle(.hover).foregroundStyle(Color.muted)
            }.font(.system(size:10,design:.monospaced))
            TextField("자막 내용",text:Binding(get:{ caption.text },set:{ caption.text = $0; caption.confidence = nil }),axis:.vertical).lineLimit(1...5).textFieldStyle(.plain).font(.system(size:12))
            DisclosureGroup("화면 위치 · 자막 폭") {
                VStack {
                    HStack { Text("가로"); Slider(value:Binding(get:{caption.horizontal ?? 0.5},set:{caption.horizontal = $0}),in:0...1) }
                    HStack { Text("세로"); Slider(value:Binding(get:{caption.vertical ?? 0.055},set:{caption.vertical = $0}),in:0...1) }
                    HStack { Text("폭"); Slider(value:Binding(get:{caption.boxWidth ?? 0.86},set:{caption.boxWidth = $0}),in:0.1...1) }
                    Button("기본 위치") { caption.horizontal = nil; caption.vertical = nil; caption.boxWidth = nil }.help("자막 위치와 폭을 기본값으로 되돌립니다")
                }.font(.system(size:9))
            }.font(.system(size:10))
            HStack {
                TimeField(title:"시작 (초)",value:$caption.start) { value in store.editOverlayTime(id:caption.id,kind:.captions,original:TimelineRange(start:caption.start,end:caption.end),delta:value-caption.start,edge:-1) }
                Text("→")
                TimeField(title:"종료 (초)",value:$caption.end) { value in store.editOverlayTime(id:caption.id,kind:.captions,original:TimelineRange(start:caption.start,end:caption.end),delta:value-caption.end,edge:1) }
            }.frame(height:22).textFieldStyle(.roundedBorder).font(.system(size:9))
        }.id(caption.id).padding(10)
            .background(store.selectedCaption == caption.id || store.overlayTime >= caption.start && store.overlayTime < caption.end ? Color.accent.opacity(0.12) : Color.raised,in:RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(low ? Color.yellow.opacity(0.5) : .clear,lineWidth:1))
    }
}

// MARK: Titles
struct TitleLibrary: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            SectionLabel(title:"타이틀",detail:"\(store.project.titles.count)")
            Button { store.addTitle() } label: { Label("재생 위치에 타이틀 추가",systemImage:"plus") }.help("재생 위치에 3초짜리 타이틀을 추가합니다 (⌃T)").buttonStyle(ActionStyle(primary:true)).disabled(!store.canEditTimeline)
            if store.project.titles.isEmpty { EmptyHint(icon:"textformat",title:"화면에 글자를 올려 보세요",text:"제목, 이름, 설명 문구를 원하는\n위치와 시간에 표시합니다.\n자막과는 따로 편집됩니다.") }
            else {
                ScrollView { LazyVStack(spacing:6) {
                    ForEach(store.project.titles.sorted { $0.start < $1.start }) { t in
                        HStack {
                            Button(timecode(t.start)) { store.selectTitle(t.id); store.seek(t.start) }.help("이 타이틀 위치로 이동").buttonStyle(.hover).font(.system(size:10,design:.monospaced)).foregroundStyle(Color.accent)
                            Text(t.text.replacingOccurrences(of:"\n",with:" ")).lineLimit(1).font(.system(size:11))
                            Spacer()
                            Button { store.project.titles.removeAll { $0.id == t.id } } label: { Image(systemName:"trash") }.help("이 타이틀을 삭제합니다").buttonStyle(.hover).foregroundStyle(Color.muted)
                        }.padding(9).background(store.selectedTitle == t.id ? Color.accent.opacity(0.15) : Color.raised,in:RoundedRectangle(cornerRadius:8))
                            .contentShape(Rectangle()).onTapGesture { store.selectTitle(t.id); store.seek(t.start) }
                    }
                } }
            }
            Text("선택한 타이틀은 오른쪽 ‘클립’ 탭에서 글자·크기·색·위치를 바꾸고, 미리보기에서 끌어 옮길 수 있습니다.").font(.system(size:9)).foregroundStyle(Color.muted)
        }.padding(12).frame(maxHeight:.infinity,alignment:.top).background(Color.panel.opacity(0.4))
    }
}
