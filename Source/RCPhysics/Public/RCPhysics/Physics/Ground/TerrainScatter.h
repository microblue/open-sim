// OpenRC Simulator - what grows where.
//
// The streamed terrain is a shaded surface and nothing else. From a thousand
// feet that is fine; flown low over it, it is a coloured sheet, and low is where
// an RC model spends its life.
//
// This decides what stands on the ground at a point: grass, scrub, trees,
// boulders, driftwood. It is a pure function of position and seed, the same way
// the height is, so the same tree is in the same place every time the cell
// containing it is rebuilt - a detail that moves when you turn around is worse
// than no detail at all.
//
// It lives beside TerrainField rather than in the renderer for the same reason
// that does: what grows there depends on the biome, and the biome is decided
// here. It is also where the rejection tests belong - nothing grows in the sea,
// on a cliff, or on the flying field.

#ifndef RCPHYSICS_PHYSICS_GROUND_TERRAINSCATTER_H
#define RCPHYSICS_PHYSICS_GROUND_TERRAINSCATTER_H

#include "RCPhysics/Physics/Ground/TerrainField.h"

#include <cstdint>
#include <vector>

namespace rc
{
    /** What kind of thing is standing there. The renderer keeps one mesh per
     *  kind and one instance buffer per kind per cell. */
    enum class ScatterKind
    {
        None,
        Grass,       ///< tufts, the ground cover that carries the near field
        Shrub,       ///< low bushes and heather
        Conifer,
        Broadleaf,
        DeadTree,    ///< bare trunks, at the tree line and in the desert
        Boulder,
        Reed,        ///< at the water's edge
        Count
    };

    struct ScatterPoint
    {
        Real  North = 0.0;
        Real  East  = 0.0;
        Real  Height = 0.0;      ///< metres above sea level
        Real  Yaw = 0.0;         ///< rad
        Real  Scale = 1.0;
        Real  Tint = 0.5;        ///< 0..1, so no two of a kind are identical
        Vec3  Normal = Vec3(0, 0, -1);
        ScatterKind Kind = ScatterKind::None;
    };

    /** Which layer of the scatter to place.
     *
     *  Ground cover and canopy need densities an order of magnitude apart - a
     *  field wants a tuft every few metres, a wood wants a tree every twenty -
     *  and driving both from one stream of candidates means the near detail
     *  cannot be raised without turning every wood into a thicket. */
    enum class ScatterLayer
    {
        GroundCover,   ///< grass, scrub, reeds
        Canopy         ///< trees, dead trunks, boulders
    };

    struct ScatterSettings
    {
        /** Nothing grows on ground steeper than this. */
        Real MaxSlope = 0.72;

        /** Nor within this of the flying field, which is mown [m]. */
        Real FieldClearance = 420.0;

        /** Height above sea level below which only reeds and driftwood
         *  appear [m], measured from the water line. */
        Real ShoreBand = 3.0;
    };

    class TerrainScatter
    {
    public:
        TerrainScatter(const TerrainField& field,
                       const ScatterSettings& settings = ScatterSettings{})
            : Field(&field), Config(settings) {}

        /** Fill one square cell with `count` candidate points and decide what,
         *  if anything, stands at each. Rejected candidates come back as
         *  ScatterKind::None rather than being removed, so the caller can size
         *  its buffers up front.
         *
         *  `jitterSeed` is mixed with the cell's own coordinates, so a cell is
         *  identical every time it is generated and neighbouring cells do not
         *  repeat. */
        void Fill(Real centreNorth, Real centreEast, Real size, int count,
                  std::uint32_t jitterSeed, ScatterLayer layer,
                  std::vector<ScatterPoint>& out) const;

    private:
        const TerrainField*  Field;
        ScatterSettings      Config;
    };
}

#endif
