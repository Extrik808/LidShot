import AppKit
import IOKit.ps
import IOKit.pwr_mgt

final class LidController {
    static let sudoersPath = "/etc/sudoers.d/lidshot"
    static let batteryThreshold = 10

    private(set) var isOn = false
    private(set) var expiresAt: Date?
    private var assertionIDs: [IOPMAssertionID] = []
    private var expiryTimer: Timer?
    private var batteryTimer: Timer?

    var onChange: (() -> Void)?

    var batteryGuard: Bool {
        get { UserDefaults.standard.object(forKey: "batteryGuard") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "batteryGuard") }
    }

    var helperInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.sudoersPath)
    }

    var statusText: String {
        guard isOn else { return "Режим закрытой крышки: выкл." }
        guard let expiresAt else { return "Режим закрытой крышки: вкл." }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Режим закрытой крышки: вкл. до \(formatter.string(from: expiresAt))"
    }

    func syncWithSystem() {
        if Self.systemSleepDisabled() {
            activate(until: nil)
        }
    }

    @discardableResult
    func enable(for duration: TimeInterval? = nil) -> Bool {
        guard setSleepDisabled(true, interactive: true) else { return false }
        activate(until: duration.map { Date().addingTimeInterval($0) })
        return true
    }

    func disable(interactive: Bool = true) {
        guard isOn else { return }
        guard setSleepDisabled(false, interactive: interactive) else { return }
        deactivate()
    }

    func installHelper() -> Bool {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lidshot-\(UUID().uuidString).sudoers")
        do {
            try rule.write(to: temp, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        let path = Shell.quote(temp.path)
        return Shell.runAsAdmin(
            "/usr/sbin/visudo -cf \(path) && /usr/bin/install -m 0440 -o root -g wheel \(path) \(Self.sudoersPath)"
        )
    }

    func uninstallHelper() -> Bool {
        Shell.runAsAdmin("/bin/rm -f \(Self.sudoersPath)")
    }

    private func activate(until date: Date?) {
        isOn = true
        expiresAt = date
        if assertionIDs.isEmpty {
            let types = [
                kIOPMAssertionTypePreventUserIdleSystemSleep,
                kIOPMAssertionTypePreventUserIdleDisplaySleep,
                "NetworkClientActive"
            ]
            for type in types {
                var id: IOPMAssertionID = 0
                let status = IOPMAssertionCreateWithName(
                    type as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "LidShot: режим закрытой крышки" as CFString,
                    &id
                )
                if status == kIOReturnSuccess {
                    assertionIDs.append(id)
                }
            }
        }
        expiryTimer?.invalidate()
        expiryTimer = nil
        if let date {
            expiryTimer = Timer.scheduledTimer(withTimeInterval: max(date.timeIntervalSinceNow, 1), repeats: false) { [weak self] _ in
                self?.disable(interactive: false)
            }
        }
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkBattery()
        }
        onChange?()
    }

    private func deactivate() {
        isOn = false
        expiresAt = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        assertionIDs.forEach { IOPMAssertionRelease($0) }
        assertionIDs.removeAll()
        onChange?()
    }

    private func checkBattery() {
        guard batteryGuard, let battery = Self.battery(), battery.onBattery,
              battery.percent <= Self.batteryThreshold else { return }
        disable(interactive: false)
    }

    private func setSleepDisabled(_ on: Bool, interactive: Bool) -> Bool {
        let value = on ? "1" : "0"
        if helperInstalled,
           Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]).status == 0 {
            return true
        }
        guard interactive else { return false }
        return Shell.runAsAdmin("/usr/bin/pmset -a disablesleep \(value)")
    }

    static func systemSleepDisabled() -> Bool {
        Shell.run("/usr/bin/pmset", ["-g"]).output
            .split(separator: "\n")
            .contains { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                return parts.first == "SleepDisabled" && parts.last == "1"
            }
    }

    static func battery() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let onBattery = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (current * 100 / maximum, onBattery)
        }
        return nil
    }
}
