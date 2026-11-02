#pragma once

#include "core/terminal_surface.hpp"

#include "links/link_hit.hpp"
#include <QFont>
#include <QRectF>
#include <QStringList>
#include <optional>

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
