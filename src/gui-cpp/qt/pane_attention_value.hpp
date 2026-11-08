#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include <QMetaType>
#include <QTypeInfo>
#include <QVariant>

#pragma once

import telar.gui.presentation.frame_pacer;

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
