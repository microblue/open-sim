#include "RCPhysics/Physics/Ground/TerrainField.h"

#include <algorithm>
#include <cmath>

namespace rc
{
    namespace
    {
        // ---------------------------------------------------------- noise --
        //
        // Gradient noise, hashed rather than table-driven so it is stateless
        // and identical everywhere it is evaluated - which is the property the
        // whole design rests on: the renderer and the collision surface must
        // agree exactly, and they only do that if the function is pure.

        inline std::uint32_t Hash(std::uint32_t x, std::uint32_t y, std::uint32_t seed)
        {
            std::uint32_t h = seed + x * 374761393u + y * 668265263u;
            h = (h ^ (h >> 13)) * 1274126177u;
            return h ^ (h >> 16);
        }

        inline Real Gradient(std::uint32_t hash, Real x, Real y)
        {
            // Eight directions, which is plenty at these scales and avoids a
            // trig call per corner.
            switch (hash & 7u)
            {
                case 0: return  x + y;
                case 1: return  x - y;
                case 2: return -x + y;
                case 3: return -x - y;
                case 4: return  x;
                case 5: return -x;
                case 6: return  y;
                default: return -y;
            }
        }

        inline Real Fade(Real t)
        {
            // Quintic: the cubic smoothstep leaves second-derivative creases
            // that show up as faint grid lines across a hillside.
            return t * t * t * (t * (t * Real(6) - Real(15)) + Real(10));
        }

        Real PerlinNoise(Real x, Real y, std::uint32_t seed)
        {
            const Real fx = std::floor(x);
            const Real fy = std::floor(y);
            const auto ix = static_cast<std::uint32_t>(static_cast<std::int64_t>(fx));
            const auto iy = static_cast<std::uint32_t>(static_cast<std::int64_t>(fy));

            const Real tx = x - fx;
            const Real ty = y - fy;
            const Real u = Fade(tx);
            const Real v = Fade(ty);

            const Real n00 = Gradient(Hash(ix,      iy,      seed), tx,           ty);
            const Real n10 = Gradient(Hash(ix + 1u, iy,      seed), tx - Real(1), ty);
            const Real n01 = Gradient(Hash(ix,      iy + 1u, seed), tx,           ty - Real(1));
            const Real n11 = Gradient(Hash(ix + 1u, iy + 1u, seed), tx - Real(1), ty - Real(1));

            const Real a = n00 + u * (n10 - n00);
            const Real b = n01 + u * (n11 - n01);
            return a + v * (b - a);
        }

        /** Fractal Brownian motion: octaves of noise at doubling frequency. */
        Real Fbm(Real x, Real y, int octaves, std::uint32_t seed,
                 Real lacunarity = Real(2.03), Real gain = Real(0.5))
        {
            Real total = 0;
            Real amplitude = 1;
            Real normalisation = 0;
            for (int i = 0; i < octaves; ++i)
            {
                total += PerlinNoise(x, y, seed + static_cast<std::uint32_t>(i) * 7919u) * amplitude;
                normalisation += amplitude;
                x *= lacunarity;
                y *= lacunarity;
                amplitude *= gain;
            }
            return (normalisation > 0) ? total / normalisation : Real(0);
        }

        /** Ridged multifractal: what makes mountains look like mountains rather
         *  than dunes. Each octave is folded about zero and inverted, so the
         *  zero crossings of the noise become sharp ridge lines. */
        Real Ridged(Real x, Real y, int octaves, std::uint32_t seed)
        {
            Real total = 0;
            Real amplitude = Real(0.5);
            Real normalisation = 0;
            Real weight = 1;

            for (int i = 0; i < octaves; ++i)
            {
                Real signal = PerlinNoise(x, y, seed + static_cast<std::uint32_t>(i) * 6151u);
                signal = Real(1) - std::fabs(signal) * Real(2);
                signal = signal * signal;
                // Each octave is attenuated where the one above it was low, so
                // detail collects on the ridges instead of everywhere.
                signal *= weight;
                weight = std::min(std::max(signal * Real(2), Real(0)), Real(1));

                total += signal * amplitude;
                normalisation += amplitude;
                x *= Real(2.07);
                y *= Real(2.07);
                amplitude *= Real(0.5);
            }
            return (normalisation > 0) ? total / normalisation : Real(0);
        }

        inline Real Smoothstep(Real edge0, Real edge1, Real value)
        {
            if (edge1 <= edge0) { return value < edge0 ? Real(0) : Real(1); }
            const Real t = std::min(std::max((value - edge0) / (edge1 - edge0), Real(0)), Real(1));
            return t * t * (Real(3) - Real(2) * t);
        }
    }

    // ------------------------------------------------------------- field --

    TerrainField::TerrainField(const TerrainSettings& settings) : Config(settings) {}

    void TerrainField::SetSettings(const TerrainSettings& settings) { Config = settings; }

    Real TerrainField::PlateauWeight(Real north, Real east) const
    {
        // 1 on the flying field, falling to 0 by the end of the blend. The
        // strip has to stay flat: the landing gear model, the ground handling
        // and every locked performance target were measured on level ground.
        const Real distance = std::sqrt(north * north + east * east);
        return Real(1) - Smoothstep(Config.PlateauRadius,
                                    Config.PlateauRadius + Config.PlateauBlend,
                                    distance);
    }

    Real TerrainField::BaseHeight(Real north, Real east) const
    {
        const Real scale = Real(1) / Config.ContinentScale;
        const Real x = north * scale;
        const Real y = east * scale;

        // Domain warp. Sampling the noise at a position that has itself been
        // displaced by noise is what turns concentric blobs into coastlines and
        // valleys that bend.
        const Real warpX = Fbm(x + Real(5.2), y + Real(1.3), 4, Config.Seed + 101u);
        const Real warpY = Fbm(x + Real(9.7), y + Real(7.1), 4, Config.Seed + 227u);
        const Real wx = x + warpX * Real(0.42);
        const Real wy = y + warpY * Real(0.42);

        // Continents: broad, slow, and centred so that roughly a third of the
        // world is below the water line.
        const Real continent = Fbm(wx, wy, 5, Config.Seed);

        // Where mountains are allowed to be at all. Without this mask the
        // ridged term covers the whole world evenly and there is nowhere flat.
        const Real orography = Smoothstep(Real(-0.05), Real(0.45),
                                          Fbm(wx * Real(0.62), wy * Real(0.62), 3,
                                              Config.Seed + 613u));

        const Real ridges = Ridged(wx * Real(2.4), wy * Real(2.4), 6, Config.Seed + 977u);

        // Mid-scale roll and fine detail, so a hillside is not smooth at every
        // distance.
        const Real hills  = Fbm(wx * Real(7.5),  wy * Real(7.5),  4, Config.Seed + 1451u);
        const Real detail = Fbm(wx * Real(31.0), wy * Real(31.0), 3, Config.Seed + 2777u);

        Real height = continent * Config.MountainHeight * Real(0.42);
        height += ridges * orography * Config.MountainHeight;
        height += hills * Real(52);
        height += detail * Real(9);

        return height;
    }

    Real TerrainField::HeightAt(Real north, Real east) const
    {
        const Real terrain = BaseHeight(north, east);
        const Real weight = PlateauWeight(north, east);
        // Blend towards the field elevation rather than replacing it, so the
        // plateau sits in the landscape instead of on top of it.
        return terrain + (Config.FieldElevation - terrain) * weight;
    }

    Real TerrainField::MoistureAt(Real north, Real east) const
    {
        const Real scale = Real(1) / (Config.ContinentScale * Real(0.55));
        const Real raw = Fbm(north * scale + Real(31.7), east * scale - Real(11.9),
                             4, Config.Seed + 3313u);
        return std::min(std::max(raw * Real(0.5) + Real(0.5), Real(0)), Real(1));
    }

    bool TerrainField::IsWater(Real north, Real east) const
    {
        return HeightAt(north, east) < Config.SeaLevel;
    }

    TerrainSample TerrainField::SampleAt(Real north, Real east) const
    {
        TerrainSample sample;
        sample.Height = HeightAt(north, east);

        // Central differences. The step is large enough that fine detail does
        // not make the normal noisy and small enough to follow a hillside.
        const Real step = Real(2.5);
        const Real hN = HeightAt(north + step, east);
        const Real hS = HeightAt(north - step, east);
        const Real hE = HeightAt(north, east + step);
        const Real hW = HeightAt(north, east - step);

        const Real dhdN = (hN - hS) / (Real(2) * step);
        const Real dhdE = (hE - hW) / (Real(2) * step);

        // World is NED: +z is DOWN, and height is measured up, so the upward
        // normal has a negative z.
        Vec3 normal(-dhdN, -dhdE, Real(-1));
        normal = normal.Normalized();
        sample.Normal = normal;

        const Real gradient = std::sqrt(dhdN * dhdN + dhdE * dhdE);
        sample.Slope = std::min(gradient, Real(1));
        sample.Moisture = MoistureAt(north, east);

        // --- which biome -------------------------------------------------
        const Real height = sample.Height;
        const Real moisture = sample.Moisture;

        if (height < Config.SeaLevel)
        {
            sample.Type = Biome::Ocean;
            sample.Blend = Smoothstep(Real(0), Real(-25), height - Config.SeaLevel);
        }
        else if (height < Config.SeaLevel + Config.BeachHeight && sample.Slope < Real(0.35))
        {
            sample.Type = Biome::Beach;
            sample.Blend = Real(1) - Smoothstep(Config.SeaLevel + Config.BeachHeight * Real(0.5),
                                                Config.SeaLevel + Config.BeachHeight, height);
        }
        else if (height > Config.SnowLine)
        {
            sample.Type = Biome::Snow;
            sample.Blend = Smoothstep(Config.SnowLine, Config.SnowLine + Real(180), height);
        }
        else if (sample.Slope > Real(0.55))
        {
            // Too steep to hold soil, whatever the climate.
            sample.Type = Biome::Rock;
            sample.Blend = Smoothstep(Real(0.55), Real(0.85), sample.Slope);
        }
        else if (moisture < Real(0.34))
        {
            sample.Type = Biome::Desert;
            sample.Blend = Real(1) - Smoothstep(Real(0.24), Real(0.34), moisture);
        }
        else if (moisture > Real(0.60))
        {
            sample.Type = Biome::Forest;
            sample.Blend = Smoothstep(Real(0.60), Real(0.74), moisture);
        }
        else
        {
            sample.Type = Biome::Grassland;
            sample.Blend = Real(1);
        }

        return sample;
    }

    // ------------------------------------------------------------ ground --

    GroundSample TerrainGround::Sample(Real north, Real east) const
    {
        const TerrainSample terrain = Field->SampleAt(north, east);

        GroundSample ground;
        // GroundSample carries world Z, which points DOWN, so a surface that is
        // 120 m above sea level is at z = -120.
        ground.SurfaceHeight = -terrain.Height;
        ground.Normal = terrain.Normal;

        switch (terrain.Type)
        {
            case Biome::Beach:
            case Biome::Desert:
                // Sand: soft, draggy, poor grip.
                ground.FrictionScale = 0.72;
                ground.RollingScale  = 2.30;
                break;
            case Biome::Rock:
                ground.FrictionScale = 1.05;
                ground.RollingScale  = 1.40;
                break;
            case Biome::Snow:
                ground.FrictionScale = 0.45;
                ground.RollingScale  = 1.90;
                break;
            case Biome::Forest:
                ground.FrictionScale = 0.95;
                ground.RollingScale  = 1.60;
                break;
            case Biome::Ocean:
                // Water is not a runway. High drag, no grip worth the name -
                // enough that an aircraft that touches it stops, which is what
                // happens.
                ground.FrictionScale = 0.10;
                ground.RollingScale  = 8.00;
                break;
            default:
                break;
        }

        return ground;
    }
}
