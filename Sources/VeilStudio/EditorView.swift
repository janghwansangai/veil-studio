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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size:12,weight:.semibold)).padding(.horizontal,13).padding(.vertical,9)
            .foregroundStyle(primary ? Color.base : Color.ink)
            .background(primary ? Color.mint : Color.raised,in:RoundedRectangle(cornerRadius:7))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
struct SectionLabel: View { var title: String; var detail: String = ""; var body: some View { HStack { Text(title).font(.system(size:12,weight:.semibold)); Spacer(); Text(detail).font(.system(size:10)).foregroundStyle(Color.muted) }.padding(.bottom,6) } }
struct EmptyHint: View { var icon: String; var title: String; var text: String; var body: some View { VStack(spacing:12) { Image(systemName:icon).font(.system(size:29,weight:.light)).foregroundStyle(Color.accent); Text(title).font(.system(size:13,weight:.semibold)); Text(text).font(.system(size:11)).foregroundStyle(Color.muted).multilineTextAlignment(.center).lineSpacing(4) }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity) } }

struct EditorView: View {
    @AppStorage("timelineHeight") private var timelineHeight = 310.0
    @State private var resizeStart: Double?
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(spacing:0) {
            header
            Divider().overlay(Color.white.opacity(0.04))
            HStack(spacing:0) {
                navigation.frame(width:170)
                Divider()
                VStack(spacing:0) {
                    toolBar
                    Divider()
                    HStack(spacing:0) {
                        library.frame(width:222)
                        Divider()
                        VStack(spacing:0) { PreviewPane(); transport }.frame(maxWidth:.infinity,maxHeight:.infinity)
                        Divider()
                        DesignInspector().frame(width:240)
                    }.frame(maxHeight:.infinity)
                    Rectangle().fill(Color.raised).frame(height:9)
                        .overlay(Capsule().fill(Color.muted).frame(width:44,height:3))
                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance:0,coordinateSpace:.global).onChanged { value in
                            if resizeStart == nil { resizeStart = timelineHeight }
                            let maximum = max(240,(NSApp.keyWindow?.contentView?.bounds.height ?? 800)-290)
                            timelineHeight = min(maximum,max(200,(resizeStart ?? 310)-value.translation.height))
                        }.onEnded { _ in resizeStart = nil })
                        .help("위아래로 드래그하여 타임라인 높이 조절")
                    TimelineView().frame(height:timelineHeight)
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
            guard !store.busy, let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier) { data,_ in
                if let data, let url = URL(dataRepresentation:data,relativeTo:nil) { Task { @MainActor in store.load(url) } }
            }; return true
        }
    }
    var header: some View {
        HStack(spacing:12) {
            HStack(spacing:9) { Image(systemName:"circle.hexagongrid.fill").font(.system(size:25)).foregroundStyle(Color.mint); Text("veil").font(.system(size:24,weight:.bold,design:.rounded)); Text("STUDIO").font(.system(size:9,weight:.semibold)).tracking(2).foregroundStyle(Color.muted) }.frame(width:160,alignment:.leading)
            Rectangle().fill(Color.white.opacity(0.09)).frame(width:1,height:22)
            VStack(alignment:.leading,spacing:3) { Text(store.fileName).font(.system(size:12,weight:.medium)).lineLimit(1); Text(store.loaded ? "\(Int(store.project.width)) × \(Int(store.project.height))  ·  \(ByteCountFormatter.string(fromByteCount:store.project.fileSize,countStyle:.file))  ·  원본 보호" : "프라이버시를 위한 영상 · 이미지 편집기").font(.system(size:10)).foregroundStyle(Color.muted) }
            Spacer()
            Label("기기 내 처리",systemImage:"lock.shield").font(.system(size:10)).foregroundStyle(Color.mint).padding(7).background(Color.mint.opacity(0.07),in:Capsule())
            Button { store.saveProject() } label: { Image(systemName:"square.and.arrow.down") }.buttonStyle(ActionStyle()).help("프로젝트 저장 ⌘S").disabled(!store.loaded || store.busy)
            Button { store.exportSheet = true } label: { Label("내보내기",systemImage:"arrow.up.right") }.buttonStyle(ActionStyle(primary:true)).disabled(!store.loaded || store.busy)
        }.padding(.horizontal,20).padding(.top,22).padding(.bottom,16)
    }
    var navigation: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("WORKSPACE").font(.system(size:9,weight:.semibold)).tracking(1.6).foregroundStyle(Color.muted).padding(.horizontal,14).padding(.top,26).padding(.bottom,12)
            ForEach(EditorTab.allCases,id:\.self) { tab in
                Button { store.tab = tab; store.drawMode = false } label: {
                    HStack(spacing:10) { Image(systemName:tab.icon).frame(width:20); Text(tab.rawValue); Spacer(); if store.tab == tab { Circle().fill(Color.accent).frame(width:5,height:5) } }
                        .font(.system(size:12,weight:store.tab == tab ? .semibold : .regular)).padding(.vertical,13).padding(.horizontal,12)
                        .foregroundStyle(store.tab == tab ? Color.accent : Color.muted)
                        .background(store.tab == tab ? Color.accent.opacity(0.10) : .clear,in:RoundedRectangle(cornerRadius:8))
                }.buttonStyle(.plain)
            }
            Rectangle().fill(Color.white.opacity(0.07)).frame(height:1).padding(.vertical,15)
            Button { store.openMedia() } label: { Label("미디어 불러오기",systemImage:"folder.badge.plus").font(.system(size:11)) }.buttonStyle(.plain).padding(12)
            Button { store.openProject() } label: { Label("프로젝트 열기",systemImage:"square.stack").font(.system(size:11)) }.buttonStyle(.plain).padding(12)
            Spacer()
            VStack(alignment:.leading,spacing:10) {
                Image(systemName:"shield.lefthalf.filled").font(.system(size:20)).foregroundStyle(Color.mint)
                Text("안심하고, 표현하세요.").font(.system(size:11,weight:.semibold))
                Text("사진과 영상은 이 Mac에서\n처리됩니다. 원본은 그대로.").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(4)
            }.padding(13).frame(maxWidth:.infinity,alignment:.leading).background(Color.raised.opacity(0.6),in:RoundedRectangle(cornerRadius:10))
            Button { store.helpSheet = true } label: { Label("지원 형식 · 용량 안내",systemImage:"questionmark.circle").font(.system(size:10)) }.buttonStyle(.plain).foregroundStyle(Color.muted).padding(.vertical,15).padding(.horizontal,10)
            Text("제작자 다있쌤 로디").font(.system(size:10,weight:.medium)).foregroundStyle(Color.mint).padding(.horizontal,10)
            Text("VEIL STUDIO   /   0.7.0").font(.system(size:8,weight:.medium,design:.monospaced)).foregroundStyle(Color.muted.opacity(0.65)).padding(.horizontal,10).padding(.bottom,12)
        }.padding(.horizontal,10).background(Color.panel.opacity(0.6))
    }
    var toolBar: some View {
        HStack(spacing:12) {
            Text(store.tab.rawValue).font(.system(size:14,weight:.semibold))
            Text(store.tab == .faces ? "선택한 얼굴에만, 모든 장면에서." : store.tab == .regions ? "가리고 싶은 부분을 직접 지정하세요." : "말을 자막으로. 원하는 문장으로.").font(.system(size:11)).foregroundStyle(Color.muted)
            Spacer()
            if store.tab == .faces {
                if !store.project.isImage { Toggle("분석 후 자동 자막",isOn:$store.autoCaptions).font(.system(size:10)).toggleStyle(.checkbox) }
                Button(action:store.analyze) { Label(store.project.analysisComplete ? "다시 분석" : "얼굴 분석",systemImage:"sparkle.viewfinder") }.buttonStyle(ActionStyle()).disabled(!store.loaded)
            } else if store.tab == .regions {
                Button { store.drawMode.toggle() } label: { Label(store.drawMode ? "그리기 취소" : "영역 그리기",systemImage:"plus.viewfinder") }.buttonStyle(ActionStyle(primary:store.drawMode)).disabled(!store.loaded)
            } else {
                Button(action:store.importSRT) { Text("SRT 가져오기") }.buttonStyle(ActionStyle()).disabled(!store.loaded || store.project.isImage)
                Button(action:{store.transcribe()}) { Label("자동 자막",systemImage:"waveform") }.buttonStyle(ActionStyle()).disabled(!store.loaded || store.project.isImage)
            }
        }.padding(.horizontal,20).frame(height:58)
    }
    @ViewBuilder var library: some View {
        switch store.tab { case .faces: FaceLibrary(); case .regions: RegionLibrary(); case .captions: CaptionLibrary() }
    }
    var transport: some View {
        HStack(spacing:14) {
            Text(store.project.isImage ? "STILL IMAGE" : "EDITED PREVIEW").font(.system(size:8,weight:.semibold,design:.monospaced)).tracking(1).foregroundStyle(Color.muted)
            Spacer()
            if !store.project.isImage {
                Button { store.seek(max(0,store.playhead-5)) } label: { Image(systemName:"gobackward.5") }.buttonStyle(.plain)
                Button(action:store.togglePlay) { Image(systemName:store.playing ? "pause.fill" : "play.fill").font(.system(size:14)).frame(width:32,height:32).background(Color.raised,in:Circle()) }.buttonStyle(.plain)
                Button { store.seek(min(store.project.editedDuration,store.playhead+5)) } label: { Image(systemName:"goforward.5") }.buttonStyle(.plain)
            }
            Spacer()
            Text("\(timecode(store.playhead)) / \(timecode(store.project.editedDuration))").font(.system(size:10,design:.monospaced)).foregroundStyle(Color.muted)
        }.padding(.horizontal,20).frame(height:52).disabled(!store.loaded || store.project.isImage)
    }
    var statusBar: some View {
        HStack(spacing:10) {
            Circle().fill(store.busy ? Color.accent : Color.mint).frame(width:5,height:5)
            Text(store.status).font(.system(size:10)).lineLimit(1)
            if store.busy { ProgressView(value:store.progress).frame(width:150); Text("\(Int(store.progress*100))%").font(.system(size:10,design:.monospaced)); Button("취소",action:store.cancel).buttonStyle(.plain).foregroundStyle(Color.accent) }
            Spacer()
            if let url = store.lastExport { Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.plain).foregroundStyle(Color.mint) }
            Text("⌘O 열기   ·   ⌘S 저장   ·   ⌘B 분할").font(.system(size:9)).foregroundStyle(Color.muted)
        }.padding(.horizontal,20).frame(height:32).background(Color.panel)
    }
}

struct FaceLibrary: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            SectionLabel(title:"감지된 인물 후보",detail:"\(store.project.faces.count)")
            if store.project.faces.isEmpty {
                EmptyHint(icon:"person.crop.square.badge.camera",title:store.project.analysisComplete ? "검출된 얼굴이 없어요" : "어떤 얼굴을 가릴까요?",text:store.project.analysisComplete ? "작거나 가려진 얼굴은 영역 마스크로 보완하세요." : "미디어를 불러오고 얼굴 분석을\n누르면 인물 썸네일이 표시됩니다.")
            } else {
                HStack {
                    Button("전체 선택") { for i in store.project.faces.indices { store.project.faces[i].selected = true } }
                    Spacer()
                    Button("선택 해제") { for i in store.project.faces.indices { store.project.faces[i].selected = false } }
                }.buttonStyle(.plain).font(.system(size:10)).foregroundStyle(Color.muted)
                ScrollView {
                    LazyVStack(spacing:6) {
                        ForEach(store.project.faces) { face in
                            HStack(spacing:9) {
                                Toggle("",isOn:Binding(get:{face.selected},set:{store.toggleFace(face.id,selected:$0)})).labelsHidden().toggleStyle(.checkbox)
                                if let data = face.thumbnail, let image = NSImage(data:data) { Image(nsImage:image).resizable().scaledToFill().frame(width:42,height:46).clipShape(RoundedRectangle(cornerRadius:6)) }
                                VStack(alignment:.leading,spacing:5) {
                                    Text(face.name).font(.system(size:11,weight:.medium)).lineLimit(2)
                                    Text("\(face.samples.count) 프레임").font(.system(size:9)).foregroundStyle(Color.muted)
                                }
                                Spacer(minLength:0)
                            }.padding(8).background(face.selected ? Color.accent.opacity(0.08) : Color.raised.opacity(0.4),in:RoundedRectangle(cornerRadius:8))
                            .onTapGesture { if let t = face.samples.first(where: { store.project.timelineTime(forSource:$0.time) != nil })?.time { store.seekSource(t) } }
                        }
                    }
                }
                Button(action:store.mergeSelected) { Label("선택 후보를 같은 인물로 묶기",systemImage:"person.2") }.buttonStyle(.plain).font(.system(size:10)).disabled(store.project.faces.filter(\.selected).count < 2)
                Text("자동 분류는 인물 후보입니다. 재등장·옆얼굴·가림 장면은 직접 검토하세요.").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(3)
                Button(action:store.applyMasks) { HStack { Image(systemName:"checkmark.shield"); Text("마스킹 적용"); Spacer(); Text("\(store.project.faces.filter(\.selected).count)") } }.buttonStyle(ActionStyle(primary:true))
            }
        }.padding(14).background(Color.panel.opacity(0.4))
    }
}

struct RegionLibrary: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            SectionLabel(title:"직접 지정한 영역",detail:"\(store.project.regions.count)")
            if store.project.regions.isEmpty { EmptyHint(icon:"rectangle.dashed",title:"범위를 직접 그리세요",text:"영역 그리기를 누른 뒤 미리보기에서\n드래그하세요. 얼굴·이름·번호판 등\n원하는 곳을 가릴 수 있습니다.") }
            else {
                ScrollViewReader { proxy in ScrollView { VStack(spacing:8) {
                    ForEach(store.project.regions) { item in
                        let region = store.itemBinding(\.regions,item:item)
                        HStack { Toggle("",isOn:region.enabled).labelsHidden(); Button { store.selectOverlay(region.wrappedValue.id,region:true) } label: { Text(region.wrappedValue.name).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain); Button { store.project.regions.removeAll { $0.id == region.wrappedValue.id } } label: { Image(systemName:"trash") }.buttonStyle(.plain).foregroundStyle(Color.muted) }
                            .font(.system(size:11)).padding(11).background(store.selectedRegion == region.wrappedValue.id ? Color.accent.opacity(0.15) : Color.raised,in:RoundedRectangle(cornerRadius:8))
                    }
                    if let region = store.project.regions.first(where: { $0.id == store.selectedRegion }) { RegionControls(region:store.itemBinding(\.regions,item:region)).id("region-details") }
                } }.onChange(of:store.selectedRegion) { if store.selectedRegion != nil { proxy.scrollTo("region-details",anchor:.top) } }.onAppear { if store.selectedRegion != nil { proxy.scrollTo("region-details",anchor:.top) } } }
            }
            Text("영역 모양과 효과는 오른쪽에서 조정합니다. 키프레임 사이의 위치·크기는 부드럽게 연결됩니다.").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(3)
        }.padding(14).background(Color.panel.opacity(0.4))
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
        VStack(alignment:.leading,spacing:13) {
            Divider().padding(.vertical,5)
            TextField("영역 이름",text:$region.name).textFieldStyle(.roundedBorder)
            SliderRow(label:"가로 위치",value:binding(\.x),range:0...0.95)
            SliderRow(label:"세로 위치 (아래 기준)",value:binding(\.y),range:0...0.95)
            SliderRow(label:"너비",value:binding(\.width),range:0.01...max(0.01,1-region.rect(at:store.overlayTime).x))
            SliderRow(label:"높이",value:binding(\.height),range:0.01...max(0.01,1-region.rect(at:store.overlayTime).y))
            if !store.project.isImage {
                number("시작 (초)",value:$region.start,edge:-1)
                number("종료 (초)",value:$region.end,edge:1)
                Button(action:store.addKeyframe) { Label("현재 위치에 키프레임 저장",systemImage:"diamond") }.buttonStyle(ActionStyle())
                Text("첫 키프레임을 저장한 후, 다른 시간에서 위치·크기를 바꾸면 키프레임이 자동 추가됩니다.").font(.system(size:9)).foregroundStyle(Color.muted)
                ForEach(region.keyframes.sorted(by:{$0.time < $1.time})) { key in
                    HStack { Button(timecode(key.time)) { store.seek(key.time) }.buttonStyle(.plain); Spacer(); Button { region.keyframes.removeAll { $0.id == key.id } } label: { Image(systemName:"xmark") }.buttonStyle(.plain) }.font(.system(size:10))
                }
            }
        }
    }
    func number(_ label: String,value: Binding<Double>,edge: Int) -> some View {
        HStack { Text(label); TimeField(title:label,value:value) { time in
            let r = region
            store.editOverlayTime(id:r.id,region:true,original:TimelineRange(start:r.start,end:r.end),delta:time-(edge < 0 ? r.start : r.end),edge:edge)
        }.frame(width:82,height:22) }.font(.system(size:10))
    }
}
struct CaptionLibrary: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            SectionLabel(title:"수정 가능한 자막",detail:"\(store.project.captions.count)")
            if !store.speechNotes.isEmpty {
                DisclosureGroup("인식 결과 · 검토할 구간 \(store.speechNotes.count)개") {
                    ScrollView { VStack(alignment:.leading,spacing:8) { ForEach(Array(store.speechNotes.enumerated()),id:\.offset) { _,note in Text(note).font(.system(size:10)).fixedSize(horizontal:false,vertical:true) } } }.frame(maxHeight:130)
                }.font(.system(size:10)).foregroundStyle(Color.orange)
            }
            Picker("인식 언어",selection:$store.language) { Text("한국어").tag("ko-KR"); Text("English").tag("en-US"); Text("日本語").tag("ja-JP") }.font(.system(size:10))
            Picker("인식 방식",selection:$store.speechOptions.engine) { ForEach(SpeechEngine.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.font(.system(size:10))
            if store.speechOptions.engine == .whisper {
                HStack {
                    Text(store.speechOptions.whisperModelPath.isEmpty ? "기본 다국어 모델" : URL(fileURLWithPath:store.speechOptions.whisperModelPath).lastPathComponent).lineLimit(1)
                    Button("모델 선택") { let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { store.speechOptions.whisperModelPath = url.path } }
                    Button("기본") { store.speechOptions.whisperModelPath = "" }
                }.font(.system(size:9))
            }
            DisclosureGroup("음성 인식 미세 조정") {
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text("분석 구간"); Picker("분석 구간",selection:$store.speechOptions.chunkSeconds) { Text("10초").tag(10.0); Text("20초").tag(20.0); Text("45초").tag(45.0) }.labelsHidden() }
                    HStack { Text("음성 증폭"); Slider(value:$store.speechOptions.gain,in:0.25...4,step:0.25); Text(String(format:"%.2f×",store.speechOptions.gain)) }
                    Stepper("오디오 트랙 \(store.speechOptions.audioTrack+1)",value:$store.speechOptions.audioTrack,in:0...15)
                    TextField("고유명사·전문용어 (쉼표로 구분)",text:$store.speechOptions.hints).textFieldStyle(.roundedBorder)
                    Button("현재 위치부터 최대 15초 시험 인식") { store.transcribe(testOnly:true) }.buttonStyle(ActionStyle()).disabled(!store.canEditTimeline)
                    Text("작은 목소리는 1.5–2×, 긴 구간이 실패하면 10초로 시험하세요. 증폭은 분석에만 적용됩니다. 음악 제거 기능은 아니며 과증폭이 높으면 배율을 낮추세요. 시험 결과는 기존 자막을 바꾸지 않습니다.").foregroundStyle(Color.muted)
                }.font(.system(size:10))
            }.font(.system(size:11)).disabled(store.busy)
            if store.project.captions.isEmpty { EmptyHint(icon:"text.bubble",title:"말을 담는 또 하나의 방법",text:"자동 자막을 생성하거나 SRT 파일을\n가져오세요. 문장과 표시 시간을\n직접 바꿀 수 있습니다.") }
            else { ScrollViewReader { proxy in ScrollView { LazyVStack(spacing:10) {
                ForEach(store.project.captions) { item in
                    CaptionRow(caption:store.itemBinding(\.captions,item:item))
                }
            } }.onChange(of:store.selectedCaption) { if let id = store.selectedCaption { proxy.scrollTo(id,anchor:.center) } }.onAppear { if let id = store.selectedCaption { proxy.scrollTo(id,anchor:.center) } } } }
            HStack { Button { let a = min(store.overlayTime,max(0,store.project.editedDuration-0.5)); let c = Caption(start:a,end:min(store.project.editedDuration,a+3),text:"새 자막",lane:store.selectedTrack == .captions ? store.selectedLane : nil); store.project.captions.append(c); store.project.separateOverlappingOverlays(); store.selectOverlay(c.id,region:false) } label: { Label("추가",systemImage:"plus") }; Spacer(); Button("SRT 저장",action:store.exportSRT).disabled(store.project.captions.isEmpty) }.buttonStyle(.plain).font(.system(size:11)).disabled(!store.loaded || store.project.isImage)
        }.padding(14).background(Color.panel.opacity(0.4))
    }
}
struct CaptionRow: View {
    @EnvironmentObject var store: EditorStore
    @Binding var caption: Caption
    var body: some View {
                    VStack(alignment:.leading,spacing:8) {
                        HStack { Button(timecode(caption.start)) { store.selectOverlay(caption.id,region:false); store.seek(caption.start) }.buttonStyle(.plain).foregroundStyle(Color.accent); Spacer(); Button { store.project.captions.removeAll {$0.id == caption.id} } label: { Image(systemName:"xmark") }.buttonStyle(.plain).foregroundStyle(Color.muted) }.font(.system(size:10,design:.monospaced))
                        TextField("자막 내용",text:$caption.text,axis:.vertical).lineLimit(2...5).textFieldStyle(.plain).font(.system(size:12))
                        DisclosureGroup("화면 위치 · 자막 폭") {
                            VStack {
                                HStack { Text("가로"); Slider(value:Binding(get:{caption.horizontal ?? 0.5},set:{caption.horizontal = $0}),in:0...1) }
                                HStack { Text("세로"); Slider(value:Binding(get:{caption.vertical ?? 0.055},set:{caption.vertical = $0}),in:0...1) }
                                HStack { Text("폭"); Slider(value:Binding(get:{caption.boxWidth ?? 0.86},set:{caption.boxWidth = $0}),in:0.1...1) }
                                Button("기본 위치") { caption.horizontal = nil; caption.vertical = nil; caption.boxWidth = nil }
                            }.font(.system(size:9))
                        }.font(.system(size:10))

                        HStack {
                            TimeField(title:"시작 (초)",value:$caption.start) { value in store.editOverlayTime(id:caption.id,region:false,original:TimelineRange(start:caption.start,end:caption.end),delta:value-caption.start,edge:-1) }
                            Text("→")
                            TimeField(title:"종료 (초)",value:$caption.end) { value in store.editOverlayTime(id:caption.id,region:false,original:TimelineRange(start:caption.start,end:caption.end),delta:value-caption.end,edge:1) }
                        }.frame(height:22).textFieldStyle(.roundedBorder).font(.system(size:9))
                    }.id(caption.id).padding(12).background(store.selectedCaption == caption.id || store.overlayTime >= caption.start && store.overlayTime < caption.end ? Color.accent.opacity(0.12) : Color.raised,in:RoundedRectangle(cornerRadius:8))
    }
}
struct SliderRow: View {
    var label: String; @Binding var value: Double; var range: ClosedRange<Double> = 0...1
    var body: some View { VStack(spacing:5) { HStack { Text(label); Spacer(); Text("\(Int(value*100))%").foregroundStyle(Color.muted).monospacedDigit() }.font(.system(size:10)); Slider(value:$value,in:range).controlSize(.small) } }
}
