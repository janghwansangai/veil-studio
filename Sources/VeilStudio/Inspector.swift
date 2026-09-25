import SwiftUI

struct InspectorPanel: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(spacing:0) {
            Picker("",selection:$store.inspector) { ForEach(InspectorTab.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            ScrollView {
                Group {
                    switch store.inspector {
                    case .clip: ClipInspector()
                    case .mask: DesignInspector()
                    case .output: OutputInspector()
                    }
                }.padding(14)
            }
        }.background(Color.panel.opacity(0.4)).disabled(!store.loaded)
    }
}

// Numeric row with slider, value text and reset. `coalesce` keeps one drag as one undo step.
struct ValueRow: View {
    var label: String; var value: Binding<Double>; var range: ClosedRange<Double>; var format: String = "%.2f"; var neutral: Double? = nil
    var body: some View {
        VStack(spacing:4) {
            HStack {
                Text(label); Spacer()
                Text(String(format:format,value.wrappedValue)).foregroundStyle(Color.muted).monospacedDigit()
                if let neutral, abs(value.wrappedValue-neutral) > 0.0001 { Button { value.wrappedValue = neutral } label: { Image(systemName:"arrow.counterclockwise") }.buttonStyle(.hover).foregroundStyle(Color.muted).help("기본값") }
            }.font(.system(size:10))
            Slider(value:value,in:range).controlSize(.small)
        }
    }
}

struct ClipInspector: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        if store.selectedTrack == .titles, let t = store.project.titles.first(where:{ $0.id == store.selectedTitle }) { TitleInspector(title:store.itemBinding(\.titles,item:t,coalesce:"title")) }
        else if store.selectedTrack == .music, let a = store.project.audioClips.first(where:{ $0.id == store.selectedAudioClip }) { AudioClipInspector(clip:store.itemBinding(\.audioClips,item:a,coalesce:"audio")) }
        else if let id = store.selectedClip, let clip = store.project.clips.first(where:{ $0.id == id }), store.selectedTrack.linkedToVideo { VideoClipInspector(clip:clip) }
        else { EmptyHint(icon:"cursorarrow.click",title:"클립을 선택하세요",text:"타임라인에서 영상·오디오·타이틀을\n클릭하면 속도, 전환, 화면, 색,\n소리를 여기서 조절합니다.").frame(height:260) }
    }
}

struct VideoClipInspector: View {
    @EnvironmentObject var store: EditorStore
    var clip: Clip
    func bind<T: Equatable>(_ key: String, get: @escaping (Clip) -> T, set: @escaping (inout Clip, T) -> Void) -> Binding<T> {
        Binding(get:{ store.project.clips.first(where:{ $0.id == clip.id }).map(get) ?? get(clip) },
                set:{ value in store.updateClips(coalesce:key) { c in set(&c,value) } })
    }
    func transform(_ key: WritableKeyPath<ClipTransform,Double>, _ name: String) -> Binding<Double> {
        bind(name,get:{ ($0.transform ?? ClipTransform())[keyPath:key] },set:{ c,v in var t = c.transform ?? ClipTransform(); t[keyPath:key] = v; c.transform = t.isIdentity ? nil : t })
    }
    func color(_ key: WritableKeyPath<ColorAdjust,Double>, _ name: String) -> Binding<Double> {
        bind(name,get:{ ($0.color ?? ColorAdjust())[keyPath:key] },set:{ c,v in var a = c.color ?? ColorAdjust(); a[keyPath:key] = v; c.color = a.isIdentity ? nil : a })
    }
    var body: some View {
        let source = store.project.source(clip.source)
        let entry = store.project.timeline.first(where:{ $0.id == clip.id })
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:4) {
                SectionLabel(title:source?.name ?? "컷",detail:store.selectedClipIDs.count > 1 ? "\(store.selectedClipIDs.count)개 선택" : "")
                Text("원본 \(timecode(clip.start))–\(timecode(clip.end)) · 편집 \(timecode(entry?.start ?? 0))–\(timecode(entry?.end ?? 0))").font(.system(size:9,design:.monospaced)).foregroundStyle(Color.muted)
            }
            group("속도",icon:"speedometer") {
                if clip.freeze != nil {
                    ValueRow(label:"정지 화면 길이 (초)",value:bind("freeze",get:{ $0.freeze ?? 2 },set:{ c,v in c.freeze = max(0.1,v) }),range:0.1...20,format:"%.1f")
                } else {
                    HStack(spacing:4) {
                        ForEach([0.5,1,2,4],id:\.self) { s in
                            Button(s == 0.5 ? "½×" : "\(Int(s))×") { store.setSpeed(s) }.buttonStyle(ActionStyle(primary:abs(clip.rate-s) < 0.001)).lineLimit(1).help("\(Int(s*100))%")
                        }
                    }
                    VStack(spacing:4) {
                        HStack { Text("재생 속도"); Spacer(); Text("\(Int((clip.rate*100).rounded()))%").foregroundStyle(clip.rate == 1 ? Color.muted : Color.yellow).monospacedDigit() }.font(.system(size:10))
                        Slider(value:Binding(get:{ log2(clip.rate) },set:{ store.setSpeed(pow(2,($0*4).rounded()/4)) }),in:-3...3).controlSize(.small)
                    }
                    Button { store.addFreezeFrame() } label: { Label("재생 위치에 정지 화면 추가",systemImage:"pause.rectangle") }.help("재생 위치의 장면을 멈춘 화면으로 2초 끼워 넣습니다 (⌥F)").buttonStyle(ActionStyle())
                    Text("속도를 바꿔도 음높이는 유지됩니다. 재생 헤드가 이 컷 위에 있을 때 정지 화면이 추가됩니다.").font(.system(size:9)).foregroundStyle(Color.muted)
                }
            }
            group("전환 효과 · 시작 부분",icon:"rhombus") {
                Picker("효과",selection:Binding(get:{ clip.transition?.kind },set:{ kind in store.setTransition(kind,duration:clip.transition?.duration ?? 0.5) })) {
                    Text("없음").tag(TransitionKind?.none)
                    ForEach(TransitionKind.allCases,id:\.self) { Text($0.rawValue).tag(TransitionKind?.some($0)) }
                }.font(.system(size:10))
                if let t = clip.transition {
                    ValueRow(label:"길이 (초)",value:Binding(get:{ t.duration },set:{ store.setTransition(t.kind,duration:$0) }),range:0.1...3,format:"%.1f")
                    Text(entry?.overlap ?? 0 > 0 ? "앞 컷과 \(String(format:"%.1f",entry?.overlap ?? 0))초 겹쳐 전환됩니다." : "앞에 이어진 컷이 없어 검은 화면에서 서서히 나타납니다.").font(.system(size:9)).foregroundStyle(Color.muted)
                }
                HStack {
                    ValueRow(label:"영상 페이드 인",value:bind("vfi",get:{ $0.videoFadeIn ?? 0 },set:{ c,v in c.videoFadeIn = v < 0.01 ? nil : v }),range:0...3,format:"%.1f")
                    ValueRow(label:"페이드 아웃",value:bind("vfo",get:{ $0.videoFadeOut ?? 0 },set:{ c,v in c.videoFadeOut = v < 0.01 ? nil : v }),range:0...3,format:"%.1f")
                }
            }
            group("화면 · 위치와 크기",icon:"rectangle.inset.topright.filled") {
                Picker("맞춤",selection:bind("fill",get:{ $0.transform?.fill ?? false },set:{ c,v in var t = c.transform ?? ClipTransform(); t.fill = v; c.transform = t.isIdentity ? nil : t })) { Text("전체 보이기").tag(false); Text("화면 채우기").tag(true) }.pickerStyle(.segmented).font(.system(size:10))
                ValueRow(label:"크기",value:transform(\.scale,"scale"),range:0.1...3,format:"%.2f×",neutral:1)
                ValueRow(label:"가로 위치",value:transform(\.x,"x"),range:-1...1,neutral:0)
                ValueRow(label:"세로 위치",value:transform(\.y,"y"),range:-1...1,neutral:0)
                ValueRow(label:"회전 (도)",value:transform(\.rotation,"rotation"),range:-180...180,format:"%.0f°",neutral:0)
                ValueRow(label:"불투명도",value:transform(\.opacity,"opacity"),range:0...1,neutral:1)
                DisclosureGroup("자르기") {
                    ValueRow(label:"왼쪽",value:transform(\.cropLeft,"cropL"),range:0...0.45,neutral:0)
                    ValueRow(label:"오른쪽",value:transform(\.cropRight,"cropR"),range:0...0.45,neutral:0)
                    ValueRow(label:"위",value:transform(\.cropTop,"cropT"),range:0...0.45,neutral:0)
                    ValueRow(label:"아래",value:transform(\.cropBottom,"cropB"),range:0...0.45,neutral:0)
                }.font(.system(size:10))
                HStack {
                    Button("PiP 오른쪽 아래") { store.updateClips { c in c.transform = ClipTransform(scale:0.35,x:0.3,y:-0.3) } }.help("작은 화면(35%)으로 오른쪽 아래에 배치합니다")
                    Button("초기화") { store.updateClips { c in c.transform = nil } }.help("위치·크기·회전·자르기를 원래대로 되돌립니다")
                }.buttonStyle(ActionStyle()).font(.system(size:9))
            }
            group("색 보정",icon:"camera.filters") {
                ValueRow(label:"노출",value:color(\.exposure,"exposure"),range:-2...2,neutral:0)
                ValueRow(label:"밝기",value:color(\.brightness,"brightness"),range:-0.5...0.5,neutral:0)
                ValueRow(label:"대비",value:color(\.contrast,"contrast"),range:0.5...1.5,neutral:1)
                ValueRow(label:"채도",value:color(\.saturation,"saturation"),range:0...2,neutral:1)
                ValueRow(label:"색온도 (따뜻하게 +)",value:color(\.temperature,"temperature"),range:-1...1,neutral:0)
                ValueRow(label:"색조 (자홍 +)",value:color(\.tint,"tint"),range:-1...1,neutral:0)
                HStack {
                    Button("흑백") { store.updateClips { c in var a = c.color ?? ColorAdjust(); a.saturation = 0; c.color = a } }.help("채도를 0으로 만들어 흑백으로 바꿉니다")
                    Button("선명하게") { store.updateClips { c in var a = c.color ?? ColorAdjust(); a.contrast = 1.12; a.saturation = 1.2; c.color = a } }.help("대비와 채도를 조금 높입니다")
                    Button("따뜻하게") { store.updateClips { c in var a = c.color ?? ColorAdjust(); a.temperature = 0.35; c.color = a } }.help("색온도를 따뜻하게 바꿉니다")
                    Button("초기화") { store.updateClips { c in c.color = nil } }.help("색 보정을 모두 되돌립니다")
                }.buttonStyle(ActionStyle()).font(.system(size:9))
            }
            group("소리",icon:"speaker.wave.2") {
                if source?.hasAudio == true && clip.freeze == nil {
                    Toggle("소리 끄기",isOn:bind("mute",get:{ $0.audioMuted == true },set:{ c,v in c.audioMuted = v ? true : nil })).font(.system(size:10))
                    ValueRow(label:"음량 (dB)",value:bind("volume",get:{ 20*log10(max(0.001,$0.volume ?? 1)) },set:{ c,v in let g = pow(10,v/20); c.volume = abs(g-1) < 0.01 ? nil : min(4,g) }),range:-40...12,format:"%.1f dB",neutral:0)
                    HStack {
                        ValueRow(label:"페이드 인",value:bind("afi",get:{ $0.audioFadeIn ?? 0 },set:{ c,v in c.audioFadeIn = v < 0.01 ? nil : v }),range:0...5,format:"%.1f")
                        ValueRow(label:"페이드 아웃",value:bind("afo",get:{ $0.audioFadeOut ?? 0 },set:{ c,v in c.audioFadeOut = v < 0.01 ? nil : v }),range:0...5,format:"%.1f")
                    }
                    Button { store.detachAudio() } label: { Label("오디오 분리",systemImage:"rectangle.split.1x2") }.help("이 컷의 소리를 독립 오디오 트랙으로 옮깁니다 (⌃⇧S)").buttonStyle(ActionStyle()).disabled(clip.audioMuted == true)
                } else { Text(clip.freeze != nil ? "정지 화면에는 소리가 없습니다." : "이 미디어에는 오디오가 없습니다.").font(.system(size:10)).foregroundStyle(Color.muted) }
            }
        }
    }
    func group<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Label(title,systemImage:icon).font(.system(size:11,weight:.semibold))
            content()
        }.padding(10).background(Color.raised.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
    }
}

struct AudioClipInspector: View {
    @EnvironmentObject var store: EditorStore
    @Binding var clip: AudioClip
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            SectionLabel(title:store.project.media.first(where:{ $0.id == clip.source })?.name ?? "오디오",detail:"독립 오디오")
            Text("원본 \(timecode(clip.start))–\(timecode(clip.end)) · 편집 \(timecode(clip.position))–\(timecode(clip.timelineEnd))").font(.system(size:9,design:.monospaced)).foregroundStyle(Color.muted)
            Toggle("소리 끄기",isOn:$clip.muted).font(.system(size:10))
            ValueRow(label:"음량 (dB)",value:Binding(get:{ 20*log10(max(0.001,clip.volume)) },set:{ clip.volume = min(4,pow(10,$0/20)) }),range:-40...12,format:"%.1f dB",neutral:0)
            ValueRow(label:"페이드 인 (초)",value:$clip.fadeIn,range:0...10,format:"%.1f",neutral:0)
            ValueRow(label:"페이드 아웃 (초)",value:$clip.fadeOut,range:0...10,format:"%.1f",neutral:0)
            HStack { Text("시작 위치 (초)"); TimeField(title:"시작 위치",value:$clip.position) { v in clip.position = max(0,v) }.frame(width:80,height:22) }.font(.system(size:10))
            Text("배경음악·효과음 트랙입니다. 영상 컷과 독립적으로 이동·분할됩니다.").font(.system(size:9)).foregroundStyle(Color.muted)
        }
    }
}

struct TitleInspector: View {
    @EnvironmentObject var store: EditorStore
    @Binding var title: TitleItem
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            SectionLabel(title:"타이틀",detail:"\(timecode(title.start))–\(timecode(title.end))")
            TextField("타이틀 문구",text:$title.text,axis:.vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
            ValueRow(label:"글자 크기",value:$title.size,range:0.02...0.25,format:"%.3f")
            ValueRow(label:"가로 위치",value:$title.x,range:0...1)
            ValueRow(label:"세로 위치 (아래 0)",value:$title.y,range:0...1)
            ColorPicker("글자 색",selection:Binding(get:{ Color(red:title.red,green:title.green,blue:title.blue) },set:{ color in
                if let c = NSColor(color).usingColorSpace(.deviceRGB) { title.red = c.redComponent; title.green = c.greenComponent; title.blue = c.blueComponent }
            }),supportsOpacity:false).font(.system(size:10))
            Toggle("굵게",isOn:$title.bold).font(.system(size:10))
            Toggle("배경 상자",isOn:$title.background).font(.system(size:10))
            ValueRow(label:"나타나기 (초)",value:$title.fadeIn,range:0...2,format:"%.1f")
            ValueRow(label:"사라지기 (초)",value:$title.fadeOut,range:0...2,format:"%.1f")
            HStack {
                Button("위") { title.y = 0.85 }.help("타이틀을 화면 위쪽에 둡니다"); Button("가운데") { title.x = 0.5; title.y = 0.5 }; Button("아래") { title.y = 0.18 }.help("타이틀을 화면 아래쪽에 둡니다")
            }.buttonStyle(ActionStyle()).font(.system(size:9))
            HStack { Text("시작"); TimeField(title:"시작",value:$title.start) { v in store.editOverlayTime(id:title.id,kind:.titles,original:TimelineRange(start:title.start,end:title.end),delta:v-title.start,edge:-1) }; Text("끝"); TimeField(title:"끝",value:$title.end) { v in store.editOverlayTime(id:title.id,kind:.titles,original:TimelineRange(start:title.start,end:title.end),delta:v-title.end,edge:1) } }.frame(height:22).font(.system(size:10))
        }
    }
}

struct DesignInspector: View {
    @EnvironmentObject var store: EditorStore
    private var editingRegions: Bool { store.tab == .regions }
    private var maskDesign: Binding<MaskDesign> {
        Binding(get:{ editingRegions ? store.project.effectiveRegionDesign : store.project.effectiveFaceDesign },set:{ value in
            store.pendingCoalesce = editingRegions ? "regionDesign" : "faceDesign"
            if editingRegions { store.project.effectiveRegionDesign = value } else { store.project.effectiveFaceDesign = value }
        })
    }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            SectionLabel(title:editingRegions ? "영역 마스크 디자인" : "얼굴 마스크 디자인",detail:editingRegions ? "영역에만 적용" : "얼굴에만 적용")
            Text(editingRegions ? "직접 지정한 영역의 효과와 모양입니다. 얼굴 마스크 설정은 유지됩니다. (얼굴 탭을 누르면 얼굴 디자인을 편집합니다)" : "선택한 얼굴의 효과와 모양입니다. 영역 마스크 설정은 유지됩니다. (영역 탭에서 영역 디자인을 편집합니다)")
                .font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(3)
            VStack(alignment:.leading,spacing:10) {
                Text("효과").font(.system(size:10)).foregroundStyle(Color.muted)
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:8) {
                    ForEach(MaskEffect.allCases,id:\.self) { effect in
                        Button { maskDesign.wrappedValue.effect = effect } label: {
                            VStack(spacing:8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius:8).fill(Color.accent.opacity(0.12)).frame(height:40)
                                    if effect == .pixel { HStack(spacing:3) { ForEach(0..<4) { i in VStack(spacing:3) { ForEach(0..<2) { j in Rectangle().fill(Color.accent.opacity(Double((i+j)%3+1)*0.3)).frame(width:9,height:9) } } } } }
                                    else { Image(systemName:effect == .blur ? "drop.halffull" : effect == .solid ? "circle.fill" : "face.smiling").font(.system(size:22,weight:.light)).foregroundStyle(Color.accent).blur(radius:effect == .blur ? 2 : 0) }
                                }
                                Text(effect.rawValue).font(.system(size:10))
                            }.padding(8).background(maskDesign.wrappedValue.effect == effect ? Color.accent.opacity(0.12) : Color.raised.opacity(0.35),in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(maskDesign.wrappedValue.effect == effect ? Color.accent.opacity(0.6) : .clear,lineWidth:1))
                        }.buttonStyle(.hover)
                    }
                }
            }
            VStack(alignment:.leading,spacing:10) {
                Text("모양").font(.system(size:10)).foregroundStyle(Color.muted)
                Picker("모양",selection:maskDesign.shape) { ForEach(MaskShape.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(maxWidth:.infinity)
                if maskDesign.wrappedValue.shape == .heart || maskDesign.wrappedValue.shape == .star {
                    Text("하트·별의 가장자리는 비어 있습니다. 가릴 부분을 충분히 덮도록 여백을 키우세요.").font(.system(size:9)).foregroundStyle(Color.orange.opacity(0.85)).lineSpacing(3)
                }
            }
            SliderRow(label:"효과 강도",value:maskDesign.strength)
            if !editingRegions { SliderRow(label:"얼굴 여백",value:maskDesign.margin,range:0...1.5) }
            if maskDesign.wrappedValue.effect == .solid || maskDesign.wrappedValue.effect == .sticker {
                ColorPicker("마스크 색상",selection:Binding(get:{Color(red:maskDesign.wrappedValue.red,green:maskDesign.wrappedValue.green,blue:maskDesign.wrappedValue.blue)},set:{color in
                    if let c = NSColor(color).usingColorSpace(.deviceRGB) { maskDesign.wrappedValue.red = c.redComponent; maskDesign.wrappedValue.green = c.greenComponent; maskDesign.wrappedValue.blue = c.blueComponent }
                }),supportsOpacity:false).font(.system(size:10))
            }
            if maskDesign.wrappedValue.effect == .sticker { TextField("스티커 문자 / 이모지",text:maskDesign.sticker).textFieldStyle(.roundedBorder).onChange(of:maskDesign.wrappedValue.sticker) { _,value in if value.count > 4 { maskDesign.wrappedValue.sticker = String(value.prefix(4)) } } }
            if !editingRegions {
                Divider()
                VStack(alignment:.leading,spacing:10) {
                    Label("검출 누락 보완",systemImage:"bandage").font(.system(size:11,weight:.semibold)).foregroundStyle(Color.mint)
                    ValueRow(label:"끊긴 구간 잇기 (초)",value:store.projectBinding(\.faceBridge,coalesce:"bridge"),range:0...3,format:"%.1f",neutral:1)
                    ValueRow(label:"등장·퇴장 유지 (초)",value:store.projectBinding(\.faceHold,coalesce:"hold"),range:0...1,format:"%.2f",neutral:0.25)
                    Text("검출이 잠깐 놓친 프레임도 같은 자리 근처라면 마스크를 이어 줍니다. 값을 키울수록 노출 위험은 줄고, 마스크가 잠시 더 남습니다.").font(.system(size:9)).foregroundStyle(Color.muted).lineSpacing(3)
                }
            }
            Divider()
            VStack(alignment:.leading,spacing:9) {
                Label("내보내기 전 검토",systemImage:"checkmark.shield").font(.system(size:11,weight:.semibold)).foregroundStyle(Color.mint)
                Text("작은 얼굴, 옆얼굴, 가려진 얼굴은 놓칠 수 있습니다. 타임라인 얼굴 줄의 주황색(검토 권장) 구간을 먼저 확인하고, 부족한 곳은 영역 마스크로 보완하세요. 블러·모자이크보다 단색이 가장 확실합니다.").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(4)
            }
        }
    }
}

struct OutputInspector: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            SectionLabel(title:"프로젝트 캔버스",detail:"\(Int(store.project.width))×\(Int(store.project.height))")
            if !store.project.isImage {
                Menu("캔버스 크기 바꾸기") {
                    ForEach([(1920.0,1080.0,"가로 1080p"),(3840,2160,"가로 4K"),(1280,720,"가로 720p"),(1080,1920,"세로 1080×1920"),(1080,1080,"정사각 1080"),(1440,1080,"4:3 1440×1080")],id:\.2) { w,h,name in
                        Button(name) { store.setCanvas(width:w,height:h) }
                    }
                    Divider()
                    ForEach(store.project.media.filter { $0.kind == .video }) { m in Button("\(m.name) 크기 · \(Int(m.width))×\(Int(m.height))") { store.setCanvas(width:m.width,height:m.height,fps:m.fps) } }
                }
                Picker("프레임률",selection:store.projectBinding(\.fps,coalesce:"fps")) {
                    ForEach([23.976,24,25,29.97,30,50,59.94,60],id:\.self) { Text(String(format:$0.rounded() == $0 ? "%.0f fps" : "%.3g fps",$0)).tag($0) }
                    if ![23.976,24,25,29.97,30,50,59.94,60].contains(store.project.fps) { Text(String(format:"%.3f fps (원본)",store.project.fps)).tag(store.project.fps) }
                }.font(.system(size:10))
                Text("캔버스와 다른 비율의 영상은 잘리지 않고 안쪽에 맞춰집니다. 클립 검사기에서 ‘화면 채우기’를 고를 수 있습니다.").font(.system(size:9)).foregroundStyle(Color.muted)
            }
            Divider()
            SectionLabel(title:"내보내기 화면 비율",detail:"크롭 미리보기")
            Picker("비율",selection:$store.project.export.ratio) { ForEach(CropRatio.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden()
            if store.project.export.ratio != .original { SliderRow(label:"크롭 가로 위치",value:$store.project.export.cropX); SliderRow(label:"크롭 세로 위치",value:$store.project.export.cropY) }
            Divider()
            Toggle("영상에 자막 입히기",isOn:$store.project.export.burnCaptions).font(.system(size:11))
            SliderRow(label:"자막 크기 (짧은 변 기준)",value:$store.project.export.captionSize,range:0.025...0.09)
            Divider()
            Button { store.exportSheet = true } label: { Label("내보내기…",systemImage:"arrow.up.right") }.help("편집 결과를 새 영상·사진 파일로 저장합니다 (⌘E)").buttonStyle(ActionStyle(primary:true))
        }
    }
}

struct ExportSheet: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack { VStack(alignment:.leading,spacing:6) { Text("마무리도, 원하는 대로.").font(.system(size:24,weight:.semibold)); Text("편집 결과를 새 파일로 저장합니다.").foregroundStyle(Color.muted).font(.system(size:12)) }; Spacer(); Image(systemName:"arrow.up.right.square").font(.system(size:30,weight:.light)).foregroundStyle(Color.mint) }
            Divider()
            HStack(alignment:.top,spacing:30) {
                VStack(alignment:.leading,spacing:16) {
                    Picker("화면 비율",selection:$store.project.export.ratio) { ForEach(CropRatio.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    Picker("해상도",selection:$store.project.export.resolution) { ForEach(OutputResolution.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    if store.project.isImage {
                        Picker("이미지 형식",selection:Binding(get:{store.project.export.resolvedImageFormat},set:{store.project.export.imageFormat = $0})) { ForEach(ImageOutput.allCases,id:\.self) { Text($0.rawValue.uppercased()).tag($0) } }
                    } else {
                        Picker("영상 형식",selection:Binding(get:{store.project.export.videoFormat ?? .mp4},set:{store.project.export.videoFormat = $0})) { ForEach(VideoOutput.allCases,id:\.self) { Text($0.rawValue.uppercased()).tag($0) } }
                        Picker("영상 코덱",selection:$store.project.export.hevc) { Text("H.264 · 높은 호환성").tag(false); Text("HEVC · 효율적인 용량").tag(true) }
                        Toggle("오디오 제외",isOn:$store.project.export.muted)
                        Toggle("자막을 영상에 입히기",isOn:$store.project.export.burnCaptions)
                    }
                    if store.project.export.ratio != .original {
                        SliderRow(label:"크롭 가로 위치",value:$store.project.export.cropX)
                        SliderRow(label:"크롭 세로 위치",value:$store.project.export.cropY)
                    }
                }.frame(width:300)
                VStack(alignment:.leading,spacing:12) {
                    Text(store.project.exportRange == nil ? "OUTPUT · 전체 타임라인" : "OUTPUT · 지정 구간").font(.system(size:9,weight:.semibold)).tracking(2).foregroundStyle(Color.muted)
                    let size = store.project.export.outputSize(store.project.size,even:!store.project.isImage)
                    Text("\(Int(size.width)) × \(Int(size.height))").font(.system(size:24,weight:.medium,design:.rounded))
                    Text(store.project.isImage ? "\(store.project.export.resolvedImageFormat.rawValue.uppercased()) 이미지" : "\(store.project.export.fileExtension.uppercased()) · \(timecode(store.project.exportDuration)) · \(Int(min(120,store.project.fps).rounded())) fps").font(.system(size:11)).foregroundStyle(Color.muted)
                    if !store.project.isImage { Text("예상 최대 용량 약 \(ByteCountFormatter.string(fromByteCount:MediaEngine.estimatedBytes(store.project),countStyle:.file))").font(.system(size:10)).foregroundStyle(Color.muted) }
                    Divider()
                    Label("원본 덮어쓰기 방지",systemImage:"checkmark"); Label("GPS·원본 메타데이터 제외",systemImage:"checkmark"); Label("서버 업로드 없음",systemImage:"checkmark")
                    Text("영상은 고품질 설정으로 다시 인코딩됩니다. HDR은 SDR로 변환됩니다.").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(4)
                }.font(.system(size:10)).foregroundStyle(Color.mint).padding(20).frame(width:250,alignment:.leading).background(Color.raised,in:RoundedRectangle(cornerRadius:12))
            }
            let pending = store.project.media.filter { $0.isVisual && !$0.maskApplied && $0.faces.contains(where:\.selected) && store.project.usedVisualSources.contains($0.id) }
            if !pending.isEmpty {
                Label("얼굴 마스킹을 아직 적용하지 않은 미디어가 \(pending.count)개 있습니다: \(pending.map(\.name).prefix(3).joined(separator:", "))",systemImage:"exclamationmark.triangle").foregroundStyle(.orange).font(.system(size:11))
                Button("선택한 얼굴 모두 마스킹 적용") { for m in pending { if let i = store.project.media.firstIndex(where:{ $0.id == m.id }) { store.project.media[i].maskApplied = true } } }.help("분석한 모든 미디어의 선택 인물에 마스킹을 적용합니다").buttonStyle(ActionStyle())
            }
            let unanalysed = store.project.media.filter { $0.isVisual && !$0.analysisComplete && store.project.usedVisualSources.contains($0.id) }
            if !unanalysed.isEmpty { Label("얼굴 분석을 하지 않은 미디어 \(unanalysed.count)개가 타임라인에 있습니다.",systemImage:"person.crop.rectangle.badge.questionmark").foregroundStyle(.orange).font(.system(size:11)) }
            HStack { Text("얼굴 누락과 자막 내용을 최종 확인해 주세요.").font(.system(size:10)).foregroundStyle(Color.muted); Spacer(); Button("닫기") { dismiss() }.buttonStyle(ActionStyle()); Button(action:store.exportMedia) { Label("저장 위치 선택",systemImage:"arrow.up.right") }.help("저장할 위치와 파일 이름을 고른 뒤 내보내기를 시작합니다").buttonStyle(ActionStyle(primary:true)) }
        }.padding(30).frame(width:680).background(Color.panel).foregroundStyle(Color.ink).tint(Color.accent)
    }
}
struct HelpSheet: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("사용 안내 · 지원 형식").font(.system(size:24,weight:.semibold))
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    item("여러 미디어","⌘O로 여러 파일(또는 폴더)을 한 번에 열면 순서대로 이어 붙인 새 프로젝트가 됩니다. 열린 프로젝트에는 ⌘I로 미디어를 추가하고, 미디어 패널에서 끝에 추가·재생 위치에 삽입·위 트랙에 연결(화면 속 화면)하거나 타임라인으로 끌어다 놓습니다. 캔버스와 비율이 다른 영상은 잘리지 않고 안쪽에 맞춰집니다.")
                    item("얼굴 분석","모든 프레임에서 얼굴을 찾고, 놓친 프레임은 움직임 추적으로 이어 줍니다. ‘정밀’ 모드는 화면을 나눠 멀리 있는 작은 얼굴까지 찾습니다(권장). 같은 시간에 함께 나온 얼굴은 절대 같은 인물로 묶지 않으며, 헷갈리는 조각은 따로 둡니다. 여러 조각이 같은 인물이면 ⌘클릭으로 골라 ‘묶기’를 누르세요. 타임라인 얼굴 줄의 주황색은 누락이 의심되는 구간입니다.")
                    item("작업 목록","미디어 여러 개를 작업 목록에 넣고 ‘순차 실행’하면 차례로 얼굴을 분석합니다. ‘자동 출력’ 항목은 찾은 얼굴을 모두 가려 지정 폴더에 바로 저장하고, ‘검토 후 출력’ 항목은 검토 창에서 확인·승인한 뒤 ‘승인 항목 출력’으로 저장합니다. 실패한 항목은 이유를 표시하고 다음 항목으로 넘어갑니다.")
                    item("자동 자막","기본 엔진은 앱에 포함된 Whisper large-v3-turbo(한국어 정확도 우선)이며 음성 구간 검출로 음악·무음 구간의 가짜 문장을 줄입니다. macOS 26에서는 Apple 새 인식기도 고를 수 있습니다. 자막은 줄당 글자 수·줄 수 규칙으로 나뉘고, 신뢰도가 낮은 문장은 노란 표시로 알려 줍니다. 모든 인식은 이 Mac에서만 처리합니다.")
                    item("편집","J/K/L 셔틀, ←/→ 1프레임, ⇧←/→ 10프레임, ↑/↓ 편집 지점, ⌘B 분할, B 자르기 도구, A 선택 도구, M 마커, N 스냅, ⌘=/⌘- 확대·축소, ⇧Z 전체 보기. 클립 검사기에서 속도·정지 화면·전환·위치/크기/회전·색 보정·음량/페이드·오디오 분리를 조절합니다.")
                    item("영상·오디오 형식","MOV, MP4, M4V(H.264·HEVC·ProRes 등 macOS가 해독하는 코덱), 사진 JPEG·PNG·HEIC·TIFF, 오디오 M4A·WAV·MP3·AIFF. MKV·WebM은 먼저 MP4로 변환하세요. 출력은 MP4/MOV(H.264/HEVC), 사진은 PNG/JPEG/TIFF/HEIC입니다. HDR은 SDR로 출력됩니다.")
                    item("안정성","편집 내용은 1.5초마다 자동 저장되며, 앱이 비정상 종료되면 다음 실행 때 복구를 제안합니다. 긴 분석·내보내기 중에는 Mac이 잠자기에 들어가지 않습니다. 오류 기록: ~/Library/Logs/VeilStudio. 원본을 옮기면 미디어 패널의 ‘다시 연결’로 위치를 지정하세요.")
                    item("개인정보","영상·음성은 서버로 전송하지 않습니다. 프로젝트와 자동 저장 파일에는 원본 경로·얼굴 썸네일·분석 좌표·자막이 들어 있으므로 작업 후 관리해 주세요. 출력 파일에는 원본 EXIF/GPS를 복사하지 않습니다.")
                }.padding(.trailing,8)
            }
            HStack { Text("Veil Studio 0.8 · 제작자 다있쌤 로디").font(.system(size:10)).foregroundStyle(Color.muted); Spacer(); Button("확인") { dismiss() }.help("창을 닫습니다").buttonStyle(ActionStyle(primary:true)) }
        }.padding(28).frame(width:680,height:680).background(Color.panel).foregroundStyle(Color.ink)
    }
    func item(_ title: String,_ text: String) -> some View { VStack(alignment:.leading,spacing:7) { Text(title).font(.system(size:13,weight:.semibold)).foregroundStyle(Color.accent); Text(text).font(.system(size:12)).foregroundStyle(Color.muted).lineSpacing(4).fixedSize(horizontal:false,vertical:true) } }
}
