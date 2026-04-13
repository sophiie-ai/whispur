import SwiftUI

struct ProviderRequestRow: View {
    let entry: ProviderRequestLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.providerID.providerDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                PreferenceBadge(title: entry.kind.rawValue, tone: .neutral)
                PreferenceBadge(title: statusLabel, tone: statusTone)

                Spacer(minLength: 6)

                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Text("\(entry.httpMethod) \(entry.endpointURL)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(entry.errorMessage ?? responseSummary)
                .font(.caption)
                .lineLimit(2)
        }
        .padding(.vertical, 8)
    }

    private var statusLabel: String {
        if let statusCode = entry.statusCode {
            return "\(statusCode)"
        }
        return "Transport"
    }

    private var statusTone: PreferenceBadge.Tone {
        guard let statusCode = entry.statusCode else { return .warning }
        switch statusCode {
        case 200 ... 299: return .good
        case 400 ... 599: return .critical
        default: return .warning
        }
    }

    private var responseSummary: String {
        let text = entry.responseBodyPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No response body." : text
    }
}

struct ProviderRequestDetailBlock: View {
    let title: String
    let value: String
    let tone: PreferenceBadge.Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(tone == .critical ? Color.red : Color.secondary)

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

extension String {
    var providerDisplayName: String {
        if let sttProvider = STTProviderID(rawValue: self) {
            return sttProvider.displayName
        }
        if let llmProvider = LLMProviderID(rawValue: self) {
            return llmProvider.displayName
        }
        return replacingOccurrences(of: "-", with: " ").capitalized
    }
}
