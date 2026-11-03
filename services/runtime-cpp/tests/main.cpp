#include "check.hpp"
#include "telar_platform/error.hpp"
#include "terminal/ghostty_handle.hpp"
#include <cstring>
#include <exception>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc == 2 && std::strcmp(argv[1], "--process-identification-fixture") == 0) {
    for (;;) {
      ::pause();
    }
  }

  try {
    testMemory();
    testOutgoingFrames();
    testDeferredResponses();
    testTabHolds();
    testClientDelivery();
    testTerminal();
    testFrameSync();
    testPlatform();
    testText();
    testClientControl();
    testHistory();
    testHistoryQueue();
    testHistoryCapacity();
    testInputCapacity();
    testPtyResponses();
    testControlServices();
    testGraphics();
    testGraphicsLimits();
    testAtomicGraphics();
    testAtomicRuntime();
    testProxyPolicy();
    testHttp1();
    testHttp2();
    testExchangeCapture();
    testCaptureDecoding();
    testCaptureProducer();
    testTransportCapture();
    testMedia();
    testBackgroundServices();
    testPathService();
    testAgents();
    testWorktreeProbe();
    testWorkspaceGit();
    testWorktreeDetection();
    testPersistence();
    testObservation();
    testCommandCapture();
    testMetrics();
    testCli();
    testLua();
    testConfig();
    testSessionFiles();
    testDescriptions();
    testProcessIdentification();
    testDeferredReports();
    testDescent();
    testLaunchDirectory();
    testLaunchFailures();
    testWorktreeLifecycle();
    testAdmission();
    std::puts("All runtime tests passed");
    return 0;
  } catch (const telar::runtime::TerminalError &error) {
    std::fprintf(stderr, "%s:%u: Ghostty result %d\n", error.location().file_name(), error.location().line(), static_cast<int>(error.result()));
    return 1;
  } catch (const telar::runtime::SystemError &error) {
    std::fprintf(stderr, "%s: %s (%d)\n", error.what(), std::strerror(error.code()), error.code());
    return 1;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "Unexpected exception: %s\n", error.what());
    return 1;
  }
}
