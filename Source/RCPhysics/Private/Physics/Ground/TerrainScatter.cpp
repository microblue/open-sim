#include "RCPhysics/Physics/Ground/TerrainScatter.h"

#include <cmath>

namespace rc
{
    namespace
    {
        inline std::uint32_t Mix(std::uint32_t h)
        {
            h ^= h >> 16; h *= 0x7feb352du;
            h ^= h >> 15; h *= 0x846ca68bu;
            h ^= h >> 16;
            return h;
        }

        inline std::uint32_t HashCell(std::int32_t x, std::int32_t y,
                                      std::uint32_t seed, std::uint32_t salt)
        {
            return Mix(static_cast<std::uint32_t>(x) * 0x9e3779b9u
                     ^ static_cast<std::uint32_t>(y) * 0x85ebca6bu
                     ^ seed ^ (salt * 0xc2b2ae35u));
        }

        /** Uniform 0..1 from a hash, advanced by a counter so one cell hash can
         *  drive many independent draws. */
        inline Real Random01(std::uint32_t base, std::uint32_t index)
        {
            return static_cast<Real>(Mix(base + index * 0x9e3779b9u) >> 8)
                 / static_cast<Real>(0x00FFFFFFu + 1u);
        }
    }

    void TerrainScatter::Fill(Real centreNorth, Real centreEast, Real size,
                              int count, std::uint32_t jitterSeed,
                              ScatterLayer layer,
                              std::vector<ScatterPoint>& out) const
    {
        out.clear();
        if (count <= 0 || size <= 0) { return; }
        out.reserve(static_cast<size_t>(count));

        // The cell's own identity, so its contents never depend on when or from
        // where it was generated.
        const auto cellX = static_cast<std::int32_t>(std::floor(centreNorth / size));
        const auto cellY = static_cast<std::int32_t>(std::floor(centreEast / size));
        // The layer is part of the cell's identity, so ground cover and canopy
        // are independent draws rather than the same points twice.
        const std::uint32_t cellHash =
            HashCell(cellX, cellY, jitterSeed,
                     (layer == ScatterLayer::GroundCover) ? 1u : 2u);

        const Real half = size * Real(0.5);

        for (int i = 0; i < count; ++i)
        {
            const auto index = static_cast<std::uint32_t>(i) * 8u;
            ScatterPoint point;

            point.North = centreNorth - half + Random01(cellHash, index + 0u) * size;
            point.East  = centreEast  - half + Random01(cellHash, index + 1u) * size;

            const TerrainSample sample = Field->SampleAt(point.North, point.East);
            point.Height = sample.Height;
            point.Normal = sample.Normal;

            // --- what cannot be here ------------------------------------
            const Real fieldDistance = std::sqrt(point.North * point.North
                                               + point.East * point.East);
            // The flying field is mown, and its own grass and treeline are
            // placed by hand where the pilot can learn them. Beyond the mown
            // area the scatter thins back in rather than switching on, so the
            // field has an edge like a real one instead of a stamped circle.
            if (fieldDistance < Config.FieldClearance + Config.FieldFeather)
            {
                const Real reach = (fieldDistance - Config.FieldClearance)
                                 / std::max(Config.FieldFeather, Real(1));
                const Real chance = std::min(std::max(reach, Real(0)), Real(1));
                // Linear. Squaring it held the density down for most of the
                // feather and produced a BIGGER bare circle than the hard cut
                // it replaced - the edge has to recover quickly or it is not an
                // edge, it is a bigger clearing.
                if (Random01(cellHash, index + 7u) > chance)
                {
                    out.push_back(point);
                    continue;
                }
            }
            if (sample.Type == Biome::Ocean || sample.Slope > Config.MaxSlope)
            {
                out.push_back(point);
                continue;
            }

            const Real aboveWater = sample.Height - Field->Settings().SeaLevel;

            // --- what is ------------------------------------------------
            const Real roll = Random01(cellHash, index + 2u);

            if (layer == ScatterLayer::GroundCover)
            {
                if (aboveWater < Config.ShoreBand)
                {
                    point.Kind = (roll < Real(0.90)) ? ScatterKind::Reed
                                                     : ScatterKind::None;
                }
                else
                {
                    switch (sample.Type)
                    {
                        case Biome::Forest:
                            // Understorey: sparser than open pasture, because
                            // less light reaches it.
                            point.Kind = (roll < Real(0.42)) ? ScatterKind::Grass
                                       : (roll < Real(0.66)) ? ScatterKind::Shrub
                                                             : ScatterKind::None;
                            break;
                        case Biome::Grassland:
                            point.Kind = (roll < Real(0.86)) ? ScatterKind::Grass
                                       : (roll < Real(0.96)) ? ScatterKind::Shrub
                                                             : ScatterKind::None;
                            break;
                        case Biome::Desert:
                            point.Kind = (roll < Real(0.09)) ? ScatterKind::Shrub
                                                             : ScatterKind::None;
                            break;
                        case Biome::Beach:
                            point.Kind = (roll < Real(0.06)) ? ScatterKind::Reed
                                                             : ScatterKind::None;
                            break;
                        case Biome::Rock:
                            point.Kind = (roll < Real(0.11)) ? ScatterKind::Shrub
                                                             : ScatterKind::None;
                            break;
                        default:
                            point.Kind = ScatterKind::None;
                            break;
                    }
                }
            }
            else if (aboveWater < Config.ShoreBand)
            {
                point.Kind = (roll < Real(0.06)) ? ScatterKind::DeadTree
                           : (roll < Real(0.12)) ? ScatterKind::Boulder
                                                 : ScatterKind::None;
            }
            else
            {
                switch (sample.Type)
                {
                    case Biome::Forest:
                        point.Kind = (roll < Real(0.44)) ? ScatterKind::Conifer
                                   : (roll < Real(0.72)) ? ScatterKind::Broadleaf
                                   : (roll < Real(0.78)) ? ScatterKind::DeadTree
                                                         : ScatterKind::None;
                        break;

                    case Biome::Grassland:
                        // Trees standing alone or in small groups, the way they
                        // do in pasture - not a canopy.
                        point.Kind = (roll < Real(0.05)) ? ScatterKind::Broadleaf
                                   : (roll < Real(0.08)) ? ScatterKind::Conifer
                                   : (roll < Real(0.10)) ? ScatterKind::Boulder
                                                         : ScatterKind::None;
                        break;

                    case Biome::Desert:
                        point.Kind = (roll < Real(0.05)) ? ScatterKind::Boulder
                                   : (roll < Real(0.07)) ? ScatterKind::DeadTree
                                                         : ScatterKind::None;
                        break;

                    case Biome::Beach:
                        point.Kind = (roll < Real(0.04)) ? ScatterKind::DeadTree
                                                         : ScatterKind::None;
                        break;

                    case Biome::Rock:
                        point.Kind = (roll < Real(0.28)) ? ScatterKind::Boulder
                                                         : ScatterKind::None;
                        break;

                    case Biome::Snow:
                        point.Kind = (roll < Real(0.09)) ? ScatterKind::Boulder
                                                         : ScatterKind::None;
                        break;

                    default:
                        point.Kind = ScatterKind::None;
                        break;
                }
            }

            // Trees thin out towards the tree line rather than stopping at it.
            if (point.Kind == ScatterKind::Conifer || point.Kind == ScatterKind::Broadleaf)
            {
                const Real treeLine = Field->Settings().SnowLine - Real(320);
                if (sample.Height > treeLine)
                {
                    const Real above = (sample.Height - treeLine) / Real(320);
                    if (Random01(cellHash, index + 3u) < above)
                    {
                        point.Kind = (Random01(cellHash, index + 4u) < Real(0.4))
                                   ? ScatterKind::DeadTree : ScatterKind::None;
                    }
                }
                // And they do not grow on ground too steep to root in, even
                // where scrub still will.
                if (sample.Slope > Real(0.52)) { point.Kind = ScatterKind::Shrub; }
            }

            point.Yaw   = Random01(cellHash, index + 5u) * Real(6.28318530718);
            point.Scale = Real(0.66) + Random01(cellHash, index + 6u) * Real(0.82);
            point.Tint  = Random01(cellHash, index + 7u);

            out.push_back(point);
        }
    }
}
