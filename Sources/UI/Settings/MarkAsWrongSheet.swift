import SwiftUI

/// "Mark as wrong": the raw and cleaned text of a dictation, what it should
/// have said, and a few tags. Saving appends one case to the local eval file.
struct MarkAsWrongSheet: View {
    private typealias Palette = SophiieTheme.Palette

    let item: PipelineResult
    let onSave: (_ expected: String, _ tags: [MyEvalCase.Tag]) -> Void
    let onCancel: () -> Void

    @State private var expected: String
    @State private var tags: Set<MyEvalCase.Tag> = []

    init(
        item: PipelineResult,
        onSave: @escaping (_ expected: String, _ tags: [MyEvalCase.Tag]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.onSave = onSave
        self.onCancel = onCancel
        _expected = State(initialValue: item.cleanedText)
    }

    private var trimmedExpected: String {
        expected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mark as wrong")
                    .font(SophiieTheme.Typography.title)
                    .foregroundStyle(Palette.ink)
                Text("Save this dictation as a private test case for the cleanup prompt.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
            }

            readOnlyBlock("What you said (raw)", item.rawTranscript)
            readOnlyBlock("What Whispur wrote", item.cleanedText)

            VStack(alignment: .leading, spacing: 6) {
                label("What it should have said")
                TextEditor(text: $expected)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 84, maxHeight: 140)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
                            .strokeBorder(Palette.controlBorder.opacity(0.6), lineWidth: 1)
                    )
                    .accessibilityLabel("What it should have said")
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Tags (optional)")
                FlowLayout(spacing: 6) {
                    ForEach(MyEvalCase.Tag.allCases) { tag in
                        TagToggle(title: tag.title, isOn: tags.contains(tag)) {
                            if tags.contains(tag) { tags.remove(tag) } else { tags.insert(tag) }
                        }
                    }
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Label("Stays on this Mac. Never uploaded.", systemImage: "lock")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.sophiieSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save Case") {
                    onSave(trimmedExpected, MyEvalCase.Tag.allCases.filter(tags.contains))
                }
                .buttonStyle(.sophiiePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedExpected.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Palette.surfaceWarm)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(SophiieTheme.Typography.captionStrong)
            .foregroundStyle(Palette.muted)
    }

    private func readOnlyBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            Text(text.isEmpty ? " " : text)
                .font(SophiieTheme.Typography.mono)
                .foregroundStyle(Palette.inkSecondary)
                .textSelection(.enabled)
                .lineLimit(6)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.small, style: .continuous))
        }
    }
}

private struct TagToggle: View {
    private typealias Palette = SophiieTheme.Palette

    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isOn ? Palette.ink : Palette.inkSecondary)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(isOn ? Palette.surfaceSelected : Palette.surface, in: Capsule())
            .overlay(Capsule().inset(by: 0.5).strokeBorder(isOn ? Palette.highlight.opacity(0.55) : Palette.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
