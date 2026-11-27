/// Percentages at which panel meters turn amber or a verdict changes. The red lines for usage and
/// memory are `Config.usageWarnUsed` and `Config.memoryWarnUsed`, which also drive the alerts.
enum PanelThresholds {
    /// Share of a usage window used at which its bar turns amber.
    static let usageCaution = 60.0
    /// Share of memory used at which a memory bar turns amber, on the Mac and on the server.
    static let memoryCaution = 70.0
    /// Server load, as a share of its cores, at which the CPU bar turns amber and the server reads busy.
    static let loadCaution = 60.0
    /// Server load at which every core is busy: the CPU bar turns red and the server reads overloaded.
    static let loadMax = 100.0
    /// Server load under which, with memory also under `idleMemory`, the server reads underused.
    static let idleLoad = 10.0
    /// Server memory use under which, with load also under `idleLoad`, the server reads underused.
    static let idleMemory = 50.0
    /// Share of host CPU one guest uses before its figure turns amber.
    static let guestCPUCaution = 25.0
}
