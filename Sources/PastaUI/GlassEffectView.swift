import AppKit
import SwiftUI

public struct GlassEffectBackground: NSViewRepresentable {
    public var cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 12) {
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context: Context) -> NSView {
        if let glassView = makeGlassEffectView() {
            return glassView
        }
        return makeVisualEffectView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        applyCornerRadius(nsView)
    }

    private func makeGlassEffectView() -> NSView? {
        guard let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else {
            return nil
        }
        let view = glassClass.init(frame: .zero)
        applyCornerRadius(view)
        return view
    }

    private func makeVisualEffectView() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .withinWindow
        view.state = .active
        applyCornerRadius(view)
        return view
    }

    private func applyCornerRadius(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        let selector = Selector(("setCornerRadius:"))
        if view.responds(to: selector) {
            view.setValue(cornerRadius, forKey: "cornerRadius")
        }
    }
}
