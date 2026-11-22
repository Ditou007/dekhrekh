import Darwin
import Foundation

struct SystemMemory {
    let usedBytes: UInt64
    let totalBytes: UInt64
    let swapUsedBytes: UInt64
}

struct AppMemory: Identifiable {
    var id: String { name }
    let name: String
    let bytes: UInt64
    let processCount: Int
}

enum MemoryReader {
    static func system() -> SystemMemory {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        // Same basis as Activity Monitor's "Memory Used": app (internal - purgeable) + wired + compressed.
        let used = kr == KERN_SUCCESS
            ? (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
               + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
            : 0

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0

        return SystemMemory(usedBytes: used, totalBytes: ProcessInfo.processInfo.physicalMemory, swapUsedBytes: swapUsed)
    }

    /// Physical footprint per app, helpers folded into their parent .app bundle.
    /// Processes owned by other users (root daemons) cannot be read and are left out.
    static func topApps(limit: Int) -> [AppMemory] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard n > 0 else { return [] }

        let totals = pids.prefix(n).reduce(into: [String: (bytes: UInt64, count: Int)]()) { acc, pid in
            guard pid > 0, let bytes = footprint(pid), let name = appName(pid) else { return }
            let prev = acc[name] ?? (0, 0)
            acc[name] = (prev.bytes + bytes, prev.count + 1)
        }
        return totals
            .map { AppMemory(name: $0.key, bytes: $0.value.bytes, processCount: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { $0 }
    }

    /// Total footprint of processes grouped under `name` (same grouping as topApps), nil when none run.
    static func appBytes(named name: String) -> UInt64? {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        let hits = pids.prefix(max(n, 0)).filter { $0 > 0 && appName($0) == name }
        guard !hits.isEmpty else { return nil }
        return hits.compactMap(footprint).reduce(0, +)
    }

    /// Every JVM is "java"; its arguments say what it is (a build daemon, an editor plugin).
    private static func javaRole(_ pid: pid_t) -> String? {
        guard let args = arguments(pid) else { return nil }
        return Config.javaRoles.first { args.contains($0.key) }?.value
    }

    /// The process's argv joined by spaces, from KERN_PROCARGS2 (own-user processes only).
    private static func arguments(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (Int32), exec path, NUL padding, then argc NUL-terminated arguments.
        return String(decoding: buf.prefix(size).dropFirst(4).map { $0 == 0 ? 32 : $0 }, as: UTF8.self)
    }

    private static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        return ok ? info.ri_phys_footprint : nil
    }

    private static func appName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        if let alias = Config.processAliases.first(where: { path.contains($0.key) }) {
            return alias.value
        }
        if (path as NSString).lastPathComponent == "java", let role = javaRole(pid) {
            return role
        }
        let bundle = path.split(separator: "/").first { $0.hasSuffix(".app") }
        let name = bundle.map { String($0.dropLast(4)) } ?? (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

func formatBytes(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824
    return gb >= 1 ? String(format: "%.1fG", gb) : String(format: "%.0fM", Double(b) / 1_048_576)
}
