#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <algorithm>
#include <cmath>
#include "telar_client/serializers/telar_protocol.hpp"
#include <QVariantMap>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>

#pragma once


import telar.gui.presentation.activity_order;

namespace telar::gui::qt {

inline QVariantMap paneChromeStyle(qreal ratio, qreal density) {
  return {
      {QStringLiteral("chipInset"), PaneStatusChip::inset * ratio},
      {QStringLiteral("chipHeight"), PaneStatusChip::height * ratio},
      {QStringLiteral("chipRadius"), PaneStatusChip::radius * ratio},
      {QStringLiteral("progressPadding"), ProgressGeometry::padding * ratio},
      {QStringLiteral("progressSide"), ProgressGeometry::ring_side * ratio},
      {QStringLiteral("progressHeight"), ProgressGeometry::height * ratio},
      {QStringLiteral("progressInset"), ProgressGeometry::ring_inset * ratio},
      {QStringLiteral("density"), density},
  };
}

}
