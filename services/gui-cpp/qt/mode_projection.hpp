#pragma once

#include "input/binding.hpp"
#include "presentation/mode_hints.hpp"
#include "projection.hpp"
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qvariant.h>

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
