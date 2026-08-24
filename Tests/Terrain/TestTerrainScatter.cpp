// OpenRC Simulator - what stands on the ground.
//
// The scatter has to be a pure function of position: a tree that moves when the
// cell containing it is rebuilt is worse than no tree, because the eye tracks
// exactly that. It also has to refuse to put things where they cannot be - in
// the sea, on a cliff, or on the mown flying field.

#include "RCPhysics/Physics/Ground/TerrainScatter.h"
#include "TestHarness.h"

#include <cmath>
#include <map>

namespace
{
    const rc::TerrainField& World()
    {
        static const rc::TerrainField field{rc::TerrainSettings{}};
        return field;
    }

}

RC_TEST(TerrainScatter, IsStableForACell)
{
    const rc::TerrainScatter scatter(World());
    std::vector<rc::ScatterPoint> a, b;

    scatter.Fill(4200.0, -3100.0, 64.0, 96, 7u, rc::ScatterLayer::Canopy, a);
    scatter.Fill(4200.0, -3100.0, 64.0, 96, 7u, rc::ScatterLayer::Canopy, b);

    RC_CHECK(a.size() == b.size());
    for (size_t i = 0; i < a.size(); ++i)
    {
        RC_CHECK_NEAR(a[i].North, b[i].North, 0.0);
        RC_CHECK_NEAR(a[i].East, b[i].East, 0.0);
        RC_CHECK_NEAR(a[i].Scale, b[i].Scale, 0.0);
        RC_CHECK(a[i].Kind == b[i].Kind);
    }
}

RC_TEST(TerrainScatter, NeighbouringCellsDoNotRepeat)
{
    // A tiling pattern is immediately visible from the air, and the cell hash
    // is the only thing preventing it.
    const rc::TerrainScatter scatter(World());
    std::vector<rc::ScatterPoint> a, b;

    scatter.Fill(4200.0, -3100.0, 64.0, 64, 7u, rc::ScatterLayer::Canopy, a);
    scatter.Fill(4200.0 + 64.0, -3100.0, 64.0, 64, 7u, rc::ScatterLayer::Canopy, b);

    int identical = 0;
    for (size_t i = 0; i < a.size() && i < b.size(); ++i)
    {
        // Compare the offset within each cell, not the absolute position.
        const rc::Real offsetA = a[i].North - 4200.0;
        const rc::Real offsetB = b[i].North - (4200.0 + 64.0);
        if (std::fabs(offsetA - offsetB) < 1e-9) { ++identical; }
    }
    RC_CHECK_MSG_VALUE(identical < 4, identical);
}

RC_TEST(TerrainScatter, PlacesEverythingOnTheSurface)
{
    const rc::TerrainScatter scatter(World());
    std::vector<rc::ScatterPoint> points;
    scatter.Fill(-6100.0, 2400.0, 128.0, 200, 11u, rc::ScatterLayer::Canopy, points);

    for (const rc::ScatterPoint& point : points)
    {
        if (point.Kind == rc::ScatterKind::None) { continue; }
        // The height it reports must be the height of the ground there, or
        // trees float and rocks are buried.
        RC_CHECK_NEAR(point.Height, World().HeightAt(point.North, point.East), 1e-9);
        RC_CHECK(point.Scale > 0.5 && point.Scale < 1.6);
    }
}

RC_TEST(TerrainScatter, NothingGrowsInTheSea)
{
    const rc::TerrainScatter scatter(World());
    std::vector<rc::ScatterPoint> points;

    int checked = 0;
    for (int cell = 0; cell < 400 && checked < 40; ++cell)
    {
        scatter.Fill(-30000.0 + cell * 150.0, -18000.0 + cell * 90.0, 96.0, 64, 3u, rc::ScatterLayer::Canopy, points);
        for (const rc::ScatterPoint& point : points)
        {
            if (World().IsWater(point.North, point.East))
            {
                ++checked;
                RC_CHECK(point.Kind == rc::ScatterKind::None);
            }
        }
    }
    RC_CHECK_MSG_VALUE(checked > 0, checked);
}

RC_TEST(TerrainScatter, TheFlyingFieldStaysClear)
{
    // The strip is mown and its treeline is placed by hand, where the pilot can
    // learn it. A tree appearing in the circuit would be a hazard the pilot had
    // no way to anticipate.
    const rc::TerrainScatter scatter(World());
    std::vector<rc::ScatterPoint> points;

    for (int cell = -3; cell <= 3; ++cell)
    {
        scatter.Fill(cell * 100.0, cell * 80.0, 100.0, 200, 5u, rc::ScatterLayer::Canopy, points);
        for (const rc::ScatterPoint& point : points)
        {
            const rc::Real distance = std::sqrt(point.North * point.North
                                              + point.East * point.East);
            if (distance < 420.0)
            {
                RC_CHECK(point.Kind == rc::ScatterKind::None);
            }
        }
    }
}

RC_TEST(TerrainScatter, NothingStandsOnACliff)
{
    const rc::TerrainScatter scatter(World());
    std::vector<rc::ScatterPoint> points;

    int steep = 0;
    for (int cell = 0; cell < 600 && steep < 30; ++cell)
    {
        scatter.Fill(9000.0 + cell * 70.0, 5000.0 - cell * 55.0, 80.0, 48, 13u, rc::ScatterLayer::Canopy, points);
        for (const rc::ScatterPoint& point : points)
        {
            if (World().SampleAt(point.North, point.East).Slope > 0.72)
            {
                ++steep;
                RC_CHECK(point.Kind == rc::ScatterKind::None);
            }
        }
    }
    RC_CHECK_MSG_VALUE(steep > 0, steep);
}

RC_TEST(TerrainScatter, GroundCoverAndCanopyAreIndependent)
{
    // Two layers, so a field can have a tuft every few metres without a wood
    // becoming a thicket. They must draw different points, or the split buys
    // nothing.
    const rc::TerrainScatter scatter(World());
    std::vector<rc::ScatterPoint> cover, canopy;

    scatter.Fill(3100.0, 2400.0, 96.0, 128, 23u, rc::ScatterLayer::GroundCover, cover);
    scatter.Fill(3100.0, 2400.0, 96.0, 128, 23u, rc::ScatterLayer::Canopy, canopy);

    int samePosition = 0;
    for (size_t i = 0; i < cover.size() && i < canopy.size(); ++i)
    {
        if (std::fabs(cover[i].North - canopy[i].North) < 1e-9) { ++samePosition; }
    }
    RC_CHECK_MSG_VALUE(samePosition < 4, samePosition);

    // And neither places the other's kinds.
    for (const rc::ScatterPoint& point : cover)
    {
        RC_CHECK(point.Kind != rc::ScatterKind::Conifer
              && point.Kind != rc::ScatterKind::Broadleaf);
    }
    for (const rc::ScatterPoint& point : canopy)
    {
        RC_CHECK(point.Kind != rc::ScatterKind::Grass);
    }
}


RC_TEST(TerrainScatter, GrasslandIsNotAForest)
{
    // Open pasture with trees standing alone, not a canopy. This is what went
    // wrong first time: a single density for both layers put a wood everywhere
    // the moisture allowed one.
    const rc::TerrainScatter scatter(World());
    std::vector<rc::ScatterPoint> canopy;

    int grasslandPoints = 0;
    int grasslandTrees = 0;
    for (int cell = 0; cell < 500; ++cell)
    {
        scatter.Fill(-14000.0 + cell * 61.0, 9000.0 - cell * 47.0, 96.0, 48, 29u,
                     rc::ScatterLayer::Canopy, canopy);
        for (const rc::ScatterPoint& point : canopy)
        {
            if (World().SampleAt(point.North, point.East).Type != rc::Biome::Grassland)
            {
                continue;
            }
            ++grasslandPoints;
            if (point.Kind == rc::ScatterKind::Conifer
                || point.Kind == rc::ScatterKind::Broadleaf)
            {
                ++grasslandTrees;
            }
        }
    }

    RC_CHECK(grasslandPoints > 0);
    const double rate = grasslandPoints > 0
        ? double(grasslandTrees) / double(grasslandPoints) : 0.0;
    RC_CHECK_MSG_VALUE(rate < 0.15, rate);
}


RC_TEST(TerrainScatter, BiomesGrowDifferentThings)
{
    // If every biome scattered the same mix, the world would be one landscape
    // painted several colours.
    const rc::TerrainScatter scatter(World());
    std::map<rc::Biome, int> trees;
    std::map<rc::Biome, int> total;

    std::vector<rc::ScatterPoint> points;
    for (int cell = 0; cell < 900; ++cell)
    {
        const rc::Real north = -24000.0 + cell * 53.0;
        const rc::Real east  =  16000.0 - cell * 41.0;
        scatter.Fill(north, east, 96.0, 40, 17u, rc::ScatterLayer::Canopy, points);
        for (const rc::ScatterPoint& point : points)
        {
            const rc::Biome biome = World().SampleAt(point.North, point.East).Type;
            total[biome] += 1;
            if (point.Kind == rc::ScatterKind::Conifer
                || point.Kind == rc::ScatterKind::Broadleaf)
            {
                trees[biome] += 1;
            }
        }
    }

    // Forest must be markedly more wooded than grassland.
    const double forestRate = total[rc::Biome::Forest] > 0
        ? double(trees[rc::Biome::Forest]) / double(total[rc::Biome::Forest]) : 0.0;
    const double grassRate = total[rc::Biome::Grassland] > 0
        ? double(trees[rc::Biome::Grassland]) / double(total[rc::Biome::Grassland]) : 0.0;

    RC_CHECK_MSG_VALUE(forestRate > grassRate * 2.0, forestRate);
    RC_CHECK_MSG_VALUE(grassRate > 0.0, grassRate);
}
