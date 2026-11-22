import Foundation

/// Types into a session's Ghostty terminal, as if the user typed it. Only for the user's own words:
/// an agent's message must go through Claude Code's peer messaging so it arrives labelled as such.
enum GhosttyInput {
    enum Outcome { case typed, notFound, failed(String) }

    static func type(_ text: String, into s: Session) -> Outcome {
        let script = """
        tell application "Ghostty"
          set target to missing value
          repeat with w in windows
            repeat with t in tabs of w
              repeat with term in terminals of t
                if target is missing value and name of term contains "\(escape(s.name))" then set target to term
              end repeat
            end repeat
          end repeat
          if target is missing value then
            set hits to {}
            repeat with w in windows
              repeat with t in tabs of w
                repeat with term in terminals of t
                  if working directory of term is "\(escape(s.cwd))" then set end of hits to term
                end repeat
              end repeat
            end repeat
            if (count of hits) is 1 then set target to item 1 of hits
          end if
          if target is missing value then return "none"
          input text "\(escape(text))" to target
          send key "enter" to target
          return "typed"
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let e = error { return .failed((e[NSAppleScript.errorMessage] as? String) ?? "\(e)") }
        return result?.stringValue == "typed" ? .typed : .notFound
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
