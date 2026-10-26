# OddSockets Godot SDK

Official Godot 4 addon for the OddSockets real-time messaging platform. Pure GDScript — no native builds, works on every Godot export target. Pub/sub channels, presence, message history, plus game features: challenges, leaderboards, achievements and directed 1:1 invites.

## Install

Copy the `addons/oddsockets/` folder into your project's `addons/` directory.
The classes register globally (`OddSocketsClient`, `OddSocketsConfig`,
`OddSocketsChannel`, `OddSocketsEnhancedFeatures`) — enabling the plugin under
Project Settings → Plugins is optional.

Requires Godot **4.3+**.

## Quick Start

```gdscript
var client := OddSocketsClient.new()
add_child(client)  # the client polls its connection every frame

var config := OddSocketsConfig.new()
config.api_key = "YOUR_API_KEY"
config.user_id = "player-123"
client.initialize(config)
await client.connect_async()

var channel := client.get_channel("my-channel")
channel.message_received.connect(_on_message)
channel.presence_changed.connect(_on_roster_changed)  # joins/leaves
await channel.subscribe_async({"enable_presence": true, "retain_history": true})

await channel.publish_async({"move": "e4"})  # dictionaries are JSON-encoded
```

Presence and history are queries, not pushes:

```gdscript
var presence := await channel.get_presence_async()   # { occupancy, occupants }
var history := await channel.get_history_async(50)   # { messages, count }
```

Note: `retain_history` **stores** messages server-side, it does not replay them
into `message_received` — late joiners subscribe first, then call
`get_history_async()`.

Messages are capped at **32KB** (UTF-8 bytes). `publish_async` checks the limit
client-side; `OddSocketsMessageSizeValidator.get_message_size_info(text)` lets
you check earlier (e.g. before letting a player hit send).

## Game Features

Scored challenges, leaderboards, achievements and directed 1:1 invites. Method
names mirror the Unity SDK one-to-one (`SendChallengeInviteAsync` →
`send_challenge_invite_async`, same arguments in the same order), so a project
ported from the Unity build maps line-for-line.

```gdscript
var game := OddSocketsEnhancedFeatures.new()
game.initialize(client)

# Receive invites and replies
game.challenge_invited.connect(func(data):
	print("%s invited you: %s" % [data.from.userId, data.payload]))
game.challenge_reply_received.connect(func(data):
	# data.replyPayload = the replier's own object
	# data.payload      = your original invite payload, echoed back
	# data.reason       = the replier's free-text note
	print("reply: accept=%s loadout=%s" % [data.accept, data.replyPayload.get("loadout")]))

# Invite another player: the payload travels as a JSON object (8KB max)
var invite := await game.send_challenge_invite_async(
	"player-456", "match", {"arena": "ruins", "seed": 42}, 120)

# Answer an invite with your own payload and a note
await game.reply_challenge_invite_async(invite_id, true, {"loadout": "bow"}, "gl hf")

# Challenges and leaderboards
await game.create_challenge_async("weekly-sprint", "score", true)
game.report_progress_async("weekly-sprint", 1250.0)
var standings := await game.get_standings_async("weekly-sprint", 10)

# Achievements
game.unlock_achievement_async("first-win", "First Win!")
game.get_achievements_async()  # results arrive on the achievement_state signal
```

Signals: `challenge_invited`, `challenge_reply_received`,
`challenge_invite_cancelled`, `challenge_invites`, `achievement_state`,
`standings_data`, `leaderboard_rank_change`, `challenge_progress`,
`challenge_complete`, `user_typing`, `reaction_added`, `reaction_removed`.

Anything not surfaced as a typed signal arrives on the client's
`enhanced_event(event_name, data)` signal, and `client.emit_async(event, payload)`
sends custom events.

## Token Auth

Player devices should not carry your API key. Exchange a short-lived token
server-side and hand it to the client via a **token provider** — it is called
before every (re)connect and again `token_refresh_lead_seconds` (default 60)
before the token expires:

```gdscript
var config := OddSocketsConfig.new()
config.user_id = "player-123"   # no api_key: token auth
client.initialize(config)

client.token_provider = func() -> Dictionary:
	var fresh = await MyBackend.mint_realtime_token()  # your server does the exchange
	return {"token": fresh.token, "expires_at": fresh.expires_at}  # ISO 8601

await client.connect_async()
```

Prefer signals? Connect `token_requested` and answer each firing with
`provide_token({"token": ..., "expires_at": ...})`.

## Get an API Key

```bash
curl -X POST https://oddsockets.com/api/agent-signup \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com", "agentName": "my-agent", "platform": "godot"}'
curl -X POST https://oddsockets.com/api/agent-signup/verify \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com", "code": "123456", "agentName": "my-agent"}'
```

## Plans

No free tier — every plan starts with a 7-day free trial.

| | Starter | Pro | Scale | Enterprise |
|---|---|---|---|---|
| **Price** | $29/mo | $99/mo | $299/mo | Contact sales |
| **Messages/mo** | 5M | 25M | 100M | Unlimited |
| **Peak connections** | 200 | 1,000 | 5,000 | Unlimited |
| **MAU** | Unlimited | Unlimited | Unlimited | Unlimited |
| **Extra messages** | $2.50/M | $1.60/M | $1.00/M | Included |

Current pricing: [oddsockets.com/#pricing](https://oddsockets.com/#pricing).

## Get Accredited

<a href="https://tyga.games/accreditation"><img src="https://prodmedia.tyga.host/public/tyga.cloud/landing/tyga.games/tygagames-black-words.svg" alt="tyga.games accreditation" height="44"></a>

Prove you can build and operate real-time features on OddSockets — channels, presence, pub/sub, delivery guarantees and production liveops — on the stack itself. Three tiers (**TCU / TCA / TCP**), certified through **tyga.games** and delivered on ClassaaS.

## Support

- Documentation: [docs.oddsockets.com](https://docs.oddsockets.com)
- Issues: open one on this repository

## License

MIT — see [LICENSE](LICENSE).

---

OddSockets - A division of Tyga.Cloud Ltd
