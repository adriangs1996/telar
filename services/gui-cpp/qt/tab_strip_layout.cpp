#include "tab_strip_layout.hpp"
#include "chrome_fonts.hpp"
#include "core/metrics.hpp"
#include "presentation/progress_geometry.hpp"
#include "presentation/tab_activity.hpp"
#include "presentation/tab_strip_geometry.hpp"
#include <QAbstractItemModel>
#include <QByteArray>
#include <QFont>
#include <QFontMetricsF>
#include <QList>
#include <QObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QVariant>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <span>
#include <string_view>
#include <utility>

namespace telar::gui::qt {

namespace {

using Geometry = TabStripGeometry;

QVariantMap positionedTab(const QVariantMap &tab, const Geometry::Measure &size, const QRectF &bounds, Geometry::Fit fit, const Geometry::Metrics &metrics) {
  const auto width = static_cast<float>(bounds.width());
  const auto height = static_cast<float>(bounds.height());
  const auto chip_side = std::max(0.0F, std::min(size.chip, width - (2 * metrics.leading)));
  const QRectF chip{metrics.leading, (height - chip_side) / 2, chip_side, chip_side};
  const auto status_right = width - (fit == Geometry::Fit::compact ? metrics.leading : metrics.trailing);
  const auto caption_left = metrics.leading + chip_side + metrics.spacing;
  const auto caption_right = status_right - size.statusSpace(metrics);
  const auto caption_width = std::max(0.0F, caption_right - caption_left);

  return {
      {QStringLiteral("key"), tab.value(QStringLiteral("key"))},
      {QStringLiteral("tab"), tab},
      {QStringLiteral("bounds"), bounds},
      {QStringLiteral("chip"), chip},
      {QStringLiteral("caption"), QRectF{caption_left, 0, caption_width, height}},
      {QStringLiteral("status"), QRectF{status_right - size.status, 0, size.status, bounds.height()}},
      {QStringLiteral("compact"), fit == Geometry::Fit::compact},
      {QStringLiteral("truncated"), fit != Geometry::Fit::compact && size.caption > caption_width},
  };
}

QString hiddenAttention(const QList<QVariantMap> &records, const Geometry::Plan &plan) {
  QString attention;
  for (qsizetype index = 0; index < records.size(); ++index) {
    if (!plan.shows(static_cast<std::size_t>(index))) {
      const auto color = records[index].value(QStringLiteral("attentionColor")).toString();
      if (!color.isEmpty()) {
        attention = color;
      }
    }
  }

  return attention;
}

}

TabStripLayout::TabStripLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

QAbstractItemModel *TabStripLayout::model() const noexcept {
  return model_;
}

QAbstractItemModel *TabStripLayout::items() noexcept {
  return &items_;
}

QFont TabStripLayout::font() const {
  return font_;
}

qreal TabStripLayout::pixelSize() const noexcept {
  return pixel_size_;
}

qreal TabStripLayout::ratio() const noexcept {
  return ratio_;
}

bool TabStripLayout::hovered() const noexcept {
  return hovered_;
}

QRectF TabStripLayout::plus() const noexcept {
  return plus_;
}

QVariantMap TabStripLayout::counter() const {
  return counter_;
}

void TabStripLayout::setModel(QAbstractItemModel *model) {
  if (model_ == model) {
    return;
  }

  for (const auto &connection : connections_) {
    disconnect(connection);
  }

  model_ = model;
  if (model != nullptr) {
    const auto changed = [this] {
      polish();
    };
    connections_ = {
        connect(model, &QAbstractItemModel::dataChanged, this, changed),
        connect(model, &QAbstractItemModel::rowsInserted, this, changed),
        connect(model, &QAbstractItemModel::rowsRemoved, this, changed),
        connect(model, &QAbstractItemModel::rowsMoved, this, changed),
        connect(model, &QAbstractItemModel::modelReset, this, changed),
        connect(model, &QObject::destroyed, this, [this] {
          model_ = nullptr;
          emit modelChanged();
          polish();
        }),
    };
  }

  anchor_.clear();
  emit modelChanged();
  polish();
}

void TabStripLayout::setFont(const QFont &font) {
  if (font_ != font) {
    font_ = font;
    emit fontChanged();
    polish();
  }
}

void TabStripLayout::setPixelSize(qreal size) {
  if (std::isfinite(size) && size > 0 && size <= ChromeMetrics::maximum_text && pixel_size_ != size) {
    pixel_size_ = size;
    emit fontChanged();
    polish();
  }
}

void TabStripLayout::setRatio(qreal ratio) {
  constexpr auto maximum_ratio = std::numeric_limits<float>::max() / Geometry::selected_maximum;
  if (std::isfinite(ratio) && ratio > 0 && ratio <= maximum_ratio && ratio_ != ratio) {
    ratio_ = ratio;
    emit ratioChanged();
    polish();
  }
}

void TabStripLayout::setHovered(bool hovered) {
  if (hovered_ != hovered) {
    hovered_ = hovered;
    emit hoveredChanged();
    polish();
  }
}

QVariantMap TabStripLayout::style() const {
  return {
      {QStringLiteral("pillRadius"), Geometry::pill_radius * ratio_},
      {QStringLiteral("chipRadius"), Geometry::chip_radius * ratio_},
      {QStringLiteral("chipAlpha"), Geometry::chip_alpha},
      {QStringLiteral("selectedChipAlpha"), Geometry::selected_chip_alpha},
      {QStringLiteral("markSide"), Geometry::mark_side * ratio_},
      {QStringLiteral("fadeWidth"), Geometry::fade_width * ratio_},
  };
}

void TabStripLayout::updatePolish() {
  rebuild();
}

void TabStripLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  if (current.size() != previous.size()) {
    polish();
  }
}

void TabStripLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    polish();
  }
}

float TabStripLayout::captionAdvance(const QString &label) {
  const auto requested_size = pixel_size_ > 0 ? pixel_size_ : font_.pixelSize();
  if (requested_size > 0 && font_.family() == QStringLiteral("IBM Plex Sans") && font_.weight() == QFont::Normal && !font_.italic()) {
    try {
      if (!fonts_) {
        fonts_ = ChromeFonts::shared();
      }

      const auto utf8 = label.toUtf8();
      const std::string_view text{utf8.constData(), static_cast<std::size_t>(utf8.size())};
      if (fonts_->covers(text, false)) {
        const auto display_scale = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
        const auto pixel_height = static_cast<std::uint16_t>(std::clamp(std::round(static_cast<float>(requested_size * display_scale)), 1.0F, ChromeMetrics::maximum_text));
        const auto shaped = fonts_->face(false).shape(text, pixel_height);

        return static_cast<float>(shaped.advance() / display_scale);
      }
    } catch (const std::exception &) {
      fonts_.reset();
    }
  }

  return static_cast<float>(QFontMetricsF{font_}.horizontalAdvance(label));
}

void TabStripLayout::rebuild() {
  if (width() <= 0 || height() <= 0 || !std::isfinite(width()) || !std::isfinite(height()) || width() > std::numeric_limits<float>::max() || height() > std::numeric_limits<float>::max()) {
    plus_ = {};
    counter_.clear();
    items_.reconcile({});
    emit layoutChanged();

    return;
  }

  const auto ratio = static_cast<float>(ratio_);
  const auto metrics = Geometry::Metrics::scaled(ratio);
  const auto available = static_cast<float>(width());
  const auto height = std::min(static_cast<float>(this->height()), Geometry::pill_height * ratio);
  const auto top = std::floor((static_cast<float>(this->height()) - height) / 2);
  const auto plus_side = std::min(Geometry::plus_side * ratio, available);
  const auto count = model_ == nullptr ? 0 : std::clamp(model_->rowCount(), 0, static_cast<int>(Geometry::maximum_tabs));
  QList<QVariantMap> records;
  std::array<Geometry::Measure, Geometry::maximum_tabs> sizes;
  std::size_t active = 0;
  std::size_t focus = 0;
  bool anchored = false;
  for (int index = 0; index < count; ++index) {
    auto record = model_->data(model_->index(index, 0), ListModel::record_role).toMap();
    record.insert(QStringLiteral("number"), index + 1);
    const auto slot = static_cast<std::size_t>(index);
    const auto kind = record.value(QStringLiteral("activityKind")).toInt();
    const auto status_width = kind == static_cast<int>(TabActivity::Kind::progress) ? ProgressGeometry::compactWidth(ratio) : record.value(QStringLiteral("statusWidth")).toFloat() * ratio;
    sizes[slot] = {.caption = captionAdvance(record.value(QStringLiteral("label")).toString()), .chip = Geometry::chip_side * ratio, .status = status_width};
    if (record.value(QStringLiteral("selected")).toBool()) {
      active = slot;
    }

    if (record.value(QStringLiteral("key")).toString() == anchor_) {
      focus = slot;
      anchored = true;
    }

    records.append(std::move(record));
  }

  if (!hovered_ || !anchored) {
    focus = active;
  }

  const Geometry::Room room{.width = std::max(0.0F, available - plus_side - metrics.gap), .metrics = metrics};
  const auto measured = std::span{sizes}.first(static_cast<std::size_t>(count));
  auto plan = Geometry::arrange(measured, focus, room);
  if (count != 0 && !plan.shows(active)) {
    plan = Geometry::arrange(measured, active, room);
  }

  QList<QVariantMap> positioned;
  float left = 0;
  for (auto index = plan.first; index < plan.end; ++index) {
    if (index != plan.first) {
      left += metrics.gap;
    }

    const QRectF bounds{left, top, plan.widths[index], height};
    positioned.append(positionedTab(records[static_cast<qsizetype>(index)], sizes[index], bounds, plan.fits[index], metrics));
    left += plan.widths[index];
  }

  counter_.clear();
  if (const auto nearest = plan.nearestHidden()) {
    left += metrics.gap;
    const auto counter_width = std::min(metrics.counter, std::max(0.0F, available - left));
    const auto attention = hiddenAttention(records, plan);

    counter_ = {
        {QStringLiteral("bounds"), QRectF{left, top, counter_width, height}},
        {QStringLiteral("count"), static_cast<qulonglong>(plan.hidden())},
        {QStringLiteral("attentionColor"), attention},
        {QStringLiteral("key"), records[static_cast<qsizetype>(*nearest)].value(QStringLiteral("key"))},
    };
    left += counter_width;
  }

  if (count != 0) {
    left += metrics.gap;
    anchor_ = records[static_cast<qsizetype>(plan.focus)].value(QStringLiteral("key")).toString();
  }

  plus_ = plus_side > 0 && height > 0 && left + plus_side <= available ? QRectF{left, top, plus_side, height} : QRectF{};
  items_.reconcile(std::move(positioned));
  emit layoutChanged();
}

}
