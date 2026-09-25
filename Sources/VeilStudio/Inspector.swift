import SwiftUI

struct DesignInspector: View {
    @EnvironmentObject var store: EditorStore
    private var editingRegions: Bool { store.tab == .regions }
    private var maskDesign: Binding<MaskDesign> {
        Binding(get:{ editingRegions ? store.project.effectiveRegionDesign : store.project.effectiveFaceDesign },set:{ value in
            if editingRegions { store.project.effectiveRegionDesign = value } else { store.project.effectiveFaceDesign = value }
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                SectionLabel(title:editingRegions ? "영역 마스크 디자인" : "얼굴 마스크 디자인",detail:editingRegions ? "영역에만 적용" : "얼굴에만 적용")
                Text(editingRegions ? "직접 지정한 영역의 효과와 모양입니다. 얼굴 마스크 설정은 유지됩니다." : "선택한 얼굴의 효과와 모양입니다. 영역 마스크 설정은 유지됩니다.")
                    .font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(3)
                VStack(alignment:.leading,spacing:10) {
                    Text("효과").font(.system(size:10)).foregroundStyle(Color.muted)
                    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:8) {
                        ForEach(MaskEffect.allCases,id:\.self) { effect in
                            Button { maskDesign.wrappedValue.effect = effect } label: {
                                VStack(spacing:8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius:8).fill(Color.accent.opacity(0.12)).frame(height:42)
                                        if effect == .pixel { HStack(spacing:3) { ForEach(0..<4) { i in VStack(spacing:3) { ForEach(0..<2) { j in Rectangle().fill(Color.accent.opacity(Double((i+j)%3+1)*0.3)).frame(width:9,height:9) } } } } }
                                        else { Image(systemName:effect == .blur ? "drop.halffull" : effect == .solid ? "circle.fill" : "face.smiling").font(.system(size:24,weight:.light)).foregroundStyle(Color.accent).blur(radius:effect == .blur ? 2 : 0) }
                                    }
                                    Text(effect.rawValue).font(.system(size:10))
                                }.padding(8).background(maskDesign.wrappedValue.effect == effect ? Color.accent.opacity(0.12) : Color.raised.opacity(0.35),in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(maskDesign.wrappedValue.effect == effect ? Color.accent.opacity(0.6) : .clear,lineWidth:1))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment:.leading,spacing:10) {
                    Text("영역 모양").font(.system(size:10)).foregroundStyle(Color.muted)
                    Picker("모양",selection:maskDesign.shape) { ForEach(MaskShape.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(maxWidth:.infinity)
                    if maskDesign.wrappedValue.shape == .heart || maskDesign.wrappedValue.shape == .star {
                        Text("하트·별의 가장자리는 비어 있습니다. 가릴 부분을 충분히 덮도록 크기를 조절하세요.").font(.system(size:9)).foregroundStyle(Color.orange.opacity(0.85)).lineSpacing(3)
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
                Divider()
                SectionLabel(title:"화면 비율",detail:"크롭 미리보기")
                Picker("비율",selection:$store.project.export.ratio) { ForEach(CropRatio.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden()
                if store.project.export.ratio != .original { SliderRow(label:"크롭 가로 위치",value:$store.project.export.cropX); SliderRow(label:"크롭 세로 위치",value:$store.project.export.cropY) }
                if store.tab == .captions {
                    Divider()
                    Toggle("영상에 자막 입히기",isOn:$store.project.export.burnCaptions).font(.system(size:11))
                    SliderRow(label:"자막 크기 (짧은 변 기준)",value:$store.project.export.captionSize,range:0.025...0.09)
                }
                Divider()
                VStack(alignment:.leading,spacing:9) {
                    Label("내보내기 전 검토",systemImage:"checkmark.shield").font(.system(size:11,weight:.semibold)).foregroundStyle(Color.mint)
                    Text("작은 얼굴, 옆얼굴, 가려진 얼굴은 놓칠 수 있습니다. 전체 영상을 확인하고 부족한 곳은 영역 마스크로 보완하세요.").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(4)
                    if store.project.analysisComplete { Text("\(store.project.faces.count)개 후보  ·  남은 컷 분석").font(.system(size:9,design:.monospaced)).foregroundStyle(Color.accent) }
                }
            }.padding(16)
        }.background(Color.panel.opacity(0.4)).disabled(!store.loaded)
    }
}
struct ExportSheet: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            HStack { VStack(alignment:.leading,spacing:6) { Text("마무리도, 원하는 대로.").font(.system(size:24,weight:.semibold)); Text("편집 결과를 새 파일로 저장합니다.").foregroundStyle(Color.muted).font(.system(size:12)) }; Spacer(); Image(systemName:"arrow.up.right.square").font(.system(size:30,weight:.light)).foregroundStyle(Color.mint) }
            Divider()
            HStack(alignment:.top,spacing:30) {
                VStack(alignment:.leading,spacing:18) {
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
                VStack(alignment:.leading,spacing:14) {
                    Text(store.project.exportRange == nil ? "OUTPUT · 전체 타임라인" : "OUTPUT · 지정 구간").font(.system(size:9,weight:.semibold)).tracking(2).foregroundStyle(Color.muted)
                    let size = store.project.export.outputSize(store.project.size,even:!store.project.isImage)
                    Text("\(Int(size.width)) × \(Int(size.height))").font(.system(size:24,weight:.medium,design:.rounded))
                    Text(store.project.isImage ? "\(store.project.export.resolvedImageFormat.rawValue.uppercased()) 이미지" : "\(store.project.export.fileExtension.uppercased()) · \(timecode(store.project.exportDuration)) · 최대 \(Int(min(120,store.project.fps))) fps").font(.system(size:11)).foregroundStyle(Color.muted)
                    Divider()
                    Label("원본 덮어쓰기 방지",systemImage:"checkmark"); Label("GPS·원본 메타데이터 제외",systemImage:"checkmark"); Label("서버 업로드 없음",systemImage:"checkmark")
                    Text("영상은 고품질 설정으로 다시 인코딩됩니다. HDR은 SDR로 변환되며, 출력 용량은 영상 내용과 코덱에 따라 달라집니다.").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(4)
                }.font(.system(size:10)).foregroundStyle(Color.mint).padding(20).frame(width:250,alignment:.leading).background(Color.raised,in:RoundedRectangle(cornerRadius:12))
            }
            if !store.project.maskApplied && store.project.faces.contains(where: \.selected) {
                Label("선택한 얼굴의 마스킹이 아직 적용되지 않았습니다.",systemImage:"exclamationmark.triangle").foregroundStyle(.orange).font(.system(size:11))
                Button("선택한 얼굴 마스킹 적용",action:store.applyMasks).buttonStyle(ActionStyle())
            }
            HStack { Text("얼굴 누락과 자막 내용을 최종 확인해 주세요.").font(.system(size:10)).foregroundStyle(Color.muted); Spacer(); Button("닫기") { dismiss() }.buttonStyle(ActionStyle()); Button(action:store.exportMedia) { Label("저장 위치 선택",systemImage:"arrow.up.right") }.buttonStyle(ActionStyle(primary:true)) }
        }.padding(30).frame(width:650).background(Color.panel).foregroundStyle(Color.ink).tint(Color.accent)
    }
}
struct HelpSheet: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("지원 형식과 처리 용량").font(.system(size:24,weight:.semibold))
            ScrollView {
                VStack(alignment:.leading,spacing:19) {
                    item("파일 크기", "파일당 GB 제한은 두지 않았습니다. 영상은 프레임을 순차 처리하므로 파일 전체를 메모리에 올리지 않습니다. 최대 처리 용량을 실기기 벤치마크로 인증한 상태는 아닙니다. 긴 영상일수록 분석 데이터·처리 시간·디스크 사용량이 늘어납니다.")
                    item("영상", "macOS AVFoundation이 읽을 수 있는 MOV, MP4, M4V와 H.264, HEVC, ProRes 등을 지원합니다. 확장자만으로 지원이 보장되지는 않습니다. MKV·WebM·일부 AVI는 먼저 MP4/MOV로 변환해야 합니다. 출력은 MP4 또는 MOV(H.264/HEVC), 원본/4K/1080p/720p, 최대 120fps입니다. 해상도는 긴 변 기준이며 원본보다 확대하지 않습니다. HDR 출력은 현재 지원하지 않습니다.")
                    item("이미지", "ImageIO가 읽는 JPEG, PNG, HEIC, TIFF, BMP 및 일부 WebP·RAW 등을 지원합니다. 다중 프레임 GIF·다중 페이지 TIFF는 받지 않습니다. 단일 이미지는 최대 1억 2천만 화소입니다. 결과는 PNG, JPEG, TIFF, HEIC로 저장하며 원본 EXIF/GPS를 복사하지 않습니다.")
                    item("메모리·디스크", "4K 3840×2160의 8비트 BGRA 프레임은 약 31.6MiB, 8K는 약 126.6MiB입니다. 렌더링에는 여러 버퍼가 필요하므로 실제 메모리는 더 큽니다. 1억 2천만 화소 이미지는 버퍼 하나만 약 458MiB입니다. 출력과 임시 파일을 위한 여유 디스크가 필요합니다. 8K·장시간·대용량 파일의 안정적인 최대치는 추가 실측이 필요합니다.")
                    item("얼굴 분석", "영상은 모든 프레임을 긴 변 최대 960px, 이미지는 최대 2400px로 축소하고 겹치는 9개 영역도 추가 검출합니다. 공간 연속성과 이미지 특징으로 인물 후보를 묶습니다. 전용 신원 인식 모델이 아니므로 재등장 인물이 나뉘거나 유사한 얼굴이 잘못 묶일 수 있습니다. 썸네일을 확인하고 후보 그룹을 수정하세요. 분석 누락은 영역 마스크·키프레임으로 보완하세요.")
                    item("자동 자막", "Apple Speech의 기기 내 음성 인식만 사용합니다. 사용 권한과 해당 언어의 기기 내 지원이 필요합니다. 45초 단위로 처리하므로 경계에서 단어가 누락될 수 있습니다. 지원이 없을 때 서버 전송으로 전환하지 않습니다. SRT 가져오기·직접 입력·수정·SRT 내보내기를 지원합니다. SRT 출력 시간에는 컷 삭제가 반영됩니다.")
                    item("컷 편집·범위", "타임라인은 편집 결과 시간입니다. 삭제하면 뒤 컷이 앞으로 붙습니다. 컷을 클릭해 선택하고 ⌘X/⌘C/⌘V로 잘라내기·복사·붙여넣기를 하세요. 여러 컷은 ⌘클릭 또는 ⌘A로 선택합니다. 컷을 드래그해 다른 컷 앞에 놓거나 화살표 버튼으로 이동합니다. I/O 또는 범위 손잡이로 내보내기 시작·끝을 정합니다. 지정 범위는 MP4와 SRT 모두에 적용됩니다. 컷 길이·순서를 바꾸면 범위는 전체로 초기화됩니다. 영역 마스크·자막 편집의 시간 입력은 편집 시간입니다.")
                    item("프로젝트·복구", "프로젝트는 원본 경로와 편집 데이터·얼굴 썸네일을 저장합니다. 미디어가 포함되지 않으므로 원본 파일을 이동하거나 바꾸지 마세요. 편집 중 마지막 작업을 이 Mac의 Application Support/VeilStudio에 자동 저장합니다. 파일 메뉴에서 복구할 수 있습니다. 자동 저장과 프로젝트 파일에도 얼굴 정보가 포함됩니다.")
                }.padding(.trailing,8)
            }
            HStack { Text("Veil Studio 0.5 · 제작자 다있쌤 로디").font(.system(size:10)).foregroundStyle(Color.muted); Spacer(); Button("확인") { dismiss() }.buttonStyle(ActionStyle(primary:true)) }
        }.padding(28).frame(width:650,height:660).background(Color.panel).foregroundStyle(Color.ink)
    }
    func item(_ title: String,_ text: String) -> some View { VStack(alignment:.leading,spacing:7) { Text(title).font(.system(size:13,weight:.semibold)).foregroundStyle(Color.accent); Text(text).font(.system(size:12)).foregroundStyle(Color.muted).lineSpacing(4).fixedSize(horizontal:false,vertical:true) } }
}
