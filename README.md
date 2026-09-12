# Remi Showdown

A turn-based card battler in Godot 4.1. Two teams of five playing cards - Ace,
Jack, Queen, King, Joker - line up across a board and fight until one side is
wiped out. Attacks are **lane-locked**: a card hits whatever stands in the slot
directly opposite it, and only skills get to pick their own target. Face-down
allows an attack one slot of give either way, for half damage; face-up does not,
so there the lane is the whole of it.

There are two game modes built on the same five cards. They no longer share a
stat table, and by now they share very little else either.

| | Face-up | Face-down |
|---|---|---|
| Board | cards and HP visible; **three statuses are not** | rows arranged face down each round |
| Buffs last | until their caster acts again or dies | until their caster acts again or dies |
| Attack reach | the lane it faces, only | its lane or either neighbour |
| Turn order | fixed, slot by slot | sides alternate, you pick which card acts |
| Dead cards | removed from the board | stay as **decoys** you can waste attacks on |
| Rules live in | `Scene/FaceUp/fu_rules.gd` | `Scene/FaceDown/fd_rules.gd` |

---

## Running it

Built and tested against **Godot 4.1.3 stable** (Mobile renderer, 1280x720).
Open `project.godot` in the editor and press play, or from this directory:

```bash
godot                                    # play
godot --headless --script res://test/run_tests.gd    # run the test suite
```

The game starts at `Scene/suit_select.tscn` and the flow is:

```
suit_select  ->  mode_select  ->  table_2.tscn      (face-up)
                             \->  fd_table.tscn     (face-down)
```

`mode_select` is also where you pick the opponent's difficulty. `GameState` is
an autoload holding the three things that cross a scene boundary: your suit,
the mode, and the difficulty.

---

## The cards

Every card can **attack** its own lane, or use its **skill**:

| Card | Skill |
|---|---|
| **Ace** | Shields an ally for 30, or three allies for 25 each when rallied. The shield is held up by the Ace - it lapses when that Ace acts again, and collapses if the Ace dies. |
| **Jack** | Shoots any enemy slot. The only action in the game with a free choice of target. |
| **Queen** | Heals an ally. |
| **King** | **Rallies** an ally one rung *up* that same ladder - a tricked ally is freed and nothing more, an untricked one gets its next skill covering three lanes instead of one. Rallying yourself instead arms **rally+**: the next rally lands on three allies at once, each getting that same ordinary rally. |
| **Joker** | **Tricks** an enemy one rung down the ladder `tricked - normal - rallied`: a rally comes off first, and only a card with no rally left gets its skill sealed. A King's *own* armed rally+ cannot be peeled - a trick on an armed King seals its skill for a while, but the arm survives. Against a rally+ the Joker gets one action to answer three rallied allies. |

The rungs above are **face-down's** reading of these skills. Face-up runs the
same five cards on the same numbers, but its Joker sets a hidden trap rather
than stepping a card down a visible ladder, and its rally is spent breaking that
trap rather than being peeled off by it. See *Hidden status (face-up)* below.

**Buffs are public for the round they happen in, and that makes them bluffable.**
A shield, rally or heal shows on the slot it was applied to even while the card
is face down - the enemy sees `SHIELDED` / `RALLIED` / `TENDED` on a lane, never
which card is in it. The mark is the *memory of watching it happen*, not the
buff: `begin_round` wipes marks along with reveals, so a shield that outlives
the round stops being visible once the rows are rearranged. A mark drawn from
lasting state would reappear on whatever slot the card moved to and quietly
report its new position every round - the opposite of what repositioning is for.
Support skills may also be spent on your own dead decoys, which achieves nothing
mechanically and is the entire point: a rallied corpse is indistinguishable from
a rallied survivor, so an action buys a lie about which lane is worth attacking.

Events are redacted per viewer too (`FDNet.redact_events`). They were being
broadcast raw, and `{"t":"rally","target":7}` names a card - ids map to names
through the public roster, so an unredacted event stream handed over exactly
what the snapshot refused to send.

This only works because the log redacts too. The rally line used to append the
target's skill word (`(SHOOT+)`), resolved without a reveal check, which named
a face-down card and would have made every bluff transparent on sight.

**The numbers are deliberately not repeated here.** `Scene/Shared/card_stats.gd`
owns HP, attack and skill values - a copy in this file would be wrong within a
week. Tune there and nowhere else.

It holds **one table per mode**, `STATS_FACEUP` and `STATS_FACEDOWN`, and they
are allowed to disagree. There used to be a single shared table, on the argument
that a copy would drift. That argument was right about copies and wrong about
these two games: face-up hides three statuses, treats a trick as a trap costing
a whole action, locks an attack to the lane it faces and holds a buff until its
caster moves, while face-down reveals rows, keeps corpses as decoys, lets an
attack reach a neighbour and runs on rounds. One Jack cannot be balanced for
both, and every attempt to tune one was quietly retuning the other.

What replaced "there is only one table" is that **no accessor has a default
mode**:

```gdscript
CardStats.hp_of("Jack", CardStats.FACE_UP)
```

A missing argument is a parse error, so a call site cannot silently read the
wrong game the way it could silently read a stale copy - the split changed the
shape of that failure rather than accepting it. That guard did its job during
the split itself: six reads in `run_tests.gd` were missed and named themselves
immediately instead of quietly reporting face-down numbers for face-up cards.

**The two tables currently hold identical numbers.** The split was structural,
not a rebalance - nothing was re-guessed. `run_tests.gd` checks both for
completeness and says so explicitly when they still coincide, because while they
do, its check that each mode is routed to the right table cannot fail.

A shield never fully stops a hit: `CardStats.SHIELD_LEAK` of every blow (with a
floor of 1) always reaches HP. That is what makes an unkillable defensive wall
impossible, so it is the constant that guarantees a match ends - it can come
down, but it can never be zero.

Face-down mode additionally multiplies every damage and shield number by
`FDRules.DAMAGE_SCALE`. That is the intended pacing lever: raise it to make
matches shorter, and do **not** tune match length by editing the stat table.
Healing deliberately does not scale with it. It is declared in exactly one
place: the board and `test/bench_ai.gd` used to carry their own copies, drifted
to 1.0 and 2.0 respectively, and every AI weight tuned through the bench was
silently measured against a different game than the one that shipped.

---

## Hidden status (face-up)

"Face-up" names the board, not the state. Every card, its HP and its position
are open. Three **statuses** are not, and each is visible only to the side that
caused it until the moment it does something the other side can watch:

| Status | Who can see it | What makes it public | How it ends |
|---|---|---|---|
| **Shield** | the Ace's own side | an enemy commits an attack *or a shoot* into the shielded card, and finds the Ace standing in front of it | the Ace acts or dies |
| **Rally** | the King's own side | the rallied card uses a skill and it covers three lanes instead of one | spent on a skill, or the King acts or dies |
| **Trick** | the **Joker's** side — *not* the victim's | the victim reaches for a skill | sprung, or the Joker acts or dies |

### A status belongs to the card that made it

All three end the same way: **when their caster acts again, or dies.** Nothing
expires on a clock. An Ace that stands still keeps shielding; an Ace that does
anything at all — including a plain attack — puts its shield down. Same for the
King's rally and the Joker's trap.

Two things follow, and both are the point:

- **One action moves a buff.** The release happens before the action resolves,
  so an Ace drops its old shield and raises a new one in a single turn, and a
  Joker frees an old target and traps a new one. Re-shielding the *same* ally is
  therefore a full top-up, not a no-op — `FUAI._shield_gain` has to know this or
  the AI would see "no room" on a full shield and never renew it.
- **Holding a buff means not having a turn**, and every card gets a turn. So a
  buff lasts exactly as long as its caster is willing to stand idle. The AI does
  not price this and correctly so: `_release_own` fires on *any* action, so the
  cost is paid identically by every option and cannot separate them.

This replaced three different expiry rules with one. The shield used to be wiped
at the start of the *shielded* card's own turn — a one-round buff belonging to
nobody, which the Ace could neither maintain nor move nor time. The rally was
cleared by whichever caller remembered to. Making expiry a property of the
caster acting is also what put the player and the AI back on the same rule
without either code path having to remember it.

The rally and the trap have one extra way to end, which is being used: a rally
is spent on the skill it widens (or on breaking a trick), and a trap is spent by
springing.

The trick is the one that inverts, and that inversion is the mechanic. A trick
is no longer a debuff you can read off the board and play around; it is a
**trap**. It does nothing at all until its victim tries to use a skill, at which
point the skill does not happen, the turn is gone, and the trap is spent. It has
no expiry — it waits.

Three consequences worth stating plainly, because each replaced an older rule:

- **A tricked card hits for half**, and the swing is what gives the trap away.
  This was taken out when the trap went hidden, on the reasoning that an owner
  watching their Jack hit for 13 instead of 26 has been told about the trick as
  surely as a label would. That is true, and it is the wrong conclusion - the
  board already had the right one. A hidden *shield* is given away by the blow
  that lands on it, and that is not a leak because the attacker has already
  committed. A trap works the same way: whichever action the victim commits, the
  cost lands and the trap goes public in the same instant. What the victim never
  gets is a chance to see it and choose differently.

  Revealed is not spent. The trap still denies the skill, and still ends only by
  springing, by its Joker moving or dying, or by a rally breaking it.

  Denying the skill *alone* had made the trick worth close to nothing, and
  `test/sweep_faceup.gd` measured exactly that: `trick` at 0.0 and at 0.35
  scored identically, because the scorer attacks on most turns and so most traps
  were simply never sprung.
- **The Skill button is always offered**, and a tricked card is offered its full
  action list. Hiding the button, or trimming `legal_actions`, would be the
  tell — the player would learn about the trap from the UI rather than from
  springing it.
- **A rally is armour.** A rallied card that walks into a trick gets its skill
  through, because the rally is spent breaking the trick instead of widening the
  skill: it covers one lane, not three. So the Joker traded its action for the
  King's, which is what keeps both cards worth playing, and a player who
  *suspects* a trick can push a skill through anyway at a known price.

**Three things redact, not one.** A hidden status has three ways out, and each
one had to learn the rule separately because each was written at a different
time:

| Surface | Leaks by | Gate |
|---|---|---|
| the battle log | naming the target in words | `table2._hidden()` |
| the animation | a caster rising behind the card, and the word that pops with it | `FUStage.cast_is_visible()` |
| the marker | a caster **parked** behind the card while it lasts | `table2._set_marker()` |
| the aiming preview | quoting a smaller number than the attack | `table2._preview_for()` |

Everything after the first is easy to miss, because nothing in them is written
in words. A Joker quietly appearing behind the player's own Jack gives the trap
away as completely as a sentence saying so. `FUStage.play()` took a `viewer`
argument for a while and never used it, which meant an enemy Ace shielding
popped a visible ghost.

The preview is the sharpest of the four and the least obvious: it quotes what a
blow would cost, so pricing it against the *real* shield turns it into an
X-ray — hover a lane, read a number smaller than the card's attack, and you have
found the Ace without spending anything. It has to promise the full figure and
let the blow under-deliver.

All four are covered by `test/test_fu_board.gd` and all four are
mutation-tested: reverting any one to the naive version produces an explicit
failure (`LEAKED` / `SHOWN` / `PARKED` / `priced a hidden shield`).

**The battle log redacts, and it has to.** Hiding a shield on the board while
the log says "Red Ace shields Red Queen" conceals nothing — this is the mistake
face-down had to fix twice. A redacted line still says that an action happened
and which card took it, because the player watched that much with their own
eyes; it is the target and the effect that stay secret. So an enemy Ace, King or
Joker using a skill logs as `Red Ace uses Shield` and no more. A Jack shooting
or a Queen healing is never redacted — the damage and the healing are on screen
either way.

**The AI plays into the same fog.** Everything `fu_ai.gd` reads about a status
goes through `FUState.sees_*` rather than off the card, so it cannot cheat by
construction — the same rule `FDState.observe()` enforces for face-down. It will
throw a kill shot into 30 points of shield it could not see, and it walks into
tricks on its own cards, loses the turn, and only then knows. `_rally_value()`
deliberately does not consult `tricked` on an ally for exactly this reason:
checking it would have the King quietly route around traps it has no way of
knowing about, which is the AI cheating in the least visible way available.

`test/test_fu_board.gd` feeds `table2._log_event()` hand-built events and checks
what reaches the log, asks `FUStage.cast_is_visible()` the same questions
directly, and sets up board state and reads `Card.has_marker()` back. None of it
is left to a played match: the log check was at first, as a string search over
whatever the AI happened to do, and breaking the redaction outright still
produced a clean run — the scorer rarely reaches for a shield or a rally. A leak
test that cannot fail is worse than no leak test, because it reads like
coverage.

---

## The face-off (face-up presentation)

`Scene/FaceUp/fu_stage.gd` is the layer outside the board, in the same relation
to `table2.gd` as `table2.gd` is to `FURules`: it owns no rules and asks no
questions, it is handed card nodes and an event list and it moves things about.

A turn reads as:

1. **`ROUND N` / `Red goes first`**, held for a moment and gone.
   `FUState.round_no` counts the passes of the slot walk. Nothing expires on a
   round and nothing resets, so the counter exists for this card and for the
   lead swap below. It lives on the state rather than the board because the
   board cannot spot a wrap reliably: `_start_turn` skips slots only one side
   can fill.

   Who leads used to be a second banner that stayed up for the whole face-off,
   and it sat across the top of a board the camera had just zoomed into — so it
   covered the very cards it was announcing. It belongs on this card instead:
   the lead alternates per round, which makes it round-level information, and
   this is the one thing on screen that is already round-level and already
   leaves. The copy that persists is in `TurnLabel`, inside the reserved HUD
   column where the camera guarantees no card can ever be.
2. **The face-off.** The two cards facing each other at that slot fill the
   screen and everything else dims to `FUStage.DIM`. The "closer to the screen"
   half is `BoardCamera.fit()` handed two cards instead of the whole board —
   the same mechanism that keeps a 2v2 endgame legible, asked a narrower
   question. A banner names which suit goes first.
3. **The choice**, on a menu between the two cards rather than pinned to the
   acting card, and labelled for what the skill actually is — `Shield`, `Shoot`,
   `Heal`, `Rally`, `Trick` — so the player never has to translate "Skill".
4. **Targeting opens the board back up.** Every skill in this mode picks a
   target, and a player cannot choose a lane they cannot see.
5. **The animation**, driven off the same event list the battle log reads:
   - an attack *leans* into the lane opposite it and comes back;
   - a shoot or a heal *travels* most of the way to what it is aiming at;
   - a caster **appears behind** the card it acted on — the Ace revealed to have
     been shielding, the King behind a rallied ally, the Joker behind a trap
     that has just gone off. It is a clone of the caster's face, not the caster
     itself, because the caster is usually somewhere else on the board and a
     revealed shield may belong to an Ace that has since died and been freed.
6. **Numbers rise off the card** as they change — `-12` in red for HP, `-8` in
   blue for what a shield ate (two pools, so two numbers, and a blow that
   vanishes entirely into a shield would otherwise pop `-0`), `+30` in green for
   a heal, and the word `SHIELDED` / `RALLIED` / `TRICKED` when one of those
   lands. The word rides the *same* `cast_is_visible` gate as the ghost beside
   it, in the same `if`, so the two cannot drift apart into a picture that shows
   what the word hides.

   While a target is being chosen, each candidate also shows what the press
   would do to it (`Card.show_preview`), which is the face-down idea in
   `FDTable._preview_damage`: picking a target should be a decision about their
   numbers, not a guess about your own.
7. **The caster then stays**, parked behind the card for as long as the status
   lasts (`Card.set_marker`). This replaced the gold and pink tints: a colour
   has to be learned before it means anything, and a card carrying both a rally
   and a trick could only ever wear one of them. It sits up and to the left so
   the transient ghost can rise centrally over the top of it — the marker says
   *this is still true*, the ghost says *this just happened*, and they have to
   be able to appear together. `doubleRally` keeps a tint, because it is a
   property of the King itself and there is no other card to stand behind.

**The lead alternates every round.** Acting second in a lane is worth something
real — the follower already knows whether the card opposite is still standing,
and whether it spent its turn on a skill. The coin flip still decides who leads
round one, which is what keeps face-up free of the seat imbalance face-down pays
about 14 points for; alternating after that means the advantage changes hands
rather than compounding over a long match.

The board widens *before* animating whenever an action reaches outside the pair.
A Jack shooting slot 4 from a screen zoomed in on slot 1 would otherwise animate
off the edge; a plain attack keeps the tight framing, which is what the framing
is for.

**Everything that takes time is a coroutine and the board awaits it.** Clearing
`table2.animate` before `_ready` makes every `FUStage` method return without
reaching an `await`, and the board then runs synchronously exactly as it did
before any of this existed. That is what the headless tests do — and it is also
why `test/test_fu_board.gd` has a third pass that runs with animation **on**,
wound forward with `Engine.time_scale`. The other two passes never touch the
code the shipping game runs, and the failure mode being guarded is specific: an
await chain that never reaches `_offer_turn()` again is a board that never takes
another input, and it looks exactly like a hang rather than like a bug.

Input is locked while anything is in flight (`table2._busy`), so a second tap
during a lunge cannot submit a second action - with two deliberate exceptions,
both routed through `_unhandled_input`. That hook is the right one rather than
merely a convenient one: a Control that was pressed consumes the event first, so
card buttons and the action menu are already excluded and "clicked on nothing"
needs no geometry test.

- **Left-click on empty board fast-forwards** the animation in flight. It winds
  live tweens forward (`FUStage.SKIP_SPEED`); it never kills them. `Tween.kill()`
  does not emit `finished`, so a skip written that way leaves every coroutine
  waiting on `await t.finished` blocked for good - and since the board only
  accepts input again when that chain reaches `_offer_turn()`, that is not a
  skipped animation but a hung game. The damage numbers are tweens on the Card
  and are deliberately not in `_live`, so skipping the choreography keeps the
  feedback it was carrying.
- **Right-click backs out of a target choice**, and does nothing else ever. A
  `Cancel` button in the HUD column does the same thing, because there is no
  right button on a phone. Cancelling returns the turn UNSPENT and re-narrows to
  the face-off that `_on_skill` widened.

Both are mutation-tested in `test/test_fu_board.gd`: implementing skip with
`kill()` stalls the animated pass on the frame guard, and a cancel that resolves
instead of backing out reports `cancel spent the turn - the actor moved on`.

**None of this has been seen.** It was built and verified headlessly: the state
machine terminates, the awaits always resolve, nothing leaks and nothing
crashes. Every duration and distance in `FUStage` is a guess that wants a human
eye — they are all named constants at the top of the file for that reason.

---

## Difficulty

Set in `mode_select`, applies to both modes.

- **EASY** - `fd_ladder_ai.gd`. A fixed priority ladder: heal whoever is hurt,
  snipe, trick, rally, otherwise attack. A coherent, readable game plan and a
  losing one, because a priority order cannot notice when the skill it is about
  to use is worth less than the attack it gives up.
- **NORMAL** - `fd_ai.gd`. HARD's scorer on HARD's weights, held back by an
  explicit blunder rate: it sometimes plays the second or third best move it can
  see. It is deliberately *not* a second weight set. It used to be a 342-line
  copy of the scorer whose weights had been left on an older stat table, which
  made it weaker only by accident and meant it got no better when HARD did.
- **HARD** - `fd_hard_ai.gd`. The same scorer playing its best move every time.

All three share `fd_scorer.gd`; the difficulty files hold nothing but numbers.
There is no lookahead in any tier.

Weights are produced by `test/sweep_ai.gd -- descend`, which is coordinate
descent against a three-opponent panel (attack-only, EASY, and the currently
shipped HARD). The panel is not decoration: against attack-only alone the
`shield_break` term cannot fire at all, because that opponent never shields.

Two traps for anyone re-tuning:

- **Read the `unfinished` column.** Win rate is computed over *finished*
  matches, so a setting that stops matches ending scores brilliantly while
  breaking the game.
- **The terms interact.** Raising `rally_discount` flipped the best `kill` from
  0 to 10, and the pair together shortened matches that either alone lengthened.
  A one-at-a-time table off a stale base reads as noise.

Face-up weights are swept by `test/sweep_faceup.gd`, the face-up counterpart to
`sweep_ai.gd` - coordinate descent against a three-opponent panel (attack-only,
the EASY ladder, and the currently shipped set). It did not exist until the
weights were first re-tuned, so the shipped numbers had been the first guess
anyone made and had then survived four rule changes that invalidated all of
them. Re-sweeping moved the panel mean from 71.2% to 84.1%.

Two lessons from that sweep are worth keeping:

- **A tie is not a finding.** `shield` came back as 0.0, which would have
  stopped the AI ever shielding. At the final set, 0.0, 0.15 and 0.35 all
  measure the same - the descent kept 0.0 only because it was tried first and
  improvements need a strict `>`. Where the metric is indifferent, prefer the
  setting that actually plays the game.
- **Check the edges of the grid.** `kill` won at 90.0, the top of the range,
  which looks like a grid edge rather than an optimum. Extending it to 130 and
  180 measured identically, so the curve really does flatten - but that had to
  be checked rather than assumed.

Face-up mode has its own scorer, `Scene/FaceUp/fu_ai.gd`, holding all three of
its brains. EASY plays a priority ladder there too; NORMAL and HARD both play
the scorer at its best, so **they are the same opponent**. Face-up has neither a
second weight set nor a blunder rate, and no sweep harness to derive one with -
that gap is real, not an oversight of this file.

Measured over 800 matches per matchup (`test/bench_ai.gd`), face-down:

| Matchup | Result |
|---|---|
| HARD vs attack-only | 97.4% |
| NORMAL vs attack-only | 69.6% |
| NORMAL vs EASY | 78.1% |
| HARD vs NORMAL | 87.0% |
| EASY vs random | 86.5% |
| attack-only vs itself (control) | 48.5% |

Attack-only is a genuinely strong strategy here, not a strawman - it beats every
priority ladder ever written for this game. That is the bar the scorer had to
clear. NORMAL is deliberately held at ~70%: a player who just attacks should
win about three matches in ten.

`test/control_fd.gd` is the harness control - two identical policies over 3000
matches, which must land near 50% (currently 48.6%). Run it before believing
any surprising result. It is also what turned up the seat imbalance below.

Face-up, measured over 800 matches per matchup (`test/bench_faceup.gd`):

| Matchup | Result | unfinished | before tuning |
|---|---|---|---|
| attack-only vs itself (control) | 48.0% | 0 | 51.0% |
| scorer vs attack-only | **89.5%** | 0 | 85.1% |
| scorer vs EASY (ladder) | 90.8% | 8 | 91.8% |
| scorer vs random | 99.3% | 0 | 98.8% |
| EASY vs attack-only | **61.1%** | 3 | 17.4% |
| EASY vs random | 96.9% | 0 | 97.0% |

**The EASY row has flipped, and it retires an argument this file made for a
long time.** A priority ladder used to lose to an opponent that only ever
attacked, 8 times in 10, and that was the whole case for replacing it with a
scorer. It now *wins* 6 times in 10. Nothing about the ladder changed - the
trick did. While a trap only denied a skill it was worth nothing, and the ladder
spends a great many turns setting them; now that a trap also halves an attack,
the same stubborn trick-first play that used to be its weakness pays off.

The case for the scorer is now the scorer's own row rather than the ladder's
failure: 89.5% against attack-only, against the ladder's 61.1%.

**Watch the `unfinished` column — caster-held shields made it worse.** It was 1
match in 800; it is now 6. A shield no longer expires on a clock, so an Ace that
keeps renewing one, behind a Queen who keeps healing, can outrun the damage
coming at it. `SHIELD_LEAK` still floors damage *through* a shield and is what
guarantees any given shield is finite, but it says nothing about healing and
nothing about renewal. This is the number to watch if the Ace or the Queen is
tuned further.

**Skills are worth more than they were.** The scorer now reaches for one on
9-12% of its turns, against about 5% before. Removing the sideways attack is
what did it: a plain attack used to come with a free choice of three lanes on
every single turn, which is a damage-shopping option no skill had to beat.
Face-down keeps the sideways reach because a lane there may hold a corpse and
avoiding a wasted turn is the decision worth having; face-up has no decoys, so
it was only ever a discount.

**Every arrangement is played twice, once under each lead.** Leading round one
is a real disadvantage here - about 10 points, measured, and symmetric between
the colours (leaders 45.3%, followers 54.8%). The bench used to let a seeded
coin flip decide the lead and trust 800 matches to average it out. It does not:
the attack-only control, which is two identical policies and must land on 50%,
came out at **44.3%**. Splitting that run by seat showed leaders-who-were-`left`
winning 39.9% and leaders-who-were-`right` winning 51.0% - the same policy, on
the same boards, eleven points apart on nothing but which seat the harness
happened to call first.

Pairing removes it by construction rather than statistically: the identical row
arrangement is dealt out under both leads, so whatever the lead is worth, it is
worth to both sides exactly once. The control came back to 48.0%. Anything that
far off 50% now is a real harness bug rather than something to average away -
which is what a control is for, and it had quietly stopped doing its job.

**Face-up mode is deterministic, and the bench has to work around it.**
`FURules` uses no RNG and neither does any brain, so a match is a pure function
of who leads and how the two rows are arranged - the same pairing replays the
same game forever. The bench shuffles the opening slot order per match, and
that shuffle is the *only* thing being sampled. Without it every row above
reads 100% or 0%, the median match length equals the maximum, and 800 matches
are 800 copies of two games. The shipped game always opens in `CardStats.ORDER`,
so these rows measure a policy across arrangements rather than the single
arrangement a player actually sees.

Two things the new harness turned up:

- **The old bench had stopped measuring its most important row.** It drove
  `table_2.tscn` and played "blind" by calling `table._on_attack()` - which,
  once an attack gained a choice of three lanes, stopped resolving and put the
  board into `player_target` waiting for a click no headless run would ever
  make. Every blind match hung there.
- **About one match in 400 does not terminate.** A Queen out-healing the damage
  coming at her can stall a face-up match indefinitely. Face-down cannot do
  this: `DAMAGE_SCALE` and the round structure bound it. Face-up has only
  `SHIELD_LEAK`, which floors damage *through a shield* and says nothing about
  healing. Watch the `unfinished` column.

### Known imbalances

Measured, not fixed - these are design decisions rather than bugs:

- **Leading round 1 costs ~14 points.** Black leads round 1 and wins 43%;
  flip the rule in `FDRules.begin_round` and the advantage follows exactly.
  It is specifically round 1, not cumulative leadership: the split is identical
  in odd- and even-length matches. Since `suit_select` is the first screen of
  the game, the player's colour choice silently sets the difficulty. Face-up
  mode already avoids this two ways: it coin-flips who leads round one, and it
  then alternates the lead every round, so the edge changes hands instead of
  accruing to one seat all match.
- **The Jack does 62% of all damage** and takes half the kills. It has the
  highest attack in the game *and* the only free-targeting damage skill, so it
  is best at both halves of every decision it faces. 95% of all rallied skills
  are Shoot+ - the rally engine is really a Jack-feeding machine.
- **The Queen** was the squishiest card in the game at 40hp while also being the
  support card, and died first in a third of all matches. Raised to 55hp, which
  cut that to 52 in 400. Her damage share stays lowest and that is fine - she
  spends three quarters of her turns healing. Attack was deliberately not
  touched: it is 70% of all actions taken, so `atk` is the dominant stat and
  every change tested rippled somewhere unintended.
- **The AI is exploitable by a human in a way self-play cannot measure.** A
  player reported beating HARD reliably with a trick-heavy game; the simulated
  equivalent loses badly to it. Chasing that gap found two genuine bugs in the
  trick scorer (below), but the residual is real: the AI has no opponent model,
  never anticipates being tricked, and funnels ~64% of its damage through one
  card. A human who neutralises the Jack neutralises the AI, and a deterministic
  one-ply scorer cannot learn that it is being read. Treat self-play win rates
  as a floor on human difficulty, not a measure of it.
- **There is one strategic axis, not a metagame.** `test/strategy_fd.gd` runs a
  round-robin between deliberately lopsided playstyles and finds a strict
  pecking order with no counterplay anywhere. `FDRules.DAMAGE_SCALE` slides
  which end of it wins - tempo at 1.0, attrition below ~0.80 - rather than
  creating diversity.

---

## Layout

```
Scene/
  suit_select.*          pick your colour
  mode_select.*          pick the mode and the difficulty
  GameState.gd           autoload: suit, mode, difficulty
  Shared/
    card_stats.gd        the stat tables - one per mode, plus the constants
                         both still share (SHIELD_LEAK, leak_of, ORDER)
    battle_log.gd        the scrolling BBCode log, shared by both modes
  Card/                  face-up card scenes — art, buttons, health bars.
                         They hold NO rules: a subclass is a name and three
                         numbers, and card.gd is a view of one FUCard.
  FaceUp/
    fu_card.gd           card DATA, no nodes
    fu_state.gd          match state: rows, turn cursor, outcome
    fu_rules.gd          the rules engine - pure, no scene references
    fu_ai.gd             all three brains: scorer, ladder, random
    fu_stage.gd          the animation layer: round card, face-off, tweens
  Table/table_2.tscn     face-up board        (controller: ../table2.gd)
  FaceDown/
    fd_card.gd           card DATA, no nodes
    fd_state.gd          match state: slots, reveals, round bookkeeping
    fd_rules.gd          the rules engine - pure, no scene references
    fd_scorer.gd         THE scoring engine, shared by NORMAL and HARD
    fd_ai.gd             NORMAL: weights + blunder rate, nothing else
    fd_hard_ai.gd        HARD: weights, nothing else
    fd_ladder_ai.gd      EASY: priority ladder
    fd_random_ai.gd      benchmark floor: picks uniformly at random
    fd_card_view.*       one board slot
    fd_table.*           the board (presentation only)
test/                    see below
```

Both sides now follow one hard rule: **`fd_rules.gd` and `fu_rules.gd` never
reference a scene, node or texture.** That is what lets whole matches run
headless in the test suite, and it is worth preserving. A board observes state
and issues actions; it holds no rules.

Face-up mode reached that shape late. `table2.gd` was 948 lines holding the
rules, the turn loop, the AI and the node manipulation together, and the card
scenes applied their own skills directly to each other's nodes - `Jack.do_skill`
called `hit()` on a Node2D and emitted the log line itself. A rule and a scene
object were the same thing, so face-up had no unit tests at all, and its only
benchmark had to instantiate the whole board once per match.

Three bugs fell out of the move, all of them cases where the human's code path
and the AI's had drifted apart while pretending to be one rule:

- **Rally stacked for the player and not for the AI.** Clearing the previous
  rally was the caller's job, and only the AI's caller did it. Both `card.gd`
  and `King.gd` documented the no-stacking rule the AI was following, so that
  is the one `FURules._clear_rallies` now enforces for everyone.
- **An armed King could hoard the arm.** The player's path always spent a
  double rally; the AI's could hand out single rallies and stay armed forever.
  Spending it is now the only legal move.
- **A King could rally itself as one of its own pair**, through the player's
  two-step picker only.

One comment also turned out to describe something the code never did: a rally
was said to be "wasted" if the card attacked instead of using its skill.
Nothing ever cleared it. A rally is spent by using a skill and by nothing else,
which is now what both the code and `F7` say.

Hidden information has a matching rule: everything the AI knows about enemy
slots comes from `FDState.observe()`, which only returns revealed ones, so it
cannot cheat by construction.

---

## Multiplayer (face-down only)

Authoritative server. The only real `FDState` lives in `server/fd_server.gd`;
clients hold a **redacted** copy that physically does not contain the
opponent's unrevealed row.

```bash
# Run the server (any machine both players can reach)
godot --headless --path RemiShowdown --script res://server/fd_server.gd -- port=8910
```

In game: **mode_select -> PLAY ONLINE**. One player enters the server address
and creates a room, reads the four-letter code aloud, and the other types it in.
The code alphabet omits O/0, I/1 and S/5 because the code gets spoken. The
server address is remembered in `user://remi.cfg` so it is typed once.

The server assigns seats, so the suit chosen on the way in does not apply to an
online match - and neither does the difficulty, since there is no AI in one.

The client layers:

```
fd_table.gd        renders, and submits through a session. Owns no rules.
  FDSession        the interface the board talks to
  FDLocalSession   single player: holds the state, drives the AI in-process
  FDRemoteSession  online: posts actions, renders the server's snapshots
```

The board cannot tell the two sessions apart. Everything flows one way - the
board submits, the session decides, the board re-renders on `synced` - which is
the only shape that works when the answer arrives from somewhere else, later.

**Why authoritative and not lockstep.** `FDRules.resolve()` uses no RNG, so
both peers replaying the same actions would stay in sync perfectly and lockstep
would be *less* code. It is still wrong here: this mode is built on not knowing
where the enemy cards are, and lockstep needs every peer to hold the full state,
so a modified client could just read it. The server has to run the rules to
validate moves anyway - and `resolve()` already returns `{ok, error}`, so
validation was free.

**What a client is told:** its own cards in full; enemy card *names and alive
flags* (public - the roster shows them and every death is announced); enemy
hp/shield/rally only while that card stands in a revealed slot; and the enemy
row with every unrevealed identity replaced by `FDCard.HIDDEN`.

`FDCard.HIDDEN` exists so that "nobody is here" and "somebody is here and you
cannot see who" are different values. Sending a plausible but false card id
instead would have put a lie in the client's memory for some later bug to
render.

**Disconnects.** A seat is held for `SEAT_HOLD_SECONDS` and returned to whoever
presents the seat token issued on join. The token is also the authorisation: a
held seat is *not* offered to a tokenless joiner, or anyone who guessed the room
code could take a dropped player's seat mid-match.

**Staying in step.** The socket staying up is not the same as the match staying
in step, and this is where "we got stuck" came from. Every state push is a *side
effect* of somebody doing something — joining, placing, acting — so a client that
missed one had no way to ask for another. It waited for a move it had already
been sent, on a socket that never dropped, with nothing on screen to suggest
anything was wrong.

Three pieces fix that:

- **Sequence numbers.** Every snapshot carries `seq`, bumped once per real state
  change. A gap tells the client it missed a push. The *board* is never
  corrupted by one — snapshots are absolute, not deltas, so the next one is the
  whole truth — but the **events** for the missing step are gone, so the client
  drops the ones it did get rather than narrating half a turn.
- **`{"t":"resync"}`.** The client can ask. The server replies to that peer
  alone with the current board, flagged `resync`, carrying no events and
  *without* bumping the sequence: nothing happened, and a resync that looked
  like a step would make the opponent think *they* had fallen behind.
- **A watchdog on silence.** Two different silences matter and only one is
  obvious. Waiting on the opponent is the visible case. Waiting on your **own**
  move to come back is the one that bites: locally it is still your turn until
  the sync lands, so anything keyed on "is it my turn" sees nothing wrong at all
  and waits forever. `FDRemoteSession` tracks both.

**Events are redacted BEFORE `advance()`, and that ordering is the bug that
started this.** `_do_action` used to resolve, advance, and only then redact — but
`advance()` can roll the round over, and `begin_round()` empties both rows and
clears every reveal. `visible_id()` then asked "is this card in a revealed
slot?" of a board that no longer existed, got `-1` back from `slot_of()` for
everything, and hid the lot. The player's log described the action they had just
watched as happening to "a face-down card", and no enemy HP was sent at all.

A rallied **Shoot+** is the likeliest way to hit it: three lanes at once, often
the last action of a round, often several kills. `test_fd_net.gd` N8 pins it by
redacting the same events on both sides of `advance()` — three named targets
become none.

### Hosting it

`server/cloud-init.yaml` is a Hetzner Cloud "Cloud config" that builds the box:
Godot 4.1.3, an unprivileged `remi` user, a systemd unit, Caddy for TLS, and a
firewall that opens only 22/80/443. `server/deploy.sh user@host` pushes the
project and restarts the service.

**It must be `wss://`, not `ws://`.** The Android export targets SDK 33 and the
Godot templates do not set `android:usesCleartextTraffic`; from SDK 28 the
platform default is to block cleartext, so a phone refuses `ws://` to a bare IP.
Caddy terminates TLS with an automatic Let's Encrypt certificate, which needs a
domain name pointed at the server - an IP alone will not do.

Two things that are easy to get wrong:

- **The game port is never exposed.** 8910 is absent from the firewall rules;
  Caddy reaches it on loopback, and only 443 is public.
- **The script-class cache is built on the server, not uploaded.** Godot resolves
  `FDRules`, `FDNet` and friends through `.godot/global_script_class_cache.cfg`,
  which `remi-reload` regenerates with a headless editor pass. Skipping it gives
  `Identifier "FDNet" not declared in the current scope` at startup.

The upload is ~3 MB, not the ~600 MB the project weighs on disk: the server
loads no scene and no texture, and `android/` alone is 207 MB of build
templates.

Face-up mode is not networked, but it is now *networkable*: `FURules.resolve()`
already returns `{ok, error, events}` and touches no scene, which is the shape
`FDSession` was built against.

It also now *needs* the other half. It was true, briefly, that a face-up server
would only have to validate — with everything visible there was nothing to
redact. Hidden status ended that: a client holding the full `FUState` could read
every unseen shield, every rally and, worst of all, every trap set on its own
cards, which is precisely the knowledge the mode is built on withholding. The
per-viewer queries a redactor would need already exist and are already the only
way the AI reads a status (`FUState.sees_shield` / `sees_rally` / `sees_trick`),
and `table2._log_event` is already a working redactor for the log. What is
missing is a snapshot that drops what those queries refuse, the way
`FDNet.redact_events` does.

---

## Audio

```
Asset/Audio/Music/           the soundtrack
Asset/Audio/SFX/CasinoSFX/   Kenney Casino Audio - cards, chips, dice
Asset/Audio/SFX/RPGSFX/      Kenney RPG Audio - impacts, cloth, books
default_bus_layout.tres      Master, with Music and SFX feeding it
Scene/Shared/audio.gd        the `Audio` autoload: player, cues, volumes
Scene/Shared/sound.gd        `Sound` - how non-scene scripts reach the autoload
Scene/Shared/audio_panel.gd  the volume sliders, built in code
Scene/Shared/game_menu.gd    the in-battle menu: Audio, Exit Game, Resume
```

**Cues are named for what happened, never for a file.** Call sites say
`Sound.cue("attack")`; `Audio.CUES` maps that to one or more takes and picks at
random. Several entries list three or four because Kenney numbers its variants
for exactly this reason — the same sound on every attack of a forty-action match
turns into a machine gun. Single-take cues get a small pitch wobble instead.

**Sound is a redaction surface too.** An enemy Ace shielding must not be
*audible* any more than it may be visible, so the cast cues sit inside the same
`cast_is_visible()` gate as the ghost and the floating word — the same `if`, so
they cannot drift apart. That makes five surfaces a hidden status can escape
through: the log, the animation, the marker, the aiming preview, and now audio.

**`Sound` exists because an autoload is not an identifier everywhere.** The
main-loop script of a `--script` run compiles before autoloads register, and so
does every `class_name` script it names — `test_fu_board.gd` calls
`FUStage.cast_is_visible()`, so the moment `fu_stage.gd` said `Audio.play_cue()`
the whole test stopped building. Scene scripts like `table2.gd` are fine, the
same way they have always referred to `GameState`. Everything else resolves
`/root/Audio` by path at call time.

Three things here are load-bearing, and all three fail *silently* when they are
wrong — no crash, just a game that is quiet, or that stops being musical after
one play.

**The player is on an autoload, not in a scene.** `change_scene_to_file()` frees
the scene it is leaving, so an `AudioStreamPlayer` placed on a board would be
destroyed and rebuilt by every scene change, restarting the track each time.
`Audio` sits outside the tree being swapped, so a track survives whatever the
game does to its scenes.

**The autoload owns the player; it does not decide when to play.** Music belongs
to a battle, so the menus are silent: `table2` and `fd_table` call
`Audio.play_music()` in `_ready()`, and `mode_select` calls `Audio.stop_music()`
in its own. Stopping on ARRIVAL at the hub rather than on departure from a board
is deliberate — there are several ways out of a match (the Menu button, the
Android back gesture, the game-over screen) and they all land at `mode_select`,
so one call covers every one of them including any added later.

**Volume is applied to buses, not to players.** A player's `volume_db` moves one
sound; a bus moves everything routed to it, including sounds that do not exist
yet. That is the entire reason `default_bus_layout.tres` exists — and note that
Godot only loads it from the path in `project.godot`, so the file alone is not
enough. The sliders are linear and hearing is not, so `Audio._apply` converts
through `linear_to_db`: assigning the slider value to `volume_db` directly is
the classic way to get a control that does nothing for most of its travel and
then falls off a cliff.

**Looping is an import setting**, the Loop tick in the import dock, stored in
`Asset/Audio/Music/*.import` and **false by default**. It is one careless
re-import away from a track that plays once and stops, so `Audio.play_music()`
also forces `stream.loop = true` at runtime. Belt and braces, deliberately:
that makes looping a property of the game rather than of a sidecar file.

The Menu button on either board opens the in-battle menu rather than leaving.
Face-down always asked before leaving; **face-up did not** - one tap on
`< Menu` ended the match, and the Android back gesture routed into the same
call. Leaving is now a choice inside the menu, and both modes confirm.

`test/test_audio.gd` covers all of it — the buses exist by name, the track
loads and loops, the player is actually playing, a lower slider is a lower bus
volume and zero is genuinely silent, and the two scenes that hang controls off
this load with those controls present.

---

## Tests and benchmarks

```bash
# BOTH rules engines: 231 assertions, plus four integration checks - a
# face-down smoke match, a face-down AI match, the face-up stat wiring, and
# 40 random face-up matches that must all reach a winner.
# Exits non-zero on failure, so it can gate a commit or an export.
godot --headless --script res://test/run_tests.gd

# Face-down AI: every difficulty against every other, 800 matches per matchup.
godot --headless --script res://test/bench_ai.gd

# Re-derive the HARD weights: coordinate descent against the opponent panel.
godot --headless --script res://test/sweep_ai.gd -- descend
# ...or sweep one term, or NORMAL's handicap.
godot --headless --script res://test/sweep_ai.gd -- save
godot --headless --script res://test/sweep_ai.gd -- blunder

# What the AI actually DOES: attack/skill mix, which skill, rally lifecycle.
godot --headless --script res://test/analyze_fd.gd
# ...and the self-rally A/B: is arming rally+ worth two King actions?
godot --headless --script res://test/analyze_fd.gd -- rally

# Audio: buses, the loop flag, and the scenes that hang controls off them.
godot --headless --script res://test/test_audio.gd

# Multiplayer: wire format and redaction (no server needed).
godot --headless --script res://test/test_fd_net.gd

# The in-game rules sheet: sections present, and its numbers match CardStats.
godot --headless --script res://test/test_rules_panel.gd

# Multiplayer end-to-end: start the server first, then any of these.
godot --headless --script res://test/test_fd_server.gd -- port=8910
godot --headless --script res://test/test_fd_rejoin.gd -- port=8910
godot --headless --script res://test/test_fd_resync.gd -- port=8910

# Face-up AI: 800 matches per matchup, headless on FURules.
godot --headless --script res://test/bench_faceup.gd
# ...or one policy against blind plus its own control.
godot --headless --script res://test/bench_faceup.gd -- scorer

# Face-up BOARD: 27 matches through the real table_2 scene, in three passes -
# 12 driven by the board's own AI, 12 played through the BUTTON HANDLERS as a
# tapping player reaches them, and 3 with the ANIMATION LAYER ON. The second
# pass is the only coverage the target picker and the armed King's two-step pick
# have anywhere; the third is the only thing that runs FUStage at all. This is
# also the only face-up test that needs a scene, which is the point of it.
godot --headless --script res://test/test_fu_board.gd
```

Both benchmarks run a **control matchup** first - the same policy on both sides,
which has to land near 50%. If the control is lopsided the harness is biased and
the other rows mean nothing.

Worth running `run_tests.gd` before an export. A parse error in one script makes
its whole class fail to register, which surfaces much later and much more
confusingly as a "nonexistent function" at runtime.

---

## Known gaps

- **No Joker artwork.** Both modes borrow the King's and flip it vertically.
  `Asset/JokerBlack.svg.import` and `JokerRed.svg.import` are orphaned sidecars
  whose source files are gone; drop real art in and remove the fallback in
  `FDCardView.art_for()`.
- **No card-back asset.** Face-down slots use a drawn back (dark panel, `?`).
- `Scene/Table/table.tscn` and `table.gd` are the superseded first-pass board,
  kept but not reachable from the menus. `table_2.tscn` is the live one.
  `table.gd` is now definitively dead rather than merely unused: it calls
  `Card.do_skill()` and `Card.card_acted()`, and neither exists any more - the
  first moved into `FURules`, the second had already been gone for a while.
  It is a runtime error away from the menu it is not wired to. Delete it.
- **Neither** `CardStats.MAX_SHIELD_FACEUP` nor `MAX_SHIELD_FACEDOWN` is
  reachable: in both modes a shield is tied to a single Ace which drops the old
  one before raising a new one, so only one application is ever live and the
  ceiling equals the grant.
- `CardStats.rallied_skill_of()` and the per-card `"rallied"` values in `STATS`
  have **no readers**. Neither engine calls it; a rallied skill still lands its
  full `skill` value in each of the three lanes it covers. The accessor and the
  data are in place for whoever wires it up, and the decision it is waiting on
  is whether both modes should read it or only face-down.

---

## Design docs

`PRD-facedown-mode.md` and `PLAN-facedown-mode.md` (in the parent directory,
outside this repo) specify face-down mode. Both are still accurate on rules and
architecture. Two places where the code knowingly diverges, and why:

- **Positioning is a phase inside `fd_table`, not a separate scene.** It happens
  every round; splitting it out would mean marshalling `FDState` through an
  autoload and rebuilding the match log at every round transition.
- **The NORMAL AI is not the PRD section 11 ladder.** That ladder is still
  here as EASY. It lost 400 matches out of 400 to an opponent that only
  attacked, which is what motivated the scoring rewrite.
