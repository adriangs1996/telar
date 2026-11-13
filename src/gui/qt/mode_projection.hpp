#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "projection.hpp"
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qvariant.h>
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <tuple>
#include <utility>

#pragma once

import telar.gui.input.key_encoder;
import telar.gui.presentation.history_inspection;

namespace telar::gui::qt {

  inline QVariantMap statusModeRecord(StatusMode mode, const ModeHints& hints = {}) {
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
