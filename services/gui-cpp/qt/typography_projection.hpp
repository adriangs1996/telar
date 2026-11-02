#pragma once

#include "core/configuration.hpp"
#include "core/metrics.hpp"
#include "presentation/display_metrics.hpp"
#include "projection.hpp"
#include <QVariantMap>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>

namespace telar::gui::qt {

inline QVariantMap chromeTypographyRecord(const DisplayMetrics &display, const FontConfiguration &font) {
  const auto &chrome = display.chrome;
  const auto density = display.density;
  return {
      {QStringLiteral("body"), chrome.body / density},
      {QStringLiteral("small"), chrome.small / density},
      {QStringLiteral("title"), chrome.title / density},
      {QStringLiteral("bodyRow"), ChromeMetrics::lineHeight(chrome.body) / density},
      {QStringLiteral("smallRow"), ChromeMetrics::lineHeight(chrome.small) / density},
      {QStringLiteral("primaryFamily"), toQString(font.family.view())},
      {QStringLiteral("primaryStyle"), toQString(font.style.view())},
  };
}

}
