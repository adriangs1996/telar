#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/models/projection.hpp"
#include <QVariantMap>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>

#pragma once

import telar.gui.core.metrics;
import telar.gui.presentation.display_metrics;

namespace telar::gui::qt {

  inline QVariantMap chromeTypographyRecord(const DisplayMetrics& display, const FontConfiguration& font) {
    const auto& chrome = display.chrome;
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
