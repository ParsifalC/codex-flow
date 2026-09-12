#!/usr/bin/env python3
"""Build and package setup for codex-flow."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from setuptools import setup
from setuptools.command.build_py import build_py as _build_py

ROOT = Path(__file__).resolve().parent

DATA_FILES = [
    "VERSION",
    "LICENSE",
    "README.md",
    "README.en.md",
    "install.sh",
    "install.ps1",
    "install-release.sh",
    "install-release.ps1",
    "smithery.yaml",
    "glama.json",
]

DATA_DIRS = [
    "scripts",
    "policy",
    "templates",
    "completions",
    "benchmark",
    "apps/chatgpt-mcp",
    "apps/macos-overlay",
]


def get_version() -> str:
    version_file = ROOT / "VERSION"
    if version_file.exists():
        return version_file.read_text(encoding="utf-8").strip().lstrip("v")
    return "dev"


def _copy_clean_tree(src: Path, dst: Path) -> None:
    """Recursively copy directory excluding pycache and temp files."""
    dst.mkdir(parents=True, exist_ok=True)
    for root, dirs, files in os.walk(src):
        rel = Path(root).relative_to(src)
        target_dir = dst / rel
        target_dir.mkdir(parents=True, exist_ok=True)
        for f in files:
            if f.endswith((".pyc", ".pyo")) or f in {".DS_Store"}:
                continue
            src_file = Path(root) / f
            dst_file = target_dir / f
            shutil.copy2(src_file, dst_file)


class CustomBuildPy(_build_py):
    """Custom build_py that stages runtime data assets into codex_flow/data."""

    def run(self) -> None:
        super().run()
        data_target = Path(self.build_lib) / "codex_flow" / "data"
        data_target.mkdir(parents=True, exist_ok=True)

        for filename in DATA_FILES:
            src_file = ROOT / filename
            if src_file.exists():
                shutil.copy2(src_file, data_target / filename)

        for dirname in DATA_DIRS:
            src_dir = ROOT / dirname
            if src_dir.is_dir():
                _copy_clean_tree(src_dir, data_target / dirname)


long_description = ""
readme_file = ROOT / "README.md"
if readme_file.exists():
    long_description = readme_file.read_text(encoding="utf-8")

if __name__ == "__main__":
    setup(
        name="codex-flow",
        version=get_version(),
        description="Intelligent, Efficient, Adaptive Multi-Agent Strategy Orchestration for Codex",
        long_description=long_description,
        long_description_content_type="text/markdown",
        author="Parsifal",
        author_email="zmw@izmw.me",
        url="https://github.com/ParsifalC/codex-flow",
        project_urls={
            "Homepage": "https://github.com/ParsifalC/codex-flow",
            "Repository": "https://github.com/ParsifalC/codex-flow",
            "Issues": "https://github.com/ParsifalC/codex-flow/issues",
            "Documentation": "https://github.com/ParsifalC/codex-flow#readme",
        },
        license="MIT",
        package_dir={"codex_flow": "packaging/pypi"},
        packages=["codex_flow"],
        package_data={"codex_flow": ["data/**/*", "data/*"]},
        cmdclass={"build_py": CustomBuildPy},
        entry_points={
            "console_scripts": [
                "codex-flow=codex_flow.cli:main",
                "codex-flow-mcp=codex_flow.mcp:main",
            ]
        },
        python_requires=">=3.8",
        classifiers=[
            "Development Status :: 5 - Production/Stable",
            "Environment :: Console",
            "Intended Audience :: Developers",
            "License :: OSI Approved :: MIT License",
            "Operating System :: MacOS",
            "Operating System :: POSIX :: Linux",
            "Operating System :: Microsoft :: Windows",
            "Programming Language :: Python :: 3",
            "Programming Language :: Python :: 3.8",
            "Programming Language :: Python :: 3.9",
            "Programming Language :: Python :: 3.10",
            "Programming Language :: Python :: 3.11",
            "Programming Language :: Python :: 3.12",
            "Programming Language :: Python :: 3.13",
            "Topic :: Software Development :: Build Tools",
            "Topic :: Scientific/Engineering :: Artificial Intelligence",
        ],
    )
