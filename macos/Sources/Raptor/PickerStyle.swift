import AppKit
import SwiftUI

// Keep the picker wide enough for paths, with content-fitted height.
enum PickerStyle {
    static let width: CGFloat = 640
    static let topInset: CGFloat = 72
    static let radius: CGFloat = 14
    static let searchHeight: CGFloat = 42
    static let createHeaderHeight: CGFloat = 60
    static let footerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 26
    static let worktreeRowHeight: CGFloat = 36
    static let selection = Color(red: 0.48, green: 0.61, blue: 0.49)

    static func panelFrame(in area: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: area.midX - width / 2, y: area.maxY - topInset - height,
               width: width, height: height)
    }

    @MainActor static func height(for model: PickerModel) -> CGFloat {
        if model.page == .create {
            let validation: CGFloat = !model.branch.isEmpty && model.previewReady && model.validationError != nil ? 28 : 0
            return 400 + validation + (model.error == nil && model.notice == nil ? 0 : 36)
        }
        let rowHeight = model.page == .worktrees ? Self.worktreeRowHeight : Self.rowHeight
        let rows = CGFloat(min(max(model.items.count, 2), 14))
        let status: CGFloat = model.error == nil && model.notice == nil ? 0 : 36
        let content = searchHeight + rows * rowHeight + 8 + footerHeight + status
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - topInset - 24
        return min(content, max(available, 180))
    }
}

extension CGRect {
    /// Keep a panel frame fully inside `limit` when it overlaps it.
    func clamped(to limit: CGRect) -> CGRect {
        guard intersects(limit) else { return self }
        var origin = self.origin
        if origin.x < limit.minX { origin.x = limit.minX }
        if origin.x + width > limit.maxX { origin.x = limit.maxX - width }
        if origin.y < limit.minY { origin.y = limit.minY }
        if origin.y + height > limit.maxY { origin.y = limit.maxY - height }
        return CGRect(origin: origin, size: size)
    }
}

private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct PickerGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: PickerStyle.radius))
        } else {
            content
                .background(MenuMaterial())
                .clipShape(RoundedRectangle(cornerRadius: PickerStyle.radius))
                .overlay(RoundedRectangle(cornerRadius: PickerStyle.radius).strokeBorder(.primary.opacity(0.12)))
        }
    }
}

extension View {
    func pickerGlass() -> some View { modifier(PickerGlass()) }
}
