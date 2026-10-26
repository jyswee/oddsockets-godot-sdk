class_name OddSocketsChannel
extends RefCounted
## A named pub/sub channel. Obtain via [method OddSocketsClient.get_channel].
##
## Note on history: subscribing with `retain_history` stores messages
## server-side but does NOT replay them into [signal message_received] —
## late joiners subscribe first, then call [method get_history_async].

## A message published by any subscriber (including this client) arrived.
## [param message] is the full envelope: id, channel, message, publisher,
## timestamp. `message` is the published string (JSON-decode it yourself when
## you published JSON).
signal message_received(message: Dictionary)
## Someone joined or left: `{ channel, action: "join"|"leave",
## user: { userId, joinedAt }, occupancy }`.
signal presence_changed(data: Dictionary)
## Response to [method get_presence_async]: `{ channel, occupancy, occupants }`.
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


func _init(client: OddSocketsClient, p_channel_name: String) -> void:
	_client = client
	channel_name = p_channel_name


## Subscribe. [param options] supports `enable_presence` and `retain_history`
## (snake_case or the wire camelCase both work). Returns the confirmation, or
## `{ "error": String }`.
func subscribe_async(options: Dictionary = {}) -> Dictionary:
	var wire_options := {}
	if options.get("enable_presence", options.get("enablePresence", false)):
		wire_options["enablePresence"] = true
	if options.get("retain_history", options.get("retainHistory", false)):
		wire_options["retainHistory"] = true
	_last_options = wire_options
	var result := await _client.request_async("subscribe",
		{"channel": channel_name, "userId": _client._config.user_id, "options": wire_options},
		"subscribed", "channel", channel_name)
	if not result.has("error"):
		_is_subscribed = true
	return result


## Leave the channel.
func unsubscribe_async() -> Dictionary:
	var result := await _client.request_async("unsubscribe",
		{"channel": channel_name, "userId": _client._config.user_id},
		"unsubscribed", "channel", channel_name)
	_is_subscribed = false
	return result


## Publish [param message] to every subscriber. Dictionaries and arrays are
## JSON-encoded; strings go as-is. Enforces the 32KB platform limit
## client-side. Returns the acknowledgement or `{ "error": String }`.
func publish_async(message: Variant) -> Dictionary:
	var wire_message: String
	if typeof(message) == TYPE_STRING:
		wire_message = message
	else:
		wire_message = JSON.stringify(message)
	var info := OddSocketsMessageSizeValidator.get_message_size_info(wire_message)
	if not info["valid"]:
		return {"error": "message too large (%d bytes > %d limit)" % [info["size_bytes"], info["max_bytes"]]}
	return await _client.request_async("publish",
		{"channel": channel_name, "message": wire_message, "userId": _client._config.user_id},
		"published", "channel", channel_name)


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
			presence_changed.emit(data)
		"presence":
			presence_received.emit(data)
		"history":
			history_received.emit(data)
		"published":
			published.emit(data)
		"subscribed":
			subscribed.emit(data)
		"unsubscribed":
			unsubscribed.emit(data)


func _resubscribe_if_needed() -> void:
	if _is_subscribed:
		_client.request_async("subscribe",
			{"channel": channel_name, "userId": _client._config.user_id, "options": _last_options},
			"subscribed", "channel", channel_name)
