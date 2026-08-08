# Privacy

[English](PRIVACY.md) · [Українська](PRIVACY.uk.md) · [Русский](PRIVACY.ru.md)

AI Limit Bar runs entirely on the user's Mac.

The app:

- does not collect analytics or telemetry;
- does not use its own server;
- does not read or store passwords, cookies, session storage, access tokens, refresh tokens, or API keys;
- does not request keyboard input, screen recording, microphone, camera, or broad file access;
- receives Codex account and limit information from the locally installed `codex app-server`;
- reads only Claude Desktop's local `plan-usage-history.json` usage cache for Claude percentages, timestamps, and its non-secret organization identifier.

Claude's local cache does not contain email, plan type, or reset times. Data older than five minutes is marked as cached and is not used for automatic status-bar selection.

When **Keep Claude data current** is enabled, AI Limit Bar may launch Claude Desktop hidden so the official app can refresh its own cache. AI Limit Bar never reads Claude's session credentials and closes only the hidden Claude instance it launched itself.

When the user switches Codex accounts, Codex opens its official browser authentication flow. The new account becomes active for other local Codex tools on the same Mac.

The user can stop all polling through **Limit monitoring** or close the app through **Quit completely**.
