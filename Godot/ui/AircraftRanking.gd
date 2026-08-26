# OpenRC Simulator - which aeroplane to offer a beginner first.
#
# The order of a list is a recommendation whether or not it was meant as one.
# The roster used to arrive in whatever order the directory listing gave, which
# is alphabetical - so someone opening a TRAINING simulator was offered a
# short-coupled tail-dragging biplane at the top and had to scroll past it to
# find the trainer.
#
# Two questions are answered here, and keeping them apart matters:
#
#   HOW HARD IS IT TO FLY?  Wing loading, roll rate, stall speed, power to
#   weight, and whether it is a tail-dragger. This is what the player is told.
#
#   WHAT SHOULD I LEARN ON?  The same, plus a nudge for an aeroplane with no
#   undercarriage, which cannot be used to practise a take-off or a landing.
#   This is what the list is sorted by.
#
# Blending them into one number gave a wrong answer twice over: the 2.4 m
# glider is the most docile thing in the roster and came out harder to fly than
# a 579 W/kg aerobat purely because it is thrown, and the order between those
# two then hung on a seven-thousandth gap.
#
# Pure functions over plain dictionaries, so the ranking can be tested against
# the real roster without building a menu around it.
extends RefCounted


## How much of a handful an aeroplane is TO FLY, 0 to 1.
##
## Every term is something the aeroplane has been measured doing, not a number
## somebody typed. Power to weight is in here because on a model aeroplane the
## throttle is most of how twitchy the thing feels - without it a 579 W/kg
## aerobat scored within a hundredth of the trainer.
static func handling(card: Dictionary) -> float:
	var performance: Dictionary = card.get("performance", {})
	var loading: float = clampf(float(card.get("loading", 40.0)) / 80.0, 0.0, 1.0)
	var roll: float = clampf(float(performance.get("roll_rate_deg_per_s", 200.0))
							 / 450.0, 0.0, 1.0)
	var stall: float = clampf((float(performance.get("stall_speed_mps", 8.0)) - 4.0)
							  / 10.0, 0.0, 1.0)
	var power: float = clampf(float(card.get("pw", 250.0)) / 600.0, 0.0, 1.0)
	var score: float = loading * 0.30 + roll * 0.30 + stall * 0.15 + power * 0.25
	# A tail-dragger will try to swap ends on every take-off roll.
	if not bool(card.get("nose_wheel", true)):
		score += 0.12
	return clampf(score, 0.0, 1.0)


## What to learn on first.
static func learning_order(card: Dictionary) -> float:
	var score: float = handling(card)
	# A NUDGE, not a verdict: someone is better off on a docile glider they
	# cannot land than on an aerobat they cannot fly.
	if bool(card.get("hand_launched", false)):
		score += 0.12
	return score


## The word for that number, on an ABSOLUTE scale anchored on the Trainer 1500
## - which is what a trainer is for. Spreading the words across whatever
## happens to be in the roster made the reference trainer come out "lively",
## which is a contradiction in terms.
static func word(score: float) -> String:
	if score < 0.50: return "gentle"
	if score < 0.62: return "straightforward"
	if score < 0.72: return "lively"
	if score < 0.82: return "demanding"
	return "a handful"


## Sorts `cards` in place, gentlest to learn on first, and stamps each with its
## handling score and the word for it.
static func rank(cards: Array) -> void:
	for card in cards:
		card["difficulty"] = handling(card)
		card["learn_order"] = learning_order(card)
	cards.sort_custom(func(a, b) -> bool:
		return float(a["learn_order"]) < float(b["learn_order"]))
