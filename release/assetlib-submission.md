# Godot Asset Library submission — prepared values

Everything below is ready to paste into the submission form at
https://godotengine.org/asset-library/asset (requires the asset-library
account; submitting is the founder's manual act, same as npm publishes).

| Field | Value |
|---|---|
| Asset name | OddSockets |
| Category | Scripts |
| License | MIT |
| Godot version | 4.3 |
| Version string | 1.0.1 |
| Repository provider | GitHub |
| Repository URL | https://github.com/jyswee/oddsockets-godot-sdk |
| Issues URL | https://github.com/jyswee/oddsockets-godot-sdk/issues |
| Download commit | the `v1.0.1` tag commit |
| Icon URL | https://prodmedia.tyga.host/public/tyga.cloud/landing/oddsockets.com/oddsockets-logo.png |
| Description | see below |

## Description

Real-time messaging for Godot games in pure GDScript — no native builds, every
export target. Pub/sub channels, presence, retained message history, and game
features: scored challenges, leaderboards, achievements, typing indicators and
directed 1:1 match invites with object payloads both ways. Awaitable API
(`await channel.publish_async(...)`) with typed signals for pushes,
auto-reconnection with automatic channel resubscription, and token auth for
player devices (token provider callback with pre-expiry refresh). Requires an
OddSockets account (7-day free trial on every plan). Docs:
https://docs.oddsockets.com/godot/docs/

## After acceptance

Bump the "Version string" and "Download commit" fields on each tagged release
(the library serves a zip of the tagged commit; no re-review for updates from
the same repo).
