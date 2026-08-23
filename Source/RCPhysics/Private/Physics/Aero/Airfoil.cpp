#include "RCPhysics/Physics/Aero/Airfoil.h"

#include <cmath>

namespace rc
{
namespace
{
    /** Smooth 0..1 ramp with zero derivative at both ends. A kink here would
     *  be felt through the stick as a buzz at the stall break. */
    Real SmoothStep(Real edge0, Real edge1, Real x)
    {
        if (edge1 - edge0 <= kEpsilon)
        {
            return x < edge0 ? 0.0 : 1.0;
        }
        const Real t = Clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    /** Fully separated flow behaves like a flat plate, and this form stays
     *  sane all the way to +/-180 degrees so a tumbling aircraft still
     *  produces finite, plausible forces. */
    Real FlatPlateLift(Real alpha)
    {
        return 2.0 * std::sin(alpha) * std::cos(alpha);
    }

    Real FlatPlateDrag(Real alpha, Real maxDrag)
    {
        const Real s = std::sin(alpha);
        return maxDrag * s * s;
    }

    /** Strip theory overpredicts what a PARTIAL-SPAN control does to a finite
     *  wing: the circulation redistributes along the span instead of following
     *  the local deflection everywhere. The lifting-line correction is around
     *  0.75 for a control covering roughly half the semi-span.
     *
     *  Without this the Trainer 1500 rolls at 270 deg/s - pb/2V of 0.22, an
     *  aerobatic figure - instead of the 130-170 deg/s a trainer actually does. */
    constexpr Real kSpanwiseEffectivenessCorrection = 0.75;

    /** Viscous loss at large deflections. Flow begins to separate over the
     *  deflected surface, so a 20 degree aileron is not twice as effective as a
     *  10 degree one. Roskam's eta_delta curve, linearised: unity below 10 deg,
     *  falling to about 0.6 by 30 deg. */
    Real DeflectionEfficiency(Real deflection)
    {
        const Real degrees = std::fabs(deflection) * 180.0 / kPi;
        return Clamp(1.0 - 0.02 * Max(0.0, degrees - 10.0), 0.5, 1.0);
    }

    /** Reynolds sensitivity of maximum lift. Empirical, deliberately mild, and
     *  bounded so that an absurd Reynolds number cannot produce a wing that
     *  lifts twice as hard. */
    Real ReynoldsLiftFactor(Real reynolds, Real referenceReynolds)
    {
        if (reynolds <= 1000.0 || referenceReynolds <= 1000.0)
        {
            return 0.7;
        }
        const Real factor = 1.0 + 0.10 * std::log(reynolds / referenceReynolds);
        return Clamp(factor, 0.55, 1.35);
    }
}

Airfoil::Airfoil(const AirfoilParameters& parameters) : Parameters(parameters) {}

void Airfoil::SetParameters(const AirfoilParameters& parameters)
{
    Parameters = parameters;
}

bool Airfoil::SetTables(Table2D lift, Table2D drag, Table2D moment, std::string* outError)
{
    if (lift.IsEmpty() || drag.IsEmpty())
    {
        if (outError) { *outError = "Airfoil: lift and drag tables are both required"; }
        return false;
    }
    LiftTable   = std::move(lift);
    DragTable   = std::move(drag);
    MomentTable = std::move(moment);
    UseTables   = true;
    return true;
}

Real Airfoil::FlapEffectiveness(Real chordFraction)
{
    // Thin-airfoil theory: tau = 1 - (theta - sin theta)/pi, theta = acos(2E - 1).
    const Real e = Clamp(chordFraction, 0.0, 1.0);
    if (e <= kEpsilon) { return 0.0; }
    if (e >= 1.0)      { return 1.0; }
    const Real theta = std::acos(ClampUnit(2.0 * e - 1.0));
    return Clamp(1.0 - (theta - std::sin(theta)) / kPi, 0.0, 1.0);
}

Real Airfoil::LiftCurveSlope(Real aspectRatio) const
{
    // Finite-wing correction. A section on a low aspect ratio surface - the
    // horizontal tail, and especially the fin - has a much shallower lift
    // curve than the 2D airfoil data suggests.
    const Real a0 = Parameters.ClAlphaPerRad;
    const Real ar = Max(aspectRatio, 0.2);
    const Real e  = Clamp(Parameters.OswaldEfficiency, 0.1, 1.0);
    return a0 / (1.0 + a0 / (kPi * ar * e));
}

Real Airfoil::ZeroLiftAngle() const
{
    // Camber shifts the whole curve left; the zero-lift angle itself is a 2D
    // property and does not change with aspect ratio.
    return -SafeDivide(Parameters.ClZeroAlpha, Parameters.ClAlphaPerRad, 0.0);
}

Real Airfoil::MaxLiftCoefficient(Real reynolds) const
{
    return Parameters.ClMax * ReynoldsLiftFactor(reynolds, Parameters.ReferenceReynolds);
}

Real Airfoil::StallAngle(Real reynolds) const
{
    if (reynolds <= 1000.0 || Parameters.ReferenceReynolds <= 1000.0)
    {
        return Parameters.AlphaStall * 0.85;
    }
    const Real factor = Clamp(1.0 + 0.04 * std::log(reynolds / Parameters.ReferenceReynolds),
                              0.75, 1.20);
    return Parameters.AlphaStall * factor;
}

Real Airfoil::MinimumDrag(Real reynolds) const
{
    // Profile drag rises as Reynolds falls; the classic flat-plate exponent.
    if (reynolds <= 1000.0 || Parameters.ReferenceReynolds <= 1000.0)
    {
        return Parameters.CdMin * 2.0;
    }
    const Real factor = std::pow(Parameters.ReferenceReynolds / reynolds, 0.2);
    return Parameters.CdMin * Clamp(factor, 0.6, 3.0);
}

AeroCoefficients Airfoil::Evaluate(const AirfoilQuery& query) const
{
    AeroCoefficients result;

    const Real alpha = WrapPi(query.Alpha);
    const Real reynolds = Max(query.Reynolds, 0.0);

    // ---------------------------------------------------- control surface ---
    // A deflected control surface changes the section's effective camber. That
    // is why it alters C_L, C_D and C_m rather than just adding a moment.
    const Real controlAuthority = query.ControlEffectiveness
                                * Clamp(query.ControlSpanFraction, 0.0, 1.0)
                                * kSpanwiseEffectivenessCorrection
                                * DeflectionEfficiency(query.ControlDeflection);
    const Real deltaAlphaZeroLift = -controlAuthority * query.ControlDeflection;

    // ------------------------------------------------------------- stall ----
    const Real stallAngle = StallAngle(reynolds);
    const Real onset = query.WasSeparated
                     ? Max(stallAngle - Parameters.ReattachHysteresis, 0.0)
                     : stallAngle;
    const Real blend = Max(Parameters.StallBlend, 1e-4);
    const Real separation = SmoothStep(onset, onset + blend, std::fabs(alpha));
    result.SeparationFraction = separation;

    if (UseTables)
    {
        // Measured polars win outright. The separation fraction above is still
        // computed, because control effectiveness depends on it.
        result.Cl = LiftTable.Evaluate(alpha, reynolds);
        result.Cd = DragTable.Evaluate(alpha, reynolds);
        result.Cm = MomentTable.IsEmpty() ? Parameters.CmQuarterChord
                                          : MomentTable.Evaluate(alpha, reynolds);
        // Even with tables, a deflected surface must still do something.
        const Real slope = LiftCurveSlope(query.AspectRatio);
        const Real deltaCl = slope * controlAuthority * query.ControlDeflection
                           * (1.0 - 0.8 * separation);
        result.Cl += deltaCl;
        result.Cm += -0.25 * deltaCl;
        result.Cd += 0.6 * Sq(query.ControlDeflection);
        return result;
    }

    // ------------------------------------------------- attached behaviour ---
    const Real slope = LiftCurveSlope(query.AspectRatio);
    const Real zeroLift = ZeroLiftAngle() + deltaAlphaZeroLift;
    const Real clMax = MaxLiftCoefficient(reynolds);

    Real clAttached = slope * (alpha - zeroLift);
    // Round the top off rather than letting the straight line run away during
    // the blend; without this the peak lands past the stall angle.
    clAttached = Clamp(clAttached, -clMax, clMax);

    // ------------------------------------------------ separated behaviour ---
    const Real clSeparated = FlatPlateLift(alpha);

    result.Cl = Lerp(clAttached, clSeparated, separation);

    // --------------------------------------------------------------- drag ---
    //
    // Separation ADDS pressure drag; it does not replace induced drag. Blending
    // between an "attached" and a "separated" total instead gets this badly
    // wrong: as C_L collapses through the break, an induced term built on the
    // blended C_L collapses with it, and total drag FALLS at the stall. That is
    // the opposite of what a stall does, and it would let an aircraft mush
    // along in deep stall instead of descending.
    //
    // So the induced term is built on the circulation the wing is still trying
    // to generate (the clamped attached value, which plateaus at C_Lmax), and
    // the wake term is added on top as separation grows.
    const Real cd0 = MinimumDrag(reynolds);
    const Real profileDrag = Parameters.CdAlphaQuadratic * Sq(alpha - zeroLift);

    const Real ar = Max(query.AspectRatio, 0.2);
    const Real e  = Clamp(Parameters.OswaldEfficiency, 0.1, 1.0);
    const Real inducedDrag = Sq(clAttached) / (kPi * ar * e);

    const Real wakeDrag = separation * FlatPlateDrag(alpha, Parameters.CdSeparatedMax);

    result.Cd = cd0 + profileDrag + inducedDrag + wakeDrag
              + 0.6 * Sq(query.ControlDeflection);

    // ------------------------------------------------------------- moment ---
    // Attached: the section's own camber moment plus the control surface's
    // contribution, both about the quarter chord.
    const Real deltaCl = slope * controlAuthority * query.ControlDeflection;
    const Real cmAttached = Parameters.CmQuarterChord - 0.25 * deltaCl;

    // Separated: the centre of pressure moves aft towards mid chord, which is
    // the strong nose-down pitching moment that makes a stall break.
    const Real normalForce = result.Cl * std::cos(alpha) + result.Cd * std::sin(alpha);
    const Real cmSeparated = -0.25 * normalForce;

    result.Cm = Lerp(cmAttached, cmSeparated, separation);

    return result;
}

} // namespace rc
