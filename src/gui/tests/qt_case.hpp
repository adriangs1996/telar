#pragma once

// A slot of a QtTest class as a case of telar::testing, so that CTest runs each slot as a test
// of its own while the slot keeps QVERIFY, QCOMPARE and its initTestCase:
//
//   const telar::gui::test::QtCase<ChromeIconTest, "symbolsFallbackKeepsOriginalCoverage">
//       case_symbols{"chrome_icon.symbols_fallback"};
//
// The program links gui-testing-main, whose QGuiApplication the slot runs in.
#include <QObject>
#include <QString>
#include <QStringList>
#include <QtTest/QTest>
#include <algorithm>
#include <cstddef>
#include <string_view>

import telar.testing;

namespace telar::gui::test {

  // A slot name as a template argument.
  template <std::size_t length>
  struct Slot {
    consteval Slot(const char (&name)[length]) noexcept {
      std::copy_n(name, length, text);
    }

    char text[length]{};
  };

  template <typename Test, Slot slot>
  class QtCase {
  public:
    explicit QtCase(std::string_view name) noexcept
        : case_{name, run} {}

  private:
    static void run() {
      Test test;
      const QStringList arguments{QStringLiteral("qt-case"), QString::fromLatin1(slot.text)};

      telar::testing::check(QTest::qExec(&test, arguments) == 0, slot.text);
    }

    telar::testing::Case case_;
  };

}
