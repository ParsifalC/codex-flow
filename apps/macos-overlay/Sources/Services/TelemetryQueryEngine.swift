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
    
    // MARK: - Transcript Insights Extraction
    
    public func enrichRunIfNeeded(_ run: inout TaskRun) {
        if (run.trajectory == nil || run.skillsUsed == nil || run.summaryInfo == nil),
           let transcript = run.transcriptPath,
           let insights = parseTranscriptInsights(from: transcript) {
            if run.skillsUsed == nil || run.skillsUsed!.isEmpty {
                run.skillsUsed = insights.skills
            }
            if run.toolsUsed == nil || run.toolsUsed!.isEmpty {
                run.toolsUsed = insights.tools
            }
            if run.trajectory == nil || run.trajectory!.isEmpty {
                run.trajectory = insights.trajectory
            }
            if run.logs == nil || run.logs!.isEmpty {
                run.logs = insights.logs
            }
            if run.summaryInfo == nil {
                run.summaryInfo = insights.summary
            }
        }
    }
    
    public func parseTranscriptInsights(from pathString: String) -> (skills: [SkillUsage], tools: [ToolCallInfo], trajectory: [TrajectoryStep], logs: [TaskLogEntry], summary: TaskSummaryInfo)? {
        guard FileManager.default.fileExists(atPath: pathString),
              let fileHandle = FileHandle(forReadingAtPath: pathString) else {
            return nil
        }
        defer { try? fileHandle.close() }
        
        // Read at most last 256KB of transcript to keep memory & parsing instant (< 2ms)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: pathString)[.size] as? UInt64) ?? 0
        let maxReadBytes: UInt64 = 256 * 1024
        if fileSize > maxReadBytes {
            try? fileHandle.seek(toOffset: fileSize - maxReadBytes)
        }
        let data = fileHandle.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        
        var skillsDict: [String: Int] = [:]
        var toolsDict: [String: ToolCallInfo] = [:]
        var trajectory: [TrajectoryStep] = []
        var logs: [TaskLogEntry] = []
        var goal: String? = nil
        var conclusion: String? = nil
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let ts = obj["timestamp"] as? String
            let recType = obj["type"] as? String
            guard let payload = obj["payload"] as? [String: Any] else { continue }
            
            if recType == "response_item" {
                let pType = payload["type"] as? String
                if pType == "custom_tool_call" {
                    let toolName = payload["name"] as? String ?? "unknown"
                    let rawInput = payload["input"]
                    let callId = payload["call_id"] as? String
                    let isMcp = toolName.starts(with: "mcp__") || toolName.lowercased().contains("mcp")
                    
                    let inputString: String
                    if let s = rawInput as? String {
                        inputString = s
                    } else if let dict = rawInput as? [String: Any],
                              let d = try? JSONSerialization.data(withJSONObject: dict),
                              let s = String(data: d, encoding: .utf8) {
                        inputString = s
                    } else {
                        inputString = ""
                    }
                    
                    if let regex = try? NSRegularExpression(pattern: "skills/([a-zA-Z0-9_\\-]+)") {
                        let matches = regex.matches(in: inputString, range: NSRange(inputString.startIndex..., in: inputString))
                        for match in matches {
                            if let range = Range(match.range(at: 1), in: inputString) {
                                let sName = String(inputString[range])
                                skillsDict[sName, default: 0] += 1
                            }
                        }
                    }
                    
                    if var existing = toolsDict[toolName] {
                        existing.count = (existing.count ?? 0) + 1
                        toolsDict[toolName] = existing
                    } else {
                        toolsDict[toolName] = ToolCallInfo(
                            name: toolName,
                            count: 1,
                            isMcp: isMcp,
                            category: isMcp ? "mcp" : "system"
                        )
                    }
                    
                    var inpSummary = ""
                    if let cmdRegex = try? NSRegularExpression(pattern: "\"cmd\"\\s*:\\s*\"([^\"]+)\""),
                       let match = cmdRegex.firstMatch(in: inputString, range: NSRange(inputString.startIndex..., in: inputString)),
                       let range = Range(match.range(at: 1), in: inputString) {
                        inpSummary = String(inputString[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        inpSummary = inputString.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                    }
                    if inpSummary.count > 160 {
                        inpSummary = String(inpSummary.prefix(157)) + "..."
                    }
                    
                    let cleanTitle = isMcp ? "MCP: \(toolName.replacingOccurrences(of: "mcp__", with: ""))" : "调用 \(toolName)"
                    trajectory.append(TrajectoryStep(
                        type: "tool_call",
                        name: toolName,
                        title: cleanTitle,
                        detail: inpSummary,
                        status: "completed",
                        isMcp: isMcp,
                        callId: callId,
                        timestamp: ts
                    ))
                    
                    logs.append(TaskLogEntry(
                        timestamp: ts,
                        level: "info",
                        type: "tool_call",
                        message: "[\(toolName)] \(inpSummary)"
                    ))
                } else if pType == "message" {
                    let role = payload["role"] as? String
                    var msgText = ""
                    if let contentList = payload["content"] as? [[String: Any]] {
                        for item in contentList {
                            if let t = item["text"] as? String {
                                msgText += t
                            } else if let ot = item["output_text"] as? String {
                                msgText += ot
                            }
                        }
                    }
                    msgText = msgText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if role == "user" && !msgText.isEmpty {
                        var cleanPrompt = msgText
                        if let r = cleanPrompt.range(of: "<USER_REQUEST>"),
                           let endR = cleanPrompt.range(of: "</USER_REQUEST>") {
                            cleanPrompt = String(cleanPrompt[r.upperBound..<endR.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        if let reqRange = cleanPrompt.range(of: "## My request:", options: .caseInsensitive) {
                            cleanPrompt = String(cleanPrompt[reqRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        if !cleanPrompt.starts(with: "<") || goal == nil {
                            goal = cleanPrompt
                        }
                    } else if role == "assistant" && !msgText.isEmpty {
                        conclusion = msgText
                    }
                }
            } else if recType == "event_msg" && payload["type"] as? String == "item_completed" {
                if let item = payload["item"] as? [String: Any],
                   item["type"] as? String == "CommandExecution" {
                    let exitCode = item["exit_code"] as? Int ?? 0
                    let stdout = (item["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if let lastIndex = trajectory.indices.last, trajectory[lastIndex].type == "tool_call" {
                        trajectory[lastIndex].status = exitCode == 0 ? "completed" : "error"
                    }
                    if !stdout.isEmpty {
                        logs.append(TaskLogEntry(
                            timestamp: ts,
                            level: exitCode == 0 ? "info" : "error",
                            type: "command_output",
                            message: "Exit \(exitCode): \(stdout.prefix(120))"
                        ))
                    }
                }
            }
        }
        
        let skillsList = skillsDict.map { SkillUsage(name: $0.key, count: $0.value) }
        let toolsList = Array(toolsDict.values)
        let summaryInfo = TaskSummaryInfo(
            goal: goal != nil ? String(goal!.prefix(300)) : nil,
            conclusion: conclusion != nil ? String(conclusion!.prefix(500)) : nil
        )
        
        return (
            skills: skillsList,
            tools: toolsList,
            trajectory: Array(trajectory.suffix(20)),
            logs: Array(logs.suffix(30)),
            summary: summaryInfo
        )
    }
    
    // MARK: - Query & Filter History (Session / Run Level)
    
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
                let turnText = run.turnPreview.lowercased()
                let proj = run.projectName.lowercased()
                let branch = (run.gitBranch ?? "").lowercased()
                let summary = (run.summary ?? "").lowercased()
                let sess = (run.sessionId ?? "").lowercased()
                let turn = (run.turnId ?? "").lowercased()
                return title.contains(qNorm) || turnText.contains(qNorm) || proj.contains(qNorm) || branch.contains(qNorm) || summary.contains(qNorm) || sess.contains(qNorm) || turn.contains(qNorm)
            }
        }
        
        if limit > 0 && runs.count > limit {
            return Array(runs.prefix(limit))
        }
        return runs
    }
    
    // MARK: - Query & Filter Chat Groups (Dimension 2: Chat Level)
    
    public func fetchChatHistory(
        limit: Int = 50,
        project: String? = nil,
        todayOnly: Bool = false,
        search: String? = nil
    ) -> [ChatSession] {
        let allRuns = loadAllRuns()
        if allRuns.isEmpty {
            return []
        }
        
        // 1. Group runs by session_id (or fallback fileStem)
        var groups: [String: [TaskRun]] = [:]
        var groupOrder: [String] = []
        
        for run in allRuns {
            let key = run.sessionId ?? run.fileStem ?? UUID().uuidString
            if groups[key] == nil {
                groups[key] = []
                groupOrder.append(key)
            }
            groups[key]!.append(run)
        }
        
        // 2. Materialize ChatSession objects
        var chats: [ChatSession] = []
        for key in groupOrder {
            guard let groupRuns = groups[key], !groupRuns.isEmpty else { continue }
            
            // Sort runs in this chat descending by timestamp (newest first)
            let sortedRuns = groupRuns.sorted { r1, r2 in
                let t1 = r1.finishedAtMs ?? r1.startedAtMs ?? 0
                let t2 = r2.finishedAtMs ?? r2.startedAtMs ?? 0
                return t1 > t2
            }
            
            let latestRun = sortedRuns.first!
            let oldestRun = sortedRuns.last!
            
            // Derive best project & branch
            let proj = latestRun.projectName
            let branch = sortedRuns.compactMap { $0.gitBranch }.first
            let cwd = latestRun.cwd ?? latestRun.thread?.cwd
            
            // Derive best title / prompt from oldest or latest thread preview
            let title = sortedRuns.compactMap { r -> String? in
                if let p = r.thread?.preview, !p.isEmpty { return p }
                if let n = r.thread?.name, !n.isEmpty { return n }
                if let s = r.summary, !s.isEmpty { return s }
                return nil
            }.first ?? latestRun.sessionTitle
            
            let summary = sortedRuns.compactMap { $0.summary }.first
            let startedAt = oldestRun.startedAtMs
            let finishedAt = latestRun.finishedAtMs
            let lastActive = sortedRuns.map { $0.finishedAtMs ?? $0.startedAtMs ?? 0 }.max() ?? 0
            
            let chat = ChatSession(
                sessionId: key,
                projectName: proj,
                gitBranch: branch,
                cwd: cwd,
                title: title,
                summary: summary,
                startedAtMs: startedAt,
                finishedAtMs: finishedAt,
                lastActiveAtMs: lastActive,
                runs: sortedRuns
            )
            chats.append(chat)
        }
        
        // 3. Filter by Today
        if todayOnly {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date()).timeIntervalSince1970 * 1000
            chats = chats.filter { chat in
                chat.lastActiveAtMs >= startOfToday
            }
        }
        
        // 4. Filter by Project
        if let proj = project, !proj.isEmpty, proj.lowercased() != "all" {
            let pNorm = proj.lowercased()
            chats = chats.filter { chat in
                let cProj = chat.projectName.lowercased()
                let cwd = (chat.cwd ?? "").lowercased()
                return cProj.contains(pNorm) || cwd.contains(pNorm)
            }
        }
        
        // 5. Filter by Search Query
        if let query = search?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            let qNorm = query.lowercased()
            chats = chats.filter { chat in
                if chat.title.lowercased().contains(qNorm) { return true }
                if chat.projectName.lowercased().contains(qNorm) { return true }
                if (chat.gitBranch ?? "").lowercased().contains(qNorm) { return true }
                if chat.sessionId.lowercased().contains(qNorm) { return true }
                if let sum = chat.summary, sum.lowercased().contains(qNorm) { return true }
                
                // Also search across each run within the chat
                for r in chat.runs {
                    if r.sessionTitle.lowercased().contains(qNorm) { return true }
                    if r.turnPreview.lowercased().contains(qNorm) { return true }
                    if (r.summary ?? "").lowercased().contains(qNorm) { return true }
                    if (r.turnId ?? "").lowercased().contains(qNorm) { return true }
                    if (r.parent?.displayModel ?? "").lowercased().contains(qNorm) { return true }
                    for w in r.allWorkers {
                        if (w.name ?? "").lowercased().contains(qNorm) { return true }
                        if (w.model ?? "").lowercased().contains(qNorm) { return true }
                    }
                }
                return false
            }
        }
        
        // 6. Sort descending by last active time
        chats.sort { $0.lastActiveAtMs > $1.lastActiveAtMs }
        
        if limit > 0 && chats.count > limit {
            return Array(chats.prefix(limit))
        }
        return chats
    }
    
    public func fetchChat(sessionId: String) -> ChatSession? {
        let sid = sessionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sid.isEmpty { return nil }
        let chats = fetchChatHistory(limit: 500)
        return chats.first { $0.sessionId.lowercased() == sid || $0.sessionId.lowercased().contains(sid) }
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
        
        var modelsDict: [String: (calls: Int, tokens: Int, roles: Set<String>, quotaDelta: Double)] = [:]
        var projectsDict: [String: (runs: Int, delegated: Int, tokens: Int, durationMs: Double, quotaDelta: Double)] = [:]
        
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
            let runDelta = run.primaryQuotaDelta ?? 0
            
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
                modelsDict[pModel] = (0, 0, [], 0)
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
                    modelsDict[wModel] = (0, 0, [], 0)
                }
                modelsDict[wModel]!.calls += 1
                modelsDict[wModel]!.tokens += wTot
                modelsDict[wModel]!.roles.insert("worker")
            }
            
            let runTot = pTot + wTotSum
            totalTokens += runTot
            
            if runTot > 0 && runDelta != 0 {
                let pRatio = Double(pTot) / Double(runTot)
                modelsDict[pModel]!.quotaDelta += runDelta * pRatio
                for w in workers {
                    let wUsage = w.effectiveUsage
                    let wTot = wUsage?.totalTokens ?? ((wUsage?.effectivePromptTokens ?? 0) + (wUsage?.effectiveOutputTokens ?? 0))
                    let wRatio = Double(wTot) / Double(runTot)
                    modelsDict[w.displayModel]!.quotaDelta += runDelta * wRatio
                }
            }
            
            if projectsDict[projName] == nil {
                projectsDict[projName] = (0, 0, 0, 0, 0)
            }
            projectsDict[projName]!.runs += 1
            if !workers.isEmpty {
                projectsDict[projName]!.delegated += 1
            }
            projectsDict[projName]!.tokens += runTot
            projectsDict[projName]!.durationMs += dur
            projectsDict[projName]!.quotaDelta += runDelta
        }
        
        let cacheRatio = inputTokens > 0 ? (Double(cachedInputTokens) / Double(inputTokens) * 100.0) : 0.0
        let workerOffload = totalTokens > 0 ? (Double(workerTokens) / Double(totalTokens) * 100.0) : 0.0
        
        let sortedModels = modelsDict.map { k, v in
            ModelStats(
                name: k,
                calls: v.calls,
                tokens: v.tokens,
                roles: Array(v.roles).sorted(),
                quotaDelta: abs(v.quotaDelta) >= 0.01 ? v.quotaDelta : nil
            )
        }.sorted { $0.tokens > $1.tokens }
        
        let sortedProjects = projectsDict.map { k, v in
            ProjectStats(
                name: k,
                runs: v.runs,
                delegated: v.delegated,
                tokens: v.tokens,
                durationMs: v.durationMs,
                quotaDelta: abs(v.quotaDelta) >= 0.01 ? v.quotaDelta : nil
            )
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

    // MARK: - Daily Quota Usage Aggregation
    public func computeDailyQuotaUsage(days: Int = 7) -> [DailyQuotaUsage] {
        let runs = loadAllRuns()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today

        var buckets: [Date: (quotaDelta: Double, tokens: Int, runs: Int)] = [:]
        for run in runs {
            guard let ms = run.finishedAtMs ?? run.startedAtMs else { continue }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: ms / 1000.0))
            guard day >= cutoff && day <= today else { continue }
            let existing = buckets[day] ?? (0.0, 0, 0)
            let delta = run.primaryQuotaDelta ?? 0.0
            let tokens = run.aggregatedUsage.totalTokens ?? 0
            buckets[day] = (existing.quotaDelta + delta, existing.tokens + tokens, existing.runs + 1)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let shortFormatter = DateFormatter()
        shortFormatter.dateFormat = "MM-dd"

        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let value = buckets[day] ?? (0.0, 0, 0)
            let displayDate: String
            if calendar.isDateInToday(day) {
                displayDate = L("Today", "今天")
            } else if calendar.isDateInYesterday(day) {
                displayDate = L("Yesterday", "昨天")
            } else {
                displayDate = shortFormatter.string(from: day)
            }
            return DailyQuotaUsage(
                date: day,
                dateString: dateFormatter.string(from: day),
                displayDate: displayDate,
                quotaDelta: value.quotaDelta,
                tokens: value.tokens,
                runs: value.runs
            )
        }
    }
}
