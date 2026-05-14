import PastaCore
import SwiftUI

// MARK: - Unified Content Type / Filter Chip
//
// One chip view used in two distinct places:
//
//   • `.filterBar(...)`   — selectable pill in the QuickSearch filter row
//                           (icon + title + optional count badge, action on tap).
//   • `.activeDismissable` — pill displayed in the main SearchBar showing the
//                           currently active content-type filter, with a
//                           trailing ⓧ button to clear it.
//
// Both modes render the exact same visual output as the previous
// `FilterChip` (QuickSearchView) and `ContentTypeFilterChip` (SearchBarView)
// implementations they replaced.

struct ContentTypeFilterChip: View {
    enum Mode {
        /// Selectable filter chip used in QuickSearch's filter bar.
        case filterBar(isSelected: Bool, count: Int?, action: () -> Void)
        /// Active content-type pill with a dismiss button.
        case activeDismissable(onClear: () -> Void)
    }

    let title: String
    let icon: String
    let tint: Color
    let mode: Mode

    var body: some View {
        switch mode {
        case let .filterBar(isSelected, count, action):
            filterBarBody(isSelected: isSelected, count: count, action: action)
        case let .activeDismissable(onClear):
            activeDismissableBody(onClear: onClear)
        }
    }

    // MARK: filter-bar styling (matches former `FilterChip` in QuickSearchView)

    private func filterBarBody(isSelected: Bool, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: active-dismissable styling (matches former `ContentTypeFilterChip` in SearchBarView)

    private func activeDismissableBody(onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear content type filter")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tint.opacity(0.18))
        )
        .overlay(
            Capsule()
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        )
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Filtering by \(title)")
    }
}

// MARK: - Convenience initializers

extension ContentTypeFilterChip {
    /// Filter-bar chip (QuickSearch). Tint is unused in this mode.
    static func filterBar(
        title: String,
        icon: String,
        isSelected: Bool,
        count: Int?,
        action: @escaping () -> Void
    ) -> ContentTypeFilterChip {
        ContentTypeFilterChip(
            title: title,
            icon: icon,
            tint: .accentColor,
            mode: .filterBar(isSelected: isSelected, count: count, action: action)
        )
    }

    /// Active dismissable pill (SearchBar) for a given `ContentType`.
    static func activeDismissable(
        type: ContentType,
        onClear: @escaping () -> Void
    ) -> ContentTypeFilterChip {
        ContentTypeFilterChip(
            title: type.displayTitle,
            icon: type.systemImageName,
            tint: type.tint,
            mode: .activeDismissable(onClear: onClear)
        )
    }
}
