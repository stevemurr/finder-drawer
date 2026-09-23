import AppKit

/// Deterministic Miller-column sizing.
///
/// Names establish each column's natural width, while the live browser
/// viewport decides whether columns grow, compress, or require horizontal
/// scrolling. Keeping the calculation stateless prevents widths from jumping
/// merely because selection changed.
@MainActor
enum BrowserColumnSizing {
    nonisolated static let minimumWidth: CGFloat = 220
    nonisolated static let maximumWidth: CGFloat = 520
    nonisolated static let filenameChrome: CGFloat = 62
    static let dividerWidth: CGFloat = 1
    nonisolated(unsafe) static let filenameFont = NSFont.systemFont(ofSize: 13)
    nonisolated static let measurementSampleLimit = 512

    /// A robust natural width: the 90th-percentile filename rather than the
    /// longest one, so one generated/pathological name cannot make every
    /// sibling pay for a 500-point column.
    ///
    /// Measurement is nonisolated so `DirectoryLister` can run it beside the
    /// directory read instead of on the main actor when a listing lands.
    nonisolated static func naturalWidth(displayNames: [String]) -> CGFloat {
        naturalWidth(displayNames: displayNames, font: filenameFont)
    }

    nonisolated static func naturalWidth(entries: [DirectoryEntry]) -> CGFloat {
        naturalWidth(displayNames: representativeDisplayNames(from: entries))
    }

    /// Core Text rather than `NSString` sizing: a `CTLine` is safe to build
    /// on any thread and measures the same single-line typographic width.
    nonisolated static func naturalWidth(displayNames: [String], font: NSFont) -> CGFloat {
        guard !displayNames.isEmpty else { return minimumWidth }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = displayNames.map { name -> CGFloat in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: attributes))
            return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }.sorted()
        let percentileIndex = max(
            0,
            min(measured.count - 1, Int(ceil(Double(measured.count) * 0.9)) - 1)
        )
        return clamp(measured[percentileIndex] + filenameChrome)
    }

    static func widths(
        for columns: [BrowserColumn],
        availableWidth: CGFloat,
        focusedIndex: Int
    ) -> [CGFloat] {
        let natural = columns.map {
            $0.naturalWidthHint ?? naturalWidth(entries: $0.entries)
        }
        return distribute(
            naturalWidths: natural,
            availableWidth: availableWidth,
            focusedIndex: focusedIndex
        )
    }

    /// Even sampling retains short and long regions of an already-sorted
    /// listing while putting a hard ceiling on AppKit font measurement. The
    /// first and last rows are always represented.
    nonisolated static func representativeDisplayNames(from entries: [DirectoryEntry]) -> [String] {
        representativeDisplayNames(from: entries, limit: measurementSampleLimit)
    }

    nonisolated static func representativeDisplayNames(
        from entries: [DirectoryEntry],
        limit: Int
    ) -> [String] {
        guard limit > 0, !entries.isEmpty else { return [] }
        guard entries.count > limit else {
            return entries.map(\.displayName)
        }
        guard limit > 1 else { return [entries[0].displayName] }

        let stride = Double(entries.count - 1) / Double(limit - 1)
        return (0..<limit).map { offset in
            entries[Int((Double(offset) * stride).rounded())].displayName
        }
    }

    /// Pure distribution surface used by tests and by the measured-name path.
    static func distribute(
        naturalWidths: [CGFloat],
        availableWidth: CGFloat,
        focusedIndex: Int
    ) -> [CGFloat] {
        guard !naturalWidths.isEmpty else { return [] }
        var widths = naturalWidths.map(clamp)
        let dividerTotal = CGFloat(max(widths.count - 1, 0)) * dividerWidth
        let usable = max(availableWidth - dividerTotal, 0)
        let minimumTotal = CGFloat(widths.count) * minimumWidth
        let naturalTotal = widths.reduce(0, +)

        // When even readable minima do not fit, preserve them and let the
        // horizontal ScrollView do its job.
        guard usable >= minimumTotal else {
            return Array(repeating: minimumWidth, count: widths.count)
        }

        if naturalTotal > usable {
            shrink(
                &widths,
                by: naturalTotal - usable,
                focusedIndex: focusedIndex
            )
        } else if naturalTotal < usable {
            grow(
                &widths,
                by: usable - naturalTotal,
                focusedIndex: focusedIndex
            )
        }
        return widths
    }

    private static func grow(
        _ widths: inout [CGFloat],
        by requestedExtra: CGFloat,
        focusedIndex: Int
    ) {
        var extra = requestedExtra
        while extra > 0.5 {
            let eligible = widths.indices.filter { widths[$0] < maximumWidth - 0.5 }
            guard !eligible.isEmpty else { break }
            let weights = eligible.map { growthWeight(for: $0, count: widths.count, focusedIndex: focusedIndex) }
            let totalWeight = weights.reduce(0, +)
            var allocated: CGFloat = 0
            for (offset, index) in eligible.enumerated() {
                let share = extra * weights[offset] / totalWeight
                let amount = min(share, maximumWidth - widths[index])
                widths[index] += amount
                allocated += amount
            }
            guard allocated > 0.5 else { break }
            extra -= allocated
        }

        // `maximumWidth` protects the natural-width calculation from one
        // pathological name; it must not manufacture dead space in a wide
        // viewport. Once every column has reached that balanced cap, let the
        // working and trailing columns absorb the remainder. This keeps the
        // browser edge-to-edge and gives a long filename real room instead of
        // truncating beside an empty canvas.
        guard extra > 0.5 else { return }
        let focused = widths.indices.contains(focusedIndex)
            ? focusedIndex
            : widths.index(before: widths.endIndex)
        let trailing = widths.index(before: widths.endIndex)
        let recipients = focused == trailing ? [focused] : [focused, trailing]
        let weights = recipients.map {
            growthWeight(for: $0, count: widths.count, focusedIndex: focused)
        }
        let totalWeight = weights.reduce(0, +)
        var allocated: CGFloat = 0
        for (offset, index) in recipients.dropLast().enumerated() {
            let amount = extra * weights[offset] / totalWeight
            widths[index] += amount
            allocated += amount
        }
        widths[recipients.last!] += extra - allocated
    }

    private static func shrink(
        _ widths: inout [CGFloat],
        by requestedDeficit: CGFloat,
        focusedIndex: Int
    ) {
        var deficit = requestedDeficit
        while deficit > 0.5 {
            let eligible = widths.indices.filter { widths[$0] > minimumWidth + 0.5 }
            guard !eligible.isEmpty else { return }
            let weights = eligible.map { shrinkWeight(for: $0, count: widths.count, focusedIndex: focusedIndex) }
            let totalWeight = weights.reduce(0, +)
            var removed: CGFloat = 0
            for (offset, index) in eligible.enumerated() {
                let share = deficit * weights[offset] / totalWeight
                let amount = min(share, widths[index] - minimumWidth)
                widths[index] -= amount
                removed += amount
            }
            guard removed > 0.5 else { return }
            deficit -= removed
        }
    }

    private static func growthWeight(for index: Int, count: Int, focusedIndex: Int) -> CGFloat {
        if index == focusedIndex { return 2.0 }
        if index == count - 1 { return 1.45 }
        return 1
    }

    private static func shrinkWeight(for index: Int, count: Int, focusedIndex: Int) -> CGFloat {
        if index == focusedIndex { return 0.55 }
        if index == count - 1 { return 0.8 }
        return 1.35
    }

    private nonisolated static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }
}
