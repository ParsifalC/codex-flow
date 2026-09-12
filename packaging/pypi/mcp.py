"""MCP server entry point for codex-flow-mcp."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import List, Optional
from codex_flow.cli import get_resource_root, run_python_script


def main(argv: Optional[List[str]] = None) -> int:
    """Run FlowPilot ChatGPT MCP Server."""
    if argv is None:
        argv = sys.argv[1:]

    root = get_resource_root()
    candidates = [
        root / "apps" / "chatgpt-mcp" / "server.py",
        root / "server.py",
    ]
    server_path = None
    for c in candidates:
        if c.is_file():
            server_path = c
            break

    if not server_path:
        print("Error: MCP server.py not found in codex-flow package", file=sys.stderr)
        return 1

    return run_python_script(server_path, argv)


if __name__ == "__main__":
    sys.exit(main())
