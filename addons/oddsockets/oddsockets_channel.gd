class_name OddSocketsChannel
extends RefCounted
## A named pub/sub channel. Obtain via [method OddSocketsClient.get_channel].
##
## Note on history: subscribing with `retain_history` stores messages
## server-side but does NOT replay them into [signal message_received] —
## late joiners subscribe first, then call [method get_history_async].

## A message published by any subscriber (including this client) arrived.
## [param message] is the full envelope: id, channel, message, publisher,
## timestamp. `message` is what the publisher sent: a Dictionary or Array
## stays one, a String stays a String.
signal message_received(message: Dictionary)
## Someone joined or left: `{ channel, action: "join"|"leave",
## user: { userId, joinedAt }, occupancy }`.
signal presence_changed(data: Dictionary)
## The full roster `{ channel, occupancy, occupants }`: the subscribe-time
## snapshot, every [method get_presence_async] answer, and again after every
## join or leave, so a roster drawn from it stays current.
signal presence_received(data: Dictionary)
## Response to [method get_history_async]: `{ channel, messages, count }`.
signal history_received(data: Dictionary)
## Publish acknowledgement: `{ messageId, channel, timestamp, subscriberCount }`.
signal published(data: Dictionary)
## Subscription confirmed.
signal subscribed(data: Dictionary)
## Unsubscribe confirmed.
signal unsubscribed(data: Dictionary)

var channel_name: String

var _client: OddSocketsClient
var _is_subscribed: bool = false
var _last_options: Dictionary = {}
var _roster: Dictionary = {}


func _init(client: OddSocketsClient, p_channel_name: String) -> void:
	_client = client
	channel_name = p_channel_name


## Subscribe. [param options] supports `enable_presence` (default false),
## `retain_history` (default true) and `max_history` (default 100); snake_case
## or the wire camelCase both work. Returns the confirmation, or
## `{ "error": String }`.
func subscribe_async(options: Dictionary = {}) -> Dictionary:
	var wire_options := {
		"maxHistory": int(options.get("max_history", options.get("maxHistory", 100))),
		"retainHistory": bool(options.get("retain_history", options.get("retainHistory", true))),
		"enablePresence": bool(options.get("enable_presence", options.get("enablePresence", false))),
	}
	_last_options = wire_options
	var result := await _client.request_async("subscribe",
		_client.with_user_id({"channel": channel_name, "options": wire_options}),
		"subscribed", "channel", channel_name)
	if not result.has("error"):
		_is_subscribed = true
	return result


## Leave the channel.
func unsubscribe_async() -> Dictionary:
	var result := await _client.request_async("unsubscribe",
		_client.with_user_id({"channel": channel_name}),
		"unsubscribed", "channel", channel_name)
	_is_subscribed = false
	_roster.clear()
	return result


## Publish [param message] to every subscriber. It goes on the wire as is:
## a Dictionary or Array arrives as an object/array for every SDK, a String as
## a string. Enforces the 32KB platform limit client-side. Returns the
## acknowledgement or `{ "error": String }`.
func publish_async(message: Variant) -> Dictionary:
	var encoded: String = message if typeof(message) == TYPE_STRING else JSON.stringify(message)
	var info := OddSocketsMessageSizeValidator.get_message_size_info(encoded)
	if not info["valid"]:
		return {"error": "message too large (%d bytes > %d limit)" % [info["size_bytes"], info["max_bytes"]]}
	return await _client.request_async("publish",
		_client.with_user_id({"channel": channel_name, "message": message}),
		"published", "channel", channel_name)


## The current roster as an Array of `{ userId, joinedAt, ... }`.
func get_occupants() -> Array:
	return _roster.values()


## Who is here right now. Requires `enable_presence` on the subscription.
func get_presence_async() -> Dictionary:
	return await _client.request_async("get_presence",
		{"channel": channel_name}, "presence", "channel", channel_name)


## Fetch up to [param count] retained messages. Requires `retain_history`.
func get_history_async(count: int = 50) -> Dictionary:
	return await _client.request_async("get_history",
		{"channel": channel_name, "count": count}, "history", "channel", channel_name)


## Publish this client's presence state (e.g. `{ "status": "in-match" }`).
func update_state_async(state: Dictionary) -> void:
	_client.emit_event("update_state", {"channel": channel_name, "state": state})


func _handle_event(event_name: String, data: Dictionary) -> void:
	match event_name:
		"message":
			message_received.emit(data)
		"presence_change":
			_apply_presence_change(data)
		"presence":
			if typeof(data.get("occupants")) == TYPE_ARRAY:
				_roster.clear()
				for occupant in data["occupants"]:
					if typeof(occupant) == TYPE_DICTIONARY and occupant.has("userId"):
						_roster[str(occupant["userId"])] = occupant
			presence_received.emit(data)
		"history":
			history_received.emit(data)
		"published":
			published.emit(data)
		"subscribed":
			subscribed.emit(data)
		"unsubscribed":
			unsubscribed.emit(data)


# Keep the roster current and re-emit it whole, like the JS SDK, so games
# that draw from presence_received see arrivals, departures and host changes.
func _apply_presence_change(data: Dictionary) -> void:
	var user: Variant = data.get("user")
	if typeof(user) == TYPE_DICTIONARY and (user as Dictionary).has("userId"):
		var uid := str(user["userId"])
		match str(data.get("action", "")):
			"join":
				_roster[uid] = user
			"leave":
				_roster.erase(uid)
	presence_changed.emit(data)
	presence_received.emit({
		"channel": channel_name,
		"occupancy": int(data["occupancy"]) if typeof(data.get("occupancy")) in [TYPE_INT, TYPE_FLOAT] else _roster.size(),
		"occupants": _roster.values(),
	})


# Re-subscribe after a reconnect with the options of the last subscribe.
func _resubscribe_async() -> Dictionary:
	if not _is_subscribed:
		return {}
	var result := await _client.request_async("subscribe",
		_client.with_user_id({"channel": channel_name, "options": _last_options}),
		"subscribed", "channel", channel_name)
	if result.has("error"):
		_is_subscribed = false
	return result
