# Failures

This is the part a toy does not have, and it is where most of the training value
is. Nobody needs practice at flying a model that works. What kills models is the
motor stopping on the far side of the circuit, a servo jamming halfway through a
turn, or the radio going quiet for two seconds at fifty feet — and every one of
those is survivable if you have met it before and unrecoverable if you have not.

| key | failure | what it does |
|---|---|---|
| `4` | **Dead stick** | The motor stops. You still have every control. |
| `5` | **Jammed aileron** | The servo holds where it was. Mid-turn, the turn continues. |
| `6` | **Elevator linkage** | The surface goes neutral and will not answer. |
| `7` | **Radio loss** | Nothing gets through for a couple of seconds. |
| `8` | **Brownout** | The receiver resets, then comes back. |
| `9` | Clear | Everything works again. |

## They fail the way the real thing fails

A "dead stick" that also centres the sticks teaches nothing, because the hard
part of a dead stick is that you have full control and no power. A jammed servo
that goes to neutral is not a jammed servo — it is the *other* failure, and the
one that is far easier to survive. The distinctions are the whole point, and the
regression suite checks each of them specifically rather than checking that
something changed.

**A servo jams where it was, not where it is safe.** The model keeps the last
command it saw while everything was working, and freezes that. Capturing it on
the first update *after* the failure looked equivalent and was not: a pilot who
centres the stick the instant they notice would have the jam freeze the centred
value, which is the one position that makes a jam harmless.

**Failsafe is a setting, because both are configurations people fly.** Holding
the last command means an aeroplane that was turning keeps turning, all the way
in. Going neutral means it probably flies itself into a wide descending circle.
They fail very differently, and a pilot should know which one their receiver
does.

**A brownout cuts the motor whatever the failsafe says.** The receiver is down;
it cannot hold anything. It is also the failure that arrives at the moment of
highest current draw, which is usually the go-around.

## Where they sit

Between the transmitter and the flight model, on the channels — and on the
propulsion for a dead stick. Nothing downstream knows a failure has happened,
which is the point: the aerodynamics does not need a special case for a jammed
aileron, it just gets an aileron that does not move.

The telemetry and the replay show what the **pilot** asked for, not what the
servos did. A jammed servo should not make the stick display lie about where the
stick is.

## Failure practice

The training mode. One setting - the chance a flight has a failure at all - and
four rules (`RCPhysics/Training/FailurePractice.h`):

- **One draw per flight.** 30 % means three flights in ten. A rate per minute
  makes a long flight certain to fail and teaches the pilot to wait for it.
- **Never on the ground.** The failure arrives after 20 to 120 s of proper
  airborne time - more than 5 m up, wheels unloaded - so it is always an
  emergency to fly, never a model that will not take off.
- **One, and it stays** until the next flight.
- **Counted honestly.** A flight that ends before its failure came is scored as
  exactly that, not as a clean flight; a reset in the air after the failure
  counts with the crashes. A flight that never got airborne is not scored.

The draw comes from a seed: whether, then when, then what, in that order, so the
same flight can be flown again - the same failure at the same moment - until it
is flown well. A glider is never given a dead stick it cannot have, and an
aircraft without a rudder never has one jam. Radio failures are opt-in.

## Why it crashed

After a crash the simulator reads the last five seconds of the flight recorder
and says, in one line, what happened and what to do differently
(`RCPhysics/Training/CrashAnalysis.h`). The rules are ordered and the first that
fits wins: a failure first - a model that lost its motor and stalled on the way
down crashed because of the motor - then a tree, then a crash that happened on
the ground (a wingtip, a nose-over), then spin, tip stall and stall, then a
hard landing, a spiral or dive, and finally flying into the ground with the wings
level.

The regression suite holds each aircraft to its character: the same
mishandling - full up elevator and full rudder from 25 m - spirals the trainer
without stalling it, snaps the warbird into a spin, stalls the glider straight
ahead and drops a wing on the sport aerobat. A flight model change that erases
those differences fails the build.

## Random failures

Off by default: a lesson decides when things break, and an unasked-for failure
in the middle of a circuit exercise is noise rather than training.

When armed, they arrive as a Poisson process rather than on a countdown — a
failure that arrives on a timer is one a pilot learns the rhythm of and stops
being surprised by. Weighted towards what actually happens, which on an electric
model is overwhelmingly the dead stick.
