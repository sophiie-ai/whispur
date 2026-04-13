import SwiftUI

private enum ProviderRequestStatusFilter: String, CaseIterable, Identifiable {
    case all = "All statuses"
    case success = "2xx"
    case clientError = "4xx"
    case serverError = "5xx"
    case transport = "Transport"

    var id: String { rawValue }

    func matches(_ entry: ProviderRequestLogEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .success:
            guard let statusCode = entry.statusCode else { return false }
            return (200 ... 299).contains(statusCode)
        case .clientError:
            guard let statusCode = entry.statusCode else { return false }
            return (400 ... 499).contains(statusCode)
        case .serverError:
            guard let statusCode = entry.statusCode else { return false }
            return (500 ... 599).contains(statusCode)
        case .transport:
            return entry.statusCode == nil
        }
    }
}

struct RequestsSettingsView: View {
    @ObservedObject var appState: AppState

    @State private var providerFilter = "all"
    @State private var statusFilter: ProviderRequestStatusFilter = .all
    @State private var selectedEntryID: ProviderRequestLogEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PreferenceCard(
                "Provider Requests",
                detail: "Review recent STT and cleanup API calls, including status, timing, and response previews.",
                icon: "network"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    headerRow
                    filterRow
                    contentArea
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            PreferenceBadge(title: "\(appState.providerRequestLog.items.count) saved", tone: .neutral)
            PreferenceBadge(title: "\(filteredEntries.count) shown", tone: .neutral)
            PreferenceBadge(title: "\(errorCount) errors", tone: errorCount == 0 ? .good : .warning)

            Spacer()

            Button("Clear Log") {
                appState.providerRequestLog.clear()
                selectedEntryID = nil
            }
            .buttonStyle(.bordered)
            .disabled(appState.providerRequestLog.items.isEmpty)
        }
    }

    private var filterRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            HStack(spacing: 8) {
                Text("Provider")
                    .font(.subheadline.weight(.medium))
                    .fixedSize()
                Picker("Provider", selection: $providerFilter) {
                    Text("All providers").tag("all")
                    ForEach(providerOptions, id: \.self) { providerID in
                        Text(providerID.providerDisplayName).tag(providerID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 160)
            }

            HStack(spacing: 8) {
                Text("Status")
                    .font(.subheadline.weight(.medium))
                    .fixedSize()
                Picker("Status", selection: $statusFilter) {
                    ForEach(ProviderRequestStatusFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 140)
            }

            Spacer(minLength: 0)
        }
    }

    private var contentArea: some View {
        HSplitView {
            listPane
                .frame(minWidth: 260, idealWidth: 360)
            inspectorPane
                .frame(minWidth: 300)
        }
        .frame(maxWidth: .infinity, minHeight: 460, alignment: .topLeading)
    }

    private var listPane: some View {
        Group {
            if filteredEntries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Matching Requests")
                        .font(.headline)

                    Text(appState.providerRequestLog.items.isEmpty
                        ? "Make a provider-backed request and it will appear here with status, duration, and the provider response."
                        : "Adjust the filters to show matching requests.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(18)
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(filteredEntries) { entry in
                        ProviderRequestRow(entry: entry)
                            .tag(entry.id)
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    if selectedEntry == nil {
                        selectedEntryID = filteredEntries.first?.id
                    }
                }
                .onChange(of: filteredEntries.map(\.id)) { _, _ in
                    if selectedEntry == nil {
                        selectedEntryID = filteredEntries.first?.id
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let selectedEntry {
                    HStack(spacing: 8) {
                        PreferenceBadge(title: selectedEntry.providerID.providerDisplayName, tone: .neutral)
                        PreferenceBadge(title: selectedEntry.kind.rawValue, tone: .neutral)
                        PreferenceBadge(title: statusLabel(for: selectedEntry), tone: statusTone(for: selectedEntry))
                        PreferenceBadge(title: "\(selectedEntry.durationMS) ms", tone: .neutral)
                        Spacer(minLength: 0)
                    }

                    detailBlock("When", selectedEntry.timestamp.formatted(date: .abbreviated, time: .standard))
                    detailBlock("Endpoint", selectedEntry.endpointURL)
                    detailBlock("Request", selectedEntry.requestSummary)
                    detailBlock("Response Preview", selectedEntry.responseBodyPreview.isEmpty ? "No response body." : selectedEntry.responseBodyPreview)

                    if let errorMessage = selectedEntry.errorMessage, !errorMessage.isEmpty {
                        detailBlock("Error", errorMessage, tone: .critical)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select a Request")
                            .font(.headline)

                        Text("The inspector will show the sanitized request summary and the provider response preview.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var providerOptions: [String] {
        Array(Set(appState.providerRequestLog.items.map(\.providerID))).sorted {
            $0.providerDisplayName.localizedCaseInsensitiveCompare($1.providerDisplayName) == .orderedAscending
        }
    }

    private var filteredEntries: [ProviderRequestLogEntry] {
        appState.providerRequestLog.items.filter { entry in
            let matchesProvider = providerFilter == "all" || entry.providerID == providerFilter
            return matchesProvider && statusFilter.matches(entry)
        }
    }

    private var selectedEntry: ProviderRequestLogEntry? {
        if let selectedEntryID {
            return filteredEntries.first(where: { $0.id == selectedEntryID })
        }
        return filteredEntries.first
    }

    private var errorCount: Int {
        appState.providerRequestLog.items.filter { entry in
            if let statusCode = entry.statusCode {
                return !(200 ... 299).contains(statusCode)
            }
            return entry.errorMessage != nil
        }.count
    }

    private func statusLabel(for entry: ProviderRequestLogEntry) -> String {
        if let statusCode = entry.statusCode {
            return "\(statusCode)"
        }
        return "Transport"
    }

    private func statusTone(for entry: ProviderRequestLogEntry) -> PreferenceBadge.Tone {
        guard let statusCode = entry.statusCode else { return .warning }
        switch statusCode {
        case 200 ... 299:
            return .good
        case 400 ... 599:
            return .critical
        default:
            return .warning
        }
    }
}

private struct ProviderRequestRow: View {
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
        case 200 ... 299:
            return .good
        case 400 ... 599:
            return .critical
        default:
            return .warning
        }
    }

    private var responseSummary: String {
        let text = entry.responseBodyPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No response body." : text
    }
}

private struct ProviderRequestDetailBlock: View {
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

private extension RequestsSettingsView {
    func detailBlock(_ title: String, _ value: String, tone: PreferenceBadge.Tone = .neutral) -> some View {
        ProviderRequestDetailBlock(title: title, value: value, tone: tone)
    }
}

private extension String {
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
