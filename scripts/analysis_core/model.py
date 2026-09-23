"""Bounded Codex exec adapter used by the analysis queue."""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Sequence


OUTPUT_SCHEMAS = {
    "requirement": {
        "type": "object",
        "additionalProperties": False,
        "required": ["text", "caveats"],
        "properties": {
            "text": {"type": "string", "minLength": 1, "maxLength": 48},
            "caveats": {"type": "array", "items": {"type": "string"}},
        },
    },
    "summary": {
        "type": "object",
        "additionalProperties": False,
        "required": ["text", "caveats"],
        "properties": {
            "text": {"type": "string", "minLength": 1, "maxLength": 80},
            "caveats": {"type": "array", "items": {"type": "string"}},
        },
    },
    "skill": {
        "type": "object",
        "additionalProperties": False,
        "required": ["name", "description", "markdown", "caveats"],
        "properties": {
            "name": {"type": "string", "minLength": 1, "maxLength": 120},
            "description": {"type": "string", "minLength": 1, "maxLength": 1000},
            "markdown": {"type": "string", "minLength": 1, "maxLength": 20000},
            "caveats": {"type": "array", "items": {"type": "string"}},
        },
    },
}


NEED_TEXT_LIMITS = {"turn_goal": 40, "better_prompt": 240, "next_step": 80}
NEED_LIST_FIELDS = ("evidence", "conflicts", "gaps")
for field, limit in NEED_TEXT_LIMITS.items():
    OUTPUT_SCHEMAS["requirement"]["properties"][field] = {"type": "string", "minLength": 1, "maxLength": limit}
for field in NEED_LIST_FIELDS:
    OUTPUT_SCHEMAS["requirement"]["properties"][field] = {"type": "array", "maxItems": 2, "items": {"type": "string", "maxLength": 120}}
OUTPUT_SCHEMAS["requirement"]["required"] += list(NEED_TEXT_LIMITS) + list(NEED_LIST_FIELDS)


def normalize_skill(result: Dict[str, Any]) -> Dict[str, Any]:
    """Generate YAML metadata from validated structured fields, never model indentation."""
    value = dict(result)
    name = re.sub(r"[^a-z0-9-]+", "-", str(value.get("name", "")).lower()).strip("-")[:64].rstrip("-") or "conversation-skill"
    description = str(value.get("description", ""))
    body = str(value.get("markdown", "")).replace("\r\n", "\n").lstrip()
    body = re.sub(r"\A---[ \t]*\n.*?\n---[ \t]*(?:\n|$)", "", body, count=1, flags=re.DOTALL).lstrip()
    value["name"] = name
    value["markdown"] = "---\nname: %s\ndescription: %s\n---\n\n%s" % (json.dumps(name, ensure_ascii=False), json.dumps(description, ensure_ascii=False), body)
    return value


class ModelError(RuntimeError):
    """A safe model boundary failure; raw model output is never included."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def _safe_mode(path: Path, mode: int) -> None:
    try:
        os.chmod(str(path), mode)
    except OSError:
        pass


class CodexExecRunner:
    """Run one finite, isolated ``codex exec`` request."""

    def __init__(
        self,
        state_dir: Path,
        model: str,
        *,
        auth_home: Optional[Path] = None,
        codex_bin: str = "codex",
        timeout: float = 90.0,
        process_factory: Callable[..., Any] = subprocess.Popen,
    ):
        self.state_dir = Path(state_dir).expanduser().resolve()
        self.model = model
        self.auth_home = Path(auth_home).expanduser().resolve() if auth_home else None
        self.codex_bin = codex_bin
        self.timeout = timeout
        self.process_factory = process_factory
        self.private_dir = self.state_dir / "private"
        self.codex_home = self.private_dir / "codex-home"
        self.empty_cwd = self.private_dir / "empty-cwd"
        self.schema_dir = self.private_dir / "schemas"
        self._prepare_private_home()

    def _prepare_private_home(self) -> None:
        for directory in (self.private_dir, self.codex_home, self.empty_cwd, self.schema_dir):
            directory.mkdir(parents=True, exist_ok=True)
            _safe_mode(directory, 0o700)
        if self.auth_home and self.auth_home.is_dir():
            source = self.auth_home / "auth.json"
            target = self.codex_home / "auth.json"
            if source.is_file() and not target.exists():
                shutil.copy2(str(source), str(target))
            if target.exists():
                _safe_mode(target, 0o600)
            for cache_name in ("models_cache.json", "models_cache"):
                source_cache = self.auth_home / cache_name
                target_cache = self.codex_home / cache_name
                if source_cache.is_file() and not target_cache.exists():
                    shutil.copy2(str(source_cache), str(target_cache))
                elif source_cache.is_dir() and not target_cache.exists():
                    shutil.copytree(str(source_cache), str(target_cache))
                if target_cache.exists():
                    _safe_mode(target_cache, 0o600 if target_cache.is_file() else 0o700)
        config = self.codex_home / "config.toml"
        if not config.exists():
            config.write_text(
                """[features]
hooks = false
plugins = false
apps = false
shell_tool = false
unified_exec = false
code_mode_host = false
multi_agent = false
browser_use = false
computer_use = false
image_generation = false
skill_search = false
workspace_dependencies = false
sleep_tool = false
skip_host_skill_discovery = true
web_search = "disabled"
""",
                encoding="utf-8",
            )
            _safe_mode(config, 0o600)

    def _schema_path(self, kind: str) -> Path:
        path = self.schema_dir / (kind + ".json")
        schema = json.dumps(OUTPUT_SCHEMAS[kind], sort_keys=True)
        if not path.exists() or path.read_text(encoding="utf-8") != schema:
            path.write_text(schema, encoding="utf-8")
            _safe_mode(path, 0o600)
        return path

    def _argv(self, kind: str) -> Sequence[str]:
        argv = [
            self.codex_bin,
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--sandbox",
            "read-only",
            "--json",
            "--output-schema",
            str(self._schema_path(kind)),
            "--thread-source",
            "background-analysis",
            "--skip-git-repo-check",
            "--cd",
            str(self.empty_cwd),
            "--model",
            self.model,
        ]
        settings = (
            "features.hooks=false",
            "features.plugins=false",
            "features.apps=false",
            "features.shell_tool=false",
            "features.unified_exec=false",
            "features.code_mode_host=false",
            "features.multi_agent=false",
            "features.browser_use=false",
            "features.computer_use=false",
            "features.image_generation=false",
            "features.skill_search=false",
            "features.workspace_dependencies=false",
            "features.sleep_tool=false",
            "features.skip_host_skill_discovery=true",
            'web_search="disabled"',
            'model_reasoning_effort="low"',
        )
        # Keep settings as argv values so no shell can reinterpret them and
        # --ignore-user-config cannot re-enable parent-host capabilities.
        for setting in settings:
            argv.extend(("-c", setting))
        argv.append("-")
        return argv

    def _kill_process_group(self, process: Any) -> None:
        pid = getattr(process, "pid", None)
        if pid and hasattr(os, "killpg"):
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
                return
            except OSError:
                pass
        kill = getattr(process, "kill", None)
        if callable(kill):
            try:
                kill()
            except OSError:
                pass

    def _terminate_and_reap(self, process: Any) -> None:
        self._kill_process_group(process)
        try:
            process.wait()
        except BaseException:
            pass
        for stream_name in ("stdin", "stdout", "stderr"):
            stream = getattr(process, stream_name, None)
            close = getattr(stream, "close", None)
            if callable(close):
                try:
                    close()
                except Exception:
                    pass
    def run(self, kind: str, prompt: str) -> Dict[str, Any]:
        if kind not in OUTPUT_SCHEMAS:
            raise ModelError("invalid_kind")
        if not isinstance(prompt, str):
            raise ModelError("invalid_prompt")
        env = os.environ.copy()
        env["CODEX_HOME"] = str(self.codex_home)
        env["CODEX_FLOW_ANALYSIS"] = "1"
        try:
            process = self.process_factory(
                list(self._argv(kind)),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=str(self.empty_cwd),
                env=env,
                text=True,
                encoding="utf-8",
                errors="replace",
                start_new_session=True,
            )
        except OSError:
            raise ModelError("process_start_failed") from None
        try:
            stdout, _stderr = process.communicate(input=prompt, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            self._terminate_and_reap(process)
            raise ModelError("timeout") from None
        except (KeyboardInterrupt, SystemExit):
            self._terminate_and_reap(process)
            raise
        except Exception:
            self._terminate_and_reap(process)
            raise ModelError("process_io_failed") from None
        if getattr(process, "returncode", 0) != 0:
            raise ModelError("process_failed")
        value = self._parse_output(stdout, kind)
        return value

    def _parse_output(self, stdout: Any, kind: str) -> Dict[str, Any]:
        if isinstance(stdout, bytes):
            try:
                stdout = stdout.decode("utf-8")
            except UnicodeDecodeError:
                raise ModelError("invalid_output") from None
        if not isinstance(stdout, str):
            raise ModelError("invalid_output")
        candidates = []
        for line in stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except (ValueError, RecursionError):
                continue
            candidates.append(value)
        for value in reversed(candidates):
            direct = value
            if isinstance(value, dict):
                for key in ("result", "output", "structured_output"):
                    nested = value.get(key)
                    if isinstance(nested, dict):
                        direct = nested
                        break
                if direct is value and value.get("type") in ("item.completed", "item.updated"):
                    item = value.get("item")
                    if isinstance(item, dict):
                        nested = item.get("structured_output", item.get("output"))
                        if isinstance(nested, dict):
                            direct = nested
                        else:
                            text = item.get("text")
                            if isinstance(text, str):
                                try:
                                    nested = json.loads(text)
                                except (ValueError, RecursionError):
                                    nested = None
                                if isinstance(nested, dict):
                                    direct = nested
            if isinstance(direct, dict) and self._valid_result(direct, kind):
                return self._clean_result(direct, kind)
        try:
            whole = json.loads(stdout.strip())
        except (ValueError, RecursionError):
            whole = None
        if isinstance(whole, dict) and self._valid_result(whole, kind):
            return self._clean_result(whole, kind)
        raise ModelError("invalid_output")

    def _valid_result(self, value: Dict[str, Any], kind: str) -> bool:
        if kind in ("requirement", "summary"):
            if kind == "requirement":
                if not all(isinstance(value.get(key), str) and value[key].strip() and len(value[key]) <= limit
                           for key, limit in NEED_TEXT_LIMITS.items()):
                    return False
                if not all(isinstance(value.get(key), list) and len(value[key]) <= 2 and
                           all(isinstance(item, str) and len(item) <= 120 for item in value[key])
                           for key in NEED_LIST_FIELDS):
                    return False
            return (
                isinstance(value.get("text"), str)
                and bool(value["text"].strip())
                and len(value["text"]) <= (48 if kind == "requirement" else 80)
                and isinstance(value.get("caveats"), list)
                and all(isinstance(item, str) for item in value["caveats"])
            )
        return (
            all(isinstance(value.get(key), str) and bool(value[key].strip()) for key in ("name", "description", "markdown"))
            and len(value["name"]) <= 120
            and len(value["description"]) <= 1000
            and len(value["markdown"]) <= 20000
            and isinstance(value.get("caveats"), list)
            and all(isinstance(item, str) for item in value["caveats"])
        )

    def _clean_result(self, value: Dict[str, Any], kind: str) -> Dict[str, Any]:
        if kind in ("requirement", "summary"):
            result: Dict[str, Any] = {"text": value["text"], "caveats": list(value["caveats"])}
            if kind == "requirement":
                result.update({key: value[key] for key in list(NEED_TEXT_LIMITS) + list(NEED_LIST_FIELDS)})
            return result
        result = {key: value[key] for key in ("name", "description", "markdown")}
        result["caveats"] = list(value["caveats"])
        return normalize_skill(result)
