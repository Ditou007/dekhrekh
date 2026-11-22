import Foundation

struct HomelabGuest: Identifiable {
    let id: Int
    let name: String
    let kind: String
    let running: Bool
    let memGB: Double
    let maxMemGB: Double
    let hostCpuPct: Double
}

struct HomelabStatus {
    let memUsedGB: Double
    let memTotalGB: Double
    let arcGB: Double?
    let load1: Double
    let cores: Int
    let tempC: Double?
    let diskPct: Double
    let uptimeH: Double
    let guestsDown: [String]
    let guests: [HomelabGuest]
    let fetchedAt: Date

    var memPct: Double { memTotalGB > 0 ? memUsedGB / memTotalGB * 100 : 0 }
    /// Load average as a share of all cores; above 100 means work is queueing for CPU.
    var loadPct: Double { Double(load1) / Double(max(cores, 1)) * 100 }
}

enum HomelabClient {
    static func fetch() async -> Result<HomelabStatus, Error>? {
        guard let server = Config.server else { return nil }
        var req = URLRequest(url: server.url)
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw CIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
            return .success(parse(obj, server))
        } catch {
            return .failure(error)
        }
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func parse(_ obj: [String: Any], _ server: ServerCard) -> HomelabStatus {
        let node = obj["node"] as? [String: Any] ?? [:]
        let containers = obj["containers"] as? [String: Any] ?? [:]
        let guests = (obj["guests"] as? [[String: Any]] ?? []).compactMap { g -> HomelabGuest? in
            guard let id = num(g["id"]) else { return nil }
            return HomelabGuest(
                id: Int(id),
                name: g["name"] as? String ?? "\(Int(id))",
                kind: g["type"] as? String ?? "",
                running: g["status"] as? String == "running",
                memGB: num(g["mem_gb"]) ?? 0,
                maxMemGB: num(g["maxmem_gb"]) ?? 0,
                hostCpuPct: num(g["host_cpu_pct"]) ?? 0
            )
        }
        return HomelabStatus(
            memUsedGB: num(node["mem_used_gb"]) ?? 0,
            memTotalGB: num(node["mem_total_gb"]) ?? 0,
            arcGB: num(obj["arc_gb"]),
            load1: num(node["load1"]) ?? 0,
            cores: Int(num(obj["cores"]) ?? Double(server.coresFallback)),
            tempC: num(obj["temp_c"]),
            diskPct: num(node["disk_pct"]) ?? 0,
            uptimeH: num(node["uptime_h"]) ?? 0,
            guestsDown: (containers["down"] as? [String] ?? []).filter { !server.parked.contains($0) },
            guests: guests,
            fetchedAt: Date()
        )
    }
}
