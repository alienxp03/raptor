import AppKit
import SwiftUI

// Rex-native metrics and palette. Sampled from the Rex Beta picker window
// (2x capture): compact 28pt rows, warm dark surface, amber selection.
enum PickerStyle {
    static let width: CGFloat = 640
    static let topInset: CGFloat = 72
    static let radius: CGFloat = 16
    static let bodyFontSize: CGFloat = 13
    static let rowFontSize: CGFloat = 13
    static let titleFontSize: CGFloat = 14
    static let controlHeight: CGFloat = 26
    static let horizontalInset: CGFloat = 10
    static let listInset: CGFloat = 6
    static let rowInset: CGFloat = 12
    static let createHeight: CGFloat = 240
    static let searchHeight: CGFloat = 40
    static let searchFieldHeight: CGFloat = 30
    static let pillsHeight: CGFloat = 34
    static let createHeaderHeight: CGFloat = searchHeight
    static let footerHeight: CGFloat = 34
    static let rowHeight: CGFloat = 32
    static let worktreeRowHeight: CGFloat = 28
    static let selectedPathHeight: CGFloat = 32
    static let selection = Color(red: 0.722, green: 0.510, blue: 0.259)
    // Warm foreground like resh; selected rows use white, never dark ink.
    static let foreground = Color(red: 0.84, green: 0.79, blue: 0.72)
    static let secondaryText = foreground.opacity(0.55)
    static let selectionText = Color.white
    private static let backgroundRGB = (red: CGFloat(0.106), green: CGFloat(0.098), blue: CGFloat(0.092))
    static let background = Color(red: backgroundRGB.red, green: backgroundRGB.green, blue: backgroundRGB.blue)
    static let fieldBackground = Color(red: 0.196, green: 0.182, blue: 0.176)
    /// Warm dark tint over the system glass, matching resh's blendTheme tint
    /// strength (panel background at 35% alpha) so text stays readable on
    /// bright desktops while the glass still shows through.
    static let glassTint = NSColor(red: backgroundRGB.red, green: backgroundRGB.green,
        blue: backgroundRGB.blue, alpha: 0.35)
    static let hairline = NSColor.white.withAlphaComponent(0.15)

    static func panelFrame(in area: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: area.midX - width / 2, y: area.maxY - topInset - height,
               width: width, height: height)
    }

    static func branchLines(for item: PickerItem) -> Int {
        guard let branch = item.branch else { return 1 }
        let label = branch + (item.isMain == true ? " · primary" : "")
        let font = NSFont.systemFont(ofSize: rowFontSize, weight: .medium)
        let measured = (label as NSString).size(withAttributes: [.font: font]).width
        return measured > width - 2 * rowInset - 30 ? 2 : 1
    }

    @MainActor static func height(for model: PickerModel) -> CGFloat {
        if model.page == .create {
            let validation: CGFloat = !model.branch.isEmpty && model.previewReady && model.validationError != nil ? 24 : 0
            return createHeight + validation + (model.error == nil && model.notice == nil ? 0 : 32)
        }
        let rowHeight = model.page == .worktrees && model.view == .repos ? Self.worktreeRowHeight : Self.rowHeight
        // Reserve the list footprint before the first backend response arrives.
        let rowCount = model.loading && model.items.isEmpty ? 8 : min(max(model.items.count, 2), 8)
        let rows = CGFloat(rowCount)
        let status: CGFloat = model.error == nil && model.notice == nil ? 0 : 32
        let pills: CGFloat = model.showsPills ? pillsHeight : 0
        let detail = model.page == .worktrees && model.view == .repos ? selectedPathHeight : 0
        let wrappedRow = model.page == .worktrees && model.view == .repos && model.selected.map({ branchLines(for: $0) > 1 }) == true ? rowHeight : 0
        let content = searchHeight + pills + rows * rowHeight + wrappedRow + 8 + detail + footerHeight + status
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

private struct RexPanelBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        // Popover surfaces only. The main panel's glass material lives in the
        // window (RaptorApp.makeContent) — PickerView itself stays transparent
        // so the system glass shows through.
        content
            .background(PickerStyle.background)
            .clipShape(RoundedRectangle(cornerRadius: PickerStyle.radius))
            .overlay(RoundedRectangle(cornerRadius: PickerStyle.radius).strokeBorder(Color.white.opacity(0.07)))
    }
}

extension View {
    func pickerGlass() -> some View { modifier(RexPanelBackground()) }
}
