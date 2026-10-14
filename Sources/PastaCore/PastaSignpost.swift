import Foundation
import os

/// Signpost intervals for user-visible latency. They appear in the Points of
/// Interest lane in Instruments and cost almost nothing when not recording.
///
/// Intervals: `History load` (first page, then full paging), `FTS search`,
/// `Quick Search show`.
public enum PastaSignpost {
    public static let signposter = OSSignposter(subsystem: "com.pasta.clipboard", category: .pointsOfInterest)
}
