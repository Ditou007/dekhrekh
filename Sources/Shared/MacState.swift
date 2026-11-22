import Darwin
import Foundation

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

/// How long the Mac has been up and how strained it is, and whether a restart would help.
struct MacState {
    let bootTime: Date
    let pressure: MemoryPressure
    let swapUsedBytes: UInt64
    let totalBytes: UInt64

    var uptime: TimeInterval { Date().timeIntervalSince(bootTime) }

    /// Reasons a restart is worth it now; empty when it is not.
    var restartReasons: [String] {
        var out: [String] = []
        let days = Int(uptime / 86400)
        if uptime >= Config.restartUptimeDays * 86400 { out.append("up \(days) days") }
        if swapUsedBytes >= totalBytes { out.append("swap \(formatBytes(swapUsedBytes)) is more than the RAM") }
        if pressure == .critical { out.append("memory pressure critical") }
        // Long uptime on its own is not worth interrupting work for; pair it with strain.
        let strained = swapUsedBytes >= totalBytes / 2 || pressure != .normal
        return out.count >= 2 || (out.count == 1 && strained && uptime >= Config.restartUptimeDays * 86400) ? out : []
    }

    static func read() -> MacState {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let boot = sysctl(&mib, 2, &tv, &size, nil, 0) == 0
            ? Date(timeIntervalSince1970: TimeInterval(tv.tv_sec)) : Date()

        var level: Int32 = 1
        var lsize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsize, nil, 0)

        let mem = MemoryReader.system()
        return MacState(bootTime: boot, pressure: MemoryPressure(rawValue: Int(level)) ?? .normal,
                        swapUsedBytes: mem.swapUsedBytes, totalBytes: mem.totalBytes)
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let days = Int(t / 86400)
    let hours = Int(t.truncatingRemainder(dividingBy: 86400) / 3600)
    return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(Int(t.truncatingRemainder(dividingBy: 3600) / 60))m"
}
