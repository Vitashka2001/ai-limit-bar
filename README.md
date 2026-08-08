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
- always prioritizes a fresh critical limit below 20%;
- shows every detected 5-hour and weekly quota;
- green at 50–100%, yellow at 20–49%, and red below 20%;
- supports Codex account switching and opens Claude Desktop directly at profile settings;
- marks stale Claude data instead of presenting it as current;
- English, Ukrainian, and Russian interface languages;
- manual refresh, monitoring pause, and launch at login.

## Data Sources

Codex data comes from the locally installed `codex app-server`. Claude data comes from Claude Desktop's local `plan-usage-history.json` cache. The app never reads browser cookies, session storage, passwords, tokens, or API keys.

Claude Desktop must run to keep its local usage cache fresh. The cache does not contain reset timestamps, so AI Limit Bar shows its update time instead. Claude data older than 15 minutes remains visible as cached data but is excluded from automatic menu-bar selection.

Claude Code usage in a supported IDE can count toward the same subscription limits, but AI Limit Bar currently reads the Claude Desktop cache. Open Claude Desktop whenever the displayed Claude data needs to refresh. Third-party IDE extensions using an API provider may have separate billing and limits.

## Requirements And Installation

- macOS 13 Ventura or newer;
- Codex or the official Codex editor extension for Codex limits;
- Claude Desktop for Claude limits.

Download `AI-Limit-Bar-2.1.2.dmg` from the [latest release](https://github.com/Vitashka2001/ai-limit-bar/releases/latest), drag **AI Limit Bar** into `Applications`, and launch it.

The public build is locally signed but not notarized. If macOS blocks the first launch, right-click the app, choose **Open**, and confirm once.

## Controls

- **Limit monitoring** pauses all background updates.
- **Switch Codex account...** opens Codex's official browser sign-in.
- **Switch Claude account...** opens Claude Desktop profile settings for sign-out and account switching.
- **Language** changes the interface language and restarts the app.
- **Launch at login** controls automatic startup.
- **Quit completely** closes the app.

To disable the utility completely, turn off **Launch at login** and choose **Quit completely**. Open it again from `Applications` whenever needed.

## Build

```sh
swift test
./scripts/build-app.sh
./scripts/package-release.sh
```

The app is written to `dist/AI Limit Bar.app`. See [PRIVACY.md](PRIVACY.md) for the full privacy note.

Codex and Claude provider logos come from [LobeHub Icons](https://github.com/lobehub/lobe-icons) `@lobehub/icons` 5.15.0 under the MIT License. The bundled license is in `Resources/ProviderIcons/LICENSE`.

AI Limit Bar is an independent open-source utility and is not affiliated with OpenAI or Anthropic. Released under the [MIT License](LICENSE).
