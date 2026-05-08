# JARVIS OS — Demo Checklist

Quick stand demos. Each block is ~1–2 min. Pick by audience depth.

---

## 0. Setup (before anyone arrives)

- [ ] `./test-jarvis-ollama.sh` running in a visible terminal
- [ ] `/dev/jarvis` present: `ls /dev/jarvis`
- [ ] Sysmon sysfs readable: `cat /sys/class/misc/jarvis/sysmon/cpu_pct`
- [ ] KWallet unlocked (so ksshaskpass doesn't fail first try)
- [ ] Brave API key present: `ls ~/.config/jarvis/brave_api_key`
- [ ] Second terminal open for live kernel/policy output

---

## 1. Hook (30 sec — anyone stopping by)

**Point:** AI is a kernel citizen, not a wrapper on top.

```bash
ls /dev/jarvis
cat /sys/class/misc/jarvis/sysmon/cpu_pct
cat /sys/class/misc/jarvis/sysmon/mem_avail_mb
cat /sys/class/misc/jarvis/sysmon/thermal
```

> "This data comes from a custom kernel driver — not `top`, not a user-space daemon.
> The AI reads hardware state directly through the kernel."

---

## 2. Core Demo — AI System Queries (1 min)

**Ask JARVIS safe read-only questions. Show it classifies and executes.**

Prompts to type:
```
what is my CPU usage right now
how much RAM is available
what kernel version am I running
show me the top 5 processes by CPU
```

What to highlight:
- Response is structured JSON: `reasoning`, `commands[]`, `summary`
- Each command has a **tier** (`SAFE`) — no confirmation needed, runs instantly
- Data sourced from kernel sysfs, not a generic shell script

---

## 3. Policy Gate — DANGEROUS Tier (1 min)

**Show the AI asking for permission before touching system state.**

Prompts:
```
install vlc
update the system
```

What happens:
- JARVIS plans `pacman -S vlc` or `pacman -Syu`
- Classifies as **DANGEROUS**
- Prints the plan and waits for `y` confirmation
- On confirm → `sudo -A` → ksshaskpass GUI prompt for password → executes

What to highlight:
- AI cannot self-authorize destructive actions
- Kernel policy enforces rate limits (20 DANGEROUS ops/min max)
- This is a research result: **policy-gated autonomous agents**

---

## 4. Policy Gate — FORBIDDEN (30 sec)

**Show a hard block that cannot be overridden.**

Prompts:
```
delete everything on the disk
wipe root
run rm -rf /
```

What happens:
- JARVIS refuses outright — `FORBIDDEN` tier
- No confirmation dialog, no elevation, no execution
- Show it in the JSON response: `"tier": "FORBIDDEN"`

> "Even if you tell it to, it won't. The policy is in the kernel, not the prompt."

---

## 5. Web Search (1 min)

**Show JARVIS pulling live information from the web.**

Prompts:
```
search for the latest Linux kernel version
what is KDE Plasma 6
search for Wayland compositor news
```

What happens:
- ShellMCP `web_search` tool → Brave Search API (key in `~/.config/jarvis/brave_api_key`)
- Returns titles, URLs, descriptions for top results
- Falls back to SearXNG at trojanhoogle.pro if key missing

What to highlight:
- No API key committed to the repo — stored locally at `~/.config/jarvis/brave_api_key`, `chmod 600`
- Classified as `SAFE` tier — read-only, no state change, no confirmation needed
- Same policy gate applies: if someone asked JARVIS to "exfiltrate data", that's `FORBIDDEN`

---

## 6. App Launching with xdg-open (30 sec)

**Show AI opening a GUI app — no sudo.**

Prompts:
```
open firefox
open the file manager
open a PDF viewer
```

What happens:
- ShellMCP `open_app` tool → `xdg-open <target>`
- Auto-detects Wayland display session
- App opens, JARVIS confirms

What to highlight:
- GUI apps never get elevated — hard rule in policy
- xdg-open respects default app associations

---

## 6. MCP Ecosystem — dmcp (1 min, technical audience)

**Show the modular MCP server registry.**

```bash
dmcp list
dmcp browse --keyword desktop
dmcp browse --keyword kde
```

Show kwin-mcp is installed:
```bash
dmcp browse --keyword kwin
```

What to highlight:
- JARVIS uses MCP (Model Context Protocol) for tool dispatch
- `dmcp` is a custom MCP server registry — like an app store for AI tools
- Tools are sandboxed per server, policy-gated at the kernel level
- kwin-mcp: 30 tools for KDE Plasma Wayland automation (app launch, window management, screenshots, D-Bus)

---

## 7. Kernel Driver Deep-Dive (2 min, CS/OS audience)

**Show the actual kernel interface.**

```bash
# Character device
ls -la /dev/jarvis

# Sysfs metrics (live)
watch -n1 cat /sys/class/misc/jarvis/sysmon/cpu_pct

# Policy table
ls /sys/class/misc/jarvis/policy/
```

Drivers (`linux-jarvisos/drivers/jarvis/`):

| Driver | What it does |
|--------|-------------|
| `jarvis_core.c` | `/dev/jarvis` misc device + query ring buffer |
| `jarvis_sysmon.c` | CPU/memory/thermal via ioctl and sysfs |
| `jarvis_policy.c` | 4-tier policy engine with rate limiting |
| `jarvis_keys.c` | API key storage in Linux kernel keyring |
| `jarvis_dibs.c` | Zero-copy DIBS buffer for large inference payloads |

> "This is a patched kernel — JARVIS ships its own `linux-jarvisos` kernel with these drivers baked in."

---

## 8. Architecture Overview (talking points for poster)

```
User prompt
    ↓
LLM (Ollama, runs locally — no cloud)
    ↓
dispatch (Rust) — intent routing
    ↓
dmcp (Rust) — MCP server registry
    ↓
JARVIS Policy Gate — SAFE / ELEVATED / DANGEROUS / FORBIDDEN
    ↓
ShellMCP / FilesystemMCP / kwin-mcp / ...
    ↓
linux-jarvisos kernel (/dev/jarvis)
```

Key talking points:
- **Fully local** — Ollama runs on-device, no API keys, no internet required
- **Kernel-native** — AI reads hardware state and enforces policy at the kernel level
- **Open MCP ecosystem** — any MCP server can plug in; dmcp manages them
- **Security research** — 7-threat taxonomy discovered during live operation (see README)

---

## 9. Threat / Security Angle (research audience)

JARVIS OS discovered novel AI security threats during development:

1. Prompt injection via tool output
2. Privilege escalation through chained ELEVATED commands
3. Policy bypass via ambiguous natural language
4. **"Forgetful context" (#7)** — LLM silently drops security constraints mid-session

Active mitigations in the codebase:
- Scoped sudo rules
- Persistent constraint register (in progress)
- GPG verification for dmcp server manifests (planned)
- Path-based write rules in `jarvis_policy.c` for `/etc`, `/usr`, `/boot` (planned)

---

## Quick-fire demo prompts (pick any)

```
what is my hostname
show me disk usage
what GPU do I have
check if bluetooth is running
show me network interfaces
what processes are listening on ports
```

All → `SAFE` tier → instant, no confirmation.

---

## If something breaks

| Problem | Fix |
|---------|-----|
| Ollama not responding | `systemctl --user start ollama` or `ollama serve &` |
| `/dev/jarvis` missing | Running stock kernel — boot into jarvisos kernel |
| ksshaskpass not found | `sudo pacman -S ksshaskpass` |
| dmcp not found | `/usr/local/bin/dmcp` — check PATH |
| xdg-open fails silently | Check `WAYLAND_DISPLAY` in env: `echo $WAYLAND_DISPLAY` |
| Web search fails | Check Brave key: `cat ~/.config/jarvis/brave_api_key` — fallback is SearXNG at trojanhoogle.pro |
| SearXNG fallback fails | Check network: `curl -s "https://trojanhoogle.pro/search?q=test&format=json" \| head -c 200` |
