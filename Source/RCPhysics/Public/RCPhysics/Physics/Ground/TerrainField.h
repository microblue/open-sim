// OpenRC Simulator - the world's shape, as a function.
//
// The field used to be a flat plane 520 m across with a ring of trees around
// it, and past that nothing: fly out and the world was a small square below you.
// This replaces it with a height function that can be evaluated anywhere, so
// the terrain is generated as you reach it and there is no edge to find.
//
// It lives in the physics core, not the renderer, for one reason: the ground the
// aircraft collides with and the ground the pilot sees have to be the same
// surface. Two implementations of "how high is the ground here" drift, and the
// symptom is flying through a mountain. There is one implementation, it is
// deterministic from a seed, and both sides call it.
//
// The flying field itself is preserved: the terrain is smoothly flattened to a
// plateau around the origin, so the strip is level, the landing gear model still
// makes sense, and the validation targets that were measured on flat ground
// remain valid.

#ifndef RCPHYSICS_PHYSICS_GROUND_TERRAINFIELD_H
#define RCPHYSICS_PHYSICS_GROUND_TERRAINFIELD_H

#include "RCPhysics/Core/Types.h"
#include "RCPhysics/Core/Math/Vec3.h"
#include "RCPhysics/Physics/Ground/LandingGear.h"

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace rc
{
    /** What the ground is made of at a point. Drives both what it looks like and
     *  how it behaves underfoot. */
    enum class Biome
    {
        Ocean,
        Beach,
        Desert,
        Grassland,
        Forest,
        Rock,
        Snow,
        Count
    };

    struct TerrainSettings
    {
        std::uint32_t Seed = 20260823u;

        /** Height of the flying field [m]. Zero, deliberately: the strip is the
         *  origin of everything else. The landing gear, the spawn points, the
         *  pilot's eye height and every locked performance target were measured
         *  with the ground at zero, and moving the field up would have meant
         *  moving all of them - so the water goes down instead. */
        Real FieldElevation = 0.0;

        /** Radius of the flat plateau the strip sits on [m], and the distance
         *  over which it blends into the surrounding terrain. Generous: a
         *  trainer circuit is a couple of hundred metres across, and terrain
         *  rising inside that would change what the validation suite measured. */
        Real PlateauRadius = 430.0;
        /** Long. At 520 m the flat disc met rising ground over a distance the
         *  eye reads as an edge, and from any height the field was a circle
         *  stamped into the landscape. A kilometre and a half of blend puts the
         *  strip in a valley floor instead of on a plate. */
        Real PlateauBlend  = 1500.0;

        /** Vertical scale of the mountains [m]. */
        Real MountainHeight = 2100.0;

        /** Horizontal scale of the continent-sized features [m]. */
        /** Horizontal scale of the continent-sized features [m]. Small enough
         *  that a coastline and a mountain range are both within sight of the
         *  strip - a world at true geographic scale is realistic and, from a
         *  flying field, indistinguishable from a flat plain. */
        Real ContinentScale = 7200.0;

        /** Sea level [m]. Below this is water. */
        /** Sea level, below the field. The strip sits on a plateau a hundred
         *  metres or so above the water, which is where a flying field usually
         *  is and puts a coastline within sight of a circuit. */
        Real SeaLevel = -135.0;

        /** Snow line [m]. */
        Real SnowLine = 1250.0;

        /** Shifts the whole world wetter or drier, -1 to 1. This is what makes
         *  one preset a forested valley and another a desert: the biome rules
         *  are unchanged, the climate they read is not. */
        Real MoistureBias = 0.0;

        /** Multiplies the ridged term only, leaving the continents alone. Above
         *  one the mountains become spires rather than hills. */
        Real Ruggedness = 1.0;

        /** Where sand gives way to grass above the water line [m]. */
        /** Narrow: a fourteen-metre band over gentle ground put a white rim
         *  around every lake and inlet in the world. */
        Real BeachHeight = 5.0;
    };

    struct TerrainSample
    {
        Real  Height = 0.0;              ///< metres above sea level
        Vec3  Normal = Vec3(0, 0, -1);   ///< world NED, pointing up out of the ground
        Biome Type   = Biome::Grassland;

        /** 0 at the edge of a biome, 1 well inside it. Lets the renderer blend
         *  rather than showing a hard line between sand and grass. */
        Real Blend = 1.0;

        /** How wet it is, 0..1. Decides desert from forest at the same height. */
        Real Moisture = 0.5;

        /** Steepness, 0 flat to 1 cliff. */
        Real Slope = 0.0;
    };

    class TerrainField
    {
    public:
        explicit TerrainField(const TerrainSettings& settings = TerrainSettings{});

        void SetSettings(const TerrainSettings& settings);
        const TerrainSettings& Settings() const { return Config; }

        /** Height of the surface [m above sea level] at a world position. Cheap
         *  enough to call per contact point every physics step. */
        Real HeightAt(Real north, Real east) const;

        /** Height plus everything derived from it. Costs four extra height
         *  evaluations for the normal, so use HeightAt when that is all you
         *  need. */
        TerrainSample SampleAt(Real north, Real east) const;

        /** True when the point is below sea level, i.e. in the water. */
        bool IsWater(Real north, Real east) const;

    private:
        TerrainSettings Config;

        Real BaseHeight(Real north, Real east) const;
        Real PlateauWeight(Real north, Real east) const;
        Real MoistureAt(Real north, Real east) const;
    };

    /** Ground provider backed by a TerrainField, so the aircraft collides with
     *  the terrain the pilot can see.
     *
     *  Trees are fed in as vertical cylinders and the ground height rises to
     *  meet them: a wing tip entering a trunk samples a surface that high, so
     *  the crash model calls it, and ground contact sets the wreck down on the
     *  canopy instead of letting it pass through. The obstacles are bucketed
     *  into a spatial grid, because a collision point can only ever be near a
     *  handful of them and the sample runs per contact point per physics step. */
    class TerrainGround : public GroundProvider
    {
    public:
        explicit TerrainGround(const TerrainField& field) : Field(&field) {}

        struct Obstacle
        {
            Real X = 0.0;        ///< north (world x)
            Real Y = 0.0;        ///< east (world y)
            Real Radius = 0.0;   ///< trunk/canopy radius [m]
            Real Height = 0.0;   ///< top of the tree above the terrain [m]
        };

        /** Replace the obstacle set. Rebuilds the spatial grid. */
        void SetObstacles(std::vector<Obstacle> obstacles);

        GroundSample Sample(Real north, Real east) const override;
        bool IsObstacle(Real north, Real east) const override;

        /** Extra surface height from an obstacle at this point, or 0. */
        Real ObstacleHeightAt(Real north, Real east) const;

    private:
        const TerrainField* Field;
        std::vector<Obstacle> Obstacles;
        /// Grid cells -> obstacle indices. Cell size is fixed; the grid itself
        /// is a hash so a huge world does not mean a huge table.
        std::unordered_map<std::int64_t, std::vector<int>> Grid;
        static constexpr Real GRID_CELL = 16.0;
        static constexpr int GRID_RADIUS = 2;   ///< cells to inspect around a point

        std::int64_t GridKey(Real north, Real east) const;
    };
}

#endif
