extends SceneTree
## Keyless token-path regression: no API key anywhere. Two players each
## exchange their own game JWT at the platform token front door via the SDK's
## token_provider and connect on minted tokens; cross-connection delivery is
## proven between them. (Minted tokens are scoped to the issuing game, so the
## witness must live in the same scope — an api-key client from another tenant
## is correctly isolated and would see nothing.) Also proves the pre-expiry
## refresh timer fires by shrinking the refresh lead to just under the token
## lifetime.
##
## Run:
##   GUEST_JWT_URL=<game guest endpoint> \
##     godot --headless --path . --script res://tests/token_auth_regression.gd
## GUEST_JWT_URL defaults to the cropsicles guest mint.

const TOKEN_FRONT_DOOR := "https://connect.oddsockets.tyga.network/v1/token"

var failures: Array[String] = []
var _mint_count := 0
var _witness_mints := 0
var _guest_jwt := ""
var _witness_jwt := ""


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var guest_url := OS.get_environment("GUEST_JWT_URL")
	if guest_url.is_empty():
		guest_url = "https://cropsicles.com/api/auth/guest"

	var suffix := str(Time.get_ticks_msec() % 100000)
	var channel_name := "godot-token-%s" % suffix

	# ── player JWTs from the game backend (one per client) ──
	var guest: Dictionary = await _post_json(guest_url, {"deviceId": "godot-sdk-dogfood-%s" % suffix}, [])
	if not _check(guest.has("token"), "guest JWT minted", str(guest).left(200)):
		_finish()
		return
	_guest_jwt = str(guest["token"])
	var guest2: Dictionary = await _post_json(guest_url, {"deviceId": "godot-sdk-witness-%s" % suffix}, [])
	_witness_jwt = str(guest2.get("token", ""))

	# ── keyless client: token_provider does the /v1/token exchange ──
	var config := OddSocketsConfig.new()
	config.user_id = "godot-token-%s-player" % suffix  # NO api_key
	var player := OddSocketsClient.new()
	player.initialize(config)
	root.add_child(player)
	player.token_provider = _mint_realtime_token

	var result: Dictionary = await player.connect_async()
	if not _check(not result.has("error"), "keyless client connects on minted token", str(result)):
		_finish()
		return
	_check(_mint_count == 1, "token_provider called exactly once for connect", str(_mint_count))

	# ── witness: a SECOND keyless client in the same game scope ──
	var witness_config := OddSocketsConfig.new()
	witness_config.user_id = "godot-token-%s-witness" % suffix
	var witness := OddSocketsClient.new()
	witness.initialize(witness_config)
	root.add_child(witness)
	witness.token_provider = _mint_witness_token
	var wr: Dictionary = await witness.connect_async()
	_check(not wr.has("error"), "witness keyless client connects", str(wr))

	var received: Array = []
	var witness_ch: OddSocketsChannel = witness.get_channel(channel_name)
	witness_ch.message_received.connect(func(d): received.append(d))
	await witness_ch.subscribe_async({})

	var player_ch: OddSocketsChannel = player.get_channel(channel_name)
	await player_ch.subscribe_async({})
	var nonce := "token-nonce-%s" % suffix
	var pub: Dictionary = await player_ch.publish_async({"text": nonce})
	_check(not pub.has("error"), "token client publish acknowledged", str(pub))
	var deadline := Time.get_ticks_msec() + 10000
	var got := false
	while not got and Time.get_ticks_msec() < deadline:
		for e in received:
			if str(e.get("message", "")).contains(nonce):
				got = true
		await process_frame
	_check(got, "witness receives token client's publish cross-connection")

	# ── pre-expiry refresh: force the lead to land ~15s from now ──
	var expires_at := str(player._config.token.get("expires_at", player._config.token.get("expiresAt", "")))
	var expiry_unix := Time.get_unix_time_from_datetime_string(expires_at)
	var seconds_left := float(expiry_unix) - Time.get_unix_time_from_system()
	_check(seconds_left > 30.0, "minted token has usable lifetime (%ds left)" % int(seconds_left), expires_at)
	player._config.token_refresh_lead_seconds = seconds_left - 15.0
	player._schedule_token_refresh()
	print("  waiting ~15s for the refresh timer…")
	deadline = Time.get_ticks_msec() + 30000
	while _mint_count < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_mint_count >= 2, "pre-expiry refresh re-invoked the token_provider", str(_mint_count))

	# Connection survived the refresh and still delivers.
	var nonce2 := "post-refresh-%s" % suffix
	await player_ch.publish_async({"text": nonce2})
	deadline = Time.get_ticks_msec() + 10000
	var got2 := false
	while not got2 and Time.get_ticks_msec() < deadline:
		for e in received:
			if str(e.get("message", "")).contains(nonce2):
				got2 = true
		await process_frame
	_check(got2, "delivery intact after token refresh")

	player.disconnect_client()
	witness.disconnect_client()
	_finish()


func _mint_realtime_token() -> Dictionary:
	_mint_count += 1
	return await _exchange(_guest_jwt)


func _mint_witness_token() -> Dictionary:
	_witness_mints += 1
	return await _exchange(_witness_jwt)


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
