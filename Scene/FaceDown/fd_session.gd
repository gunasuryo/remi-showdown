extends Node
class_name FDSession

# What the board plays against. One of these owns the match; the board only
# renders it and asks it to do things.
#
# There are two implementations and the board cannot tell them apart:
#   FDLocalSession   - holds the real FDState and drives the AI in-process
#   FDRemoteSession  - holds a redacted FDState the server sent, and posts
#                      actions over a socket
#
# The split exists because fd_table.gd used to own the rules directly: it called
# FDRules.resolve() inline, advanced the round itself, and pumped the AI in its
# own _process. None of that survives contact with a server, where the answer to
# "what happened" arrives later and from somewhere else. Everything now flows
# one way - the board submits, the session decides, the board re-renders on
# `synced` - which is the only shape that works for both.

# The match state moved on. `events` is what caused it, for the log and the
# damage numbers; it is empty for a plain resync.
signal synced(events: Array)

# Something to tell the player: a rejected move, an opponent joining or
# dropping. Never fatal on its own.
signal notice(text: String)

signal finished(winner: int)

# What the board renders from. For a remote session this is a REDACTED copy -
# a real FDState, but with FDCard.HIDDEN where the server withheld the enemy
# row - so every query the board already makes keeps working unchanged.
var state: FDState = null

var my_side: int = FDState.BLACK

func enemy_side() -> int:
	return FDState.RED if my_side == FDState.BLACK else FDState.BLACK

func is_my_turn() -> bool:
	return state != null \
		and state.phase == FDState.Phase.BATTLE \
		and state.side_to_act == my_side

# True while the session is waiting on someone else, so the board can say so
# instead of looking frozen.
func is_waiting() -> bool:
	return false

func waiting_text() -> String:
	return ""

# ── Overridden by each implementation ─────────────────────────────────────

func start() -> void:
	pass

func submit_placement(_row: Array) -> void:
	pass

func submit_action(_card_id: int, _kind: String, _target_slot: int) -> void:
	pass

func leave() -> void:
	pass
