import Foundation
import PastaCore

/// Groups clipboard entries into time-based sections.
enum TimeGrouper {
    static func group(_ entries: [ClipboardEntry]) -> [(String, [ClipboardEntry])] {
        let now = Date()
        let calendar = Calendar.current

        var groups: [(String, [ClipboardEntry])] = []
        var lastMinute: [ClipboardEntry] = []
        var last5Min: [ClipboardEntry] = []
        var lastHour: [ClipboardEntry] = []
        var today: [ClipboardEntry] = []
        var yesterday: [ClipboardEntry] = []
        var thisWeek: [ClipboardEntry] = []
        var older: [ClipboardEntry] = []

        let oneMinuteAgo = now.addingTimeInterval(-60)
        let fiveMinutesAgo = now.addingTimeInterval(-300)
        let oneHourAgo = now.addingTimeInterval(-3600)
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!

        for entry in entries {
            if entry.timestamp > oneMinuteAgo {
                lastMinute.append(entry)
            } else if entry.timestamp > fiveMinutesAgo {
                last5Min.append(entry)
            } else if entry.timestamp > oneHourAgo {
                lastHour.append(entry)
            } else if entry.timestamp >= startOfToday {
                today.append(entry)
            } else if entry.timestamp >= startOfYesterday {
                yesterday.append(entry)
            } else if entry.timestamp >= startOfWeek {
                thisWeek.append(entry)
            } else {
                older.append(entry)
            }
        }

        if !lastMinute.isEmpty { groups.append(("Last Minute", lastMinute)) }
        if !last5Min.isEmpty { groups.append(("Last 5 Minutes", last5Min)) }
        if !lastHour.isEmpty { groups.append(("Last Hour", lastHour)) }
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !older.isEmpty { groups.append(("Older", older)) }

        return groups
    }
}
