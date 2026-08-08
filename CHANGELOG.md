# Changelog

## 2.3.0 - 2026-08-08

- Replaced the removed custom Codex artwork with official `Codex.Color` from `@lobehub/icons` 5.15.0.
- Added a dual-provider menu-bar mode for concurrent Codex and Claude activity.
- Split the menu-bar progress track into two independently colored segments.
- Preserved Codex activity across app restarts and added a 30-minute shared-session window.

## 2.2.0 - 2026-08-08

- Restored the complete supplied Codex artwork instead of extracting its cloud silhouette.
- Added optional automatic Claude refresh through a brief hidden Claude Desktop launch.
- Kept Claude credentials private by letting the official app perform its own authenticated request.
- Automatically closes only the hidden Claude instance started by AI Limit Bar.

## 2.1.2 - 2026-08-08

- Rebuilt the Codex provider mark from the supplied SVG and WebP artwork.
- Removed unavailable Claude account and plan labels from the dashboard.
- Restored the compact single-line Claude freshness header.

## 2.1.1 - 2026-08-08

- Corrected the Codex mark using the official `@lobehub/icons` geometry.
- Added provider marks to both account-switching actions and refined icon alignment.
- Added safe Claude organization identification while keeping cache freshness visible.

## 2.1.0 - 2026-08-08

- Removed the duplicated active-limit header from the dashboard.
- Moved the active provider to the top and added a restrained highlight.
- Restored the 5-hour or 7-day window label in the menu bar.
- Replaced generic provider symbols with LobeHub Codex and Claude logos.
- Added a safe shortcut to Claude Desktop profile settings for switching accounts.

## 2.0.0 - 2026-08-08

- Renamed the app to AI Limit Bar.
- Added safe local Claude Desktop usage tracking without reading credentials.
- Added automatic provider selection based on critical limits, recent activity, and the frontmost AI app.
- Replaced the single-provider menu with a combined Codex and Claude dashboard.
- Added provider marks, freshness states, and stale-data protection.
- Preserved preferences and launch-at-login settings from Codex Limit Bar.

## 1.1.1 - 2026-07-19

- Made the limit gauge and information rows follow the full menu width on every language.

## 1.1.0 - 2026-07-19

- Added English, Ukrainian, and Russian interface languages.
- Added an in-app language selector with automatic restart.
- Added full README and privacy documentation in all three languages.
- Documented and tested the green, yellow, and red indicator thresholds.

## 1.0.0 - 2026-07-19

- Added the remaining-limit indicator to the macOS menu bar.
- Added detailed 5-hour and weekly limits with reset times.
- Added active Codex account display and account switching.
- Added manual refresh, monitoring pause, and launch at login.
- Added native light and dark appearance support.
- Added a Universal build for Apple Silicon and Intel.
