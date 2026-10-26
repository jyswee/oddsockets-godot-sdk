extends SceneTree
## Lifecycle stress: churn, unclean drop, auto-reconnect and recovery. A clean
## round-trip is blind to slot leaks and reconnect bugs — this is not clean.
## Run against QA:
##   PROBE_KEY=<key> ODDSOCKETS_WORKER_URL=https://<qa worker> \
##     godot --headless --path . --script res://tests/lifecycle_stress.gd

const CHURN_CYCLES := 15
const CONNECT_CYCLES := 5

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
	var channel_name := "godot-stress-%s" % suffix

	# ── 1. connect/disconnect cycles: teardown must be clean every time ──
	var cycler := _make_client(api_key, "stress-%s-cycler" % suffix)
	for i in CONNECT_CYCLES:
		var r: Dictionary = await cycler.connect_async()
		_check(not r.has("error"), "connect cycle %d" % i, str(r))
		cycler.disconnect_client()
		await process_frame
	cycler.queue_free()

	# ── 2. subscribe/unsubscribe churn on one connection ──
	var churner := _make_client(api_key, "stress-%s-churner" % suffix)
	await churner.connect_async()
	var ch: OddSocketsChannel = churner.get_channel(channel_name)
	var churn_ok := true
	for i in CHURN_CYCLES:
		var s: Dictionary = await ch.subscribe_async({"enable_presence": true, "retain_history": true})
		var p: Dictionary = await ch.publish_async({"cycle": i})
		var u: Dictionary = await ch.unsubscribe_async()
		if s.has("error") or p.has("error") or u.has("error"):
			churn_ok = false
			print("  churn cycle %d: sub=%s pub=%s unsub=%s" % [i, s, p, u])
	_check(churn_ok, "%d subscribe/publish/unsubscribe churn cycles" % CHURN_CYCLES)

	# After churn, a fresh subscribe shows exactly ONE occupant (no leaked slots).
	await ch.subscribe_async({"enable_presence": true, "retain_history": true})
	var pres: Dictionary = await ch.get_presence_async()
	_check(int(pres.get("occupancy", -1)) == 1,
		"occupancy is exactly 1 after churn (no leaked presence slots)", str(pres))

	# History survived the churn: all CHURN_CYCLES publishes retained (cap allowing).
	var hist: Dictionary = await ch.get_history_async(50)
	var msg_count := (hist.get("messages", []) as Array).size()
	_check(msg_count >= CHURN_CYCLES, "history retained across churn (%d msgs)" % msg_count, str(msg_count))

	# ── 3. unclean drop mid-session → auto-reconnect → auto-resubscribe ──
	var speaker := _make_client(api_key, "stress-%s-speaker" % suffix)
	await speaker.connect_async()
	var speaker_ch: OddSocketsChannel = speaker.get_channel(channel_name)
	await speaker_ch.subscribe_async({})

	var events: Array = []
	churner.get_channel(channel_name).message_received.connect(
		func(d): events.append(d))
	var reconnected := []
	churner.connected.connect(func(): reconnected.append(true))

	# Kill the socket underneath the client — NOT disconnect_client(), so the
	# client sees an unexpected drop exactly like a network failure.
	churner._ws.close()
	var deadline := Time.get_ticks_msec() + 20000
	while reconnected.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not reconnected.is_empty(), "auto-reconnect after unclean drop")

	# Resubscription is automatic; give it a beat, then prove delivery resumed.
	await create_timer(1.5).timeout
	var post_nonce := "post-drop-%s" % suffix
	await speaker_ch.publish_async({"text": post_nonce})
	deadline = Time.get_ticks_msec() + 10000
	var got := false
	while not got and Time.get_ticks_msec() < deadline:
		for e in events:
			if str(e.get("message", "")).contains(post_nonce):
				got = true
		await process_frame
	_check(got, "message delivery resumes on the resubscribed channel after reconnect")

	# Missed-message recovery: history readback still serves the full stream.
	var hist2: Dictionary = await churner.get_channel(channel_name).get_history_async(50)
	var found_post := false
	for m in hist2.get("messages", []):
		if str(m.get("message", "")).contains(post_nonce):
			found_post = true
	_check(found_post, "history readback includes post-drop message")

	# ── 4. update_state: emits cleanly, no error frame within the window ──
	var errors: Array = []
	churner.request_error.connect(func(ev, msg): errors.append({"ev": ev, "msg": msg}))
	churner.get_channel(channel_name).update_state_async({"status": "stress-testing"})
	await create_timer(2.0).timeout
	var state_err := false
	for e in errors:
		if str(e["ev"]) == "update_state":
			state_err = true
			print("  update_state error: ", e)
	_check(not state_err, "update_state accepted (no error frame)")

	churner.disconnect_client()
	speaker.disconnect_client()
	_finish()


func _make_client(api_key: String, user_id: String) -> OddSocketsClient:
	var config := OddSocketsConfig.new()
	config.api_key = api_key
	config.user_id = user_id
	config.reconnect_delay_seconds = 0.5
	var worker_override := OS.get_environment("ODDSOCKETS_WORKER_URL")
	if not worker_override.is_empty():
		config.worker_url = worker_override
	var client := OddSocketsClient.new()
	client.initialize(config)
	root.add_child(client)
	return client


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
