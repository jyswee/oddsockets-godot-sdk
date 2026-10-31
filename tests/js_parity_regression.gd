extends SceneTree
## JS-parity regression: the Godot SDK behaves like @oddsockets/js 2.0.2 on
## the token lane. Every client is keyless and sets NO user_id — identity comes
## from the token. Covers: connect without user_id, object payloads arriving
## as objects, a roster that follows joins/leaves, reconnect ordering
## (re-subscribed before connected, then reconnected), and the JS subscribe
## defaults (history retained, 100 messages).
##
## Run:
##   godot --headless --path . --script res://tests/js_parity_regression.gd
## Optional: GUEST_JWT_URL (defaults to the cropsicles guest mint).
## Optional: PARITY_CHANNEL=<name> to share the room with a JS 2.0.2 peer
## (tests/js_peer.js); the test then also requires the peer's object message.

const TOKEN_FRONT_DOOR := "https://connect.oddsockets.tyga.network/v1/token"

var failures: Array[String] = []
var _guest_url := ""
var _suffix := ""


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_guest_url = OS.get_environment("GUEST_JWT_URL")
	if _guest_url.is_empty():
		_guest_url = "https://cropsicles.com/api/auth/guest"
	_suffix = str(Time.get_ticks_msec() % 100000)
	var channel_name := OS.get_environment("PARITY_CHANNEL")
	var js_peer := not channel_name.is_empty()
	if not js_peer:
		channel_name = "godot-parity-%s" % _suffix

	# ── 1. token lane, no user_id ──
	var a: OddSocketsClient = await _token_client("a")
	var b: OddSocketsClient = await _token_client("b")
	if a == null or b == null:
		_finish()
		return
	_check(a._config.user_id.is_empty() and b._config.user_id.is_empty(),
		"clients configured with no user_id")

	# ── 5. subscribe defaults match JS ──
	var ch_a: OddSocketsChannel = a.get_channel(channel_name)
	var rosters: Array = []
	ch_a.presence_received.connect(func(d): rosters.append(d))
	var inbox_a: Array = []
	ch_a.message_received.connect(func(d): inbox_a.append(d))
	var sub_a: Dictionary = await ch_a.subscribe_async({"enable_presence": true})
	_check(not sub_a.has("error"), "token client subscribes without user_id", str(sub_a))
	_check(ch_a._last_options.get("retainHistory") == true
		and int(ch_a._last_options.get("maxHistory", 0)) == 100,
		"subscribe defaults retainHistory=true, maxHistory=100", str(ch_a._last_options))

	var ch_b: OddSocketsChannel = b.get_channel(channel_name)
	var inbox_b: Array = []
	ch_b.message_received.connect(func(d): inbox_b.append(d))
	await ch_b.subscribe_async({"enable_presence": true})

	# ── 2. object payloads stay objects ──
	var nonce := "parity-%s" % _suffix
	var pub: Dictionary = await ch_b.publish_async({"text": nonce, "n": 7, "tags": ["x", "y"]})
	_check(not pub.has("error"), "token client publishes without user_id", str(pub))
	var got: Dictionary = await _wait_for(inbox_a, func(e):
		return typeof(e.get("message")) == TYPE_DICTIONARY and str(e["message"].get("text", "")) == nonce)
	_check(not got.is_empty(), "Dictionary publish arrives as a Dictionary", str(inbox_a).left(200))
	if not got.is_empty():
		_check(typeof(got["message"].get("tags")) == TYPE_ARRAY, "nested Array survives", str(got["message"]))
		_check(not str(got.get("publisher", "")).is_empty(),
			"publisher identity comes from the token (%s)" % str(got.get("publisher", "")))
	var s_pub: Dictionary = await ch_b.publish_async("plain-%s" % _suffix)
	var got_s: Dictionary = await _wait_for(inbox_a, func(e):
		return typeof(e.get("message")) == TYPE_STRING and str(e["message"]) == "plain-%s" % _suffix)
	_check(not s_pub.has("error") and not got_s.is_empty(), "String publish arrives as a String")

	# History retained by default.
	await process_frame
	var hist: Dictionary = await ch_a.get_history_async(20)
	_check((hist.get("messages", []) as Array).size() >= 2,
		"history retained with default options (%d msgs)" % (hist.get("messages", []) as Array).size(), str(hist).left(200))

	# ── 3. roster follows joins and leaves ──
	var c: OddSocketsClient = await _token_client("c")
	var c_id := ""
	if c != null:
		var before := rosters.size()
		await c.get_channel(channel_name).subscribe_async({"enable_presence": true})
		var grew: Dictionary = await _wait_for(rosters, func(r): return (r.get("occupants", []) as Array).size() >= 3, before)
		_check(not grew.is_empty(), "roster re-emitted with newcomer (3 occupants)", str(rosters.back() if rosters.size() > 0 else {}).left(200))
		var ids := ch_a.get_occupants().map(func(o): return str(o.get("userId", "")))
		_check(ids.size() >= 3, "get_occupants() reflects the join", str(ids))
		before = rosters.size()
		var count_before := ch_a.get_occupants().size()
		c.disconnect_client()
		var shrank: Dictionary = await _wait_for(rosters, func(r): return (r.get("occupants", []) as Array).size() == count_before - 1, before)
		_check(not shrank.is_empty(), "roster re-emitted without the leaver", str(rosters.back() if rosters.size() > 0 else {}).left(200))

	# ── 4. reconnect: re-subscribed before connected, then reconnected ──
	var order: Array = []
	ch_b.subscribed.connect(func(_d): order.append("subscribed"))
	b.connected.connect(func(): order.append("connected"))
	b.reconnected.connect(func(): order.append("reconnected"))
	b._ws.close()  # unclean drop, not disconnect_client()
	var deadline := Time.get_ticks_msec() + 30000
	while not order.has("reconnected") and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(order == ["subscribed", "connected", "reconnected"],
		"reconnect: re-subscribed, then connected, then reconnected", str(order))
	# Right after reconnected, delivery to the re-subscribed channel works.
	inbox_b.clear()
	var n2 := "after-reconnect-%s" % _suffix
	await ch_a.publish_async({"text": n2})
	var got2: Dictionary = await _wait_for(inbox_b, func(e):
		return typeof(e.get("message")) == TYPE_DICTIONARY and str(e["message"].get("text", "")) == n2)
	_check(not got2.is_empty(), "re-subscribed channel receives immediately after reconnected")

	# ── optional: a JS 2.0.2 peer in the same room ──
	if js_peer:
		await ch_a.publish_async({"from": "godot", "nonce": _suffix})
		var from_js: Dictionary = await _wait_for(inbox_a, func(e):
			return typeof(e.get("message")) == TYPE_DICTIONARY and str(e["message"].get("from", "")) == "js", 0, 30000)
		_check(not from_js.is_empty(), "JS 2.0.2 peer's object arrives as a Dictionary", str(inbox_a).left(300))

	a.disconnect_client()
	b.disconnect_client()
	_finish()


func _token_client(tag: String) -> OddSocketsClient:
	var guest: Dictionary = await _post_json(_guest_url,
		{"deviceId": "godot-parity-%s-%s" % [_suffix, tag]}, [])
	if not _check(guest.has("token"), "guest JWT minted (%s)" % tag, str(guest).left(200)):
		return null
	var jwt := str(guest["token"])
	var client := OddSocketsClient.new()
	client.initialize(OddSocketsConfig.new())  # NO api_key, NO user_id
	root.add_child(client)
	client.token_provider = func() -> Dictionary: return await _exchange(jwt)
	var result: Dictionary = await client.connect_async()
	if not _check(not result.has("error"), "keyless client %s connects with no user_id" % tag, str(result)):
		return null
	return client


func _wait_for(list: Array, pred: Callable, start: int = 0, timeout_ms: int = 10000) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		for i in range(start, list.size()):
			if typeof(list[i]) == TYPE_DICTIONARY and pred.call(list[i]):
				return list[i]
		await process_frame
	return {}


func _exchange(jwt: String) -> Dictionary:
	var minted: Dictionary = await _post_json(TOKEN_FRONT_DOOR, {},
		["Authorization: Bearer %s" % jwt])
	if not minted.has("token"):
		return {"error": "mint failed: %s" % str(minted).left(200)}
	return {
		"token": str(minted["token"]),
		"expires_at": str(minted.get("expiresAt", minted.get("expires_at", ""))),
	}


func _post_json(url: String, body: Dictionary, extra_headers: Array) -> Dictionary:
	var http := HTTPRequest.new()
	root.add_child(http)
	var headers := PackedStringArray(["Content-Type: application/json"])
	for h in extra_headers:
		headers.append(h)
	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		return {"error": "request failed: %s" % error_string(err)}
	var response: Array = await http.request_completed
	http.queue_free()
	var code := int(response[1])
	var text := (response[3] as PackedByteArray).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"error": "HTTP %d non-JSON: %s" % [code, text.left(160)]}
	if code < 200 or code >= 300:
		return {"error": "HTTP %d: %s" % [code, text.left(160)]}
	return parsed


func _check(cond: bool, name: String, detail: String = "") -> bool:
	if cond:
		print("[PASS] ", name)
	else:
		print("[FAIL] ", name, " — ", detail.left(220))
		failures.append(name)
	return cond


func _finish() -> void:
	if failures.is_empty():
		print("\n=== ALL PASS ===")
	else:
		print("\n=== %d FAILURES: %s ===" % [failures.size(), ", ".join(failures)])
	quit(0 if failures.is_empty() else 1)
