#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "history_filters_layout.hpp"
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
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QString>
#include <QStringList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>



import telar.gui.input.child_mouse;
import telar.gui.core.metrics;
import telar.gui.presentation.history_filter_geometry;

namespace telar::gui::qt {

namespace {

QString label(std::string_view value) {
  return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
}

}

HistoryFiltersLayout::HistoryFiltersLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

QVariantMap HistoryFiltersLayout::input() const {
  return input_;
}

void HistoryFiltersLayout::setInput(const QVariantMap &input) {
  if (input_ != input) {
    input_ = input;
    prepareLabels();
    emit inputChanged();
    emit labelsChanged();
    polish();
  }
}

QVariantMap HistoryFiltersLayout::measurements() const {
  return measurements_;
}

void HistoryFiltersLayout::setMeasurements(const QVariantMap &measurements) {
  if (measurements_ != measurements) {
    measurements_ = measurements;
    emit measurementsChanged();
    polish();
  }
}

QVariantList HistoryFiltersLayout::scopeChoices() const {
  return scope_choices_;
}

QVariantList HistoryFiltersLayout::authorChoices() const {
  return author_choices_;
}

QStringList HistoryFiltersLayout::keyLabels() const {
  return key_labels_;
}

void HistoryFiltersLayout::prepareLabels() {
  const auto scope = input_.value(QStringLiteral("scope")).toString();
  const auto author = input_.value(QStringLiteral("author")).toString();
  const auto value = input_.value(QStringLiteral("scopeValue")).toString();
  scope_choices_.clear();
  for (const auto &choice : HistoryFilterLabels::scopes) {
    const auto route = label(choice.value);
    const auto selected = route == scope;
    scope_choices_.append(QVariantMap{{QStringLiteral("text"), label(choice.text)}, {QStringLiteral("value"), route}, {QStringLiteral("detail"), selected ? value : QString{}}, {QStringLiteral("selected"), selected}});
  }

  author_choices_.clear();
  for (const auto &choice : HistoryFilterLabels::authors) {
    const auto route = label(choice.value);
    author_choices_.append(QVariantMap{{QStringLiteral("text"), label(choice.text)}, {QStringLiteral("value"), route}, {QStringLiteral("selected"), route == author}});
  }

  key_labels_.clear();
  const auto keys = HistoryFilterLabels::keys(input_.value(QStringLiteral("macStyle")).toBool() ? HistoryKeyStyle::mac : HistoryKeyStyle::pc);
  for (const auto key : keys) {
    key_labels_.append(label(key));
  }
}

QRectF HistoryFiltersLayout::logical(Rect area) const noexcept {
  return {area.x / density_, area.y / density_, area.width / density_, area.height / density_};
}

QVariantMap HistoryFiltersLayout::chipRecord(const HistoryFilterChipGeometry &chip) const {
  const auto local = [&chip](Rect area) {
    area.x -= chip.bounds.x;
    area.y -= chip.bounds.y;

    return area;
  };

  return {{QStringLiteral("bounds"), logical(chip.bounds)}, {QStringLiteral("label"), logical(local(chip.label))}, {QStringLiteral("value"), logical(local(chip.value))}};
}

QVariantMap HistoryFiltersLayout::layout() const {
  QVariantList scopes;
  for (const auto &chip : geometry_.scopes) {
    scopes.append(chipRecord(chip));
  }

  QVariantList authors;
  for (const auto &chip : geometry_.authors) {
    authors.append(chipRecord(chip));
  }

  QVariantList keys;
  for (const auto &area : geometry_.keys) {
    keys.append(logical(area));
  }

  return {
      {QStringLiteral("scopes"), scopes},
      {QStringLiteral("authors"), authors},
      {QStringLiteral("keys"), keys},
      {QStringLiteral("failed"), chipRecord(geometry_.failed)},
      {QStringLiteral("scopeGroup"), logical(geometry_.scope_group)},
      {QStringLiteral("authorGroup"), logical(geometry_.author_group)},
      {QStringLiteral("separator"), logical(geometry_.separator)},
      {QStringLiteral("showKeys"), geometry_.show_keys},
      {QStringLiteral("showRight"), geometry_.show_right},
      {QStringLiteral("visible"), geometry_.visible},
      {QStringLiteral("groupRadius"), HistoryFilterGeometry::group_radius * ratio_},
      {QStringLiteral("chipRadius"), HistoryFilterChipGeometry::corner_radius * ratio_},
      {QStringLiteral("ringWidth"), HistoryFilterChipGeometry::ring_width * ratio_},
      {QStringLiteral("dangerRingAlpha"), HistoryFilterChipGeometry::danger_ring_alpha},
  };
}

std::size_t HistoryFiltersLayout::hoverTargets(std::uint64_t generation, std::span<HistoryHoverTarget> destination) const {
  if (!isVisible() || window() == nullptr || !geometry_.visible) {
    return 0;
  }

  std::size_t count = 0;
  const auto append = [&](HistoryFilterAction action, Rect area) {
    if (count == destination.size() || area.empty()) {
      return;
    }

    const auto bounds = mapRectToScene(logical(area));
    destination[count++] = {.identity = {.action = action, .generation = generation}, .bounds = {.x = static_cast<float>(bounds.x() * density_), .y = static_cast<float>(bounds.y() * density_), .width = static_cast<float>(bounds.width() * density_), .height = static_cast<float>(bounds.height() * density_)}};
  };
  constexpr std::array scopes{HistoryFilterAction::global, HistoryFilterAction::workspace, HistoryFilterAction::cwd, HistoryFilterAction::pane};
  for (std::size_t index = 0; index < scopes.size(); ++index) {
    append(scopes[index], geometry_.scopes[index].bounds);
  }

  if (geometry_.show_right) {
    append(HistoryFilterAction::failed, geometry_.failed.bounds);
    constexpr std::array authors{HistoryFilterAction::human, HistoryFilterAction::agent, HistoryFilterAction::all};
    for (std::size_t index = 0; index < authors.size(); ++index) {
      append(authors[index], geometry_.authors[index].bounds);
    }
  }

  return count;
}

void HistoryFiltersLayout::updatePolish() {
  const auto ratio = input_.value(QStringLiteral("ratio"), 1).toDouble();
  if (!std::isfinite(ratio) || ratio <= 0) {
    return;
  }

  ratio_ = ratio;
  density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
  ChromeMetrics chrome;
  chrome.ratio = static_cast<float>(ratio_ * density_);
  const auto advance = [this](const QVariant &value) {
    const auto width = value.toDouble();

    return std::isfinite(width) && width > 0 ? static_cast<float>(width * density_) : 0.0F;
  };
  const auto scope_widths = measurements_.value(QStringLiteral("scopes")).toList();
  const auto author_widths = measurements_.value(QStringLiteral("authors")).toList();
  const auto key_widths = measurements_.value(QStringLiteral("keys")).toList();
  HistoryFilterMeasurements measured;
  for (std::size_t index = 0; index < measured.scopes.size(); ++index) {
    const auto widths = scope_widths.value(static_cast<qsizetype>(index)).toMap();
    const auto choice = scope_choices_.value(static_cast<qsizetype>(index)).toMap();
    measured.scopes[index] = {.label = advance(widths.value(QStringLiteral("label"))), .value = advance(widths.value(QStringLiteral("value"))), .has_value = !choice.value(QStringLiteral("detail")).toString().isEmpty()};
  }
  for (std::size_t index = 0; index < measured.authors.size(); ++index) {
    measured.authors[index].label = advance(author_widths.value(static_cast<qsizetype>(index)));
  }
  for (std::size_t index = 0; index < measured.keys.size(); ++index) {
    measured.keys[index] = advance(key_widths.value(static_cast<qsizetype>(index)));
  }
  measured.failed = advance(measurements_.value(QStringLiteral("failed")));
  geometry_ = HistoryFilterGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, chrome, measured);
  emit layoutChanged();
}

void HistoryFiltersLayout::componentComplete() {
  QQuickItem::componentComplete();
  updatePolish();
}

void HistoryFiltersLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  polish();
}

void HistoryFiltersLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    polish();
  }
}

}
