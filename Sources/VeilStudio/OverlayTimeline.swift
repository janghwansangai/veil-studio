import SwiftUI

struct OverlayTimelineBlock: View {
    @EnvironmentObject var store: EditorStore
    var item: OverlayTimelineItem
    var scale: Double
    @State private var original: TimelineRange?
    @State private var anchor = 0.0

    var body: some View {
        HStack(spacing:0) {
            handle(-1)
            Text(item.title).font(.system(size:8)).lineLimit(1)
                .frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                .gesture(gesture(0))
            handle(1)
        }
        .background(item.region ? Color.mint.opacity(0.65) : Color.orange.opacity(0.65),in:RoundedRectangle(cornerRadius:3))
        .overlay(RoundedRectangle(cornerRadius:3).stroke((item.region ? store.selectedTrack == .regions && store.selectedRegion == item.sourceID : store.selectedTrack == .captions && store.selectedCaption == item.sourceID) ? Color.white : Color.clear,lineWidth:2).allowsHitTesting(false))
        .contextMenu {
            Menu("트랙으로 이동") {
                ForEach(0..<store.laneCount(item.region ? .regions : .captions),id:\.self) { lane in
                    Button("트랙 \(lane+1)") { store.moveItem(item.sourceID,to:item.region ? .regions : .captions,lane:lane) }
                }
                Button("새 트랙") { let kind: EditTrack = item.region ? .regions : .captions; store.addLane(kind); store.moveItem(item.sourceID,to:kind,lane:store.selectedLane) }
            }
        }
        .help("가운데: 길이 유지 이동 · 양 끝: 트림 · 선택한 트랙만 편집")
    }

    func handle(_ edge: Int) -> some View {
        Rectangle().fill(Color.white.opacity(0.8)).frame(width:8).contentShape(Rectangle()).onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }.highPriorityGesture(gesture(edge))
    }
    func gesture(_ edge: Int) -> some Gesture {
        DragGesture(minimumDistance:0,coordinateSpace:.global).onChanged { value in
            if original == nil {
                store.pause(); store.focusTimeline(); store.beginTimelineGesture()
                anchor = edge > 0 ? item.end : item.start
                store.selectOverlay(item.sourceID,region:item.region)
                if item.region {
                    store.tab = .regions; store.selectedRegion = item.sourceID
                    if let r = store.project.regions.first(where:{$0.id == item.sourceID}) { original = TimelineRange(start:r.start,end:r.end) }
                } else {
                    store.tab = .captions
                    if let c = store.project.captions.first(where:{$0.id == item.sourceID}) { original = TimelineRange(start:c.start,end:c.end) }
                }
                store.seek(item.start)
            }
            guard let original else { return }
            let translation = value.translation.width/max(0.001,scale)
            guard abs(translation) > 0.000001 else { return }
            let delta = translation
            store.editOverlayTime(id:item.sourceID,region:item.region,original:original,delta:delta,edge:edge)
        }.onEnded { _ in store.endTimelineGesture(); original = nil }
    }
}
