#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tab_strip_layout.hpp"
#include "chrome_fonts.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include "../core/terminal_size.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <span>
#include <limits>
#include "list_model.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <exception>
#include "telar_config/graphics/limits.hpp"
#include <concepts>
#include <utility>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <stdexcept>
#include <tuple>
#include <charconv>
#include <cstring>
#include <system_error>
#include "window_animation_clock.hpp"
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



import telar.gui.core.metrics;
import telar.gui.input.child_mouse;
import telar.gui.presentation.activity_order;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

namespace {

using Geometry = TabStripGeometry;

void previewOrder(std::span<std::size_t> order, const QList<QVariantMap> &records, const TabDragMove &move) {
  const auto id_at = [&](std::size_t index) {
    return records[static_cast<qsizetype>(index)].value(QStringLiteral("key")).toString().toULongLong();
  };
  const auto source = std::ranges::find(order, move.location.tab_id, id_at);
  const auto anchor = move.relative_to ? std::ranges::find(order, *move.relative_to, id_at) : order.end();
  if (source == order.end() || anchor == order.end() || source == anchor) {
    return;
  }

  const auto from = source - order.begin();
  const auto insertion = (anchor - order.begin()) + (move.direction == TabMoveDirection::next ? 1 : 0);
  const auto destination = insertion - (from < insertion ? 1 : 0);
  if (from < destination) {
    std::rotate(order.begin() + from, order.begin() + from + 1, order.begin() + destination + 1);
  } else {
    std::rotate(order.begin() + destination, order.begin() + from, order.begin() + from + 1);
  }
}

QVariantMap positionedTab(const QVariantMap &tab, const Geometry::Measure &size, const QRectF &bounds, Geometry::Fit fit, const Geometry::Metrics &metrics) {
  const auto width = static_cast<float>(bounds.width());
  const auto height = static_cast<float>(bounds.height());
  const auto chip_side = std::max(0.0F, std::min(size.chip, width - (2 * metrics.leading)));
  const QRectF chip{metrics.leading, 0, chip_side, height};
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
    : QQuickItem(parent) {
  bindClock();
}

TabStripLayout::~TabStripLayout() {
  QObject::disconnect(frame_connection_);
  if (!clock_.isNull()) {
    clock_->detach(*this);
  }
}

QString TabStripLayout::hoveredTab() const {
  return hovered_tab_ ? QString::number(*hovered_tab_) : QString{};
}

void TabStripLayout::setPointerHover(std::optional<std::uint64_t> tab) {
  if (hovered_tab_ != tab) {
    hovered_tab_ = tab;
    emit pointerHoverChanged();
  }
}

void TabStripLayout::setContext(std::uint64_t machine_view, std::optional<WorkspaceLocation> workspace) {
  const auto same_workspace = workspace_.has_value() == workspace.has_value() && (!workspace_ || (workspace_->kind == workspace->kind && workspace_->id == workspace->id));
  if (machine_view_ == machine_view && same_workspace) {
    return;
  }
  setPointerHover(std::nullopt);
  machine_view_ = machine_view;
  workspace_ = workspace;
  anchor_.clear();
  motions_ = {};
  selection_motion_.reset();
  next_sample_ns_.reset();
  drag_preview_.reset();
  dragged_.reset();
  drop_marker_ = {};
  dragged_bounds_ = {};
  polish();
}

bool TabStripLayout::eligible() const noexcept {
  return isVisible() && width() > 0 && height() > 0;
}

std::optional<std::uint64_t> TabStripLayout::deadline([[maybe_unused]] std::uint64_t now_ns) const noexcept {
  return frame_requested_ ? std::nullopt : next_sample_ns_;
}

void TabStripLayout::sample(std::uint64_t now_ns) {
  if (!frame_requested_ && next_sample_ns_ && now_ns >= *next_sample_ns_) {
    frame_requested_ = true;
    polish();
    if (auto *view = window()) {
      view->update();
    }
  }
}

void TabStripLayout::bindClock() {
  QObject::disconnect(frame_connection_);
  if (!clock_.isNull()) {
    clock_->detach(*this);
  }
  clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
  if (!clock_.isNull()) {
    clock_->attach(*this);
    frame_connection_ = connect(window(), &QQuickWindow::afterAnimating, this, [this] {
      // Queue the sample before this frame's polish pass. A deadline timer
      // waking after polish can skip the next display refresh.
      if (eligible() && next_sample_ns_) {
        frame_requested_ = true;
        polish();
      }
    });
  }
}

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

QRectF TabStripLayout::dropMarker() const noexcept {
  return drop_marker_;
}

QRectF TabStripLayout::draggedBounds() const noexcept {
  return dragged_bounds_;
}

std::size_t TabStripLayout::dropSlots(std::span<TabDropSlot> output) const {
  if (!isVisible() || window() == nullptr) {
    return 0;
  }

  const auto origin = mapToScene(QPointF{});
  const auto scale = window()->effectiveDevicePixelRatio();
  const auto count = std::min(drop_slot_count_, output.size());
  for (std::size_t index = 0; index < count; ++index) {
    const auto &slot = drop_slots_[index];
    output[index] = {.id = slot.id, .bounds = {.x = static_cast<float>((origin.x() + slot.bounds.x) * scale), .y = static_cast<float>((origin.y() + slot.bounds.y) * scale), .width = static_cast<float>(slot.bounds.width * scale), .height = static_cast<float>(slot.bounds.height * scale)}};
  }

  return count;
}

void TabStripLayout::setDrag(std::optional<TabDragMove> preview, std::optional<std::uint64_t> dragged, QPointF pointer, qreal grab_offset) {
  if (preview && (!workspace_ || workspace_->kind != preview->location.workspace.kind || workspace_->id != preview->location.workspace.id)) {
    preview.reset();
  }

  drag_preview_ = preview;
  dragged_ = dragged;
  drag_pointer_ = mapFromScene(pointer);
  drag_grab_offset_ = grab_offset;
  polish();
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
  selection_motion_.reset();
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

QRectF TabStripLayout::plus() const noexcept {
  return plus_;
}

void TabStripLayout::setPlus(const QRectF &plus) {
  if (plus_ != plus) {
    plus_ = plus;
    emit plusChanged();
  }
}

QVariantMap TabStripLayout::style() const {
  return {
      {QStringLiteral("pillRadius"), Geometry::pill_radius * ratio_},
      {QStringLiteral("tileWidth"), Geometry::tile_width * ratio_},
      {QStringLiteral("tileHeight"), Geometry::tile_height * ratio_},
      {QStringLiteral("tileRadius"), Geometry::tile_radius * ratio_},
      {QStringLiteral("pathGap"), Geometry::path_gap * ratio_},
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
  if (change == ItemSceneChange) {
    bindClock();
  }
  if (change == ItemVisibleHasChanged) {
    frame_requested_ = false;
    if (!clock_.isNull()) {
      clock_->requestSynchronization();
    }
    if (isVisible()) {
      polish();
      if (auto *view = window()) {
        view->update();
      }
    }
  }
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

TabStripGeometry::Plan TabStripLayout::measureTabs(QList<QVariantMap> &records, std::span<TabStripGeometry::Measure> sizes, const TabStripGeometry::Room &room) {
  const auto ratio = static_cast<float>(ratio_);
  const auto count = model_ == nullptr ? 0 : std::clamp(model_->rowCount(), 0, static_cast<int>(Geometry::maximum_tabs));
  std::size_t active = 0;
  std::size_t focus = 0;
  bool anchored = false;
  for (int index = 0; index < count; ++index) {
    auto record = model_->data(model_->index(index, 0), ListModel::record_role).toMap();
    record.insert(QStringLiteral("number"), index + 1);
    const auto slot = static_cast<std::size_t>(index);
    const auto kind = record.value(QStringLiteral("activityKind")).toInt();
    const auto status_width = kind == static_cast<int>(TabActivity::Kind::progress) ? ProgressGeometry::compactWidth(ratio) : record.value(QStringLiteral("statusWidth")).toFloat() * ratio;
    const auto title = record.value(QStringLiteral("title"), record.value(QStringLiteral("label"))).toString();
    const auto path = record.value(QStringLiteral("path")).toString();
    const auto stacked = std::min(static_cast<std::size_t>(std::max<qsizetype>(record.value(QStringLiteral("cards")).toList().size(), 1)), Geometry::chip_widths.size());
    const auto caption = captionAdvance(title) + (path.isEmpty() ? 0 : (Geometry::path_gap * ratio) + captionAdvance(path));
    sizes[slot] = {.caption = caption, .chip = Geometry::chip_widths[stacked - 1] * ratio, .status = status_width};
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

  const auto measured = std::span{sizes}.first(static_cast<std::size_t>(count));
  auto plan = Geometry::arrange(measured, focus, room);
  if (count != 0 && !plan.shows(active)) {
    plan = Geometry::arrange(measured, active, room);
  }

  return plan;
}

QRectF TabStripLayout::placeTab(std::uint64_t id, QRectF bounds, TabMotionFrame &frame) {
  const auto dragging = dragged_ == id;
  if (dragging) {
    if (drag_preview_) {
      drop_marker_ = bounds;
    }
    constexpr qreal lift = 3;
    bounds.moveLeft(std::clamp(drag_pointer_.x() - drag_grab_offset_, qreal{0}, std::max(qreal{0}, width() - bounds.width())));
    bounds.translate(0, -lift * ratio_);
  }

  if (workspace_) {
    const auto density = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    const Rect physical{.x = static_cast<float>(bounds.x() * density), .y = static_cast<float>(bounds.y() * density), .width = static_cast<float>(bounds.width() * density), .height = static_cast<float>(bounds.height() * density)};
    const auto visible = motions_.place({.id = id, .bounds = physical, .immediate = dragging}, frame);
    bounds = {visible.x / density, visible.y / density, visible.width / density, visible.height / density};
  }

  if (dragging) {
    dragged_bounds_ = bounds;
  }

  return bounds;
}

QVariantList TabStripLayout::placeCards(const QVariantMap &tab, TabMotionFrame &frame) {
  const auto source = tab.value(QStringLiteral("cards")).toList();
  std::array<TabCardInput, PaneLayout::maximum_panes> inputs{};
  std::size_t count = 0;
  for (const auto &entry : source) {
    if (count == inputs.size()) {
      break;
    }

    const auto card = entry.toMap();
    inputs[count++] = {.pane = card.value(QStringLiteral("key")).toString().toULongLong(), .focused = card.value(QStringLiteral("focused")).toBool(), .attention = !card.value(QStringLiteral("attentionColor")).toString().isEmpty()};
  }

  std::array<TabCardPlacement, TabCardMotions::maximum_cards> placed{};
  const auto written = card_motions_.place(std::span{inputs}.first(count), placed, frame);
  // Delegates follow pane order, so a card keeps its item while its pose moves.
  std::sort(placed.begin(), placed.begin() + written, [](const TabCardPlacement &left, const TabCardPlacement &right) {
    return left.pane < right.pane;
  });

  QVariantList cards;
  for (const auto &card : std::span{placed}.first(written)) {
    const auto row = std::ranges::find(source, card.pane, [](const QVariant &entry) {
      return entry.toMap().value(QStringLiteral("key")).toString().toULongLong();
    });
    auto record = row->toMap();
    record.insert(QStringLiteral("x"), card.pose.x * ratio_);
    record.insert(QStringLiteral("y"), card.pose.y * ratio_);
    record.insert(QStringLiteral("rotation"), card.pose.rotation);
    record.insert(QStringLiteral("scale"), card.pose.scale);
    record.insert(QStringLiteral("rank"), static_cast<qulonglong>(card.rank));
    record.insert(QStringLiteral("layer"), card.lifted ? static_cast<int>(TabCardMotions::maximum_cards) : static_cast<int>(TabCardMotions::maximum_cards - 1 - card.rank));
    cards.append(std::move(record));
  }

  return cards;
}

void TabStripLayout::raiseDraggedSlot() {
  const auto delivered = std::span{drop_slots_}.first(drop_slot_count_);
  const auto lifted = std::ranges::find(delivered, dragged_, [](const TabDropSlot &slot) {
    return std::optional{slot.id};
  });
  if (lifted != delivered.end()) {
    std::rotate(lifted, lifted + 1, delivered.end());
  }
}

void TabStripLayout::rebuild() {
  if (width() <= 0 || height() <= 0 || !std::isfinite(width()) || !std::isfinite(height()) || width() > std::numeric_limits<float>::max() || height() > std::numeric_limits<float>::max()) {
    strip_bounds_ = {};
    selection_bounds_ = {};
    selection_motion_.reset();
    motions_ = {};
    next_sample_ns_.reset();
    frame_requested_ = false;
    drop_marker_ = {};
    dragged_bounds_ = {};
    drop_slot_count_ = 0;
    counter_.clear();
    items_.reconcile({});
    emit layoutChanged();

    return;
  }

  TabMotionFrame frame{.now_ns = clock_.isNull() ? 0 : clock_->now(), .interval_ns = clock_.isNull() ? TabMotionFrame::default_interval_ns : clock_->frameInterval(), .deadline_ns = std::nullopt};
  motions_.begin(workspace_);
  card_motions_.begin();
  const auto ratio = static_cast<float>(ratio_);
  const auto metrics = Geometry::Metrics::scaled(ratio);
  const auto available = static_cast<float>(width());
  const auto height = std::min(static_cast<float>(this->height()), Geometry::pill_height * ratio);
  const auto density = window() == nullptr ? qreal{1} : window()->effectiveDevicePixelRatio();
  const auto top = static_cast<float>(std::floor((this->height() - height) * density / 2) / density);
  QList<QVariantMap> records;
  std::array<Geometry::Measure, Geometry::maximum_tabs> sizes;
  const Geometry::Room room{.width = available, .metrics = metrics};
  const auto plan = measureTabs(records, sizes, room);
  const auto count = records.size();

  std::array<std::size_t, Geometry::maximum_tabs> order{};
  const auto shown = plan.end - plan.first;
  for (std::size_t index = 0; index < shown; ++index) {
    order[index] = plan.first + index;
  }

  if (drag_preview_) {
    previewOrder(std::span{order}.first(shown), records, *drag_preview_);
  }

  QList<QVariantMap> positioned;
  drop_slot_count_ = 0;
  drop_marker_ = {};
  dragged_bounds_ = {};
  std::optional<Rect> selection;
  bool selection_dragging = false;
  float left = 0;
  for (std::size_t position = 0; position < shown; ++position) {
    const auto index = order[position];
    if (position != 0) {
      left += metrics.gap;
    }

    QRectF bounds{left, top, plan.widths[index], height};
    const auto &record = records[static_cast<qsizetype>(index)];
    const auto id = record.value(QStringLiteral("key")).toString().toULongLong();
    const auto dragging = dragged_ == id;
    const auto target = bounds;
    bounds = placeTab(id, bounds, frame);
    if (record.value(QStringLiteral("selected")).toBool()) {
      const auto selected_bounds = dragging ? bounds : target;
      selection = Rect{.x = static_cast<float>(selected_bounds.x() * density), .y = static_cast<float>(selected_bounds.y() * density), .width = static_cast<float>(selected_bounds.width() * density), .height = static_cast<float>(selected_bounds.height() * density)};
      selection_dragging = dragging;
    }

    auto entry = positionedTab(record, sizes[index], bounds, plan.fits[index], metrics);
    entry.insert(QStringLiteral("dragging"), dragging);
    entry.insert(QStringLiteral("cards"), placeCards(record, frame));
    entry.insert(QStringLiteral("separator"), position + 1 < shown && !record.value(QStringLiteral("selected")).toBool() && !records[static_cast<qsizetype>(order[position + 1])].value(QStringLiteral("selected")).toBool());
    positioned.append(std::move(entry));
    drop_slots_[drop_slot_count_++] = {.id = id, .bounds = {.x = static_cast<float>(bounds.x()), .y = static_cast<float>(bounds.y()), .width = static_cast<float>(bounds.width()), .height = static_cast<float>(bounds.height())}};
    left += plan.widths[index];
  }

  raiseDraggedSlot();

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
    const auto id = records[static_cast<qsizetype>(*nearest)].value(QStringLiteral("key")).toString().toULongLong();
    drop_slots_[drop_slot_count_++] = {.id = id, .bounds = {.x = left, .y = top, .width = counter_width, .height = height}};
    left += counter_width;
  }

  strip_bounds_ = count != 0 ? QRectF{0, top, std::min(left, available), height} : QRectF{};
  selection_bounds_ = {};
  if (selection) {
    if (!selection_motion_) {
      selection_motion_ = TabMotion{.from = *selection, .to = *selection};
    }
    const auto visible = selection_motion_->place(*selection, frame, selection_dragging || !workspace_);
    selection_bounds_ = {visible.x / density, visible.y / density, visible.width / density, visible.height / density};
  } else {
    selection_motion_.reset();
  }

  if (count != 0) {
    anchor_ = records[static_cast<qsizetype>(plan.focus)].value(QStringLiteral("key")).toString();
  }

  motions_.finish();
  card_motions_.finish();
  next_sample_ns_ = clock_.isNull() ? std::nullopt : frame.deadline_ns;
  frame_requested_ = false;
  if (!clock_.isNull()) {
    clock_->requestSynchronization();
    if (next_sample_ns_) {
      window()->update();
    }
  }
  items_.reconcile(std::move(positioned));
  emit layoutChanged();
}

}
