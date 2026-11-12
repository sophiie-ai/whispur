import Foundation

/// The cap the history, diagnostics and request logs share: keep the newest
/// `maxItems`, plus up to `maxPinnedItems` older pinned ones (failed or
/// anomalous dictations), so a burst of normal dictations can't push out
/// the ones worth debugging, and the files still can't grow without limit.
enum PinnedTrim {
    /// `items` is newest first; so is the result. `dropped` lists what was
    /// removed, so callers can delete files that belonged to it.
    static func trim<Item>(
        _ items: [Item],
        maxItems: Int,
        maxPinnedItems: Int,
        isPinned: (Item) -> Bool
    ) -> (kept: [Item], dropped: [Item]) {
        guard items.count > maxItems else { return (items, []) }
        var kept = Array(items.prefix(maxItems))
        var dropped: [Item] = []
        var pinnedKept = 0
        for item in items.dropFirst(maxItems) {
            if pinnedKept < maxPinnedItems, isPinned(item) {
                kept.append(item)
                pinnedKept += 1
            } else {
                dropped.append(item)
            }
        }
        return (kept, dropped)
    }
}
