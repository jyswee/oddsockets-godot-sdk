# OddSockets Godot Demo

Two players, one window, two **separate live connections** — everything that
crosses the panel boundary travelled through OddSockets, never a local
shortcut. Each panel header names the worker that connection landed on.

## Run it

1. Open this repository in Godot 4.3+.
2. Open `demo/demo.tscn` and press Play.
3. Enter an API key (or set `ODDSOCKETS_API_KEY` before launching the editor).

## What it shows (all real frames)

- **Connection banner** — each panel shows its own worker assignment.
- **Roster** — "N PLAYING NOW", seeded by a presence query, kept live by
  join/leave pushes.
- **Chat feed** — publishes from one panel arrive in the other over the wire
  (the SDK never locally echoes).
- **Typing indicator** — `start_typing` from one panel renders "… is typing"
  in the other.
- **Match invites** — "Invite other player" sends an object payload; the other
  panel gets Accept/Decline buttons; the reply carries its own payload back,
  and the inviter's feed prints `replyPayload`, the echoed invite payload and
  the reason — the full cross-payload contract.
- **Achievement banner** — `unlock_achievement_async` broadcasts to every
  participant.

## Honesty note

Run two editor instances on two machines with the same channel and it behaves
identically — the two panels are independent clients and may even land on
different workers (watch the headers).
