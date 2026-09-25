import SwiftUI
import AppKit

struct TimeField: NSViewRepresentable {
    var title: String
    @Binding var value: Double
    var changed: (Double) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ScrollTimeTextField {
        let view = ScrollTimeTextField(); view.isBezeled = true; view.bezelStyle = .roundedBezel
        let formatter = NumberFormatter(); formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 3; formatter.usesGroupingSeparator = false; formatter.decimalSeparator = "."; view.formatter = formatter
        view.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular)
        view.delegate = context.coordinator; view.placeholderString = title
        view.setAccessibilityLabel(title); view.toolTip = "초 입력 · 스크롤: 0.1초 · Shift+스크롤: 1초"
        view.onScroll = { delta in context.coordinator.apply(delta:delta) }; return view
    }
    func updateNSView(_ view: ScrollTimeTextField,context: Context) {
        context.coordinator.parent = self
        if view.currentEditor() == nil { view.doubleValue = value }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimeField
        init(_ p: TimeField) { parent = p }
        func apply(delta: Double) { parent.changed(max(0,parent.value+delta)) }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let number = Double(field.stringValue), number.isFinite { parent.changed(max(0,number)) }
            field.doubleValue = parent.value
        }
    }
}
final class ScrollTimeTextField: NSTextField {
    var onScroll: ((Double)->Void)?
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0 else { return }
        window?.makeFirstResponder(nil)
        onScroll?((event.scrollingDeltaY > 0 ? 1 : -1)*(event.modifierFlags.contains(.shift) ? 1 : 0.1))
    }
}
