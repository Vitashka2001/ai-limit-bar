<p align="center"><img src="Resources/AppIcon.png" width="152" alt="AI Limit Bar icon"></p>
<h1 align="center">AI Limit Bar</h1>
<p align="center">Codex and Claude usage limits in the macOS menu bar.</p>
<p align="center"><strong>English</strong> · <a href="README.uk.md">Українська</a> · <a href="README.ru.md">Русский</a></p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-111111?logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <a href="https://github.com/Vitashka2001/ai-limit-bar/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Vitashka2001/ai-limit-bar/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/Vitashka2001/ai-limit-bar/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/Vitashka2001/ai-limit-bar"></a>
</p>

AI Limit Bar shows the most relevant fresh quota in the menu bar and all detected Codex and Claude limits in one native dashboard.

## Features

- automatically follows recent Codex or Claude activity;
- shows Codex and Claude side by side when both were active in the current 30-minute work session;
- always prioritizes a fresh critical limit below 20%;
- shows every detected 5-hour and weekly quota;
- shows each limit's reset date and time when supplied by Codex or Claude Code;
- lets you hide Codex or Claude from both the dashboard and menu-bar indicator;
- green at 50–100%, yellow at 20–49%, and red below 20%;
- supports Codex account switching and opens Claude Desktop directly at profile settings;
- polls live Claude limits about once a minute with Claude Code's own sign-in, the same way Codex is tracked;
- merges every local Claude source, so a percentage from one and a reset time from another appear together;
- offers official Claude Code and Desktop setup links when no live Claude source is available;
- keeps showing the last known Claude limit instead of a dash, and empties a window once its reset time passes;
- English, Ukrainian, and Russian interface languages;
- manual refresh, monitoring pause, and launch at login.

## Data Sources

Codex data comes from the locally installed `codex app-server`.

For Claude, the primary source is a live request to `api.anthropic.com/api/oauth/usage` — the request behind Claude Code's `/usage` command — sent about once a minute, right after waking from sleep, and when the menu opens. It authenticates with Claude Code's own sign-in, read from the login keychain through the same `/usr/bin/security` tool Claude Code uses, so no keychain prompt appears. Only the access token is used; the app never renews the sign-in itself, because that would sign Claude Code out. When the token has expired, live requests pause until Claude Code renews it on its next use. See [PRIVACY.md](PRIVACY.md) for exactly what is read and sent.

The local sources keep the indicator populated while the live request cannot run: the `cachedUsageUtilization` entry Claude Code keeps in `~/.claude.json` (refreshed about once per prompt), Claude Desktop's `plan-usage-history.json` (rewritten only while its window is in use), and the official Claude Code [`statusLine`](https://code.claude.com/docs/en/statusline) bridge, installed with `refreshInterval` so a terminal session reports every 30 seconds. The VS Code side panel does not run the status line. All sources are merged window by window — the newest percentage wins, and a reset time from an older source fills in while it still lies ahead. AI Limit Bar keeps the last known value instead of blanking the indicator, and a window whose reset time has passed is shown as empty again.

When the dashboard falls back to a local source, its status line says why — for example, that live limits resume once Claude Code runs. Third-party IDE extensions such as Cline can use separate API billing and may not expose Claude.ai subscription limits.

## Requirements And Installation

- macOS 13 Ventura or newer;
- Codex or the official Codex editor extension for Codex limits;
- official Claude Code for live Claude limits, or Claude Desktop for cached fallback data.

Download `AI-Limit-Bar-2.6.0.dmg` from the [latest release](https://github.com/Vitashka2001/ai-limit-bar/releases/latest), drag **AI Limit Bar** into `Applications`, and launch it.

The public build is locally signed but not notarized. If macOS blocks the first launch, right-click the app, choose **Open**, and confirm once.

## Controls

- **Limit monitoring** pauses all background updates.
- **Displayed services** hides Codex or Claude and stops that service's polling. At least one service remains visible.
- **Automatic Claude updates** turns on live Claude limits and the status-line bridge; turning it off stops all requests to Anthropic.
- **Switch Codex account...** opens Codex's official browser sign-in.
- **Switch Claude account...** opens Claude Desktop profile settings. Without Desktop, **Set up Claude tracking...** offers the official Claude Code guide and Desktop download.
- **Language** changes the interface language and restarts the app.
- **Launch at login** controls automatic startup.
- **Quit completely** closes the app.

To disable the utility completely, turn off **Launch at login** and choose **Quit completely**. Open it again from `Applications` whenever needed.

When no Claude source is configured, the setup recommendation appears automatically only once. It remains available later through **Set up Claude tracking...**, but refreshes never open it by themselves.

## Build

```sh
swift test
./scripts/build-app.sh
./scripts/package-release.sh
```

The app is written to `dist/AI Limit Bar.app`. See [PRIVACY.md](PRIVACY.md) for the full privacy note.

Codex and Claude provider logos come from [LobeHub Icons](https://github.com/lobehub/lobe-icons) `@lobehub/icons` 5.15.0 under the MIT License. The bundled license is in `Resources/ProviderIcons/LICENSE`.

AI Limit Bar is an independent open-source utility and is not affiliated with OpenAI or Anthropic. Released under the [MIT License](LICENSE).
