import Foundation

public class TelemetryQueryEngine {
    public static let shared = TelemetryQueryEngine()
    
    private var cachedRuns: [String: (mtime: Date, run: TaskRun)] = [:]
    private var runsDirURL: URL
    private var lastFileURL: URL
    
    public init(customRoot: URL? = nil) {
        if let root = customRoot {
            self.runsDirURL = root.appendingPathComponent("runs")
            self.lastFileURL = root.appendingPathComponent("last.json")
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
            let telemetryRoot = URL(fileURLWithPath: codexHome)
                .appendingPathComponent("codex-flow")
                .appendingPathComponent("telemetry")
            self.runsDirURL = telemetryRoot.appendingPathComponent("runs")
            self.lastFileURL = telemetryRoot.appendingPathComponent("last.json")
        }
    }
    
    // MARK: - Core File Reading & Cache
    
    public func loadAllRuns() -> [TaskRun] {
        guard FileManager.default.fileExists(atPath: runsDirURL.path) else {
            return []
        }
        
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: runsDirURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        var result: [TaskRun] = []
        
        for fileURL in jsonFiles {
            let stem = fileURL.deletingPathExtension().lastPathComponent
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            
            if let cached = cachedRuns[stem], cached.mtime == mtime {
                result.append(cached.run)
                continue
            }
            
            guard let data = try? Data(contentsOf: fileURL),
                  var run = try? JSONDecoder().decode(TaskRun.self, from: data) else {
                continue
            }
            
            run.fileStem = stem
            cachedRuns[stem] = (mtime, run)
            result.append(run)
        }
        
        // Sort descending by finished time or started time
        result.sort { r1, r2 in
            let t1 = r1.finishedAtMs ?? r1.startedAtMs ?? 0
            let t2 = r2.finishedAtMs ?? r2.startedAtMs ?? 0
            return t1 > t2
        }
        
        return result
    }
    
    public func loadLatestRun() -> TaskRun? {
        if FileManager.default.fileExists(atPath: lastFileURL.path),
           let data = try? Data(contentsOf: lastFileURL),
           let run = try? JSONDecoder().decode(TaskRun.self, from: data) {
            return run
        }
        let runs = loadAllRuns()
        return runs.first
    }
    
    // MARK: - Query & Filter History
    
    public func fetchHistory(
        limit: Int = 100,
        project: String? = nil,
        todayOnly: Bool = false,
        search: String? = nil
    ) -> [TaskRun] {
        var runs = loadAllRuns()
        
        if todayOnly {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date()).timeIntervalSince1970 * 1000
            runs = runs.filter { run in
                let ts = run.finishedAtMs ?? run.startedAtMs ?? 0
                return ts >= startOfToday
            }
        }
        
        if let proj = project, !proj.isEmpty, proj.lowercased() != "all" {
            let pNorm = proj.lowercased()
            runs = runs.filter { run in
                let runProj = run.projectName.lowercased()
                let cwd = (run.cwd ?? "").lowercased()
                return runProj.contains(pNorm) || cwd.contains(pNorm)
            }
        }
        
        if let query = search?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            let qNorm = query.lowercased()
            runs = runs.filter { run in
                let title = run.sessionTitle.lowercased()
                let proj = run.projectName.lowercased()
                let branch = (run.gitBranch ?? "").lowercased()
                let summary = (run.summary ?? "").lowercased()
                let sess = (run.sessionId ?? "").lowercased()
                let turn = (run.turnId ?? "").lowercased()
                return title.contains(qNorm) || proj.contains(qNorm) || branch.contains(qNorm) || summary.contains(qNorm) || sess.contains(qNorm) || turn.contains(qNorm)
            }
        }
        
        if limit > 0 && runs.count > limit {
            return Array(runs.prefix(limit))
        }
        return runs
    }
    
    public func fetchRun(identifier: String) -> TaskRun? {
        let t = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.lowercased() == "last" {
            return loadLatestRun()
        }
        
        let runs = loadAllRuns()
        
        // Match #1, #2, etc.
        let numStr = t.hasPrefix("#") ? String(t.dropFirst()) : t
        if let idx = Int(numStr), idx >= 1 && idx <= runs.count {
            return runs[idx - 1]
        }
        
        // Match session ID, turn ID or file stem
        let tLower = t.lowercased()
        for run in runs {
            if let stem = run.fileStem?.lowercased(), stem.contains(tLower) {
                return run
            }
            if let sess = run.sessionId?.lowercased(), sess.contains(tLower) {
                return run
            }
            if let turn = run.turnId?.lowercased(), turn.contains(tLower) {
                return run
            }
        }
        
        return nil
    }
    
    // MARK: - Projects List
    
    public func allProjects() -> [String] {
        let runs = loadAllRuns()
        var set = Set<String>()
        for r in runs {
            set.insert(r.projectName)
        }
        return Array(set).sorted()
    }
    
    // MARK: - Stats Aggregation
    
    public func computeStats(days: Int = 30, project: String? = nil) -> TelemetryStats {
        let runs = loadAllRuns()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 * 1000
        
        var totalRuns = 0
        var delegatedRuns = 0
        var directRuns = 0
        var totalDurationMs: Double = 0
        
        var totalTokens = 0
        var parentTokens = 0
        var workerTokens = 0
        
        var cachedInputTokens = 0
        var inputTokens = 0
        var outputTokens = 0
        var reasoningOutputTokens = 0
        
        var totalCreditsMicros: Double = 0
        var hasCredits = false
        
        var modelsDict: [String: (calls: Int, tokens: Int, roles: Set<String>)] = [:]
        var projectsDict: [String: (runs: Int, delegated: Int, tokens: Int, durationMs: Double)] = [:]
        
        let pFilter = (project != nil && !project!.isEmpty && project!.lowercased() != "all") ? project!.lowercased() : nil
        
        for run in runs {
            let ts = run.finishedAtMs ?? run.startedAtMs ?? 0
            if ts < cutoff {
                continue
            }
            
            let projName = run.projectName
            let cwd = run.cwd ?? ""
            if let pf = pFilter {
                if !projName.lowercased().contains(pf) && !cwd.lowercased().contains(pf) {
                    continue
                }
            }
            
            totalRuns += 1
            let workers = run.allWorkers
            if !workers.isEmpty {
                delegatedRuns += 1
            } else {
                directRuns += 1
            }
            
            let dur = run.durationSeconds * 1000.0
            totalDurationMs += dur
            
            // Parent usage
            let parent = run.parent
            let pModel = parent?.displayModel ?? "unknown"
            let pUsage = parent?.effectiveUsage
            
            let pTot = pUsage?.totalTokens ?? ((pUsage?.effectivePromptTokens ?? 0) + (pUsage?.effectiveOutputTokens ?? 0))
            let pIn = pUsage?.effectivePromptTokens ?? 0
            let pCin = pUsage?.effectiveCachedTokens ?? 0
            let pOut = pUsage?.effectiveOutputTokens ?? 0
            let pRout = pUsage?.effectiveReasoningTokens ?? 0
            let pCred = pUsage?.estimatedCreditsMicros
            
            parentTokens += pTot
            cachedInputTokens += pCin
            inputTokens += pIn
            outputTokens += pOut
            reasoningOutputTokens += pRout
            if let c = pCred, c > 0 {
                totalCreditsMicros += c
                hasCredits = true
            }
            
            if modelsDict[pModel] == nil {
                modelsDict[pModel] = (0, 0, [])
            }
            modelsDict[pModel]!.calls += 1
            modelsDict[pModel]!.tokens += pTot
            modelsDict[pModel]!.roles.insert("parent")
            
            // Worker usage
            var wTotSum = 0
            for w in workers {
                let wModel = w.displayModel
                let wUsage = w.effectiveUsage
                let wTot = wUsage?.totalTokens ?? ((wUsage?.effectivePromptTokens ?? 0) + (wUsage?.effectiveOutputTokens ?? 0))
                let wIn = wUsage?.effectivePromptTokens ?? 0
                let wCin = wUsage?.effectiveCachedTokens ?? 0
                let wOut = wUsage?.effectiveOutputTokens ?? 0
                let wRout = wUsage?.effectiveReasoningTokens ?? 0
                let wCred = wUsage?.estimatedCreditsMicros
                
                workerTokens += wTot
                wTotSum += wTot
                cachedInputTokens += wCin
                inputTokens += wIn
                outputTokens += wOut
                reasoningOutputTokens += wRout
                if let c = wCred, c > 0 {
                    totalCreditsMicros += c
                    hasCredits = true
                }
                
                if modelsDict[wModel] == nil {
                    modelsDict[wModel] = (0, 0, [])
                }
                modelsDict[wModel]!.calls += 1
                modelsDict[wModel]!.tokens += wTot
                modelsDict[wModel]!.roles.insert("worker")
            }
            
            let runTot = pTot + wTotSum
            totalTokens += runTot
            
            if projectsDict[projName] == nil {
                projectsDict[projName] = (0, 0, 0, 0)
            }
            projectsDict[projName]!.runs += 1
            if !workers.isEmpty {
                projectsDict[projName]!.delegated += 1
            }
            projectsDict[projName]!.tokens += runTot
            projectsDict[projName]!.durationMs += dur
        }
        
        let cacheRatio = inputTokens > 0 ? (Double(cachedInputTokens) / Double(inputTokens) * 100.0) : 0.0
        let workerOffload = totalTokens > 0 ? (Double(workerTokens) / Double(totalTokens) * 100.0) : 0.0
        
        let sortedModels = modelsDict.map { k, v in
            ModelStats(name: k, calls: v.calls, tokens: v.tokens, roles: Array(v.roles).sorted())
        }.sorted { $0.tokens > $1.tokens }
        
        let sortedProjects = projectsDict.map { k, v in
            ProjectStats(name: k, runs: v.runs, delegated: v.delegated, tokens: v.tokens, durationMs: v.durationMs)
        }.sorted { $0.tokens > $1.tokens }
        
        return TelemetryStats(
            days: days,
            projectFilter: project,
            totalRuns: totalRuns,
            delegatedRuns: delegatedRuns,
            directRuns: directRuns,
            totalDurationMs: totalDurationMs,
            totalTokens: totalTokens,
            parentTokens: parentTokens,
            workerTokens: workerTokens,
            cachedInputTokens: cachedInputTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            cacheRatio: cacheRatio,
            workerOffloadRatio: workerOffload,
            estimatedCreditsMicros: hasCredits ? totalCreditsMicros : nil,
            models: sortedModels,
            projects: sortedProjects
        )
    }
}
