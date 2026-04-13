import SwiftUI

enum ProviderRequestStatusFilter: String, CaseIterable, Identifiable {
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
                    RequestsHeaderRow(
                        totalCount: appState.providerRequestLog.items.count,
                        shownCount: filteredEntries.count,
                        errorCount: errorCount,
                        onClear: {
                            appState.providerRequestLog.clear()
                            selectedEntryID = nil
                        }
                    )
                    RequestsFilterBar(
                        providerOptions: providerOptions,
                        providerFilter: $providerFilter,
                        statusFilter: $statusFilter
                    )
                    contentArea
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contentArea: some View {
        HSplitView {
            RequestsListPane(
                filteredEntries: filteredEntries,
                isLogEmpty: appState.providerRequestLog.items.isEmpty,
                selectedEntryID: $selectedEntryID
            )
            .frame(minWidth: 260, idealWidth: 360)

            RequestsInspectorPane(entry: selectedEntry)
                .frame(minWidth: 300)
        }
        .frame(maxWidth: .infinity, minHeight: 460, alignment: .topLeading)
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
}

// MARK: - Subviews

private struct RequestsHeaderRow: View {
    let totalCount: Int
    let shownCount: Int
    let errorCount: Int
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PreferenceBadge(title: "\(totalCount) saved", tone: .neutral)
            PreferenceBadge(title: "\(shownCount) shown", tone: .neutral)
            PreferenceBadge(title: "\(errorCount) errors", tone: errorCount == 0 ? .good : .warning)

            Spacer()

            Button("Clear Log", action: onClear)
                .buttonStyle(.bordered)
                .disabled(totalCount == 0)
        }
    }
}

private struct RequestsFilterBar: View {
    let providerOptions: [String]
    @Binding var providerFilter: String
    @Binding var statusFilter: ProviderRequestStatusFilter

    var body: some View {
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
}

private struct RequestsListPane: View {
    let filteredEntries: [ProviderRequestLogEntry]
    let isLogEmpty: Bool
    @Binding var selectedEntryID: ProviderRequestLogEntry.ID?

    var body: some View {
        Group {
            if filteredEntries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Matching Requests")
                        .font(.headline)

                    Text(isLogEmpty
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
                    if selectedEntryID == nil {
                        selectedEntryID = filteredEntries.first?.id
                    }
                }
                .onChange(of: filteredEntries.map(\.id)) { _, _ in
                    if selectedEntryID == nil || !filteredEntries.contains(where: { $0.id == selectedEntryID }) {
                        selectedEntryID = filteredEntries.first?.id
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RequestsInspectorPane: View {
    let entry: ProviderRequestLogEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let entry {
                    HStack(spacing: 8) {
                        PreferenceBadge(title: entry.providerID.providerDisplayName, tone: .neutral)
                        PreferenceBadge(title: entry.kind.rawValue, tone: .neutral)
                        PreferenceBadge(title: statusLabel(for: entry), tone: statusTone(for: entry))
                        PreferenceBadge(title: "\(entry.durationMS) ms", tone: .neutral)
                        Spacer(minLength: 0)
                    }

                    ProviderRequestDetailBlock(title: "When", value: entry.timestamp.formatted(date: .abbreviated, time: .standard), tone: .neutral)
                    ProviderRequestDetailBlock(title: "Endpoint", value: entry.endpointURL, tone: .neutral)
                    ProviderRequestDetailBlock(title: "Request", value: entry.requestSummary, tone: .neutral)
                    ProviderRequestDetailBlock(
                        title: "Response Preview",
                        value: entry.responseBodyPreview.isEmpty ? "No response body." : entry.responseBodyPreview,
                        tone: .neutral
                    )

                    if let errorMessage = entry.errorMessage, !errorMessage.isEmpty {
                        ProviderRequestDetailBlock(title: "Error", value: errorMessage, tone: .critical)
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

    private func statusLabel(for entry: ProviderRequestLogEntry) -> String {
        if let statusCode = entry.statusCode {
            return "\(statusCode)"
        }
        return "Transport"
    }

    private func statusTone(for entry: ProviderRequestLogEntry) -> PreferenceBadge.Tone {
        guard let statusCode = entry.statusCode else { return .warning }
        switch statusCode {
        case 200 ... 299: return .good
        case 400 ... 599: return .critical
        default: return .warning
        }
    }
}
