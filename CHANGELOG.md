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

## 2.0.0 — 2026-10-31

Brings the addon in line with @oddsockets/js 2.0.2, so Godot and web players
can share a room.

- **Breaking:** `publish_async` sends Dictionaries and Arrays as objects, not
  JSON strings. `message_received` hands you the same type the publisher sent;
  drop any `JSON.parse_string` on received messages.
- `user_id` is optional. On the token lane, identity comes from the token;
  with an API key it defaults to the key's user. `userId` is only sent when set.
- `presence_received` re-emits the full roster after every join and leave;
  new `OddSocketsChannel.get_occupants()`.
- Reconnect re-subscribes every channel before `connected` fires; new
  `reconnected` signal follows it.
- Subscribe defaults match JS: `retain_history` true, `max_history` 100.
- Fix: connecting again right after `disconnect_client()` was refused; the old
  socket's close is now completed first.
- tests/js_parity_regression.gd (keyless, no user_id) and tests/js_peer.js
  (a JS 2.0.2 client in the same room).
