#include "RCPhysics/Input/ChannelTypes.h"

namespace rc
{
const char* ToString(RCChannel channel)
{
    switch (channel)
    {
        case RCChannel::Aileron:  return "AIL";
        case RCChannel::Elevator: return "ELE";
        case RCChannel::Throttle: return "THR";
        case RCChannel::Rudder:   return "RUD";
        case RCChannel::Flap:     return "FLP";
        case RCChannel::Aux1:     return "AUX1";
        case RCChannel::Count:    break;
    }
    return "???";
}

} // namespace rc
