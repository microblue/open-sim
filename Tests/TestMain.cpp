#include "TestHarness.h"

#include "RCPhysics/Core/Log.h"

#include <cstring>

namespace rctest
{
std::vector<TestCase>& Registry()
{
    static std::vector<TestCase> cases;
    return cases;
}

int RunAll(const char* filter)
{
    const std::string filterText = (filter != nullptr) ? filter : std::string();

    int totalTests   = 0;
    int failedTests  = 0;
    int totalChecks  = 0;

    for (const TestCase& testCase : Registry())
    {
        const std::string fullName = std::string(testCase.Suite) + "." + testCase.Name;
        if (!filterText.empty() && fullName.find(filterText) == std::string::npos)
        {
            continue;
        }

        ++totalTests;
        TestContext ctx;
        testCase.Function(ctx);
        totalChecks += ctx.Checks();

        if (ctx.Failures() > 0)
        {
            ++failedTests;
            std::printf("  [FAIL] %s  (%d/%d checks failed)\n",
                        fullName.c_str(), ctx.Failures(), ctx.Checks());
        }
        else
        {
            std::printf("  [ ok ] %s  (%d checks)\n", fullName.c_str(), ctx.Checks());
        }
    }

    std::printf("\n%d tests, %d checks, %d failed\n", totalTests, totalChecks, failedTests);
    return failedTests;
}

} // namespace rctest

int main(int argc, char** argv)
{
    // Tests exercise error paths on purpose; keep the console readable.
    rc::SetLogVerbosity(rc::LogLevel::Error);

    const char* filter = (argc > 1) ? argv[1] : nullptr;
    std::printf("OpenRC Simulator - physics core tests\n");
    if (filter != nullptr)
    {
        std::printf("filter: \"%s\"\n", filter);
    }
    std::printf("\n");

    const int failures = rctest::RunAll(filter);
    return (failures == 0) ? 0 : 1;
}
