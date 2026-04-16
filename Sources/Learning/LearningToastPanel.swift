import AppKit
import Combine
import SwiftUI

/// Candidate substitution surfaced after a paste — the user edited
/// "from" into "to" and we're asking whether to remember the new spelling.
struct VocabularySuggestion: Identifiable, Equatable {
    let id = UUID()
    let from: String
    let to: String
}

/// Drives the floating toast that replaces the old NSAlert flow. Multiple
/// suggestions queue inside one panel so the user can accept or dismiss
/// them all without blocking anything.
@MainActor
final class LearningSuggestionCenter: ObservableObject {
    @Published var pending: [VocabularySuggestion] = []
    /// Fires when the user clicks "Add" for a suggestion.
    var onAccept: ((VocabularySuggestion) -> Void)?

    func present(_ suggestions: [VocabularySuggestion]) {
        pending.append(contentsOf: suggestions)
    }

    func accept(_ suggestion: VocabularySuggestion) {
        pending.removeAll { $0.id == suggestion.id }
        onAccept?(suggestion)
    }

    func dismiss(_ suggestion: VocabularySuggestion) {
        pending.removeAll { $0.id == suggestion.id }
    }

    func dismissAll() {
        pending.removeAll()
    }
}

/// Non-modal panel shown at the bottom-right of the screen while the user
/// continues working. Auto-hides when the queue empties.
@MainActor
final class LearningToastPanelManager {
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var autoDismiss: Task<Void, Never>?

    func bind(to center: LearningSuggestionCenter) {
        cancellable = center.$pending
            .receive(on: RunLoop.main)
            .sink { [weak self] pending in
                guard let self else { return }
                if pending.isEmpty {
                    self.hide()
                } else {
                    self.show(center: center)
                    self.scheduleAutoDismiss(center: center)
                }
            }
    }

    private func show(center: LearningSuggestionCenter) {
        if panel == nil {
            let hosting = NSHostingView(rootView: LearningToastView(center: center).frame(width: 360))
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = false
            panel.contentView = hosting
            self.panel = panel
        }
        positionPanel()
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        autoDismiss?.cancel()
        autoDismiss = nil
    }

    private func scheduleAutoDismiss(center: LearningSuggestionCenter) {
        autoDismiss?.cancel()
        autoDismiss = Task { [weak self, weak center] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                center?.dismissAll()
                self?.hide()
            }
        }
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        let x = visibleFrame.maxX - size.width - 20
        let y = visibleFrame.minY + 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct LearningToastView: View {
    @ObservedObject var center: LearningSuggestionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text("Learn from your edits?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    center.dismissAll()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(center.pending.prefix(3)) { suggestion in
                    SuggestionRow(suggestion: suggestion, center: center)
                }
                if center.pending.count > 3 {
                    Text("+\(center.pending.count - 3) more")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.94), Color.black.opacity(0.84)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct SuggestionRow: View {
    let suggestion: VocabularySuggestion
    @ObservedObject var center: LearningSuggestionCenter

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(suggestion.from)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .strikethrough(true, color: .white.opacity(0.4))
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                Text(suggestion.to)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .lineLimit(1)

            Spacer(minLength: 4)

            Button("Add") {
                center.accept(suggestion)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .tint(.orange)

            Button("Skip") {
                center.dismiss(suggestion)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }
}
