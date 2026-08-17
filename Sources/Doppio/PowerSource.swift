// SPDX-License-Identifier: Apache-2.0
import Foundation
import IOKit.ps

/// Reads the current power source (AC vs battery) and charge level via IOKit.
enum PowerSource {
    struct State {
        let onAC: Bool
        /// Battery charge 0–100, or nil on desktops / when unknown.
        let percent: Int?
    }

    static func current() -> State {
        // Desktops (no battery) report AC; treat a missing snapshot as AC too.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return State(onAC: true, percent: nil)
        }

        let providing = IOPSGetProvidingPowerSourceType(blob)?
            .takeUnretainedValue() as String?
        let onAC = (providing == (kIOPSACPowerValue as String))

        var percent: Int?
        if let sources = IOPSCopyPowerSourcesList(blob)?
            .takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
                if let cur = desc[kIOPSCurrentCapacityKey as String] as? Int,
                   let max = desc[kIOPSMaxCapacityKey as String] as? Int, max > 0 {
                    percent = Int((Double(cur) / Double(max) * 100).rounded())
                    break
                }
            }
        }
        return State(onAC: onAC, percent: percent)
    }
}
