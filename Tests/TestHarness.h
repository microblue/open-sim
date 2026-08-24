// OpenRC Simulator - minimal test harness for the physics core.
//
// Deliberately tiny and dependency-free: these tests must run on a bare
// toolchain with no engine, no package manager and no network, because they are
// the thing that tells us a physics change did not silently break the flight
// model (Docs/MILESTONES.md, Milestone 8).
//
//     RC_TEST(Quat, RoundTripsThroughEuler)
//     {
//         RC_CHECK_NEAR(recovered.pitch, 0.3, 1e-12);
//     }
#pragma once

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace rctest
{
class TestContext
{
public:
    void Check(bool condition, const char* expression, const char* file, int line)
    {
        ++CheckCount;
        if (!condition)
        {
            ++FailureCount;
            std::printf("      FAIL %s:%d  %s\n", file, line, expression);
        }
    }

    void CheckNear(double actual, double expected, double tolerance,
                   const char* expression, const char* file, int line)
    {
        ++CheckCount;
        const double difference = std::fabs(actual - expected);
        if (!(difference <= tolerance) || !std::isfinite(difference))
        {
            ++FailureCount;
            std::printf("      FAIL %s:%d  %s\n"
                        "           actual   = %.12g\n"
                        "           expected = %.12g  (tolerance %.3g, off by %.3g)\n",
                        file, line, expression, actual, expected, tolerance, difference);
        }
    }

    /** Like Check, but prints the value that failed - so a tolerance miss says
     *  by how much rather than only that it happened. */
    void CheckValue(bool condition, double value,
                    const char* expression, const char* file, int line)
    {
        ++CheckCount;
        if (!condition)
        {
            ++FailureCount;
            std::printf("      FAIL %s:%d  %s\n"
                        "           value = %.12g\n",
                        file, line, expression, value);
        }
    }

    /** Explicit failure with a formatted reason. */
    void Fail(const std::string& reason, const char* file, int line)
    {
        ++CheckCount;
        ++FailureCount;
        std::printf("      FAIL %s:%d  %s\n", file, line, reason.c_str());
    }

    int Failures() const { return FailureCount; }
    int Checks() const   { return CheckCount; }

private:
    int CheckCount   = 0;
    int FailureCount = 0;
};

using TestFunction = void (*)(TestContext&);

struct TestCase
{
    const char*  Suite;
    const char*  Name;
    TestFunction Function;
};

std::vector<TestCase>& Registry();

struct AutoRegister
{
    AutoRegister(const char* suite, const char* name, TestFunction function)
    {
        Registry().push_back(TestCase{suite, name, function});
    }
};

/** Runs every registered test whose "Suite.Name" contains `filter`
 *  (nullptr or empty runs everything). Returns the number of failed tests. */
int RunAll(const char* filter);

} // namespace rctest

#define RC_TEST(SuiteName, TestName)                                                    \
    static void rctest_##SuiteName##_##TestName(::rctest::TestContext& ctx);            \
    static ::rctest::AutoRegister rctest_reg_##SuiteName##_##TestName(                  \
        #SuiteName, #TestName, &rctest_##SuiteName##_##TestName);                       \
    static void rctest_##SuiteName##_##TestName(::rctest::TestContext& ctx)

#define RC_CHECK(Condition) \
    ctx.Check((Condition), #Condition, __FILE__, __LINE__)

#define RC_CHECK_NEAR(Actual, Expected, Tolerance) \
    ctx.CheckNear((Actual), (Expected), (Tolerance), #Actual " ~= " #Expected, __FILE__, __LINE__)

/** Like RC_CHECK, but reports the value that failed - so a tolerance miss says
 *  by how much rather than only that it happened. */
#define RC_CHECK_MSG_VALUE(Condition, Value) \
    ctx.CheckValue((Condition), (Value), #Condition, __FILE__, __LINE__)

#define RC_FAIL(Reason) \
    ctx.Fail((Reason), __FILE__, __LINE__)
