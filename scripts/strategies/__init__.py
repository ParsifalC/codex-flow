"""Built-in strategy registry for codex-flow."""
from __future__ import annotations

from .balanced import STRATEGY as BALANCED
from .base import StrategySpec
from .efficient import STRATEGY as EFFICIENT
from .quality import STRATEGY as QUALITY
from .speed import STRATEGY as SPEED

_REGISTRY: dict[str, StrategySpec] = {
    spec.name: spec
    for spec in (EFFICIENT, BALANCED, QUALITY, SPEED)
}


def names() -> tuple[str, ...]:
    return tuple(_REGISTRY)


def get(name: str) -> StrategySpec:
    try:
        return _REGISTRY[name]
    except KeyError as exc:
        raise ValueError(f"invalid strategy: {name}") from exc


def all_specs() -> tuple[StrategySpec, ...]:
    return tuple(_REGISTRY.values())
