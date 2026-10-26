extends Control
## Two-player OddSockets demo in one window. Each panel is its OWN connection
## to the live platform — everything you see cross a panel boundary travelled
## through OddSockets, never a local shortcut. The header of each panel names
## the worker it landed on; the roster, feed, typing line, invite flow and
## achievement banner are all driven by real frames.
##
## Run: open this scene and press play. Provide an API key via the
## ODDSOCKETS_API_KEY environment variable or the entry field.

const CHANNEL := "godot-demo-arena"

var _suffix: String
var _panels: Array = []


func _ready() -> void:
	_suffix = str(Time.get_ticks_msec() % 100000)
	var key := OS.get_environment("ODDSOCKETS_API_KEY")
	if key.is_empty():
		_show_key_entry()
	else:
		_start(key)


func _show_key_entry() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	add_child(box)
	var label := Label.new()
	label.text = "OddSockets API key:"
	box.add_child(label)
	var entry := LineEdit.new()
	entry.custom_minimum_size = Vector2(420, 0)
	entry.secret = true
	box.add_child(entry)
	var go := Button.new()
	go.text = "Connect both players"
	box.add_child(go)
	go.pressed.connect(func():
		if not entry.text.is_empty():
			box.queue_free()
			_start(entry.text))


func _start(api_key: String) -> void:
	var split := HSplitContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	split.split_offset = int(size.x / 2.0)
	add_child(split)
	var alice := PlayerPanel.new(self, api_key, "demo-%s-alice" % _suffix)
	var bob := PlayerPanel.new(self, api_key, "demo-%s-bob" % _suffix)
	alice.other = bob
	bob.other = alice
	split.add_child(alice)
	split.add_child(bob)
	_panels = [alice, bob]


class PlayerPanel:
	extends PanelContainer

	var other: PlayerPanel
	var client: OddSocketsClient
	var channel: OddSocketsChannel
	var game: OddSocketsEnhancedFeatures
	var user_id: String

	var _header: Label
	var _roster: Label
	var _feed: RichTextLabel
	var _typing: Label
	var _input: LineEdit
	var _invite_box: HBoxContainer
	var _occupants := {}
	var _typing_clear_at := 0.0
	var _last_typing_sent := 0.0
	var _pending_invite: Dictionary = {}

	func _init(host: Control, api_key: String, p_user_id: String) -> void:
		user_id = p_user_id
		_build_ui()
		client = OddSocketsClient.new()
		host.add_child.call_deferred(client)
		var config := OddSocketsConfig.new()
		config.api_key = api_key
		config.user_id = user_id
		client.initialize(config)
		_connect_when_ready.call_deferred()

	func _build_ui() -> void:
		var box := VBoxContainer.new()
		add_child(box)
		_header = Label.new()
		_header.text = "%s — connecting…" % user_id
		box.add_child(_header)
		_roster = Label.new()
		_roster.text = "0 PLAYING NOW"
		box.add_child(_roster)
		_feed = RichTextLabel.new()
		_feed.scroll_following = true
		_feed.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_feed.custom_minimum_size = Vector2(0, 240)
		box.add_child(_feed)
		_typing = Label.new()
		_typing.text = " "
		box.add_child(_typing)
		var row := HBoxContainer.new()
		box.add_child(row)
		_input = LineEdit.new()
		_input.placeholder_text = "say something…"
		_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_input.text_submitted.connect(_on_send)
		_input.text_changed.connect(_on_typing)
		row.add_child(_input)
		var actions := HBoxContainer.new()
		box.add_child(actions)
		var invite_btn := Button.new()
		invite_btn.text = "Invite other player"
		invite_btn.pressed.connect(_on_invite_pressed)
		actions.add_child(invite_btn)
		var ach_btn := Button.new()
		ach_btn.text = "Unlock achievement"
		ach_btn.pressed.connect(_on_achievement_pressed)
		actions.add_child(ach_btn)
		_invite_box = HBoxContainer.new()
		_invite_box.visible = false
		box.add_child(_invite_box)

	func _connect_when_ready() -> void:
		var result: Dictionary = await client.connect_async()
		if result.has("error"):
			_header.text = "%s — FAILED: %s" % [user_id, result["error"]]
			return
		_header.text = "%s — LIVE on %s" % [user_id, client.worker_info.get("workerId", "?")]

		channel = client.get_channel(CHANNEL)
		channel.message_received.connect(_on_message)
		channel.presence_changed.connect(_on_presence_change)
		await channel.subscribe_async({"enable_presence": true, "retain_history": true})
		var presence: Dictionary = await channel.get_presence_async()
		for occupant in presence.get("occupants", []):
			var uid := str(occupant.get("userId", occupant)) if typeof(occupant) == TYPE_DICTIONARY else str(occupant)
			_occupants[uid] = true
		_redraw_roster(int(presence.get("occupancy", _occupants.size())))
		_log("[color=gray]joined %s via %s[/color]" % [CHANNEL, client.worker_info.get("workerId", "?")])

		game = OddSocketsEnhancedFeatures.new()
		game.initialize(client)
		game.challenge_invited.connect(_on_invited)
		game.challenge_reply_received.connect(_on_reply_received)
		game.achievement_state.connect(_on_achievement)
		game.user_typing.connect(_on_user_typing)

	func _process(_delta: float) -> void:
		if _typing_clear_at > 0.0 and Time.get_unix_time_from_system() > _typing_clear_at:
			_typing.text = " "
			_typing_clear_at = 0.0

	# ── outbound ──
	func _on_send(text: String) -> void:
		if text.is_empty():
			return
		_input.clear()
		var result: Dictionary = await channel.publish_async({"type": "chat", "text": text})
		if result.has("error"):
			_log("[color=red]send failed: %s[/color]" % result["error"])

	func _on_typing(text: String) -> void:
		var now := Time.get_unix_time_from_system()
		if not text.is_empty() and game != null and now - _last_typing_sent > 1.5:
			_last_typing_sent = now
			game.start_typing(user_id, CHANNEL)

	func _on_invite_pressed() -> void:
		var seed_value := randi() % 1000
		var result: Dictionary = await game.send_challenge_invite_async(
			other.user_id, "match", {"arena": "demo-ruins", "seed": seed_value}, 120)
		if result.has("error"):
			_log("[color=red]invite failed: %s[/color]" % result["error"])
		else:
			_log("[color=orange]→ invited %s (arena demo-ruins, seed %d)[/color]" % [other.user_id, seed_value])

	func _on_achievement_pressed() -> void:
		game.unlock_achievement_async("demo-first-win", "First Win!")

	# ── inbound (all of this arrived over the wire) ──
	func _on_message(envelope: Dictionary) -> void:
		var body: Variant = JSON.parse_string(str(envelope.get("message", "")))
		var text := str(body.get("text", envelope.get("message"))) if typeof(body) == TYPE_DICTIONARY else str(envelope.get("message"))
		var who := str(envelope.get("publisher", "?"))
		_log("[b]%s[/b]: %s" % [who, text])

	func _on_presence_change(data: Dictionary) -> void:
		var uid := str(data.get("user", {}).get("userId", "?"))
		if str(data.get("action")) == "join":
			_occupants[uid] = true
			_log("[color=green]%s joined[/color]" % uid)
		else:
			_occupants.erase(uid)
			_log("[color=gray]%s left[/color]" % uid)
		_redraw_roster(int(data.get("occupancy", _occupants.size())))

	func _on_invited(data: Dictionary) -> void:
		_pending_invite = data
		_log("[color=orange]← %s invites you: %s[/color]" % [
			str(data.get("from", {}).get("userId", "?")), JSON.stringify(data.get("payload", {}))])
		for child in _invite_box.get_children():
			child.queue_free()
		var accept := Button.new()
		accept.text = "Accept (sends loadout)"
		accept.pressed.connect(func(): _answer_invite(true))
		_invite_box.add_child(accept)
		var decline := Button.new()
		decline.text = "Decline"
		decline.pressed.connect(func(): _answer_invite(false))
		_invite_box.add_child(decline)
		_invite_box.visible = true

	func _answer_invite(accepted: bool) -> void:
		_invite_box.visible = false
		var reply: Dictionary = await game.reply_challenge_invite_async(
			str(_pending_invite.get("inviteId")), accepted,
			{"loadout": "bow"}, "gl hf" if accepted else "busy")
		if reply.has("error"):
			_log("[color=red]reply failed: %s[/color]" % reply["error"])

	func _on_reply_received(data: Dictionary) -> void:
		_log("[color=orange]← %s %s — their loadout: %s, note: \"%s\" (your invite echoed: %s)[/color]" % [
			str(data.get("from", {}).get("userId", "?")),
			"ACCEPTED" if data.get("accept") else "declined",
			JSON.stringify(data.get("replyPayload", {})),
			str(data.get("reason", "")),
			JSON.stringify(data.get("payload", {}))])

	func _on_achievement(data: Dictionary) -> void:
		_log("[bgcolor=yellow][color=black] 🏆 %s %s [/color][/bgcolor]" % [
			str(data.get("identity", data.get("userId", ""))), str(data.get("achievementId", ""))])

	func _on_user_typing(data: Dictionary) -> void:
		var uid := str(data.get("userId", "?"))
		if uid == user_id:
			return
		_typing.text = "%s is typing…" % uid
		_typing_clear_at = Time.get_unix_time_from_system() + 2.0

	func _redraw_roster(occupancy: int) -> void:
		var names := ", ".join(_occupants.keys())
		_roster.text = "%d PLAYING NOW — %s" % [occupancy, names]

	func _log(bbcode: String) -> void:
		_feed.append_text(bbcode + "\n")
