import Foundation

/// `dekhrekh ci --wait [branch] [--repo=<label>] [--timeout=<minutes>] [--log-lines=<n>]`
/// Exit 0 when every run on the branch's newest commit passed, 1 on a failure, 3 on timeout.
func runWait(args: [String]) -> Never {
    func option(_ name: String) -> String? {
        args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
    }
    let cwd = FileManager.default.currentDirectoryPath
    let repo = option("repo").flatMap { label in Config.repos.first { $0.label == label } } ?? repoForFolder(cwd)
    guard let repo else {
        let labels = Config.repos.map(\.label).joined(separator: ", ")
        FileHandle.standardError.write("dekhrekh ci --wait: not in a watched repo; pass --repo=<\(labels)>\n".data(using: .utf8)!)
        exit(2)
    }
    let branchArg = args.first { !$0.hasPrefix("-") && $0 != "ci" }
    guard let branch = branchArg ?? Git.branch(at: cwd) else {
        FileHandle.standardError.write("dekhrekh ci --wait: no branch given and none checked out here\n".data(using: .utf8)!)
        exit(2)
    }
    let minutes = option("timeout").flatMap(Double.init) ?? 30
    let logLines = option("log-lines").flatMap(Int.init) ?? 40

    let sem = DispatchSemaphore(value: 0)
    var result: Result<WaitResult, Error>!
    Task {
        do {
            let r = try await CIClient().waitForBranch(repo: repo, branch: branch, timeout: minutes * 60,
                                                       logLines: logLines) { line in
                print("… \(line)")
                fflush(stdout)
            }
            result = .success(r)
        } catch {
            result = .failure(error)
        }
        sem.signal()
    }
    sem.wait()

    Frame.open()
    switch result! {
    case .failure(let e):
        print("dekhrekh ci --wait: \(e.localizedDescription)")
        Frame.close()
        exit(2)
    case .success(let r):
        if r.timedOut {
            print("TIMED OUT after \(Int(minutes)) min: \(r.repo) \(r.branch) @\(r.sha) still running")
            Frame.close()
            exit(3)
        }
        print("\(r.passed ? "PASSED" : "FAILED"): \(r.repo) \(r.branch) @\(r.sha)")
        for run in r.runs { print("  \(run.conclusion.padding(toLength: 10, withPad: " ", startingAt: 0)) \(run.name)  \(run.url)") }
        for f in r.failures {
            print("\nFailed job: \(f.name)\(f.step.map { " (step: \($0))" } ?? "")\n  \(f.url)")
            if !f.logTail.isEmpty {
                print("  last \(f.logTail.count) log lines:")
                f.logTail.forEach { print("  | \($0)") }
            }
        }
        Frame.close()
        exit(r.passed ? 0 : 1)
    }
}
