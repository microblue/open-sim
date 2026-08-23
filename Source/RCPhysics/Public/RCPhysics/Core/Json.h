// OpenRC Simulator - minimal JSON reader for aircraft / airfoil / propeller data.
//
// Why hand-rolled rather than vendored: the core must build both under UBT
// (exceptions disabled) and standalone, must not drag a 25k-line header into
// every translation unit, and must give precise line numbers when a tuning file
// is malformed - that error message is read dozens of times a session while
// dialling in a flight model.
//
// Accepted beyond strict JSON, deliberately, because these files are edited by
// hand while tuning:
//   - // line comments and block comments
//   - trailing commas in objects and arrays
//
// No exceptions are thrown. Every failure is reported through JsonParseResult.
#pragma once

#include "RCPhysics/Core/Types.h"

#include <map>
#include <string>
#include <vector>

namespace rc
{
class JsonValue;

using JsonObject = std::map<std::string, JsonValue>;
using JsonArray  = std::vector<JsonValue>;

class JsonValue
{
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    JsonValue() = default;
    explicit JsonValue(bool v)               : ValueType(Type::Bool), BoolValue(v) {}
    explicit JsonValue(Real v)               : ValueType(Type::Number), NumberValue(v) {}
    explicit JsonValue(std::string v)        : ValueType(Type::String), StringValue(std::move(v)) {}
    explicit JsonValue(JsonArray v)          : ValueType(Type::Array), ArrayValue(std::move(v)) {}
    explicit JsonValue(JsonObject v)         : ValueType(Type::Object), ObjectValue(std::move(v)) {}

    Type GetType() const { return ValueType; }
    bool IsNull() const   { return ValueType == Type::Null; }
    bool IsBool() const   { return ValueType == Type::Bool; }
    bool IsNumber() const { return ValueType == Type::Number; }
    bool IsString() const { return ValueType == Type::String; }
    bool IsArray() const  { return ValueType == Type::Array; }
    bool IsObject() const { return ValueType == Type::Object; }

    bool        AsBool(bool fallback = false) const;
    Real        AsNumber(Real fallback = 0.0) const;
    std::string AsString(const std::string& fallback = std::string()) const;

    const JsonArray&  AsArray() const;
    const JsonObject& AsObject() const;

    /** Object member lookup. Returns a null value when absent or not an object. */
    const JsonValue& operator[](const std::string& key) const;
    bool Has(const std::string& key) const;

    /** Array element. Returns a null value when out of range or not an array. */
    const JsonValue& At(size_t index) const;
    size_t Size() const;

    // Typed member helpers - the form used all over AircraftLoader.
    Real        GetNumber(const std::string& key, Real fallback = 0.0) const;
    bool        GetBool(const std::string& key, bool fallback = false) const;
    std::string GetString(const std::string& key,
                          const std::string& fallback = std::string()) const;

    /** Reads a 3-element numeric array into x/y/z. Returns false and leaves the
     *  outputs untouched when the member is missing or malformed. */
    bool GetVector3(const std::string& key, Real& outX, Real& outY, Real& outZ) const;

    /** Reads an array of numbers. Returns false when absent or not all numeric. */
    bool GetNumberArray(const std::string& key, std::vector<Real>& outValues) const;

private:
    static const JsonValue& NullValue();

    Type        ValueType = Type::Null;
    bool        BoolValue = false;
    Real        NumberValue = 0.0;
    std::string StringValue;
    JsonArray   ArrayValue;
    JsonObject  ObjectValue;
};

struct JsonParseResult
{
    bool        Success = false;
    std::string Error;      ///< empty on success
    int         Line   = 0; ///< 1-based line of the failure
    int         Column = 0; ///< 1-based column of the failure

    /** "line 12, column 5: expected ':'" - ready to hand to RC_LOG. */
    std::string Describe() const;
};

/** Parse JSON text. On failure the returned value is null and `outResult`
 *  carries the reason. */
JsonValue ParseJson(const std::string& text, JsonParseResult& outResult);

/** Read a whole file into a string. Returns false if it cannot be opened. */
bool ReadTextFile(const std::string& path, std::string& outText, std::string& outError);

/** Convenience: read + parse, logging nothing. */
JsonValue ParseJsonFile(const std::string& path, JsonParseResult& outResult);

} // namespace rc
