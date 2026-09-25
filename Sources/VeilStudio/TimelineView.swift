import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:14) {
                Label(store.selectedTrack.rawValue,systemImage:"slider.horizontal.below.rectangle").font(.system(size:11,weight:.semibold))
                Button(action:store.undo) { Image(systemName:"arrow.uturn.backward") }.disabled(store.undoStack.isEmpty)
                Button(action:store.redo) { Image(systemName:"arrow.uturn.forward") }.disabled(store.redoStack.isEmpty)
                Divider().frame(height:14)
                Button(action:store.split) { Label("분할",systemImage:"scissors") }.help("재생 위치에서 분할 ⌘B").disabled(!store.canEditTimeline)
                Button { store.editSelection("cut") } label: { Image(systemName:"scissors.badge.ellipsis") }.help("선택 컷 잘라내기 ⌘X").disabled(!store.selectionAvailable)
                Button { store.editSelection("copy") } label: { Image(systemName:"doc.on.doc") }.help("선택 컷 복사 ⌘C").disabled(!store.selectionAvailable)
                Button { store.editSelection("paste") } label: { Image(systemName:"doc.on.clipboard") }.help("재생 위치에 붙여넣기 ⌘V").disabled(!store.canEditTimeline || !store.pasteAvailable)
                Button { store.editSelection("delete") } label: { Image(systemName:"trash") }.help("선택 컷 삭제 후 붙이기 Delete").disabled(!store.selectionAvailable)
                Button { store.moveSelected(-1) } label: { Image(systemName:"arrow.left.to.line") }.help("선택 컷 앞으로 이동").disabled(!store.selectionAvailable)
                Button { store.moveSelected(1) } label: { Image(systemName:"arrow.right.to.line") }.help("선택 컷 뒤로 이동").disabled(!store.selectionAvailable)
                Spacer(minLength:8)
                if let clip = store.project.clips.first(where:{$0.id == store.selectedClip}) {
                    Text("원본 구간").foregroundStyle(Color.muted)
                    TextField("원본 시작",value:Binding(get:{clip.start},set:{store.trimClip(clip.id,start:$0)}),format:.number.precision(.fractionLength(2))).frame(width:64)
                    Text("–")
                    TextField("원본 끝",value:Binding(get:{clip.end},set:{store.trimClip(clip.id,end:$0)}),format:.number.precision(.fractionLength(2))).frame(width:64)
                }
                Text("편집 후 \(timecode(store.project.editedDuration))").foregroundStyle(Color.muted)
            }.font(.system(size:10)).frame(height:36)
            HStack(spacing:10) {
                Label("내보내기 구간",systemImage:"inset.filled.rectangle").foregroundStyle(Color.mint)
                Button("시작 I",action:store.markIn)
                Button("끝 O",action:store.markOut)
                TextField("내보내기 시작",value:Binding(get:{store.project.exportRange?.start ?? 0},set:{store.setExportRange(start:$0,end:store.project.exportRange?.end ?? store.project.editedDuration)}),format:.number.precision(.fractionLength(2))).frame(width:65)
                Text("–")
                TextField("내보내기 끝",value:Binding(get:{store.project.exportRange?.end ?? store.project.editedDuration},set:{store.setExportRange(start:store.project.exportRange?.start ?? 0,end:$0)}),format:.number.precision(.fractionLength(2))).frame(width:65)
                Text("초").foregroundStyle(Color.muted)
                Button("선택 컷 범위",action:store.exportSelectedClips).disabled(!store.selectionAvailable)
                Button("범위 해제") { store.project.exportRange = nil }.disabled(store.project.exportRange == nil)
                Button("범위 삭제",action:store.deleteMarkedRange).disabled(store.project.exportRange == nil)
                Spacer(minLength:4)
                Text("\(store.project.exportRange == nil ? "전체" : "지정 구간") · \(timecode(store.project.exportDuration))").foregroundStyle(Color.mint)
            }.font(.system(size:10)).frame(height:34).disabled(!store.canEditTimeline || store.project.clips.isEmpty)
            HStack {
                Menu("트랙 추가") {
                    Button("영상 트랙") { store.addLane(.video) }
                    Button("영역 마스크 트랙") { store.addLane(.regions) }
                    Button("자막 트랙") { store.addLane(.captions) }
                }
                Button("겹친 항목 분리") { store.project.separateOverlappingOverlays() }
                Text("블록 우클릭 → 트랙 이동 · 위쪽 트랙이 앞에 표시됩니다").foregroundStyle(Color.muted)
                Spacer()
            }.font(.system(size:10)).frame(height:25)
            GeometryReader { geometry in
                let timelineWidth = max(1,geometry.size.width-133)
                VStack(alignment:.leading,spacing:4) {
                    HStack(spacing:12) {
                        Text("편집 시간").font(.system(size:9)).frame(width:105,alignment:.leading)
                        TimelineRuler().frame(width:timelineWidth,height:44)
                    }
                    ScrollView(.vertical) {
                        HStack(alignment:.top,spacing:12) {
                            VStack(alignment:.leading,spacing:0) {
                                ForEach(store.timelineRows) { row in
                                    Button(row.title) { store.selectLane(row.kind,lane:row.lane) }
                                        .foregroundStyle((store.selectedTrack == row.kind || store.selectedTrack.linkedToVideo && row.kind.linkedToVideo) && store.selectedLane == row.lane ? Color.accent : Color.muted)
                                        .frame(height:31)
                                }
                            }.font(.system(size:9)).frame(width:105,alignment:.leading)
                            TimelineLanes().frame(width:timelineWidth,height:Double(store.timelineRows.count)*31)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }.scrollIndicators(.visible)
                }.frame(maxWidth:.infinity,alignment:.leading)
                    .overlay(alignment:.topLeading) {
                        Rectangle().fill(Color.white).frame(width:1).offset(x:117+timelineWidth*store.playhead/max(0.01,store.project.editedDuration)).allowsHitTesting(false)
                    }
            }.padding(.top,4)
            Text("컷: 순서 이동 · 자막/영역: 시간 이동 · 양 끝: 길이 조절 · 겹친 영역은 왼쪽 목록에서 선택")
                .font(.system(size:9)).foregroundStyle(Color.muted).frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,8)
        }.buttonStyle(.plain).textFieldStyle(.roundedBorder).padding(.horizontal,18).background(Color.panel.opacity(0.5))
    }
}

struct TimelineLanes: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(0.01,store.project.editedDuration)
            VStack(alignment:.leading,spacing:6) {
                ForEach(store.timelineRows) { row in
                    ZStack(alignment:.leading) {
                        RoundedRectangle(cornerRadius:3).fill(Color.raised.opacity(0.4))
                            .dropDestination(for:String.self) { values,point in
                                guard let raw = values.first, let id = UUID(uuidString:raw) else { return false }
                                store.moveItem(id,to:row.kind,lane:row.lane,at:point.x/width*duration); return true
                            }
                        if row.kind.linkedToVideo {
                            ForEach(Array(store.project.gaps(in:row.lane).enumerated()),id:\.offset) { _,gap in
                                Color.white.opacity(0.001).frame(width:width*gap.duration/duration,height:25).contentShape(Rectangle())
                                    .contextMenu { Button("빈 구간 삭제 후 붙이기") { store.closeGap(gap,lane:row.lane) } }
                                    .offset(x:width*gap.start/duration)
                            }
                            ForEach(store.project.timeline.filter { ($0.clip.lane ?? 0) == row.lane }) { entry in
                                ZStack {
                                    if row.kind == .video { TimelineClipCell(entry:entry,pixelsPerSecond:width/duration) }
                                    else { LinkedClipCell(entry:entry,kind:row.kind) }
                                }.frame(width:max(1,width*entry.clip.duration/duration),height:25).offset(x:width*entry.start/duration)
                            }
                        } else {
                            ForEach(store.project.overlayItems(regionsOnly:row.kind == .regions).filter { item in
                                row.kind == .regions ? (store.project.regions.first(where:{$0.id == item.sourceID})?.lane ?? 0) == row.lane : (store.project.captions.first(where:{$0.id == item.sourceID})?.lane ?? 0) == row.lane
                            }) { item in
                                OverlayTimelineBlock(item:item,scale:width/duration)
                                    .frame(width:max(22,width*(item.end-item.start)/duration),height:25).offset(x:width*item.start/duration)
                            }
                        }
                    }.frame(width:width,height:25)
                }

            }.frame(width:width,height:geo.size.height,alignment:.topLeading).clipped()
        }
    }
}
struct TimelineRuler: View {
    @EnvironmentObject var store: EditorStore
    @State private var rangeGesture = false
    @State private var rangeOrigin = 0.0
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(0.01,store.project.editedDuration)
            ZStack(alignment:.topLeading) {
                Canvas { context,size in
                    for tick in 0...60 {
                        let x = width*Double(tick)/60
                        let major = tick%10 == 0
                        var line = Path(); line.move(to:CGPoint(x:x,y:major ? 19 : 27)); line.addLine(to:CGPoint(x:x,y:40))
                        context.stroke(line,with:.color(major ? Color.muted : Color.muted.opacity(0.4)),lineWidth:1)
                    }
                }.allowsHitTesting(false)
                HStack { ForEach(0..<7) { n in Text(timecode(duration*Double(n)/6)).font(.system(size:8,design:.monospaced)); if n < 6 { Spacer() } } }.frame(height:16).allowsHitTesting(false)
                TimelineWheelSurface(seek:{ fraction in store.focusTimeline(); store.seek(fraction*duration) },wheel:{ delta,precise,fine in
                    store.focusTimeline(); store.pause(); store.seek(timelineWheelDestination(current:store.playhead,delta:delta,precise:precise,fine:fine,duration:duration))
                }).help("클릭·드래그로 이동 · 휠로 재생 위치 이동 · Shift+휠 미세 이동")
                if let range = store.project.exportRange {
                    Rectangle().fill(Color.mint).frame(width:width*range.duration/duration,height:3).offset(x:width*range.start/duration,y:40).allowsHitTesting(false)
                    rangeHandle(isStart:true,time:range.start,width:width,duration:duration)
                    rangeHandle(isStart:false,time:range.end,width:width,duration:duration)
                }
            }
        }
    }
    func rangeHandle(isStart: Bool,time: Double,width: Double,duration: Double) -> some View {
        RoundedRectangle(cornerRadius:2).fill(Color.mint).frame(width:8,height:20)
            .overlay(Text(isStart ? "I" : "O").font(.system(size:7,weight:.bold)).foregroundStyle(Color.base))
            .contentShape(Rectangle()).position(x:max(4,min(width-4,width*time/duration)),y:30)
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.global).onChanged { v in
                if !rangeGesture { rangeOrigin = time; store.beginTimelineGesture(); rangeGesture = true }
                let next = rangeOrigin+v.translation.width/width*duration
                if isStart { store.setExportRange(start:next,end:store.project.exportRange?.end ?? duration) }
                else { store.setExportRange(start:store.project.exportRange?.start ?? 0,end:next) }
            }.onEnded { _ in store.endTimelineGesture(); rangeGesture = false })
    }
}
struct TimelineClipCell: View {
    @EnvironmentObject var store: EditorStore
    var entry: TimelineEntry
    var pixelsPerSecond: Double
    @State private var trimOrigin: Double?
    @State private var trimScale = 1.0
    var body: some View {
        GeometryReader { geo in
            HStack(spacing:4) {
                Image(systemName:"film")
                Text("컷 \(entry.index+1)").lineLimit(1)
                if geo.size.width > 130 { Text(timecode(entry.clip.duration)).foregroundStyle(Color.muted) }
                Spacer(minLength:0)
            }.font(.system(size:9)).padding(.horizontal,8).frame(maxWidth:.infinity,maxHeight:.infinity)
                .background(Color.accent.opacity(((store.selectedTrack.linkedToVideo) && store.selectedClips.contains(entry.id)) ? 0.4 : 0.18),in:RoundedRectangle(cornerRadius:4))
                .overlay(RoundedRectangle(cornerRadius:4).stroke(((store.selectedTrack.linkedToVideo) && store.selectedClips.contains(entry.id)) ? Color.accent : Color.accent.opacity(0.25),lineWidth:1))
                .contentShape(Rectangle())
                .onTapGesture { store.selectClip(entry.id,extending:NSApp.currentEvent?.modifierFlags.contains(.command) == true); store.seek(entry.start) }
                .draggable(entry.id.uuidString)
                .dropDestination(for:String.self) { values,point in
                    guard let raw = values.first, let id = UUID(uuidString:raw), store.project.clips.contains(where:{$0.id == id}) else { return false }
                    let next = entry.index+1 < store.project.clips.count ? store.project.clips[entry.index+1].id : nil
                    store.moveClip(id,before:point.x < geo.size.width/2 ? entry.id : next); return true
                }
                .contextMenu {
                    Menu("트랙으로 이동") {
                        ForEach(0..<store.laneCount(.video),id:\.self) { lane in Button("영상 \(lane+1)") { store.moveItem(entry.id,to:.video,lane:lane) } }
                        Button("새 영상 트랙") { store.addLane(.video); store.moveItem(entry.id,to:.video,lane:store.selectedLane) }
                    }
                    Button("이 컷 선택") { store.selectClip(entry.id) }
                    Button("복사") { store.selectClip(entry.id); store.copyClips() }
                    Button("잘라내기") { store.selectClip(entry.id); store.cutClips() }
                    Button("삭제 후 붙이기") { store.selectClip(entry.id); store.deleteClip() }
                    Button("앞으로 이동") { store.selectClip(entry.id); store.moveSelected(-1) }
                    Button("뒤로 이동") { store.selectClip(entry.id); store.moveSelected(1) }
                    Button("이 컷만 내보내기") { store.selectClip(entry.id); store.exportSelectedClips() }
                }
                .overlay(alignment:.leading) { if geo.size.width > 24 { trimHandle(start:true) } }
                .overlay(alignment:.trailing) { if geo.size.width > 24 { trimHandle(start:false) } }
                .help("\(timecode(entry.clip.start))–\(timecode(entry.clip.end)) 원본 구간 · 드래그해서 순서 이동")
        }
    }
    func trimHandle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius:2).fill(Color.white.opacity(0.55)).frame(width:5,height:18).padding(.horizontal,1)
            .contentShape(Rectangle()).onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }.gesture(DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { value in
                if trimOrigin == nil { trimOrigin = start ? entry.clip.start : entry.clip.end; trimScale = max(0.001,pixelsPerSecond); store.beginTimelineGesture(); store.selectClip(entry.id) }
                let time = (trimOrigin ?? 0)+value.translation.width/trimScale
                if start { store.trimClip(entry.id,start:time) } else { store.trimClip(entry.id,end:time) }
            }.onEnded { _ in trimOrigin = nil; store.endTimelineGesture() })
    }
}

struct TimelineWheelSurface: NSViewRepresentable {
    var seek: (Double) -> Void
    var wheel: (Double,Bool,Bool) -> Void
    func makeNSView(context: Context) -> Surface { let view = Surface(); view.setAccessibilityElement(true); view.setAccessibilityRole(.group); view.setAccessibilityLabel("시간 눈금 · 클릭 및 휠로 재생 위치 이동"); return view }
    func updateNSView(_ view: Surface, context: Context) { view.seek = seek; view.wheel = wheel }
    final class Surface: NSView {
        var seek: (Double) -> Void = { _ in }
        var wheel: (Double,Bool,Bool) -> Void = { _,_,_ in }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds,cursor:.pointingHand) }
        override func mouseDown(with event: NSEvent) { move(event) }
        override func mouseDragged(with event: NSEvent) { move(event) }
        private func move(_ event: NSEvent) { let point = convert(event.locationInWindow,from:nil); seek(min(1,max(0,point.x/max(1,bounds.width)))) }
        override func scrollWheel(with event: NSEvent) {
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            wheel(delta,event.hasPreciseScrollingDeltas,event.modifierFlags.contains(.shift))
        }
    }
}

private struct WaveformRenderKey: Equatable {
    var revision: Int
    var width: Int
    var clips: [Clip]
    var duration: Double
}
struct AudioWaveformLane: View {
    var clip: Clip? = nil
    @EnvironmentObject var store: EditorStore
    @State private var bars = Path()
    var body: some View {
        GeometryReader { geo in
            let key = WaveformRenderKey(revision:store.waveformRevision,width:Int(geo.size.width),clips:clip.map { [$0] } ?? store.project.clips,duration:clip?.duration ?? store.project.editedDuration)
            ZStack(alignment:.leading) {
                Canvas { context,size in
                    context.fill(bars,with:.color(store.project.export.muted ? Color.muted.opacity(0.5) : Color.cyan.opacity(0.8)))
                    var center = Path(); center.move(to:CGPoint(x:0,y:size.height/2)); center.addLine(to:CGPoint(x:size.width,y:size.height/2))
                    context.stroke(center,with:.color(Color.cyan.opacity(0.2)),lineWidth:0.5)
                }.allowsHitTesting(false)
                if !store.waveformStatus.isEmpty { Text(store.waveformStatus).font(.system(size:9)).foregroundStyle(Color.muted).padding(.horizontal,8) }
            }.onAppear { rebuild(width:key.width) }.onChange(of:key) { rebuild(width:key.width) }
        }.help("원본 첫 번째 오디오의 파형 · 영상 컷과 함께 잘리고 이동합니다")
    }
    private func rebuild(width: Int) {
        var path = Path()
        guard width > 0, let data = store.waveform, data.hasAudio, store.project.editedDuration > 0 else { bars = path; return }
        let duration = clip?.duration ?? store.project.editedDuration
        let entries = clip.map { [TimelineEntry(clip:$0,index:0,start:0)] } ?? store.project.visibleTimeline
        for entry in entries {
            let left = max(0,Int(floor(entry.start/duration*Double(width))))
            let right = min(width,Int(ceil(entry.end/duration*Double(width))))
            guard right > left else { continue }
            for x in left..<right {
                let a = max(entry.start,Double(x)/Double(width)*duration)
                let b = min(entry.end,Double(x+1)/Double(width)*duration)
                let peak = data.peak(from:entry.clip.start+a-entry.start,to:entry.clip.start+b-entry.start)
                let h = Double(sqrt(peak))*23
                if h > 0 { path.addRect(CGRect(x:Double(x),y:12.5-h/2,width:1,height:h)) }
            }
        }
        bars = path
    }
}


struct LinkedClipCell: View {
    @EnvironmentObject var store: EditorStore
    let entry: TimelineEntry
    let kind: EditTrack
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius:3).fill((kind == .audio ? Color.cyan : Color.mint).opacity(0.1))
            if kind == .audio { AudioWaveformLane(clip:entry.clip) }
            else {
                Canvas { context,size in
                    for span in store.faceSourceCoverage where span.end > entry.clip.start && span.start < entry.clip.end {
                        let a = max(entry.clip.start,span.start), b = min(entry.clip.end,span.end)
                        let x = (a-entry.clip.start)/entry.clip.duration*size.width
                        context.fill(Path(CGRect(x:x,y:0,width:max(1,(b-a)/entry.clip.duration*size.width),height:size.height)),with:.color(Color.mint.opacity(0.5)))
                    }
                }.allowsHitTesting(false)
            }
            if store.selectedTrack.linkedToVideo && store.selectedClips.contains(entry.id) { RoundedRectangle(cornerRadius:3).stroke(Color.accent,lineWidth:1).allowsHitTesting(false) }
        }.contentShape(Rectangle())
            .onTapGesture { store.selectClip(entry.id,extending:NSApp.currentEvent?.modifierFlags.contains(.command) == true); store.selectedTrack = kind; store.seek(entry.start) }
            .draggable(entry.id.uuidString)
            .contextMenu {
                Menu("연결된 세트 트랙 이동") {
                    ForEach(0..<store.laneCount(.video),id:\.self) { lane in Button("영상 세트 \(lane+1)") { store.moveItem(entry.id,to:.video,lane:lane) } }
                    Button("새 영상 세트") { store.addLane(.video); store.moveItem(entry.id,to:.video,lane:store.selectedLane) }
                }
                Button("연결된 세트 삭제") { store.selectClip(entry.id); store.deleteClip() }
            }
    }
}
