import Foundation

/// Types into a session's Ghostty terminal, as if the user typed it. Only for the user's own words:
/// an agent's message must go through Claude Code's peer messaging so it arrives labelled as such.
enum GhosttyInput {
    enum Outcome { case typed, notFound, failed(String) }

    static func type(_ text: String, into s: Session) -> Outcome {
        let script = """
        tell application "Ghostty"
        \(findTerminal(s))
          if target is missing value then return "none"
          input text "\(appleScriptString(text))" to target
          send key "enter" to target
          return "typed"
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let e = error { return .failed((e[NSAppleScript.errorMessage] as? String) ?? "\(e)") }
        return result?.stringValue == "typed" ? .typed : .notFound
    }

    /// AppleScript, run inside `tell application "Ghostty"`, that sets `target` to the session's
    /// terminal, or to missing value. Titles are matched by substring, so `web` also matches
    /// `web-admin`: several title hits are narrowed by folder, and anything still ambiguous is
    /// left unmatched rather than guessed, since the caller may type into it.
    static func findTerminal(_ s: Session) -> String {
        let name = appleScriptString(s.name)
        let cwd = appleScriptString(s.cwd)
        return """
          set byName to {}
          set byFolder to {}
          repeat with w in windows
            repeat with t in tabs of w
              repeat with term in terminals of t
                if "\(name)" is not "" and name of term contains "\(name)" then set end of byName to term
                if working directory of term is "\(cwd)" then set end of byFolder to term
              end repeat
            end repeat
          end repeat
          set target to missing value
          if (count of byName) is 1 then
            set target to item 1 of byName
          else if (count of byName) > 1 then
            set both to {}
            repeat with term in byName
              if working directory of term is "\(cwd)" then set end of both to term
            end repeat
            if (count of both) is 1 then set target to item 1 of both
          else if (count of byFolder) is 1 then
            set target to item 1 of byFolder
          end if
        """
    }
}
