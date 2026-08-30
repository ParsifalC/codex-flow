#!/usr/bin/env python3
"""Check OpenAI official model docs and update codex-flow recommendations.

Fail-closed by design: if the official pages cannot be parsed or required
capabilities cannot be verified, no policy file is modified.
"""
from __future__ import annotations

import argparse
import html
import json
import re
import sys
import urllib.request
from dataclasses import dataclass, asdict
from pathlib import Path

MODELS_URL = "https://developers.openai.com/api/docs/models"
MODEL_URL = "https://developers.openai.com/api/docs/models/{model}"
MODEL_RE = re.compile(r"gpt-(\d+)\.(\d+)-(sol|terra|luna)", re.I)


@dataclass(frozen=True)
class ModelInfo:
    model: str
    major: int
    minor: int
    tier: str
    input_price: float
    cached_input_price: float
    output_price: float
    supports_high: bool
    supports_xhigh: bool
    supports_max: bool
    supports_agent_tools: bool

    @property
    def family(self) -> tuple[int, int]:
        return self.major, self.minor

    @property
    def worker_cost_score(self) -> float:
        # Implementation loops typically combine large input context with output.
        # Keep the score simple and transparent; this is a ranking heuristic, not
        # an estimate of a user's bill.
        return 0.7 * self.input_price + 0.3 * self.output_price


def fetch(url: str) -> str:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "codex-flow-recommendation-bot/0.3"},
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        return response.read().decode(charset, errors="replace")


def visible_text(raw: str) -> str:
    # The docs are server-rendered today, but this intentionally tolerates
    # additional markup. Scripts/styles are removed before whitespace folding.
    raw = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", raw)
    raw = re.sub(r"(?s)<[^>]+>", " ", raw)
    return re.sub(r"\s+", " ", html.unescape(raw)).strip()


def discover_models(index_raw: str) -> list[str]:
    found: dict[str, tuple[int, int, str]] = {}
    for match in MODEL_RE.finditer(index_raw):
        major, minor, tier = int(match.group(1)), int(match.group(2)), match.group(3).lower()
        model = f"gpt-{major}.{minor}-{tier}"
        found[model] = (major, minor, tier)
    return sorted(found)


def parse_model(model: str, raw: str) -> ModelInfo:
    m = MODEL_RE.fullmatch(model)
    if not m:
        raise ValueError(f"unsupported model id: {model}")
    major, minor, tier = int(m.group(1)), int(m.group(2)), m.group(3).lower()
    text = visible_text(raw)

    effort_match = re.search(
        r"Reasoning(?:\.effort)?\s+supports:?\s*(.{0,180})",
        text,
        re.I,
    )
    efforts = effort_match.group(1).lower() if effort_match else ""

    price_match = re.search(
        r"Text tokens.*?Input\s*\$([0-9]+(?:\.[0-9]+)?)"
        r".*?Cached input\s*\$([0-9]+(?:\.[0-9]+)?)"
        r".*?Output\s*\$([0-9]+(?:\.[0-9]+)?)",
        text,
        re.I,
    )
    if not price_match:
        raise ValueError(f"could not parse token pricing for {model}")

    # A coding worker must expose modern agent/tool surfaces. Either marker is
    # accepted so minor docs wording changes do not cause false negatives.
    supports_agent_tools = bool(
        re.search(r"\b(?:Apply patch|Hosted shell|Skills)\b", text, re.I)
    )

    return ModelInfo(
        model=model,
        major=major,
        minor=minor,
        tier=tier,
        input_price=float(price_match.group(1)),
        cached_input_price=float(price_match.group(2)),
        output_price=float(price_match.group(3)),
        supports_high="high" in efforts,
        supports_xhigh="xhigh" in efforts,
        supports_max="max" in efforts,
        supports_agent_tools=supports_agent_tools,
    )


def choose(models: list[ModelInfo]) -> tuple[ModelInfo, ModelInfo]:
    qualifying = [
        m
        for m in models
        if m.supports_high and m.supports_xhigh and m.supports_max and m.supports_agent_tools
    ]
    if not qualifying:
        raise ValueError("no model satisfies the reasoning/tool capability floor")

    families = sorted({m.family for m in qualifying}, reverse=True)
    for family in families:
        same_family = [m for m in qualifying if m.family == family]
        parents = [m for m in same_family if m.tier == "sol"]
        workers = [m for m in same_family if m.tier in {"luna", "terra"}]
        if parents and workers:
            parent = parents[0]
            worker = min(workers, key=lambda m: (m.worker_cost_score, m.output_price, m.input_price))
            return parent, worker
    raise ValueError("latest qualifying family lacks both flagship and efficient worker tiers")


def replace_toml_value(text: str, section: str, key: str, value: str) -> str:
    pattern = re.compile(
        rf"(?ms)(^\[{re.escape(section)}\]\s*$)(.*?)(?=^\[[^\n]+\]\s*$|\Z)"
    )
    match = pattern.search(text)
    if not match:
        raise ValueError(f"missing [{section}] section")
    body = match.group(2)
    line_re = re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$")
    new_line = f'{key} = "{value}"'
    if line_re.search(body):
        body = line_re.sub(new_line, body)
    else:
        if body and not body.endswith("\n"):
            body += "\n"
        body += new_line + "\n"
    return text[: match.start(2)] + body + text[match.end(2) :]


def write_defaults(path: Path, parent: ModelInfo, worker: ModelInfo) -> bool:
    original = path.read_text()
    updated = original
    updated = replace_toml_value(updated, "models", "parent_recommended_model", parent.model)
    updated = replace_toml_value(updated, "models", "worker_model", worker.model)
    if updated == original:
        return False
    path.write_text(updated)
    return True


def load_fixture(path: Path) -> tuple[str, dict[str, str]]:
    payload = json.loads(path.read_text())
    return payload["index"], payload["models"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--defaults", default="policy/defaults.toml")
    parser.add_argument("--fixture", help="offline JSON fixture used by tests")
    parser.add_argument("--write", action="store_true", help="update policy/defaults.toml when changed")
    parser.add_argument("--json", action="store_true", help="emit machine-readable result")
    args = parser.parse_args()

    try:
        if args.fixture:
            index_raw, fixture_models = load_fixture(Path(args.fixture))
            fetch_model = lambda model: fixture_models[model]
        else:
            index_raw = fetch(MODELS_URL)
            fetch_model = lambda model: fetch(MODEL_URL.format(model=model))

        discovered = discover_models(index_raw)
        if not discovered:
            raise ValueError("no Sol/Terra/Luna model ids discovered from official model index")

        parsed = []
        for model in discovered:
            try:
                parsed.append(parse_model(model, fetch_model(model)))
            except (KeyError, ValueError, urllib.error.URLError) as exc:
                print(f"warning: skipping {model}: {exc}", file=sys.stderr)

        parent, worker = choose(parsed)
        result = {
            "parent_recommended_model": parent.model,
            "worker_model": worker.model,
            "worker_cost_score": round(worker.worker_cost_score, 6),
            "worker_input_price": worker.input_price,
            "worker_cached_input_price": worker.cached_input_price,
            "worker_output_price": worker.output_price,
            "source": MODELS_URL,
        }

        changed = False
        if args.write:
            changed = write_defaults(Path(args.defaults), parent, worker)
        result["changed"] = changed

        if args.json:
            print(json.dumps(result, sort_keys=True))
        else:
            print(f"parent recommendation: {parent.model}")
            print(
                f"worker recommendation: {worker.model} "
                f"(${worker.input_price:g} input / ${worker.output_price:g} output per 1M)"
            )
            print("defaults changed" if changed else "defaults already current")
        return 0
    except Exception as exc:
        print(f"recommendation check failed closed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
