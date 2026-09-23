import SwiftUI
import Observation

/// A local strip gesture keeps tab moves separate from file drag-and-drop.
/// Hovering previews a pair; only release mutates the workspace.
@MainActor @Observable
final class DrawerTabDragState {
    var frames: [UUID: CGRect] = [:]
    var sourceID: UUID?
    var location: CGPoint = .zero
    var translation: CGSize = .zero

    func mergeTarget(in groups: [DrawerTabGroup]) -> UUID? {
        guard let sourceIndex = groups.firstIndex(where: { $0.id == sourceID }),
              groups[sourceIndex].secondaryID == nil, isInsideStrip else { return nil }
        return [sourceIndex - 1, sourceIndex + 1].first { index in
            guard groups.indices.contains(index), groups[index].secondaryID == nil,
                  let frame = frames[groups[index].id] else { return false }
            // Leave the edges available for insertion without accidental pairing.
            return frame.insetBy(dx: min(18, frame.width * 0.15), dy: 0).contains(location)
        }.map { groups[$0].id }
    }

    func destination(in groups: [DrawerTabGroup]) -> UUID? {
        groups.first { group in
            group.id != sourceID && frames[group.id].map { location.x < $0.midX } == true
        }?.id
    }

    var isInsideStrip: Bool {
        guard let sourceID, let frame = frames[sourceID] else { return false }
        return location.y >= frame.minY - 12 && location.y <= frame.maxY + 12
    }

    @discardableResult
    func finish(in workspace: DrawerWorkspace) -> Bool {
        defer { cancel() }
        guard let sourceID, isInsideStrip else { return false }
        if let target = mergeTarget(in: workspace.tabGroups) {
            return workspace.mergeGroups(sourceID, into: target)
        }
        return workspace.moveGroup(sourceID, relativeTo: destination(in: workspace.tabGroups))
    }

    func cancel() {
        sourceID = nil
        translation = .zero
    }
}

struct DrawerTabDragGesture: ViewModifier {
    let workspace: DrawerWorkspace
    let state: DrawerTabDragState
    let groupID: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        content.highPriorityGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("drawer-tab-strip"))
                .updating($isDragging) { _, active, _ in active = true }
                .onChanged { value in
                    state.sourceID = groupID
                    state.location = value.location
                    state.translation = value.translation
                }
                .onEnded { value in
                    state.location = value.location
                    guard state.sourceID == groupID else { return }
                    let merging = state.mergeTarget(in: workspace.tabGroups) != nil
                    let animation: Animation = merging
                        ? .spring(response: 0.42, dampingFraction: 0.86)
                        : .easeInOut(duration: 0.18)
                    withAnimation(reduceMotion ? nil : animation) {
                        _ = state.finish(in: workspace)
                    }
                }
        )
        .onChange(of: isDragging) { _, active in
            if !active, state.sourceID == groupID { state.cancel() }
        }
    }
}

struct DrawerTabReordering: ViewModifier {
    let workspace: DrawerWorkspace
    let state: DrawerTabDragState
    let groupID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mergeTarget: UUID? { state.mergeTarget(in: workspace.tabGroups) }
    private var isSource: Bool { groupID != nil && state.sourceID == groupID }
    private var isTarget: Bool { groupID != nil && mergeTarget == groupID }
    private var previewAnimation: Animation? {
        guard !reduceMotion else { return nil }
        // Keep the release transaction's longer spring when the preview ends.
        return state.sourceID == nil ? .spring(response: 0.42, dampingFraction: 0.86) : .easeOut(duration: 0.18)
    }
    private var dragOffset: CGSize {
        guard isSource else { return .zero }
        return CGSize(width: state.translation.width,
                      height: max(-4, min(4, state.translation.height)) - (reduceMotion || mergeTarget == nil ? 0 : 5))
    }

    func body(content: Content) -> some View {
        accessible(content)
            .overlay {
                if isTarget {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.accentColor.opacity(0.1))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                        }
                        .padding(-4)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.94)))
                }
            }
            .scaleEffect(reduceMotion ? 1 : isTarget ? 0.96 : isSource && mergeTarget != nil ? 0.9 : 1)
            .rotationEffect(.degrees(!reduceMotion && isSource && mergeTarget != nil ? -4 : 0))
            .shadow(color: .black.opacity(isSource ? 0.16 : 0), radius: 8, y: 4)
            .offset(dragOffset)
            .animation(previewAnimation, value: mergeTarget)
            // Measure the stationary layout slot, not the lifted tab's bounds.
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { remember(geometry.frame(in: .named("drawer-tab-strip"))) }
                    .onChange(of: geometry.frame(in: .named("drawer-tab-strip"))) { _, frame in remember(frame) }
            })
            .overlay(alignment: .leading) {
                if state.sourceID != nil, state.isInsideStrip, mergeTarget == nil,
                   state.destination(in: workspace.tabGroups) == groupID {
                    Capsule().fill(Color.accentColor).frame(width: 2, height: 28)
                        .offset(x: -3).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if isTarget {
                    Text("Release to group")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                        .fixedSize().offset(y: 19)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .zIndex(isSource ? 2 : isTarget ? 1 : 0)
            .onDisappear {
                if let groupID { state.frames[groupID] = nil }
                if groupID != nil && state.sourceID == groupID { state.cancel() }
            }
    }

    private func remember(_ frame: CGRect) {
        if let groupID { state.frames[groupID] = frame }
    }

    @ViewBuilder private func accessible(_ content: Content) -> some View {
        if let groupID {
            content
                .accessibilityAction(named: "Move Tab Left") { workspace.moveGroup(groupID, by: -1) }
                .accessibilityAction(named: "Move Tab Right") { workspace.moveGroup(groupID, by: 1) }
        } else {
            content
        }
    }
}
