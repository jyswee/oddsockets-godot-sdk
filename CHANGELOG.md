# Changelog

## 1.0.0 — 2026-10-26

Initial release.

- Pure GDScript addon for Godot 4.3+ (no native builds; all export targets).
- Core: connect/disconnect with auto-reconnect, channel pub/sub, presence
  (queries + join/leave pushes), retained history, 32KB client-side message
  validation.
- Game features with Unity-parity method names: challenge invites
  (object payloads both directions — the reply's payload reaches the inviter
  as `replyPayload`), challenges, progress, standings, achievements, typing
  indicators, reactions.
- Token auth: `token_provider` callable or `token_requested`/`provide_token`
  signal pair, with automatic pre-expiry refresh.
- Verified with a two-client live regression (tests/two_client_regression.gd):
  cross-connection delivery, presence, history, invite/reply payload
  round-trip, oversize rejection — 17/17 passing at release.

## 1.0.1 — 2026-10-26

- `OddSocketsClient.worker_info` — the worker assignment (`workerId`, `url`)
  this connection landed on, for on-screen connection indicators.
- demo/ — two-player demo scene: two live connections in one window showing
  roster, chat, typing, the full invite/replyPayload flow and achievement
  banners, with per-panel worker indicators.
