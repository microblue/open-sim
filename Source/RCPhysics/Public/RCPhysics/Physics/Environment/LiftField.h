// OpenRC Simulator - the air that goes up.
//
// A wind field says which way the air is moving. It says nothing about why some
// of it is rising, and rising air is what a glider is FOR. We shipped a
// thirteen-to-one thermal glider into a world with no thermals in it.
//
// Two sources, both real and both flyable:
//
//   Thermals    Columns of rising air over ground that has warmed. They drift
//               downwind, they have a life - they build, they work, they die -
//               and each is surrounded by the sink that has to balance it. A
//               pilot finds one by the way the model lifts a wing, centres in
//               it by turning towards the lift, and loses it by flying out the
//               far side into the sink.
//
//   Slope lift  Wind pushed up a hillside. Steady, predictable and tied to a
//               place, which is why slope soaring is a different sport from
//               thermalling. It exists only where the wind has a hill to climb
//               and dies away above the ridge.
//
// Both are pure functions of position, time and seed, like everything else that
// shapes this world - so a thermal is in the same place for two pilots flying
// the same field, and a session can be reproduced.
//
// Downwind of a ridge the same calculation gives sink, which is not a bonus
// feature: flying into the lee of a hill and finding the air going down is one
// of the ways models are lost, and it should be possible to learn it here.

#ifndef RCPHYSICS_PHYSICS_ENVIRONMENT_LIFTFIELD_H
#define RCPHYSICS_PHYSICS_ENVIRONMENT_LIFTFIELD_H

#include "RCPhysics/Core/Math/Vec3.h"
#include "RCPhysics/Core/Types.h"
#include "RCPhysics/Physics/Ground/TerrainField.h"

#include <cstdint>

namespace rc
{
    struct LiftSettings
    {
        std::uint32_t Seed = 0x74E33Au;

        // --- thermals ----------------------------------------------------
        /** Peak vertical speed in the core of a fully developed thermal over
         *  ideal ground [m/s]. A good day on a dry field. */
        Real ThermalStrength = 3.2;

        /** Radius of the working core [m]. Model-sized thermals are small; a
         *  fifty metre core is a couple of turns of a trainer. */
        Real ThermalRadius = 60.0;

        /** Mean distance between thermals [m]. */
        Real ThermalSpacing = 620.0;

        /** Height above the ground at which a thermal stops working [m]. */
        Real ThermalTop = 800.0;

        /** How long one lives, birth to death [s]. */
        Real ThermalLifetime = 420.0;

        /** Sink around the column, as a fraction of the core's strength. The
         *  air a thermal lifts has to come down somewhere, and the ring of
         *  sink around it is what makes centring a skill rather than a
         *  formality. */
        Real SinkFraction = 0.32;

        /** Radius at which the surrounding sink is strongest, as a multiple of
         *  the core radius. */
        Real SinkRadius = 2.6;

        // --- slope lift --------------------------------------------------
        /** Fraction of the wind's upslope component that becomes lift. */
        Real SlopeScale = 0.80;

        /** Height above the ground over which slope lift decays [m]. */
        Real SlopeDecay = 110.0;

        /** Lee-side sink, as a fraction of the slope lift the same hill would
         *  make facing the other way. */
        Real LeeSinkFraction = 0.7;

        /** Master switch, so a lesson or a test can fly in still air. */
        bool Enabled = true;
    };

    /** What the air is doing at a point, split out so the HUD can show a pilot
     *  where the lift came from rather than only that it exists. */
    struct LiftSample
    {
        Real Thermal = 0.0;    ///< m/s, positive up
        Real Slope   = 0.0;    ///< m/s, positive up
        Real Total() const { return Thermal + Slope; }

        /** Distance to the centre of the nearest thermal [m], and how strong it
         *  is right now. Used by the variometer and by the training aids; a
         *  pilot never sees this directly. */
        Real NearestThermalDistance = 1e9;
        Real NearestThermalStrength = 0.0;
    };

    class LiftField
    {
    public:
        explicit LiftField(const TerrainField& terrain,
                           const LiftSettings& settings = LiftSettings{});

        void SetSettings(const LiftSettings& settings);
        const LiftSettings& Settings() const { return Config; }

        /** How strongly the ground here makes thermals, 0 to 1. Bare rock and
         *  sand in sun are the engine of a soaring day; forest is damp and
         *  shaded, water makes none at all. */
        Real GroundHeating(Real north, Real east) const;

        /** Vertical air velocity at a world position, and where it came from.
         *  `time` is the simulation clock; `wind` is the mean wind, which the
         *  thermals drift on and the slopes are lifted by. */
        LiftSample SampleAt(const Vec3& positionWorld, Real time, const Vec3& wind) const;

        /** The same thing as a world velocity, ready to add to the wind.
         *  World is NED, so rising air is NEGATIVE z. */
        Vec3 VelocityAt(const Vec3& positionWorld, Real time, const Vec3& wind) const;

    private:
        const TerrainField* Terrain;
        LiftSettings        Config;

        Real ThermalAt(const Vec3& positionWorld, Real time, const Vec3& wind,
                       LiftSample& out) const;
        Real SlopeAt(const Vec3& positionWorld, const Vec3& wind) const;
    };
}

#endif
