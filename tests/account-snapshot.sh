#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not installed, skipping native account snapshot test"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Compile only the Foundation-backed account service into a temporary test
# harness. This deliberately avoids build.sh and never writes installed
# ~/.codex binaries.
cat > "$TMP/Test.swift" <<'SWIFT'
import Foundation

func L(_ english: String, _ chinese: String) -> String { english }
func formatLocalDateTime(_ date: Date) -> String { "date" }

@main
struct AccountSnapshotFixtureTest {
    static func main() throws {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.count > 2 {
            let mode = CommandLine.arguments[2]
            let startedAt = Date()
            var failure: Error?
            do {
                _ = try AccountSnapshotService.load()
            } catch {
                failure = error
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            guard let failure else {
                throw NSError(
                    domain: "FlowPilot.AccountFixture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected \(mode) app-server failure"]
                )
            }
            let message = failure.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(!message.isEmpty, "\(mode) returned an empty localized error")
            precondition(elapsed < 6.0, "\(mode) exceeded bounded test limit")
            print("account snapshot \(mode) bounded failure passed")
            return
        }
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
        let account: [String: Any] = [
            "account": ["type": "chatgpt", "email": "fixture@example.com", "planType": "pro"],
            "requiresOpenaiAuth": false
        ]

        let first = try AccountSnapshotService.parse(
            accountResponse: account,
            limitsResponse: fixture,
            now: Date(timeIntervalSince1970: 1)
        )
        let second = try AccountSnapshotService.parse(
            accountResponse: account,
            limitsResponse: fixture,
            now: Date(timeIntervalSince1970: 2)
        )

        precondition(first.email == "fixture@example.com")
        precondition(first.resetCreditCount == 4)
        precondition(first.resetCredits.isEmpty)
        precondition(first.quotaWindows.count == 2)
        precondition(first.quotaWindows[0].durationMinutes == 300)
        precondition(first.quotaWindows[0].usedPercent == 42)
        precondition(first.quotaWindows[1].durationMinutes == 10080)
        precondition(first.quotaWindows[1].usedPercent == 61)
        precondition(first.quotaWindows.map(\.id) == second.quotaWindows.map(\.id))

        AccountSnapshotService.clearCache()
        precondition(AccountSnapshotService.cached == nil)
        AccountSnapshotService.updateCache(first)
        precondition(AccountSnapshotService.cached?.email == "fixture@example.com")
        AccountSnapshotService.clearCache()
        precondition(AccountSnapshotService.cached == nil)

        let duplicateWindow = try AccountSnapshotService.parse(
            accountResponse: [:],
            limitsResponse: [
                "rateLimitsByLimitId": [
                    "codex": [
                        "primary": ["windowDurationMins": 300, "usedPercent": 10, "resetsAt": 1_700_000_000],
                        "secondary": ["windowDurationMins": 300, "usedPercent": 20, "resetsAt": 1_700_000_000]
                    ]
                ]
            ],
            now: Date(timeIntervalSince1970: 1)
        )
        precondition(duplicateWindow.quotaWindows.count == 1)
        precondition(duplicateWindow.quotaWindows[0].durationMinutes == 300)
        precondition(duplicateWindow.quotaWindows[0].usedPercent == 10)

        let distinctWindows = try AccountSnapshotService.parse(
            accountResponse: [:],
            limitsResponse: [
                "rateLimitsByLimitId": [
                    "codex": [
                        "primary": ["windowDurationMins": 300, "usedPercent": 10, "resetsAt": 1_700_000_000],
                        "secondary": ["windowDurationMins": 10080, "usedPercent": 20, "resetsAt": 1_700_000_000]
                    ]
                ]
            ],
            now: Date(timeIntervalSince1970: 1)
        )
        precondition(distinctWindows.quotaWindows.count == 2)
        precondition(distinctWindows.quotaWindows.map(\.durationMinutes) == [300, 10080])

        let zero = try AccountSnapshotService.parse(
            accountResponse: [:],
            limitsResponse: ["rateLimitResetCredits": ["availableCount": 0, "credits": NSNull()]],
            now: Date(timeIntervalSince1970: 1)
        )
        precondition(zero.resetCreditCount == 0)
        precondition(zero.resetCredits.isEmpty)
        precondition(!zero.isEmpty)

        let missing = try AccountSnapshotService.parse(
            accountResponse: [:],
            limitsResponse: ["rateLimitResetCredits": ["credits": []]],
            now: Date(timeIntervalSince1970: 1)
        )
        precondition(missing.resetCreditCount == nil)
        precondition(missing.resetCredits.isEmpty)
        precondition(missing.isEmpty)
        print("account snapshot fixture test passed")
    }
}
SWIFT

cat > "$TMP/fake-app-server.py" <<'PY'
#!/usr/bin/env python3
import json
import sys
import time

mode = sys.argv[1]
if mode == "silent":
    time.sleep(30)
    raise SystemExit(0)
if mode == "eof":
    raise SystemExit(17)

for line in sys.stdin:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        continue
    if mode == "malformed":
        print("not-json", flush=True)
        raise SystemExit(0)
    if mode == "rpc-error":
        print(json.dumps({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "error": {"code": -32000, "message": "fixture app-server error"},
        }), flush=True)
        time.sleep(30)
        raise SystemExit(0)
    raise SystemExit(2)
PY
chmod +x "$TMP/fake-app-server.py"

CLANG_MODULE_CACHE_PATH="$TMP/module-cache" swiftc \
    -parse-as-library \
    "$ROOT_DIR/apps/macos-overlay/Sources/Services/AccountSnapshotService.swift" \
    "$TMP/Test.swift" \
    -o "$TMP/account-snapshot-test"

"$TMP/account-snapshot-test" "$ROOT_DIR/tests/fixtures/account-rate-limits.json"

for mode in silent eof malformed rpc-error; do
    CODEX_FLOW_APP_SERVER_COMMAND="exec python3 \"$TMP/fake-app-server.py\" $mode" \
        "$TMP/account-snapshot-test" "$ROOT_DIR/tests/fixtures/account-rate-limits.json" "$mode"
done
