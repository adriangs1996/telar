#pragma once

#include "presentation/attention_fades.hpp"
#include <QMetaType>
#include <QTypeInfo>
#include <QVariant>
#include <optional>

Q_DECLARE_METATYPE(telar::gui::PaneAttentionKey)
Q_DECLARE_TYPEINFO(telar::gui::PaneAttentionKey, Q_RELOCATABLE_TYPE);

namespace telar::gui::qt {

inline QVariant paneAttentionValue(PaneAttentionKey key) {
  return QVariant::fromValue(key);
}

inline std::optional<PaneAttentionKey> paneAttentionKey(const QVariant &value) {
  return value.canConvert<PaneAttentionKey>() ? std::optional{value.value<PaneAttentionKey>()} : std::nullopt;
}

}
