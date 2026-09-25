import SwiftUI

func rowHeight(_ kind: EditTrack) -> Double {
    switch kind { case .video: return 46; case .audio: return 26; case .faces: return 12; case .music: return 30; default: return 24 }
}
let rowSpacing = 3.0
let timelineLabelWidth = 118.0

struct TimelineView: View {
    @EnvironmentObject var store: EditorStore
    @ObservedObject var viewport: TimelineViewport
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing:0) {
            toolbar
            rangeBar
            GeometryReader { geo in
                let trackWidth = max(100,geo.size.width-timelineLabelWidth-6)
                let rows = store.timelineRows
                let totalHeight = rows.reduce(0) { $0+rowHeight($1.kind)+rowSpacing }
                VStack(alignment:.leading,spacing:4) {
                    HStack(spacing:6) {
                        Text("편집 시간").font(.system(size:9)).foregroundStyle(Color.muted).frame(width:timelineLabelWidth,alignment:.leading)
                        TimelineRuler(viewport:viewport).frame(width:trackWidth,height:44).clipped()
                    }
                    ScrollView(.vertical) {
                        HStack(alignment:.top,spacing:6) {
                            VStack(alignment:.leading,spacing:rowSpacing) {
                                ForEach(rows) { row in
                                    Button { store.selectLane(row.kind,lane:row.lane) } label: {
                                        HStack(spacing:4) {
                                            Image(systemName:icon(row.kind)).font(.system(size:8))
                                            Text(row.title).lineLimit(1)
                                        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).contentShape(Rectangle())
                                    }
                                    .foregroundStyle(highlighted(row) ? Color.accent : Color.muted)
                                    .frame(width:timelineLabelWidth,height:rowHeight(row.kind),alignment:.leading)
                                }
                            }.font(.system(size:9))
                            TimelineLanes(viewport:viewport,rows:rows).frame(width:trackWidth,height:totalHeight)
                                .background(TimelineScrollMonitor(viewport:viewport))
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }.scrollIndicators(.visible)
                    HStack(spacing:6) {
                        Color.clear.frame(width:timelineLabelWidth,height:10)
                        TimelineScrollBar(viewport:viewport).frame(width:trackWidth,height:10)
                    }
                }
                .overlay(alignment:.topLeading) {
                    // Explicit top-leading stack: the line spans ruler and lanes, the head sits on the ruler.
                    let x = viewport.x(store.playhead)
                    ZStack(alignment:.topLeading) {
                        if x >= -1, x <= trackWidth+1 {
                            Rectangle().fill(Color.white).frame(width:1).frame(maxHeight:.infinity).offset(x:timelineLabelWidth+6+x)
                            Triangle().fill(Color.white).frame(width:11,height:8).offset(x:timelineLabelWidth+6+x-5,y:36)
                        }
                    }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).allowsHitTesting(false)
                }
                .onAppear { viewport.update(width:trackWidth,duration:store.project.editedDuration) }
                .onChange(of:trackWidth) { viewport.update(width:trackWidth,duration:store.project.editedDuration) }
                .onChange(of:store.project.editedDuration) { viewport.update(width:trackWidth,duration:store.project.editedDuration) }
                .onChange(of:store.playhead) { if store.playing { viewport.follow(store.playhead) } }
            }.padding(.top,4)
            Text(store.tool == .blade ? "자르기 도구: 블록을 클릭하면 그 위치에서 나뉩니다 · A 키로 선택 도구" : "클릭: 선택 · 드래그: 이동/트랙 변경 · 양 끝: 길이 조절 · ⌥휠: 확대 · 가로 휠/Shift+휠: 이동 · 미디어를 끌어다 놓아 배치")
                .font(.system(size:9)).foregroundStyle(store.tool == .blade ? Color.orange : Color.muted).frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,6)
        }.buttonStyle(.hover).textFieldStyle(.roundedBorder).padding(.horizontal,14).background(Color.panel.opacity(0.5))
    }
    func highlighted(_ row: TimelineRow) -> Bool { (store.selectedTrack == row.kind || store.selectedTrack.linkedToVideo && row.kind.linkedToVideo) && store.selectedLane == row.lane }
    func icon(_ kind: EditTrack) -> String {
        switch kind { case .video: return "film"; case .audio: return "waveform"; case .faces: return "person.crop.square"; case .regions: return "viewfinder"; case .captions: return "captions.bubble"; case .titles: return "textformat"; case .music: return "music.note" }
    }
    var toolbar: some View {
        HStack(spacing:11) {
            Label(store.selectedTrack.rawValue,systemImage:"slider.horizontal.below.rectangle").font(.system(size:11,weight:.semibold)).lineLimit(1)
            Button(action:store.undo) { Image(systemName:"arrow.uturn.backward") }.disabled(store.undoStack.isEmpty).help("실행 취소 ⌘Z")
            Button(action:store.redo) { Image(systemName:"arrow.uturn.forward") }.disabled(store.redoStack.isEmpty).help("다시 실행 ⇧⌘Z")
            Divider().frame(height:14)
            Picker("",selection:$store.tool) { Image(systemName:"cursorarrow").tag(EditTool.select); Image(systemName:"scissors").tag(EditTool.blade) }.pickerStyle(.segmented).frame(width:74).labelsHidden().help("선택 도구 A · 자르기 도구 B")
            Button(action:store.split) { Label("분할",systemImage:"square.split.1x2") }.help("재생 위치에서 분할 ⌘B").disabled(!store.canEditTimeline)
            Button { store.editSelection("cut") } label: { Image(systemName:"scissors.badge.ellipsis") }.help("잘라내기 ⌘X").disabled(!store.selectionAvailable)
            Button { store.editSelection("copy") } label: { Image(systemName:"doc.on.doc") }.help("복사 ⌘C").disabled(!store.selectionAvailable)
            Button { store.editSelection("paste") } label: { Image(systemName:"doc.on.clipboard") }.help("재생 위치에 붙여넣기 ⌘V").disabled(!store.canEditTimeline || !store.pasteAvailable)
            Button { store.editSelection("delete") } label: { Image(systemName:"trash") }.help("삭제 Delete").disabled(!store.selectionAvailable)
            Button { store.moveSelected(-1) } label: { Image(systemName:"arrow.left.to.line") }.help("선택 항목 앞으로 ⌥⌘←").disabled(!store.selectionAvailable)
            Button { store.moveSelected(1) } label: { Image(systemName:"arrow.right.to.line") }.help("선택 항목 뒤로 ⌥⌘→").disabled(!store.selectionAvailable)
            Divider().frame(height:14)
            Button { store.addMarker() } label: { Image(systemName:"bookmark") }.help("마커 추가 M").disabled(!store.canEditTimeline)
            Toggle(isOn:$store.snapping) { Image(systemName:"arrow.right.and.line.vertical.and.arrow.left") }.toggleStyle(.button).help("스냅 N")
            Spacer(minLength:6)
            if let clip = store.project.clips.first(where:{$0.id == store.selectedClip}), clip.freeze == nil {
                Text("원본").foregroundStyle(Color.muted)
                TextField("원본 시작",value:Binding(get:{clip.start},set:{store.trimClip(clip.id,start:$0)}),format:.number.precision(.fractionLength(2))).frame(width:58)
                Text("–")
                TextField("원본 끝",value:Binding(get:{clip.end},set:{store.trimClip(clip.id,end:$0)}),format:.number.precision(.fractionLength(2))).frame(width:58)
            }
            Button { viewport.zoom(by:1/1.5) } label: { Image(systemName:"minus.magnifyingglass") }.help("축소 ⌘-")
            Slider(value:Binding(get:{viewport.zoomLevel},set:{viewport.zoomLevel = $0}),in:0...1).frame(width:90).controlSize(.mini)
            Button { viewport.zoom(by:1.5,around:store.playhead) } label: { Image(systemName:"plus.magnifyingglass") }.help("확대 ⌘=")
            Button("전체") { viewport.fit() }.help("타임라인 전체 보기 ⇧Z")
            Text(frameTimecode(store.project.editedDuration,fps:store.project.fps)).font(.system(size:10,design:.monospaced)).foregroundStyle(Color.muted)
            if !store.timelineDetached {
                Button { openWindow(id:DetachedWindow.timeline) } label: { Image(systemName:"macwindow.on.rectangle") }.help("타임라인을 별도 창으로 분리합니다. 다른 모니터로 옮길 수 있습니다 (⌥⌘T)")
            }
        }.font(.system(size:10)).frame(height:34)
    }
    var rangeBar: some View {
        HStack(spacing:9) {
            Label("내보내기 구간",systemImage:"inset.filled.rectangle").foregroundStyle(Color.mint)
            Button("시작 I",action:store.markIn).help("재생 위치를 내보내기 시작점으로 지정합니다 (I)")
            Button("끝 O",action:store.markOut).help("재생 위치를 내보내기 끝점으로 지정합니다 (O)")
            TextField("내보내기 시작",value:Binding(get:{store.project.exportRange?.start ?? 0},set:{store.setExportRange(start:$0,end:store.project.exportRange?.end ?? store.project.editedDuration)}),format:.number.precision(.fractionLength(2))).frame(width:62)
            Text("–")
            TextField("내보내기 끝",value:Binding(get:{store.project.exportRange?.end ?? store.project.editedDuration},set:{store.setExportRange(start:store.project.exportRange?.start ?? 0,end:$0)}),format:.number.precision(.fractionLength(2))).frame(width:62)
            Button("선택 범위",action:store.exportSelectedClips).help("선택한 컷(또는 블록)의 시작~끝을 내보내기 구간으로 지정합니다").disabled(!store.selectionAvailable)
            Button("해제") { store.project.exportRange = nil }.help("내보내기 구간을 지우고 전체를 내보냅니다").disabled(store.project.exportRange == nil)
            Button("범위 삭제",action:store.deleteMarkedRange).help("지정 구간을 지우고 뒤의 내용을 앞으로 붙입니다").disabled(store.project.exportRange == nil)
            Divider().frame(height:14)
            Menu("트랙 추가") {
                Button("영상 트랙") { store.addLane(.video) }
                Button("독립 오디오 트랙") { store.addLane(.music) }
                Button("타이틀 트랙") { store.addLane(.titles) }
                Button("영역 마스크 트랙") { store.addLane(.regions) }
                Button("자막 트랙") { store.addLane(.captions) }
            }.frame(width:78)
            Button("겹침 분리") { store.project.separateOverlappingOverlays() }.help("같은 트랙에서 겹친 자막·영역·타이틀을 다른 트랙으로 나눕니다")
            Spacer(minLength:4)
            Text("\(store.project.exportRange == nil ? "전체" : "지정 구간") · \(timecode(store.project.exportDuration))").foregroundStyle(Color.mint)
        }.font(.system(size:10)).frame(height:30).disabled(!store.canEditTimeline || store.project.editedDuration <= 0)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path { var p = Path(); p.move(to:CGPoint(x:r.minX,y:r.minY)); p.addLine(to:CGPoint(x:r.maxX,y:r.minY)); p.addLine(to:CGPoint(x:r.midX,y:r.maxY)); p.closeSubpath(); return p }
}

// Horizontal scroll and zoom for the lanes: horizontal wheel or Shift+wheel scrolls, ⌥/⌘+wheel
// zooms around the pointer. Plain vertical wheel keeps scrolling the track list.
struct TimelineScrollMonitor: NSViewRepresentable {
    @ObservedObject var viewport: TimelineViewport
    func makeNSView(context: Context) -> MonitorView { let v = MonitorView(); v.viewport = viewport; return v }
    func updateNSView(_ view: MonitorView, context: Context) { view.viewport = viewport }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }
    final class MonitorView: NSView {
        weak var viewport: TimelineViewport?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching:.scrollWheel) { [weak self] event in
                guard let self, let viewport = self.viewport, event.window === self.window else { return event }
                let local = self.convert(event.locationInWindow,from:nil)
                guard let clip = self.visibleRectInSuperview, clip.contains(local) else { return event }
                let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
                let scale = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
                if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
                    let factor = pow(1.01,Double(dy+dx)*(event.hasPreciseScrollingDeltas ? 1 : 6))
                    MainActor.assumeIsolated { viewport.zoom(by:factor,around:viewport.time(local.x)) }
                    return nil
                }
                if abs(dx) > abs(dy) || event.modifierFlags.contains(.shift) {
                    let delta = abs(dx) > abs(dy) ? dx : dy
                    MainActor.assumeIsolated { viewport.scroll(seconds:-Double(delta)*scale/viewport.pixelsPerSecond) }
                    return nil
                }
                return event
            }
        }
        // Only the part of the lanes actually shown by the enclosing scroll view.
        private var visibleRectInSuperview: CGRect? { let r = visibleRect; return r.isEmpty ? nil : r }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct TimelineScrollBar: View {
    @ObservedObject var viewport: TimelineViewport
    @State private var origin: Double?
    var body: some View {
        GeometryReader { geo in
            let total = max(viewport.duration*1.05,viewport.visible.end)
            let w = geo.size.width
            let thumb = max(24,w*min(1,(viewport.visible.end-viewport.visible.start)/max(0.001,total)))
            let x = (w-thumb)*min(1,max(0,viewport.offset/max(0.001,total-(viewport.visible.end-viewport.visible.start))))
            ZStack(alignment:.leading) {
                Capsule().fill(Color.raised.opacity(0.6))
                Capsule().fill(Color.muted.opacity(0.7)).frame(width:thumb).offset(x:x.isFinite ? x : 0)
                    .gesture(DragGesture(minimumDistance:0).onChanged { v in
                        if origin == nil { origin = viewport.offset }
                        let span = viewport.visible.end-viewport.visible.start
                        let seconds = v.translation.width/max(1,w-thumb)*max(0.001,total-span)
                        viewport.offset = (origin ?? 0)+seconds; viewport.fitted = false; viewport.clamp()
                    }.onEnded { _ in origin = nil })
            }
        }.help("드래그해서 타임라인 이동")
    }
}

struct TimelineLanes: View {
    @EnvironmentObject var store: EditorStore
    @ObservedObject var viewport: TimelineViewport
    let rows: [TimelineRow]
    var body: some View {
        let entries = store.project.timeline
        let visible = viewport.visible
        let pps = viewport.pixelsPerSecond
        let total = rows.reduce(0) { $0+rowHeight($1.kind)+rowSpacing }
        // Rows are stacked, not offset, so each track always sits beside its label.
        VStack(alignment:.leading,spacing:rowSpacing) {
            ForEach(rows) { row in
                let h = rowHeight(row.kind)
                ZStack(alignment:.topLeading) {
                    RoundedRectangle(cornerRadius:3).fill(Color.raised.opacity(row.kind == .faces ? 0.25 : 0.4))
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            if store.tool == .blade { return }
                            store.selectLane(row.kind,lane:row.lane); store.seek(viewport.time(location.x))
                        }
                        .dropDestination(for:String.self) { values,point in
                            guard let raw = values.first else { return false }
                            return store.dropMedia(raw,at:store.snapTime(viewport.time(point.x),pixelsPerSecond:pps),row:row)
                        }
                    rowContent(row,entries:entries,visible:visible,height:h)
                }.frame(width:viewport.width,height:h,alignment:.topLeading)
            }
            Spacer(minLength:0)
        }
        .frame(width:viewport.width,height:total,alignment:.topLeading)
        .overlay(alignment:.topLeading) {
            ZStack(alignment:.topLeading) {
                ForEach(store.project.markers.filter { visible.contains($0.time) }) { marker in
                    Rectangle().fill(Color.orange.opacity(0.45)).frame(width:1,height:total).offset(x:viewport.x(marker.time))
                }
            }.frame(width:viewport.width,height:total,alignment:.topLeading).allowsHitTesting(false)
        }
        .clipped()
        .onContinuousHover { phase in
            // Scissors pointer while the blade tool is active.
            if case .active = phase, store.tool == .blade { Cursors.blade.set() }
        }
        .onChange(of:store.tool) { if store.tool == .select { NSCursor.arrow.set() } }
        .onAppear { store.thumbnails.onUpdate = { [weak store] in store?.thumbnailRevision += 1 } }
        .environment(\.timelineScale,pps)
    }
    @ViewBuilder func rowContent(_ row: TimelineRow, entries: [TimelineEntry], visible: TimelineRange, height: Double) -> some View {
        switch row.kind {
        case .video, .audio, .faces:
            if row.kind == .video {
                ForEach(Array(store.project.gaps(in:row.lane).filter { $0.intersects(visible) }.enumerated()),id:\.offset) { _,gap in
                    Color.white.opacity(0.001).frame(width:max(1,gap.duration*viewport.pixelsPerSecond),height:height).contentShape(Rectangle())
                        .contextMenu { Button("빈 구간 삭제 후 붙이기") { store.closeGap(gap,lane:row.lane) } }
                        .offset(x:viewport.x(gap.start))
                }
            }
            ForEach(entries.filter { $0.lane == row.lane && $0.end > visible.start && $0.start < visible.end }) { entry in
                Group {
                    switch row.kind {
                    case .video: VideoClipCell(entry:entry,row:row,viewport:viewport)
                    case .audio: LinkedAudioCell(entry:entry,row:row)
                    default: FaceCoverageCell(entry:entry,row:row)
                    }
                }.frame(width:max(2,entry.clip.timelineDuration*viewport.pixelsPerSecond),height:height).offset(x:viewport.x(entry.start))
            }
        case .regions, .captions, .titles:
            ForEach(overlayItems(row).filter { $0.end > visible.start && $0.start < visible.end },id:\.id) { item in
                OverlayTimelineBlock(item:item,row:row,viewport:viewport)
                    .frame(width:max(14,(item.end-item.start)*viewport.pixelsPerSecond),height:height).offset(x:viewport.x(item.start))
            }
        case .music:
            ForEach(store.project.audioClips.filter { $0.lane == row.lane && $0.timelineEnd > visible.start && $0.position < visible.end }) { clip in
                OverlayTimelineBlock(item:TimelineBlockItem(id:clip.id,kind:.music,start:clip.position,end:clip.timelineEnd,title:store.project.media.first(where:{ $0.id == clip.source })?.name ?? "오디오",muted:clip.gain == 0),row:row,viewport:viewport)
                    .frame(width:max(14,clip.duration*viewport.pixelsPerSecond),height:height).offset(x:viewport.x(clip.position))
            }
        }
    }
    func overlayItems(_ row: TimelineRow) -> [TimelineBlockItem] {
        switch row.kind {
        case .regions: return store.project.regions.filter { ($0.lane ?? 0) == row.lane }.map { TimelineBlockItem(id:$0.id,kind:.regions,start:$0.start,end:$0.end,title:$0.name,muted:!$0.enabled) }
        case .captions: return store.project.captions.filter { ($0.lane ?? 0) == row.lane }.map { TimelineBlockItem(id:$0.id,kind:.captions,start:$0.start,end:$0.end,title:$0.text.replacingOccurrences(of:"\n",with:" "),muted:false,warning:($0.confidence ?? 1) < SpeechOptions.reviewConfidence) }
        default: return store.project.titles.filter { ($0.lane ?? 0) == row.lane }.map { TimelineBlockItem(id:$0.id,kind:.titles,start:$0.start,end:$0.end,title:$0.text.replacingOccurrences(of:"\n",with:" "),muted:false) }
        }
    }
}

private struct TimelineScaleKey: EnvironmentKey { static let defaultValue = 60.0 }
extension EnvironmentValues { var timelineScale: Double { get { self[TimelineScaleKey.self] } set { self[TimelineScaleKey.self] = newValue } } }

struct VideoClipCell: View {
    @EnvironmentObject var store: EditorStore
    let entry: TimelineEntry
    let row: TimelineRow
    @ObservedObject var viewport: TimelineViewport
    @State private var drag: CGSize = .zero
    @State private var dragging = false
    @State private var trimOrigin: Double?
    var selected: Bool { store.selectedTrack.linkedToVideo && store.selectedClips.contains(entry.id) }
    var source: MediaSource? { store.project.source(entry.clip.source) }
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment:.topLeading) {
                FilmstripView(entry:entry,source:source,viewport:viewport,height:geo.size.height).clipShape(RoundedRectangle(cornerRadius:4))
                LinearGradient(colors:[.black.opacity(0.55),.clear],startPoint:.top,endPoint:.center).clipShape(RoundedRectangle(cornerRadius:4)).allowsHitTesting(false)
                if entry.overlap > 0 {
                    // Transition region shaded where this clip blends over the previous one.
                    Rectangle().fill(Color.accent.opacity(0.35)).frame(width:entry.overlap*viewport.pixelsPerSecond).overlay(Image(systemName:"rhombus.fill").font(.system(size:8)).foregroundStyle(.white)).allowsHitTesting(false)
                } else if entry.clip.transition != nil {
                    Image(systemName:"rhombus.fill").font(.system(size:8)).foregroundStyle(Color.accent).padding(3).allowsHitTesting(false)
                }
                HStack(spacing:4) {
                    if store.offlineMedia.contains(source?.id ?? UUID()) { Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.red) }
                    Text(source?.name ?? "컷").lineLimit(1)
                    if let f = entry.clip.freeze { Text("정지 \(String(format:"%.1f",f))초").foregroundStyle(.cyan) }
                    else if entry.clip.rate != 1 { Text("\(Int((entry.clip.rate*100).rounded()))%").foregroundStyle(.yellow) }
                    if entry.clip.color?.isIdentity == false { Image(systemName:"camera.filters") }
                    if entry.clip.transform?.isIdentity == false { Image(systemName:"rectangle.inset.topright.filled") }
                    if source?.maskApplied == true { Image(systemName:"checkmark.shield.fill").foregroundStyle(Color.mint) }
                }.font(.system(size:9,weight:.medium)).foregroundStyle(.white).padding(.horizontal,entry.overlap > 0 ? entry.overlap*viewport.pixelsPerSecond+4 : 6).padding(.top,3)
                    .frame(width:width,alignment:.leading).clipped().allowsHitTesting(false)
            }
            .overlay(RoundedRectangle(cornerRadius:4).stroke(selected ? Color.accent : Color.accent.opacity(0.25),lineWidth:selected ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture(count:2) { store.seek(entry.start) }
            .gesture(SpatialTapGesture().onEnded { value in
                if store.tool == .blade { store.blade(at:entry.start+value.location.x/viewport.pixelsPerSecond,row:row) }
                else { store.selectClip(entry.id,extending:NSApp.currentEvent?.modifierFlags.contains(.command) == true) }
            })
            .gesture(DragGesture(minimumDistance:4).onChanged { v in
                guard store.tool == .select, trimOrigin == nil else { return }
                if !dragging { dragging = true; store.selectClip(entry.id) }
                drag = v.translation
            }.onEnded { v in
                guard dragging else { return }
                dragging = false; drag = .zero
                let target = store.snapTime(entry.start+v.translation.width/viewport.pixelsPerSecond,pixelsPerSecond:viewport.pixelsPerSecond,excluding:entry.id)
                let stride = rowHeight(.video)+rowHeight(.audio)+rowHeight(.faces)+rowSpacing*3
                let lane = max(0,min(63,entry.lane-Int((v.translation.height/stride).rounded())))
                store.dropClip(entry.id,at:target,lane:lane)
            })
            .contextMenu { ClipContextMenu(entry:entry) }
            .overlay(alignment:.leading) { if width > 24 && store.tool == .select { trimHandle(start:true) } }
            .overlay(alignment:.trailing) { if width > 24 && store.tool == .select { trimHandle(start:false) } }
            .offset(drag).opacity(dragging ? 0.7 : 1).zIndex(dragging ? 10 : 0)
            .help("\(source?.name ?? "") · 원본 \(timecode(entry.clip.start))–\(timecode(entry.clip.end)) · 편집 \(timecode(entry.start))–\(timecode(entry.end))")
        }
    }
    func trimHandle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius:2).fill(Color.white.opacity(0.65)).frame(width:5,height:22).padding(.horizontal,1)
            .contentShape(Rectangle().inset(by:-3)).hoverCursor(.resizeLeftRight)
            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { value in
                if trimOrigin == nil { trimOrigin = start ? entry.clip.start : (entry.clip.freeze != nil ? entry.clip.end : entry.clip.end); store.beginTimelineGesture(); store.selectClip(entry.id) }
                let seconds = value.translation.width/max(0.001,viewport.pixelsPerSecond)*(entry.clip.freeze != nil ? 1 : entry.clip.rate)
                let time = (trimOrigin ?? 0)+seconds
                if start { store.trimClip(entry.id,start:time) } else { store.trimClip(entry.id,end:time) }
            }.onEnded { _ in trimOrigin = nil; store.endTimelineGesture() })
    }
}

struct ClipContextMenu: View {
    @EnvironmentObject var store: EditorStore
    let entry: TimelineEntry
    var body: some View {
        Button("선택") { store.selectClip(entry.id) }
        Menu("속도") {
            ForEach([0.25,0.5,0.75,1,1.5,2,4,8],id:\.self) { s in Button("\(Int(s*100))%") { store.selectClip(entry.id); store.setSpeed(s) } }
        }
        Button("재생 위치에 정지 화면 추가") { store.selectClip(entry.id); store.addFreezeFrame() }
        Menu("전환 효과 (시작 부분)") {
            ForEach(TransitionKind.allCases,id:\.self) { k in Button(k.rawValue) { store.selectClip(entry.id); store.setTransition(k) } }
            Divider(); Button("전환 제거") { store.selectClip(entry.id); store.setTransition(nil) }
        }
        Button("오디오 분리") { store.selectClip(entry.id); store.detachAudio() }
        Button(entry.clip.audioMuted == true ? "소리 켜기" : "소리 끄기") { store.selectClip(entry.id); store.updateClips { $0.audioMuted = $0.audioMuted == true ? nil : true } }
        Divider()
        Menu("트랙으로 이동") {
            ForEach(0..<store.laneCount(.video),id:\.self) { lane in Button("영상 \(lane+1)") { store.moveItem(entry.id,to:.video,lane:lane) } }
            Button("새 영상 트랙") { store.addLane(.video); store.moveItem(entry.id,to:.video,lane:store.selectedLane) }
        }
        Button("복사") { store.selectClip(entry.id); store.copyClips() }
        Button("잘라내기") { store.selectClip(entry.id); store.cutClips() }
        Button("삭제") { store.selectClip(entry.id); store.deleteClip() }
        Button("이 컷만 내보내기 범위로") { store.selectClip(entry.id); store.exportSelectedClips() }
        Button("효과 초기화") { store.selectClip(entry.id); store.updateClips { $0.color = nil; $0.transform = nil; $0.videoFadeIn = nil; $0.videoFadeOut = nil } }
        if let id = store.project.source(entry.clip.source)?.id {
            Button("미디어 패널에서 보기") { store.selectedMedia = id; store.tab = .media }
            Button("이 미디어의 얼굴 보기") { store.selectedMedia = id; store.tab = .faces }
        }
    }
}

// Filmstrip: one thumbnail per slot, taken at the source time shown in that slot.
struct FilmstripView: View {
    @EnvironmentObject var store: EditorStore
    let entry: TimelineEntry
    let source: MediaSource?
    @ObservedObject var viewport: TimelineViewport
    let height: Double
    var body: some View {
        let _ = store.thumbnailRevision
        let aspect = source.map { $0.width > 0 && $0.height > 0 ? $0.width/$0.height : 16/9 } ?? 16/9
        let slot = max(14,height*min(3,max(0.3,aspect)))
        let clipX = viewport.x(entry.start), width = entry.clip.timelineDuration*viewport.pixelsPerSecond
        let first = max(0,Int(floor(-clipX/slot))), last = Int(ceil(min(width,viewport.width-clipX)/slot))
        let step = ThumbnailCache.step(for:slot/viewport.pixelsPerSecond*max(0.001,entry.clip.rate == 0 ? 1 : entry.clip.rate))
        let frames: [(Double,CGImage?)] = source.map { s in
            (first..<max(first,min(last,first+200))).map { i in
                let t = entry.start+(Double(i)+0.5)*slot/viewport.pixelsPerSecond
                return (Double(i)*slot,store.thumbnails.frame(s,at:entry.sourceTime(at:min(entry.end-0.001,t)),step:step))
            }
        } ?? []
        Canvas { context,size in
            context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(Color.accent.opacity(0.22)))
            for (x,image) in frames {
                guard let image else { continue }
                // Aspect-fill each slot, clipped to it, so neighbouring frames never overlap.
                let rect = CGRect(x:x,y:0,width:slot,height:size.height)
                let imageAspect = Double(image.width)/max(1,Double(image.height))
                let w = max(slot,size.height*imageAspect), h = w/imageAspect
                var tile = context; tile.clip(to:Path(rect))
                tile.draw(Image(decorative:image,scale:1),in:CGRect(x:rect.midX-w/2,y:rect.midY-h/2,width:w,height:h))
                var edge = Path(); edge.move(to:CGPoint(x:rect.maxX,y:0)); edge.addLine(to:CGPoint(x:rect.maxX,y:size.height))
                context.stroke(edge,with:.color(.black.opacity(0.35)),lineWidth:1)
            }
        }.allowsHitTesting(false)
    }
}

struct LinkedAudioCell: View {
    @EnvironmentObject var store: EditorStore
    let entry: TimelineEntry
    let row: TimelineRow
    var body: some View {
        let _ = store.waveformRevision
        let sourceID = store.project.sourceID(of:entry.clip)
        let wave = sourceID.flatMap { store.waveforms[$0] }
        let muted = entry.clip.gain == 0 || entry.clip.freeze != nil
        let selected = store.selectedTrack.linkedToVideo && store.selectedClips.contains(entry.id)
        ZStack {
            RoundedRectangle(cornerRadius:3).fill(Color.cyan.opacity(muted ? 0.04 : 0.1))
            WaveformShape(wave:wave,from:entry.clip.start,to:entry.clip.freeze != nil ? entry.clip.start : entry.clip.end,gain:min(2,entry.clip.gain))
                .fill(muted ? Color.muted.opacity(0.35) : Color.cyan.opacity(0.85)).allowsHitTesting(false)
            if entry.clip.audioMuted == true { Text("소리 꺼짐 · 분리됨").font(.system(size:8)).foregroundStyle(Color.muted).allowsHitTesting(false) }
            if selected { RoundedRectangle(cornerRadius:3).stroke(Color.accent,lineWidth:1).allowsHitTesting(false) }
        }.contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                if store.tool == .blade { store.blade(at:entry.start+value.location.x/max(0.001,store.viewport.pixelsPerSecond),row:row) }
                else { store.selectClip(entry.id,extending:NSApp.currentEvent?.modifierFlags.contains(.command) == true); store.selectedTrack = .audio }
            })
            .contextMenu { ClipContextMenu(entry:entry) }
    }
}
// Peak envelope of source audio between two source times, drawn across the given width.
struct WaveformShape: Shape {
    var wave: AudioWaveform?
    var from: Double
    var to: Double
    var gain: Double = 1
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let wave, wave.hasAudio, to > from, rect.width > 0 else { return path }
        let columns = min(Int(rect.width),2000)
        guard columns > 0 else { return path }
        let span = (to-from)/Double(columns)
        for x in 0..<columns {
            let a = from+Double(x)*span
            let peak = Double(sqrt(wave.peak(from:a,to:a+span)))*min(1,gain)
            let h = peak*rect.height*0.92
            if h > 0.3 { path.addRect(CGRect(x:rect.minX+Double(x)*rect.width/Double(columns),y:rect.midY-h/2,width:max(1,rect.width/Double(columns)),height:h)) }
        }
        return path
    }
}
struct FaceCoverageCell: View {
    @EnvironmentObject var store: EditorStore
    let entry: TimelineEntry
    let row: TimelineRow
    var body: some View {
        let id = store.project.sourceID(of:entry.clip)
        let spans = id.flatMap { store.faceCoverage[$0] } ?? []
        let review = id.flatMap { i in store.project.media.first { $0.id == i }?.reviewRanges } ?? []
        Canvas { context,size in
            let duration = max(0.0001,entry.clip.timelineDuration)
            func draw(_ list: [TimelineRange], _ color: Color) {
                for span in list where span.end > entry.clip.start && span.start < entry.clip.end {
                    let a = entry.clip.offset(forSource:max(entry.clip.start,span.start)), b = entry.clip.offset(forSource:min(entry.clip.end,span.end))
                    let x = a/duration*size.width
                    context.fill(Path(CGRect(x:x,y:0,width:max(1,(b-a)/duration*size.width),height:size.height)),with:.color(color))
                }
            }
            if entry.clip.freeze != nil {
                if spans.contains(where:{ $0.contains(entry.clip.start) }) { context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(Color.mint.opacity(0.55))) }
            } else { draw(spans,Color.mint.opacity(0.55)); draw(review,Color.orange.opacity(0.8)) }
        }
        .background(RoundedRectangle(cornerRadius:2).fill(Color.mint.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { store.selectClip(entry.id); store.selectedTrack = .faces; if let id { store.selectedMedia = id }; store.tab = .faces }
        .help("민트: 얼굴 마스크가 적용되는 구간 · 주황: 얼굴 누락이 의심되어 검토를 권장하는 구간")
    }
}

struct TimelineRuler: View {
    @EnvironmentObject var store: EditorStore
    @ObservedObject var viewport: TimelineViewport
    @State private var rangeGesture = false
    @State private var rangeOrigin = 0.0
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let steps = viewport.tickSteps
            let visible = viewport.visible
            ZStack(alignment:.topLeading) {
                Canvas { context,size in
                    // Integer tick indices avoid drift from repeatedly adding fractions.
                    let perMajor = max(1,Int((steps.major/steps.minor).rounded()))
                    var i = Int(floor(visible.start/steps.minor))
                    while Double(i)*steps.minor <= visible.end+steps.minor {
                        let t = Double(i)*steps.minor
                        let x = viewport.x(t)
                        let major = i % perMajor == 0
                        var line = Path(); line.move(to:CGPoint(x:x,y:major ? 18 : 28)); line.addLine(to:CGPoint(x:x,y:40))
                        context.stroke(line,with:.color(major ? Color.muted : Color.muted.opacity(0.35)),lineWidth:1)
                        if major { context.draw(Text(rulerLabel(t,step:steps.major)).font(.system(size:8,design:.monospaced)).foregroundColor(Color.muted),at:CGPoint(x:x+3,y:8),anchor:.leading) }
                        i += 1
                    }
                    if store.project.editedDuration > 0 {
                        let end = viewport.x(store.project.editedDuration)
                        if end < size.width { context.fill(Path(CGRect(x:end,y:0,width:size.width-end,height:size.height)),with:.color(Color.black.opacity(0.25))) }
                    }
                }.allowsHitTesting(false)
                TimelineWheelSurface(seek:{ x in store.focusTimeline(); store.seek(viewport.time(x)) },wheel:{ delta,precise,fine in
                    store.focusTimeline(); store.pause(); store.seek(timelineWheelDestination(current:store.playhead,delta:delta,precise:precise,fine:fine,duration:store.project.editedDuration))
                }).help("클릭·드래그로 이동 · 휠로 재생 위치 이동 · Shift+휠 미세 이동")
                ForEach(store.project.markers.filter { visible.contains($0.time) }) { marker in
                    Image(systemName:"bookmark.fill").font(.system(size:9)).foregroundStyle(store.selectedMarker == marker.id ? Color.yellow : Color.orange)
                        .position(x:viewport.x(marker.time),y:34)
                        .onTapGesture { store.selectedMarker = marker.id; store.seek(marker.time) }
                        .contextMenu {
                            Button("이 위치로 이동") { store.seek(marker.time) }
                            Button("마커 삭제") { store.project.markers.removeAll { $0.id == marker.id } }
                        }
                        .help(marker.name)
                }
                if let range = store.project.exportRange {
                    Rectangle().fill(Color.mint).frame(width:max(1,range.duration*viewport.pixelsPerSecond),height:3).offset(x:viewport.x(range.start),y:40).allowsHitTesting(false)
                    rangeHandle(isStart:true,time:range.start,width:width)
                    rangeHandle(isStart:false,time:range.end,width:width)
                }
            }
        }
    }
    func rangeHandle(isStart: Bool,time: Double,width: Double) -> some View {
        RoundedRectangle(cornerRadius:2).fill(Color.mint).frame(width:8,height:20)
            .overlay(Text(isStart ? "I" : "O").font(.system(size:7,weight:.bold)).foregroundStyle(Color.base))
            .contentShape(Rectangle()).position(x:max(4,min(width-4,viewport.x(time))),y:30)
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.global).onChanged { v in
                if !rangeGesture { rangeOrigin = time; store.beginTimelineGesture(); rangeGesture = true }
                let next = store.snapTime(rangeOrigin+v.translation.width/viewport.pixelsPerSecond,pixelsPerSecond:viewport.pixelsPerSecond)
                if isStart { store.setExportRange(start:next,end:store.project.exportRange?.end ?? store.project.editedDuration) }
                else { store.setExportRange(start:store.project.exportRange?.start ?? 0,end:next) }
            }.onEnded { _ in store.endTimelineGesture(); rangeGesture = false })
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
        private func move(_ event: NSEvent) { let point = convert(event.locationInWindow,from:nil); seek(min(bounds.width,max(0,point.x))) }
        override func scrollWheel(with event: NSEvent) {
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            wheel(delta,event.hasPreciseScrollingDeltas,event.modifierFlags.contains(.shift))
        }
    }
}
