import Foundation

@main
struct LocalizationSettingsTests {
    static func main() throws {
        // The test runner supplies an isolated CODEX_HOME and the source CLI.
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]!)
        let policy = root.appendingPathComponent("codex-flow.toml")
        try "[strategy]\nprofile = \"quality\"\n\n[ui]\nlanguage = \"en\"\n".write(to: policy, atomically: true, encoding: .utf8)

        try AppLocalization.setConfiguredLanguage("zh")
        precondition(AppLocalization.configuredLanguage() == "zh")
        precondition(AppLocalization.resolveLanguage() == .zh)
        let saved = try String(contentsOf: policy, encoding: .utf8)
        precondition(saved.contains("profile = \"quality\""), "Language changes must preserve other settings")

        try AppLocalization.setConfiguredLanguage("en")
        precondition(AppLocalization.resolveLanguage() == .en)
        try AppLocalization.setConfiguredLanguage("auto")
        precondition(AppLocalization.configuredLanguage() == "auto")
        precondition(AppLocalization.resolveLanguage() == AppLocalization.systemLanguage())

        let before = try Data(contentsOf: policy)
        do {
            try AppLocalization.setConfiguredLanguage("unsupported")
            preconditionFailure("Invalid language must be rejected")
        } catch {
            let after = try Data(contentsOf: policy)
            precondition(before == after, "A rejected change must preserve the policy")
        }
        print("Language persistence, resolution, rejection and policy preservation passed")
    }
}
