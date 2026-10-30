import AppKit
import SwiftUI

// Keep the picker wide enough for paths, with content-fitted height.
enum PickerStyle {
    static let width: CGFloat = 640
    static let topInset: CGFloat = 72
    static let radius: CGFloat = 14
    static let bodyFontSize: CGFloat = 13
    static let titleFontSize: CGFloat = 14
    static let controlHeight: CGFloat = 28
    static let horizontalInset: CGFloat = 10
    static let createHeight: CGFloat = 260
    static let searchHeight: CGFloat = 42
    static let createHeaderHeight: CGFloat = searchHeight
    static let footerHeight: CGFloat = 42
    static let rowHeight: CGFloat = controlHeight
    static let worktreeRowHeight: CGFloat = controlHeight
    static let selectedPathHeight: CGFloat = 44
    static let selection = Color(red: 0.48, green: 0.61, blue: 0.49)

    static func panelFrame(in area: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: area.midX - width / 2, y: area.maxY - topInset - height,
               width: width, height: height)
    }

    static func branchLines(for item: PickerItem) -> Int {
        guard let branch = item.branch else { return 1 }
        let label = branch + (item.isMain == true ? " · primary" : "")
        let font = NSFont.systemFont(ofSize: bodyFontSize, weight: .medium)
        let measured = (label as NSString).size(withAttributes: [.font: font]).width
        return measured > width - 30 ? 2 : 1
    }

    @MainActor static func height(for model: PickerModel) -> CGFloat {
        if model.page == .create {
            let validation: CGFloat = !model.branch.isEmpty && model.previewReady && model.validationError != nil ? 28 : 0
            return createHeight + validation + (model.error == nil && model.notice == nil ? 0 : 36)
        }
        let rowHeight = model.page == .worktrees ? Self.worktreeRowHeight : Self.rowHeight
        // Reserve the list footprint before the first backend response arrives.
        let rowCount = model.loading && model.items.isEmpty ? 8 : min(max(model.items.count, 2), 8)
        let rows = CGFloat(rowCount)
        let status: CGFloat = model.error == nil && model.notice == nil ? 0 : 36
        let detail = model.page == .worktrees ? selectedPathHeight : 0
        let wrappedRow = model.page == .worktrees && model.selected.map({ branchLines(for: $0) > 1 }) == true ? rowHeight : 0
        let content = searchHeight + rows * rowHeight + wrappedRow + 8 + detail + footerHeight + status
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
