// OpenRC Simulator - interpolated lookup tables.
//
// These exist so that the aerodynamic and propulsion models are never locked to
// an analytic curve fit. V0.1 seeds them from analytic approximations, but the
// same objects accept XFoil polars, wind-tunnel sweeps and APC propeller data
// files without touching any calling code.
//
//   Table1D : CL(alpha), thrust coefficient vs advance ratio, ...
//   Table2D : CL(alpha, Reynolds), Ct(J, blade pitch), ...
#pragma once

#include "RCPhysics/Core/Types.h"

#include <string>
#include <vector>

namespace rc
{
/** What happens outside the sampled range. */
enum class ExtrapolationMode
{
    Clamp,      ///< hold the edge value (default; safe for coefficients)
    Linear      ///< continue the edge slope (use for monotone physical trends)
};

/** Monotonically increasing keys -> values, linear interpolation between. */
class Table1D
{
public:
    Table1D() = default;

    /** Build from parallel arrays. Returns false (and leaves the table empty)
     *  if sizes mismatch, fewer than one point is supplied, or keys are not
     *  strictly increasing. `outError` receives a human-readable reason. */
    bool Build(std::vector<Real> keys,
               std::vector<Real> values,
               std::string* outError = nullptr);

    Real Evaluate(Real key) const;

    /** Derivative dValue/dKey at `key` (piecewise constant per segment).
     *  Used for things like lift-curve slope queries. */
    Real EvaluateSlope(Real key) const;

    void SetExtrapolation(ExtrapolationMode mode) { Extrapolation = mode; }
    ExtrapolationMode GetExtrapolation() const { return Extrapolation; }

    bool   IsEmpty() const { return Keys.empty(); }
    size_t Size() const    { return Keys.size(); }
    Real   MinKey() const  { return Keys.empty() ? 0.0 : Keys.front(); }
    Real   MaxKey() const  { return Keys.empty() ? 0.0 : Keys.back(); }

    const std::vector<Real>& GetKeys() const   { return Keys; }
    const std::vector<Real>& GetValues() const { return Values; }

private:
    /** Index of the segment containing `key`, plus the 0..1 fraction into it. */
    size_t FindSegment(Real key, Real& outFraction) const;

    std::vector<Real> Keys;
    std::vector<Real> Values;
    ExtrapolationMode Extrapolation = ExtrapolationMode::Clamp;
};

/** Bilinear interpolation over a rectangular grid.
 *  Values are row-major: Values[rowIndex * ColumnCount + columnIndex],
 *  where rows are indexed by RowKeys and columns by ColumnKeys. */
class Table2D
{
public:
    Table2D() = default;

    bool Build(std::vector<Real> rowKeys,
               std::vector<Real> columnKeys,
               std::vector<Real> values,
               std::string* outError = nullptr);

    Real Evaluate(Real rowKey, Real columnKey) const;

    void SetExtrapolation(ExtrapolationMode mode) { Extrapolation = mode; }

    bool   IsEmpty() const { return Values.empty(); }
    size_t RowCount() const    { return RowKeys.size(); }
    size_t ColumnCount() const { return ColumnKeys.size(); }

private:
    std::vector<Real> RowKeys;
    std::vector<Real> ColumnKeys;
    std::vector<Real> Values;
    ExtrapolationMode Extrapolation = ExtrapolationMode::Clamp;
};

} // namespace rc
