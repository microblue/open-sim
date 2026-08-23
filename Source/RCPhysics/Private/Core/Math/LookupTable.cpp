#include "RCPhysics/Core/Math/LookupTable.h"

#include <algorithm>

namespace rc
{
namespace
{
    void SetError(std::string* outError, const char* message)
    {
        if (outError != nullptr) { *outError = message; }
    }

    bool IsStrictlyIncreasing(const std::vector<Real>& keys)
    {
        for (size_t i = 1; i < keys.size(); ++i)
        {
            if (!(keys[i] > keys[i - 1])) { return false; }
        }
        return true;
    }
}

// ------------------------------------------------------------------ 1D ------

bool Table1D::Build(std::vector<Real> keys, std::vector<Real> values, std::string* outError)
{
    Keys.clear();
    Values.clear();

    if (keys.empty())
    {
        SetError(outError, "Table1D: needs at least one sample");
        return false;
    }
    if (keys.size() != values.size())
    {
        SetError(outError, "Table1D: key/value count mismatch");
        return false;
    }
    if (!IsStrictlyIncreasing(keys))
    {
        SetError(outError, "Table1D: keys must be strictly increasing");
        return false;
    }

    Keys   = std::move(keys);
    Values = std::move(values);
    return true;
}

size_t Table1D::FindSegment(Real key, Real& outFraction) const
{
    // Caller guarantees Keys.size() >= 2 and MinKey() <= key <= MaxKey().
    const auto upper = std::upper_bound(Keys.begin(), Keys.end(), key);
    size_t hi = static_cast<size_t>(upper - Keys.begin());
    if (hi == 0) { hi = 1; }
    if (hi >= Keys.size()) { hi = Keys.size() - 1; }
    const size_t lo = hi - 1;

    const Real span = Keys[hi] - Keys[lo];
    outFraction = (span > kEpsilon) ? ((key - Keys[lo]) / span) : 0.0;
    return lo;
}

Real Table1D::Evaluate(Real key) const
{
    if (Keys.empty())   { return 0.0; }
    if (Keys.size() == 1) { return Values[0]; }

    if (key <= Keys.front())
    {
        if (Extrapolation == ExtrapolationMode::Clamp) { return Values.front(); }
        const Real slope = (Values[1] - Values[0]) / (Keys[1] - Keys[0]);
        return Values.front() + slope * (key - Keys.front());
    }
    if (key >= Keys.back())
    {
        if (Extrapolation == ExtrapolationMode::Clamp) { return Values.back(); }
        const size_t n = Keys.size();
        const Real slope = (Values[n - 1] - Values[n - 2]) / (Keys[n - 1] - Keys[n - 2]);
        return Values.back() + slope * (key - Keys.back());
    }

    Real fraction = 0.0;
    const size_t lo = FindSegment(key, fraction);
    return Lerp(Values[lo], Values[lo + 1], fraction);
}

Real Table1D::EvaluateSlope(Real key) const
{
    if (Keys.size() < 2) { return 0.0; }

    size_t lo = 0;
    if (key <= Keys.front())
    {
        lo = 0;
    }
    else if (key >= Keys.back())
    {
        lo = Keys.size() - 2;
    }
    else
    {
        Real fraction = 0.0;
        lo = FindSegment(key, fraction);
    }

    // Clamped extrapolation is flat outside the sampled range.
    if (Extrapolation == ExtrapolationMode::Clamp &&
        (key < Keys.front() || key > Keys.back()))
    {
        return 0.0;
    }
    return (Values[lo + 1] - Values[lo]) / (Keys[lo + 1] - Keys[lo]);
}

// ------------------------------------------------------------------ 2D ------

bool Table2D::Build(std::vector<Real> rowKeys,
                    std::vector<Real> columnKeys,
                    std::vector<Real> values,
                    std::string* outError)
{
    RowKeys.clear();
    ColumnKeys.clear();
    Values.clear();

    if (rowKeys.empty() || columnKeys.empty())
    {
        SetError(outError, "Table2D: needs at least one row and one column");
        return false;
    }
    if (values.size() != rowKeys.size() * columnKeys.size())
    {
        SetError(outError, "Table2D: value count must equal rows * columns");
        return false;
    }
    if (!IsStrictlyIncreasing(rowKeys) || !IsStrictlyIncreasing(columnKeys))
    {
        SetError(outError, "Table2D: row and column keys must be strictly increasing");
        return false;
    }

    RowKeys    = std::move(rowKeys);
    ColumnKeys = std::move(columnKeys);
    Values     = std::move(values);
    return true;
}

Real Table2D::Evaluate(Real rowKey, Real columnKey) const
{
    if (Values.empty()) { return 0.0; }

    // Locate the bracketing indices and blend fractions on each axis. A single
    // row or column degenerates gracefully to 1D / constant.
    auto locate = [](const std::vector<Real>& keys, Real key,
                     ExtrapolationMode mode, size_t& outLow, Real& outFraction)
    {
        if (keys.size() == 1) { outLow = 0; outFraction = 0.0; return; }

        if (key <= keys.front())
        {
            outLow = 0;
            outFraction = (mode == ExtrapolationMode::Clamp)
                        ? 0.0
                        : (key - keys[0]) / (keys[1] - keys[0]);
            return;
        }
        if (key >= keys.back())
        {
            outLow = keys.size() - 2;
            const Real span = keys[outLow + 1] - keys[outLow];
            outFraction = (mode == ExtrapolationMode::Clamp)
                        ? 1.0
                        : 1.0 + (key - keys.back()) / span;
            return;
        }
        const auto upper = std::upper_bound(keys.begin(), keys.end(), key);
        size_t hi = static_cast<size_t>(upper - keys.begin());
        if (hi == 0) { hi = 1; }
        if (hi >= keys.size()) { hi = keys.size() - 1; }
        outLow = hi - 1;
        outFraction = (key - keys[outLow]) / (keys[hi] - keys[outLow]);
    };

    size_t r0 = 0, c0 = 0;
    Real rf = 0.0, cf = 0.0;
    locate(RowKeys, rowKey, Extrapolation, r0, rf);
    locate(ColumnKeys, columnKey, Extrapolation, c0, cf);

    const size_t columns = ColumnKeys.size();
    const size_t r1 = (RowKeys.size() == 1) ? r0 : r0 + 1;
    const size_t c1 = (columns == 1) ? c0 : c0 + 1;

    const Real v00 = Values[r0 * columns + c0];
    const Real v01 = Values[r0 * columns + c1];
    const Real v10 = Values[r1 * columns + c0];
    const Real v11 = Values[r1 * columns + c1];

    const Real lower = Lerp(v00, v01, cf);
    const Real upper = Lerp(v10, v11, cf);
    return Lerp(lower, upper, rf);
}

} // namespace rc
