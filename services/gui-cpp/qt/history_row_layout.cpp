#include "history_row_layout.hpp"
#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "presentation/history_card.hpp"
#include "presentation/history_command_line.hpp"
#include "presentation/history_match_highlight.hpp"
#include "presentation/history_row_geometry.hpp"
#include "text/cell_text_measure.hpp"
#include <QByteArray>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>

namespace telar::gui::qt {

HistoryRowLayout::HistoryRowLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

QVariantMap HistoryRowLayout::measurements() const {
  return measurements_;
}

void HistoryRowLayout::setMeasurements(const QVariantMap &measurements) {
  if (measurements_ != measurements) {
    measurements_ = measurements;
    measurements_dirty_ = true;
    emit measurementsChanged();
    polish();
  }
}

QRectF HistoryRowLayout::logical(Rect area) const noexcept {
  return {area.x / density_, area.y / density_, area.width / density_, area.height / density_};
}

QVariantMap HistoryRowLayout::layout() const {
  return {
      {QStringLiteral("frame"), logical(geometry_.frame)},
      {QStringLiteral("status"), logical(geometry_.status)},
      {QStringLiteral("command"), logical(geometry_.command)},
      {QStringLiteral("provider"), logical(geometry_.provider)},
      {QStringLiteral("cwd"), logical(geometry_.cwd)},
      {QStringLiteral("time"), logical(geometry_.time)},
      {QStringLiteral("radius"), HistoryRowGeometry::corner_radius * ratio_},
      {QStringLiteral("stroke"), ratio_},
      {QStringLiteral("needed"), command_width_ / density_},
      {QStringLiteral("providerRadius"), HistoryRowGeometry::provider_radius * ratio_},
      {QStringLiteral("selectionTintAlpha"), HistoryRowGeometry::selection_tint_alpha},
      {QStringLiteral("selectionRingAlpha"), HistoryRowGeometry::selection_ring_alpha},
      {QStringLiteral("hoverAlpha"), HistoryRowGeometry::hover_alpha},
      {QStringLiteral("cwdAlpha"), HistoryRowGeometry::cwd_alpha},
      {QStringLiteral("cardHeight"), card_.height / density_},
      {QStringLiteral("meta"), logical(card_.meta)},
      {QStringLiteral("more"), card_.more},
      {QStringLiteral("moreBound"), HistoryCard::more_bound},
      {QStringLiteral("lines"), commandLines()},
  };
}

void HistoryRowLayout::setHistoryIndex(int index) {
  if (history_index_ != index) {
    history_index_ = index;
    emit historyIndexChanged();
  }
}

Rect HistoryRowLayout::physicalFrame() const noexcept {
  return geometry_.frame;
}

QVariantMap HistoryRowLayout::commandLine(std::string_view text, Rect bounds, bool continues, HistoryMatchHighlight &highlight) const {
  const auto needed = static_cast<float>(cellTextColumns(text)) * cell_width_;
  const auto line = HistoryCommandLine::derive(bounds, {.needed = needed, .cell_width = cell_width_, .continues = continues});
  QVariantList matches;
  auto record = [&](Rect area, std::string_view cluster) {
    matches.append(QVariantMap{
        {QStringLiteral("bounds"), logical(area)},
        {QStringLiteral("text"), QString::fromUtf8(cluster.data(), static_cast<qsizetype>(cluster.size()))},
    });
  };
  highlight.paint(text, line.text, cell_width_, record);

  return {
      {QStringLiteral("text"), QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()))},
      {QStringLiteral("bounds"), logical(line.text)},
      {QStringLiteral("markerBounds"), logical(line.marker)},
      {QStringLiteral("marker"), QString::fromUtf8(line.mark.data(), static_cast<qsizetype>(line.mark.size()))},
      {QStringLiteral("matches"), matches},
  };
}

QVariantList HistoryRowLayout::commandLines() const {
  const auto query = measurements_.value(QStringLiteral("query")).toString().toUtf8();
  HistoryMatchHighlight highlight{{query.constData(), static_cast<std::size_t>(query.size())}};
  QVariantList result;
  if (!expanded_) {
    const std::string_view text{command_bytes_.constData(), static_cast<std::size_t>(command_bytes_.size())};
    const auto end = text.find_first_of("\r\n");
    result.append(commandLine(text.substr(0, end), geometry_.command, end != std::string_view::npos, highlight));

    return result;
  }

  for (std::uint16_t index = 0; index < card_.shown; ++index) {
    const Rect area{.x = geometry_.command.x, .y = card_.text_y + (static_cast<float>(index) * cell_height_), .width = geometry_.command.width, .height = cell_height_};
    result.append(commandLine(card_.lines[index], area, false, highlight));
  }

  return result;
}

void HistoryRowLayout::prepareCommand() {
  const auto text = measurements_.value(QStringLiteral("commandText")).toString();
  if (command_text_ != text) {
    command_text_ = text;
    command_bytes_ = text.toUtf8();
    const std::string_view bytes{command_bytes_.constData(), static_cast<std::size_t>(command_bytes_.size())};
    first_line_columns_ = cellTextColumns(bytes.substr(0, bytes.find_first_of("\r\n")));
  }
}

void HistoryRowLayout::updatePolish() {
  const auto density = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
  const auto advance = [&](const QString &name) {
    const auto value = measurements_.value(name).toDouble();

    return std::isfinite(value) && value > 0 ? static_cast<float>(value * density) : 0;
  };
  const auto ratio = measurements_.value(QStringLiteral("ratio"), 1).toDouble();
  if (!std::isfinite(ratio) || ratio <= 0) {
    return;
  }

  ChromeMetrics chrome;
  chrome.ratio = static_cast<float>(ratio * density);
  chrome.small = static_cast<std::uint16_t>(std::clamp(std::round(advance(QStringLiteral("smallPixels"))), 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
  prepareCommand();
  const auto cell_width = std::max(1.0F, std::round(advance(QStringLiteral("cellWidth"))));
  const auto cell_height = std::max(1.0F, std::round(advance(QStringLiteral("cellHeight"))));
  const auto command_width = static_cast<float>(first_line_columns_) * cell_width;
  const HistoryRowMeasurements measured{
      .command = command_width,
      .cwd = advance(QStringLiteral("cwd")),
      .time = advance(QStringLiteral("time")),
      .agent = measurements_.value(QStringLiteral("agent")).toBool(),
      .show_cwd = measurements_.value(QStringLiteral("showCwd")).toBool(),
      .has_cwd = measurements_.value(QStringLiteral("hasCwd")).toBool(),
      .has_time = measurements_.value(QStringLiteral("hasTime")).toBool(),
      .expanded = measurements_.value(QStringLiteral("expanded")).toBool(),
  };
  const auto row_height = advance(QStringLiteral("rowHeight"));
  const auto geometry = HistoryRowGeometry::derive({.width = static_cast<float>(width() * density), .height = static_cast<float>(height() * density)}, chrome, row_height, measured);
  if (geometry != geometry_ || density != density_ || ratio != ratio_ || command_width != command_width_ || measurements_dirty_) {
    geometry_ = geometry;
    density_ = density;
    ratio_ = ratio;
    command_width_ = command_width;
    cell_width_ = cell_width;
    cell_height_ = cell_height;
    expanded_ = measured.expanded;
    card_ = expanded_ ? HistoryCard::measure(geometry_, chrome, {.cell_width = cell_width, .cell_height = cell_height, .row_height = row_height, .viewport_height = advance(QStringLiteral("viewportHeight"))}, {command_bytes_.constData(), static_cast<std::size_t>(command_bytes_.size())}) : HistoryCard{};
    if (expanded_) {
      const auto raw_open = measurements_.value(QStringLiteral("open"), 1).toFloat();
      const auto open = std::isfinite(raw_open) ? std::clamp(raw_open, 0.0F, 1.0F) : 0.0F;
      const auto delta = std::max(0.0F, card_.intrinsic_height - row_height) * open;
      const auto opened = std::round(row_height + delta);
      const auto viewport_height = advance(QStringLiteral("viewportHeight"));
      const auto tallest = std::max(row_height, viewport_height - chrome.px(HistoryCard::viewport_clearance));
      card_.height = viewport_height > 0 ? std::min(tallest, opened) : opened;
    }

    measurements_dirty_ = false;
    emit layoutChanged();
  }
}

void HistoryRowLayout::componentComplete() {
  QQuickItem::componentComplete();
  updatePolish();
}

void HistoryRowLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  polish();
}

void HistoryRowLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    polish();
  }
}

}
