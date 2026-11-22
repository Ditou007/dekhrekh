import AppKit
import Darwin

/// The GUI app a session runs in, found by walking the claude process's parents.
struct TerminalHost {
    let app: NSRunningApplication
    /// The claude process's terminal, e.g. "/dev/ttys003".
    let tty: String?
    /// Set when the session runs inside tmux: "session:window.pane".
    let tmuxPane: String?

    var bundleId: String { app.bundleIdentifier ?? "" }
}

enum TerminalApps {
    static let ghostty = "com.mitchellh.ghostty"
    static let iterm = "com.googlecode.iterm2"
    static let appleTerminal = "com.apple.Terminal"

    static let folderEditors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "com.google.android.studio",
    ]
    private static let jetBrainsPrefix = "com.jetbrains."

    private static let tmuxName = "tmux"
    private static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    private static let maxDepth = 64
    private static let noDevice = dev_t(-1)

    static func isFolderEditor(_ bundleId: String) -> Bool {
        folderEditors.contains(bundleId) || bundleId.hasPrefix(jetBrainsPrefix)
    }

    /// Blocking (runs tmux); call off the main thread.
    static func host(of pid: pid_t) -> TerminalHost? {
        let tty = info(pid).flatMap(\.tty)
        let chain = ancestors(of: pid)
        guard chain.contains(where: { info($0)?.name == tmuxName }) else {
            return guiApp(in: chain).map { TerminalHost(app: $0, tty: tty, tmuxPane: nil) }
        }
        // The tmux server is daemonised (its parent is launchd), so the host is the GUI app
        // above an attached tmux client, not above claude.
        let pane = tty.flatMap(tmuxPane(forTTY:))
        let clientApp = pane
            .flatMap { tmuxClientPids(session: String($0.prefix { $0 != ":" })) }?
            .lazy.compactMap { guiApp(in: ancestors(of: $0)) }.first
        return clientApp.map { TerminalHost(app: $0, tty: tty, tmuxPane: pane) }
    }

    static func selectTmuxPane(_ pane: String) {
        _ = tmux(["select-window", "-t", pane])
        _ = tmux(["select-pane", "-t", pane])
    }

    private static func guiApp(in chain: [pid_t]) -> NSRunningApplication? {
        chain.lazy.compactMap { pid -> NSRunningApplication? in
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != nil, app.activationPolicy == .regular else { return nil }
            return app
        }.first
    }

    /// The process itself first, then each parent up to (not including) launchd.
    private static func ancestors(of pid: pid_t, depth: Int = maxDepth) -> [pid_t] {
        guard depth > 0, pid > 1, let parent = info(pid)?.ppid else { return [] }
        return [pid] + ancestors(of: parent, depth: depth - 1)
    }

    private struct ProcInfo {
        let ppid: pid_t
        let name: String
        let tty: String?
    }

    private static func info(_ pid: pid_t) -> ProcInfo? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let dev = kp.kp_eproc.e_tdev
        let tty = dev == noDevice ? nil : devname(dev, S_IFCHR).map { "/dev/" + String(cString: $0) }
        return ProcInfo(ppid: kp.kp_eproc.e_ppid, name: name, tty: tty)
    }

    private static func tmuxPane(forTTY tty: String) -> String? {
        tmux(["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"])?
            .split(separator: "\n")
            .first { $0.hasPrefix(tty + " ") }
            .map { String($0.dropFirst(tty.count + 1)) }
    }

    private static func tmuxClientPids(session: String) -> [pid_t]? {
        tmux(["list-clients", "-t", session, "-F", "#{client_pid}"])?
            .split(separator: "\n").compactMap { pid_t($0) }
    }

    private static func tmux(_ args: [String]) -> String? {
        guard let path = tmuxPaths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
