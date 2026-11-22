import AppKit

/// Brings a session's own window or tab to the front in whichever app hosts it.
/// Ghostty titles each terminal with the session name (behind a status glyph), so the name is
/// tried first; the working directory is the fallback when exactly one terminal sits there.
/// iTerm2 and Terminal.app are matched by the claude process's tty; editors get the window for
/// the session's folder; anything else is just activated.
enum TerminalFocus {
    private static let queue = DispatchQueue(label: "dekhrekh.terminal-focus")
    private static let noMatch = "none"

    static func focus(_ s: Session) {
        // Process lookups, tmux and AppleScript all block; keep them off the main thread.
        queue.async {
            guard let host = TerminalApps.host(of: s.pid) else {
                if !focusGhostty(s) { DispatchQueue.main.async { activateTerminalApp() } }
                return
            }
            if let pane = host.tmuxPane { TerminalApps.selectTmuxPane(pane) }
            let focused: Bool
            switch host.bundleId {
            case TerminalApps.ghostty: focused = focusGhostty(s)
            case TerminalApps.iterm: focused = host.tty.map(focusITerm) ?? false
            case TerminalApps.appleTerminal: focused = host.tty.map(focusAppleTerminal) ?? false
            case let id where TerminalApps.isFolderEditor(id):
                DispatchQueue.main.async { openFolder(s.cwd, in: host.app) }
                focused = true
            default: focused = false
            }
            if !focused { DispatchQueue.main.async { host.app.activate() } }
        }
    }

    static func activateTerminalApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Config.terminalBundleId).first?.activate()
    }

    private static func focusGhostty(_ s: Session) -> Bool {
        let name = escape(s.name)
        let cwd = escape(s.cwd)
        return run("""
        tell application "Ghostty"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with term in terminals of t
                if name of term contains "\(name)" then
                  focus term
                  return "name"
                end if
              end repeat
            end repeat
          end repeat
          set hits to {}
          repeat with w in windows
            repeat with t in tabs of w
              repeat with term in terminals of t
                if working directory of term is "\(cwd)" then set end of hits to term
              end repeat
            end repeat
          end repeat
          if (count of hits) is 1 then
            focus (item 1 of hits)
            return "folder"
          end if
          return "\(noMatch)"
        end tell
        """)
    }

    private static func focusITerm(tty: String) -> Bool {
        run("""
        tell application id "\(TerminalApps.iterm)"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(escape(tty))" then
                  select w
                  select t
                  select s
                  activate
                  return "tty"
                end if
              end repeat
            end repeat
          end repeat
          return "\(noMatch)"
        end tell
        """)
    }

    private static func focusAppleTerminal(tty: String) -> Bool {
        run("""
        tell application id "\(TerminalApps.appleTerminal)"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(escape(tty))" then
                set selected of t to true
                set index of w to 1
                set frontmost of w to true
                activate
                return "tty"
              end if
            end repeat
          end repeat
          return "\(noMatch)"
        end tell
        """)
    }

    /// Opening a folder that is already open focuses its existing window in VS Code, Cursor and Zed.
    private static func openFolder(_ path: String, in app: NSRunningApplication) {
        guard let appURL = app.bundleURL else {
            app.activate()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: config) { _, error in
            if error != nil { DispatchQueue.main.async { app.activate() } }
        }
    }

    private static func run(_ script: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil && result?.stringValue != noMatch
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
