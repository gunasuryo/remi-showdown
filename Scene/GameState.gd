extends Node

# Global game state passed between scenes

enum Mode { FACE_UP = 0, FACE_DOWN = 1 }

# The three tiers, face-down mode (see Scene/FaceDown/):
#
# EASY   - fd_ladder_ai.gd. The original priority ladder: heal whoever is hurt,
#          snipe, trick, rally, otherwise attack. A coherent game plan, just a
#          losing one - a fixed order cannot notice when the skill it is about
#          to use is worth less than the attack it gives up.
# NORMAL - fd_ai.gd. HARD's scorer on HARD's weights, held back by an explicit
#          blunder rate: it sometimes plays the second or third best move it
#          can see. It used to be a stale copy of the scorer that was weaker
#          only by accident; the gap is now a number someone chose.
# HARD   - fd_hard_ai.gd. The same scorer playing its best move every time,
#          on weights swept by test/sweep_ai.gd against a three-opponent panel.
#
# There is NO lookahead in any tier, despite what this comment used to claim.
#
# Face-up mode has the same three tiers in Scene/FaceUp/fu_ai.gd, but only two
# brains: EASY plays that file's priority ladder, and NORMAL and HARD BOTH play
# its scorer at full strength, so they are the same opponent. There is no
# second weight set and no blunder rate on that side. (This comment used to say
# face-up EASY was random - it has always been the ladder; random is the
# benchmark floor in test/bench_faceup.gd and is not reachable from the menu.)
#
enum Difficulty { EASY = 0, NORMAL = 1, HARD = 2 }

# Who the face-down board plays against. ONLINE swaps FDLocalSession for
# FDRemoteSession; nothing else about the board changes.
enum Opponent { AI = 0, ONLINE = 1 }

var opponent: int = Opponent.AI

# Where the match server lives, and which room to ask it for. `seat_token` is
# handed out on join and is what buys the seat back after a dropped connection,
# so it is kept here rather than in the board scene, which is torn down and
# rebuilt on a rematch.
# The match server this build ships pointed at, so nobody has to type an
# address to play. It is still overridable from the lobby (and remembered in
# user://remi.cfg) for testing against a local server or a different host.
#
# wss:// rather than ws:// is not a preference: the Android export targets SDK
# 33, and from SDK 28 the platform blocks cleartext by default, so a ws:// URL
# simply fails to connect on a phone with no useful error.
const DEFAULT_SERVER_URL := "wss://remishowdown.duckdns.org"

var server_url: String = DEFAULT_SERVER_URL
var room_action: String = "create"   # "create" or "join"
var room_code: String = ""
var seat_token: String = ""

# Why the board sent the player back to the lobby, shown there once. Set for a
# bad room code, an unreachable server, or a connection given up on.
var last_error: String = ""

# The server address is the one thing here worth remembering between runs -
# nobody wants to retype a host on a phone keyboard every match.
const PREFS_PATH := "user://remi.cfg"

func _ready() -> void:
	load_prefs()

func load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return
	var saved: String = str(cfg.get_value("online", "server_url", ""))
	if saved == "":
		return

	# A saved address must not outlive the build that suggested it. An earlier
	# build shipped pointing at ws://127.0.0.1:8910 and wrote that to disk on
	# every create/join; installing a build with a working default on top of it
	# then loaded the dead localhost address and ignored its own default. The
	# symptom is the worst kind - the client sits on "Connecting..." forever,
	# dialling a server that was never there.
	#
	# So the file records which default it was written against. If this build
	# ships a different one, the saved value came from an older build and is
	# discarded. A genuinely hand-entered address survives, because writing one
	# stamps the current default alongside it.
	var written_against: String = str(cfg.get_value("online", "shipped_default", ""))
	if written_against != DEFAULT_SERVER_URL:
		push_warning("remi: discarding saved server '%s' from an older build" % saved)
		return

	server_url = saved

func save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	cfg.set_value("online", "server_url", server_url)
	# Stamped so a later build with a different default knows this value is
	# stale rather than deliberate.
	cfg.set_value("online", "shipped_default", DEFAULT_SERVER_URL)
	cfg.save(PREFS_PATH)

# Forget the saved address and go back to what this build ships with. The lobby
# offers this as a way out when nothing connects.
func reset_server() -> void:
	server_url = DEFAULT_SERVER_URL
	save_prefs()

# In an online match the server decides which seat you get, and it overwrites
# this when the room is confirmed.
var player_suit: int = 1  # 1 = Black, 2 = Red
var mode: int = Mode.FACE_UP
var difficulty: int = Difficulty.NORMAL
