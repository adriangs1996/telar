#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <algorithm>
#include <array>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <tuple>
#include <optional>
#include <string_view>
#include <utility>
#include <concepts>
#include "projection.hpp"
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qvariant.h>

#pragma once


import telar.gui.input.key_encoder;
import telar.gui.presentation.history_inspection;

namespace telar::gui::qt {

inline QVariantMap statusModeRecord(StatusMode mode, const ModeHints &hints = {}) {
  QVariantList records;
  for (const auto &hint : hints.items()) {
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
