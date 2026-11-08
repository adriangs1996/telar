#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>
#include <QMetaType>
#include <QTypeInfo>
#include <QVariant>

#pragma once

import telar.gui.presentation.display_metrics;

Q_DECLARE_METATYPE(telar::gui::ProgressSample)
Q_DECLARE_TYPEINFO(telar::gui::ProgressSample, Q_RELOCATABLE_TYPE);



namespace telar::gui::qt {

inline QVariant progressValue(ProgressSample sample) {
  return QVariant::fromValue(sample);
}

inline std::optional<ProgressSample> progressSample(const QVariant &value) {
  return value.canConvert<ProgressSample>() ? std::optional{value.value<ProgressSample>()} : std::nullopt;
}

}
