import Foundation

/// One read of everything local the panel shows: sessions, transcripts, usage, memory. It spawns
/// processes and reads multi-MB transcripts, so `Store` runs it off the main thread.
struct LocalScan {
    struct Input {
        /// Timer poll number, or -1 for a refresh triggered by the notify hook, which skips the
        /// checks that only need to run every few polls.
        let tick: Int
        let samples: [UsageHistory.Sample]
        let topApps: Bool

        func every(_ n: Int) -> Bool { tick >= 0 && tick % n == 0 }
    }

    /// A value that is only read on some polls; nil means "not read this time, keep the old one".
    struct Reading<T> { let value: T }

    let sessions: [Session]
    let claims: [String: String]
    let handedOff: Set<String>
    let subagents: [String: [RunningSubagent]]
    let questions: [String: String]
    let waitReasons: [String: WaitReason]
    let usage: [AccountUsage]
    let samples: [UsageHistory.Sample]
    let memory: SystemMemory
    let macState: MacState?
    let restorable: Reading<SessionSnapshot?>?
    let dockerVMBytes: Reading<UInt64?>?
    let topApps: [AppMemory]?

    static func run(_ input: Input) -> LocalScan {
        let statusline = SessionReader.readStatusline()
        let sessions = SessionReader.readSessions(statusline: statusline)
        let usage = SessionReader.readUsage(statusline: statusline)

        var macState: MacState?
        var restorable: Reading<SessionSnapshot?>?
        if input.every(Config.snapshotEveryTicks) {
            let state = MacState.read()
            SessionSnapshots.save(sessions, statusline: statusline, bootTime: state.bootTime,
                                  branch: { Git.branch(at: $0) })
            macState = state
            restorable = Reading(value: SessionSnapshots.pendingRestore(live: sessions))
        }

        return LocalScan(
            sessions: sessions,
            claims: sessions.reduce(into: [:]) { acc, s in acc[s.id] = Claims.read(for: s.id)?.note },
            handedOff: Handoff.handedOff(),
            subagents: sessions.reduce(into: [:]) { acc, s in
                let a = Subagents.running(for: s, statusline: statusline)
                if !a.isEmpty { acc[s.id] = a }
            },
            questions: sessions.reduce(into: [:]) { acc, s in
                acc[s.id] = Questions.pending(for: s, statusline: statusline)
            },
            waitReasons: sessions.filter { $0.status == .waiting }.reduce(into: [:]) { acc, s in
                acc[s.id] = WaitReasons.reason(for: s, statusline: statusline)
            },
            usage: usage,
            samples: UsageHistory.record(usage, existing: input.samples),
            memory: MemoryReader.system(),
            macState: macState,
            restorable: restorable,
            dockerVMBytes: input.every(Config.processScanEveryTicks)
                ? Reading(value: MemoryReader.appBytes(named: Config.dockerVMName)) : nil,
            topApps: input.topApps && input.every(Config.topAppsEveryTicks)
                ? MemoryReader.topApps(limit: Config.topAppsLimit) : nil
        )
    }
}
