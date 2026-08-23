#include "RCPhysics/Input/ChannelMapper.h"

#include "RCPhysics/Core/Json.h"
#include "RCPhysics/Core/Log.h"

#include <sstream>

namespace rc
{
namespace
{
    /** Channel order used by the on-disk profile. Kept explicit so that adding
     *  a channel later cannot silently renumber an existing profile. */
    const char* const kChannelKeys[kChannelCount] = {
        "aileron", "elevator", "throttle", "rudder", "flap", "aux1"
    };
}

ChannelMapper::ChannelMapper() = default;

ChannelBinding& ChannelMapper::Binding(RCChannel channel)
{
    return Bindings[static_cast<size_t>(channel)];
}

const ChannelBinding& ChannelMapper::Binding(RCChannel channel) const
{
    return Bindings[static_cast<size_t>(channel)];
}

void ChannelMapper::Bind(RCChannel channel, int axisIndex,
                         const AxisCalibration& calibration)
{
    ChannelBinding& binding = Binding(channel);
    binding.AxisIndex   = axisIndex;
    binding.Calibration = calibration;

    if (!calibration.IsValid())
    {
        RC_LOG(Input, Warning,
               "%s bound to axis %d with an unusable calibration "
               "(min %.3f centre %.3f max %.3f); it will read neutral.",
               ToString(channel), axisIndex,
               calibration.RawMin, calibration.RawCenter, calibration.RawMax);
    }
}

void ChannelMapper::Unbind(RCChannel channel)
{
    Binding(channel) = ChannelBinding{};
}

bool ChannelMapper::IsFullyBound() const
{
    // Flap and Aux1 are optional; the four primary channels are not.
    const RCChannel required[] = {RCChannel::Aileron, RCChannel::Elevator,
                                  RCChannel::Throttle, RCChannel::Rudder};
    for (RCChannel channel : required)
    {
        const ChannelBinding& binding = Binding(channel);
        if (!binding.IsBound() || !binding.Calibration.IsValid())
        {
            return false;
        }
    }
    return true;
}

ChannelValues ChannelMapper::Update(const RawAxisState& raw) const
{
    ChannelValues values = ChannelValues::Neutral();

    if (!raw.Connected)
    {
        // Deliberately NOT the last known values. A transmitter unplugged mid
        // flight must close the throttle and centre the sticks, so the habit
        // the pilot builds is the safe one.
        return values;
    }

    for (size_t i = 0; i < kChannelCount; ++i)
    {
        const RCChannel channel = static_cast<RCChannel>(i);
        const ChannelBinding& binding = Bindings[i];
        if (!binding.IsBound())
        {
            continue;
        }

        const bool bipolar = IsBipolar(channel);
        const Real rawValue = raw.GetAxis(binding.AxisIndex);
        const Real normalized = binding.Calibration.Normalize(rawValue, bipolar);
        values.Set(channel, binding.Shaping.Apply(normalized, bipolar));
    }

    return values;
}

void ChannelMapper::SetRawMode(bool rawMode)
{
    for (ChannelBinding& binding : Bindings)
    {
        binding.Shaping.RawMode = rawMode;
    }
}

bool ChannelMapper::IsRawMode() const
{
    // Raw mode is all-or-nothing from the UI's point of view; report it as on
    // only when every channel agrees.
    for (const ChannelBinding& binding : Bindings)
    {
        if (!binding.Shaping.RawMode) { return false; }
    }
    return true;
}

std::string ChannelMapper::ToJson() const
{
    std::ostringstream out;
    out.precision(9);
    out << "{\n  \"format_version\": " << kProfileFormatVersion << ",\n  \"channels\": {";

    for (size_t i = 0; i < kChannelCount; ++i)
    {
        const ChannelBinding& b = Bindings[i];
        out << (i == 0 ? "\n" : ",\n");
        out << "    \"" << kChannelKeys[i] << "\": {"
            << " \"axis\": "      << b.AxisIndex
            << ", \"raw_min\": "   << b.Calibration.RawMin
            << ", \"raw_center\": "<< b.Calibration.RawCenter
            << ", \"raw_max\": "   << b.Calibration.RawMax
            << ", \"deadzone\": "  << b.Calibration.Deadzone
            << ", \"reversed\": "  << (b.Calibration.Reversed ? "true" : "false")
            << ", \"expo\": "      << b.Shaping.Expo
            << ", \"dual_rate\": " << b.Shaping.DualRate
            << ", \"trim\": "      << b.Shaping.Trim
            << ", \"raw_mode\": "  << (b.Shaping.RawMode ? "true" : "false")
            << " }";
    }
    out << "\n  }\n}\n";
    return out.str();
}

bool ChannelMapper::FromJson(const std::string& text, std::string* outError)
{
    JsonParseResult result;
    const JsonValue root = ParseJson(text, result);
    if (!result.Success)
    {
        if (outError) { *outError = result.Describe(); }
        return false;
    }

    // Version 1 profiles were captured while Godot was still applying an SDL
    // gamepad mapping to the transmitter. That mapping renumbers axes and
    // rescales some of them to 0..1, so a version 1 file binds channels to axes
    // that now mean something entirely different - a throttle bound to what is
    // really a three-position switch, for instance. Silently loading one puts
    // the aircraft in the air under controls the pilot is not holding, so it is
    // refused and the caller falls back to a built-in profile or the wizard.
    const int version = static_cast<int>(root.GetNumber("format_version", 1.0));
    if (version < kProfileFormatVersion)
    {
        if (outError)
        {
            *outError = "profile format version " + std::to_string(version) +
                        " predates the raw-axis input path and cannot be "
                        "trusted; recalibrate with the wizard";
        }
        return false;
    }

    const JsonValue& channels = root["channels"];
    if (!channels.IsObject())
    {
        if (outError) { *outError = "missing 'channels' object"; }
        return false;
    }

    for (size_t i = 0; i < kChannelCount; ++i)
    {
        const JsonValue& entry = channels[kChannelKeys[i]];
        if (!entry.IsObject())
        {
            continue;   // absent channels stay unbound
        }

        ChannelBinding binding;
        binding.AxisIndex = static_cast<int>(entry.GetNumber("axis", -1.0));
        binding.Calibration.RawMin    = entry.GetNumber("raw_min", -1.0);
        binding.Calibration.RawCenter = entry.GetNumber("raw_center", 0.0);
        binding.Calibration.RawMax    = entry.GetNumber("raw_max", 1.0);
        binding.Calibration.Deadzone  = entry.GetNumber("deadzone", 0.02);
        binding.Calibration.Reversed  = entry.GetBool("reversed", false);
        binding.Shaping.Expo     = entry.GetNumber("expo", 0.0);
        binding.Shaping.DualRate = entry.GetNumber("dual_rate", 1.0);
        binding.Shaping.Trim     = entry.GetNumber("trim", 0.0);
        binding.Shaping.RawMode  = entry.GetBool("raw_mode", false);

        Bindings[i] = binding;
    }

    return true;
}

} // namespace rc
