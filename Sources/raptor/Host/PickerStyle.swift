import AppKit
import SwiftUI

struct PinChangeTransactionKey: TransactionKey {
    static let defaultValue = false
}

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
    static let createHeaderHeight: CGFloat = searchHeight
    static let footerHeight: CGFloat = 34
    static let maxVisibleRows = 16
    static let rowHeight: CGFloat = 32
    static let unreadIndicatorSize: CGFloat = 5
    static let pinReorderDuration = 0.24
    static let pinGlyphDuration = 0.16

    static func animatesPinChanges(reduceMotion: Bool, previous: [PickerItem], updated: [PickerItem]) -> Bool {
        !reduceMotion && !previous.isEmpty && previous.count == updated.count
            && Set(previous.map(\.id)) == Set(updated.map(\.id))
    }
    static let agentRowHeight: CGFloat = 32
    static let agentGroupHeight: CGFloat = 22
    static let agentGroupSpacing: CGFloat = 8
    static let worktreeRowHeight: CGFloat = 28
    static let selectedPathHeight: CGFloat = 32

    // Colors forward to PickerPalette, which the Go backend refreshes with
    // the active Rex theme while the panel is visible.
    static var selection: Color { PickerPalette.selection }
    // Composite explicitly so glass/wallpaper cannot change label contrast.
    static var selectionBackground: Color { background.overlay(with: selection, fraction: PickerPalette.selectionOpacity) }
    static var selectionText: Color {
        let preferred = PickerPalette.selectionText
        return preferred.contrastRatio(with: selectionBackground) >= 4.5
            ? preferred : contrastText(for: selectionBackground)
    }
    static func unreadIndicatorColor(selected: Bool) -> Color {
        let surface = selected ? selectionBackground : background
        return selection.contrastRatio(with: surface) >= 3 ? selection : contrastText(for: surface)
    }
    static var editingAccent: Color { Color(nsColor: .controlAccentColor) }
    static var background: Color { PickerPalette.background }
    static var fieldBackground: Color { PickerPalette.fieldBackground }
    static var foreground: Color { PickerPalette.foreground }
    static var secondaryText: Color { foreground.opacity(0.55) }
    /// Opaque prompt ink: AppKit's default placeholder and translucent text can
    /// become unreadable when Rex's theme differs from the system appearance.
    static var placeholderText: Color {
        let surface = background.overlay(with: fieldBackground,
                                          fraction: NSColor(fieldBackground).alphaComponent)
        let preferred = surface.overlay(with: foreground, fraction: 0.7)
        return preferred.contrastRatio(with: surface) >= 4.5
            ? preferred : contrastText(for: surface)
    }
    static var sessionText: Color {
        PickerPalette.isDark ? Color(red: 173 / 255.0, green: 208 / 255.0, blue: 173 / 255.0)
            : Color(red: 57 / 255.0, green: 96 / 255.0, blue: 57 / 255.0)
    }
    static var directoryText: Color {
        PickerPalette.isDark ? Color(red: 198 / 255.0, green: 201 / 255.0, blue: 198 / 255.0) : foreground
    }
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

    static func errorSummary(_ error: String) -> String {
        // Worktrunk prints fetch progress before the actual failure. JSON parse
        // failures after an empty switch result are secondary, not the cause.
        let lines = error.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last { !$0.isEmpty && !$0.hasPrefix("parse wt switch:") } ?? error
    }

    static func deletionErrorSummary(_ error: String) -> String {
        if error.localizedCaseInsensitiveContains("not a git repository") { return "Not a Git repository." }
        return errorSummary(error)
    }

    static func hasDeletionSelection(_ deletion: PickerModel.SessionDeletion) -> Bool {
        deletion.plan?.worktrees?.contains(where: \.deletable) == true
            || !deletion.selectedPaths.isEmpty || deletion.preparationSelection?.isEmpty == false
    }

    static func deletionHeight(_ deletion: PickerModel.SessionDeletion) -> CGFloat {
        let rows = Array((deletion.plan?.worktrees ?? []).prefix(5))
        let hasSelection = hasDeletionSelection(deletion)
        // Match the compact context, rows and footer; additional rows scroll.
        var content: CGFloat = 20 + 14
        if !rows.isEmpty {
            content += 10
            for row in rows {
                content += row.branch.isEmpty ? 30 : 47
                if let error = row.error {
                    content += deletionErrorSummary(error) == "Not a Git repository." ? 17 : 31
                } else if deletion.checkingPath == row.path || !row.isChecked || row.needsForce == true
                    || deletion.deletedPaths.contains(row.path)
                    || (deletion.phase == .preparing && deletion.preparationSelection?.contains(row.path) == true) {
                    content += 17
                }
            }
            content += CGFloat(rows.count - 1)
        }
        if deletion.plan != nil {
            if hasSelection && [.confirm, .forceOffered, .forceConfirm, .deleting].contains(deletion.phase) {
                content += 30
            }
            content += 24
        }
        if deletion.phase == .forceConfirm { content += 38 }
        if deletion.error != nil { content += 52 }
        if (deletion.plan == nil && deletion.phase == .loading) || deletion.phase == .deleting { content += 30 }
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - topInset - 24
        return min(max(searchHeight + content + 39, 180), max(available, 180))
    }

    @MainActor static func height(for model: PickerModel) -> CGFloat {
        if let deletion = model.sessionDeletion { return deletionHeight(deletion) }
        if model.shortcutsPresented {
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - topInset - 24
            return min(594, max(available, 180))
        }
        if model.page == .pr {
            // Status is available once GitHub metadata resolves; progress gets
            // a separate row only while an operation is in flight.
            let state: CGFloat = model.pullRequest?.state?.isEmpty == false ? 24 : 0
            return 276 + state + (model.prStage == nil ? 0 : 24)
                + (model.error == nil && model.notice == nil ? 0 : 32)
        }
        if model.page == .create {
            let validation: CGFloat = !model.branch.isEmpty && model.previewReady && model.validationError != nil ? 24 : 0
            return createHeight + validation + (model.error == nil && model.notice == nil ? 0 : 32)
        }
        let rowHeight = model.view == .agents ? Self.agentRowHeight : (model.page == .worktrees ? Self.worktreeRowHeight : Self.rowHeight)
        // Reserve the list footprint before the first backend response arrives.
        let rowCount = model.loading && model.items.isEmpty ? maxVisibleRows : min(max(model.items.count, 2), maxVisibleRows)
        let rows = CGFloat(rowCount)
        let status: CGFloat = model.error == nil && model.notice == nil ? 0 : 32
        let detail = model.view == .sessions && model.page == .worktrees ? selectedPathHeight : 0
        let wrappedRow = model.view == .sessions && model.page == .worktrees && model.selected.map({ branchLines(for: $0) > 1 }) == true ? rowHeight : 0
        let groupCount = model.view == .agents ? model.agentSections.count : 0
        let groups = CGFloat(groupCount) * agentGroupHeight + CGFloat(max(groupCount - 1, 0)) * agentGroupSpacing
        let content = searchHeight + rows * rowHeight + groups + wrappedRow
            + 8 + detail + footerHeight + status
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
            .preferredColorScheme(PickerPalette.isDark ? .dark : .light)
            .background(PickerStyle.background)
            .clipShape(RoundedRectangle(cornerRadius: PickerStyle.radius))
            .overlay(RoundedRectangle(cornerRadius: PickerStyle.radius).strokeBorder(PickerPalette.stroke))
    }
}

extension View {
    func pickerGlass() -> some View { modifier(RexPanelBackground()) }

    /// Draw outside the native field: AppKit can replace prompt attributes when
    /// its field editor gains focus or the window's appearance changes.
    func pickerPlaceholder(_ prompt: String, when empty: Bool) -> some View {
        overlay(alignment: .leading) {
            if empty {
                Text(prompt)
                    .foregroundStyle(PickerStyle.placeholderText)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
