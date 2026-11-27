import Foundation

func runStats(limit: Int, json: Bool) async -> Never {
    let result = await CIClient().stats(runs: limit)

    if json {
        let out = result.map { r -> [String: Any] in
            [
                "repo": r.label, "runs": r.runs,
                "wall_median_min": r.wallMedian.map { $0 as Any } ?? NSNull(),
                "wall_max_min": r.wallMax.map { $0 as Any } ?? NSNull(),
                "error": r.error.map { $0 as Any } ?? NSNull(),
                "jobs": r.jobs.map {
                    ["name": $0.name, "count": $0.count, "wait_median_min": $0.waitMedian,
                     "wait_max_min": $0.waitMax, "run_median_min": $0.runMedian, "run_max_min": $0.runMax]
                },
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: Frame.wrap(out), options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit(0)
    }

    let f = { (v: Double) in String(format: "%5.1fm", v) }
    Frame.open()
    for r in result {
        if let e = r.error {
            print("\(r.label): \(e)")
            continue
        }
        let wall = r.wallMedian.map { "push to done median \(f($0).trimmingCharacters(in: .whitespaces)), worst \(f(r.wallMax ?? 0).trimmingCharacters(in: .whitespaces))" } ?? "no data"
        print("\(r.label): last \(r.runs) completed runs, \(wall)")
        print("  job           n   wait med   wait max    run med    run max")
        for j in r.jobs {
            print("  \(j.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(String(format: "%2d", j.count))    \(f(j.waitMedian))     \(f(j.waitMax))     \(f(j.runMedian))     \(f(j.runMax))")
        }
        print("")
    }
    Frame.close()
    exit(0)
}
