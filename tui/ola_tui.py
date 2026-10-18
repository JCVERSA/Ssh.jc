#!/usr/bin/env python3
"""Ola terminal interface (Textual).

The Bash ``ola`` program remains the engine and the safety boundary. This
application only reads the local Ollama HTTP API and delegates actions to the
installed ``ola`` CLI. It deliberately does not reimplement model deletion,
model switching, Supervisor management or Pack Speed/Fluidité logic.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import selectors
import shutil
import signal
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from rich.text import Text
from textual import events
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen, Screen
from textual.widgets import Button, DataTable, Footer, Header, Input, OptionList, RichLog, Static, TextArea
from textual.widgets.option_list import Option

API_URL = os.environ.get("OLA_TUI_API_URL", "http://127.0.0.1:11434").rstrip("/")
CLI = os.environ.get("OLA_TUI_CLI") or shutil.which("ola") or "/usr/local/bin/ola"
URL_FILE = Path("/etc/ollama-cloudflare-url")
MODEL_FILE = Path("/etc/ollama-cloudflare-model")
SPEED_FILE = Path("/etc/ollama-cloudflare-speed")
KEEPALIVE_FILE = Path("/etc/ollama-cloudflare-keepalive")
DEFAULT_MODEL = "qwen3:1.7b"
LOG_FILES = [
    ("Ollama", Path("/var/log/supervisor/ollama.log")),
    ("Ollama erreurs", Path("/var/log/supervisor/ollama-error.log")),
    ("cloudflared", Path("/var/log/supervisor/cloudflared-ollama.log")),
    ("cloudflared erreurs", Path("/var/log/supervisor/cloudflared-ollama-error.log")),
    ("Watchdog", Path("/var/log/supervisor/ollama-watchdog.log")),
]
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:@-]*$")
# Keep only a small set of framework themes with strong default contrast:
# a dark default, a dark blue variant and a light variant. The last choice
# is persisted per user in THEME_FILE.
THEME_CYCLE = [
    "textual-dark",
    "nord",
    "textual-light",
]
THEME_FILE = Path(
    os.environ.get(
        "OLA_TUI_THEME_FILE",
        str(Path.home() / ".config" / "ola-tui" / "theme"),
    )
)


def normalize_model(name: str) -> str:
    name = name.strip()
    last = name.rsplit("/", 1)[-1]
    return name if ":" in last else f"{name}:latest"


def valid_model(name: str) -> bool:
    return bool(MODEL_RE.fullmatch(name.strip()))


def running_as_root() -> bool:
    return hasattr(os, "geteuid") and os.geteuid() == 0


def display_model_name(name: str, limit: int) -> str:
    """Shorten a model name in the middle, keeping registry and tag visible."""
    if len(name) <= limit:
        return name
    keep = max(8, limit - 1)
    left = keep // 2
    right = keep - left
    return f"{name[:left]}…{name[-right:]}"


def dialog_classes(app: App) -> str:
    size = app.size
    compact = size.width < 72 or size.height < 24
    return "dialog compact" if compact else "dialog"


def read_first_line(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore").splitlines()[0].strip()
    except (OSError, IndexError):
        return ""


def format_bytes(value: Any) -> str:
    try:
        size = float(value or 0)
    except (TypeError, ValueError):
        return "inconnue"
    if size <= 0:
        return "inconnue"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return "inconnue"


def format_expiry(value: str) -> str:
    if not value:
        return "—"
    return value.replace("T", " ")[:19]


def load_saved_theme() -> str:
    try:
        name = THEME_FILE.read_text(encoding="utf-8").splitlines()[0].strip()
    except (OSError, IndexError):
        return "textual-dark"
    return name if name in THEME_CYCLE else "textual-dark"


def save_theme(name: str) -> None:
    if name not in THEME_CYCLE:
        return
    try:
        THEME_FILE.parent.mkdir(parents=True, exist_ok=True)
        THEME_FILE.write_text(f"{name}\n", encoding="utf-8")
    except OSError:
        # Theme persistence is a convenience; never fail the TUI for it.
        pass


def parse_expiry(value: str) -> datetime | None:
    if not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def format_expiry_relative(value: str, now: datetime | None = None) -> str:
    parsed = parse_expiry(value)
    if parsed is None:
        return "non définie"
    current = now or datetime.now(timezone.utc)
    seconds = int((parsed - current).total_seconds())
    if seconds <= 0:
        return "expirée"
    if seconds < 90:
        return f"dans {seconds} s"
    if seconds < 600:
        minutes, rest_seconds = divmod(seconds, 60)
        return f"dans {minutes} min {rest_seconds:02d} s"
    minutes = seconds // 60
    if minutes < 90:
        return f"dans {minutes} min"
    hours, rest_minutes = divmod(minutes, 60)
    if hours < 48:
        return f"dans {hours} h {rest_minutes:02d}" if rest_minutes else f"dans {hours} h"
    days = seconds // 86400
    if days < 730:
        return f"dans {days} j"
    years, remaining_days = divmod(days, 365)
    months = remaining_days // 30
    return f"dans {years} a {months} mo" if months else f"dans {years} a"


def format_expiry_details(value: str) -> str:
    parsed = parse_expiry(value)
    if parsed is None:
        return "non définie"
    local = parsed.astimezone()
    return (
        f"{format_expiry_relative(value)} · le "
        f"{local.strftime('%d/%m/%Y à %H:%M')} ({local.strftime('%Z')})"
    )


def http_json(path: str, payload: dict[str, Any] | None = None, timeout: float = 6) -> Any:
    data = None
    headers = {"Content-Type": "application/json"}
    method = "GET"
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        method = "POST"
    request = urllib.request.Request(
        f"{API_URL}{path}", data=data, headers=headers, method=method
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def http_status(url: str, timeout: float = 2) -> int | None:
    try:
        request = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return int(response.status)
    except urllib.error.HTTPError as exc:
        return int(exc.code)
    except (OSError, ValueError):
        return None


def parse_meminfo() -> dict[str, int]:
    values: dict[str, int] = {}
    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if ":" not in line:
                continue
            key, raw = line.split(":", 1)
            parts = raw.strip().split()
            if parts and parts[0].isdigit():
                values[key] = int(parts[0]) * 1024
    except OSError:
        pass
    return values


def supervisor_status() -> dict[str, str]:
    executable = shutil.which("supervisorctl")
    if not executable:
        return {}
    try:
        result = subprocess.run(
            [executable, "status"],
            text=True,
            capture_output=True,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    statuses: dict[str, str] = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            statuses[parts[0]] = parts[1]
    return statuses


@dataclass
class ModelInfo:
    name: str
    size: int = 0
    digest: str = ""
    family: str = ""
    parameter_size: str = ""
    quantization: str = ""
    loaded: bool = False
    loaded_size: int = 0
    expires_at: str = ""
    context_length: int | None = None


@dataclass
class Snapshot:
    api_ok: bool = False
    version: str = "inconnue"
    error: str = ""
    models: list[ModelInfo] = field(default_factory=list)
    default_model: str = DEFAULT_MODEL
    public_url: str = ""
    speed_mode: str = "balanced"
    keepalive: str = "5m"
    services: dict[str, str] = field(default_factory=dict)
    cloudflared_ready: int | None = None
    mem_total: int = 0
    mem_available: int = 0
    swap_total: int = 0
    swap_free: int = 0
    fetched_at: float = 0.0


def fetch_snapshot() -> Snapshot:
    snapshot = Snapshot()
    snapshot.default_model = read_first_line(MODEL_FILE) or DEFAULT_MODEL
    snapshot.public_url = read_first_line(URL_FILE)
    snapshot.speed_mode = read_first_line(SPEED_FILE) or "balanced"
    if snapshot.speed_mode not in {"balanced", "speed"}:
        snapshot.speed_mode = "balanced"
    snapshot.keepalive = read_first_line(KEEPALIVE_FILE) or "5m"

    mem = parse_meminfo()
    snapshot.mem_total = mem.get("MemTotal", 0)
    snapshot.mem_available = mem.get("MemAvailable", 0)
    snapshot.swap_total = mem.get("SwapTotal", 0)
    snapshot.swap_free = mem.get("SwapFree", 0)
    snapshot.services = supervisor_status()
    snapshot.cloudflared_ready = http_status("http://127.0.0.1:20241/ready")

    models: dict[str, ModelInfo] = {}
    try:
        version_data = http_json("/api/version", timeout=4)
        snapshot.version = str(version_data.get("version") or "inconnue")
        snapshot.api_ok = True
        tags = http_json("/api/tags", timeout=6)
        for item in tags.get("models") or []:
            name = str(item.get("name") or "")
            if not name:
                continue
            details = item.get("details") or {}
            models[name] = ModelInfo(
                name=name,
                size=int(item.get("size") or 0),
                digest=str(item.get("digest") or ""),
                family=str(details.get("family") or ""),
                parameter_size=str(details.get("parameter_size") or ""),
                quantization=str(details.get("quantization_level") or ""),
            )
        try:
            running = http_json("/api/ps", timeout=6)
            for item in running.get("models") or []:
                name = str(item.get("name") or "")
                if not name:
                    continue
                model = models.setdefault(name, ModelInfo(name=name))
                model.loaded = True
                model.loaded_size = int(item.get("size") or 0)
                model.expires_at = str(item.get("expires_at") or "")
                context = item.get("context_length")
                model.context_length = int(context) if context else None
        except Exception:
            # The model table remains useful with /api/tags alone.
            pass
    except Exception as exc:  # API down / malformed response
        snapshot.error = str(exc) or exc.__class__.__name__

    default_norm = normalize_model(snapshot.default_model)
    snapshot.models = sorted(
        models.values(),
        key=lambda model: (
            normalize_model(model.name) == default_norm,
            model.name.lower(),
        ),
    )
    snapshot.fetched_at = time.time()
    return snapshot


def fetch_show(model: str) -> dict[str, Any]:
    if not valid_model(model):
        return {}
    try:
        data = http_json("/api/show", {"model": model}, timeout=8)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _terminate_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
    except (OSError, ProcessLookupError):
        pass
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
    except (OSError, ProcessLookupError):
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def run_cli_stream(
    args: list[str],
    emit: Callable[[str], None] | None = None,
    should_cancel: Callable[[], bool] | None = None,
    timeout: int = 900,
) -> tuple[int, str]:
    """Run ola without a shell, streaming merged stdout/stderr line by line.

    The child runs in its own process group so cancellation from the TUI can
    stop the Bash CLI and the tools it launched (curl, ollama, ...).
    """
    if not CLI:
        return 127, "Commande ola introuvable."
    try:
        process = subprocess.Popen(
            [CLI, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
            start_new_session=True,
        )
    except FileNotFoundError:
        return 127, f"Commande ola introuvable : {CLI}"
    except OSError as exc:
        return 1, f"Impossible de lancer ola : {exc}"

    output: list[str] = []

    def push(text: str) -> None:
        output.append(text)
        if emit is not None:
            emit(text)

    if process.stdout is None:
        return 1, "Impossible de lire la sortie de ola."
    selector = selectors.DefaultSelector()
    try:
        selector.register(process.stdout, selectors.EVENT_READ)
        os.set_blocking(process.stdout.fileno(), False)
        buffer = b""
        started = time.monotonic()
        while True:
            if should_cancel is not None and should_cancel():
                _terminate_process(process)
                push("")
                push("Action annulée par l'utilisateur.")
                return 130, "\n".join(output).strip() or "(aucune sortie)"
            if time.monotonic() - started > timeout:
                _terminate_process(process)
                push("")
                push(f"Commande interrompue après {timeout} secondes.")
                return 124, "\n".join(output).strip() or "(aucune sortie)"

            events = selector.select(timeout=0.1)
            if events:
                chunk = os.read(process.stdout.fileno(), 4096)
                if chunk:
                    # Progress reporters often update with carriage returns
                    # instead of newlines; treat both as line boundaries so
                    # downloads are visible while they run.
                    buffer += chunk.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
                    while b"\n" in buffer:
                        raw, buffer = buffer.split(b"\n", 1)
                        push(raw.decode("utf-8", errors="replace").rstrip("\r"))
                elif process.poll() is not None:
                    break
            elif process.poll() is not None:
                break
        if buffer:
            push(buffer.decode("utf-8", errors="replace").rstrip("\r"))
        code = int(process.wait())
        return code, "\n".join(output).strip() or "(aucune sortie)"
    finally:
        selector.close()
        try:
            process.stdout.close()
        except OSError:
            pass


class ConfirmScreen(ModalScreen[bool]):
    BINDINGS = [
        Binding("escape", "cancel", "Annuler"),
        Binding("q", "cancel", "Annuler"),
    ]

    def __init__(
        self,
        title: str,
        message: str,
        confirm_label: str = "Confirmer",
        confirm_variant: str = "primary",
    ):
        super().__init__()
        self.dialog_title = title
        self.dialog_message = message
        self.confirm_label = confirm_label
        self.confirm_variant = confirm_variant

    def compose(self) -> ComposeResult:
        with Vertical(classes=dialog_classes(self.app)):
            yield Static(self.dialog_title, classes="dialog-title")
            yield Static(self.dialog_message, classes="dialog-message")
            with Horizontal(classes="dialog-buttons"):
                yield Button("Annuler", id="cancel", variant="primary")
                yield Button(self.confirm_label, id="confirm", variant=self.confirm_variant)

    def on_mount(self) -> None:
        # Safe default for every confirmation: pressing Enter immediately
        # after the dialog opens cancels instead of executing the action.
        # The user must deliberately move to the confirmation button.
        self.query_one("#cancel", Button).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm")

    def action_cancel(self) -> None:
        self.dismiss(False)


class AddModelScreen(ModalScreen[str | None]):
    BINDINGS = [Binding("escape", "cancel", "Annuler")]

    def compose(self) -> ComposeResult:
        with Vertical(classes=dialog_classes(self.app)):
            yield Static("Ajouter et utiliser un modèle", classes="dialog-title")
            yield Static(
                "Le modèle sera téléchargé si nécessaire, puis chargé. Les autres modèles seront déchargés de la RAM par ola use.",
                classes="dialog-message",
            )
            yield Input(placeholder="Exemple : qwen3:0.6b", id="model-name")
            with Horizontal(classes="dialog-buttons"):
                yield Button("Télécharger et utiliser", id="add", variant="success")
                yield Button("Annuler", id="cancel", variant="primary")

    def on_mount(self) -> None:
        self.query_one("#model-name", Input).focus()

    def action_cancel(self) -> None:
        self.dismiss(None)

    def submit(self) -> None:
        value = self.query_one("#model-name", Input).value.strip()
        if not valid_model(value):
            self.app.notify("Nom de modèle invalide.", severity="error")
            return
        self.dismiss(value)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "add":
            self.submit()
        else:
            self.dismiss(None)

    def on_input_submitted(self, _event: Input.Submitted) -> None:
        self.submit()


class OutputScreen(Screen):
    BINDINGS = [
        Binding("escape", "close", "Fermer"),
        Binding("q", "close", "Fermer"),
        Binding("ctrl+c", "cancel_action", "Annuler l'action"),
    ]

    def __init__(self, title: str, content: str = "", running: bool = False):
        super().__init__()
        self.output_title = title
        self.output_content = content
        self.running = running
        self.finished_code: int | None = None
        self.started_at = time.monotonic()

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical():
            yield Static(self.output_title, id="output-title")
            yield RichLog(id="output-log", highlight=False, markup=False, wrap=True)
            yield Static("", id="output-status")
        yield Footer()

    def on_mount(self) -> None:
        log = self.query_one("#output-log", RichLog)
        if self.output_content:
            log.write(self.output_content)
        log.scroll_home(animate=False)
        self._update_status()
        if self.running:
            self.set_interval(1.0, self._update_status)

    def _elapsed(self) -> int:
        return max(0, int(time.monotonic() - self.started_at))

    def _update_status(self) -> None:
        try:
            status = self.query_one("#output-status", Static)
        except Exception:
            return
        if self.running:
            status.update(
                f"En cours depuis {self._elapsed()} s · sortie en direct · q ou Ctrl+C : annuler"
            )
        elif self.finished_code is not None:
            status.update(
                f"Terminé · code {self.finished_code} · durée {self._elapsed()} s · q : fermer"
            )

    def append_output(self, text: str) -> None:
        try:
            self.query_one("#output-log", RichLog).write(text)
        except Exception:
            pass

    def set_finished(self, code: int) -> None:
        self.finished_code = int(code)
        self.running = False
        self._update_status()

    def action_cancel_action(self) -> None:
        if not self.running:
            return
        request = getattr(self.app, "request_action_cancel", None)
        if callable(request):
            request()
        try:
            self.query_one("#output-status", Static).update(
                "Annulation demandée… attente de l'arrêt du processus."
            )
        except Exception:
            pass

    def action_close(self) -> None:
        if self.running:
            self.action_cancel_action()
            return
        self.app.pop_screen()


class LogsScreen(Screen):
    BINDINGS = [
        Binding("escape", "close", "Fermer"),
        Binding("q", "close", "Fermer"),
        Binding("r", "refresh_log", "Rafraîchir"),
        Binding("/", "focus_search", "Rechercher"),
        Binding("n", "next_match", "Résultat suivant"),
        Binding("N", "previous_match", "Résultat précédent"),
        Binding("f", "toggle_follow", "Suivi"),
        Binding("1", "select_log(0)", "Ollama"),
        Binding("2", "select_log(1)", "Erreurs"),
        Binding("3", "select_log(2)", "Tunnel"),
        Binding("4", "select_log(3)", "Tunnel err."),
        Binding("5", "select_log(4)", "Watchdog"),
    ]

    def __init__(self):
        super().__init__()
        self.current_index = 0
        self.follow = False
        self.search_term = ""
        self.matches: list[tuple[int, int]] = []
        self.match_index = -1
        self.current_lines: list[str] = []

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical():
            yield Static("", id="log-title")
            with Horizontal(id="log-search-row"):
                yield Input(placeholder="Recherche… (/ saisir, Entrée suivant, n/N naviguer)", id="log-search")
                yield Static("Suivi : non", id="log-mode")
            yield TextArea("", id="log-content", read_only=True, show_line_numbers=True)
        yield Footer()

    def on_mount(self) -> None:
        self.show_current(goto_end=True)
        self.query_one("#log-content", TextArea).focus()
        self.set_interval(2.0, self._follow_tick)

    def _update_title(self) -> None:
        name, path = LOG_FILES[self.current_index]
        search = ""
        if self.search_term:
            if self.matches:
                search = f" · recherche « {self.search_term} » : {self.match_index + 1}/{len(self.matches)}"
            else:
                search = f" · recherche « {self.search_term} » : aucun résultat"
        self.query_one("#log-title", Static).update(
            f"Journal {name} — {path}  (1-5 fichiers, / recherche, f suivi, r rafraîchir, q fermer){search}"
        )
        self.query_one("#log-mode", Static).update(
            "Suivi : oui (2 s)" if self.follow else "Suivi : non"
        )

    def _compute_matches(self) -> None:
        term = self.search_term.strip().lower()
        self.matches = []
        if not term:
            self.match_index = -1
            return
        for line_number, line in enumerate(self.current_lines):
            lowered = line.lower()
            column = lowered.find(term)
            while column >= 0:
                self.matches.append((line_number, column))
                column = lowered.find(term, column + max(1, len(term)))
        self.match_index = 0 if self.matches else -1

    def _go_to_match(self) -> None:
        if not self.matches or self.match_index < 0:
            self._update_title()
            return
        line, column = self.matches[self.match_index]
        area = self.query_one("#log-content", TextArea)
        area.move_cursor((line, column), center=True)
        self._update_title()

    def show_current(self, goto_end: bool = False) -> None:
        _name, path = LOG_FILES[self.current_index]
        area = self.query_one("#log-content", TextArea)
        previous_cursor = area.cursor_location
        try:
            data = path.read_bytes()[-150_000:]
            content = data.decode("utf-8", errors="replace")
            if not content:
                content = "(fichier vide)"
        except OSError as exc:
            content = f"Journal illisible : {exc}\nEssaie de lancer la TUI avec les droits root."
        self.current_lines = content.splitlines()
        area.load_text(content)
        self._compute_matches()
        if self.search_term and self.matches:
            self._go_to_match()
        elif goto_end or self.follow:
            area.scroll_end(animate=False)
        else:
            try:
                area.move_cursor(
                    (min(previous_cursor[0], max(0, len(self.current_lines) - 1)), previous_cursor[1])
                )
            except Exception:
                pass
        self._update_title()

    def _follow_tick(self) -> None:
        if self.follow:
            self.show_current(goto_end=True)

    def action_focus_search(self) -> None:
        self.query_one("#log-search", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id != "log-search":
            return
        self.search_term = event.value.strip()
        self._compute_matches()
        self._go_to_match()
        self.query_one("#log-content", TextArea).focus()

    def action_next_match(self) -> None:
        if not self.search_term:
            self.action_focus_search()
            return
        if self.matches:
            self.match_index = (self.match_index + 1) % len(self.matches)
            self._go_to_match()

    def action_previous_match(self) -> None:
        if not self.search_term:
            self.action_focus_search()
            return
        if self.matches:
            self.match_index = (self.match_index - 1) % len(self.matches)
            self._go_to_match()

    def action_toggle_follow(self) -> None:
        self.follow = not self.follow
        self._update_title()
        if self.follow:
            self.show_current(goto_end=True)
        self.app.notify(f"Suivi des journaux : {'activé' if self.follow else 'désactivé'}")

    def action_refresh_log(self) -> None:
        self.show_current(goto_end=self.follow)

    def action_select_log(self, index: int) -> None:
        if 0 <= index < len(LOG_FILES):
            self.current_index = index
            self.show_current(goto_end=True)

    def action_close(self) -> None:
        self.app.pop_screen()


HELP_TEXT = """OLA — AIDE DE L'INTERFACE TERMINAL

BUT
Cette interface supervise Ollama et le tunnel Cloudflare. Le moteur reste
la commande ola : la TUI lit l'API locale et délègue les actions au CLI,
avec ses protections (un seul modèle chargé, suppression vérifiée,
packs Speed/Fluidité et retours arrière).

NAVIGATION
  ↑ / ↓        Choisir un modèle
  m            Ouvrir le menu d'actions du modèle sélectionné
  ?            Cette aide
  r            Rafraîchir l'état
  t            Changer de thème
  q / Échap    Fermer l'écran courant ; quitter depuis l'écran principal

ACTIONS SUR LE MODÈLE SÉLECTIONNÉ
  u  Utiliser : décharger les autres modèles, charger celui-ci, le définir par défaut
  d  Supprimer définitivement du disque (confirmation)
  l  Libérer de la RAM seulement (confirmation si le modèle est chargé)
  a  Ajouter/télécharger puis utiliser un modèle
  w  Préchauffer pour 30 minutes (confirmation si la RAM va changer)
  p  Afficher le preset fluidité JSON
  b  Benchmark classique (confirmation)
  B  Benchmark streaming / premier token visible (confirmation)
  s  État du Pack Speed
  f  État du Pack Fluidité
  g  Journaux Supervisor (1-5 fichiers, / recherche, Entrée puis n/N pour
     naviguer entre les résultats, f suivi automatique, r rafraîchir)

CONFIRMATIONS ET SÉCURITÉ
Le focus initial d'une confirmation est toujours sur Annuler.
Appuyer sur Entrée juste après l'ouverture annule donc l'action.
Il faut choisir explicitement le bouton d'exécution pour continuer.
La suppression du modèle par défaut exige toujours cette confirmation.

ACTIONS LONGUES
Les téléchargements, utilisations et benchmarks affichent leur sortie en
direct avec le temps écoulé. Pendant l'exécution, q ou Ctrl+C demande
l'annulation du processus ; q ferme ensuite l'écran de résultat.

ACCÈS
En root, toutes les actions sont disponibles.
En non-root, l'affichage reste possible, mais Utiliser, Supprimer,
Libérer RAM et Ajouter sont désactivés car ola exige root.

TERMINAL
À partir d'environ 95 colonnes ou 29 lignes, l'affichage est standard.
En dessous, un mode compact masque la bannière et réduit les panneaux.
Sur très petit terminal, les panneaux sont masqués pour garder le tableau
des modèles utilisable.
"""


class HelpScreen(Screen):
    BINDINGS = [
        Binding("escape", "close", "Fermer"),
        Binding("q", "close", "Fermer"),
    ]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical():
            yield Static("Aide Ola", id="output-title")
            yield TextArea(HELP_TEXT, id="help-content", read_only=True, show_line_numbers=False)
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#help-content", TextArea).focus()

    def action_close(self) -> None:
        self.app.pop_screen()


class ActionMenuScreen(ModalScreen[str | None]):
    BINDINGS = [
        Binding("escape", "cancel", "Annuler"),
        Binding("q", "cancel", "Annuler"),
    ]

    def __init__(self, model: str, protected_disabled: bool = False):
        super().__init__()
        self.model_name = model
        self.protected_disabled = protected_disabled

    def compose(self) -> ComposeResult:
        with Vertical(classes=f"{dialog_classes(self.app)} action-dialog"):
            yield Static(f"Actions — {self.model_name}", classes="dialog-title")
            yield OptionList(
                Option("u — Utiliser et définir par défaut", id="use", disabled=self.protected_disabled),
                Option("d — Supprimer définitivement du disque…", id="delete", disabled=self.protected_disabled),
                Option("l — Libérer de la RAM…", id="unload", disabled=self.protected_disabled),
                Option("w — Préchauffer 30 minutes…", id="warm"),
                Option("p — Preset fluidité", id="preset"),
                Option("b — Benchmark classique…", id="bench"),
                Option("B — Benchmark streaming…", id="stream"),
                Option("s — État Pack Speed", id="speed"),
                Option("f — État Pack Fluidité", id="fluid"),
                Option("g — Journaux", id="logs"),
                id="action-list",
            )
            yield Static("↑/↓ choisir · Entrée valider · Échap annuler", classes="dialog-message")

    def on_mount(self) -> None:
        self.query_one("#action-list", OptionList).focus()

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        event.stop()
        self.dismiss(event.option.id)

    def action_cancel(self) -> None:
        self.dismiss(None)


class OlaTui(App):
    TITLE = "Ola"
    SUB_TITLE = "Ollama + Cloudflare"
    CSS = """
    Screen { background: $surface; }
    #banner {
        height: 3;
        padding: 0 1;
        background: $primary;
        color: $text;
        text-style: bold;
        content-align: left middle;
    }
    #top { height: 14; }
    #summary, #details {
        height: 14;
        padding: 0 1;
        border: solid $primary;
        overflow-y: auto;
    }
    #summary { width: 58%; }
    #details { width: 42%; border: solid $secondary; }
    #models { height: 1fr; border: solid $primary; }
    #status {
        height: 1;
        padding: 0 1;
        background: $boost;
        color: $text;
    }
    #output-title {
        height: 3;
        padding: 0 1;
        background: $primary;
        color: $text;
        text-style: bold;
        content-align: left middle;
    }
    #output-log { height: 1fr; border: solid $primary; }
    #output-status {
        height: 1;
        padding: 0 1;
        background: $boost;
        color: $text;
    }
    #help-content { height: 1fr; border: solid $primary; }
    #log-title {
        height: 2;
        padding: 0 1;
        background: $primary;
        color: $text;
        text-style: bold;
        content-align: left middle;
    }
    #log-content { height: 1fr; border: solid $primary; }
    #log-search-row { height: 3; padding: 0 1; }
    #log-search { width: 1fr; }
    #log-mode { width: 16; content-align: center middle; }
    .dialog {
        width: 72;
        max-width: 92%;
        height: auto;
        max-height: 88%;
        margin: 4 6;
        padding: 1 2;
        background: $surface;
        border: thick $primary;
    }
    .dialog-title { text-style: bold; padding-bottom: 1; }
    .dialog-message { padding-bottom: 1; max-height: 12; overflow-y: auto; }
    .dialog-buttons { height: 3; align: right middle; }
    .dialog-buttons Button { margin-left: 1; }
    .dialog.compact {
        width: 60;
        max-width: 96%;
        max-height: 96%;
        margin: 1 1;
        padding: 0 1;
    }
    .dialog.compact .dialog-title { padding-bottom: 0; }
    .dialog.compact .dialog-message { padding-bottom: 0; max-height: 8; overflow-y: auto; }
    .action-dialog { width: 68; }
    .action-dialog #action-list { height: 11; }
    .dialog.compact.action-dialog #action-list { height: 8; }

    /* Responsive terminal modes, toggled from App.on_resize/on_mount. */
    .responsive-compact #banner { display: none; }
    .responsive-compact #top { height: 9; }
    .responsive-compact #summary, .responsive-compact #details { height: 9; }
    .responsive-minimal #banner { display: none; }
    .responsive-minimal #top { display: none; }
    .responsive-minimal #status { display: none; }
    """

    BINDINGS = [
        Binding("q", "quit", "Quitter"),
        Binding("?", "help", "Aide"),
        Binding("m", "action_menu", "Actions"),
        Binding("r", "refresh", "Rafraîchir"),
        Binding("u", "use_model", "Utiliser"),
        Binding("d", "delete_model", "Supprimer"),
        Binding("l", "unload_model", "Libérer RAM"),
        Binding("a", "add_model", "Ajouter"),
        Binding("w", "warm_model", "Préchauffer"),
        Binding("p", "preset_model", "Preset"),
        Binding("b", "bench_model", "Bench"),
        Binding("B", "stream_bench_model", "Bench streaming"),
        Binding("s", "speed_status", "Speed"),
        Binding("f", "fluid_status", "Fluidité"),
        Binding("g", "logs", "Logs"),
        Binding("t", "cycle_theme", "Thème"),
    ]

    def __init__(self):
        super().__init__()
        self.snapshot = Snapshot()
        self.current_model = ""
        # Cache /api/show by model digest: if the same model name is
        # downloaded again with different content, the detail is refetched.
        self.show_cache: dict[str, tuple[str, dict[str, Any]]] = {}
        self.refreshing = False
        self.action_running = False
        self._action_cancel_requested = False
        self.last_refresh_at: float | None = None
        self.last_success_at: float | None = None
        saved_theme = load_saved_theme()
        self.theme_index = THEME_CYCLE.index(saved_theme) if saved_theme in THEME_CYCLE else 0
        try:
            if saved_theme in self.available_themes:
                self.theme = saved_theme
        except Exception:
            pass
        # Keep direct references to the main-screen widgets. App.query_one()
        # searches the currently displayed screen, so background refreshes
        # would otherwise fail while an output, log or dialog screen is open.
        self.summary_widget: Static | None = None
        self.details_widget: Static | None = None
        self.models_table: DataTable | None = None
        self.status_widget: Static | None = None
        # None means "the table has never been rendered". It must differ
        # from the signature of an empty model list, otherwise the initial
        # empty-state row is never added.
        self.table_signature: tuple[object, ...] | None = None

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static("OLA  ·  Ollama + Cloudflare Tunnel  ·  interface Textual", id="banner")
        with Horizontal(id="top"):
            yield Static("Chargement de l'état…", id="summary")
            yield Static("Sélectionne un modèle dans le tableau.", id="details")
        yield DataTable(id="models", zebra_stripes=True, cursor_type="row")
        yield Static("Démarrage…", id="status")
        yield Footer()

    async def on_mount(self) -> None:
        self.summary_widget = self.query_one("#summary", Static)
        self.details_widget = self.query_one("#details", Static)
        self.models_table = self.query_one("#models", DataTable)
        self.status_widget = self.query_one("#status", Static)
        table = self.models_table
        table.add_columns("État", "Modèle", "Taille", "RAM", "Défaut", "Expiration", "Contexte")
        self._apply_responsive_layout()
        self.set_interval(3.0, self._refresh_timer)
        self.set_interval(1.0, self._tick_status)
        await self.refresh_snapshot(force=True)

    def _apply_responsive_layout(self) -> None:
        width, height = self.size.width, self.size.height
        compact = width < 95 or height < 29
        minimal = width < 64 or height < 19
        for screen in self.screen_stack:
            screen.set_class(compact, "responsive-compact")
            screen.set_class(minimal, "responsive-minimal")
        if self.models_table is not None:
            # Column widths and expiry formatting depend on terminal width.
            self.table_signature = None

    async def _on_resize(self, event: events.Resize) -> None:
        await super()._on_resize(event)
        self._apply_responsive_layout()
        if self.models_table is not None and (self.snapshot.models or self.current_model):
            self._render_snapshot()

    def _refresh_timer(self) -> None:
        if not self.refreshing and not self.action_running:
            self.run_worker(self.refresh_snapshot(), group="refresh", exclusive=True)

    def _freshness_text(self) -> str:
        if self.snapshot.error:
            if self.last_success_at is None:
                return "données indisponibles"
            success_age = max(0, int(time.monotonic() - self.last_success_at))
            return f"données indisponibles · dernier succès il y a {success_age} s"
        reference = self.last_success_at or self.last_refresh_at
        if reference is None:
            return "pas encore actualisé"
        age = max(0, int(time.monotonic() - reference))
        if age > 9:
            return f"données anciennes ({age} s)"
        return f"mis à jour il y a {age} s"

    def _status_text(self) -> str:
        snap = self.snapshot
        if snap.error:
            return (
                "API Ollama injoignable · récupération : ola start, puis ola doctor · "
                f"g journaux · {self._freshness_text()}"
            )
        return (
            f"{len(snap.models)} modèle(s) · défaut : {snap.default_model} · "
            f"{self._freshness_text()} · ? aide · m actions"
        )

    def _tick_status(self) -> None:
        if self.action_running or self.status_widget is None:
            return
        try:
            self.status_widget.update(self._status_text())
            self._render_details()
        except Exception:
            pass

    def _cached_show(self, name: str) -> dict[str, Any]:
        model = self._selected_model_info(name)
        cached = self.show_cache.get(name)
        if cached is None:
            return {}
        cached_digest, show = cached
        if model is not None and model.digest and cached_digest != model.digest:
            return {}
        return show

    def _show_cache_valid(self, name: str) -> bool:
        return bool(self._cached_show(name))

    async def refresh_snapshot(self, force: bool = False) -> None:
        if self.refreshing:
            return
        self.refreshing = True
        try:
            snapshot = await asyncio.to_thread(fetch_snapshot)
            self.snapshot = snapshot
            self.last_refresh_at = time.monotonic()
            if snapshot.api_ok and not snapshot.error:
                self.last_success_at = self.last_refresh_at
            if snapshot.models:
                present = {model.name for model in snapshot.models}
                self.show_cache = {
                    name: cached
                    for name, cached in self.show_cache.items()
                    if name in present
                }
            self._render_snapshot()
            selected = self.selected_model_name()
            if selected and not self._show_cache_valid(selected):
                show = await asyncio.to_thread(fetch_show, selected)
                if show:
                    selected_info = self._selected_model_info(selected)
                    self.show_cache[selected] = (
                        selected_info.digest if selected_info is not None else "",
                        show,
                    )
                self._render_details()
        finally:
            self.refreshing = False

    def _render_snapshot(self) -> None:
        if self.summary_widget is None or self.models_table is None or self.status_widget is None:
            return
        snap = self.snapshot
        summary = Text()
        api_style = "bold green" if snap.api_ok else "bold red"
        summary.append("Ollama : ", style="bold")
        summary.append("● API OK" if snap.api_ok else "● API injoignable", style=api_style)
        summary.append(f"  ·  version {snap.version}\n")
        summary.append("Services : ", style="bold")
        for index, (label, program) in enumerate(
            (
                ("Ollama", "ollama"),
                ("Tunnel", "cloudflared-ollama"),
                ("Watchdog", "ollama-watchdog"),
            )
        ):
            if index:
                summary.append(" · ")
            state = snap.services.get(program, "état inconnu")
            style = "green" if state == "RUNNING" else "yellow" if state == "état inconnu" else "red"
            summary.append(f"{label} ", style="bold")
            summary.append(state, style=style)
        summary.append("\n")
        summary.append("Tunnel local : ", style="bold")
        summary.append(
            "prêt\n" if snap.cloudflared_ready == 200 else f"non confirmé ({snap.cloudflared_ready or 'aucune réponse'})\n"
        )
        summary.append("URL publique : ", style="bold")
        summary.append(f"{snap.public_url or 'non enregistrée'}\n")
        if snap.public_url:
            summary.append("Public : ", style="bold")
            summary.append(
                "API non authentifiée — garde cette URL privée\n", style="yellow"
            )
        summary.append("Pack Speed : ", style="bold")
        summary.append(f"{snap.speed_mode}")
        summary.append("  ·  Keep-alive : ", style="bold")
        summary.append(f"{snap.keepalive}\n")
        if snap.mem_total:
            free_pct = int(snap.mem_available * 100 / snap.mem_total)
            used_pct = 100 - free_pct
            filled = min(20, max(0, int(used_pct * 20 / 100)))
            bar = "█" * filled + "░" * (20 - filled)
            summary.append("RAM : ", style="bold")
            summary.append(
                f"{format_bytes(snap.mem_available)} libres / {format_bytes(snap.mem_total)} "
                f"· {used_pct}% utilisée [{bar}]\n"
            )
        if snap.swap_total:
            summary.append("Swap : ", style="bold")
            summary.append(f"{format_bytes(snap.swap_free)} libres / {format_bytes(snap.swap_total)}\n")
        summary.append("Accès : ", style="bold")
        summary.append(
            "root (actions actives)" if running_as_root() else "non-root (lecture seule pour les actions protégées)"
        )
        if snap.error:
            detail = " ".join(str(snap.error).split())
            if len(detail) > 90:
                detail = f"{detail[:87]}…"
            summary.append("\nErreur : ", style="bold red")
            summary.append("Ollama ne répond pas localement.\n", style="red")
            summary.append("Récupération : ", style="bold")
            summary.append("quitte (q), lance ola start, puis ola doctor ; journaux ici avec g.\n")
            summary.append("Détail technique : ", style="bold")
            summary.append(detail, style="red")
        self.summary_widget.update(summary)

        table = self.models_table
        previous = self.current_model
        default_norm = normalize_model(snap.default_model)
        width = self.size.width
        if width >= 110:
            model_name_limit = 54
        elif width >= 90:
            model_name_limit = 42
        elif width >= 70:
            model_name_limit = 32
        else:
            model_name_limit = 24
        short_expiry = width < 90
        table_signature = (
            model_name_limit,
            short_expiry,
            tuple(
                (
                    model.name,
                    model.size,
                    model.loaded,
                    model.loaded_size,
                    format_expiry_relative(model.expires_at) if model.loaded else "—",
                    model.context_length,
                    normalize_model(model.name) == default_norm,
                )
                for model in snap.models
            ),
        )
        # Avoid rebuilding the table every three seconds when nothing changed:
        # it would reset the cursor/scroll while the user is navigating.
        if table_signature != self.table_signature:
            self.table_signature = table_signature
            table.clear()
            for model in snap.models:
                is_default = normalize_model(model.name) == default_norm
                expiry = format_expiry_relative(model.expires_at) if model.loaded else "—"
                table.add_row(
                    "● RAM" if model.loaded else "○ disque",
                    display_model_name(model.name, model_name_limit),
                    format_bytes(model.size),
                    format_bytes(model.loaded_size) if model.loaded else "—",
                    "défaut" if is_default else "—",
                    expiry,
                    str(model.context_length or "—"),
                    key=model.name,
                )
            if not snap.models:
                table.add_row(
                    "—",
                    "Aucun modèle téléchargé — touche a pour ajouter",
                    "—",
                    "—",
                    "—",
                    "—",
                    "—",
                    key="__empty__",
                )
                self.current_model = ""
            else:
                names = [model.name for model in snap.models]
                loaded_names = [model.name for model in snap.models if model.loaded]
                if previous in names:
                    target = previous
                elif loaded_names:
                    # The loaded model consumes the scarce RAM resource; it is
                    # the most useful initial selection for this console.
                    target = loaded_names[0]
                else:
                    target = names[-1]
                self.current_model = target
                try:
                    table.move_cursor(row=names.index(target), column=0, animate=False)
                except Exception:
                    pass
        self.status_widget.update(self._status_text())
        self._render_details()

    def selected_model_name(self) -> str:
        if self.models_table is None:
            return self.current_model
        table = self.models_table
        try:
            cell_key = table.coordinate_to_cell_key(table.cursor_coordinate)
            value = str(cell_key.row_key.value or "")
            if value and value != "__empty__":
                self.current_model = value
        except Exception:
            pass
        return self.current_model

    def _render_details(self) -> None:
        if self.details_widget is None:
            return
        name = self.selected_model_name()
        details_widget = self.details_widget
        if not name:
            if not self.snapshot.models:
                details_widget.update(
                    "Aucun modèle téléchargé.\n\nTouche a : ajouter et utiliser un modèle."
                )
            else:
                details_widget.update("Aucun modèle sélectionné.")
            return
        model = next((item for item in self.snapshot.models if item.name == name), None)
        show = self._cached_show(name)
        show_details = show.get("details") or {}
        capabilities = show.get("capabilities") or []
        text = Text()
        is_default_model = normalize_model(name) == normalize_model(self.snapshot.default_model)
        text.append("Modèle sélectionné\n", style="bold underline")
        text.append(f"{name}\n", style="bold")
        if model:
            text.append("État : ", style="bold")
            text.append("chargé en RAM" if model.loaded else "sur disque seulement")
            text.append(" · Défaut ola : ", style="bold")
            text.append("oui\n" if is_default_model else "non\n")
            text.append("Taille disque : ", style="bold")
            text.append(f"{format_bytes(model.size)}\n")
            if model.loaded:
                text.append("Taille RAM déclarée : ", style="bold")
                text.append(f"{format_bytes(model.loaded_size)}\n")
                text.append("Expiration keep-alive : ", style="bold")
                text.append(f"{format_expiry_details(model.expires_at)}\n")
        parameter_size = str(show_details.get("parameter_size") or (model.parameter_size if model else ""))
        family = str(show_details.get("family") or (model.family if model else ""))
        quantization = str(show_details.get("quantization_level") or (model.quantization if model else ""))
        if parameter_size or family:
            if parameter_size:
                text.append("Paramètres : ", style="bold")
                text.append(parameter_size)
            if parameter_size and family:
                text.append(" · ")
            if family:
                text.append("Famille : ", style="bold")
                text.append(family)
            text.append("\n")
        if quantization:
            text.append("Quantification : ", style="bold")
            text.append(f"{quantization}\n")
        if capabilities:
            text.append("Capacités : ", style="bold")
            text.append(", ".join(str(value) for value in capabilities) + "\n")
        if not model:
            text.append("Défaut ola : ", style="bold")
            text.append("oui\n" if is_default_model else "non\n")
        if not show and self.snapshot.api_ok:
            text.append("Détail technique : chargement…\n")
        text.append("Actions : u utiliser · d supprimer · l libérer RAM · w préchauffer · p preset · b bench")
        details_widget.update(text)

    async def on_data_table_row_highlighted(self, _event: DataTable.RowHighlighted) -> None:
        name = self.selected_model_name()
        if name and not self._show_cache_valid(name):
            show = await asyncio.to_thread(fetch_show, name)
            if show:
                info = self._selected_model_info(name)
                self.show_cache[name] = (info.digest if info is not None else "", show)
        self._render_details()

    def _require_model(self) -> str:
        name = self.selected_model_name()
        if not name or not valid_model(name):
            self.notify("Aucun modèle sélectionné.", severity="warning")
            return ""
        return name

    def _selected_model_info(self, name: str) -> ModelInfo | None:
        return next((item for item in self.snapshot.models if item.name == name), None)

    def _require_root(self, action_label: str) -> bool:
        if running_as_root():
            return True
        self.notify(
            f"{action_label} : root requis. Relance avec sudo ola tui ou utilise ola en root.",
            severity="error",
        )
        return False

    def _confirm_cli(
        self,
        title: str,
        message: str,
        confirm_label: str,
        output_title: str,
        args: list[str],
        timeout: int = 900,
        confirm_variant: str = "primary",
    ) -> None:
        def done(confirmed: bool) -> None:
            if confirmed:
                self.run_worker(
                    self.execute_cli(output_title, args, timeout=timeout),
                    group="actions",
                    exclusive=True,
                )

        self.push_screen(
            ConfirmScreen(title, message, confirm_label, confirm_variant=confirm_variant),
            done,
        )

    def request_action_cancel(self) -> None:
        if self.action_running:
            self._action_cancel_requested = True
            self.notify("Annulation de l'action demandée…", severity="warning")

    async def execute_cli(self, title: str, args: list[str], timeout: int = 900) -> None:
        if self.action_running:
            self.notify("Une action est déjà en cours.", severity="warning")
            return
        self.action_running = True
        self._action_cancel_requested = False
        if self.status_widget is not None:
            self.status_widget.update(f"Exécution : ola {' '.join(args)} …")
        screen = OutputScreen(
            title,
            f"{title}\nCommande : ola {' '.join(args)}\n\n",
            running=True,
        )
        self.push_screen(screen)

        def emit(line: str) -> None:
            try:
                self.call_from_thread(screen.append_output, line)
            except Exception:
                pass

        try:
            code, _output = await asyncio.to_thread(
                run_cli_stream,
                args,
                emit,
                lambda: self._action_cancel_requested,
                timeout,
            )
            screen.set_finished(code)
            if code == 0:
                self.notify("Action terminée.")
            elif code == 130:
                self.notify("Action annulée.", severity="warning")
            else:
                self.notify(f"La commande a échoué (code {code}).", severity="error")
        finally:
            self.action_running = False
            await self.refresh_snapshot(force=True)

    def action_refresh(self) -> None:
        if not self.refreshing and not self.action_running:
            self.run_worker(self.refresh_snapshot(force=True), group="refresh", exclusive=True)

    def action_use_model(self) -> None:
        model = self._require_model()
        if not model or not self._require_root("Utiliser un modèle"):
            return

        def done(confirmed: bool) -> None:
            if confirmed:
                self.run_worker(
                    self.execute_cli("Utiliser un modèle", ["use", model]),
                    group="actions",
                    exclusive=True,
                )

        self.push_screen(
            ConfirmScreen(
                "Utiliser ce modèle ?",
                f"ola use {model}\n\nLes autres modèles seront déchargés de la RAM, puis ce modèle sera chargé et deviendra le défaut de ola.",
                "Utiliser",
            ),
            done,
        )

    def action_delete_model(self) -> None:
        model = self._require_model()
        if not model or not self._require_root("Supprimer un modèle"):
            return
        is_default = normalize_model(model) == normalize_model(self.snapshot.default_model)
        args = ["delete", model, "--force"] if is_default else ["delete", model]
        consequence = (
            "C'est le modèle par défaut actuel : après suppression, ola choisira un autre modèle restant ou retirera le défaut enregistré."
            if is_default
            else "Le modèle sera déchargé de la RAM si nécessaire, puis supprimé du disque."
        )

        def done(confirmed: bool) -> None:
            if confirmed:
                self.run_worker(
                    self.execute_cli("Supprimer un modèle", args),
                    group="actions",
                    exclusive=True,
                )

        self.push_screen(
            ConfirmScreen(
                "Suppression définitive",
                f"Supprimer définitivement {model} du disque ?\n\n{consequence}\n\nCette action est irréversible sans nouveau téléchargement.",
                "Supprimer",
                confirm_variant="error",
            ),
            done,
        )

    def action_unload_model(self) -> None:
        model = self._require_model()
        if not model or not self._require_root("Libérer la RAM"):
            return
        info = self._selected_model_info(model)
        if info is None or not info.loaded:
            self.notify(f"{model} n'est pas chargé en RAM.", severity="warning")
            return
        self._confirm_cli(
            "Libérer la RAM ?",
            f"ola unload {model}\n\nLe modèle sera déchargé de la mémoire. Une génération en cours peut être interrompue ; le fichier du modèle restera sur le disque.",
            "Libérer",
            "Libérer la RAM",
            ["unload", model],
        )

    def action_add_model(self) -> None:
        if not self._require_root("Ajouter un modèle"):
            return
        def done(name: str | None) -> None:
            if name:
                self.run_worker(
                    self.execute_cli("Ajouter et utiliser un modèle", ["use", name]),
                    group="actions",
                    exclusive=True,
                )

        self.push_screen(AddModelScreen(), done)

    def action_warm_model(self) -> None:
        model = self._require_model()
        if not model:
            return
        info = self._selected_model_info(model)
        loaded_others = [
            item.name for item in self.snapshot.models if item.loaded and item.name != model
        ]
        if info is not None and info.loaded and not loaded_others:
            self.run_worker(
                self.execute_cli("Préchauffer un modèle", ["fluid", "warm", model]),
                group="actions",
                exclusive=True,
            )
            return
        if loaded_others:
            consequence = (
                f"Le modèle chargé {loaded_others[0]} sera déchargé de la RAM, "
                f"puis {model} sera chargé et gardé au chaud 30 minutes."
            )
        else:
            consequence = f"{model} sera chargé en RAM et gardé au chaud 30 minutes."
        self._confirm_cli(
            "Préchauffer ce modèle ?",
            f"ola fluid warm {model}\n\n{consequence}",
            "Préchauffer",
            "Préchauffer un modèle",
            ["fluid", "warm", model],
        )

    def action_preset_model(self) -> None:
        model = self._require_model()
        if model:
            self.run_worker(
                self.execute_cli("Preset fluidité", ["fluid", "preset", model], timeout=120),
                group="actions",
                exclusive=True,
            )

    def action_bench_model(self) -> None:
        model = self._require_model()
        if not model:
            return

        def done(confirmed: bool) -> None:
            if confirmed:
                self.run_worker(
                    self.execute_cli("Benchmark classique", ["bench", model], timeout=1200),
                    group="actions",
                    exclusive=True,
                )

        self.push_screen(
            ConfirmScreen(
                "Lancer le benchmark ?",
                f"ola bench {model}\n\nLe test peut prendre du temps et charger/décharger des modèles en RAM. Il ne modifie ni la configuration ni les fichiers des modèles.",
                "Benchmarker",
            ),
            done,
        )

    def action_stream_bench_model(self) -> None:
        model = self._require_model()
        if not model:
            return

        def done(confirmed: bool) -> None:
            if confirmed:
                self.run_worker(
                    self.execute_cli(
                        "Benchmark streaming / fluidité",
                        ["bench", "--stream", model],
                        timeout=1200,
                    ),
                    group="actions",
                    exclusive=True,
                )

        self.push_screen(
            ConfirmScreen(
                "Lancer le benchmark streaming ?",
                f"ola bench --stream {model}\n\nLe test mesure le premier token visible et la régularité du flux. Il peut charger/décharger des modèles en RAM, sans modifier la configuration.",
                "Benchmarker",
            ),
            done,
        )

    def action_speed_status(self) -> None:
        self.run_worker(
            self.execute_cli("Pack Speed", ["speed"], timeout=120),
            group="actions",
            exclusive=True,
        )

    def action_fluid_status(self) -> None:
        self.run_worker(
            self.execute_cli("Fluidité", ["fluid"], timeout=120),
            group="actions",
            exclusive=True,
        )

    def action_help(self) -> None:
        self.push_screen(HelpScreen())

    def action_action_menu(self) -> None:
        model = self._require_model()
        if not model:
            return

        def done(action: str | None) -> None:
            if not action:
                return
            handlers = {
                "use": self.action_use_model,
                "delete": self.action_delete_model,
                "unload": self.action_unload_model,
                "warm": self.action_warm_model,
                "preset": self.action_preset_model,
                "bench": self.action_bench_model,
                "stream": self.action_stream_bench_model,
                "speed": self.action_speed_status,
                "fluid": self.action_fluid_status,
                "logs": self.action_logs,
            }
            handler = handlers.get(action)
            if handler is not None:
                handler()

        self.push_screen(
            ActionMenuScreen(model, protected_disabled=not running_as_root()),
            done,
        )

    def action_logs(self) -> None:
        self.push_screen(LogsScreen())

    def action_cycle_theme(self) -> None:
        available = set(getattr(self, "available_themes", {}) or {})
        candidates = [name for name in THEME_CYCLE if not available or name in available]
        if not candidates:
            self.notify("Aucun thème alternatif disponible.", severity="warning")
            return
        self.theme_index = (self.theme_index + 1) % len(candidates)
        try:
            self.theme = candidates[self.theme_index]
            save_theme(self.theme)
            self.notify(f"Thème : {self.theme} (mémorisé)")
        except Exception as exc:
            self.notify(f"Thème indisponible : {exc}", severity="warning")


def main() -> None:
    OlaTui().run()


if __name__ == "__main__":
    main()
