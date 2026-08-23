// OpenRC Simulator - airfoil coefficients, including the stall.
//
// The section's job is to answer one question: at this angle of attack, this
// Reynolds number, this control deflection, and given whether the flow was
// already separated, what are C_L, C_D and C_m?
//
// Everything about the stall lives here, and it is driven by LOCAL angle of
// attack only. There is no aircraft-level "is stalled" flag anywhere in the
// project, which is what lets one wing stall while the other still flies.
//
// V0.1 seeds the curves analytically. The same class accepts tabulated data
// (XFoil, wind tunnel) through Table2D without any calling code changing.
#pragma once

#include "RCPhysics/Core/Math/LookupTable.h"
#include "RCPhysics/Core/Types.h"

#include <string>

namespace rc
{
/** Analytic description of a 2D section. All angles in radians. */
struct AirfoilParameters
{
    /** C_L at zero angle of attack - the camber. */
    Real ClZeroAlpha = 0.0;

    /** 2D lift-curve slope [1/rad]. Thin-airfoil theory gives 2*pi = 6.28;
     *  real sections at RC Reynolds numbers come in nearer 5.5 - 5.9. */
    Real ClAlphaPerRad = 5.7;

    Real ClMax = 1.2;

    /** Angle at which separation begins. */
    Real AlphaStall = 0.2269;   // 13 deg

    /** Width of the transition into full separation. THIS is what makes a stall
     *  gentle or vicious: a trainer wants it wide, a pattern ship narrow. */
    Real StallBlend = 0.0873;   // 5 deg

    /** Separated flow reattaches at a lower angle than it detached. Reproduces
     *  the "you have to unload properly to recover" behaviour that matters for
     *  training. */
    Real ReattachHysteresis = 0.0436;   // 2.5 deg

    Real CdMin = 0.012;

    /** Growth of profile drag with angle of attack, per rad^2. */
    Real CdAlphaQuadratic = 0.012;

    /** Flat-plate drag deep in the stall. */
    Real CdSeparatedMax = 1.30;

    Real CmQuarterChord = -0.075;

    Real OswaldEfficiency = 0.85;

    /** The Reynolds number the numbers above were characterised at. */
    Real ReferenceReynolds = 200000.0;
};

/** What a section evaluation produces. */
struct AeroCoefficients
{
    Real Cl = 0.0;
    Real Cd = 0.0;
    Real Cm = 0.0;

    /** 0 = fully attached, 1 = fully separated. Continuous, so the debug view
     *  can show a wing progressively letting go rather than a boolean flip. */
    Real SeparationFraction = 0.0;

    bool IsSeparated() const { return SeparationFraction > 0.5; }
};

/** Inputs to one evaluation. Grouped so the signature stays readable and so a
 *  new influence can be added without touching every call site. */
struct AirfoilQuery
{
    Real Alpha = 0.0;               ///< local angle of attack [rad]
    Real Reynolds = 200000.0;
    Real AspectRatio = 6.0;         ///< of the surface this section belongs to

    /** Control surface deflection [rad], positive trailing-edge down. */
    Real ControlDeflection = 0.0;

    /** Thin-airfoil flap effectiveness of the attached control surface, 0..1.
     *  Zero when the section carries no control surface. */
    Real ControlEffectiveness = 0.0;

    /** Fraction of the section's span the control surface covers. */
    Real ControlSpanFraction = 1.0;

    /** Separation state carried over from the previous step, for hysteresis. */
    bool WasSeparated = false;
};

class Airfoil
{
public:
    Airfoil() = default;
    explicit Airfoil(const AirfoilParameters& parameters);

    void SetParameters(const AirfoilParameters& parameters);
    const AirfoilParameters& GetParameters() const { return Parameters; }

    /** Supply measured polars. When present they replace the analytic curve
     *  for C_L / C_D / C_m; the stall parameters are still used for the
     *  separation bookkeeping the control surfaces depend on.
     *  Rows are angle of attack [rad], columns Reynolds number. */
    bool SetTables(Table2D lift, Table2D drag, Table2D moment, std::string* outError = nullptr);
    bool HasTables() const { return UseTables; }

    AeroCoefficients Evaluate(const AirfoilQuery& query) const;

    /** Finite-wing lift-curve slope for a given aspect ratio [1/rad]. */
    Real LiftCurveSlope(Real aspectRatio) const;

    /** Angle of attack at which the 2D section produces zero lift [rad]. */
    Real ZeroLiftAngle() const;

    /** Reynolds-corrected maximum lift coefficient. Lower Reynolds, less lift -
     *  the single most important RC-scale correction. */
    Real MaxLiftCoefficient(Real reynolds) const;

    /** Reynolds-corrected stall angle [rad]. */
    Real StallAngle(Real reynolds) const;

    /** Reynolds-corrected minimum profile drag. */
    Real MinimumDrag(Real reynolds) const;

    /** Thin-airfoil flap effectiveness for a control surface occupying
     *  `chordFraction` of the chord. Free function of geometry only. */
    static Real FlapEffectiveness(Real chordFraction);

private:
    AirfoilParameters Parameters;

    bool    UseTables = false;
    Table2D LiftTable;
    Table2D DragTable;
    Table2D MomentTable;
};

} // namespace rc
