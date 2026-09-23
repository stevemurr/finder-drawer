import AppKit
import SwiftUI

/// drawer treatment for the reusable Miller-column stack.
enum BrowserColumnSurfaceStyle: Equatable {
    case standard

    var background: Color { DrawerTheme.surface }

    var divider: Color { DrawerTheme.line }

    var focusedColumnBackground: NSColor {
        NSColor.clear
    }

    var focusedSelection: NSColor {
        NSColor(DrawerTheme.shell).withAlphaComponent(0.14)
    }

    var unfocusedSelection: NSColor {
        NSColor(DrawerTheme.text).withAlphaComponent(0.10)
    }

    var focusRail: NSColor { NSColor(DrawerTheme.shell) }
}

/// A reusable, single-`BrowserViewModel` column surface.
///
/// Every drawer location mounts this exact view. Keeping the stack here
/// prevents the browser host from copying the browser's traversal
/// or file-operation behavior while allowing the two roots to own independent
/// surrounding chrome.
struct BrowserColumnSurface: View {
    @Bindable var viewModel: BrowserViewModel
    var showsItemSizes = false
    var showsOnlyFocusedColumn = false
    var style: BrowserColumnSurfaceStyle = .standard
    var accessibilityIdentifier = "browser-columns"
    var childAccessibilityPrefix = "browser"

    var body: some View {
        GeometryReader { geometry in
            let widths = BrowserColumnSizing.widths(
                for: viewModel.columns,
                availableWidth: geometry.size.width,
                focusedIndex: viewModel.focusedColumnIndex
            )

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(visibleColumns, id: \.element.id) {
                            index, column in
                            BrowserColumnContentView(
                                viewModel: viewModel,
                                index: index,
                                column: column,
                                showsItemSizes: showsItemSizes,
                                style: style,
                                accessibilityPrefix: childAccessibilityPrefix
                            )
                            .frame(
                                width: showsOnlyFocusedColumn ? geometry.size.width : widths.indices.contains(index)
                                    ? widths[index]
                                    : BrowserColumnSizing.minimumWidth
                            )
                            .id(column.id)

                            if !showsOnlyFocusedColumn && index < viewModel.columns.count - 1 {
                                Rectangle()
                                    .fill(style.divider)
                                    .frame(width: 1)
                            }
                        }
                    }
                    .frame(
                        minWidth: geometry.size.width,
                        maxHeight: .infinity,
                        alignment: .leading
                    )
                }
                .scrollIndicators(.automatic)
                // Keep the working column on screen as the user descends.
                .onChange(of: viewModel.focusedColumnIndex) { _, index in
                    guard viewModel.columns.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(viewModel.columns[index].id, anchor: .trailing)
                    }
                }
                .onChange(of: geometry.size.width) { _, _ in
                    guard viewModel.columns.indices.contains(viewModel.focusedColumnIndex) else { return }
                    proxy.scrollTo(viewModel.columns[viewModel.focusedColumnIndex].id, anchor: .trailing)
                }
                .onChange(of: viewModel.columns.count) { _, _ in
                    guard let last = viewModel.columns.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .trailing)
                    }
                }
            }
        }
        .background(style.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
    private var visibleColumns: [(offset: Int, element: BrowserColumn)] {
        let all = Array(viewModel.columns.enumerated())
        if showsOnlyFocusedColumn {
            let index = viewModel.columns.count > viewModel.focusedColumnIndex + 1 ? viewModel.focusedColumnIndex + 1 : viewModel.focusedColumnIndex
            return all.filter { $0.offset == index }
        }
        return all
    }

}

/// A column's table stays resident behind every transient state.
///
/// This is deliberately an internal type rather than a private helper so the
/// responder regression can be hosted and tested: a slow load must not replace
/// the AppKit table after the panel already focused it.
struct BrowserColumnContentView: View {
    @Bindable var viewModel: BrowserViewModel
    let index: Int
    let column: BrowserColumn
    var showsItemSizes = false
    var style: BrowserColumnSurfaceStyle = .standard
    var accessibilityPrefix = "browser"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(column.url.lastPathComponent.isEmpty ? "/" : column.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                if !column.isLoading { Text("\(column.entries.count) items").fixedSize() }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 34)
        ZStack {
            BrowserColumnTableView(
                viewModel: viewModel,
                index: index,
                column: column,
                renamingURL: viewModel.renamingURL,
                isFocusedColumn: viewModel.focusedColumnIndex == index,
                showsItemSizes: showsItemSizes,
                style: style,
                accessibilityPrefix: accessibilityPrefix
            )
            .opacity(column.presentationState == .content || column.presentationState == .empty ? 1 : 0)
            .allowsHitTesting(column.presentationState == .content || column.presentationState == .empty)

            switch column.presentationState {
            case .content:
                EmptyView()
            case .loading:
                BrowserColumnStatusView(
                    kind: .loading,
                    title: "Loading \(column.url.lastPathComponent)…",
                    detail: nil,
                    accessibilityIdentifier: "\(accessibilityPrefix)-column-loading-\(index)",
                    style: style,
                    retry: nil
                )
            case .empty:
                BrowserColumnStatusView(
                    kind: .empty,
                    title: "This folder is empty",
                    detail: column.url.lastPathComponent,
                    accessibilityIdentifier: "\(accessibilityPrefix)-column-empty-\(index)",
                    style: style,
                    retry: nil
                )
                .allowsHitTesting(false)
            case let .error(message):
                BrowserColumnStatusView(
                    kind: .error,
                    title: "Couldn’t load this folder",
                    detail: message,
                    accessibilityIdentifier: "\(accessibilityPrefix)-column-error-\(index)",
                    style: style,
                    retry: { viewModel.retryColumn(at: index) }
                )
            }
        }
        }
    }
}

private struct BrowserColumnStatusView: View {
    enum Kind: Equatable {
        case loading
        case empty
        case error

        var symbol: String {
            switch self {
            case .loading, .empty: "folder"
            case .error: "exclamationmark.triangle"
            }
        }
    }

    let kind: Kind
    let title: String
    let detail: String?
    let accessibilityIdentifier: String
    let style: BrowserColumnSurfaceStyle
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(DrawerTheme.muted)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DrawerTheme.muted)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            if kind == .loading {
                ProgressView()
                    .controlSize(.small)
                    .tint(DrawerTheme.shell)
            }
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusable()
                    .accessibilityIdentifier(accessibilityIdentifier.replacingOccurrences(
                        of: "error",
                        with: "retry"
                    ))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Finds one table by both browser identity and column index. Model identity
/// is essential when a drawer window mounts two column-zero tables.
@MainActor
enum BrowserColumnTableLocator {
    static func table(
        for viewModel: BrowserViewModel,
        columnIndex: Int,
        in view: NSView
    ) -> FileColumnTableView? {
        if let table = view as? FileColumnTableView,
           table.coordinator?.parent.viewModel === viewModel,
           table.coordinator?.parent.index == columnIndex {
            return table
        }
        for subview in view.subviews {
            if let table = table(
                for: viewModel,
                columnIndex: columnIndex,
                in: subview
            ) {
                return table
            }
        }
        return nil
    }
}
