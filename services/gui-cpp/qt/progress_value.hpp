#pragma once

#include "presentation/progress_motion.hpp"
#include <QMetaType>
#include <QTypeInfo>
#include <QVariant>
#include <optional>

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
