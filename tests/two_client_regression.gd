extends SceneTree
## Two-client honest regression against the live platform. Run headless:
##   PROBE_KEY=<api key> godot --headless --path . --script res://tests/two_client_regression.gd
##
## Two separate connections (alice subscribes/receives, bob publishes/invites)
## prove cross-connection delivery — nothing is locally echoed or simulated.

var failures: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var api_key := OS.get_environment("PROBE_KEY")
	if api_key.is_empty():
		push_error("PROBE_KEY env required")
		quit(2)
		return

	var suffix := str(Time.get_ticks_msec() % 100000)
	var channel_name := "godot-regress-%s" % suffix
	var alice := _make_client(api_key, "godot-%s-alice" % suffix)
	var bob := _make_client(api_key, "godot-%s-bob" % suffix)

	# ── connect ──
	var r1: Dictionary = await alice.client.connect_async()
	var r2: Dictionary = await bob.client.connect_async()
	_check(not r1.has("error") and not r2.has("error"), "both clients connect",
		str(r1) + " / " + str(r2))
	if not failures.is_empty():
		_finish()
		return

	# ── subscribe + presence_change join ──
	var ch_a: OddSocketsChannel = alice.client.get_channel(channel_name)
	var ch_b: OddSocketsChannel = bob.client.get_channel(channel_name)
	_tap(ch_a.message_received, alice, "message")
	_tap(ch_a.presence_changed, alice, "presence_change")
	var sub_a: Dictionary = await ch_a.subscribe_async({"enable_presence": true, "retain_history": true})
	_check(not sub_a.has("error"), "alice subscribes", str(sub_a))
	var sub_b: Dictionary = await ch_b.subscribe_async({"enable_presence": true, "retain_history": true})
	_check(not sub_b.has("error"), "bob subscribes", str(sub_b))
	var join: Variant = await _wait(alice, "presence_change",
		func(d): return d.get("action") == "join")
	_check(join != null and join["data"].get("user", {}).get("userId", "").contains("bob"),
		"alice sees bob join (presence_change)", str(join))

	# ── cross-connection publish ──
	var nonce := "nonce-%s" % suffix
	var pub: Dictionary = await ch_b.publish_async({"hello": "godot", "nonce": nonce})
	_check(not pub.has("error") and pub.has("messageId"), "bob publish acknowledged", str(pub))
	var msg: Variant = await _wait(alice, "message",
		func(d): return str(d.get("message", "")).contains(nonce))
	_check(msg != null, "alice receives bob's message cross-connection", str(msg))

	# ── presence + history queries ──
	var pres: Dictionary = await ch_a.get_presence_async()
	_check(int(pres.get("occupancy", 0)) >= 2 and (pres.get("occupants", []) as Array).size() >= 2,
		"presence shows both occupants", str(pres))
	var hist: Dictionary = await ch_a.get_history_async(10)
	_check((hist.get("messages", []) as Array).size() >= 1, "history returns the publish", str(hist))

	# ── oversize publish rejected client-side ──
	var big: Dictionary = await ch_b.publish_async("z".repeat(33000))
	_check(big.has("error") and str(big["error"]).contains("too large"),
		"33KB publish rejected client-side", str(big))

	# ── game surface: invite with object payload ──
	var game_a := OddSocketsEnhancedFeatures.new()
	game_a.initialize(alice.client)
	var game_b := OddSocketsEnhancedFeatures.new()
	game_b.initialize(bob.client)
	_tap(game_b.challenge_invited, bob, "challenge_invited")
	_tap(game_a.challenge_reply_received, alice, "challenge_reply_received")
	_tap(game_a.user_typing, alice, "user_typing")

	var inv: Dictionary = await game_a.send_challenge_invite_async(
		bob.client._config.user_id, "match", {"arena": "godot-probe", "seed": 9}, 120)
	_check(not inv.has("error") and inv.has("inviteId"), "invite acknowledged", str(inv))
	var invited: Variant = await _wait(bob, "challenge_invited",
		func(d): return d.get("inviteId") == inv.get("inviteId"))
	_check(invited != null and invited["data"].get("payload", {}).get("arena") == "godot-probe",
		"invite payload arrives as object", str(invited))

	# ── reply: replyPayload + invite echo + reason ──
	var reply: Dictionary = await game_b.reply_challenge_invite_async(
		str(inv["inviteId"]), true, {"loadout": "bow"}, "gl hf")
	_check(not reply.has("error") and reply.get("replyPayload", {}).get("loadout") == "bow",
		"reply_success echoes replyPayload", str(reply))
	var recv: Variant = await _wait(alice, "challenge_reply_received",
		func(d): return d.get("inviteId") == inv.get("inviteId"))
	_check(recv != null and recv["data"].get("replyPayload", {}).get("loadout") == "bow",
		"inviter receives replyPayload", str(recv))
	_check(recv != null and recv["data"].get("payload", {}).get("arena") == "godot-probe",
		"invite payload echo intact on reply", str(recv))
	_check(recv != null and str(recv["data"].get("reason", "")) == "gl hf",
		"reason intact on reply", str(recv))

	# ── oversize reply payload rejected by the platform ──
	var inv2: Dictionary = await game_a.send_challenge_invite_async(
		bob.client._config.user_id, "match", {"x": 1}, 120)
	var big_reply: Dictionary = await game_b.reply_challenge_invite_async(
		str(inv2["inviteId"]), false, {"blob": "z".repeat(9000)})
	_check(big_reply.has("error") and str(big_reply["error"]).contains("too large"),
		"9KB reply payload rejected by platform", str(big_reply))

	# ── typing indicator cross-connection ──
	game_b.start_typing(bob.client._config.user_id, channel_name)
	var typing: Variant = await _wait(alice, "user_typing", func(_d): return true)
	_check(typing != null, "typing indicator arrives cross-connection", str(typing))

	alice.client.disconnect_client()
	bob.client.disconnect_client()
	_finish()


func _make_client(api_key: String, user_id: String) -> Dictionary:
	var config := OddSocketsConfig.new()
	config.api_key = api_key
	config.user_id = user_id
	var manager_override := OS.get_environment("ODDSOCKETS_MANAGER_URL")
	if not manager_override.is_empty():
		config.manager_url = manager_override
	var worker_override := OS.get_environment("ODDSOCKETS_WORKER_URL")
	if not worker_override.is_empty():
		config.worker_url = worker_override
	var client := OddSocketsClient.new()
	client.initialize(config)
	root.add_child(client)
	return {"client": client, "events": []}


func _tap(sig: Signal, holder: Dictionary, label: String) -> void:
	sig.connect(func(data: Dictionary): holder["events"].append({"ev": label, "data": data}))


func _wait(holder: Dictionary, label: String, pred: Callable, timeout := 10.0) -> Variant:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		for e in holder["events"]:
			if e["ev"] == label and pred.call(e["data"]):
				return e
		await process_frame
	return null


func _check(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		print("[PASS] ", name)
	else:
		print("[FAIL] ", name, " — ", detail.left(220))
		failures.append(name)


func _finish() -> void:
	if failures.is_empty():
		print("\n=== ALL PASS ===")
	else:
		print("\n=== %d FAILURES: %s ===" % [failures.size(), ", ".join(failures)])
	quit(0 if failures.is_empty() else 1)
