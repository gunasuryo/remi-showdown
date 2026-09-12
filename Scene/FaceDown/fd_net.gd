extends RefCounted
class_name FDNet

# Wire format for networked face-down matches.
#
# The design in one line: the SERVER owns the only authoritative FDState, and
# every client is sent a REDACTED copy that physically does not contain the
# opponent's secrets.
#
# WHY NOT LOCKSTEP
# FDRules.resolve() uses no RNG at all, so both peers replaying the same action
# list would stay in sync perfectly, and lockstep would be less code. It is the
# wrong answer here anyway: face-down mode is built entirely on not knowing
# where the enemy cards are, and lockstep requires every peer to hold the full
# state. A modified client could then simply read the opponent's row. Since the
# server has to run the rules to validate moves regardless - and resolve()
# already returns {ok, error}, so validation is free - the authoritative model
# costs little and cannot be cheated by reading memory.
#
# WHAT A CLIENT IS TOLD
#   own cards          everything
#   enemy cards        name and alive - both public, because the roster shows
#                      who is left and every death is announced
#   enemy card detail  hp / shield / rally / tricked, but ONLY while that card
#                      stands in a slot its owner has revealed
#   enemy slots        real id where revealed, FDCard.HIDDEN otherwise
#   revealed / acted   both sides in full; both are things you watched happen
#
# The invariant that matters is asserted in test/test_fd_net.gd: for every
# unrevealed enemy card, its name must not appear anywhere in the encoded
# payload. That test is the security property, not the comments.

const PROTOCOL_VERSION := 1

# ── Actions (client -> server) ────────────────────────────────────────────

static func encode_action(card_id: int, kind: String, target_slot: int) -> Dictionary:
	return {"t": "action", "card_id": card_id, "kind": kind, "target_slot": target_slot}

# A room request carrying the suit this client would like. The server decides:
# whoever asks first gets their choice, and the other is given what is left.
static func encode_room(kind: String, code: String, token: String, prefer: int) -> Dictionary:
	return {"t": kind, "code": code, "token": token, "prefer": prefer}

static func encode_placement(slot_ids: Array) -> Dictionary:
	return {"t": "place", "slots": slot_ids.duplicate()}

# An action off the wire is untrusted input. This only checks it is SHAPED
# correctly; whether it is legal is FDRules.resolve()'s job, and it already
# answers that with {ok, error}.
static func valid_action(msg: Dictionary) -> bool:
	if str(msg.get("t", "")) != "action":
		return false
	if not (msg.get("card_id") is int or msg.get("card_id") is float):
		return false
	if not (msg.get("target_slot") is int or msg.get("target_slot") is float):
		return false
	return str(msg.get("kind", "")) in ["attack", "skill"]

static func valid_placement(msg: Dictionary) -> bool:
	if str(msg.get("t", "")) != "place":
		return false
	var row = msg.get("slots")
	if not (row is Array):
		return false
	for v in row:
		if not (v is int or v is float):
			return false
	return true

static func action_from(msg: Dictionary) -> Dictionary:
	return {
		"card_id": int(msg.get("card_id", FDCard.NONE)),
		"kind": str(msg.get("kind", "attack")),
		"target_slot": int(msg.get("target_slot", -1)),
	}

# ── Events (server -> client) ─────────────────────────────────────────────

# Every event field that carries a card id.
const CARD_ID_KEYS := ["actor", "target", "card", "by"]

# Events are the other half of the wire, and they were being broadcast raw.
# That defeated the whole snapshot redaction: {"t":"rally","target":7} names a
# card, ids map to names through the public roster, and a client that also sees
# a RALLIED mark on lane 3 then knows exactly which card is standing there. It
# would also have made a bluff on a corpse transparent on arrival.
#
# Any id the viewer is not entitled to resolve is replaced by FDCard.HIDDEN.
# The lane and the effect survive - which is what the board needs to draw - and
# the identity does not.
static func redact_events(state: FDState, events: Array, viewer: int) -> Array:
	var out: Array = []
	for ev in events:
		if not (ev is Dictionary):
			continue
		var e: Dictionary = ev.duplicate(true)
		for k in CARD_ID_KEYS:
			if e.has(k):
				e[k] = visible_id(state, int(e[k]), viewer)
		out.append(e)
	return out

# The id as `viewer` may know it, or FDCard.HIDDEN.
static func visible_id(state: FDState, id: int, viewer: int) -> int:
	if id < 0:
		return id
	var c: FDCard = state.card_by_id(id)
	if c == null:
		return FDCard.HIDDEN
	if c.side == viewer:
		return id
	var slot: int = state.slot_of(c)
	if slot != -1 and state.is_revealed(c.side, slot):
		return id
	return FDCard.HIDDEN

# ── Snapshots (server -> client) ──────────────────────────────────────────

# Everything `viewer` is entitled to know, and nothing else.
static func snapshot(state: FDState, viewer: int) -> Dictionary:
	var enemy: int = state.opponent(viewer)

	# Which enemy cards are standing in a slot their owner has revealed. Only
	# these get their volatile numbers sent.
	var exposed := {}
	var enemy_row: Array = state.slots[enemy]
	for slot in range(enemy_row.size()):
		if state.is_revealed(enemy, slot):
			exposed[int(enemy_row[slot])] = true

	var cards: Array = []
	for c in state.cards:
		cards.append(_card_payload(c, c.side == viewer, exposed.has(c.id)))

	return {
		"t": "state",
		"v": PROTOCOL_VERSION,
		"viewer": viewer,
		"round_no": state.round_no,
		"leader": state.leader,
		"side_to_act": state.side_to_act,
		"board_size": state.board_size,
		"phase": state.phase,
		"damage_scale": state.damage_scale,
		"next_id": state._next_id,
		"cards": cards,
		"slots": {
			str(viewer): state.slots[viewer].duplicate(),
			str(enemy): _redact_row(state, enemy),
		},
		# Buffs on the enemy row are public even where the identity is not: the
		# action that applied one happened in the open. Sent per SLOT rather
		# than per card, so "that lane is shielded" says nothing about which
		# card is standing in it - which is what lets a shielded corpse pass
		# for a guarded one.
		"marks": _slot_marks(state, enemy),
		"revealed": {
			str(FDState.BLACK): state.revealed[FDState.BLACK].keys(),
			str(FDState.RED): state.revealed[FDState.RED].keys(),
		},
		"acted": {
			str(FDState.BLACK): state.acted[FDState.BLACK].keys(),
			str(FDState.RED): state.acted[FDState.RED].keys(),
		},
		"placed": {
			str(FDState.BLACK): state.placed[FDState.BLACK],
			str(FDState.RED): state.placed[FDState.RED],
		},
	}

# The enemy row with every unrevealed identity replaced by HIDDEN. The slot
# still reads as occupied, so the board draws a face-down card rather than an
# empty lane - it simply has no id to look up.
static func _redact_row(state: FDState, enemy: int) -> Array:
	var out: Array = []
	for slot in range(state.slots[enemy].size()):
		if state.is_revealed(enemy, slot):
			out.append(int(state.slots[enemy][slot]))
		else:
			out.append(FDCard.HIDDEN)
	return out

static func _slot_marks(state: FDState, enemy: int) -> Array:
	var out: Array = []
	for slot in range(state.slots[enemy].size()):
		var c: FDCard = state.card_at(enemy, slot)
		out.append({} if c == null else c.buff_marks())
	return out

static func _card_payload(c: FDCard, own: bool, exposed: bool) -> Dictionary:
	# Name and alive are public for both sides: the roster shows who is left and
	# FDRules announces every death.
	var d := {
		"id": c.id, "side": c.side, "name": c.card_name, "alive": c.alive,
	}
	if not own and not exposed:
		return d
	d.merge({
		"hp": c.hp, "max_hp": c.max_hp, "atk": c.atk, "skill": c.skill_value,
		"shield": c.shield, "max_shield": c.max_shield, "shield_ace": c.shield_ace,
		"rallied": c.rallied, "rally_king": c.rally_king, "rally_last": c.rally_last,
		"king_plus": c.king_plus,
		"nullified": c.nullified, "joker_link": c.joker_link,
	}, true)
	return d

# Rebuilds a client-side FDState from a snapshot. The result is a real FDState,
# so every query the board already makes keeps working - it just happens to
# have HIDDEN in the enemy row and blanks where the server withheld detail.
static func restore(msg: Dictionary) -> FDState:
	var s := FDState.new()
	s.round_no = int(msg.get("round_no", 1))
	s.leader = int(msg.get("leader", FDState.BLACK))
	s.side_to_act = int(msg.get("side_to_act", FDState.BLACK))
	s.board_size = int(msg.get("board_size", 5))
	s.phase = int(msg.get("phase", FDState.Phase.POSITIONING))
	s.damage_scale = float(msg.get("damage_scale", 1.0))
	s.player_side = int(msg.get("viewer", FDState.BLACK))
	s._next_id = int(msg.get("next_id", 0))

	for raw in msg.get("cards", []):
		s.cards.append(_card_from(raw))

	for side in [FDState.BLACK, FDState.RED]:
		var key := str(side)
		var row: Array = []
		for v in msg.get("slots", {}).get(key, []):
			row.append(int(v))
		s.slots[side] = row
		s.revealed[side] = {}
		for v in msg.get("revealed", {}).get(key, []):
			s.revealed[side][int(v)] = true
		s.acted[side] = {}
		for v in msg.get("acted", {}).get(key, []):
			s.acted[side][int(v)] = true
		s.placed[side] = bool(msg.get("placed", {}).get(key, false))

	var enemy: int = s.opponent(s.player_side)
	var marks: Array = []
	for m in msg.get("marks", []):
		marks.append(m if m is Dictionary else {})
	s.hidden_marks[enemy] = marks
	return s

static func _card_from(raw: Dictionary) -> FDCard:
	var c := FDCard.new()
	c.id = int(raw.get("id", FDCard.NONE))
	c.side = int(raw.get("side", FDState.BLACK))
	c.card_name = str(raw.get("name", ""))
	c.alive = bool(raw.get("alive", true))
	# A withheld card carries its published stat line and nothing situational:
	# what an Ace hits for is in CardStats and was never secret.
	c.max_hp = int(raw.get("max_hp", CardStats.hp_of(c.card_name, CardStats.FACE_DOWN) if CardStats.has_card(c.card_name, CardStats.FACE_DOWN) else 0))
	c.atk = int(raw.get("atk", CardStats.atk_of(c.card_name, CardStats.FACE_DOWN) if CardStats.has_card(c.card_name, CardStats.FACE_DOWN) else 0))
	c.skill_value = int(raw.get("skill", CardStats.skill_of(c.card_name, CardStats.FACE_DOWN) if CardStats.has_card(c.card_name, CardStats.FACE_DOWN) else 0))
	c.hp = int(raw.get("hp", c.max_hp))
	c.max_shield = int(raw.get("max_shield", CardStats.MAX_SHIELD_FACEDOWN))
	c.shield = int(raw.get("shield", 0))
	c.shield_ace = int(raw.get("shield_ace", FDCard.NONE))
	c.rallied = bool(raw.get("rallied", false))
	c.rally_king = int(raw.get("rally_king", FDCard.NONE))
	c.rally_last = bool(raw.get("rally_last", false))
	c.king_plus = bool(raw.get("king_plus", false))
	c.nullified = bool(raw.get("nullified", false))
	c.joker_link = int(raw.get("joker_link", FDCard.NONE))
	return c

# ── Framing ───────────────────────────────────────────────────────────────

static func to_bytes(msg: Dictionary) -> PackedByteArray:
	return JSON.stringify(msg).to_utf8_buffer()

# Returns {} on anything that is not a JSON object, so a malformed or hostile
# packet is dropped rather than crashing the peer that received it.
static func from_bytes(buf: PackedByteArray) -> Dictionary:
	var parsed = JSON.parse_string(buf.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}
