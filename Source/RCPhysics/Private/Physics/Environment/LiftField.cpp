#include "RCPhysics/Physics/Environment/LiftField.h"

#include <algorithm>
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

        inline std::uint32_t CellHash(std::int32_t x, std::int32_t y, std::uint32_t seed)
        {
            return Mix(static_cast<std::uint32_t>(x) * 0x9e3779b9u
                     ^ static_cast<std::uint32_t>(y) * 0x85ebca6bu
                     ^ seed);
        }

        inline Real Unit(std::uint32_t base, std::uint32_t index)
        {
            return static_cast<Real>(Mix(base + index * 0x9e3779b9u) >> 8)
                 / static_cast<Real>(0x01000000u);
        }

        inline Real Smoothstep(Real edge0, Real edge1, Real value)
        {
            if (edge1 <= edge0) { return value < edge0 ? Real(0) : Real(1); }
            const Real t = std::min(std::max((value - edge0) / (edge1 - edge0), Real(0)), Real(1));
            return t * t * (Real(3) - Real(2) * t);
        }
    }

    LiftField::LiftField(const TerrainField& terrain, const LiftSettings& settings)
        : Terrain(&terrain), Config(settings) {}

    void LiftField::SetSettings(const LiftSettings& settings) { Config = settings; }

    Real LiftField::GroundHeating(Real north, Real east) const
    {
        const TerrainSample ground = Terrain->SampleAt(north, east);
        switch (ground.Type)
        {
            case Biome::Desert:    return 1.00;   // bare sand in sun, the engine of the day
            case Biome::Beach:     return 0.85;
            case Biome::Rock:      return 0.90;
            case Biome::Grassland: return 0.62;
            case Biome::Forest:    return 0.30;   // damp and shaded
            case Biome::Snow:      return 0.10;   // reflects almost everything
            case Biome::Ocean:     return 0.00;   // water does not make thermals
            default:               return 0.45;
        }
    }

    Real LiftField::ThermalAt(const Vec3& positionWorld, Real time, const Vec3& wind,
                              LiftSample& out) const
    {
        const Real groundHeight = Terrain->HeightAt(positionWorld.x, positionWorld.y);
        const Real altitude = -positionWorld.z;                 // world z is DOWN
        const Real above = altitude - groundHeight;
        if (above < Real(0)) { return Real(0); }

        // Thermals drift downwind. Working in a frame that moves with the air
        // means a column keeps its identity as it goes, rather than the
        // aircraft flying through a series of unrelated ones.
        const Real driftNorth = wind.x * time;
        const Real driftEast  = wind.y * time;
        const Real fieldNorth = positionWorld.x - driftNorth;
        const Real fieldEast  = positionWorld.y - driftEast;

        const Real spacing = std::max(Config.ThermalSpacing, Real(50));
        const auto cellX = static_cast<std::int32_t>(std::floor(fieldNorth / spacing));
        const auto cellY = static_cast<std::int32_t>(std::floor(fieldEast / spacing));

        Real total = Real(0);

        // The nine cells around the point. A thermal near a boundary reaches
        // into its neighbours, and sampling only the containing cell would cut
        // every column into squares.
        for (std::int32_t dx = -1; dx <= 1; ++dx)
        {
            for (std::int32_t dy = -1; dy <= 1; ++dy)
            {
                const std::uint32_t hash = CellHash(cellX + dx, cellY + dy, Config.Seed);

                // Where in its cell, and where in its life.
                const Real centreNorth = (cellX + dx + Unit(hash, 1)) * spacing;
                const Real centreEast  = (cellY + dy + Unit(hash, 2)) * spacing;

                const Real dNorth = fieldNorth - centreNorth;
                const Real dEast  = fieldEast - centreEast;
                const Real distance = std::sqrt(dNorth * dNorth + dEast * dEast);

                const Real radius = Config.ThermalRadius * (Real(0.7) + Unit(hash, 3) * Real(0.8));
                if (distance > radius * Config.SinkRadius * Real(1.3)) { continue; }

                // Life cycle. Each has its own phase, so they are not all born
                // at once - a sky where every thermal starts together is a sky
                // that is either working or dead, and never either for long.
                const Real lifetime = Config.ThermalLifetime
                                    * (Real(0.6) + Unit(hash, 4) * Real(0.9));
                const Real phase = std::fmod(time / lifetime + Unit(hash, 5), Real(1));
                // Builds over the first fifth, works, dies over the last third.
                const Real maturity = Smoothstep(Real(0.0), Real(0.20), phase)
                                    * (Real(1) - Smoothstep(Real(0.66), Real(1.0), phase));

                // The ground under the column decides how strong it can be, and
                // it is sampled where the thermal is rooted rather than where
                // the aircraft happens to be.
                const Real heating = GroundHeating(centreNorth + driftNorth,
                                                   centreEast + driftEast);
                if (heating <= Real(0.02)) { continue; }

                // Height profile: weak at the ground where it is still
                // organising, strongest in the middle, gone at the top.
                const Real height = above / std::max(Config.ThermalTop, Real(50));
                if (height > Real(1)) { continue; }
                const Real profile = Smoothstep(Real(0), Real(0.12), height)
                                   * (Real(1) - Smoothstep(Real(0.75), Real(1.0), height));

                const Real peak = Config.ThermalStrength * heating * maturity * profile
                                * (Real(0.7) + Unit(hash, 6) * Real(0.7));
                if (peak <= Real(0)) { continue; }

                // Core, then the sink that balances it. A bell for the lift and
                // a ring for the sink: fly through the middle and you go up,
                // clip the edge and you go down, which is the whole game.
                const Real r = distance / radius;
                const Real core = peak * std::exp(-r * r * Real(1.4));
                const Real ringCentre = Config.SinkRadius;
                const Real ringWidth = Config.SinkRadius * Real(0.55);
                const Real ring = peak * Config.SinkFraction
                                * std::exp(-std::pow((r - ringCentre) / ringWidth, Real(2)));

                total += core - ring;

                if (distance < out.NearestThermalDistance)
                {
                    out.NearestThermalDistance = distance;
                    out.NearestThermalStrength = peak;
                }
            }
        }

        return total;
    }

    Real LiftField::SlopeAt(const Vec3& positionWorld, const Vec3& wind) const
    {
        const Real windSpeed = std::sqrt(wind.x * wind.x + wind.y * wind.y);
        if (windSpeed < Real(0.5)) { return Real(0); }

        const TerrainSample ground = Terrain->SampleAt(positionWorld.x, positionWorld.y);
        const Real above = -positionWorld.z - ground.Height;
        if (above < Real(0)) { return Real(0); }

        // The surface normal, in the horizontal plane, points down the hill.
        // Wind blowing against that is wind being forced up it.
        //
        // The normal is NED with z up-negative, so its horizontal part already
        // points downslope; the dot product with the wind is positive on a lee
        // face and negative on a windward one.
        const Real downslopeDotWind = ground.Normal.x * wind.x + ground.Normal.y * wind.y;
        const Real gradient = std::sqrt(ground.Normal.x * ground.Normal.x
                                      + ground.Normal.y * ground.Normal.y);
        if (gradient < Real(1e-4)) { return Real(0); }

        // Positive into the hill, negative into the lee.
        const Real facing = -downslopeDotWind;

        // Decays with height above the ground: slope lift is a skin over the
        // hillside, not a column.
        const Real decay = std::exp(-above / std::max(Config.SlopeDecay, Real(5)));

        Real lift = facing * Config.SlopeScale * decay;
        if (lift < Real(0))
        {
            // The lee. Rotor and sink behind a ridge is how models are lost,
            // and it is worth being able to learn it somewhere safe.
            lift *= Config.LeeSinkFraction;
        }
        return lift;
    }

    LiftSample LiftField::SampleAt(const Vec3& positionWorld, Real time, const Vec3& wind) const
    {
        LiftSample sample;
        if (!Config.Enabled) { return sample; }

        sample.Thermal = ThermalAt(positionWorld, time, wind, sample);
        sample.Slope = SlopeAt(positionWorld, wind);
        return sample;
    }

    Vec3 LiftField::VelocityAt(const Vec3& positionWorld, Real time, const Vec3& wind) const
    {
        const LiftSample sample = SampleAt(positionWorld, time, wind);
        // World is NED: rising air is negative z.
        return Vec3(Real(0), Real(0), -sample.Total());
    }
}
