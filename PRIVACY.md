# Privacy

[English](PRIVACY.md) · [Українська](PRIVACY.uk.md) · [Русский](PRIVACY.ru.md)

AI Limit Bar runs entirely on the user's Mac.

The app:

- does not collect analytics or telemetry;
- does not use its own server;
- does not read or store passwords, cookies, session storage, access tokens, refresh tokens, or API keys;
- does not request keyboard input, screen recording, microphone, camera, or broad file access;
- receives Codex account and limit information from the locally installed `codex app-server`;
- receives Claude Code rate-limit percentages and reset timestamps through its official local `statusLine` interface;
- can passively read Claude Desktop's local `plan-usage-history.json` usage cache for percentages, timestamps, and its non-secret organization identifier.

When **Automatic Claude updates** is enabled, AI Limit Bar adds a command to `~/.claude/settings.json`. Claude Code can send its normal status-line JSON to that command after responses. AI Limit Bar stores only the two rate-limit percentages, reset timestamps, capture time, and last-change time. It does not store session identifiers, workspace paths, prompts, responses, or model context.

Claude Desktop's cache does not contain email, plan type, or reset times. Cached data older than five minutes remains visible but is not used for automatic status-bar selection. If fresh Claude Code data is unavailable, automatic updates may launch Claude Desktop hidden. AI Limit Bar tracks the exact process it started and terminates it after fresh data arrives or after a 30-second timeout. It never terminates a Claude Desktop process that was already running.

When the user switches Codex accounts, Codex opens its official browser authentication flow. The new account becomes active for other local Codex tools on the same Mac.

The user can stop all polling through **Limit monitoring** or close the app through **Quit completely**.
