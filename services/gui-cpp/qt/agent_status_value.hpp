#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <QMetaType>
#include <QTypeInfo>
#include <QVariant>
#include <optional>

#pragma once

import telar.gui.presentation.application_mark;

Q_DECLARE_METATYPE(telar::gui::StatusAgeInterval)
Q_DECLARE_TYPEINFO(telar::gui::StatusAgeInterval, Q_RELOCATABLE_TYPE);



namespace telar::gui::qt {

inline QVariant statusAgeValue(StatusAgeInterval interval) {
  return QVariant::fromValue(interval);
}

inline std::optional<StatusAgeInterval> statusAgeInterval(const QVariant &value) {
  return value.canConvert<StatusAgeInterval>() ? std::optional{value.value<StatusAgeInterval>()} : std::nullopt;
}

}
