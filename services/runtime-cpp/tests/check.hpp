#pragma once

#include <cstdio>
#include <cstdlib>
#include <source_location>

inline void check(bool condition, std::source_location location = std::source_location::current()) {
  if (!condition) {
    std::fprintf(stderr, "%s:%u: check failed\n", location.file_name(), location.line());
    std::abort();
  }
}

void testMemory();
void testOutgoingFrames();
void testDeferredResponses();
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
void testMetrics();
void testCli();
void testLua();
void testConfig();
void testSessionFiles();
void testDescriptions();
void testProcessIdentification();
void testDeferredReports();
void testDescent();
void testClone();

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
