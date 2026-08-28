#!/usr/bin/env python3
"""Run the repository's small pytest-style test functions without external packages."""

from __future__ import annotations

import importlib.util
import inspect
import io
import sys
import tempfile
import traceback
from contextlib import ExitStack, redirect_stdout
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
TEST_FILES = (
    ROOT / "tools" / "test_match_stats.py",
    ROOT / "tools" / "test_betting.py",
    ROOT / "tools" / "test_arbiter_ladder.py",
    ROOT / "tools" / "test_project_inventory.py",
    ROOT / "backend" / "test_generate.py",
)


def load_module(path: Path):
    for directory in (path.parent, ROOT / "tools", ROOT / "backend"):
        value = str(directory)
        if value not in sys.path:
            sys.path.insert(0, value)
    spec = importlib.util.spec_from_file_location(f"aib_test_{path.stem}", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CaptureFixture:
    def __init__(self):
        self.stdout = io.StringIO()

    def readouterr(self):
        value = self.stdout.getvalue()
        self.stdout.seek(0)
        self.stdout.truncate(0)
        return SimpleNamespace(out=value, err="")


def run_test(fn):
    params = inspect.signature(fn).parameters
    unknown = set(params) - {"tmp_path", "capsys"}
    if unknown:
        raise RuntimeError(f"unsupported test fixtures: {', '.join(sorted(unknown))}")
    kwargs = {}
    with ExitStack() as stack:
        if "tmp_path" in params:
            tmp = stack.enter_context(tempfile.TemporaryDirectory(prefix="aibattle-test-"))
            kwargs["tmp_path"] = Path(tmp)
        if "capsys" in params:
            capture = CaptureFixture()
            stack.enter_context(redirect_stdout(capture.stdout))
            kwargs["capsys"] = capture
        fn(**kwargs)


def main() -> int:
    total = 0
    failures = []
    for path in TEST_FILES:
        module = load_module(path)
        tests = sorted(
            (name, value)
            for name, value in vars(module).items()
            if name.startswith("test_") and callable(value)
        )
        for name, fn in tests:
            total += 1
            try:
                run_test(fn)
            except Exception:
                failures.append((f"{path.name}::{name}", traceback.format_exc()))

    if failures:
        for name, details in failures:
            print(f"[fail] {name}")
            print(details.rstrip())
        print(f"[fail] {len(failures)}/{total} tests failed")
        return 1

    print(f"[ok] {total} tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
