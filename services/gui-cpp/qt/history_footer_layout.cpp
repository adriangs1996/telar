#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "history_footer_layout.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <array>
#include <string_view>
#include <optional>
#include <utility>
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include "history_hint_projection.hpp"
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <limits>



import telar.gui.core.metrics;
import telar.gui.history.browser;
import telar.gui.input.child_mouse;
import telar.gui.presentation.history_filter_geometry;
import telar.gui.presentation.history_meta_geometry;

namespace telar::gui::qt {
namespace {

QString actionName(HistoryFooterAction action) {
  switch (action) {
  case HistoryFooterAction::none:
    return QStringLiteral("none");
  case HistoryFooterAction::submit:
    return QStringLiteral("submit");
  case HistoryFooterAction::alternate:
    return QStringLiteral("alternate");
  case HistoryFooterAction::inspect:
    return QStringLiteral("inspect");
  case HistoryFooterAction::visit:
    return QStringLiteral("visit");
  }

  return {};
}

QString label(std::string_view text) {
  return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
}

}

HistoryFooterLayout::HistoryFooterLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

QVariantMap HistoryFooterLayout::input() const {
  return input_;
}

void HistoryFooterLayout::setInput(const QVariantMap &input) {
  if (input_ != input) {
    input_ = input;
    prepareLabels();
    emit inputChanged();
    emit labelsChanged();
    polish();
  }
}

QVariantMap HistoryFooterLayout::measurements() const {
  return measurements_;
}

void HistoryFooterLayout::setMeasurements(const QVariantMap &measurements) {
  if (measurements_ != measurements) {
    measurements_ = measurements;
    emit measurementsChanged();
    polish();
  }
}

QVariantList HistoryFooterLayout::hints() const {
  return hints_;
}

QString HistoryFooterLayout::range() const {
  return range_;
}

void HistoryFooterLayout::prepareLabels() {
  const auto state = input_.value(QStringLiteral("state")).toMap();
  const HistoryFooterOptions options{
      .key_style = state.value(QStringLiteral("macStyle")).toBool() ? HistoryKeyStyle::mac : HistoryKeyStyle::pc,
      .offset = static_cast<std::uint32_t>(std::min(state.value(QStringLiteral("offset")).toULongLong(), qulonglong{std::numeric_limits<std::uint32_t>::max()})),
      .count = static_cast<std::uint16_t>(std::clamp(state.value(QStringLiteral("count")).toInt(), 0, static_cast<int>(std::numeric_limits<std::uint16_t>::max()))),
      .inspecting = state.value(QStringLiteral("inspecting")).toBool(),
      .enter_runs = state.value(QStringLiteral("enterRuns")).toBool(),
      .has_more = state.value(QStringLiteral("hasMore")).toBool(),
      .fuzzy = state.value(QStringLiteral("matchFuzzy")).toBool(),
      .has_query = !state.value(QStringLiteral("query")).toString().isEmpty(),
  };
  footer_ = HistoryFooter::resolve(options);
  choice_ = {.index = static_cast<std::size_t>(std::max(0, state.value(QStringLiteral("selection")).toInt())), .revision = state.value(QStringLiteral("revision")).toString().toULongLong()};

  range_ = label(HistoryFooter::range(options).view());
  hints_.clear();
  for (std::size_t index = 0; index < footer_.count; ++index) {
    const auto hint = footer_.hints[index];
    hints_.append(QVariantMap{
        {QStringLiteral("key"), label(hint.key)},
        {QStringLiteral("word"), label(hint.word)},
        {QStringLiteral("action"), actionName(hint.action)},
    });
  }
}

QRectF HistoryFooterLayout::logical(Rect area) const noexcept {
  return {area.x / density_, area.y / density_, area.width / density_, area.height / density_};
}

QVariantMap HistoryFooterLayout::layout() const {
  QVariantList hints;
  for (const auto &hint : geometry_.hints) {
    hints.append(historyHintRecord(hint, density_));
  }

  auto result = historyHintStyle(ratio_);
  result.insert(QStringLiteral("hints"), hints);
  result.insert(QStringLiteral("hintCount"), static_cast<qulonglong>(geometry_.count));
  result.insert(QStringLiteral("separator"), logical(geometry_.separator));
  result.insert(QStringLiteral("range"), logical(geometry_.range));
  result.insert(QStringLiteral("error"), logical(geometry_.error));
  result.insert(QStringLiteral("showRange"), geometry_.range_visible);
  result.insert(QStringLiteral("showError"), geometry_.error_visible);

  return result;
}

std::size_t HistoryFooterLayout::hoverTargets(std::uint64_t generation, std::span<HistoryHoverTarget> destination) const {
  if (!isVisible() || window() == nullptr) {
    return 0;
  }

  std::size_t count = 0;
  for (std::size_t index = 0; index < geometry_.count && count < destination.size(); ++index) {
    const auto action = footer_.hints[index].action;
    if (action == HistoryFooterAction::none) {
      continue;
    }

    const auto bounds = mapRectToScene(logical(geometry_.hints[index].bounds));
    destination[count++] = {.identity = {.action = HistoryFooterIdentity{.action = action, .choice = choice_}, .generation = generation}, .bounds = {.x = static_cast<float>(bounds.x() * density_), .y = static_cast<float>(bounds.y() * density_), .width = static_cast<float>(bounds.width() * density_), .height = static_cast<float>(bounds.height() * density_)}};
  }

  return count;
}

void HistoryFooterLayout::updatePolish() {
  const auto ratio = input_.value(QStringLiteral("ratio"), 1).toDouble();
  if (!std::isfinite(ratio) || ratio <= 0) {
    return;
  }

  density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
  ratio_ = ratio;
  ChromeMetrics chrome;
  chrome.ratio = static_cast<float>(ratio * density_);
  const auto small = input_.value(QStringLiteral("smallPixels")).toDouble() * density_;
  chrome.small = std::isfinite(small) ? static_cast<std::uint16_t>(std::clamp(std::round(small), qreal{0}, qreal{std::numeric_limits<std::uint16_t>::max()})) : 0;
  const auto advance = [this](const QVariant &value) {
    const auto measured = value.toDouble();

    return std::isfinite(measured) && measured > 0 ? static_cast<float>(measured * density_) : 0;
  };
  const auto state = input_.value(QStringLiteral("state")).toMap();
  const auto hints = measurements_.value(QStringLiteral("hints")).toList();
  HistoryFooterMeasurements measured;
  measured.count = std::min(static_cast<std::size_t>(hints_.size()), HistoryFooter::capacity);
  measured.range = advance(measurements_.value(QStringLiteral("range")));
  measured.empty = state.value(QStringLiteral("count")).toInt() == 0;
  measured.error = !state.value(QStringLiteral("error")).toString().isEmpty();
  for (std::size_t index = 0; index < measured.count; ++index) {
    const auto hint = hints.value(static_cast<qsizetype>(index)).toMap();
    measured.hints[index] = {.key = advance(hint.value(QStringLiteral("key"))), .word = advance(hint.value(QStringLiteral("word")))};
  }

  geometry_ = HistoryFooterGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, chrome, measured);
  emit layoutChanged();
}

void HistoryFooterLayout::componentComplete() {
  QQuickItem::componentComplete();
  updatePolish();
}

void HistoryFooterLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  polish();
}

void HistoryFooterLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    polish();
  }
}

}
