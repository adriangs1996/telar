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

  // What git says of a path, as the letter a row shows at its end and the role of the window's
  // colors it is drawn in; no letter for a path as committed.
  inline void putChange(QVariantMap& record, PathChange change) {
    struct Mark {
      const char* letter;
      const char* tone;
    };

    const auto mark = [&] -> Mark {
      switch (change) {
      case PathChange::modified:
        return {.letter = "M", .tone = "yellow"};
      case PathChange::added:
        return {.letter = "A", .tone = "green"};
      case PathChange::deleted:
        return {.letter = "D", .tone = "red"};
      case PathChange::renamed:
        return {.letter = "R", .tone = "blue"};
      // A file git does not hold yet is common, and asks for nothing: quiet, as the name's
      // directory.
      case PathChange::untracked:
        return {.letter = "U", .tone = "overlay1"};
      case PathChange::conflicted:
        return {.letter = "!", .tone = "red"};
      case PathChange::none:
        break;
      }

      return {.letter = "", .tone = ""};
    }();

    if (*mark.letter != 0) {
      record.insert(QStringLiteral("badge"), QString::fromLatin1(mark.letter));
      record.insert(QStringLiteral("badgeTone"), QString::fromLatin1(mark.tone));
    }
  }

}
