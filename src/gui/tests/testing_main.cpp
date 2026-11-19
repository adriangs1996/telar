// The main of the GUI's Qt test programs: the cases of telar::testing run inside one
// QGuiApplication, offscreen with the software Quick backend unless the test's environment
// names a platform, as the native window tests name cocoa. Listing the cases needs none.
#include <QGuiApplication>
#include <QtGlobal>
#include <cstring>

import telar.testing;

int main(int argc, char** argv) {
  for (int index = 1; index < argc; ++index) {
    if (std::strcmp(argv[index], "--gtest_list_tests") == 0) {
      return telar::testing::run(argc, argv);
    }
  }

  if (!qEnvironmentVariableIsSet("QT_QPA_PLATFORM")) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
  }

  if (!qEnvironmentVariableIsSet("QT_QUICK_BACKEND")) {
    qputenv("QT_QUICK_BACKEND", "software");
  }

  const QGuiApplication application{argc, argv};

  return telar::testing::run(argc, argv);
}
