#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QMetaType>
#include <QTypeInfo>
#include <QVariant>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <variant>

#pragma once

import telar.gui.presentation.frame_pacer;

Q_DECLARE_METATYPE(telar::gui::PaneAttentionKey)
Q_DECLARE_TYPEINFO(telar::gui::PaneAttentionKey, Q_RELOCATABLE_TYPE);

namespace telar::gui::qt {

  inline QVariant paneAttentionValue(PaneAttentionKey key) {
    return QVariant::fromValue(key);
  }

  inline std::optional<PaneAttentionKey> paneAttentionKey(const QVariant& value) {
    return value.canConvert<PaneAttentionKey>() ? std::optional{value.value<PaneAttentionKey>()} : std::nullopt;
  }

}
