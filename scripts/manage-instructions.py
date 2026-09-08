#!/usr/bin/env python3
"""Install and inspect codex-flow's global prompt entry instructions.

The helper owns only the block between BEGIN_MARKER and END_MARKER in the
global AGENTS files.  It reads and writes bytes so unrelated content,
including a missing final newline, survives an install/uninstall round trip.
"""

from __future__ import print_function

import argparse
import json
import os
import stat
import sys
import tempfile
from pathlib import Path


BEGIN_MARKER = b"<!-- codex-flow:begin -->"
END_MARKER = b"<!-- codex-flow:end -->"
STATE_FILE = "instructions-state.json"
TARGET_NAMES = ("AGENTS.md", "AGENTS.override.md")


class InstructionError(RuntimeError):
    """A target cannot be safely inspected or updated."""


def default_codex_home():
    return Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()


def default_template(codex_home):
    local = Path(__file__).resolve().parents[1] / "templates" / "flow-pilot-instructions.md"
    if local.is_file():
        return local
    return Path(codex_home) / "codex-flow" / "flow-pilot-instructions.md"


def _lexists(path):
    return os.path.lexists(str(path))


def _read_target(path):
    if not _lexists(path):
        return None
    if path.is_symlink():
        raise InstructionError("refusing to manage symlink target: {}".format(path))
    if not path.is_file():
        raise InstructionError("refusing to manage non-file target: {}".format(path))
    try:
        return path.read_bytes()
    except OSError as exc:
        raise InstructionError("cannot read {}: {}".format(path, exc))


def _marker_range(data):
    """Return the owned block range, or ``None`` when no markers exist.

    A marker must occupy its own line.  Any unmatched or repeated marker is a
    hard error and is checked for every target before any target is changed.
    """

    begins = data.count(BEGIN_MARKER)
    ends = data.count(END_MARKER)
    if not begins and not ends:
        return None
    if begins != 1 or ends != 1:
        raise InstructionError("malformed or duplicate codex-flow instruction markers")
    begin = data.find(BEGIN_MARKER)
    end = data.find(END_MARKER)
    if end <= begin:
        raise InstructionError("malformed codex-flow instruction marker order")
    if end and data[end - 1 : end] not in (b"\n", b"\r"):
        raise InstructionError("codex-flow end marker must start a line")
    if begin and data[begin - 1 : begin] not in (b"\n", b"\r"):
        raise InstructionError("codex-flow begin marker must start a line")
    begin_after = begin + len(BEGIN_MARKER)
    if begin_after >= len(data) or data[begin_after : begin_after + 1] not in (b"\n", b"\r"):
        raise InstructionError("codex-flow begin marker must end a line")
    end_after = end + len(END_MARKER)
    if end_after < len(data) and data[end_after : end_after + 1] not in (b"\n", b"\r"):
        raise InstructionError("codex-flow end marker must end a line")
    if data[end_after : end_after + 2] == b"\r\n":
        end_after += 2
    elif data[end_after : end_after + 1] in (b"\n", b"\r"):
        end_after += 1
    return begin, end_after


def _remove_block(data):
    span = _marker_range(data)
    if span is None:
        return data, False
    start, end = span
    return data[:start] + data[end:], True


def _expand_template(data, codex_home):
    home = str(Path(codex_home).expanduser()).encode("utf-8")
    # Keep the documented token and accept the two common spellings so a
    # locally customized template remains useful across releases.
    for token in (b"{{CODEX_HOME}}", b"${CODEX_HOME}", b"__CODEX_HOME__"):
        data = data.replace(token, home)
    return data


def _block_for(template, codex_home):
    try:
        template_data = Path(template).read_bytes()
    except OSError as exc:
        raise InstructionError("cannot read instruction template {}: {}".format(template, exc))
    if BEGIN_MARKER in template_data or END_MARKER in template_data:
        raise InstructionError("instruction template contains reserved codex-flow markers")
    template_data = _expand_template(template_data, codex_home)
    if not template_data.endswith((b"\n", b"\r")):
        template_data += b"\n"
    return BEGIN_MARKER + b"\n" + template_data + END_MARKER + b"\n"


def _state_path(codex_home):
    return Path(codex_home) / "codex-flow" / STATE_FILE


def _load_state(codex_home):
    path = _state_path(codex_home)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return {"created": []}
    created = value.get("created") if isinstance(value, dict) else []
    if not isinstance(created, list):
        created = []
    return {"created": [name for name in created if name in TARGET_NAMES]}


def _atomic_write(path, data, mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".codex-flow-", dir=str(path.parent))
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if mode is not None and os.name != "nt":
            temporary.chmod(mode)
        os.replace(str(temporary), str(path))
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _atomic_write_json(path, value):
    payload = (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    _atomic_write(path, payload)


def _inspect(codex_home):
    home = Path(codex_home)
    result = {}
    for name in TARGET_NAMES:
        path = home / name
        data = _read_target(path)
        span = _marker_range(data) if data is not None else None
        result[name] = {
            "path": path,
            "data": data,
            "span": span,
            "has_block": span is not None,
        }
    return result


def _effective_name(items):
    override = items["AGENTS.override.md"]["data"]
    if override is not None and override.strip():
        return "AGENTS.override.md"
    return "AGENTS.md"


def _status(codex_home, template=None):
    items = _inspect(codex_home)
    target = _effective_name(items)
    active = items[target]
    report = {
        "status": "missing",
        "target": target,
        "paths": {name: str(items[name]["path"]) for name in TARGET_NAMES},
        "has_base": items["AGENTS.md"]["data"] is not None,
        "has_override": items["AGENTS.override.md"]["data"] is not None,
    }
    if active["data"] is None or not active["has_block"]:
        if target == "AGENTS.override.md":
            report["status"] = "shadowed"
        return report
    if template is not None:
        expected = _block_for(template, codex_home)
        begin, end = active["span"]
        if active["data"][begin:end] != expected:
            report["status"] = "stale"
            return report
    report["status"] = "installed"
    return report


def check(codex_home, template=None):
    """Return an effective-target status suitable for doctor and callers."""

    return _status(Path(codex_home), Path(template) if template else None)


def install(codex_home, template):
    """Install the managed block while preserving all unrelated bytes."""

    home = Path(codex_home)
    # Read/validate every possible target, including an inactive one, before
    # computing or applying changes.  This guarantees malformed markers cause
    # zero managed-file writes.
    items = _inspect(home)
    block = _block_for(template, home)
    target = _effective_name(items)
    old_state = _load_state(home)
    created = set(old_state.get("created", []))
    changes = {}

    for name in TARGET_NAMES:
        item = items[name]
        data = item["data"]
        if data is None:
            continue
        remaining, had_block = _remove_block(data)
        if had_block and not remaining and name in created and name != target:
            changes[name] = None
            created.discard(name)
        elif had_block and remaining != data:
            changes[name] = (remaining, item["path"].stat().st_mode)

    target_item = items[target]
    target_data = target_item["data"]
    if target_data is None:
        target_user_data = b""
        target_mode = None
        created.add(target)
    else:
        target_user_data, _ = _remove_block(target_data)
        target_mode = stat.S_IMODE(target_item["path"].stat().st_mode)
    desired = block + target_user_data
    # The target receives the fresh block below; discard the intermediate
    # cleanup entry produced by the all-target pass.
    changes.pop(target, None)
    if target_item["data"] != desired:
        changes[target] = (desired, target_mode)

    # Stage all replacement files before touching either target.  The helper
    # does not follow symlinks and refuses them during _inspect.
    staged = []
    originals = {name: items[name]["data"] for name in TARGET_NAMES}
    modes = {
        name: (stat.S_IMODE(items[name]["path"].stat().st_mode) if items[name]["data"] is not None else None)
        for name in TARGET_NAMES
    }
    try:
        for name, change in changes.items():
            if change is None:
                continue
            data, mode = change
            path = items[name]["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp_name = tempfile.mkstemp(prefix=".codex-flow-", dir=str(path.parent))
            temp = Path(tmp_name)
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            if mode is not None and os.name != "nt":
                temp.chmod(mode)
            staged.append((name, path, temp))
        for name, change in changes.items():
            path = items[name]["path"]
            if change is None:
                if _lexists(path):
                    path.unlink()
            else:
                temp = next(item[2] for item in staged if item[0] == name)
                os.replace(str(temp), str(path))
        new_state = {"created": sorted(created)}
        if new_state != old_state or changes:
            _atomic_write_json(_state_path(home), new_state)
    except Exception:
        # Restore only regular files that this invocation could have touched.
        # Marker validation and symlink refusal happen before this section.
        for _, _, temp in staged:
            try:
                temp.unlink()
            except FileNotFoundError:
                pass
        for name in TARGET_NAMES:
            path = items[name]["path"]
            original = originals.get(name)
            if original is None:
                try:
                    if _lexists(path):
                        path.unlink()
                except OSError:
                    pass
            elif not path.is_symlink():
                try:
                    _atomic_write(path, original, modes[name])
                except OSError:
                    pass
        raise
    return _status(home, Path(template))


def uninstall(codex_home):
    """Remove only managed blocks from both targets."""

    home = Path(codex_home)
    items = _inspect(home)  # validates all markers and symlink targets first
    state = _load_state(home)
    created = set(state.get("created", []))
    changes = {}
    for name in TARGET_NAMES:
        data = items[name]["data"]
        if data is None or not items[name]["has_block"]:
            continue
        remaining, _ = _remove_block(data)
        if not remaining and name in created:
            changes[name] = None
            created.discard(name)
        else:
            changes[name] = (remaining, stat.S_IMODE(items[name]["path"].stat().st_mode))
    for name, change in changes.items():
        path = items[name]["path"]
        if change is None:
            path.unlink()
        else:
            _atomic_write(path, change[0], change[1])
    new_state = {"created": sorted(created)}
    if new_state != state:
        _atomic_write_json(_state_path(home), new_state)
    return {"status": "removed" if changes else "absent", "removed": sorted(changes)}


def _print_result(result, as_json):
    if as_json:
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    else:
        print(result.get("status", "unknown"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", default=None, help="Codex home containing AGENTS.md")
    parser.add_argument("--template", default=None, help="flow-pilot-instructions.md path")
    parser.add_argument("--json", action="store_true", dest="as_json")
    parser.add_argument("command", choices=("install", "check", "uninstall"))
    args = parser.parse_args(argv)
    home = Path(args.codex_home).expanduser() if args.codex_home else default_codex_home()
    try:
        if args.command == "install":
            template = Path(args.template).expanduser() if args.template else default_template(home)
            result = install(home, template)
            _print_result(result, args.as_json)
            return 0
        if args.command == "check":
            template = Path(args.template).expanduser() if args.template else default_template(home)
            result = check(home, template)
            _print_result(result, args.as_json)
            return 0 if result["status"] == "installed" else 1
        result = uninstall(home)
        _print_result(result, args.as_json)
        return 0
    except InstructionError as exc:
        result = {"status": "error", "error": str(exc)}
        _print_result(result, args.as_json)
        return 2
    except OSError as exc:
        result = {"status": "error", "error": str(exc)}
        _print_result(result, args.as_json)
        return 2


if __name__ == "__main__":
    sys.exit(main())
