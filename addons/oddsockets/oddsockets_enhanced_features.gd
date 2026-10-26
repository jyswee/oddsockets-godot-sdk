class_name OddSocketsEnhancedFeatures
extends RefCounted
## Game features: challenge invites, challenges, achievements, leaderboards,
## typing and reactions. Method names mirror the Unity SDK one-to-one
## (SendChallengeInviteAsync -> send_challenge_invite_async, same arguments in
## the same order), so ported game code maps line-for-line.

## An invite arrived: `{ inviteId, from, toUserId, type, payload, expiresAt }`.
## `payload` is the inviter's JSON object.
signal challenge_invited(data: Dictionary)
## The invitee answered: `{ inviteId, from, accept, type, payload, replyPayload,
## reason }`. `payload` echoes the original invite; `replyPayload` is the
## replier's own object.
signal challenge_reply_received(data: Dictionary)
## An invite was cancelled by the inviter.
signal challenge_invite_cancelled(data: Dictionary)
## Response to [method get_challenge_invites_async]: `{ invites }`.
signal challenge_invites(data: Dictionary)
## Achievement state: unlock broadcasts and [method get_achievements_async]
## responses.
signal achievement_state(data: Dictionary)
## Leaderboard standings: response to [method get_standings_async].
signal standings_data(data: Dictionary)
## This client's leaderboard rank changed.
signal leaderboard_rank_change(data: Dictionary)
## A participant reported challenge progress.
signal challenge_progress(data: Dictionary)
## A participant completed a challenge.
signal challenge_complete(data: Dictionary)
## Someone started/stopped typing: `{ userId, channel, isTyping }`.
signal user_typing(data: Dictionary)
## A reaction was added to a message.
signal reaction_added(data: Dictionary)
## A reaction was removed from a message.
signal reaction_removed(data: Dictionary)

var _client: OddSocketsClient


func initialize(client: OddSocketsClient) -> void:
	_client = client
	_client.enhanced_event.connect(_on_enhanced_event)


# ── Challenge invites ──

## Invite [param to_user_id] to a match. [param payload] travels as a JSON
## object and reaches the invitee's [signal challenge_invited] as-is (8KB max).
## [param ttl] seconds until the invite expires (0 = platform default).
## Returns `{ inviteId, ... }` or `{ "error": String }`.
func send_challenge_invite_async(to_user_id: String, type: String = "match",
		payload: Dictionary = {}, ttl: int = 0, channel: String = "") -> Dictionary:
	var req := {"toUserId": to_user_id, "type": type, "payload": payload}
	if ttl > 0:
		req["ttl"] = ttl
	if not channel.is_empty():
		req["channel"] = channel
	return await _client.request_async("challenge_invite", req, "challenge_invite_success")


## Answer an invite. [param payload] is this player's own JSON object — it
## reaches the inviter as `replyPayload` (8KB max); [param reason] is a short
## free-text note carried alongside it. Argument order matches Unity's
## ReplyChallengeInviteAsync(inviteId, accept, payload, reason).
func reply_challenge_invite_async(invite_id: String, accept: bool,
		payload: Dictionary = {}, reason: String = "") -> Dictionary:
	var req := {"inviteId": invite_id, "accept": accept}
	if not payload.is_empty():
		req["payload"] = payload
	if not reason.is_empty():
		req["reason"] = reason
	return await _client.request_async("challenge_reply", req,
		"challenge_reply_success", "inviteId", invite_id)


## Withdraw a pending invite; the invitee gets challenge_invite_cancelled.
func cancel_challenge_invite_async(invite_id: String) -> Dictionary:
	return await _client.request_async("challenge_invite_cancel",
		{"inviteId": invite_id}, "challenge_invite_cancel_success", "inviteId", invite_id)


## Pull this player's pending invites (e.g. on reconnect). Returns `{ invites }`.
func get_challenge_invites_async() -> Dictionary:
	return await _client.request_async("challenge_invites_query", {}, "challenge_invites")


# ── Challenges, achievements, leaderboards ──

## Create a challenge. [param options] may carry name, cohort, platform, etc.
func create_challenge_async(challenge_id: String, metric: String,
		ranked: bool = false, options: Dictionary = {}) -> Dictionary:
	var req := {"challengeId": challenge_id, "metric": metric, "ranked": ranked}
	req.merge(options)
	return await _client.request_async("challenge_create", req,
		"challenge_create_success", "challengeId", challenge_id)


## Report a progress value. Participants receive [signal challenge_progress].
func report_progress_async(challenge_id: String, value: float, metric: String = "") -> void:
	var req := {"challengeId": challenge_id, "value": value}
	if not metric.is_empty():
		req["metric"] = metric
	_client.emit_event("challenge_progress", req)


## Complete a challenge with an outcome ("won", "lost", ...). Returns the
## final standing: `{ challengeId, outcome, finalValue, rank }`.
func complete_challenge_async(challenge_id: String, outcome: String,
		options: Dictionary = {}) -> Dictionary:
	var req := {"challengeId": challenge_id, "outcome": outcome}
	req.merge(options)
	return await _client.request_async("challenge_complete", req,
		"challenge_complete_success", "challengeId", challenge_id)


## Top-N leaderboard standings. Returns `{ challengeId, standings, ... }`.
func get_standings_async(challenge_id: String, limit: int = 20, offset: int = 0) -> Dictionary:
	return await _client.request_async("challenge_standings",
		{"challengeId": challenge_id, "limit": limit, "offset": offset},
		"challenge_standings_success", "challengeId", challenge_id)


## Unlock an achievement, or report partial progress with
## [param percent_complete] < 100.
func unlock_achievement_async(achievement_id: String, name: String = "",
		percent_complete: float = 100.0) -> void:
	var req := {"achievementId": achievement_id, "percentComplete": percent_complete}
	if not name.is_empty():
		req["name"] = name
	_client.emit_event("achievement_unlock", req)


## Query achievement state (all, or one via [param achievement_id]). The
## response arrives on [signal achievement_state].
func get_achievements_async(achievement_id: String = "") -> void:
	var req := {}
	if not achievement_id.is_empty():
		req["achievementId"] = achievement_id
	_client.emit_event("achievement_query", req)


# ── Typing & reactions ──

func start_typing(user_id: String, channel: String) -> void:
	_client.emit_event("start_typing", {"userId": user_id, "channel": channel})


func stop_typing(user_id: String, channel: String) -> void:
	_client.emit_event("stop_typing", {"userId": user_id, "channel": channel})


func add_reaction(message_id: String, channel: String, emoji: String, user_id: String = "") -> void:
	var req := {"messageId": message_id, "channel": channel, "emoji": emoji}
	if not user_id.is_empty():
		req["userId"] = user_id
	_client.emit_event("add_reaction", req)


func remove_reaction(message_id: String, channel: String, emoji: String, user_id: String = "") -> void:
	var req := {"messageId": message_id, "channel": channel, "emoji": emoji}
	if not user_id.is_empty():
		req["userId"] = user_id
	_client.emit_event("remove_reaction", req)


func _on_enhanced_event(event_name: String, data: Dictionary) -> void:
	match event_name:
		"challenge_invited":
			challenge_invited.emit(data)
		"challenge_reply_received":
			challenge_reply_received.emit(data)
		"challenge_invite_cancelled":
			challenge_invite_cancelled.emit(data)
		"challenge_invites":
			challenge_invites.emit(data)
		"achievement_state", "achievement_unlock", "achievement_progress":
			achievement_state.emit(data)
		"challenge_standings_success":
			standings_data.emit(data)
		"leaderboard_rank_change":
			leaderboard_rank_change.emit(data)
		"challenge_progress":
			challenge_progress.emit(data)
		"challenge_complete":
			challenge_complete.emit(data)
		"user_typing":
			user_typing.emit(data)
		"reaction_added":
			reaction_added.emit(data)
		"reaction_removed":
			reaction_removed.emit(data)
