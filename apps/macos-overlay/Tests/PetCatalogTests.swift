import Foundation
import Combine

@main
struct PetCatalogTests {
    static func main() throws {
        let catalog = """
        [
          {"id":"custom","displayName":"My companion","current":true},
          {"id":"deepseek","displayName":"deepseek酱","preset":true,"spriteVersionNumber":1},
          {"id":"default","displayName":"Original bubble","preset":true},
          {"id":"dasheng","displayName":"大圣","preset":true},
          {"id":"noir-webling","displayName":"Noir Webling","preset":true},
          {"id":"lulu-capybara-2","displayName":"噜噜","preset":true},
          {"id":"doraemon","displayName":"Doraemon","preset":true}
        ]
        """
        var calls = [[String]]()
        let parsed = try PetCatalogService.list { arguments in
            calls.append(arguments)
            return catalog
        }
        precondition(calls == [["pets", "list", "--json"]])
        precondition(parsed.first?.current == true, "Catalog must preserve explicit custom selection")
        precondition(parsed.first?.version == 1, "Absent sprite version defaults to v1")
        precondition(parsed[1].displayName == "deepseek酱")
        let ordered = PetCatalogParser.ordered(parsed)
        precondition(ordered.map(\.id) == PetCatalogParser.presetOrder + ["custom", "default"])
        precondition(ordered.filter { $0.id == "default" }.count == 1, "Classic option must appear exactly once")
        precondition(ordered.first?.current == false, "Default badge must not override selected custom pet")
        let classic = try PetCatalogParser.parse("[{\"id\":\"default\",\"current\":true}]")
        precondition(PetCatalogParser.ordered(classic).last?.current == true)
        precondition(PetCatalogParser.ordered([]).map(\.id) == ["default"])

        for invalid in ["{}", "not json", "[{\"id\":\"../escape\"}]", "[{\"id\":\"x\"},{\"id\":\"x\"}]", "[{\"id\":\"x\",\"spriteVersionNumber\":3}]"] {
            do {
                _ = try PetCatalogParser.parse(invalid)
                preconditionFailure("Invalid catalog was accepted: \(invalid)")
            } catch {}
        }
        try PetCatalogService.select("default") { arguments in
            calls.append(arguments)
            return "selected"
        }
        precondition(calls.last == ["pets", "use", "default", "--no-notify"], "Native selection must save without triggering an IPC reload")
        enum ExpectedFailure: Error { case unavailable }
        do {
            try PetCatalogService.select("dasheng") { _ in throw ExpectedFailure.unavailable }
            preconditionFailure("CLI errors must reach the UI")
        } catch ExpectedFailure.unavailable {}
        let state = OverlayState()
        var didReload = false
        state.reloadPetAsync { outcome in
            precondition(Thread.isMainThread, "UI reload completion must run on the main thread")
            precondition(outcome.accepted && outcome.selectedID == "default", "An absent selection keeps the classic fallback until CLI seeding completes")
            didReload = true
        }
        precondition(!didReload, "Reload must return without synchronously decoding on the main thread")
        let deadline = Date().addingTimeInterval(5)
        while !didReload && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(didReload, "Async reload must deliver completion")
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]!)
        let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PET_FIXTURES_ROOT"]!)
        let installed = home.appendingPathComponent("codex-flow/pets/installed")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let current = home.appendingPathComponent("codex-flow/pets/current")
        for id in ["synthetic-v1", "synthetic-v2"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(id), to: installed.appendingPathComponent(id))
        }
        func selectAndReload(_ id: String) throws -> PetReloadOutcome {
            try PetCatalogService.select(id) { arguments in
                try Data(arguments[2].utf8).write(to: current, options: .atomic)
                return "selected"
            }
            var result: PetReloadOutcome?
            state.reloadPetAsync { result = $0 }
            let deadline = Date().addingTimeInterval(5)
            while result == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(result != nil)
            return result!
        }
        let initialSelection = try selectAndReload("synthetic-v1")
        precondition(initialSelection.accepted)
        // Exercise the actual settings -> CLI -> reload path with a live IPC server.
        // A notifying CLI plus a second UI reload would publish the resource twice.
        let socketPath = home.appendingPathComponent("codex-flow/overlay.sock").path
        let server = IPCService.Server(state: state, socketPath: socketPath)
        defer { server.stop() }
        var publications = 0
        let observation = state.$petResource.dropFirst().sink { _ in publications += 1 }
        var selectionResult: PetReloadOutcome?
        state.selectPet("synthetic-v2") { selectionResult = $0 }
        let selectionDeadline = Date().addingTimeInterval(10)
        while selectionResult == nil && Date() < selectionDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(selectionResult?.accepted == true && state.selectedPetID == "synthetic-v2")
        precondition(publications == 1, "Settings selection must apply the resource exactly once")
        // An external CLI change must update the same selection observed by settings.
        try Data("synthetic-v1".utf8).write(to: current, options: .atomic)
        var externalResponse: String?
        DispatchQueue.global().async {
            let response = IPCService.sendCommand("pet reload\n", socketPath: socketPath).response
            DispatchQueue.main.async { externalResponse = response }
        }
        let externalDeadline = Date().addingTimeInterval(5)
        while externalResponse == nil && Date() < externalDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(externalResponse?.contains("\"ok\":true") == true)
        precondition(state.selectedPetID == "synthetic-v1", "External reload must update the settings selection")
        observation.cancel()
        try Data("invalid image".utf8).write(to: installed.appendingPathComponent("synthetic-v2/spritesheet.png"))
        let rejected = try selectAndReload("synthetic-v2")
        precondition(!rejected.accepted && state.petResource == nil, "Rejected image uses the classic fallback")
        precondition(rejected.selectedID == "synthetic-v2")
        let recovered = try selectAndReload("synthetic-v1")
        precondition(recovered.accepted && state.petResource?.id == "synthetic-v1",
                     "The previous pet must be selectable after a native rejection")
        try FileManager.default.removeItem(at: home.appendingPathComponent("codex-flow/pets"))
        print("Pet catalog ordering, selection, CLI errors and async reload tests passed")
    }
}
