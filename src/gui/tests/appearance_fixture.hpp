#pragma once

#include <QGuiApplication>
#include <QStyleHints>
#include <QtCore/qnamespace.h>

namespace telar::gui::test {

class AppearanceFixture {
public:
  AppearanceFixture()
      : original_(QGuiApplication::styleHints()->colorScheme()) {}

  ~AppearanceFixture() {
    set(original_);
  }

  AppearanceFixture(const AppearanceFixture &) = delete;
  AppearanceFixture &operator=(const AppearanceFixture &) = delete;
  AppearanceFixture(AppearanceFixture &&) = delete;
  AppearanceFixture &operator=(AppearanceFixture &&) = delete;

  static void set(Qt::ColorScheme scheme) {
    QGuiApplication::styleHints()->colorSchemeChanged(scheme);
  }

private:
  Qt::ColorScheme original_;
};

}
