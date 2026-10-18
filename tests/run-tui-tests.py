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
import time
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


def fake_run_cli_stream(args, emit, should_cancel, timeout: int = 900) -> tuple[int, str]:
    CLI_CALLS.append(args)
    if args == ["fluid"]:
        emit("FLUIDE SIMULÉ : action longue en cours")
        for _ in range(100):
            if should_cancel():
                return 130, "FLUIDE SIMULÉ : annulé"
            time.sleep(0.05)
        return 0, "FLUIDE SIMULÉ : terminé"
    output = "SORTIE SIMULÉE " + " ".join(args)
    emit(output)
    return 0, output


REAL_RUN_CLI_STREAM = mod.run_cli_stream
mod.run_cli_stream = fake_run_cli_stream
mod.running_as_root = lambda: True

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


async def wait_output_finished(pilot, app) -> None:
    await wait_until(
        pilot,
        lambda: app.screen.__class__.__name__ == "OutputScreen" and not app.action_running,
        "output action finished",
    )


async def main() -> None:
    stream_script = TMP / "fake-ola"
    stream_script.write_text(
        "#!/bin/sh\nprintf 'ligne 1\\n'\nprintf 'ligne 2\\n'\nprintf 'progression\\r'\nsleep 10\n",
        encoding="utf-8",
    )
    stream_script.chmod(0o755)
    original_cli = mod.CLI
    mod.CLI = str(stream_script)
    streamed: list[str] = []
    stream_started = time.monotonic()
    try:
        code, _output = await asyncio.to_thread(
            REAL_RUN_CLI_STREAM,
            ["test"],
            streamed.append,
            lambda: time.monotonic() - stream_started > 0.5,
            5,
        )
    finally:
        mod.CLI = original_cli
    assert code == 130, code
    assert streamed[:3] == ["ligne 1", "ligne 2", "progression"], streamed
    assert time.monotonic() - stream_started < 5
    print("PASS: real CLI streaming and process-group cancellation")

    app = mod.OlaTui()
    async with app.run_test(size=(120, 38)) as pilot:
        await wait_until(pilot, lambda: app.query_one("#models").row_count == 2, "model rows")
        assert app.selected_model_name() == "qwen3:1.7b"
        print("PASS: initial table and default-last selection")

        summary_text = str(app.query_one("#summary").render())
        details_text = str(app.query_one("#details").render())
        assert "Services :" in summary_text
        assert "Swap :" in summary_text
        assert "Accès :" in summary_text
        assert "Capacités :" in details_text
        assert "Défaut ola : oui" in details_text
        rendered = app.export_screenshot().replace("\xa0", " ")
        for expected in ("Services", "Swap", "Accès", "Capacités", "Actions", "préchauffer", "bench"):
            assert expected in rendered, f"Missing visible panel text at 120x38: {expected}"
        print("PASS: summary and details essentials are visible at 120x38")

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
        await wait_output_finished(pilot, app)
        await pilot.press("q")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "OutputScreen",
            "output screen close",
        )

        await pilot.press("u")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "ConfirmScreen",
            "use confirmation",
        )
        assert app.focused is not None and app.focused.id == "cancel"
        assert app.screen.query_one("#confirm").variant == "primary"
        await pilot.press("enter")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "ConfirmScreen",
            "use cancellation by Enter",
        )
        assert not any(call[:1] == ["use"] for call in CLI_CALLS), CLI_CALLS
        print("PASS: confirmation focus starts on Cancel and Enter cancels use")

        await pilot.press("d")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "ConfirmScreen",
            "delete confirmation",
        )
        assert app.focused is not None and app.focused.id == "cancel"
        assert app.screen.query_one("#confirm").variant == "error"
        await pilot.press("enter")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "ConfirmScreen",
            "delete cancellation by Enter",
        )
        assert not any(call[:1] == ["delete"] for call in CLI_CALLS), CLI_CALLS
        print("PASS: Enter on a fresh delete confirmation cancels safely")

        await pilot.press("d")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "ConfirmScreen",
            "delete confirmation reopened",
        )
        await pilot.click("#confirm")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "OutputScreen",
            "confirmed deletion output",
        )
        assert CLI_CALLS[-1] == ["delete", "llama3.2:1b"], CLI_CALLS
        print("PASS: explicit confirmation still executes deletion")
        await wait_output_finished(pilot, app)
        await pilot.press("q")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "OutputScreen",
            "delete output close",
        )

        await pilot.press("w")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "ConfirmScreen",
            "warm confirmation",
        )
        assert app.focused is not None and app.focused.id == "cancel"
        await pilot.press("enter")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "ConfirmScreen",
            "warm cancellation",
        )
        assert not any(call[:2] == ["fluid", "warm"] for call in CLI_CALLS), CLI_CALLS
        await pilot.press("w")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "ConfirmScreen",
            "warm confirmation reopened",
        )
        await pilot.click("#confirm")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "OutputScreen",
            "warm output",
        )
        assert CLI_CALLS[-1] == ["fluid", "warm", "llama3.2:1b"], CLI_CALLS
        print("PASS: warm asks before changing the loaded model")
        await wait_output_finished(pilot, app)
        await pilot.press("q")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "OutputScreen",
            "warm output close",
        )

        await pilot.press("l")
        await pilot.pause()
        await asyncio.sleep(0.1)
        assert app.screen.__class__.__name__ != "ConfirmScreen"
        assert not any(call[:1] == ["unload"] for call in CLI_CALLS), CLI_CALLS
        print("PASS: unload on a disk-only model does not call the CLI")

        await pilot.press("down")
        await wait_until(
            pilot, lambda: app.selected_model_name() == "qwen3:1.7b", "loaded model selection"
        )
        await pilot.press("l")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "ConfirmScreen",
            "unload confirmation",
        )
        await pilot.press("enter")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "ConfirmScreen",
            "unload cancellation",
        )
        assert not any(call[:1] == ["unload"] for call in CLI_CALLS), CLI_CALLS
        await pilot.press("l")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "ConfirmScreen",
            "unload confirmation reopened",
        )
        await pilot.click("#confirm")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "OutputScreen",
            "unload output",
        )
        assert CLI_CALLS[-1] == ["unload", "qwen3:1.7b"], CLI_CALLS
        print("PASS: unload asks before freeing a loaded model")
        await wait_output_finished(pilot, app)
        await pilot.press("q")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "OutputScreen",
            "unload output close",
        )

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
        await wait_output_finished(pilot, app)
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

        await pilot.press("?")
        await wait_until(
            pilot, lambda: app.screen.__class__.__name__ == "HelpScreen", "help screen"
        )
        await pilot.press("q")
        await wait_until(
            pilot, lambda: app.screen.__class__.__name__ != "HelpScreen", "help close"
        )
        print("PASS: help screen")

        await pilot.press("m")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "ActionMenuScreen",
            "action menu",
        )
        await pilot.press("escape")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "ActionMenuScreen",
            "action menu close",
        )
        print("PASS: action menu screen")

        await pilot.press("f")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ == "OutputScreen"
            and bool(getattr(app.screen, "running", False)),
            "streaming fluid output",
        )
        assert CLI_CALLS[-1] == ["fluid"], CLI_CALLS
        await pilot.press("q")
        await wait_until(pilot, lambda: not app.action_running, "fluid cancellation")
        assert app.screen.__class__.__name__ == "OutputScreen"
        assert getattr(app.screen, "finished_code", None) == 130
        print("PASS: live output can be cancelled with q")
        await pilot.press("q")
        await wait_until(
            pilot,
            lambda: app.screen.__class__.__name__ != "OutputScreen",
            "cancelled output close",
        )

        await pilot.press("q")

    mod.fetch_snapshot = lambda: mod.Snapshot(
        api_ok=True,
        version="0.40.6",
        models=[],
        default_model="qwen3:1.7b",
        public_url="",
        speed_mode="balanced",
        keepalive="5m",
        services={},
        cloudflared_ready=None,
        mem_total=2_000_000_000,
        mem_available=1_000_000_000,
        swap_total=0,
        swap_free=0,
    )
    empty_app = mod.OlaTui()
    async with empty_app.run_test(size=(120, 38)) as pilot:
        await wait_until(
            pilot,
            lambda: empty_app.query_one("#models").row_count == 1,
            "initial empty-state row",
        )
        assert empty_app.selected_model_name() == ""
        details_text = str(empty_app.query_one("#details").render())
        assert "Aucun modèle téléchargé." in details_text
        assert "Touche a : ajouter et utiliser un modèle." in details_text
        rendered = empty_app.export_screenshot().replace("\xa0", " ").replace("&#160;", " ")
        assert "Aucun" in rendered
        print("PASS: initial empty state is visible and actionable")
        await pilot.press("q")

    mod.fetch_snapshot = lambda: mod.Snapshot(
        api_ok=True,
        version="0.40.6",
        models=[
            mod.ModelInfo(name="llama3.2:1b", size=1_000_000_000, loaded=True, loaded_size=1_100_000_000),
            mod.ModelInfo(name="qwen3:1.7b", size=1_400_000_000),
        ],
        default_model="qwen3:1.7b",
        public_url="https://ollama.example.com",
        speed_mode="balanced",
        keepalive="5m",
        services={},
        cloudflared_ready=200,
        mem_total=2_000_000_000,
        mem_available=1_000_000_000,
        swap_total=0,
        swap_free=0,
    )
    loaded_app = mod.OlaTui()
    async with loaded_app.run_test(size=(120, 38)) as pilot:
        await wait_until(
            pilot,
            lambda: loaded_app.query_one("#models").row_count == 2,
            "loaded-first model rows",
        )
        assert loaded_app.selected_model_name() == "llama3.2:1b"
        print("PASS: initial selection prefers the loaded model over the default")
        await pilot.press("q")

    CLI_CALLS.clear()
    mod.running_as_root = lambda: False
    nonroot_app = mod.OlaTui()
    async with nonroot_app.run_test(size=(120, 38)) as pilot:
        await wait_until(
            pilot,
            lambda: nonroot_app.query_one("#models").row_count == 2,
            "non-root model rows",
        )
        await pilot.press("u")
        await pilot.pause()
        await asyncio.sleep(0.1)
        assert nonroot_app.screen.__class__.__name__ != "ConfirmScreen"
        assert not any(call[:1] == ["use"] for call in CLI_CALLS), CLI_CALLS
        print("PASS: protected actions are refused before confirmation in non-root mode")
        await pilot.press("q")
    mod.running_as_root = lambda: True

    dynamic_app = mod.OlaTui()
    async with dynamic_app.run_test(size=(120, 38)) as pilot:
        await wait_until(
            pilot,
            lambda: dynamic_app.query_one("#models").row_count == 2,
            "dynamic resize model rows",
        )
        await pilot.resize_terminal(80, 24)
        await wait_until(
            pilot,
            lambda: "responsive-compact" in dynamic_app.screen.classes
            and dynamic_app.query_one("#models").region.height >= 10,
            "dynamic compact resize",
        )
        await pilot.resize_terminal(60, 20)
        await wait_until(
            pilot,
            lambda: "responsive-minimal" in dynamic_app.screen.classes
            and dynamic_app.query_one("#models").region.height >= 15,
            "dynamic minimal resize",
        )
        print("PASS: responsive layout follows live terminal resizing")
        await pilot.press("q")

    for size, expected_class, min_table_height in (
        ((80, 24), "responsive-compact", 10),
        ((60, 20), "responsive-minimal", 15),
    ):
        responsive_app = mod.OlaTui()
        async with responsive_app.run_test(size=size) as pilot:
            await wait_until(
                pilot,
                lambda: responsive_app.query_one("#models").row_count == 2,
                f"responsive rows at {size}",
            )
            assert expected_class in responsive_app.screen.classes
            table_height = responsive_app.query_one("#models").region.height
            assert table_height >= min_table_height, (size, table_height)
            print(f"PASS: responsive {expected_class} layout at {size[0]}x{size[1]}")
            await pilot.press("q")

    print("ALL TUI PILOT TESTS PASS")


if __name__ == "__main__":
    asyncio.run(main())
