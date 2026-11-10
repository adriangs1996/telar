module;
#include <cstdio>
#include <cstdlib>

export module telar.runtime.tests.check;

import std;

export {
inline void check(bool condition, std::source_location location = std::source_location::current()) {
  if (!condition) {
    std::fprintf(stderr, "%s:%u: check failed\n", location.file_name(), location.line());
    std::abort();
  }
}

// The runtime-tests entry points are defined in non-module units, so they
// stay attached to the global module.
extern "C++" {
void testMemory();
void testOutgoingFrames();
void testDeferredResponses();
void testTabHolds();
void testClientDelivery();
void testTerminal();
void testFrameSync();
void testPlatform();
void testText();
void testClientControl();
void testHistory();
void testHistoryQueue();
void testHistoryCapacity();
void testInputCapacity();
void testPtyResponses();
void testPtyResponseQueue();

void testControlServices();

void testGraphics();
void testGraphicsLimits();
void testAtomicGraphics();
void testAtomicRuntime();
void testProxyPolicy();
void testHttp1();
void testMedia();
void testBackgroundServices();
void testPathService();

void testAgents();

void testWorktreeProbe();
void testPersistence();
void testObservation();
void testCommandCapture();
void testShellIntegration();
void testMetrics();
void testCli();
void testLua();
void testConfig();
void testSessionFiles();
void testDescriptions();
void testProcessIdentification();
void testDeferredReports();
void testDescent();

void testWorkspaceGit();

void testWorktreeDetection();
void testLaunchDirectory();
void testLaunchFailures();
void testWorktreeLifecycle();
void testAdmission();
void testHttp2();
void testExchangeCapture();
void testCaptureDecoding();
void testCaptureProducer();
void testTransportCapture();
}
}
