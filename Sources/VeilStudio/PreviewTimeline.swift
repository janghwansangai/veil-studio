import SwiftUI
import AVKit

final class PlayerSurface: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) { super.init(frame:frame); wantsLayer = true; layer?.addSublayer(playerLayer); playerLayer.videoGravity = .resizeAspect }
    required init?(coder: NSCoder) { nil }
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
            let pad = 20.0; let available = CGSize(width:max(1,geo.size.width-pad*2),height:max(1,geo.size.height-64))
            let ratio = store.loaded ? store.project.width/max(1,store.project.height) : 16/9
            let width = min(available.width,available.height*ratio); let height = width/max(0.01,ratio)
            ZStack {
                Color.base
                if store.loaded {
                    VStack(spacing:10) {
                        HStack {
                            let applied = store.project.media.contains(where:\.maskApplied)
                            Label(applied ? "마스킹 적용됨" : "원본 미리보기",systemImage:applied ? "checkmark.shield.fill" : "eye").foregroundStyle(applied ? Color.mint : Color.muted)
                            if !store.offlineMedia.isEmpty { Label("원본 \(store.offlineMedia.count)개 없음",systemImage:"exclamationmark.triangle.fill").foregroundStyle(.red) }
                            Spacer()
                            Text(store.project.isImage ? "IMAGE" : "\(Int(store.project.width))×\(Int(store.project.height)) · \(Int(store.project.fps.rounded())) FPS")
                        }.font(.system(size:9,weight:.medium)).frame(width:width)
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
                            overlays(width:width,height:height)
                        }.frame(width:width,height:height).clipShape(RoundedRectangle(cornerRadius:5)).shadow(color:.black.opacity(0.3),radius:14,y:8)
                        Text(hint).font(.system(size:9)).foregroundStyle(store.drawMode ? Color.accent : Color.muted).lineLimit(1)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                } else { welcome.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity) }
            }
        }
    }
    var hint: String {
        if store.drawMode { return "미리보기 위를 드래그해 가릴 영역을 지정하세요" }
        if store.tab == .titles { return "선택한 타이틀을 끌어 위치를 옮길 수 있습니다" }
        if store.inspector == .clip, store.selectedTrack.linkedToVideo, store.selectedClip != nil { return "선택한 클립: 상자를 끌어 위치, 오른쪽 아래 손잡이로 크기 조절" }
        return store.project.export.ratio == .original ? "\(Int(store.project.width)) × \(Int(store.project.height)) 캔버스" : "점선 안쪽이 내보내기 영역입니다 · 크롭 위치는 출력 설정에서 변경"
    }
    @ViewBuilder func overlays(width: Double, height: Double) -> some View {
        let size = CGSize(width:width,height:height)
        if store.tab == .regions, !store.drawMode, let r = store.project.regions.first(where:{$0.id == store.selectedRegion}), r.enabled, store.project.isImage || (store.overlayTime >= r.start && store.overlayTime < r.end) {
            RegionTransformOverlay(region:r,size:size)
        }
        if store.tab == .captions, let c = store.project.captions.first(where:{$0.id == store.selectedCaption}), store.overlayTime >= c.start, store.overlayTime < c.end {
            let font = max(12,min(width,height)*store.project.export.captionSize)
            let w = width*max(0.1,min(1,c.boxWidth ?? 0.86))
            let lines = max(1,min(5,Int(ceil(Double(c.text.count)*font*0.8/max(1,w)))+c.text.filter({$0 == "\n"}).count))
            let h = font*(Double(lines)*1.35+0.7)
            let x = (width-w)*(c.horizontal ?? 0.5)
            let y = c.vertical.map { (height-h)*$0 } ?? height*0.055
            Rectangle().strokeBorder(Color.orange,style:StrokeStyle(lineWidth:1.5,dash:[4,3])).frame(width:w,height:h).position(x:x+w/2,y:height-y-h/2).allowsHitTesting(false)
        }
        if store.tab == .titles, let t = store.project.titles.first(where:{ $0.id == store.selectedTitle }), store.playhead >= t.start, store.playhead < t.end {
            TitleMoveOverlay(title:t,size:size)
        }
        if store.inspector == .clip, !store.drawMode, store.tab != .titles, store.selectedTrack.linkedToVideo, let id = store.selectedClip,
           let entry = store.project.timeline.first(where:{ $0.id == id }), store.playhead >= entry.start, store.playhead < entry.end,
           let source = store.project.source(entry.clip.source), source.width > 0 {
            ClipTransformOverlay(entry:entry,source:source,size:size)
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
    }
    func clamp(_ p: CGPoint,width: Double,height: Double) -> CGPoint { CGPoint(x:min(width,max(0,p.x)),y:min(height,max(0,p.y))) }
    var welcome: some View {
        VStack(spacing:18) {
            ZStack {
                RoundedRectangle(cornerRadius:28).fill(Color.accent.opacity(0.05)).frame(width:108,height:108).rotationEffect(.degrees(-8))
                RoundedRectangle(cornerRadius:24).stroke(Color.accent.opacity(0.22),lineWidth:1).frame(width:92,height:92).rotationEffect(.degrees(7))
                Image(systemName:"person.crop.rectangle.badge.plus").font(.system(size:36,weight:.ultraLight)).foregroundStyle(Color.accent)
            }.padding(.bottom,6)
            VStack(spacing:10) { Text("기억은 선명하게,\n얼굴은 안전하게.").font(.system(size:28,weight:.semibold)).tracking(-1).multilineTextAlignment(.center); Text("영상·사진·오디오를 여러 개 한꺼번에 이곳에 놓아주세요.").font(.system(size:12)).foregroundStyle(Color.muted) }
            HStack(spacing:10) {
                Button(action:store.openMedia) { Label("미디어로 새 프로젝트",systemImage:"plus") }.buttonStyle(ActionStyle(primary:true))
                Button { store.openProject() } label: { Label("프로젝트 열기",systemImage:"square.stack") }.buttonStyle(ActionStyle())
            }
            Text("MOV · MP4 · M4V · JPEG · PNG · HEIC · M4A · WAV · MP3\n여러 파일을 고르면 순서대로 이어 붙이고, 폴더도 가져올 수 있습니다").font(.system(size:10)).foregroundStyle(Color.muted).lineSpacing(5).multilineTextAlignment(.center)
            HStack(spacing:24) {
                mini("sparkle.viewfinder","얼굴 찾기","01")
                mini("checkmark.shield","선택해 가리기","02")
                mini("captions.bubble","자동 자막","03")
                mini("arrow.up.right","안전하게 내보내기","04")
            }.padding(.top,16)
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

// On-screen position of a title; dragging moves its centre.
struct TitleMoveOverlay: View {
    @EnvironmentObject var store: EditorStore
    var title: TitleItem
    var size: CGSize
    @State private var origin: CGPoint?
    var body: some View {
        let font = max(8,min(size.width,size.height)*title.size)
        let w = min(size.width*0.92,max(font*2,Double(title.text.split(separator:"\n").map(\.count).max() ?? 1)*font*0.9)), h = font*1.4*Double(max(1,title.text.split(separator:"\n").count))
        Rectangle().strokeBorder(Color.pink,style:StrokeStyle(lineWidth:1.5,dash:[4,3])).background(Color.pink.opacity(0.06))
            .frame(width:w,height:h).position(x:size.width*title.x,y:size.height*(1-title.y))
            .contentShape(Rectangle()).onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { v in
                if origin == nil { origin = CGPoint(x:title.x,y:title.y); store.beginTimelineGesture() }
                guard let origin, let i = store.project.titles.firstIndex(where:{ $0.id == title.id }) else { return }
                store.project.titles[i].x = max(0,min(1,origin.x+v.translation.width/size.width))
                store.project.titles[i].y = max(0,min(1,origin.y-v.translation.height/size.height))
            }.onEnded { _ in origin = nil; store.endTimelineGesture() })
    }
}

// Frame of the selected clip on the canvas: drag to move, corner to scale.
struct ClipTransformOverlay: View {
    @EnvironmentObject var store: EditorStore
    var entry: TimelineEntry
    var source: MediaSource
    var size: CGSize
    @State private var origin: ClipTransform?
    var body: some View {
        let t = entry.clip.transform ?? ClipTransform()
        let canvas = store.project.size
        let base = t.fill ? max(canvas.width/source.width,canvas.height/source.height) : min(canvas.width/source.width,canvas.height/source.height)
        let view = size.width/max(1,canvas.width)
        let w = source.width*base*t.scale*view, h = source.height*base*t.scale*view
        let cx = size.width/2+t.x*size.width, cy = size.height/2-t.y*size.height
        Rectangle().strokeBorder(Color.yellow.opacity(0.9),lineWidth:1.5)
            .contentShape(Rectangle()).frame(width:w,height:h).rotationEffect(.degrees(t.rotation)).position(x:cx,y:cy)
            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { v in
                if origin == nil { origin = t; store.beginTimelineGesture() }
                guard let o = origin else { return }
                store.updateClips { c in var n = c.transform ?? ClipTransform(); n.x = max(-1,min(1,o.x+v.translation.width/size.width)); n.y = max(-1,min(1,o.y-v.translation.height/size.height)); c.transform = n }
            }.onEnded { _ in origin = nil; store.endTimelineGesture() })
            .overlay {
                Rectangle().fill(Color.yellow).frame(width:11,height:11).position(x:cx+w/2,y:cy+h/2)
                    .gesture(DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { v in
                        if origin == nil { origin = t; store.beginTimelineGesture() }
                        guard let o = origin else { return }
                        let grow = (v.translation.width/max(20,w)+v.translation.height/max(20,h))
                        store.updateClips { c in var n = c.transform ?? ClipTransform(); n.scale = max(0.05,min(10,o.scale*(1+grow))); c.transform = n }
                    }.onEnded { _ in origin = nil; store.endTimelineGesture() })
            }
            .help("클립 위치·크기 · 검사기에서 정확한 값을 입력할 수 있습니다")
    }
}
