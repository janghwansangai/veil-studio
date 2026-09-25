import SwiftUI

struct TimelineBlockItem: Identifiable {
    var id: UUID
    var kind: EditTrack
    var start: Double
    var end: Double
    var title: String
    var muted: Bool
    var warning = false
}

// Caption, region, title and independent-audio blocks: centre drag moves, edges trim.
struct OverlayTimelineBlock: View {
    @EnvironmentObject var store: EditorStore
    var item: TimelineBlockItem
    var row: TimelineRow
    @ObservedObject var viewport: TimelineViewport
    @State private var original: TimelineRange?
    var color: Color {
        switch item.kind { case .regions: return .mint; case .captions: return .orange; case .titles: return .pink; default: return .cyan }
    }
    var selected: Bool {
        switch item.kind {
        case .regions: return store.selectedTrack == .regions && store.selectedRegion == item.id
        case .captions: return store.selectedTrack == .captions && store.selectedCaption == item.id
        case .titles: return store.selectedTrack == .titles && store.selectedTitle == item.id
        default: return store.selectedTrack == .music && store.selectedAudioClip == item.id
        }
    }
    var body: some View {
        ZStack {
            if item.kind == .music, let clip = store.project.audioClips.first(where:{ $0.id == item.id }) {
                let _ = store.waveformRevision
                WaveformShape(wave:store.waveforms[clip.source],from:clip.start,to:clip.end,gain:min(2,clip.gain)).fill(Color.white.opacity(0.55)).allowsHitTesting(false)
            }
            HStack(spacing:0) {
                handle(-1)
                HStack(spacing:3) {
                    if item.warning { Image(systemName:"exclamationmark.circle.fill").foregroundStyle(.yellow) }
                    Text(item.title).lineLimit(1)
                }.font(.system(size:8)).frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle())
                    .hoverCursor(store.tool == .blade ? Cursors.blade : .openHand)
                    .gesture(SpatialTapGesture().onEnded { v in
                        if store.tool == .blade { store.blade(at:item.start+(v.location.x+8)/viewport.pixelsPerSecond,row:row) } else { select() }
                    })
                    .gesture(gesture(0))
                handle(1)
            }
        }
        .background(color.opacity(item.muted ? 0.25 : 0.62),in:RoundedRectangle(cornerRadius:3))
        .overlay(RoundedRectangle(cornerRadius:3).stroke(selected ? Color.white : Color.clear,lineWidth:2).allowsHitTesting(false))
        .contextMenu {
            Menu("트랙으로 이동") {
                ForEach(0..<store.laneCount(item.kind),id:\.self) { lane in Button("트랙 \(lane+1)") { store.moveItem(item.id,to:item.kind,lane:lane) } }
                Button("새 트랙") { store.addLane(item.kind); store.moveItem(item.id,to:item.kind,lane:store.selectedLane) }
            }
            Button("재생 위치로 이동") { store.moveItem(item.id,to:item.kind,lane:row.lane,at:store.playhead) }
            Button("삭제") { select(); store.editSelection("delete") }
        }
        .help(helpText)
    }
    var helpText: String {
        item.warning ? "인식 신뢰도가 낮은 자막입니다. 내용을 확인하세요 · 가운데 드래그: 이동 · 양 끝: 길이 조절" : "가운데 드래그: 길이 유지 이동 · 양 끝: 길이 조절 · 선택한 트랙만 편집"
    }
    func select() {
        switch item.kind {
        case .regions: store.selectOverlay(item.id,region:true)
        case .captions: store.selectOverlay(item.id,region:false)
        case .titles: store.selectTitle(item.id)
        default: store.selectAudioClip(item.id)
        }
    }
    func handle(_ edge: Int) -> some View {
        Rectangle().fill(Color.white.opacity(store.tool == .blade ? 0.2 : 0.8)).frame(width:6).contentShape(Rectangle()).hoverCursor(store.tool == .blade ? Cursors.blade : .resizeLeftRight).highPriorityGesture(gesture(edge))
    }
    func gesture(_ edge: Int) -> some Gesture {
        DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { value in
            guard store.tool == .select else { return }
            if original == nil {
                store.pause(); store.focusTimeline(); store.beginTimelineGesture(); select()
                original = TimelineRange(start:item.start,end:item.end)
            }
            guard let original else { return }
            let raw = value.translation.width/max(0.001,viewport.pixelsPerSecond)
            // Snap the edge being moved (or the start when moving the whole block).
            let anchor = edge > 0 ? original.end : original.start
            let snapped = store.snapTime(anchor+raw,pixelsPerSecond:viewport.pixelsPerSecond,excluding:item.id)-anchor
            store.editOverlayTime(id:item.id,kind:item.kind,original:original,delta:snapped,edge:edge)
        }.onEnded { _ in if original != nil { store.endTimelineGesture() }; original = nil }
    }
}
