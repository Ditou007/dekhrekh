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
    /// Progress or result of a handoff or move started from the panel, per session.
    @Published private(set) var handoffStatus: [String: String] = [:]
    /// Which operation last wrote each status note, so a stale clear-timer leaves a newer one alone.
    private var statusOwner: [String: UUID] = [:]
    private static let statusNoteSeconds: TimeInterval = 120
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
        refreshLocal(poll: true)
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
                Task { @MainActor in self?.refreshLocal(poll: true) }
            },
            Timer.scheduledTimer(withTimeInterval: Config.ciPollSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshCI() }
            },
        ]
    }

    private var localRefresh: Task<Void, Never>?
    /// A refresh asked for while one was running; it runs once that one is done.
    private var localRefreshQueued = false
    /// Counts timer polls (not watcher-triggered refreshes) to space out the slower checks.
    private var tick = 0
    /// Reads sessions, transcripts, usage and memory off the main thread, then publishes the result.
    /// `poll` is true for the timer's 2 s polls; refreshes triggered by the notify hook skip the slow checks.
    func refreshLocal(poll: Bool = false) {
        guard localRefresh == nil else { localRefreshQueued = true; return }
        let tick = poll ? self.tick : -1
        if poll { self.tick += 1 }
        let input = LocalScan.Input(
            tick: tick, samples: usageSamples, topApps: memoryExpanded
        )
        localRefresh = Task {
            let scan = await Task.detached(priority: .userInitiated) { LocalScan.run(input) }.value
            apply(scan)
            localRefresh = nil
            if localRefreshQueued {
                localRefreshQueued = false
                refreshLocal()
            }
        }
    }

    private func apply(_ scan: LocalScan) {
        let fresh = scan.sessions
        let waiting = Set(fresh.filter { $0.status == .waiting }.map(\.id))
        if !waiting.subtracting(knownWaiting).isEmpty { chime(.newWaiting) }
        knownWaiting = waiting

        sessions = fresh
        claims = scan.claims
        handedOff = scan.handedOff
        subagents = scan.subagents
        restartCheck = RestartCheck(sessions: fresh, subagents: scan.subagents)
        questions = scan.questions
        let asking = Set(questions.keys)
        if !asking.subtracting(knownAsking).isEmpty { chime(.newWaiting) }
        knownAsking = asking
        waitReasons = scan.waitReasons
        usage = scan.usage
        let crossed = Set(usage.flatMap { u in
            UsageWindow.allCases.flatMap { window -> [String] in
                guard let w = u[window] else { return [] }
                return Self.limitChimeAt.filter { w.usedPercent >= $0 }
                    .map { "\(u.profile.name) \(window.rawValue) \(Int($0)) \(Int(w.resetsAt.timeIntervalSince1970))" }
            }
        })
        if let before = crossedLimits, !crossed.subtracting(before).isEmpty { chime(.limitCrossed) }
        crossedLimits = (crossedLimits ?? []).union(crossed)
        usageSamples = scan.samples
        memory = scan.memory
        now = Date()
        if let m = scan.macState { macState = m }
        if let r = scan.restorable { restorable = r.value }
        if let d = scan.dockerVMBytes { dockerVMBytes = d.value }
        if let apps = scan.topApps, memoryExpanded { topApps = apps }
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
        let op = beginStatus(s, "Handing off: asking the session to write its handoff...")
        let statusline = SessionReader.readStatusline()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Handoff.run(s, statusline: statusline, force: false) { line in
                DispatchQueue.main.async { self.setStatus(s, op, "Handing off: " + line) }
            }
            DispatchQueue.main.async {
                switch result {
                case .success: self.finishStatus(s, op, "Handed off: the new session is open in Ghostty.")
                case .failure(let why): self.finishStatus(s, op, "Handoff not done: \(why)")
                }
            }
        }
    }

    /// The account this session can continue on, when its own is near a limit.
    func moveTarget(_ s: Session) -> Profile? { Move.offer(for: s, usage: usage) }

    func move(_ s: Session, to target: Profile) {
        let op = beginStatus(s, "Moving to \(target.title)...")
        let statusline = SessionReader.readStatusline()
        let usage = self.usage
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Move.run(s, to: target, statusline: statusline, usage: usage, force: false) { line in
                DispatchQueue.main.async { self.setStatus(s, op, "Moving: " + line) }
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let p): self.finishStatus(s, op, "Continues on \(p.title) in a new Ghostty tab.")
                case .failure(let why): self.finishStatus(s, op, "Not moved: \(why)")
                }
            }
        }
    }

    private func beginStatus(_ s: Session, _ note: String) -> UUID {
        let op = UUID()
        statusOwner[s.id] = op
        handoffStatus[s.id] = note
        return op
    }

    private func setStatus(_ s: Session, _ op: UUID, _ note: String) {
        guard statusOwner[s.id] == op else { return }
        handoffStatus[s.id] = note
    }

    /// Shows the result, then clears it after a while so the row returns to normal, unless another
    /// operation on the same session has started since.
    private func finishStatus(_ s: Session, _ op: UUID, _ note: String) {
        setStatus(s, op, note)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.statusNoteSeconds) {
            guard self.statusOwner[s.id] == op else { return }
            self.handoffStatus[s.id] = nil
            self.statusOwner[s.id] = nil
        }
    }

    private var prFetch: Task<Void, Never>?
    private var ciFetch: Task<Void, Never>?

    /// Skipped while a fetch is still running, so a slow network cannot stack polls or let an
    /// older result land after a newer one.
    func refreshPRs() {
        guard prFetch == nil else { return }
        prFetch = Task {
            let result = await client.fetchPRs()
            prs = result.prs
            prErrors = result.errors
            prFetch = nil
        }
    }

    func limitETA(_ u: AccountUsage, _ window: UsageWindow) -> Date? {
        guard let w = u[window], w.resetsAt > now else { return nil }
        return UsageHistory.limitETA(profile: u.profile, window: window, current: w, samples: usageSamples, now: now)
    }

    var swapHot: Bool { (memory?.swapUsedBytes ?? 0) >= Config.swapWarnBytes }
    var prsNeedingYou: Int { prs.filter { $0.state.needsYou }.count }

    func refreshTopApps() {
        Task {
            let apps = await Task.detached(priority: .userInitiated) { MemoryReader.topApps(limit: Config.topAppsLimit) }.value
            if memoryExpanded { topApps = apps }
        }
    }

    var memoryHot: Bool {
        guard let m = memory, m.totalBytes > 0 else { return false }
        return Double(m.usedBytes) / Double(m.totalBytes) * 100 >= Config.memoryWarnUsed
    }

    func refreshCI() {
        guard ciFetch == nil else { return }
        ciFetch = Task {
            defer { ciFetch = nil }
            let results = await client.fetchAll()
            let ids = Set(results.flatMap { $0.failures.filter { !$0.scheduled }.map(\.id) })
            if ciPrimed && !ids.subtracting(knownFailures).isEmpty { chime(.ciFailed) }
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
            UsageWindow.allCases.compactMap { u[$0] }.contains {
                $0.resetsAt > now && $0.usedPercent >= Config.usageWarnUsed
            }
        }
        let limitSoon = usage.contains { u in
            UsageWindow.allCases.contains { limitETA(u, $0) != nil }
        }
        let warn = nightlyFailureCount > 0 || lowContextCount > 0 || usageHot || limitSoon || memoryHot || swapHot || homelabHot
        return warn ? .warn : .calm
    }

    enum Chime: String {
        case newWaiting = "Glass"
        case limitCrossed = "Sosumi"
        case ciFailed = "Basso"
    }

    private func chime(_ c: Chime) {
        guard soundOn else { return }
        NSSound(named: NSSound.Name(c.rawValue))?.play()
    }
}
