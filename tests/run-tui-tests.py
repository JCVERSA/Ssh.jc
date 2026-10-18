#!/usr/bin/env python3
"""Headless Textual pilot tests for tui/ola_tui.py.

Run with a Python interpreter that has Textual installed, for example:
OLA_TUI_TEST_PYTHON=/path/to/venv/bin/python tests/run-tests.sh
"""

from __future__ import annotations

import asyncio
import importlib.util
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ola_tui", ROOT / "tui" / "ola_tui.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load tui/ola_tui.py")
mod = importlib.util.module_from_spec(SPEC)
sys.modules["ola_tui"] = mod
SPEC.loader.exec_module(mod)


def fake_snapshot() -> object:
    return mod.Snapshot(
        api_ok=True,
        version="0.40.6",
        models=[
            mod.ModelInfo(name="llama3.2:1b", size=1_000_000_000, parameter_size="1B"),
            mod.ModelInfo(
                name="qwen3:1.7b",
                size=1_400_000_000,
                loaded=True,
                loaded_size=1_500_000_000,
                expires_at="2030-01-01T00:00:00Z",
                context_length=1024,
                parameter_size="1.7B",
            ),
        ],
        default_model="qwen3:1.7b",
        public_url="https://ollama.example.com",
        speed_mode="speed",
        keepalive="5m",
        services={
            "ollama": "RUNNING",
            "cloudflared-ollama": "RUNNING",
            "ollama-watchdog": "RUNNING",
        },
        cloudflared_ready=200,
        mem_total=2_000_000_000,
        mem_available=500_000_000,
        swap_total=500_000_000,
        swap_free=400_000_000,
    )


mod.fetch_snapshot = fake_snapshot
mod.fetch_show = lambda _model: {
    "details": {
        "parameter_size": "1.7B",
        "family": "qwen3",
        "quantization_level": "Q4_K_M",
    },
    "capabilities": ["completion", "thinking"],
}

CLI_CALLS: list[list[str]] = []


def fake_run_cli(args: list[str], timeout: int = 900) -> tuple[int, str]:
    CLI_CALLS.append(args)
    return 0, "SORTIE SIMULÉE " + " ".join(args)


mod.run_cli = fake_run_cli

TMP = Path(tempfile.mkdtemp(prefix="ola-tui-tests-"))
LOG_PATH = TMP / "test.log"
LOG_PATH.write_text("ligne de journal 1\nligne de journal 2\n", encoding="utf-8")
mod.LOG_FILES = [("Test", LOG_PATH)]


async def wait_until(pilot, predicate, label: str) -> None:
    for _ in range(120):
        await pilot.pause()
        await asyncio.sleep(0.02)
        if predicate():
            return
    raise AssertionError(f"Timeout: {label}")


async def main() -> None:
    app = mod.OlaTui()
    async with app.run_test(size=(130, 42)) as pilot:
        await wait_until(pilot, lambda: app.query_one("#models").row_count == 2, "model rows")
        assert app.selected_model_name() == "qwen3:1.7b"
        print("PASS: initial table and default-last selection")

        await pilot.press("up")
        await wait_until(
            pilot, lambda: app.selected_model_name() == "llama3.2:1b", "keyboard selection"
        )
        print("PASS: keyboard navigation")

        await pilot.press("p")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "OutputScreen",
            "preset output screen",
        )
        assert CLI_CALLS[-1] == ["fluid", "preset", "llama3.2:1b"], CLI_CALLS
        print("PASS: preset action delegates to ola CLI")
        await app.refresh_snapshot(force=True)
        assert app.screen.__class__.__name__ == "OutputScreen"
        print("PASS: background refresh works while an output screen is open")
        await pilot.press("q")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "OutputScreen",
            "output screen close",
        )

        await pilot.press("d")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "ConfirmScreen",
            "delete confirmation",
        )
        await pilot.click("#cancel")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "ConfirmScreen",
            "delete cancellation",
        )
        assert not any(call[:1] == ["delete"] for call in CLI_CALLS), CLI_CALLS
        print("PASS: cancelled deletion does not call the CLI")

        await pilot.press("a")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "AddModelScreen",
            "add model screen",
        )
        await pilot.press(*"qwen3:0.6b")
        await pilot.press("enter")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "OutputScreen",
            "add model execution",
        )
        assert CLI_CALLS[-1] == ["use", "qwen3:0.6b"], CLI_CALLS
        print("PASS: add-model input accepts names containing q and delegates to ola use")
        await pilot.press("q")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "OutputScreen",
            "add output close",
        )

        await pilot.press("g")
        await wait_until(
            pilot, lambda: app.screen.__class__.__name__ == "LogsScreen", "logs screen"
        )
        await pilot.press("q")
        await wait_until(
            pilot, lambda: app.screen.__class__.__name__ != "LogsScreen", "logs close"
        )
        print("PASS: logs screen")

        before = app.theme
        await pilot.press("t")
        await pilot.pause()
        print(f"PASS: theme action ({before} -> {app.theme})")

        await pilot.press("q")

    print("ALL TUI PILOT TESTS PASS")


if __name__ == "__main__":
    asyncio.run(main())
