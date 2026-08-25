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

## Random failures

Off by default: a lesson decides when things break, and an unasked-for failure
in the middle of a circuit exercise is noise rather than training.

When armed, they arrive as a Poisson process rather than on a countdown — a
failure that arrives on a timer is one a pilot learns the rhythm of and stops
being surprised by. Weighted towards what actually happens, which on an electric
model is overwhelmingly the dead stick.
