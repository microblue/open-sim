#include "TestHarness.h"

#include "RCPhysics/Core/Json.h"

using namespace rc;

namespace
{
    const char* const kAircraftFragment = R"JSON(
{
    // Trainer-style fragment, written the way a human tunes it.
    "name": "Trainer 1500",
    "mass_kg": 1.35,
    "wingspan_m": 1.5,
    "powered": true,
    "notes": null,
    "cg_offset_m": [0.0, 0.0, -0.015],
    "alpha_table_deg": [-8, 0, 8, 14, 18],

    /* Nested objects must survive too. */
    "propeller": {
        "diameter_in": 11,
        "pitch_in": 6,
        "blades": 2,      // trailing comma below is intentional
    },
}
)JSON";
}

RC_TEST(Json, ParsesAircraftFragmentWithCommentsAndTrailingCommas)
{
    JsonParseResult result;
    const JsonValue root = ParseJson(kAircraftFragment, result);

    if (!result.Success)
    {
        RC_FAIL("parse failed: " + result.Describe());
        return;
    }

    RC_CHECK(root.IsObject());
    RC_CHECK(root.GetString("name") == "Trainer 1500");
    RC_CHECK_NEAR(root.GetNumber("mass_kg"), 1.35, 1e-15);
    RC_CHECK_NEAR(root.GetNumber("wingspan_m"), 1.5, 1e-15);
    RC_CHECK(root.GetBool("powered") == true);
    RC_CHECK(root["notes"].IsNull());
    RC_CHECK(root.Has("propeller"));
    RC_CHECK(!root.Has("missing_member"));
}

RC_TEST(Json, ReadsVectorsAndNumberArrays)
{
    JsonParseResult result;
    const JsonValue root = ParseJson(kAircraftFragment, result);
    RC_CHECK(result.Success);

    Real x = 0.0, y = 0.0, z = 0.0;
    RC_CHECK(root.GetVector3("cg_offset_m", x, y, z));
    RC_CHECK_NEAR(z, -0.015, 1e-15);

    std::vector<Real> alphas;
    RC_CHECK(root.GetNumberArray("alpha_table_deg", alphas));
    RC_CHECK(alphas.size() == 5);
    RC_CHECK_NEAR(alphas[3], 14.0, 1e-15);

    // Wrong shape must be rejected rather than silently half-read.
    RC_CHECK(!root.GetVector3("alpha_table_deg", x, y, z));
    RC_CHECK(!root.GetNumberArray("name", alphas));
}

RC_TEST(Json, NestedAccessAndDefaults)
{
    JsonParseResult result;
    const JsonValue root = ParseJson(kAircraftFragment, result);
    RC_CHECK(result.Success);

    const JsonValue& prop = root["propeller"];
    RC_CHECK(prop.IsObject());
    RC_CHECK_NEAR(prop.GetNumber("diameter_in"), 11.0, 1e-15);
    RC_CHECK_NEAR(prop.GetNumber("pitch_in"), 6.0, 1e-15);

    // Missing members fall back instead of crashing - the loader relies on this
    // so that a partially specified aircraft still builds.
    RC_CHECK_NEAR(prop.GetNumber("spinner_diameter_in", 1.5), 1.5, 1e-15);
    RC_CHECK(prop.GetString("manufacturer", "unknown") == "unknown");
    RC_CHECK(root["does"]["not"]["exist"].IsNull());
}

RC_TEST(Json, ParsesNumberFormats)
{
    JsonParseResult result;
    const JsonValue root = ParseJson(
        R"({"a": -2, "b": 1e3, "c": 2.5E-2, "d": 0.0, "e": 1.789e-5})", result);
    RC_CHECK(result.Success);
    RC_CHECK_NEAR(root.GetNumber("a"), -2.0, 1e-15);
    RC_CHECK_NEAR(root.GetNumber("b"), 1000.0, 1e-12);
    RC_CHECK_NEAR(root.GetNumber("c"), 0.025, 1e-15);
    RC_CHECK_NEAR(root.GetNumber("e"), 1.789e-5, 1e-18);
}

RC_TEST(Json, ParsesEscapesInStrings)
{
    JsonParseResult result;
    const JsonValue root = ParseJson(R"({"s": "a\"b\\c\nd°"})", result);
    RC_CHECK(result.Success);
    const std::string s = root.GetString("s");
    RC_CHECK(s.find('"') != std::string::npos);
    RC_CHECK(s.find('\n') != std::string::npos);
    RC_CHECK(s.find("\xc2\xb0") != std::string::npos);   // degree sign, UTF-8
}

RC_TEST(Json, ReportsTheFailingLine)
{
    // A missing colon on line 3 is the classic hand-editing mistake.
    const char* const broken = "{\n"
                               "  \"good\": 1,\n"
                               "  \"bad\" 2\n"
                               "}\n";
    JsonParseResult result;
    ParseJson(broken, result);

    RC_CHECK(!result.Success);
    RC_CHECK(result.Line == 3);
    RC_CHECK(!result.Error.empty());
    RC_CHECK(result.Describe().find("line 3") != std::string::npos);
}

RC_TEST(Json, RejectsTruncatedAndTrailingGarbage)
{
    JsonParseResult result;

    ParseJson("{\"a\": 1", result);
    RC_CHECK(!result.Success);

    ParseJson("{\"a\": 1} extra", result);
    RC_CHECK(!result.Success);

    ParseJson("{\"a\": \"unterminated}", result);
    RC_CHECK(!result.Success);

    ParseJson("", result);
    RC_CHECK(!result.Success);
}

RC_TEST(Json, RejectsRunawayNesting)
{
    // Guards against a malformed file driving the parser into stack overflow.
    std::string deep;
    for (int i = 0; i < 512; ++i) { deep += "["; }
    for (int i = 0; i < 512; ++i) { deep += "]"; }

    JsonParseResult result;
    ParseJson(deep, result);
    RC_CHECK(!result.Success);
}

RC_TEST(Json, MissingFileIsReportedNotCrashed)
{
    JsonParseResult result;
    const JsonValue root = ParseJsonFile("/definitely/not/a/real/path.json", result);
    RC_CHECK(!result.Success);
    RC_CHECK(root.IsNull());
    RC_CHECK(result.Error.find("cannot open") != std::string::npos);
}
