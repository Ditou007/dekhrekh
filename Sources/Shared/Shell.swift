import Foundation

/// Runs a command and collects its stdout. Every subprocess in the app and CLI goes through here.
enum Shell {
    struct Output {
        let status: Int32
        let stdout: Data

        var ok: Bool { status == 0 }
        var text: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static let defaultTimeout: TimeInterval = 10

    /// Nil when the program cannot be started or outlives `timeout` (it is then terminated).
    /// Stdout is drained while the child runs, so large output cannot fill the pipe and stall it;
    /// stderr is discarded for the same reason.
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = defaultTimeout,
                    cwd: URL? = nil, environment: [String: String]? = nil) -> Output? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        if let environment { proc.environment = environment }
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        guard (try? proc.run()) != nil else { return nil }

        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            proc.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return nil
        }
        drained.wait()
        return Output(status: proc.terminationStatus, stdout: data)
    }

    /// The first executable called `name` on `PATH`, then in the usual install folders, since an app
    /// launched from Finder or at login gets a minimal `PATH`.
    static func which(_ name: String, extraDirs: [String] = []) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let common = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin",
                      Config.home.appendingPathComponent(".local/bin").path]
        return (extraDirs + pathDirs + common)
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Single-quotes `s` for a POSIX shell.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

enum Git {
    private static let git = "/usr/bin/git"
    private static let timeout: TimeInterval = 3

    /// The checked-out branch at `cwd`; nil outside a repo, on a detached HEAD, or when git is slow
    /// (a folder on a network mount, say).
    static func branch(at cwd: String) -> String? {
        guard !cwd.isEmpty,
              let r = Shell.run(git, ["--no-optional-locks", "-C", cwd, "branch", "--show-current"], timeout: timeout),
              r.ok, !r.text.isEmpty
        else { return nil }
        return r.text
    }

    /// `git remote -v` at `cwd`, lowercased.
    static func remotes(at cwd: String) -> String? {
        guard let r = Shell.run(git, ["--no-optional-locks", "-C", cwd, "remote", "-v"], timeout: timeout), r.ok
        else { return nil }
        return r.text.lowercased()
    }
}

/// Escapes a string for use inside an AppleScript string literal.
func appleScriptString(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}
