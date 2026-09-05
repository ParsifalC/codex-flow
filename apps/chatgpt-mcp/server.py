"""Minimal loopback MCP Streamable HTTP server for FlowPilot telemetry."""

from __future__ import annotations

import argparse
import ipaddress
import json
import signal
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


_MODULE_DIR = Path(__file__).resolve().parent
if __package__:
    from . import adapter
else:
    if str(_MODULE_DIR) not in sys.path:
        sys.path.insert(0, str(_MODULE_DIR))
    import adapter  # type: ignore


JSONRPC_VERSION = "2.0"
SERVER_NAME = "chatgpt-codex-flow"
SERVER_VERSION = "2.1.2"
MAX_REQUEST_BYTES = 1024 * 1024


def _response(request_id: Any, result: Any = None, error: Any = None) -> Dict[str, Any]:
    payload: Dict[str, Any] = {"jsonrpc": JSONRPC_VERSION, "id": request_id}
    if error is not None:
        payload["error"] = error
    else:
        payload["result"] = result
    return payload


def _error(code: int, message: str) -> Dict[str, Any]:
    return {"code": code, "message": message}


def _valid_id(value: Any) -> bool:
    return value is None or isinstance(value, (str, int, float)) and not isinstance(value, bool)


def _initialize_result(params: Any) -> Dict[str, Any]:
    requested = params.get("protocolVersion") if isinstance(params, dict) else None
    # Echo versions understood by current MCP clients.  If a future client
    # version is sent, fall back to this server's known Streamable HTTP version.
    supported = {"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"}
    protocol_version = requested if requested in supported else "2025-03-26"
    return {
        "protocolVersion": protocol_version,
        "capabilities": {
            "tools": {"listChanged": False},
            "resources": {"subscribe": False, "listChanged": False},
        },
        "serverInfo": {
            "name": SERVER_NAME,
            "title": "FlowPilot telemetry",
            "version": SERVER_VERSION,
        },
        "instructions": "Use flowpilot_get_telemetry for read-only run telemetry.",
    }


def _dispatch(request: Any) -> Optional[Dict[str, Any]]:
    """Dispatch one JSON-RPC value; ``None`` means notification."""

    if not isinstance(request, dict):
        return _response(None, error=_error(-32600, "Invalid Request"))
    request_id = request.get("id")
    has_id = "id" in request
    if request.get("jsonrpc") != JSONRPC_VERSION:
        return _response(request_id if has_id else None, error=_error(-32600, "Invalid Request"))
    if has_id and not _valid_id(request_id):
        return _response(None, error=_error(-32600, "Invalid Request"))
    method = request.get("method")
    if not isinstance(method, str):
        return _response(request_id if has_id else None, error=_error(-32600, "Invalid Request"))
    params = request.get("params")

    if method == "notifications/initialized":
        # MCP sends this as a notification (without an id).  If a caller
        # incorrectly supplies an id, preserve JSON-RPC request semantics
        # instead of silently dropping that id.
        return None if not has_id else _response(request_id, result={})
    if method == "initialize":
        if params is not None and not isinstance(params, dict):
            result = _response(request_id if has_id else None, error=_error(-32602, "Invalid params"))
        else:
            result = _response(request_id if has_id else None, result=_initialize_result(params or {}))
    elif method == "ping":
        result = _response(request_id if has_id else None, result={})
    elif method == "tools/list":
        result = _response(request_id if has_id else None, result={"tools": [adapter.tool_descriptor()]})
    elif method == "resources/list":
        result = _response(
            request_id if has_id else None,
            result={"resources": [adapter.resource_descriptor()]},
        )
    elif method == "resources/read":
        if not isinstance(params, dict) or not isinstance(params.get("uri"), str):
            result = _response(request_id if has_id else None, error=_error(-32602, "Invalid params"))
        elif params.get("uri") != adapter.RESOURCE_URI:
            result = _response(request_id if has_id else None, error=_error(-32602, "Unknown resource"))
        else:
            try:
                text = adapter.read_widget()
            except adapter.WidgetResourceError:
                result = _response(request_id if has_id else None, error=_error(-32002, "Resource unavailable"))
            else:
                result = _response(
                    request_id if has_id else None,
                    result={
                        "contents": [
                            {
                                "uri": adapter.RESOURCE_URI,
                                "mimeType": adapter.RESOURCE_MIME_TYPE,
                                "text": text,
                            }
                        ]
                    },
                )
    elif method == "tools/call":
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            result = _response(request_id if has_id else None, error=_error(-32602, "Invalid params"))
        elif params.get("name") != adapter.TOOL_NAME:
            result = _response(request_id if has_id else None, error=_error(-32602, "Unknown tool"))
        else:
            arguments = params.get("arguments")
            if arguments is not None and not isinstance(arguments, dict):
                result = _response(request_id if has_id else None, error=_error(-32602, "Invalid params"))
            else:
                try:
                    tool_value = adapter.tool_result(arguments or {})
                except Exception:
                    # Telemetry is fail-open; a read adapter failure must not
                    # terminate the HTTP process or touch the collector.
                    tool_value = {
                        "content": [
                            {
                                "type": "text",
                                "text": "FlowPilot telemetry is temporarily unavailable.",
                            }
                        ],
                        "structuredContent": adapter.unavailable_telemetry(),
                        "isError": True,
                    }
                result = _response(request_id if has_id else None, result=tool_value)
    else:
        result = _response(
            request_id if has_id else None,
            error=_error(-32601, "Method not found"),
        )

    return None if not has_id else result


def dispatch_json(value: Any) -> Optional[Any]:
    """Dispatch a single request or a JSON-RPC batch."""

    if isinstance(value, list):
        if not value:
            return _response(None, error=_error(-32600, "Invalid Request"))
        responses = [_dispatch(item) for item in value]
        responses = [item for item in responses if item is not None]
        return responses or None
    return _dispatch(value)


def _is_loopback_host(host: str) -> bool:
    normalized = host.strip().lower()
    if normalized == "localhost":
        return True
    try:
        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False


class LoopbackHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class LoopbackHTTPServerV6(LoopbackHTTPServer):
    address_family = __import__("socket").AF_INET6


class MCPRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format_string: str, *args: Any) -> None:
        # A long-running local adapter should not fill stderr with access logs.
        return

    def _headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header(
            "Access-Control-Allow-Headers",
            "Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version",
        )

    def _send_json(self, status: int, value: Any) -> None:
        data = json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
        self.send_response(status)
        self._headers()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_empty(self, status: int) -> None:
        self.send_response(status)
        self._headers()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_OPTIONS(self) -> None:
        if self.path not in ("/mcp", "/healthz"):
            self._send_empty(HTTPStatus.NOT_FOUND)
            return
        self._send_empty(HTTPStatus.NO_CONTENT)

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._send_json(
                HTTPStatus.OK,
                {"ok": True, "service": SERVER_NAME, "version": SERVER_VERSION},
            )
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def _read_json(self) -> Tuple[Optional[Any], Optional[Tuple[int, str]]]:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            return None, (HTTPStatus.LENGTH_REQUIRED, "Content-Length is required")
        try:
            length = int(raw_length)
        except (TypeError, ValueError):
            return None, (HTTPStatus.BAD_REQUEST, "Invalid Content-Length")
        if length < 0 or length > MAX_REQUEST_BYTES:
            return None, (HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Request body is too large")
        try:
            raw = self.rfile.read(length)
            value = json.loads(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return None, (HTTPStatus.BAD_REQUEST, "Parse error")
        return value, None

    def do_POST(self) -> None:
        if self.path != "/mcp":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
            return
        value, read_error = self._read_json()
        if read_error is not None:
            status, message = read_error
            self._send_json(
                status,
                _response(None, error=_error(-32700, message)),
            )
            return
        try:
            result = dispatch_json(value)
        except Exception:
            # Never propagate an adapter or dispatch failure into the server
            # loop.  The collector is a separate process and remains untouched.
            result = _response(None, error=_error(-32603, "Internal error"))
        if result is None:
            self._send_empty(HTTPStatus.NO_CONTENT)
        else:
            self._send_json(HTTPStatus.OK, result)


def _make_server(host: str, port: int) -> LoopbackHTTPServer:
    if not _is_loopback_host(host):
        raise ValueError("--host must be a loopback address")
    server_class = LoopbackHTTPServerV6 if ":" in host else LoopbackHTTPServer
    return server_class((host, port), MCPRequestHandler)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="FlowPilot telemetry MCP server")
    parser.add_argument("--host", default="127.0.0.1", help="loopback bind address")
    parser.add_argument("--port", default=8787, type=int, help="TCP port (default: 8787)")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.port < 0 or args.port > 65535:
        print("--port must be between 0 and 65535", file=sys.stderr)
        return 2
    try:
        server = _make_server(args.host, args.port)
    except (OSError, ValueError) as exc:
        print("Unable to bind FlowPilot MCP server: %s" % exc, file=sys.stderr)
        return 1

    def stop(signum: int, frame: Any) -> None:
        # ``shutdown`` must run off the serve_forever thread to avoid waiting
        # on itself when SIGINT/SIGTERM arrives in the main thread.
        threading.Thread(target=server.shutdown, daemon=True).start()

    previous: Dict[int, Any] = {}
    for signal_number in (signal.SIGINT, signal.SIGTERM):
        try:
            previous[signal_number] = signal.signal(signal_number, stop)
        except (ValueError, OSError):
            pass
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        for signal_number, handler in previous.items():
            try:
                signal.signal(signal_number, handler)
            except (ValueError, OSError):
                pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
