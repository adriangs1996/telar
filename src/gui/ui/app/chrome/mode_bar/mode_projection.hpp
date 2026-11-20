#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/models/projection.hpp"
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qvariant.h>
#include <string_view>

#pragma once

import telar.gui.application;

namespace telar::gui::qt {

  inline QVariantMap statusModeRecord(application::status_bar::StatusMode mode, const application::status_bar::ModeHints& hints = {}) {
    QVariantList records;

    for (const auto& hint : hints.items()) {
      records.append(QVariantMap{
          {QStringLiteral("key"), static_cast<int>(hint.key.key)},
          {QStringLiteral("character"), hint.key.character},
          {QStringLiteral("modifiers"), hint.key.modifiers},
          {QStringLiteral("label"), toQString(hint.label)},
      });
    }

    return {{QStringLiteral("kind"), static_cast<int>(mode)}, {QStringLiteral("hints"), records}};
  }

}
