# Roadmap

The test for every item: does it make an hour in the simulator worth more to a
pilot with a real transmitter? Ordered by that, not by how impressive it is.

## V0.2 — what a pilot takes away from a flight

Done:

- **Crash analysis.** One line on what happened, one on what to do, from the
  flight recorder's last five seconds (`Training/CrashAnalysis`).
- **Failure practice.** One honest draw per flight, airborne-time onset,
  repeatable seed, hidden-notice mode (`Training/FailurePractice`).
- **Ground effect.** Per-section image-vortex model; tail downwash relief.
- **Flight log export.** `F10` writes the recorder as CSV.
- **Settings.** Volumes, window, units, stick mode (HUD and keyboard), practice.
- **Pilot aids.** Warning chips, pilot-view auto-zoom, vertical height cue,
  pause on focus loss, held-key masking.
- **CI.** The physics core and its suite on Linux (gcc, clang), macOS and
  Windows on every push.

Next, in order:

1. **Debrief after a practice flight.** The outcome tallies exist
   (`get_failure_practice()`); show them, with Repeat / New flight / Menu.
2. **Lessons.** Short exercises built on the same machinery: dead stick from
   the downwind leg, landing with the ailerons jammed, find the trim. Each ends
   with a descriptive outcome, not a score.
3. **Repeatable random conditions.** A seeded "fly somewhere new" that draws
   an aircraft, a place and weather from a few believable recipes (calm, a
   breeze, a lively afternoon, windy) and can be flown again from its seed.
4. **Landing grading.** Touchdown sink rate, distance from the threshold,
   centreline and float, from the recorder - the same data the crash card reads.
5. **Downwash lag.** The tail feels the wing's downwash a short time later
   (`l_tail / V`); that delay is most of the pitch damping a real model has.
6. **Audio.** Propagation delay on a flyby and air absorption with distance,
   so a model is heard where it was, not where it is.
7. **Time of day.** Sun position from date and place; dusk flying.
8. **Windows and macOS builds** of the game, not only the core.
9. **Units in the crash card.** Its sentences are metric whatever the HUD shows.
10. **A flyable aircraft workshop**: scale, weight, power and throw as
    multipliers on a stock aircraft, with physically consistent scaling.

Not planned: anything that does not make the time in the simulator transfer to
the field.
