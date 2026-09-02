#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CODEX_HOME="$TMP_DIR/codex-home"
mkdir -p "$CODEX_HOME/codex-flow/telemetry"

# Keep this fixture representative of the telemetry collector's last-run file,
# while ensuring the smoke test never reads or writes the user's real CODEX_HOME.
cat > "$CODEX_HOME/codex-flow/telemetry/last.json" <<'EOF'
{
  "schema_version": 1,
  "session_id": "smoke-session",
  "turn_id": "smoke-turn",
  "cwd": "/tmp/codex-flow-smoke",
  "parent": {
    "model": "gpt-5.6-sol",
    "status": "completed",
    "usage_delta": {
      "input_tokens": 120,
      "cached_input_tokens": 40,
      "output_tokens": 80,
      "reasoning_output_tokens": 20,
      "total_tokens": 200
    }
  },
  "workers": {
    "smoke-worker": {
      "agent_id": "smoke-worker",
      "agent_type": "worker-implementer",
      "model": "gpt-5.6-luna",
      "status": "completed",
      "conclusion": "Implemented worker telemetry output.",
      "usage": {"total_tokens": 50}
    }
  },
  "started_at_ms": 1750000000000,
  "finished_at_ms": 1750000002500
}
EOF

PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
LOG_FILE="$TMP_DIR/server.log"
CODEX_HOME="$CODEX_HOME" "$ROOT_DIR/bin/codex-flow-mcp" \
  --host 127.0.0.1 --port "$PORT" >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

export CODEX_HOME
python3 - "$PORT" <<'PY'
import json
import sys
import time
try:
    from urllib.error import HTTPError, URLError
    from urllib.request import Request, urlopen
except ImportError:
    raise SystemExit("urllib is required")

port = sys.argv[1]
base_url = "http://127.0.0.1:{0}".format(port)
session_id = None
request_id = 0


def decode_response(raw):
    text = raw.decode("utf-8")
    try:
        return json.loads(text)
    except ValueError:
        # Accept an SSE-wrapped JSON-RPC response as well as a plain JSON
        # response. This keeps the check compatible with both MCP transports.
        for line in text.splitlines():
            if line.startswith("data:"):
                try:
                    return json.loads(line[5:].strip())
                except ValueError:
                    continue
    raise AssertionError("response was not JSON or an SSE JSON message: {0!r}".format(text[:300]))


def http_request(path, payload=None, method=None):
    headers = {"Accept": "application/json, text/event-stream"}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode("utf-8")
        method = method or "POST"
    if session_id:
        headers["MCP-Session-Id"] = session_id
    request = Request(base_url + path, data=data, headers=headers, method=method)
    try:
        response = urlopen(request, timeout=3)
        return response.status, dict(response.headers), response.read()
    except HTTPError as error:
        return error.code, dict(error.headers), error.read()
    except URLError as error:
        raise AssertionError("request to {0} failed: {1}".format(path, error))


def wait_for_health():
    deadline = time.time() + 8
    last_error = None
    while time.time() < deadline:
        try:
            status, unused_headers, raw = http_request("/healthz", method="GET")
            if status == 200:
                body = json.loads(raw.decode("utf-8"))
                assert isinstance(body, dict), body
                assert (
                    body.get("ok") is True
                    or str(body.get("status", "")).lower() in ("ok", "healthy")
                ), body
                return
            last_error = "HTTP {0}: {1}".format(status, raw[:300])
        except (AssertionError, ValueError, URLError, OSError) as error:
            last_error = str(error)
        time.sleep(0.1)
    raise AssertionError("/healthz did not become ready: {0}".format(last_error))


def rpc(method, params=None):
    global request_id, session_id
    request_id += 1
    message = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    status, headers, raw = http_request("/mcp", message)
    assert status == 200, (method, status, raw[:500])
    response = decode_response(raw)
    assert response.get("jsonrpc") == "2.0", response
    assert response.get("id") == request_id, response
    if "error" in response:
        raise AssertionError("{0} returned an error: {1}".format(method, response["error"]))
    assert isinstance(response.get("result"), dict), response
    session_id = headers.get("Mcp-Session-Id") or headers.get("mcp-session-id") or session_id
    return response["result"]


def rpc_error(method, params=None):
    global request_id
    request_id += 1
    message = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    status, unused_headers, raw = http_request("/mcp", message)
    assert status == 200, (method, status, raw[:500])
    response = decode_response(raw)
    assert response.get("jsonrpc") == "2.0", response
    assert response.get("id") == request_id, response
    assert isinstance(response.get("error"), dict), response
    assert isinstance(response["error"].get("code"), int), response
    return response["error"]


wait_for_health()

initialize = rpc(
    "initialize",
    {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "codex-flow-smoke", "version": "1"},
    },
)
assert isinstance(initialize.get("serverInfo"), dict), initialize

# Complete the MCP initialization handshake. Notifications do not have a
# response, so a normal JSON-RPC request is not used for this message.
status, unused_headers, unused_raw = http_request(
    "/mcp",
    {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
)
assert status in (200, 202, 204), status

tools = rpc("tools/list", {})
tool_entries = tools.get("tools")
assert isinstance(tool_entries, list), tools
assert any(item.get("name") == "flowpilot_get_telemetry" for item in tool_entries if isinstance(item, dict)), tools

tool_result = rpc(
    "tools/call",
    {"name": "flowpilot_get_telemetry", "arguments": {}},
)
assert tool_result.get("isError") is not True, tool_result
assert isinstance(tool_result.get("content") or tool_result.get("structuredContent"), (list, dict)), tool_result
structured = tool_result.get("structuredContent")
assert isinstance(structured, dict), tool_result
assert structured.get("status") == "completed", structured
assert structured.get("total_tokens") == 250, structured
assert structured.get("parent", {}).get("model") == "gpt-5.6-sol", structured
worker = next(item for item in structured.get("participants", []) if item.get("role") == "worker")
assert worker.get("conclusion") == "Implemented worker telemetry output.", structured

resources = rpc("resources/list", {})
resource_entries = resources.get("resources")
assert isinstance(resource_entries, list) and resource_entries, resources
ui_resource = next(
    (
        item
        for item in resource_entries
        if isinstance(item, dict)
        and (
            str(item.get("mimeType", "")).lower().startswith("text/html")
            or str(item.get("uri", "")).startswith("ui://")
        )
    ),
    None,
)
assert isinstance(ui_resource, dict) and ui_resource.get("uri"), resources
resource_uri = ui_resource["uri"]
resource = rpc("resources/read", {"uri": resource_uri})
contents = resource.get("contents")
assert isinstance(contents, list) and contents, resource
assert any(
    isinstance(item, dict) and (item.get("text") is not None or item.get("blob") is not None)
    for item in contents
), resource

unknown_method = rpc_error("codex_flow_method_does_not_exist", {})
assert unknown_method.get("code") in (-32601, -32602), unknown_method
unknown_tool = rpc_error(
    "tools/call",
    {"name": "codex_flow_tool_does_not_exist", "arguments": {}},
)
assert unknown_tool.get("code") in (-32601, -32602), unknown_tool

print("chatgpt MCP smoke test passed")
PY

printf 'chatgpt-mcp test passed (CODEX_HOME isolated at %s)\n' "$CODEX_HOME"
