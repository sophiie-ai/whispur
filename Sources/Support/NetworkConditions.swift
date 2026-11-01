import Foundation
import Network

/// Watches whether the network is one a large background download should
/// wait out: Low Data Mode, or an expensive interface such as a phone
/// hotspot.
@MainActor
final class NetworkConditionsMonitor {
    private let monitor = NWPathMonitor()

    /// `onChange` runs on the main actor with the first path and every
    /// change after it; true means hold background downloads.
    init(onChange: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let constrained = Self.holdsBackgroundDownloads(isConstrained: path.isConstrained, isExpensive: path.isExpensive)
            Task { @MainActor in onChange(constrained) }
        }
        monitor.start(queue: DispatchQueue(label: "ai.sophiie.whispur.network-conditions", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    nonisolated static func holdsBackgroundDownloads(isConstrained: Bool, isExpensive: Bool) -> Bool {
        isConstrained || isExpensive
    }
}
