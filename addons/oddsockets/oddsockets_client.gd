class_name OddSocketsClient
extends Node
## OddSockets real-time client for Godot 4.
##
## Add the node to the scene tree (it polls the connection every frame), call
## [method initialize] with an [OddSocketsConfig], then [method connect_async].
## Channels come from [method get_channel]; game features (challenges,
## achievements, leaderboards) from [OddSocketsEnhancedFeatures].

## Authenticated and ready — channels can subscribe, messages flow.
signal connected
## Connection closed. [param code] / [param reason] come from the close frame.
signal disconnected(code: int, reason: String)
## The connection attempt was refused (bad credentials, unreachable endpoint).
signal connection_error(message: String)
## The platform rejected a request: [param event] names the request that
## failed, [param message] says why.
signal request_error(event: String, message: String)
## Every event that is not routed to a channel, in arrival order. Game
## features listen here; games can too for anything not surfaced as a signal.
signal enhanced_event(event_name: String, data: Dictionary)
## Fired when a fresh auth token is needed and no token_provider is set.
## Answer every firing with [method provide_token].
signal token_requested

const DEFAULT_MANAGER_URL := "https://connect.oddsockets.tyga.network"

## Optional token source: a Callable returning
## `{ "token": String, "expires_at": String }` (it may await internally).
## Checked before [signal token_requested].
var token_provider: Callable = Callable()

## Populated after discovery: `{ "workerId": String, "url": String }`. Useful
## for on-screen connection indicators and support reports.
var worker_info: Dictionary = {}

var _config: OddSocketsConfig
var _ws: WebSocketPeer
var _channels: Dictionary = {}
var _pending: Array = []
var _state: int = STATE_IDLE
var _intentional_close: bool = false
var _reconnect_attempts: int = 0
var _awaiting_token: bool = false
var _token_refresh_at_msec: int = -1

enum { STATE_IDLE, STATE_CONNECTING, STATE_CONNECTED }


## True once the authenticated handshake has completed.
func is_client_connected() -> bool:
	return _state == STATE_CONNECTED


func initialize(config: OddSocketsConfig) -> void:
	_config = config


## Connect: resolve credentials (requesting a token when configured for token
## auth), discover a worker, open the socket and authenticate. Returns `{}` on
## success or `{ "error": String }` — the same outcome also arrives on the
## [signal connected] / [signal connection_error] signals.
func connect_async() -> Dictionary:
	if _config == null or _config.user_id.is_empty():
		var msg := "initialize() with a user_id before connect_async()"
		connection_error.emit(msg)
		return {"error": msg}
	if _state != STATE_IDLE:
		return {"error": "already connecting or connected"}
	_intentional_close = false
	_state = STATE_CONNECTING

	# Token-auth clients fetch a fresh token before every (re)connect so a
	# reconnect after expiry never presents a dead token.
	if _config.api_key.is_empty():
		if not _has_token_source() and _config.token.is_empty():
			return _fail_connect("no api_key, no token and no token provider configured")
		if _has_token_source():
			var tok := await _request_fresh_token()
			if tok.has("error"):
				return _fail_connect(str(tok["error"]))

	var worker_url := _config.worker_url
	if worker_url.is_empty():
		var selected := await _select_worker()
		if selected.has("error"):
			return _fail_connect(str(selected["error"]))
		worker_url = str(selected.get("url", ""))
		if worker_url.is_empty():
			return _fail_connect("worker discovery returned no url")
		worker_info = {"workerId": str(selected.get("workerId", "")), "url": worker_url}
	else:
		worker_info = {"workerId": "(pinned)", "url": worker_url}

	var ws_url := worker_url.replace("https://", "wss://").replace("http://", "ws://") \
		+ "/socket.io/?EIO=4&transport=websocket"
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(ws_url)
	if err != OK:
		return _fail_connect("websocket connect failed: %s" % error_string(err))

	# The handshake continues frame-by-frame in _process(); block here until it
	# resolves either way so callers can simply `await client.connect_async()`.
	var deadline := Time.get_ticks_msec() + int(_config.request_timeout_seconds * 1000.0)
	while _state == STATE_CONNECTING:
		if Time.get_ticks_msec() > deadline:
			_teardown_socket()
			return _fail_connect("timeout during connection handshake")
		await get_tree().process_frame
	if _state == STATE_CONNECTED:
		return {}
	return {"error": "connection refused"}


## Close the connection. No automatic reconnect follows an intentional close.
func disconnect_client() -> void:
	_intentional_close = true
	_token_refresh_at_msec = -1
	if _ws != null and _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_ws.close()
	_state = STATE_IDLE


## Channel accessor; creates the channel wrapper on first use.
func get_channel(channel_name: String) -> OddSocketsChannel:
	if not _channels.has(channel_name):
		_channels[channel_name] = OddSocketsChannel.new(self, channel_name)
	return _channels[channel_name]


## Send a raw event. Payload must be a Dictionary.
func emit_event(event_name: String, payload: Dictionary) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		request_error.emit(event_name, "not connected")
		return
	_ws.send_text("42" + JSON.stringify([event_name, payload]))


## Unity-parity alias for [method emit_event].
func emit_async(event_name: String, payload: Dictionary) -> void:
	emit_event(event_name, payload)


## Answer a [signal token_requested] firing (or refresh proactively).
## [param fresh_token] is `{ "token": String, "expires_at": String }`.
func provide_token(fresh_token: Dictionary) -> void:
	_config.token = fresh_token
	_schedule_token_refresh()
	_awaiting_token = false


## Send an event and await its response event (or a platform error for the
## request). [param match_key]/[param match_value] narrow which response
## belongs to this call (e.g. channel name). Returns the response Dictionary,
## or `{ "error": String }` on error/timeout.
func request_async(send_event: String, payload: Dictionary, success_event: String,
		match_key: String = "", match_value: Variant = null,
		timeout_seconds: float = -1.0) -> Dictionary:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return {"error": "not connected"}
	if timeout_seconds <= 0.0:
		timeout_seconds = _config.request_timeout_seconds
	var slot := {"done": false, "result": {}}
	_pending.append({
		"slot": slot,
		"success": success_event,
		"request": send_event,
		"key": match_key,
		"value": match_value,
	})
	emit_event(send_event, payload)
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while not slot["done"]:
		if Time.get_ticks_msec() > deadline:
			_remove_pending(slot)
			return {"error": "timeout waiting %s" % success_event}
		await get_tree().process_frame
	return slot["result"]


func _process(_delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			while _ws.get_available_packet_count() > 0:
				var packet := _ws.get_packet()
				if _ws.was_string_packet():
					_handle_frame(packet.get_string_from_utf8())
		WebSocketPeer.STATE_CLOSED:
			var code := _ws.get_close_code()
			var reason := _ws.get_close_reason()
			_ws = null
			var was_connected := _state == STATE_CONNECTED
			_state = STATE_IDLE
			if was_connected:
				disconnected.emit(code, reason)
			if not _intentional_close and _config != null and _config.auto_reconnect and was_connected:
				_attempt_reconnect()
	_maybe_refresh_token()


# ── Engine.IO / Socket.IO framing ──
# Text frames: "0{open}" → reply "40{auth}"; "2" ping → "3" pong;
# "40..." connect ack; "44{...}" connect error; "42[event, data]" events.
func _handle_frame(frame: String) -> void:
	if frame == "2":
		_ws.send_text("3")
		return
	if frame.begins_with("0"):
		var auth := {"userId": _config.user_id}
		if not _config.api_key.is_empty():
			auth["apiKey"] = _config.api_key
		else:
			auth["token"] = str(_config.token.get("token", ""))
		_ws.send_text("40" + JSON.stringify(auth))
		return
	if frame.begins_with("44"):
		var detail := frame.substr(2)
		_teardown_socket()
		_state = STATE_IDLE
		connection_error.emit("authentication refused: %s" % detail)
		return
	if frame.begins_with("40"):
		_state = STATE_CONNECTED
		_reconnect_attempts = 0
		_schedule_token_refresh()
		connected.emit()
		return
	if not frame.begins_with("42"):
		return
	var parsed: Variant = JSON.parse_string(frame.substr(frame.find("[")))
	if typeof(parsed) != TYPE_ARRAY or (parsed as Array).is_empty():
		return
	var arr := parsed as Array
	var event_name := str(arr[0])
	var data: Dictionary = arr[1] if arr.size() > 1 and typeof(arr[1]) == TYPE_DICTIONARY else {}
	_dispatch(event_name, data)


func _dispatch(event_name: String, data: Dictionary) -> void:
	# Resolve any request/response awaiter first (error frames carry the
	# originating request name in data.event).
	for p in _pending.duplicate():
		if event_name == p["success"] \
				and (p["key"].is_empty() or data.get(p["key"]) == p["value"]):
			p["slot"]["result"] = data
			p["slot"]["done"] = true
			_pending.erase(p)
			break
		if event_name == "error" and str(data.get("event", "")) == p["request"]:
			p["slot"]["result"] = {"error": str(data.get("message", "request failed"))}
			p["slot"]["done"] = true
			_pending.erase(p)
			break

	if event_name == "error":
		request_error.emit(str(data.get("event", "")), str(data.get("message", "")))
		return

	# Channel-scoped events route to the channel wrapper.
	if event_name in ["message", "presence_change", "presence", "history",
			"published", "subscribed", "unsubscribed"]:
		var ch := str(data.get("channel", ""))
		if _channels.has(ch):
			(_channels[ch] as OddSocketsChannel)._handle_event(event_name, data)
			return

	enhanced_event.emit(event_name, data)


# ── Worker discovery ──
func _select_worker() -> Dictionary:
	var manager := _config.manager_url if not _config.manager_url.is_empty() else DEFAULT_MANAGER_URL
	var ident := _config.client_identifier
	if ident.is_empty():
		ident = "godot-%s" % _config.user_id
	var auth_param: String
	if not _config.api_key.is_empty():
		auth_param = "apiKey=%s" % _config.api_key.uri_encode()
	else:
		auth_param = "token=%s" % str(_config.token.get("token", "")).uri_encode()
	var url := "%s/api/cluster/select-worker?%s&userId=%s&clientIdentifier=%s" % [
		manager, auth_param, _config.user_id.uri_encode(), ident.uri_encode()]

	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		return {"error": "worker discovery request failed: %s" % error_string(err)}
	var response: Array = await http.request_completed
	http.queue_free()
	var code := int(response[1])
	var body := (response[3] as PackedByteArray).get_string_from_utf8()
	if code != 200:
		return {"error": "worker discovery HTTP %d: %s" % [code, body.left(200)]}
	var parsed: Variant = JSON.parse_string(body)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"error": "worker discovery returned invalid JSON"}
	return parsed


# ── Token lifecycle ──
func _has_token_source() -> bool:
	return token_provider.is_valid() or token_requested.get_connections().size() > 0


func _request_fresh_token() -> Dictionary:
	if token_provider.is_valid():
		var result: Variant = await token_provider.call()
		if typeof(result) != TYPE_DICTIONARY or not (result as Dictionary).has("token"):
			return {"error": "token_provider must return { token, expires_at }"}
		provide_token(result)
		return {}
	_awaiting_token = true
	token_requested.emit()
	var deadline := Time.get_ticks_msec() + int(_config.request_timeout_seconds * 1000.0)
	while _awaiting_token:
		if Time.get_ticks_msec() > deadline:
			_awaiting_token = false
			return {"error": "timeout waiting for provide_token()"}
		await get_tree().process_frame
	return {}


func _schedule_token_refresh() -> void:
	_token_refresh_at_msec = -1
	if _config == null or not _config.api_key.is_empty() or _config.token.is_empty():
		return
	var expires_at := str(_config.token.get("expires_at", ""))
	if expires_at.is_empty():
		return
	var expiry_unix := Time.get_unix_time_from_datetime_string(expires_at)
	if expiry_unix <= 0:
		return
	var seconds_left := float(expiry_unix) - Time.get_unix_time_from_system()
	var lead := maxf(seconds_left - _config.token_refresh_lead_seconds, 1.0)
	_token_refresh_at_msec = Time.get_ticks_msec() + int(lead * 1000.0)


func _maybe_refresh_token() -> void:
	if _token_refresh_at_msec < 0 or Time.get_ticks_msec() < _token_refresh_at_msec:
		return
	_token_refresh_at_msec = -1
	if _state == STATE_CONNECTED and _has_token_source():
		_request_fresh_token()


# ── Reconnect ──
func _attempt_reconnect() -> void:
	if _config.max_reconnect_attempts > 0 and _reconnect_attempts >= _config.max_reconnect_attempts:
		connection_error.emit("reconnect attempts exhausted")
		return
	_reconnect_attempts += 1
	var delay := minf(
		_config.reconnect_delay_seconds * pow(2.0, float(_reconnect_attempts - 1)), 30.0)
	await get_tree().create_timer(delay).timeout
	if _intentional_close or _state != STATE_IDLE:
		return
	var result := await connect_async()
	if not result.has("error"):
		# Restore the channels the game had subscribed before the drop.
		for ch in _channels.values():
			(ch as OddSocketsChannel)._resubscribe_if_needed()


func _fail_connect(message: String) -> Dictionary:
	_state = STATE_IDLE
	connection_error.emit(message)
	return {"error": message}


func _teardown_socket() -> void:
	if _ws != null:
		_ws.close()
		_ws = null


func _remove_pending(slot: Dictionary) -> void:
	for p in _pending.duplicate():
		if p["slot"] == slot:
			_pending.erase(p)


func _exit_tree() -> void:
	disconnect_client()
