import SwiftUI
import AVKit

final class PlayerSurface: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) { super.init(frame:frame); wantsLayer = true; layer?.addSublayer(playerLayer); playerLayer.videoGravity = .resizeAspect }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}
struct PlayerView: NSViewRepresentable {
    var player: AVPlayer
    func makeNSView(context: Context) -> PlayerSurface { let view = PlayerSurface(); view.playerLayer.player = player; return view }
    func updateNSView(_ view: PlayerSurface,context: Context) { view.playerLayer.player = player }
}
struct PreviewPane: View {
    @EnvironmentObject var store: EditorStore
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    var body: some View {
        GeometryReader { geo in
            let pad = 24.0; let available = CGSize(width:max(1,geo.size.width-pad*2),height:max(1,geo.size.height-72))
            let ratio = store.loaded ? store.project.width / max(1,store.project.height) : 16/9
            let width = min(available.width,available.height*ratio); let height = width/ratio
            ZStack {
                Color.base
                if store.loaded {
                    VStack(spacing:14) {
                        HStack { Label(store.project.maskApplied ? "마스킹 적용됨" : "원본 미리보기",systemImage:store.project.maskApplied ? "checkmark.shield.fill" : "eye").foregroundStyle(store.project.maskApplied ? Color.mint : Color.muted); Spacer(); Text(store.project.isImage ? "IMAGE" : "\(Int(store.project.fps.rounded())) FPS") }.font(.system(size:9,weight:.medium)).frame(width:width)
                        ZStack {
                            Color.black
                            if store.project.isImage { if let image = store.stillPreview { Image(nsImage:image).resizable().scaledToFit() } }
                            else { PlayerView(player:store.player) }
                            if store.project.export.ratio != .original {
                                let crop = store.project.export.cropRect(CGSize(width:width,height:height))
                                let flipped = CGRect(x:crop.minX,y:height-crop.maxY,width:crop.width,height:crop.height)
                                Path { path in path.addRect(CGRect(x:0,y:0,width:width,height:height)); path.addRect(flipped) }.fill(Color.black.opacity(0.6),style:FillStyle(eoFill:true)).allowsHitTesting(false)
                                Rectangle().strokeBorder(Color.white.opacity(0.75),style:StrokeStyle(lineWidth:1,dash:[5,4])).frame(width:flipped.width,height:flipped.height).position(x:flipped.midX,y:flipped.midY).allowsHitTesting(false)
                            }
                            if store.tab == .regions, !store.drawMode, let r = store.project.regions.first(where:{$0.id == store.selectedRegion}), r.enabled, store.project.isImage || (store.overlayTime >= r.start && store.overlayTime < r.end) {
                                RegionTransformOverlay(region:r,size:CGSize(width:width,height:height))
                            }
                            if store.tab == .captions, let c = store.project.captions.first(where:{$0.id == store.selectedCaption}), store.overlayTime >= c.start, store.overlayTime < c.end {
                                let font = max(12,min(width,height)*store.project.export.captionSize)
                                let w = width*max(0.1,min(1,c.boxWidth ?? 0.86))
                                let lines = max(1,min(5,Int(ceil(Double(c.text.count)*font*0.8/max(1,w)))+c.text.filter({$0 == "\n"}).count))
                                let h = font*(Double(lines)*1.35+0.7)
                                let x = (width-w)*(c.horizontal ?? 0.5)
                                let y = c.vertical.map { (height-h)*$0 } ?? height*0.055
                                Rectangle().strokeBorder(Color.orange,style:StrokeStyle(lineWidth:1.5,dash:[4,3]))
                                    .frame(width:w,height:h).position(x:x+w/2,y:height-y-h/2).allowsHitTesting(false)
                            }
                            if store.drawMode {
                                Color.white.opacity(0.001).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:1).onChanged { v in
                                    if dragStart == nil { dragStart = clamp(v.startLocation,width:width,height:height) }; dragEnd = clamp(v.location,width:width,height:height)
                                }.onEnded { _ in
                                    if let a = dragStart, let b = dragEnd { store.addRegion(NormalRect(x:min(a.x,b.x)/width,y:1-max(a.y,b.y)/height,width:abs(a.x-b.x)/width,height:abs(a.y-b.y)/height)) }
                                    dragStart = nil; dragEnd = nil
                                })
                                if let a = dragStart, let b = dragEnd {
                                    Rectangle().fill(Color.accent.opacity(0.15)).overlay(Rectangle().stroke(Color.accent,lineWidth:2)).frame(width:abs(a.x-b.x),height:abs(a.y-b.y)).position(x:(a.x+b.x)/2,y:(a.y+b.y)/2).allowsHitTesting(false)
                                }
                            }
                        }.frame(width:width,height:height).clipShape(RoundedRectangle(cornerRadius:5)).shadow(color:.black.opacity(0.3),radius:14,y:8)
                        Text(store.drawMode ? "미리보기 위를 드래그해 가릴 영역을 지정하세요" : store.project.export.ratio == .original ? "\(Int(store.project.width)) × \(Int(store.project.height))  ·  원본 좌표로 편집" : "점선 안쪽이 내보내기 영역입니다 · 크롭 위치는 내보내기 설정에서 변경")
                            .font(.system(size:9)).foregroundStyle(store.drawMode ? Color.accent : Color.muted)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                } else { welcome.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity) }
            }
        }
    }
    func clamp(_ p: CGPoint,width: Double,height: Double) -> CGPoint { CGPoint(x:min(width,max(0,p.x)),y:min(height,max(0,p.y))) }
    var welcome: some View {
        VStack(spacing:20) {
            ZStack {
                RoundedRectangle(cornerRadius:28).fill(Color.accent.opacity(0.05)).frame(width:108,height:108).rotationEffect(.degrees(-8))
                RoundedRectangle(cornerRadius:24).stroke(Color.accent.opacity(0.22),lineWidth:1).frame(width:92,height:92).rotationEffect(.degrees(7))
                Image(systemName:"person.crop.rectangle.badge.plus").font(.system(size:36,weight:.ultraLight)).foregroundStyle(Color.accent)
            }.padding(.bottom,8)
            VStack(spacing:10) { Text("기억은 선명하게,\n얼굴은 안전하게.").font(.system(size:28,weight:.semibold)).tracking(-1).multilineTextAlignment(.center); Text("영상과 사진을 이곳에 놓아주세요.").font(.system(size:12)).foregroundStyle(Color.muted) }
            Button(action:store.openMedia) { Label("미디어 불러오기",systemImage:"plus") }.buttonStyle(ActionStyle(primary:true)).keyboardShortcut("o",modifiers:.command)
            Text("MOV · MP4 · JPEG · PNG · HEIC 외\n파일 크기 제한 없이, Mac의 지원 코덱으로").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(5).multilineTextAlignment(.center)
            HStack(spacing:24) {
                mini("sparkle.viewfinder","얼굴 찾기","01")
                mini("checkmark.shield","선택해 가리기","02")
                mini("arrow.up.right","안전하게 내보내기","03")
            }.padding(.top,20)
        }
    }
    func mini(_ icon: String,_ title: String,_ number: String) -> some View { VStack(spacing:7) { Image(systemName:icon).font(.system(size:16)).foregroundStyle(Color.muted); Text(title).font(.system(size:9)).foregroundStyle(Color.muted); Text(number).font(.system(size:8,design:.monospaced)).foregroundStyle(Color.muted.opacity(0.5)) } }
}

struct RegionTransformOverlay: View {
    @EnvironmentObject var store: EditorStore
    var region: ManualRegion
    var size: CGSize
    @State private var origin: NormalRect?
    var body: some View {
        let rect = region.rect(at:store.overlayTime)
        let box = rect.scaled(to:size)
        Rectangle().fill(Color.accent.opacity(0.08))
            .overlay(Rectangle().strokeBorder(Color.accent,lineWidth:2))
            .contentShape(Rectangle()).onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }.gesture(drag(resize:false))
            .overlay(alignment:.bottomTrailing) {
                Rectangle().fill(Color.white).frame(width:12,height:12).contentShape(Rectangle()).onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }.gesture(drag(resize:true))
            }
            .frame(width:box.width,height:box.height).position(x:box.midX,y:size.height-box.midY)
            .help("드래그: 영역 이동 · 오른쪽 아래 손잡이: 크기 조절 · 키프레임이 있으면 현재 위치에 기록")
    }
    func drag(resize: Bool) -> some Gesture {
        DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { v in
            if origin == nil { store.pause(); origin = region.rect(at:store.overlayTime); store.beginTimelineGesture() }
            guard let origin else { return }
            var r = origin
            let dx = v.translation.width/size.width, dy = v.translation.height/size.height
            if resize {
                r.width = max(0.01,min(1-r.x,origin.width+dx))
                let top = origin.y+origin.height
                r.height = max(0.01,min(top,origin.height+dy)); r.y = top-r.height
            } else {
                r.x = max(0,min(1-r.width,origin.x+dx)); r.y = max(0,min(1-r.height,origin.y-dy))
            }
            store.editRegionRect(region.id,rect:r)
        }.onEnded { _ in origin = nil; store.endTimelineGesture() }
    }
}
