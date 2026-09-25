import SwiftUI
import AppKit

enum Cursors {
    // Scissors pointer for the blade tool, drawn from the SF Symbol with a dark outline for contrast.
    static let blade: NSCursor = {
        let size = NSSize(width:22,height:22)
        let image = NSImage(size:size,flipped:false) { rect in
            guard let symbol = NSImage(systemSymbolName:"scissors",accessibilityDescription:"자르기")?.withSymbolConfiguration(.init(pointSize:15,weight:.bold)) else { return false }
            for (offset,color) in [(CGPoint(x:1,y:-1),NSColor.black),(CGPoint(x:-1,y:1),NSColor.black),(CGPoint.zero,NSColor.white)] {
                let tinted = NSImage(size:symbol.size,flipped:false) { r in symbol.draw(in:r); color.set(); r.fill(using:.sourceAtop); return true }
                tinted.draw(in:NSRect(x:(rect.width-symbol.size.width)/2+offset.x,y:(rect.height-symbol.size.height)/2+offset.y,width:symbol.size.width,height:symbol.size.height))
            }
            return true
        }
        return NSCursor(image:image,hotSpot:NSPoint(x:11,y:11))
    }()
}

// Sets a pointer while hovering and restores it reliably, even if the view disappears mid-hover.
private struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    @State private var inside = false
    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active: inside = true; cursor.set()
                case .ended: if inside { inside = false; NSCursor.arrow.set() }
                }
            }
            .onDisappear { if inside { inside = false; NSCursor.arrow.set() } }
    }
}
extension View {
    func hoverCursor(_ cursor: NSCursor) -> some View { modifier(HoverCursor(cursor:cursor)) }
}

// Plain button with a hand pointer and a soft highlight on hover.
struct HoverPlainStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration:configuration) }
    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .padding(.horizontal,2)
                .background(RoundedRectangle(cornerRadius:4).fill(Color.white.opacity(hovering && enabled ? 0.08 : 0)))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .hoverCursor(enabled ? .pointingHand : .arrow)
        }
    }
}
extension ButtonStyle where Self == HoverPlainStyle { static var hover: HoverPlainStyle { HoverPlainStyle() } }
