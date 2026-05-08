#!/usr/bin/env python3
"""
jarvis_agent.py — JarvisOS Autonomous Agent Runtime

Voice (Vosk) + text input → Ollama planning → JARVIS policy gate → execution

Launched by test-jarvis-ollama.sh which sets:
  JARVIS_MODEL      — Ollama model name
  OLLAMA_URL        — Ollama base URL (default http://localhost:11434)
  VOSK_MODEL_PATH   — path to Vosk model dir (empty = voice disabled)
  JARVIS_LOG        — log file path (default /tmp/jarvis.log)
"""

import sys
import os
import json
import threading
import queue
import subprocess
import requests
import time
import signal
import pty
import select
import stat
import tempfile
import atexit
from datetime import datetime
from pathlib import Path

# ── Optional Vosk / PyAudio ───────────────────────────────────────────────────
# These are runtime-optional — installed by the launcher into a venv.
# Pyright can't resolve them from the system env, hence the type: ignore.
VOSK_OK = False
_VoskModel: type | None = None
_VoskRec:   type | None = None
_pyaudio:   object | None = None
try:
    from vosk import Model as _VoskModel, KaldiRecognizer as _VoskRec  # type: ignore[import]
    import pyaudio as _pyaudio                                          # type: ignore[import-untyped]
    VOSK_OK = True
except ImportError:
    pass

# ── Config from environment ───────────────────────────────────────────────────
OLLAMA_URL  = os.environ.get("OLLAMA_URL",        "http://localhost:11434")
MODEL       = os.environ.get("JARVIS_MODEL",       "")
VOSK_PATH   = os.environ.get("VOSK_MODEL_PATH",    "")
LOG_FILE    = os.environ.get("JARVIS_LOG",         "/tmp/jarvis.log")

# ── ANSI palette ──────────────────────────────────────────────────────────────
R    = "\033[0m"
BOLD = "\033[1m"
DIM  = "\033[2m"
RED  = "\033[91m"
YEL  = "\033[93m"
GRN  = "\033[92m"
CYN  = "\033[96m"
PRP  = "\033[95m"
BLU  = "\033[94m"
WHT  = "\033[97m"

def _p(colour, tag, msg, end="\n"):
    print(f"{colour}{tag}{R} {msg}", end=end, flush=True)

def jarvis(msg):  _p(PRP,  "[JARVIS]", msg)
def kern(msg):    _p(BLU,  "[KERN]  ", msg)
def ok(msg):      _p(GRN,  "[ OK ]  ", msg)
def warn(msg):    _p(YEL,  "[WARN]  ", msg)
def err(msg):     _p(RED,  "[ERR]   ", msg)
def info(msg):    _p(CYN,  "[INFO]  ", msg)

def audit(msg):
    line = f"{datetime.now().isoformat()}  {msg}"
    _p(YEL, "[AUDIT] ", msg)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass

def hdr(msg):
    print(f"\n{BOLD}{BLU}━━━ {msg} {'━' * max(0, 44 - len(msg))}{R}")

# ── Sysmon ────────────────────────────────────────────────────────────────────
def sysmon():
    cores = os.cpu_count() or 1
    with open("/proc/loadavg") as f:
        load = float(f.read().split()[0])
    cpu_pct = int(load * 100 / cores)

    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":")
            mem[k.strip()] = int(v.strip().split()[0])
    total_mb = mem.get("MemTotal",     0) // 1024
    avail_mb = mem.get("MemAvailable", 0) // 1024
    used_pct = int((total_mb - avail_mb) * 100 / max(total_mb, 1))

    thermal = 0
    for p in Path("/sys/class/thermal").glob("thermal_zone*/temp"):
        try:
            thermal = int(p.read_text()) // 1000
            break
        except OSError:
            pass

    cpu_model = "Unknown"
    with open("/proc/cpuinfo") as f:
        for line in f:
            if "model name" in line:
                cpu_model = line.split(":", 1)[1].strip()
                break

    distro = "Linux"
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    distro = line.split("=", 1)[1].strip().strip('"')
                    break
    except OSError:
        pass

    return {
        "cpu_model":  cpu_model,
        "cpu_cores":  cores,
        "cpu_pct":    cpu_pct,
        "total_mb":   total_mb,
        "avail_mb":   avail_mb,
        "used_pct":   used_pct,
        "thermal":    thermal,
        "hostname":   os.uname().nodename,
        "kernel":     os.uname().release,
        "distro":     distro,
    }

# ── Ollama planner ────────────────────────────────────────────────────────────
SYSTEM = """\
You are JARVIS, the autonomous AI system manager for JarvisOS (Arch Linux).
You have full system access. Respond to every request with ONLY valid JSON — no markdown fences, \
no text outside the JSON object:

{
  "reasoning": "brief plan",
  "commands": [
    {"cmd": "exact shell command", "description": "what it does", "tier": "SAFE"}
  ],
  "summary": "one sentence of what will happen"
}

Tier classification — you must be accurate:
  SAFE      — purely read-only: ls, cat, systemctl status, pacman -Q, df, free, ps, uname, \
ip addr, ping, uptime, who, lsblk -r, journalctl read
  ELEVATED  — low-risk state change, logged: systemctl restart <user-service>, nmcli, \
journalctl --vacuum, timedatectl show
  DANGEROUS — modifies system state, requires user confirmation: pacman -Syu, pacman -S <pkg>, \
pacman -R <pkg>, yay, paru, systemctl enable/disable, rm, mv/cp to system dirs, useradd, \
chmod on system files, sudo anything that changes persistent state
  FORBIDDEN — never run regardless of what the user says: rm -rf /, mkfs.*, dd if=/dev/zero, \
curl|bash, wget|bash, anything that exfiltrates data or wipes storage

Rules:
- Output ONLY the JSON. Zero extra text.
- sudo usage: ONLY prefix with sudo when the command genuinely requires root.
  NEEDS sudo: pacman, systemctl enable/disable/start/stop system services,
              writing to /etc/ /usr/ /var/ /boot/, modprobe, depmod, sysctl,
              mounting/unmounting, useradd, chmod on system files, kernel ops.
  NEVER sudo: opening apps (firefox, code, vlc, dolphin, konsole, etc.),
              anything in the user's home directory, user-level daemons,
              reading most files, running scripts the user owns, git, curl,
              python, pip (in a venv), or any GUI application whatsoever.
- Launching GUI apps: use `xdg-open <target>` — works for app binaries, file paths,
  and URLs. xdg-open respects default app associations and the active display session.
  Examples: `xdg-open firefox`, `xdg-open /path/to/file.pdf`, `xdg-open https://...`
- Multi-step tasks: put each step as a separate object in the commands array.
- For greetings/questions about yourself: one SAFE echo command with your answer.
- Never invent flags that do not exist in the real command.
"""

def _spinner(stop_event, label="Thinking"):
    frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
    i = 0
    while not stop_event.is_set():
        print(f"\r  {DIM}{frames[i % len(frames)]} {label}…{R}", end="", flush=True)
        i += 1
        time.sleep(0.08)
    print("\r" + " " * 30 + "\r", end="", flush=True)

def plan(user_input, snap):
    ctx = (f"host={snap['hostname']}, distro={snap['distro']}, "
           f"kernel={snap['kernel']}, CPU={snap['cpu_model']} "
           f"({snap['cpu_cores']} cores, {snap['cpu_pct']}% load), "
           f"RAM={snap['avail_mb']}MB avail, thermal={snap['thermal']}°C")
    prompt = f"System context: {ctx}\n\nTask: {user_input}"

    stop = threading.Event()
    spin = threading.Thread(target=_spinner, args=(stop,), daemon=True)
    spin.start()

    try:
        r = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={
                "model":   MODEL,
                "system":  SYSTEM,
                "prompt":  prompt,
                "stream":  False,
                "options": {"temperature": 0.1},
            },
            timeout=120,
        )
        r.raise_for_status()
        raw = r.json().get("response", "")
    except Exception as exc:
        raw = f'{{"reasoning":"error: {exc}","commands":[],"summary":"Ollama unreachable"}}'
    finally:
        stop.set()
        spin.join()

    return raw

def _extract_json(text):
    depth, start = 0, -1
    for i, ch in enumerate(text):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start >= 0:
                try:
                    return json.loads(text[start : i + 1])
                except json.JSONDecodeError:
                    depth, start = 0, -1
    return None

def summarise(user_input, output):
    prompt = (f"Task: '{user_input}'\n\nOutput:\n{output[:2000]}\n\n"
              "Give a plain-English 1–3 sentence summary of what happened "
              "and whether it succeeded.")
    stop = threading.Event()
    spin = threading.Thread(target=_spinner, args=(stop, "Summarising"), daemon=True)
    spin.start()
    try:
        r = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={"model": MODEL, "prompt": prompt, "stream": False,
                  "options": {"temperature": 0.2}},
            timeout=60,
        )
        return r.json().get("response", "(summary unavailable)")
    except Exception:
        return "(summary unavailable)"
    finally:
        stop.set()
        spin.join()

# ── KDE polkit / sudo askpass setup ──────────────────────────────────────────
# Written once at startup; path injected into every sudo command as SUDO_ASKPASS.
_ASKPASS_PATH: str = ""

def _setup_askpass() -> str:
    """Create a tiny shell script that pops up a KDE password dialog.

    Preference order:
      1. kdialog wrapper — always present on KDE Plasma, works on Wayland,
                           avoids ksshaskpass "Unable to parse phrase" errors
      2. ksshaskpass     — fallback if kdialog is absent
      3. nothing         — fall back to terminal sudo
    """
    global _ASKPASS_PATH

    # Prefer a kdialog wrapper — it ignores the sudo phrase argument entirely
    # and pops up a clean dialog, avoiding ksshaskpass parse errors.
    if _which("kdialog"):
        try:
            fd, path = tempfile.mkstemp(suffix=".sh", prefix="jarvis-askpass-")
            with os.fdopen(fd, "w") as f:
                f.write("#!/bin/bash\n")
                f.write(
                    'kdialog --password '
                    '"JARVIS needs your sudo password:" '
                    '--title "JARVIS — Authentication Required" '
                    '2>/dev/null\n'
                )
            os.chmod(path, stat.S_IRWXU)
            atexit.register(_remove_askpass, path)
            _ASKPASS_PATH = path
            ok(f"sudo askpass: kdialog → {path}")
            return _ASKPASS_PATH
        except OSError as exc:
            warn(f"Could not create askpass script: {exc}")

    # Fallback: ksshaskpass (may print "Unable to parse phrase" but still works)
    for candidate in ("ksshaskpass", "/usr/lib/ssh/ksshaskpass",
                      "/usr/lib/ksshaskpass"):
        if Path(candidate).exists():
            _ASKPASS_PATH = candidate
            ok(f"sudo askpass: {candidate}")
            return _ASKPASS_PATH
        full = _which(candidate)
        if full:
            _ASKPASS_PATH = full
            ok(f"sudo askpass: {full}")
            return _ASKPASS_PATH

    warn("No KDE askpass found — sudo will prompt in terminal")
    return ""

def _remove_askpass(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass

def _which(cmd: str) -> str:
    import shutil
    return shutil.which(cmd) or ""

def _inject_askpass(cmd: str) -> tuple[str, dict[str, str]]:
    """Rewrite 'sudo …' → 'sudo -A …' and return the extra env needed.

    Also injects --noconfirm into pacman install/upgrade/remove commands so
    interactive provider-selection prompts don't block autonomous execution.
    """
    env: dict[str, str] = {}
    if "sudo " in cmd and _ASKPASS_PATH:
        cmd = cmd.replace("sudo ", "sudo -A ", 1)
        env["SUDO_ASKPASS"] = _ASKPASS_PATH

    # Prevent pacman from blocking on "choose a provider" prompts.
    # Only add --noconfirm to -S / -R / -U operations, not -Q (query).
    import re
    if re.search(r"\bpacman\b.*\s-[A-Za-z]*[SRU]", cmd) and "--noconfirm" not in cmd:
        cmd = cmd.rstrip() + " --noconfirm"

    return cmd, env

# ── Policy helpers ────────────────────────────────────────────────────────────
_TIER_CLR = {
    "SAFE":      GRN,
    "ELEVATED":  YEL,
    "DANGEROUS": RED,
    "FORBIDDEN": RED + BOLD,
}

def tier_fmt(tier):
    return f"{_TIER_CLR.get(tier, WHT)}{tier}{R}"

# ── Command runner ────────────────────────────────────────────────────────────
def run_cmd(cmd: str) -> tuple[str, int]:
    """Run a command through a PTY so output streams live and interactive
    programs (pacman confirmations, file pagers, etc.) work correctly.
    sudo commands are transparently rewritten to use the KDE askpass dialog."""

    cmd, extra_env = _inject_askpass(cmd)

    env = os.environ.copy()
    env.update(extra_env)

    print(f"  {DIM}$ {cmd}{R}")
    print(f"  {DIM}{'─' * 52}{R}", flush=True)

    # Open a PTY so the child thinks it's attached to a terminal —
    # this keeps pacman/systemctl colors and interactive prompts working.
    master_fd, slave_fd = pty.openpty()
    collected: list[str] = []

    try:
        proc = subprocess.Popen(
            cmd,
            shell=True,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            env=env,
            close_fds=True,
        )
        os.close(slave_fd)
        slave_fd = -1

        while True:
            try:
                readable, _, _ = select.select([master_fd], [], [], 0.1)
                if readable:
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    text = chunk.decode("utf-8", errors="replace")
                    # Indent each line with two spaces for visual nesting
                    indented = "\n".join(
                        "  " + l for l in text.split("\n")
                    )
                    print(indented, end="", flush=True)
                    collected.append(text)
                elif proc.poll() is not None:
                    # Drain any remaining output
                    try:
                        readable2, _, _ = select.select([master_fd], [], [], 0.05)
                        if readable2:
                            chunk = os.read(master_fd, 4096)
                            text = chunk.decode("utf-8", errors="replace")
                            indented = "\n".join("  " + l for l in text.split("\n"))
                            print(indented, end="", flush=True)
                            collected.append(text)
                    except OSError:
                        pass
                    break
            except KeyboardInterrupt:
                proc.terminate()
                break

        proc.wait()

    finally:
        try:
            os.close(master_fd)
        except OSError:
            pass
        if slave_fd >= 0:
            try:
                os.close(slave_fd)
            except OSError:
                pass

    print(f"\n  {DIM}{'─' * 52}{R}")
    return "".join(collected), proc.returncode

# ── Confirmation queue ────────────────────────────────────────────────────────
# When a DANGEROUS-tier plan needs user approval, handle() sets this to a fresh
# Queue and the text thread routes its next readline() result here instead of
# input_q.  This avoids the race where readline() in the text thread grabs the
# user's "y/n" before the main thread's input() call can see it.
_confirm_q: "queue.Queue | None" = None

# ── Request handler ───────────────────────────────────────────────────────────
def handle(user_input, snap):
    print()
    jarvis(f'Planning: "{user_input}"')

    raw  = plan(user_input, snap)
    obj  = _extract_json(raw)

    if not obj:
        warn("Could not parse model response.")
        print(f"  {DIM}{raw[:400]}{R}")
        return

    reasoning = obj.get("reasoning", "")
    summary   = obj.get("summary",   "")
    commands  = obj.get("commands",  [])

    print(f"\n  {BOLD}Plan:{R} {reasoning}\n")

    if not commands:
        warn("No commands in plan.")
        return

    # ── Print plan table ──────────────────────────────────────────────────────
    print(f"  {DIM}{'#':<4}  {'TIER':<20}  {'COMMAND':<40}  DESCRIPTION{R}")
    print(f"  {DIM}{'─'*4}  {'─'*20}  {'─'*40}  {'─'*30}{R}")
    for i, c in enumerate(commands):
        print(
            f"  {i+1:<4}  "
            f"{tier_fmt(c.get('tier','SAFE')):<30}  "
            f"{c.get('cmd','')[:40]:<40}  "
            f"{DIM}{c.get('description','')}{R}"
        )
    print()

    # ── Policy override: force DANGEROUS tier for package managers ───────────
    # The model sometimes mis-classifies `pacman -Syu` as ELEVATED.
    # Any command that invokes a package manager must always require confirmation.
    _PKG_PATTERNS = ("pacman ", "yay ", "paru ", "apt ", "dnf ", "zypper ")
    for c in commands:
        cmd = c.get("cmd", "")
        if any(p in cmd for p in _PKG_PATTERNS) and c.get("tier") == "ELEVATED":
            c["tier"] = "DANGEROUS"

    # ── FORBIDDEN: hard block ─────────────────────────────────────────────────
    if any(c.get("tier") == "FORBIDDEN" for c in commands):
        print(f"  {RED}{BOLD}[POLICY: FORBIDDEN]  Request blocked unconditionally.{R}")
        audit(f"BLOCKED (FORBIDDEN): {user_input}")
        return

    # ── DANGEROUS: require explicit confirmation ──────────────────────────────
    if any(c.get("tier") == "DANGEROUS" for c in commands):
        global _confirm_q
        print(f"  {RED}[POLICY: DANGEROUS]{R}  This plan will modify system state.")
        print(f"  {BOLD}Summary:{R} {summary}\n")
        # Route the next text-thread readline() result to a private queue so
        # we don't race with readline() for ownership of stdin.
        cq: queue.Queue = queue.Queue()
        _confirm_q = cq
        print(f"  Confirm execution? [y/N]  ", end="", flush=True)
        try:
            _, response = cq.get(timeout=30)
            confirm = response.strip().lower()
        except queue.Empty:
            _confirm_q = None
            print()
            jarvis("Confirmation timed out — aborted.")
            return
        except KeyboardInterrupt:
            _confirm_q = None
            print()
            jarvis("Aborted.")
            return
        _confirm_q = None
        if confirm != "y":
            jarvis("Aborted by user.")
            return
        print()

    # ── Execute ───────────────────────────────────────────────────────────────
    all_output = ""
    for i, c in enumerate(commands):
        tier = c.get("tier", "SAFE")
        cmd  = c.get("cmd",  "")
        desc = c.get("description", "")

        print(f"  {BOLD}[{i+1}/{len(commands)}]{R} {desc}")

        if tier == "ELEVATED":
            audit(f"ELEVATED exec: {cmd}")

        out, rc = run_cmd(cmd)
        all_output += f"\n--- {cmd} ---\n{out}"

        if rc != 0:
            warn(f"Exit code {rc}")

    print()
    jarvis(summarise(user_input, all_output))
    audit(f"TASK: {user_input}")
    print()

# ── Voice listener ────────────────────────────────────────────────────────────
class VoiceListener(threading.Thread):
    """Continuously transcribes microphone input via Vosk.

    State machine:
      WAITING  — only watches for the wake phrase "hey jarvis"
      ACTIVE   — the next complete utterance becomes a command

    Wake phrase detected in the same utterance as a command
    (e.g. "hey jarvis update my system") is handled inline — the
    wake phrase is stripped and the remainder is dispatched directly.
    """

    RATE           = 16000
    CHUNK          = 4096
    ACTIVE_TIMEOUT = 8.0    # seconds to wait for a command before going back to sleep

    # All accepted wake-phrase variants (lowercase)
    WAKE_PHRASES = [
        "hey jarvis",
        "hey, jarvis",
        "ok jarvis",
        "okay jarvis",
        "hi jarvis",
    ]

    def __init__(self, model_path: str, input_q: queue.Queue):
        super().__init__(daemon=True, name="VoiceListener")
        self.model_path   = model_path
        self.q            = input_q
        self.paused       = threading.Event()
        self.running      = True
        self._active      = False
        self._active_t    = 0.0

    # ── helpers ───────────────────────────────────────────────────────────────
    def _has_wake(self, text: str) -> bool:
        t = text.lower()
        return any(w in t for w in self.WAKE_PHRASES)

    def _strip_wake(self, text: str) -> str:
        """Remove the wake phrase and return whatever command follows it."""
        t = text.lower()
        for w in self.WAKE_PHRASES:
            idx = t.find(w)
            if idx != -1:
                rest = text[idx + len(w):].strip().lstrip(",. ")
                return rest
        return text

    def _activate(self) -> None:
        self._active   = True
        self._active_t = time.time()
        print(f"\r  {GRN}{BOLD}[VOICE]{R} Hey! How can I help? (speak your command…)   ")
        print(f"{PRP}jarvis>{R} ", end="", flush=True)

    def _deactivate(self) -> None:
        self._active = False
        print(f"\r  {DIM}[VOICE]{R} {DIM}Listening for 'Hey JARVIS'…{R}                  ")
        print(f"{PRP}jarvis>{R} ", end="", flush=True)

    def _dispatch(self, text: str) -> None:
        print(f"\r  {CYN}[VOICE]{R} Command: \"{text}\"")
        self.q.put(("voice", text))
        self._deactivate()

    # ── main loop ─────────────────────────────────────────────────────────────
    def run(self) -> None:
        if not VOSK_OK or _VoskModel is None or _VoskRec is None or _pyaudio is None:
            warn("VoiceListener started but Vosk is not available — exiting thread")
            return
        from typing import cast, Any
        VoskModel = cast(type, _VoskModel)
        VoskRec   = cast(type, _VoskRec)
        pa_mod    = cast(Any,  _pyaudio)
        try:
            model  = VoskModel(self.model_path)
            pa     = pa_mod.PyAudio()
            stream = pa.open(
                format=pa_mod.paInt16, channels=1,
                rate=self.RATE, input=True,
                frames_per_buffer=self.CHUNK,
            )
            stream.start_stream()

            def new_rec() -> Any:
                return VoskRec(model, self.RATE)

            rec = new_rec()
            ok("Microphone ready")
            self._deactivate()

            while self.running:
                if self.paused.is_set():
                    time.sleep(0.05)
                    continue

                # Active-state timeout — no command heard in time
                if self._active and (time.time() - self._active_t) > self.ACTIVE_TIMEOUT:
                    print(f"\r  {DIM}[VOICE]{R} {DIM}(no command heard — back to sleep){R}   ")
                    print(f"{PRP}jarvis>{R} ", end="", flush=True)
                    self._active = False
                    rec = new_rec()

                data     = stream.read(self.CHUNK, exception_on_overflow=False)
                is_final = rec.AcceptWaveform(data)

                if not self._active:
                    # ── WAITING: watch for wake phrase ────────────────────────
                    # Check partial result first for near-instant response
                    partial = json.loads(rec.PartialResult()).get("partial", "")
                    if self._has_wake(partial):
                        cmd = self._strip_wake(partial)
                        if cmd:
                            # Wake + command in one breath
                            rec = new_rec()
                            self._dispatch(cmd)
                        else:
                            rec = new_rec()
                            self._activate()
                    elif is_final:
                        text = json.loads(rec.Result()).get("text", "").strip()
                        if self._has_wake(text):
                            cmd = self._strip_wake(text)
                            if cmd:
                                self._dispatch(cmd)
                            else:
                                rec = new_rec()
                                self._activate()
                else:
                    # ── ACTIVE: capture command ───────────────────────────────
                    if is_final:
                        text = json.loads(rec.Result()).get("text", "").strip()
                        if text and len(text) > 2:
                            rec = new_rec()
                            self._dispatch(text)

            stream.stop_stream()
            stream.close()
            pa.terminate()

        except Exception as exc:
            warn(f"Voice listener stopped: {exc}")

    def pause(self) -> None:
        self.paused.set()

    def resume(self) -> None:
        self.paused.clear()
        self._deactivate()

    def stop(self) -> None:
        self.running = False

# ── Text input thread ─────────────────────────────────────────────────────────
def _text_thread(input_q: queue.Queue):
    try:
        import readline as _readline  # type: ignore[import]  # noqa: side-effect only
        del _readline
    except ImportError:
        pass
    while True:
        try:
            print(f"{PRP}jarvis>{R} ", end="", flush=True)
            line = sys.stdin.readline()
            if not line:        # EOF
                input_q.put(("quit", ""))
                break
            # If a DANGEROUS confirmation is pending, route there instead
            cq = _confirm_q
            if cq is not None:
                cq.put(("text", line.rstrip("\n")))
            else:
                input_q.put(("text", line.rstrip("\n")))
        except (EOFError, KeyboardInterrupt):
            input_q.put(("quit", ""))
            break

# ── Banner ────────────────────────────────────────────────────────────────────
def banner(snap, voice_active):
    print(f"{PRP}{BOLD}", end="")
    print(r"     ██╗ █████╗ ██████╗ ██╗   ██╗██╗███████╗      ██████╗ ███████╗")
    print(r"     ██║██╔══██╗██╔══██╗██║   ██║██║██╔════╝     ██╔═══██╗██╔════╝")
    print(r"     ██║███████║██████╔╝██║   ██║██║███████╗     ██║   ██║███████╗")
    print(r"██   ██║██╔══██║██╔══██╗╚██╗ ██╔╝██║╚════██║     ██║   ██║╚════██║")
    print(r"╚█████╔╝██║  ██║██║  ██║ ╚████╔╝ ██║███████║     ╚██████╔╝███████║")
    print(r" ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝      ╚═════╝ ╚══════╝")
    print(f"  Autonomous Agent  ·  JarvisOS  ·  {'Voice + Text' if voice_active else 'Text'} Interface{R}")
    print()
    print(f"  {CYN}Host:{R}    {snap['hostname']}  |  {snap['distro']}  |  kernel {snap['kernel']}")
    print(f"  {CYN}CPU:{R}     {snap['cpu_model']}  ({snap['cpu_cores']} cores, {snap['cpu_pct']}% load)")
    print(f"  {CYN}RAM:{R}     {snap['avail_mb']} MB free  /  {snap['total_mb']} MB total")
    print(f"  {CYN}Thermal:{R} {snap['thermal']}°C")
    print(f"  {CYN}Model:{R}   {MODEL}")
    print(f"  {CYN}Log:{R}     {LOG_FILE}")
    print()
    mode = f"{GRN}voice + text{R}" if voice_active else f"{YEL}text only{R}"
    print(f"  Input mode: {mode}")
    print(f"  {DIM}Commands: sysmon | quit{R}")
    print()

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    if not MODEL:
        err("JARVIS_MODEL not set. Run via test-jarvis-ollama.sh")
        sys.exit(1)

    snap = sysmon()

    # KDE polkit askpass — must happen before any sudo command runs
    _setup_askpass()

    # Voice setup
    voice_active = (
        VOSK_OK
        and bool(VOSK_PATH)
        and Path(VOSK_PATH).exists()
    )

    banner(snap, voice_active)

    input_q: queue.Queue = queue.Queue()

    # Start voice listener
    vl: VoiceListener | None = None
    if voice_active:
        try:
            vl = VoiceListener(VOSK_PATH, input_q)
            vl.start()
        except Exception as exc:
            warn(f"Voice start failed: {exc}")
            vl = None

    # Start text input thread
    text_t = threading.Thread(target=_text_thread, args=(input_q,), daemon=True)
    text_t.start()

    # Graceful Ctrl-C
    def _sigint(_sig, _frame):  # noqa: signal handler — params required by API
        input_q.put(("quit", ""))
    signal.signal(signal.SIGINT, _sigint)

    # Main loop
    while True:
        try:
            source, user_input = input_q.get(timeout=0.5)
        except queue.Empty:
            continue

        low = user_input.strip().lower()

        if source == "quit" or low in ("quit", "exit", "q", "bye"):
            print(f"\n{PRP}JARVIS signing off.{R}\n")
            break

        if not user_input.strip():
            continue

        if low == "sysmon":
            snap = sysmon()
            jarvis(
                f"CPU {snap['cpu_pct']}%  |  "
                f"RAM {snap['avail_mb']} MB free  |  "
                f"{snap['thermal']}°C"
            )
            if source != "voice":
                print(f"{PRP}jarvis>{R} ", end="", flush=True)
            continue

        # Pause mic during execution so it doesn't pick up command output
        if vl:
            vl.pause()

        handle(user_input.strip(), snap)

        if vl:
            vl.resume()
            # Reprint prompt only if last input was from voice
            if source == "voice":
                print(f"{PRP}jarvis>{R} ", end="", flush=True)

    # Cleanup
    if vl:
        vl.stop()

if __name__ == "__main__":
    main()
