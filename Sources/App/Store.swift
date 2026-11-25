import AppKit
import Combine

enum Attention: Int, Comparable {
    case calm, warn, alert

    static func < (a: Attention, b: Attention) -> Bool { a.rawValue < b.rawValue }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var waitReasons: [String: WaitReason] = [:]
    @Published private(set) var claims: [String: String] = [:]
    /// Progress or result of a handoff started from the panel, per session.
    @Published private(set) var handoffStatus: [String: String] = [:]
    /// Session-id prefixes (8 chars) that have already handed off; they get no second button.
    @Published private(set) var handedOff: Set<String> = []
    /// Idle sessions whose last reply ended with a question for the user.
    @Published private(set) var questions: [String: String] = [:]
    private var knownAsking: Set<String> = []
    /// "<profile> <window> <threshold> <resets_at>" already chimed for; nil until the first read,
    /// so limits already past a threshold at launch do not chime.
    private var crossedLimits: Set<String>?
    private static let limitChimeAt: [Double] = [75, 90]
    @Published private(set) var subagents: [String: [RunningSubagent]] = [:]
    @Published private(set) var restartCheck = RestartCheck(busy: [], subagents: [])
    @Published private(set) var macState = MacState.read()
    @Published private(set) var restorable: SessionSnapshot?
    @Published private(set) var restoreError: String?
    private var notifyWatcher: DispatchSourceFileSystemObject?
    @Published private(set) var usage: [AccountUsage] = []
    @Published private(set) var ci: [RepoCI] = []
    @Published private(set) var now = Date()
    @Published private(set) var homelab: HomelabStatus?
    @Published private(set) var homelabError: String?
    @Published var homelabExpanded = UserDefaults.standard.bool(forKey: "homelabExpanded") {
        didSet { UserDefaults.standard.set(homelabExpanded, forKey: "homelabExpanded") }
    }
    @Published private(set) var memory: SystemMemory?
    @Published private(set) var dockerVMBytes: UInt64?
    /// Tallest the sections below the header may be on the current screen; they scroll past it.
    @Published var maxBodyHeight: CGFloat = .greatestFiniteMagnitude
    /// Measured height of the sections; kept here so a change triggers a window resize.
    @Published var bodyHeight: CGFloat = 300
    @Published private(set) var prs: [PullRequest] = []
    @Published private(set) var prErrors: [String] = []
    private(set) var usageSamples: [UsageHistory.Sample] = UsageHistory.read()
    @Published private(set) var topApps: [AppMemory] = []
    @Published var prsExpanded = UserDefaults.standard.object(forKey: "prsExpanded") as? Bool ?? true {
        didSet { UserDefaults.standard.set(prsExpanded, forKey: "prsExpanded") }
    }
    @Published var memoryExpanded = UserDefaults.standard.bool(forKey: "memoryExpanded") {
        didSet {
            UserDefaults.standard.set(memoryExpanded, forKey: "memoryExpanded")
            if memoryExpanded { refreshTopApps() } else { topApps = [] }
        }
    }
    @Published var compact: Bool {
        didSet { UserDefaults.standard.set(compact, forKey: "compact") }
    }
    /// Leaves the panel out of screenshots, recordings and screen sharing.
    @Published var hideFromCapture = UserDefaults.standard.object(forKey: "hideFromCapture") == nil
        || UserDefaults.standard.bool(forKey: "hideFromCapture") {
        didSet { UserDefaults.standard.set(hideFromCapture, forKey: "hideFromCapture") }
    }
    @Published var soundOn: Bool {
        didSet { UserDefaults.standard.set(soundOn, forKey: "soundOn") }
    }

    private let client = CIClient()
    private var timers: [Timer] = []
    private var knownWaiting: Set<String> = []
    private var knownFailures: Set<Int> = []
    private var ciPrimed = false

    init() {
        compact = UserDefaults.standard.bool(forKey: "compact")
        soundOn = UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true
    }

    func start() {
        watchNotifications()
        SessionSnapshots.rotateIfRebooted(bootTime: macState.bootTime)
        if memoryExpanded { refreshTopApps() }
        refreshLocal()
        refreshCI()
        refreshHomelab()
        refreshPRs()
        timers = [
            Timer.scheduledTimer(withTimeInterval: Config.prPollSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshPRs() }
            },
            Timer.scheduledTimer(withTimeInterval: Config.serverPollSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshHomelab() }
            },
            Timer.scheduledTimer(withTimeInterval: Config.sessionPollSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshLocal() }
            },
            Timer.scheduledTimer(withTimeInterval: Config.ciPollSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshCI() }
            },
        ]
    }

    func refreshLocal() {
        let statusline = SessionReader.readStatusline()
        let fresh = SessionReader.readSessions(statusline: statusline)
        let waiting = Set(fresh.filter { $0.status == .waiting }.map(\.id))
        if !waiting.subtracting(knownWaiting).isEmpty { chime("Glass") }
        knownWaiting = waiting

        sessions = fresh
        claims = fresh.reduce(into: [:]) { acc, s in acc[s.id] = Claims.read(for: s.id)?.note }
        handedOff = Handoff.handedOff()
        subagents = fresh.reduce(into: [:]) { acc, s in
            let a = Subagents.running(for: s, statusline: statusline)
            if !a.isEmpty { acc[s.id] = a }
        }
        restartCheck = RestartCheck(
            busy: fresh.filter { !$0.isBackground && ($0.status == .busy || $0.status == .shell) },
            subagents: fresh.compactMap { s in subagents[s.id].map { (s, $0) } }
        )
        questions = fresh.reduce(into: [:]) { acc, s in acc[s.id] = Questions.pending(for: s, statusline: statusline) }
        let asking = Set(questions.keys)
        if !asking.subtracting(knownAsking).isEmpty { chime("Glass") }
        knownAsking = asking
        waitReasons = fresh.filter { $0.status == .waiting }.reduce(into: [:]) { acc, s in
            acc[s.id] = WaitReasons.reason(for: s, statusline: statusline)
        }
        usage = SessionReader.readUsage(statusline: statusline)
        let crossed = Set(usage.flatMap { u in
            [("5h", u.fiveHour), ("7d", u.sevenDay)].flatMap { name, w -> [String] in
                guard let w else { return [] }
                return Self.limitChimeAt.filter { w.usedPercent >= $0 }
                    .map { "\(u.profile.name) \(name) \(Int($0)) \(Int(w.resetsAt.timeIntervalSince1970))" }
            }
        })
        if let before = crossedLimits, !crossed.subtracting(before).isEmpty { chime("Sosumi") }
        crossedLimits = (crossedLimits ?? []).union(crossed)
        usageSamples = UsageHistory.record(usage, existing: usageSamples)
        memory = MemoryReader.system()
        now = Date()
        if tick % Config.snapshotEveryTicks == 0 {
            macState = MacState.read()
            SessionSnapshots.save(fresh, statusline: statusline, bootTime: macState.bootTime,
                                  branch: TranscriptReader.gitBranch)
            restorable = SessionSnapshots.pendingRestore(live: fresh)
        }
        if tick % Config.processScanEveryTicks == 0 {
            dockerVMBytes = MemoryReader.appBytes(named: Config.dockerVMName)
        }
        tick += 1
        if memoryExpanded && tick % Config.topAppsEveryTicks == 0 { refreshTopApps() }
    }

    /// The Notification hook writes into this folder; refresh at once instead of on the next poll.
    private func watchNotifications() {
        let dir = WaitReasons.notifyDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshLocal() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        notifyWatcher = src
    }

    /// Reopens every session open before the last restart, each in its own Ghostty tab.
    func restoreSessions() {
        guard let snap = restorable else { return }
        let sessions = snap.sessions.filter { $0.background != true }
        DispatchQueue.global(qos: .userInitiated).async {
            let err = SessionSnapshots.reopen(sessions)
            DispatchQueue.main.async {
                self.restoreError = err
                if err == nil {
                    SessionSnapshots.markRestored()
                    self.restorable = nil
                }
            }
        }
    }

    func dismissRestore() {
        SessionSnapshots.markRestored()
        restorable = nil
    }

    func handoff(_ s: Session) {
        handoffStatus[s.id] = "Handing off: asking the session to write its handoff..."
        let statusline = SessionReader.readStatusline()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Handoff.run(s, statusline: statusline, force: false) { line in
                DispatchQueue.main.async { self.handoffStatus[s.id] = "Handing off: " + line }
            }
            DispatchQueue.main.async {
                switch result {
                case .success: self.handoffStatus[s.id] = "Handed off: the new session is open in Ghostty."
                case .failure(let why): self.handoffStatus[s.id] = "Handoff not done: \(why)"
                }
                // Clear the note after a while so the row returns to normal.
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) { self.handoffStatus[s.id] = nil }
            }
        }
    }

    func refreshPRs() {
        Task {
            let result = await client.fetchPRs()
            prs = result.prs
            prErrors = result.errors
        }
    }

    func limitETA(_ u: AccountUsage, window name: String, _ w: RateWindow?) -> Date? {
        guard let w, w.resetsAt > now else { return nil }
        return UsageHistory.limitETA(profile: u.profile, window: name, current: w, samples: usageSamples, now: now)
    }

    var swapHot: Bool { (memory?.swapUsedBytes ?? 0) >= Config.swapWarnBytes }
    var prsNeedingYou: Int { prs.filter { $0.state.needsYou }.count }

    private var tick = 0

    func refreshTopApps() {
        topApps = MemoryReader.topApps(limit: Config.topAppsLimit)
    }

    var memoryHot: Bool {
        guard let m = memory, m.totalBytes > 0 else { return false }
        return Double(m.usedBytes) / Double(m.totalBytes) * 100 >= Config.memoryWarnUsed
    }

    func refreshCI() {
        Task {
            let results = await client.fetchAll()
            let ids = Set(results.flatMap { $0.failures.filter { !$0.scheduled }.map(\.id) })
            if ciPrimed && !ids.subtracting(knownFailures).isEmpty { chime("Basso") }
            knownFailures = ids
            ciPrimed = true
            ci = results
        }
    }

    func refreshHomelab() {
        Task {
            switch await HomelabClient.fetch() {
            case nil: break
            case .success(let s):
                homelab = s
                homelabError = nil
            case .failure(let e):
                homelabError = e.localizedDescription
            }
        }
    }

    var homelabHot: Bool {
        guard Config.server != nil else { return false }
        guard let h = homelab else { return homelabError != nil }
        return h.memPct >= Config.memoryWarnUsed
            || h.loadPct >= 100
            || (h.tempC ?? 0) >= (Config.server?.tempBadC ?? 90)
            || !h.guestsDown.isEmpty
    }

    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    var askingCount: Int { questions.count }
    /// Failures that need someone now; a failed nightly waits for its next run and is only a notice.
    var failureCount: Int { ci.reduce(0) { $0 + $1.failures.filter { !$0.scheduled }.count } }
    var nightlyFailureCount: Int { ci.reduce(0) { $0 + $1.failures.filter(\.scheduled).count } }
    var lowContextCount: Int {
        // Only sessions the panel can act on: a background session gets no handoff button, and one
        // that already wrote its handoff has a continuation.
        sessions.filter {
            ($0.ctxRemaining ?? 100) <= Config.ctxCriticalRemaining && !$0.isBackground
                && !handedOff.contains(String($0.id.prefix(8)))
        }.count
    }

    var attention: Attention {
        if failureCount > 0 || waitingCount > 0 || askingCount > 0 { return .alert }
        let usageHot = usage.contains { u in
            [u.fiveHour, u.sevenDay].compactMap { $0 }.contains {
                $0.resetsAt > now && $0.usedPercent >= Config.usageWarnUsed
            }
        }
        let limitSoon = usage.contains { u in
            limitETA(u, window: "5h", u.fiveHour) != nil || limitETA(u, window: "7d", u.sevenDay) != nil
        }
        let warn = nightlyFailureCount > 0 || lowContextCount > 0 || usageHot || limitSoon || memoryHot || swapHot || homelabHot
        return warn ? .warn : .calm
    }

    private func chime(_ name: String) {
        guard soundOn else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
