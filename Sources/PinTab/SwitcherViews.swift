import AppKit
import Observation
import PinTabCore
import SwiftUI

enum Metrics {
    static let icon: CGFloat = 80
    static let tilePadding: CGFloat = 10
    static let tileSpacing: CGFloat = 6
    static var tileSize: CGFloat { icon + tilePadding * 2 }
    static let panelPadding: CGFloat = 18
    static let minSwitchWidth: CGFloat = 280

    static let manageIcon: CGFloat = 52
    static let manageTileWidth: CGFloat = 104
    static let manageTileHeight: CGFloat = 100
    static let manageSpacing: CGFloat = 6
    static let minManageWidth: CGFloat = 420
    static let maxManageColumns = 8

    static let cornerRadius: CGFloat = 22
}

/// Everything the panel displays, rebuilt by SwitcherController from the state machine.
@Observable
final class SwitcherViewModel {
    enum Mode { case switching, managing }

    struct Tile: Identifiable {
        let id: AppID
        let name: String
        let icon: NSImage
        var isPinned: Bool
        var isRunning: Bool
        var canToggle: Bool
    }

    var mode: Mode = .switching
    var tiles: [Tile] = []
    var selection: AppID?
    var message: String?
    var shortcutLabel: String = ""
    /// Width of the scrolling icon row (switching) or grid (managing).
    var rowWidth: CGFloat = 0
    /// Overall content width, at least as wide as the row.
    var contentWidth: CGFloat = Metrics.minSwitchWidth
    var columns: Int = 1
    var gridHeight: CGFloat = 0

    @ObservationIgnored var onPoint: (AppID) -> Void = { _ in }
    @ObservationIgnored var onClick: (AppID) -> Void = { _ in }
    @ObservationIgnored var onManage: () -> Void = {}
    @ObservationIgnored var onDone: () -> Void = {}

    var selectedName: String? {
        tiles.first { $0.id == selection }?.name
    }
}

struct SwitcherRootView: View {
    let model: SwitcherViewModel

    var body: some View {
        Group {
            switch model.mode {
            case .switching: SwitchingView(model: model)
            case .managing: ManagingView(model: model)
            }
        }
        .fixedSize()
    }
}

// MARK: Switching

private struct SwitchingView: View {
    let model: SwitcherViewModel

    var body: some View {
        VStack(spacing: 12) {
            if model.tiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(model.message ?? "No pinned apps are running")
                        .font(.system(size: 15, weight: .medium))
                }
                .frame(width: model.contentWidth)
                .padding(.vertical, 6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Metrics.tileSpacing) {
                            ForEach(model.tiles) { tile in
                                SwitchTile(tile: tile, isSelected: tile.id == model.selection, model: model)
                                    .id(tile.id)
                            }
                        }
                    }
                    .frame(width: model.rowWidth, height: Metrics.tileSize)
                    .onAppear { scroll(proxy, to: model.selection) }
                    .onChange(of: model.selection) { _, selection in scroll(proxy, to: selection) }
                }
            }
            ZStack {
                Text(model.selectedName ?? " ")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: max(model.contentWidth - 190, 80))
                    .accessibilityHidden(true)
                HStack {
                    Spacer()
                    PressButton(title: "Manage…", hint: "M", prominent: false, action: model.onManage)
                }
            }
            .frame(width: model.contentWidth)
        }
        .padding(Metrics.panelPadding)
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: AppID?) {
        guard let id else { return }
        proxy.scrollTo(id, anchor: .center)
    }
}

private struct SwitchTile: View {
    let tile: SwitcherViewModel.Tile
    let isSelected: Bool
    let model: SwitcherViewModel

    var body: some View {
        Image(nsImage: tile.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: Metrics.icon, height: Metrics.icon)
            .padding(Metrics.tilePadding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.16) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.28) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { model.onPoint(tile.id) }
            }
            .onTapGesture { model.onClick(tile.id) }
            .accessibilityElement()
            .accessibilityLabel(tile.name)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.onClick(tile.id) }
    }
}

// MARK: Managing

private struct ManagingView: View {
    let model: SwitcherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Pinned Apps")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.message ?? "Click an app to pin or unpin it. Only running apps can be newly pinned.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: model.contentWidth, alignment: .leading)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Metrics.manageTileWidth), spacing: Metrics.manageSpacing),
                                             count: model.columns),
                              spacing: Metrics.manageSpacing) {
                        ForEach(model.tiles) { tile in
                            ManageTile(tile: tile, isFocused: tile.id == model.selection, model: model)
                                .id(tile.id)
                        }
                    }
                }
                .frame(width: model.rowWidth, height: model.gridHeight)
                .frame(width: model.contentWidth)
                .onChange(of: model.selection) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }

            HStack {
                Text("Arrow keys move · Space pins or unpins · Return closes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                PressButton(title: "Done", hint: nil, prominent: true, action: model.onDone)
            }
            .frame(width: model.contentWidth)
        }
        .padding(Metrics.panelPadding)
    }
}

private struct ManageTile: View {
    let tile: SwitcherViewModel.Tile
    let isFocused: Bool
    let model: SwitcherViewModel

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: tile.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Metrics.manageIcon, height: Metrics.manageIcon)
                .overlay(alignment: .topTrailing) {
                    PinBadge(isPinned: tile.isPinned)
                        .offset(x: 8, y: -6)
                }
                .padding(.top, 6)
            Text(tile.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
            Text(status)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(width: Metrics.manageTileWidth, height: Metrics.manageTileHeight)
        .opacity(tile.isRunning ? 1 : 0.55)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tile.isPinned ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active = phase { model.onPoint(tile.id) }
        }
        .onTapGesture { model.onClick(tile.id) }
        .accessibilityElement()
        .accessibilityLabel(tile.isPinned ? "Unpin \(tile.name)" : "Pin \(tile.name)")
        .accessibilityValue(status)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onClick(tile.id) }
    }

    private var status: String {
        switch (tile.isPinned, tile.isRunning) {
        case (true, true): return "Pinned"
        case (true, false): return "Pinned · not running"
        case (false, true): return "Not pinned"
        case (false, false): return tile.canToggle ? "Unpinned · not running" : "Not running"
        }
    }
}

/// Filled pin when pinned, outlined when not: state is conveyed by shape and text, not only colour.
private struct PinBadge: View {
    let isPinned: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isPinned ? Color.accentColor : Color(nsColor: .windowBackgroundColor).opacity(0.9))
            Circle()
                .strokeBorder(isPinned ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1)
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isPinned ? Color.white : Color.secondary)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// A button that acts on mouse-down, so entering Manage wins against a near-simultaneous modifier release.
private struct PressButton: View {
    let title: String
    let hint: String?
    let prominent: Bool
    let action: () -> Void
    /// Gesture-scoped, so it resets even when the panel hides mid-press and mouse-up never arrives.
    @GestureState private var isPressed = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let hint {
                Text(hint)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.5)))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .background(
            Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(isPressed ? 0.22 : 0.12))
        )
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, pressed, _ in
                    guard !pressed else { return }
                    pressed = true
                    action()
                }
        )
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
