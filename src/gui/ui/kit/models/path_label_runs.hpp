#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/models/projection.hpp"
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <cstdint>
#include <span>
#include <string_view>

#pragma once

import telar.gui.application;

namespace telar::gui::qt {

  // The color a part of a path's label is drawn in, as a role of the window's colors.
  [[nodiscard]] inline QString pathRunColor(application::paths::PathLabelTone tone) {
    switch (tone) {
    case application::paths::PathLabelTone::match:
      return QStringLiteral("accent");
    case application::paths::PathLabelTone::name:
      return QStringLiteral("text");
    case application::paths::PathLabelTone::directory:
    case application::paths::PathLabelTone::ellipsis:
      return QStringLiteral("subtext0");
    }

    return QStringLiteral("subtext0");
  }

  // A path as every picker of the window shows it: its directory quiet, its name plain, the
  // characters the query matched marked, cut to `width` cells. Each run is {text, colorRole,
  // bold}; the terminal's path picker and the editor's draw the same ones.
  [[nodiscard]] inline QVariantList pathLabelRuns(std::string_view path, std::span<const std::uint16_t> positions, std::uint16_t width) {
    application::paths::PathLabel label;
    QVariantList runs;

    label.layout(path, positions, width);
    runs.reserve(static_cast<qsizetype>(label.runs().size()));
    for (const auto& run : label.runs()) {
      runs.append(QVariantMap{{QStringLiteral("text"), toQString(run.text)}, {QStringLiteral("colorRole"), pathRunColor(run.tone)}, {QStringLiteral("bold"), run.tone == application::paths::PathLabelTone::match}});
    }

    return runs;
  }

}
