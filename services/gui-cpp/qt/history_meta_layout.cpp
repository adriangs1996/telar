#include "input/history_action_capture.hpp"
#include "history_meta_layout.hpp"
#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "core/theme_values.hpp"
#include "history_hint_projection.hpp"
#include "presentation/history_actions.hpp"
#include "presentation/history_card.hpp"
#include "presentation/history_facts.hpp"
#include "presentation/history_meta_geometry.hpp"
#include "telar_client/serializers/telar_messages.hpp"
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
#include <optional>
#include <string_view>

namespace telar::gui::qt {

namespace {

QString actionName(HistoryCardAction action) {
  switch (action) {
  case HistoryCardAction::copy:
    return QStringLiteral("copy");
  case HistoryCardAction::erase:
    return QStringLiteral("erase");
  case HistoryCardAction::visit:
    return QStringLiteral("visit");
  }

  return {};
}

std::string_view bytes(const QByteArray &text) noexcept {
  return {text.constData(), static_cast<std::size_t>(text.size())};
}

}

HistoryMetaLayout::HistoryMetaLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

QVariantMap HistoryMetaLayout::input() const {
  return input_;
}

void HistoryMetaLayout::setInput(const QVariantMap &input) {
  if (input_ != input) {
    input_ = input;
    prepareLabels();
    emit inputChanged();
    emit labelsChanged();
    polish();
  }
}

QVariantMap HistoryMetaLayout::measurements() const {
  return measurements_;
}

void HistoryMetaLayout::setMeasurements(const QVariantMap &measurements) {
  if (measurements_ != measurements) {
    measurements_ = measurements;
    emit measurementsChanged();
    polish();
  }
}

QVariantList HistoryMetaLayout::facts() const {
  return facts_;
}

QVariantList HistoryMetaLayout::actions() const {
  return actions_;
}

void HistoryMetaLayout::prepareLabels() {
  const auto record = input_.value(QStringLiteral("record")).toMap();
  const auto directory = record.value(QStringLiteral("compactCwd"), record.value(QStringLiteral("cwd"))).toString().toUtf8();
  const auto provider = record.value(QStringLiteral("provider")).toString().toUtf8();
  const auto duration = record.value(QStringLiteral("duration")).toString().toUtf8();
  const auto age = record.value(QStringLiteral("age")).toString().toUtf8();
  const auto style = input_.value(QStringLiteral("macStyle")).toBool() ? HistoryKeyStyle::mac : HistoryKeyStyle::pc;
  const HistoryFactData data{
      .directory = bytes(directory),
      .provider = bytes(provider),
      .duration = bytes(duration),
      .age = bytes(age),
      .exit_code = record.contains(QStringLiteral("exitCode")) ? std::optional{record.value(QStringLiteral("exitCode")).toInt()} : std::nullopt,
      .status = static_cast<HistoryStatus>(record.value(QStringLiteral("status")).toInt()),
      .key_style = style,
      .more = static_cast<std::uint16_t>(std::clamp(input_.value(QStringLiteral("more")).toInt(), 0, static_cast<int>(HistoryCard::more_bound))),
      .truncated = record.value(QStringLiteral("truncated")).toBool(),
      .loaded = input_.value(QStringLiteral("loaded"), true).toBool(),
      .show_directory = input_.value(QStringLiteral("showDirectory"), true).toBool(),
      .has_time = record.contains(QStringLiteral("timestamp")) && record.value(QStringLiteral("timestamp")).toLongLong() >= 0,
      .agent = record.value(QStringLiteral("author")).toString() == QStringLiteral("agent"),
  };
  facts_.clear();
  auto append = [this](std::string_view text, PaletteRole color) {
    facts_.append(QVariantMap{
        {QStringLiteral("text"), QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()))},
        {QStringLiteral("color"), QString::fromLatin1(palette_names[static_cast<std::size_t>(color)])},
    });
  };
  HistoryFacts::visit(data, append);
  actions_.clear();
  for (const auto label : HistoryActions::labels(style)) {
    actions_.append(QVariantMap{
        {QStringLiteral("key"), QString::fromUtf8(label.key.data(), static_cast<qsizetype>(label.key.size()))},
        {QStringLiteral("word"), QString::fromUtf8(label.word.data(), static_cast<qsizetype>(label.word.size()))},
        {QStringLiteral("action"), actionName(label.action)},
    });
  }
}

QRectF HistoryMetaLayout::logical(Rect area) const noexcept {
  return {area.x / density_, area.y / density_, area.width / density_, area.height / density_};
}

QVariantMap HistoryMetaLayout::layout() const {
  QVariantList facts;
  for (const auto area : geometry_.facts) {
    facts.append(logical(area));
  }

  QVariantList actions;
  for (const auto &geometry : geometry_.actions) {
    actions.append(historyHintRecord(geometry, density_));
  }

  auto result = historyHintStyle(ratio_);
  result.insert(QStringLiteral("facts"), facts);
  result.insert(QStringLiteral("actions"), actions);
  result.insert(QStringLiteral("factCount"), static_cast<qulonglong>(geometry_.fact_count));
  result.insert(QStringLiteral("actionCount"), static_cast<qulonglong>(geometry_.action_count));

  return result;
}

HistoryActionSurface HistoryMetaLayout::actionSurface(std::uint64_t generation) const {
  HistoryActionSurface result{.generation = generation, .scale = density_};
  if (!isVisible() || window() == nullptr) {
    return result;
  }

  const auto labels = HistoryActions::labels(HistoryKeyStyle::pc);
  for (std::size_t index = 0; index < geometry_.action_count; ++index) {
    auto bounds = mapRectToScene(logical(geometry_.actions[index].bounds));
    for (const auto *ancestor = parentItem(); ancestor != nullptr; ancestor = ancestor->parentItem()) {
      if (ancestor->clip()) {
        bounds = bounds.intersected(ancestor->mapRectToScene(ancestor->boundingRect()));
      }
    }

    result.targets[index] = {.action = labels[index].action, .bounds = {.x = static_cast<float>(bounds.x() * density_), .y = static_cast<float>(bounds.y() * density_), .width = static_cast<float>(bounds.width() * density_), .height = static_cast<float>(bounds.height() * density_)}, .enabled = isEnabled()};
  }

  return result;
}

void HistoryMetaLayout::updatePolish() {
  density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
  const auto ratio = input_.value(QStringLiteral("ratio"), 1).toDouble();
  if (!std::isfinite(ratio) || ratio <= 0) {
    return;
  }

  ratio_ = ratio;
  ChromeMetrics chrome;
  chrome.ratio = static_cast<float>(ratio * density_);
  const auto small = input_.value(QStringLiteral("smallPixels")).toDouble() * density_;
  chrome.small = std::isfinite(small) ? static_cast<std::uint16_t>(std::clamp(std::round(small), qreal{0}, qreal{std::numeric_limits<std::uint16_t>::max()})) : 0;
  const auto advance = [this](const QVariant &value) {
    const auto measured = value.toDouble();

    return std::isfinite(measured) && measured > 0 ? static_cast<float>(measured * density_) : 0;
  };
  const auto facts = measurements_.value(QStringLiteral("facts")).toList();
  const auto actions = measurements_.value(QStringLiteral("actions")).toList();
  HistoryMetaMeasurements measured;
  measured.fact_count = std::min(static_cast<std::size_t>(facts_.size()), HistoryFacts::capacity);
  measured.selected = input_.value(QStringLiteral("selected"), true).toBool();
  measured.pane_open = input_.value(QStringLiteral("paneOpen")).toBool();
  for (std::size_t index = 0; index < measured.fact_count; ++index) {
    measured.facts[index] = advance(facts.value(static_cast<qsizetype>(index)));
  }

  for (std::size_t index = 0; index < measured.actions.size(); ++index) {
    const auto value = actions.value(static_cast<qsizetype>(index)).toMap();
    measured.actions[index] = {.key = advance(value.value(QStringLiteral("key"))), .word = advance(value.value(QStringLiteral("word")))};
  }

  geometry_ = HistoryMetaGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, chrome, measured);
  emit layoutChanged();
}

void HistoryMetaLayout::componentComplete() {
  QQuickItem::componentComplete();
  updatePolish();
}

void HistoryMetaLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  polish();
}

void HistoryMetaLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    polish();
  }
}

}
