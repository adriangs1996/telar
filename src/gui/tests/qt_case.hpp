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
#include <cstddef>
#include <string_view>

import telar.testing;
import telar.base.ds;

namespace telar::gui::test {

  // A slot name as a template argument.
  template <std::size_t length>
  struct Slot {
    // Implicit and from the literal's array, so that a slot name deduces from a string literal.
    consteval Slot(const char (&name)[length]) noexcept { // NOLINT(cppcoreguidelines-explicit-constructor,misc-explicit-constructor,cppcoreguidelines-avoid-c-arrays,modernize-avoid-c-arrays): a string literal binds only to an array reference.
      for (std::size_t index = 0; index < length; ++index) {
        text.atMut(index) = name[index];
      }
    }

    ds::Array<char, length> text{};
  };

  template <typename Test, Slot slot>
  class QtCase {
  public:
    // From a literal, which telar::testing::Case takes without a constructor that may throw.
    template <std::size_t Size>
    explicit QtCase(const char (&name)[Size]) noexcept // NOLINT(cppcoreguidelines-avoid-c-arrays,modernize-avoid-c-arrays): a string literal binds only to an array reference.
        : case_{name, run} {}

  private:
    static void run() {
      Test test;
      const QStringList arguments{QStringLiteral("qt-case"), QString::fromLatin1(slot.text.data())};

      telar::testing::check(QTest::qExec(&test, arguments) == 0, slot.text.data());
    }

    telar::testing::Case case_;
  };

}
