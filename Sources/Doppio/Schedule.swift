// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure logic for the recurring weekly keep-awake window. Kept separate from
/// the coordinator so it can be unit-tested deterministically.
enum Schedule {
    /// Is the window active at `date`?
    ///
    /// - `weekdays` are `Calendar` weekday numbers (1=Sun … 7=Sat) on which the
    ///   window *starts*.
    /// - Same-day windows (`start < end`, e.g. 09:00–18:00) are active on the
    ///   listed weekdays.
    /// - Overnight windows (`start > end`, e.g. 22:00–06:00) stay active past
    ///   midnight into the following day, still attributed to the start day.
    /// - `start == end` is treated as disabled (zero-length).
    static func isActive(date: Date,
                         startMinutes: Int,
                         endMinutes: Int,
                         weekdays: Set<Int>,
                         calendar: Calendar = .current) -> Bool {
        guard startMinutes != endMinutes, !weekdays.isEmpty else { return false }
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = comps.weekday, let h = comps.hour, let m = comps.minute else {
            return false
        }
        let now = h * 60 + m

        if startMinutes < endMinutes {
            return weekdays.contains(wd) && now >= startMinutes && now < endMinutes
        } else {
            // Overnight: evening portion belongs to today's start day; the
            // after-midnight portion belongs to yesterday's start day.
            let yesterday = wd == 1 ? 7 : wd - 1
            return (now >= startMinutes && weekdays.contains(wd))
                || (now < endMinutes && weekdays.contains(yesterday))
        }
    }

    /// "09:00" from minutes-since-midnight.
    static func formatMinutes(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }
}
