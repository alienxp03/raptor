import AppKit
import SwiftUI

// Rex-native metrics and palette. Sampled from the Rex Beta picker window
// (2x capture): compact 28pt rows, warm dark surface, amber selection.
@MainActor
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
    static let agentRowHeight: CGFloat = 32
    static let agentGroupHeight: CGFloat = 22
    /// Quiet per-host rows: the New Session hint and the unreachable note.
    static let sessionAuxRowHeight: CGFloat = 26
    static let agentGroupSpacing: CGFloat = 8
    static let worktreeRowHeight: CGFloat = 28
    static let selectedPathHeight: CGFloat = 32

    // Colors forward to PickerPalette, which the Go backend refreshes with
    // the active Rex theme while the panel is visible.
    static var selection: Color { PickerPalette.selection }
    static var selectionBackground: Color { selection.opacity(PickerPalette.selectionOpacity) }
    static var selectionText: Color { PickerPalette.selectionText }
    static var background: Color { PickerPalette.background }
    static var fieldBackground: Color { PickerPalette.fieldBackground }
    static var foreground: Color { PickerPalette.foreground }
    static var secondaryText: Color { foreground.opacity(0.55) }
    static var glassTint: NSColor { NSColor(background).withAlphaComponent(0.35) }
    static var hairline: NSColor { NSColor(foreground).withAlphaComponent(0.15) }

    /// Repaint the material as well as SwiftUI after an asynchronous theme load.
    static func applyPanelTheme(to material: NSView) {
        material.appearance = NSAppearance(named: PickerPalette.isDark ? .darkAqua : .aqua)
        material.layer?.borderColor = hairline.cgColor
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            glass.tintColor = PickerPalette.usesThemeTint ? glassTint : nil
        } else if material is NSVisualEffectView {
            material.layer?.backgroundColor = PickerPalette.usesThemeTint ? glassTint.cgColor : nil
        } else {
            material.layer?.backgroundColor = NSColor(background).cgColor
        }
    }

    static func panelAnimationBehavior(reduceMotion: Bool) -> NSWindow.AnimationBehavior {
        reduceMotion ? .none : .default
    }

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
        let rowHeight = model.view == .agents ? Self.agentRowHeight : (model.page == .worktrees && model.view == .repos ? Self.worktreeRowHeight : Self.rowHeight)
        // Reserve the list footprint before the first backend response arrives.
        let showGroups = model.view == .agents
            || (model.view == .sessions && model.page == .directories)
        let extraRows: Int
        if model.view == .sessions && model.page == .directories {
            extraRows = model.hostSections.filter { $0.host.reachable }.count
                + model.hostSections.filter { !$0.host.reachable }.count
        } else { extraRows = 0 }
        let rowCount = model.loading && model.items.isEmpty ? 8 : min(max(model.items.count + extraRows, 2), 8)
        let rows = CGFloat(rowCount)
        let status: CGFloat = model.error == nil && model.notice == nil ? 0 : 32
        let pills: CGFloat = model.showsPills ? pillsHeight : 0
        let detail = model.page == .worktrees && model.view == .repos ? selectedPathHeight : 0
        let wrappedRow = model.page == .worktrees && model.view == .repos && model.selected.map({ branchLines(for: $0) > 1 }) == true ? rowHeight : 0
        let groupCount = showGroups
            ? (model.view == .agents ? model.agentSections.count : model.hostSections.count)
            : 0
        let groups = CGFloat(groupCount) * agentGroupHeight + CGFloat(max(groupCount - 1, 0)) * agentGroupSpacing
        // Quiet per-host rows (New Session hints, unreachable notes) are shorter
        // than session rows; the count above must match the view's rows.
        let auxRows: CGFloat = model.view == .sessions && model.page == .directories
            ? CGFloat(extraRows) * (sessionAuxRowHeight - rowHeight)
            : 0
        let content = searchHeight + pills + rows * rowHeight + groups + auxRows + wrappedRow + 8 + detail + footerHeight + status
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
            .overlay(RoundedRectangle(cornerRadius: PickerStyle.radius).strokeBorder(PickerPalette.stroke))
    }
}

extension View {
    func pickerGlass() -> some View { modifier(RexPanelBackground()) }
}
