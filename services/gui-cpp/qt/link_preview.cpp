#include "link_preview.hpp"
#include "core/terminal_surface.hpp"
#include "links/link_hit.hpp"
#include "projection.hpp"
#include <QFontMetricsF>
#include <QPointF>
#include <QTextLayout>
#include <QTextOption>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cmath>
#include <optional>
#include <utility>

namespace telar::gui::qt {

std::optional<LinkPreview> LinkPreview::layout(const LinkHit &hit, const TerminalSurface &surface, const QFont &font, qreal chrome_scale) {
  if (surface.cell.x <= 0 || surface.cell.y <= 0 || !std::isfinite(chrome_scale) || chrome_scale <= 0) {
    return {};
  }

  const auto gap = margin * chrome_scale;
  const auto pad = padding * chrome_scale;
  const auto available = std::min(maximum_width * chrome_scale, surface.content.width - (2 * gap));
  const auto room = std::floor((surface.content.height - (2 * gap) - (2 * pad)) / surface.cell.y);
  if (available < (2 * pad) + surface.cell.x || room < 1) {
    return {};
  }

  const auto rows = static_cast<int>(std::min(qreal{maximum_rows}, room));
  QTextLayout text{toQString(hit.match.target.text()), font};
  QTextOption options;
  options.setWrapMode(QTextOption::WrapAnywhere);
  options.setTextDirection(Qt::LeftToRight);
  text.setTextOption(options);
  text.beginLayout();
  QStringList lines;
  auto widest = qreal{0};
  bool clipped = false;
  while (true) {
    auto line = text.createLine();
    if (!line.isValid()) {
      break;
    }

    line.setLineWidth(available - (2 * pad));
    if (lines.size() == rows) {
      clipped = true;
      break;
    }

    widest = std::max(widest, line.naturalTextWidth());
    lines.append(text.text().mid(line.textStart(), line.textLength()));
  }

  text.endLayout();
  if (clipped) {
    constexpr char16_t ellipsis = u'\u2026';
    const QFontMetricsF metrics{font};
    lines.back() = metrics.elidedText(lines.back() + QChar{ellipsis}, Qt::ElideRight, available - (2 * pad));
  }

  const auto width = lines.size() > 1 || clipped ? available : std::min(available, (2 * pad) + widest);
  const auto height = (2 * pad) + (static_cast<qreal>(lines.size()) * surface.cell.y);
  const auto anchor_x = hit.area.x - surface.content.x;
  const auto anchor_y = hit.area.y - surface.content.y;
  const auto above = anchor_y - gap - height;
  const auto y = std::clamp(above >= 0 ? above : anchor_y + hit.area.height + gap, qreal{0}, std::max(qreal{0}, surface.content.height - height));
  const auto x = std::clamp(qreal{anchor_x}, gap, std::max(gap, surface.content.width - gap - width));

  return LinkPreview{.bounds = {x, y, width, height}, .lines = std::move(lines), .font = font, .inset = pad, .row_height = surface.cell.y, .corner_radius = radius * chrome_scale};
}

}
