# VibeDeck 🧠

<p align="center">
  <img src="Resources/AppIcon_1024.png" width="100" height="100" alt="VibeDeck Icon" />
</p>

<h3 align="center">The Native macOS Menu Bar Dashboard for Vibe Coders</h3>

<p align="center">
  <b>Reap orphaned MCP zombie processes · Monitor AI quotas & 5h/weekly reset countdowns · Track Token costs & Prompt Cache hit rates in real time.</b>
</p>

<p align="center">
  <a href="https://github.com/xixilys/vibedeck/releases"><img src="https://img.shields.io/github/v/release/xixilys/vibedeck?style=flat-square&color=blue" alt="Release"></a>
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B-lightgrey?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Language-Swift%20%2F%20SwiftUI-orange?style=flat-square&logo=swift" alt="Swift Native">
  <img src="https://img.shields.io/badge/Dependencies-Zero%20(Pure%20Native)-success?style=flat-square" alt="Zero Dependencies">
  <img src="https://img.shields.io/badge/Privacy-100%25%20Local-blueviolet?style=flat-square" alt="100% Local">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <b>🇺🇸 English</b> •
  <a href="README_zh.md">🇨🇳 简体中文</a>
</p>

> **Fork notice.** VibeDeck is a fork of [**VibeGauge**](https://github.com/MaxHaiCom/vibe-gauge) by [@MaxHaiCom](https://github.com/MaxHaiCom), released under the MIT License. All credit for the original app goes to its author; this fork is maintained independently by [@xixilys](https://github.com/xixilys) and is not affiliated with or endorsed by upstream.
>
> **What this fork adds:** a translucent glass panel redesign · per-account quota tiles across local and remote devices · Codex process monitor · a System tab (CPU / GPU / memory / temperatures) · SMC fan control through a privileged helper with a smooth PI "Smart cooling" mode that targets the hottest core · first-token latency per device · mixed-currency daily totals · bounded system probes so a stalled network mount can no longer freeze the scan.
>
> The bundle ID is `io.github.xixilys.vibedeck`, so it installs side by side with upstream VibeGauge and does not share its settings.

---

<p align="center">
  <img src="assets/dashboard_subscription.png" width="48%" alt="Subscription & Quota Dashboard" />
  &nbsp;
  <img src="assets/dashboard_system.png" width="48%" alt="System & MCP Process Cleaner" />
</p>

---

## 💡 Why VibeDeck?

When using autonomous coding agents like **Claude Code**, **OpenAI Codex**, **Google Antigravity (agy)**, or **Grok CLI**, developers encounter three recurring frustrations:

1. **🧟‍♂️ Memory Leaks from Orphaned MCP Servers**:
   Every time an agent spins up or aborts, headless `node` or `python` Model Context Protocol (MCP) server processes are left behind (`PPID == 1`). Over days of coding, dozens or hundreds of these zombie processes quietly hoard **5 GB to 10 GB of RAM**, triggering heavy swap and system thermal throttling.
2. **⏳ Quota Blind Spots & "Reset Anxiety"**:
   Each vendor uses a different quota model — Claude's dynamic 5-hour rolling window and 7-day limits, Codex's weekly quotas, Gemini's credit pools. Wondering if your quota has reset or when you can code again usually requires hitting rate limits in the terminal or opening vendor dashboards.
3. **📊 Token Costs & Prompt Cache Black Hole**:
   How many tokens did you burn today? Is Prompt Caching actually hitting 95%+ to save your budget? How much thinking/reasoning token overhead was generated?

**VibeDeck** is built entirely with native **Swift + AppKit + SwiftUI**. It has **zero third-party dependencies and no prompt or usage-log uploads**. Usage analysis stays local; the Network tab makes only the trace requests documented below.

---

## ✨ Features

- 🧹 **One-Click Orphaned MCP Reaper**:
  - Automatically identifies headless MCP servers (`PPID == 1`, no listening ports, not on system whitelist, matches MCP signatures).
  - Multi-tier safety guards prevent accidental kills of legitimate dev tasks.
  - One-click clearing of `~/.npm/_npx` cache bloat.
  - Optional silent background sweep every 30 minutes.
- ⏱️ **Unified AI Quota & Reset Timers**:
  - **Claude**: Captures subscription tier (Max 5x / Max 20x / Pro / Team), 5-hour percentage, 7-day quota, and exact countdown to reset.
  - **Codex**: Detects primary `codex` bucket usage, identifies `usage_limit_exceeded` exact unlock timestamps, and supports optional passwordless SSH synchronization from multiple remote dev machines (WSL, Linux, other Macs).
  - **Gemini / Antigravity**: Tracks official and 3rd-party quota pools with respective reset dates.
  - **Grok**: Reads weekly credit usage and billing cycle reset boundaries.
  - **Local Model Probing**: Detects running Ollama / LM Studio instances and active models.
- 🧮 **opencode & Chinese-model usage**:
  - Reads opencode's local SQLite database per message, so DeepSeek / GLM / Kimi and other models opencode drives are counted in the Statistics tab.
  - Optional password-less SSH pull from WSL / Linux / other Macs, with usage tagged per host (e.g. `OpenCode · wsl-box`).
- 📈 **Today's Token Analytics & Prompt Cache ROI**:
  - Aggregated daily stats: hundreds of millions in context tokens, output tokens, and thinking/reasoning tokens.
  - Real-time Prompt Cache hit rate calculations (e.g. 97.4% hit rate).
  - Live inspector capturing the latest 3 interaction rounds (model name, latency, cache hit %, tokens).
- 🔌 **Built-in Transparent API Key Proxy (Optional)**:
  - For direct API calls (e.g. routing Claude Code or scripts to GLM, DeepSeek, Kimi, MiniMax, OpenRouter).
  - Runs a local proxy daemon on `127.0.0.1:18790` with zero configuration needed.
  - Fetches plan tiers & remaining balances automatically while keeping keys strictly in memory.
- 🖥️ **macOS Native Craftsmanship**:
  - Pure Swift native app — starts instantly and sips minimal system resources.
  - Menu bar icon shows live available memory percentage.
  - Adaptive panel height with **two-finger trackpad swipe** to switch tabs smoothly.

---


### New in this version

- **One overview across Herdr devices**: enabled Herdr SSH machines are discovered automatically and merged with manual `remoteHosts`. Claude, Codex, Grok and Antigravity quota readings are grouped by platform and labelled by device. Account percentages are never added together; expired, undated, unavailable and retained readings are distinguished. Collection is read-only and uses existing SSH connections without changing credentials or providers. Coverage depends on the metadata available from each CLI.
- **Clearer daily statistics**: fresh input and cached input are shown separately; reasoning remains a subset of output. API-equivalent estimates sit below usage and remain separate from subscription bills. Local history appears before slow remote scans finish, and failed refreshes retain their history with a visible explanation.
- **Daily API-equivalent cost & forecast** (ccusage-compatible accounting): a dated reference catalog (`Resources/prices.builtin.json`) includes newly verified official OpenAI rates; other entries retain their reference sources. Your `prices.json` always wins. The **Prices** page shows input, output and cache rates, sources and long-context rules. Built-in models account for supported cache, long-context and Fast tiers; custom rates follow their explicit override rules. Claude and Codex requests are de-duplicated, including archived rollout copies and replayed fork usage. Today's estimate uses the 28-day hourly profile; monthly extrapolation requires at least seven prior recorded days, otherwise month-to-date is shown. Device filters apply to costs, forecasts and the heatmap.
- **WSL / Linux / other-Mac daily usage**: `remoteHosts` (SSH, incremental, compressed, only `python3` needed remotely) or `mountRoots` (`label=/mounted/home`, read directly). Switch devices at the top of the panel.
- **Model "nerf" detection** (inspired by [is-gpt-nerfed](https://github.com/kiyoakii/is-gpt-nerfed), passive, 0 tokens): silent model swaps, reasoning-effort drops, hidden internal models and shrinking context windows in Codex; Claude Code switching to a smaller tier without `/model`; unusually short answers vs your 2-week median. If is-gpt-nerfed is installed its ModelTrace fingerprint verdicts are shown too. Hard evidence adds a dot to the menu bar icon and sends a notification.
- **macOS-style panel**: HIG type scale, continuous-corner cards, System Settings–style icons, SF Symbols, monospaced digits, light & dark. `VibeDeck --render-panel <dir>` renders every page to PNG.

## 🚀 Quick Start

### Method 1: Download Pre-built Binary (Recommended)

> Universal app — runs on **Apple Silicon and Intel** Macs with **macOS 14+**. The UI follows your system language (English / 简体中文).

1. Download the latest `VibeDeck.zip` from [GitHub Releases](https://github.com/xixilys/vibedeck/releases).
2. Unzip and drag `VibeDeck.app` into your `/Applications` folder.
3. Launch it. The icon will appear in your top menu bar.

> **Tip**: On first launch, if prompted by macOS Gatekeeper, click "Open Anyway" in `System Settings → Privacy & Security`. If you use menu-bar management utilities like Bartender or Ice, make sure VibeDeck isn't hidden in a collapsed drawer.

---

### Method 2: Build from Source in 3 Seconds (Zero Dependencies)

No heavy Xcode installation required — only macOS standard command line tools (`swiftc`):

```bash
# 1. Clone the repository
git clone https://github.com/xixilys/vibedeck.git
cd vibedeck

# 2. Build and bundle
./build.sh

# 3. Launch
open VibeDeck.app
```

#### Headless & CLI Flags

```bash
# Verify parsing logic and output a single terminal snapshot (no UI launched)
./VibeDeck.app/Contents/MacOS/VibeDeck --selftest

# Install / Uninstall the background API accounting proxy daemon
./VibeDeck.app/Contents/MacOS/VibeDeck --install-proxy
./VibeDeck.app/Contents/MacOS/VibeDeck --uninstall-proxy
```

---

## 🔍 Data Sources & Freshness

All subscription tiers, quotas, and token metrics are read strictly from local session logs or vendor cache files:

Token totals and API-equivalent costs cover collected local, SSH and mounted-device session records. **All** combines those devices' daily tokens; after the first history scan, it uses the same daily records as Statistics, including archived sessions. **Codex cloud tasks started by Dot are not yet included.** Executing their tools on a Mac does not produce local model-usage logs. Missing cloud usage is unknown, not zero, and is not inferred from quota percentages or context length.

| Provider | Plan Detection | Quotas & Reset Timestamps | Update Frequency |
|:---|:---|:---|:---|
| **Claude** | `~/.claude.json`<br>(e.g. `max_5x`, `max_20x`, `pro`) | `~/.claude/claude-usage.json`<br>(Statusline-intercepted 5h / 7d rates & reset points) | Automatically updates on every dialogue round |
| **Codex** | `~/.codex/auth.json`<br>(JWT `chatgpt_plan_type`) | Session jsonl `rate_limits`<br>(Extracts exact unlock time from `task_complete` errors) | Updates only when requests are actively sent |
| **Gemini** | Local auth token verification | `~/.cache/agy-hud/quota_cache.json`<br>(Split by primary & 3rd-party model pools) | Refreshed by background helper while agy runs |
| **Grok** | `~/.grok/settings_cache.json` | `~/.grok/logs/unified.jsonl`<br>(Latest billing credits config & period end) | Periodically flushed by Grok CLI |
| **opencode** | opencode's own SQLite DB<br>(`providerID` / `modelID` per message) | Non-quota based<br>(`~/.local/share/opencode/opencode.db`, per-message tokens) | Re-read in full on each Statistics scan |
| **Ollama** | Local socket & process probe | Non-quota based (monitors active on-device models) | Instant live status |

> 📌 *Note*: Footnotes such as "Recorded 1h ago" represent the **timestamp when the vendor CLI last refreshed its local log**, not a lag in VibeDeck. The panel reads existing snapshots every five seconds while open and releases its view when closed. Process and quota collection runs every eight seconds, including while the menu is open; the panel does not start a duplicate scanner. Unchanged menu-bar icons are reused.

---

## Network and Historical Statistics

The panel has five tabs: **Subscriptions / API / Statistics / Network / System**.

- **Network** probes only each AI domain's `/cdn-cgi/trace` endpoint (Anthropic, ChatGPT, OpenAI API and Grok), once per minute with fresh connections. Gemini has no trace endpoint; its route is shown only when the local clash connection table contains an active connection. Failures remain visible as unavailable.
- The local clash API is read every 10 seconds (`clashAPI`, default `http://127.0.0.1:9090`; optional `clashSecret`). Only loopback addresses are accepted. Local interface, route and DNS information refresh every 30 seconds; byte counters are sampled at least two seconds apart. No network configuration is changed.
- Every 10 minutes, an IPv6-only request to Cloudflare's trace endpoint checks IPv6 reachability, and local resolver addresses are checked for possible DNS leakage. These are indicators, not proof that all traffic follows the same route. Exit-change notifications are enabled by default, with a 10-minute cooldown per AI.
- **Statistics** reads local Claude, Codex, opencode and API proxy logs in the background, then updates incrementally every five minutes. Claude requests are deduplicated across files; Codex uses per-request usage when available and cumulative differences otherwise. opencode's database is re-read in full each scan (the message table is small) and its rows are keyed by message id, so re-reading never double counts. Events are grouped by their timestamps in the local timezone.
- Remote hosts configured via `remoteHosts` are pulled over password-less SSH. Codex quota is merged across all of them; opencode usage is fetched incrementally (`time_updated` cursor, with a full re-pull at least once a day). A host that fails keeps its previously cached contribution instead of being zeroed, and its status is shown in the Codex detail rows.
- History is stored in `~/.config/vibedeck/usage-daily.json`. Removing old logs retains their already-cached history; rewriting a file replaces its contribution. Session counts are distinct log files, or distinct opencode session ids for opencode sources. CLI and API proxy sources can include the same call and are not deduplicated against each other.
- API-equivalent costs use custom `~/.config/vibedeck/prices.json` rates first, then the built-in reference catalog. [GPT-6.1 Sol's verified official rates](https://developers.openai.com/api/docs/models/gpt-6.1-sol) are $2 input, $0.10 cached input, $2.50 cache write and $10 output per million tokens; long-context and Fast rules apply to the built-in entry. Custom rows do not inherit those multipliers. Set `fast_multiplier` on a custom row to explicitly surcharge recorded `priority` / `fast` requests (for example, `2` for Astra). Missing or `1` means no extra surcharge, including rows whose price already includes Fast. The factor applies once to input, cache and output after peak/off-peak selection. Each row may set `currency`; currencies stay separate. `_peak` and `offpeak` support time-of-day rates. The Prices page or `VibeDeck --sync-prices` fills missing rates from models.dev and refreshes unchanged, traceable synced rows. Manual and legacy rows without provenance are preserved; writes are backed up and stopped if the file changes during sync. Unpriced models remain excluded. Token totals include cached input and output; reasoning is included in output.

No prompts or usage logs are uploaded by these features. Network probes necessarily make the outbound requests described above. The optional existing API proxy and remote Codex synchronization retain their own behavior. `--selftest` skips remote SSH, exercises parsing and incremental-cache fixtures, and prints masked network and real historical summaries.

---

## 🛠️ API Key Accounting Proxy (Optional)

When routing terminal tools or scripts directly to AI provider endpoints, route requests through the local proxy to capture token analytics and credit balances:

1. **Install Proxy Daemon**:
   Click "Install API Proxy" in the API tab, or run:
   ```bash
   ./VibeDeck.app/Contents/MacOS/VibeDeck --install-proxy
   ```
   The proxy listens on `127.0.0.1:18790`.

2. **Zero-Config Routing**:
   Simply prefix your existing endpoint URL:
   ```bash
   # GLM (Zhipu AI)
   export ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://open.bigmodel.cn/api/anthropic
   
   # DeepSeek
   export OPENAI_BASE_URL=http://127.0.0.1:18790/https://api.deepseek.com/v1
   ```
   *(One-liner to prepend the proxy to all ANTHROPIC_BASE_URL declarations in `~/.zshrc`:)*
   ```bash
   perl -pi.bak -e 's#(ANTHROPIC_BASE_URL=["\x27]?)(?!http://127\.0\.0\.1:18790/)(https?://)#$1http://127.0.0.1:18790/$2#' ~/.zshrc
   ```

3. **Supported Providers**:
   - **GLM Coding Plan**: Automatic tier & 5h/weekly quota tracking
   - **OpenRouter**: Real-time remaining balance & credits calculation
   - **DeepSeek**: Balance endpoint integration
   - **Kimi / MiniMax / Volcano Ark / MiMo**: Streaming token usage accounting

---

## ⚙️ Configuration (Optional)

Everything works with zero config. These files and settings are only needed for the extras.

**Price table** — `~/.config/vibedeck/prices.json`. VibeDeck ships no built-in prices (they change too often; a wrong number is worse than none). Without it, "API-equivalent cost" is simply hidden.
```bash
mkdir -p ~/.config/vibedeck
curl -fsSL https://raw.githubusercontent.com/xixilys/vibedeck/main/Resources/prices.example.json -o ~/.config/vibedeck/prices.json
# then fill in per-million-token prices; model names match by longest prefix
```

**Request-based plan limits** — `~/.config/vibedeck/plans.json` (see [`Resources/plans.example.json`](Resources/plans.example.json)). For coding plans that expose no usage API, quota = requests counted by the local proxy ÷ the limit you enter, always labelled *estimated*.

**Advanced settings** (`defaults write io.github.xixilys.vibedeck <key> <value>`, then restart the app):

| Key | Default | Purpose |
|-----|---------|---------|
| `logRetentionDays` | `30` | Session logs older than this are offered for cleanup (min 7) |
| `clashAPI` | `http://127.0.0.1:9090` | Clash / mihomo / sing-box controller for the Network tab (loopback only) |
| `clashSecret` | — | Controller secret, if you set one |
| `remoteHosts` | off | Space/comma-separated `user@host` list with password-less SSH; merges Codex quota and opencode usage from WSL / Linux / other Macs. The old single-host `codexRemoteHost` key is still accepted |

---

## 🗑️ Uninstall

```bash
/Applications/VibeDeck.app/Contents/MacOS/VibeDeck --uninstall-proxy   # only if you installed the proxy
rm -rf /Applications/VibeDeck.app ~/.config/vibedeck
defaults delete io.github.xixilys.vibedeck
```
If you enabled *Launch at Login*, turn it off in the menu first (or remove it in System Settings → General → Login Items). Remember to strip the `http://127.0.0.1:18790/` prefix from any `*_BASE_URL` you pointed at the proxy.

---

## 🛡️ Privacy & Security

- 🔒 **100% Local Execution**: No analytics, no telemetry, no remote servers. Your token counts and usage data never leave your Mac.
- 🔑 **Zero Key Disk Logging**: API keys processed by the local proxy remain strictly in volatile process memory for upstream balance checks. Recorded logs only store an 8-character SHA-256 fingerprint; URL query parameters are stripped.
- ⚙️ **Non-Intrusive**: VibeDeck reads local logs and network settings, and makes the documented trace probes. It does not tamper with OAuth credentials, proxy your login sessions, or modify vendor or system network configurations.
- 🛡️ **Whitelisted Safe Reaping**: The process cleaner strictly enforces multi-criteria verification before terminating orphaned processes.

---

## 🤝 Contributing

Contributions, feature requests, and bug reports are warmly welcomed — see [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: please report privately, see [SECURITY.md](SECURITY.md).
- Discover a new MCP process pattern? Please open a PR to update the signature filters.
- Vendor changed their log format or introduced a new quota tier? Feel free to submit an issue.

---

## 📄 License

Released under the [MIT License](LICENSE).
