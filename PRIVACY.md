# Privacy

[English](PRIVACY.md) · [Українська](PRIVACY.uk.md) · [Русский](PRIVACY.ru.md)

AI Limit Bar runs on the user's Mac and talks to no server of its own.

The app:

- does not collect analytics or telemetry;
- does not use its own server;
- does not read or store passwords, cookies, session storage, or API keys;
- does not request keyboard input, screen recording, microphone, camera, or broad file access;
- receives Codex account and limit information from the locally installed `codex app-server`;
- with **Automatic Claude updates** enabled, requests Claude limits from Anthropic's `api.anthropic.com/api/oauth/usage` using Claude Code's own sign-in, as described below;
- receives Claude Code rate-limit percentages and reset timestamps through its official local `statusLine` interface;
- can passively read Claude Desktop's local `plan-usage-history.json` usage cache for percentages, timestamps, and its non-secret organization identifier;
- can passively read the `cachedUsageUtilization` entry Claude Code itself keeps in `~/.claude.json` for percentages, reset times, and its non-secret account identifier. No other part of that file is used.

## Live Claude limits

Claude's local caches refresh only about once per prompt, so during a long agent run they do not move. To show current numbers, AI Limit Bar asks Anthropic directly, about once a minute, with the same request Claude Code's `/usage` command makes.

To authenticate that request, AI Limit Bar reads the `Claude Code-credentials` item from the login keychain through `/usr/bin/security` — the same tool Claude Code uses to store it, which is why no keychain prompt appears. It re-reads the item on every request because Claude Code replaces it whenever it renews the sign-in. Of that item, only the access token is used, held in memory for that one request, and sent only to `api.anthropic.com`. The refresh token in the same item is never used: renewing the sign-in here would rotate it away from Claude Code and sign Claude Code out. When the access token has expired or is rejected, AI Limit Bar asks Claude Code to renew its own sign-in by running Claude Code's local `/usage` command in the background: no model request, no cost, no saved session, and with hooks, MCP servers and auto-memory turned off. Claude Code then renews the token the same way any other open Claude Code window would. This happens only when the token has lapsed — roughly once every eight hours while Claude Code itself is not in use — and at most once every 10 minutes if it does not succeed. Until then the local sources below are shown instead. Nothing from the item is written to disk or logged.

The response contains only usage percentages and reset times; AI Limit Bar keeps the latest one in memory and does not write it to disk. If Anthropic answers with a rate limit, the app waits as long as the server asks, backing off up to 15 minutes.

Turning **Automatic Claude updates** off stops these requests entirely.

## Local Claude sources

When **Automatic Claude updates** is enabled, AI Limit Bar also adds a command to `~/.claude/settings.json` together with Claude Code's official `refreshInterval` option, so the status line re-runs every 30 seconds while a terminal session is open. Claude Code sends its normal status-line JSON to that command. AI Limit Bar stores only the two rate-limit percentages, reset timestamps, capture time, and last-change time. It does not store session identifiers, workspace paths, prompts, responses, or model context.

Claude Desktop's cache does not contain email, plan type, or reset times, so AI Limit Bar fills those in from the other sources. All sources are merged window by window and the newest value wins. Cached data stays visible and is used for status-bar selection regardless of age, because a quota does not move while Claude is idle; a window whose reset time has passed is shown as empty again. AI Limit Bar never launches, hides, or terminates Claude Desktop.

To decide which service to show, AI Limit Bar remembers the last usage percentages it saw for each service and when they last grew, in its own preferences.

## Other

When the user switches Codex accounts, Codex opens its official browser authentication flow. The new account becomes active for other local Codex tools on the same Mac.

The user can stop all polling through **Limit monitoring** or close the app through **Quit completely**.
