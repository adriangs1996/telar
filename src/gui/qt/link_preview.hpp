#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <cstddef>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <limits>
#include <optional>
#include <array>
#include "../terminal/cell_position.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <QFont>
#include <QRectF>
#include <QStringList>

#pragma once


import telar.gui.core.metrics;
import telar.gui.links.link_hover;

namespace telar::gui::qt {

struct LinkPreview {
  static constexpr qreal maximum_width = 640;
  static constexpr int maximum_rows = 12;
  static constexpr qreal margin = 8;
  static constexpr qreal padding = 10;
  static constexpr qreal radius = 7;

  QRectF bounds;
  QStringList lines;
  QFont font;
  qreal inset = 0;
  qreal row_height = 0;
  qreal corner_radius = 0;

  [[nodiscard]] static std::optional<LinkPreview> layout(const LinkHit &hit, const TerminalSurface &surface, const QFont &font, qreal chrome_scale);
};

}
