#include "history_inspection_layout.hpp"
#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "core/theme_values.hpp"
#include "presentation/history_inspection.hpp"
#include "presentation/history_inspection_geometry.hpp"
#include "scroll_event.hpp"
#include <QByteArray>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QWheelEvent>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <string_view>

namespace telar::gui::qt {
namespace {

std::string_view bytes(const QByteArray &text) noexcept {
  return {text.constData(), static_cast<std::size_t>(text.size())};
}

QString string(std::string_view text) {
  return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
}

PaletteRole color(const QString &name) {
  const auto encoded = name.toUtf8();
  const auto *const found = std::ranges::find(palette_names, bytes(encoded));

  return found == palette_names.end() ? PaletteRole::text : static_cast<PaletteRole>(found - palette_names.begin());
}

}

HistoryInspectionLayout::HistoryInspectionLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

QVariantMap HistoryInspectionLayout::input() const {
  return input_;
}

void HistoryInspectionLayout::setInput(const QVariantMap &input) {
  if (input_ == input) {
    return;
  }

  const auto identity_changed = input_.value(QStringLiteral("identity")) != input.value(QStringLiteral("identity"));
  input_ = input;
  if (identity_changed) {
    setScroll(0);
  }

  emit inputChanged();
  polish();
}

QVariantList HistoryInspectionLayout::advances() const {
  return advances_;
}

void HistoryInspectionLayout::setAdvances(const QVariantList &advances) {
  if (advances_ != advances) {
    advances_ = advances;
    emit advancesChanged();
    polish();
  }
}

QVariantMap HistoryInspectionLayout::layout() const {
  return layout_;
}

int HistoryInspectionLayout::scroll() const {
  return scroll_;
}

void HistoryInspectionLayout::setScroll(int scroll) {
  const auto next = std::max(0, scroll);
  if (scroll_ != next) {
    scroll_ = next;
    emit scrollChanged();
    polish();
  }
}

QRectF HistoryInspectionLayout::logical(Rect area) const noexcept {
  return {area.x / density_, area.y / density_, area.width / density_, area.height / density_};
}

float HistoryInspectionLayout::physical(const QVariant &value) const {
  const auto measured = value.toDouble();

  return std::isfinite(measured) && measured > 0 ? static_cast<float>(measured * density_) : 0;
}

ChromeMetrics HistoryInspectionLayout::metrics(qreal ratio) const {
  const auto pixels = [&](const QString &name) {
    return static_cast<std::uint16_t>(std::clamp(std::round(physical(input_.value(name))), 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
  };
  ChromeMetrics chrome;
  chrome.ratio = static_cast<float>(ratio * density_);
  chrome.body = pixels(QStringLiteral("bodyPixels"));
  chrome.small = pixels(QStringLiteral("smallPixels"));

  return chrome;
}

QVariantMap HistoryInspectionLayout::projectLine(const HistoryInspectionLine &line, const HistoryInspectionGeometry &geometry, std::uint16_t index) const {
  const auto row = geometry.row(index);

  return {
      {QStringLiteral("command"), line.kind == HistoryInspectionLine::Kind::command},
      {QStringLiteral("fact"), line.kind == HistoryInspectionLine::Kind::fact},
      {QStringLiteral("heading"), line.kind == HistoryInspectionLine::Kind::heading},
      {QStringLiteral("text"), string(line.text)},
      {QStringLiteral("label"), string(line.label)},
      {QStringLiteral("color"), QString::fromLatin1(palette_names[static_cast<std::size_t>(line.color)])},
      {QStringLiteral("mono"), line.mono},
      {QStringLiteral("bounds"), logical(row)},
      {QStringLiteral("textBounds"), logical(geometry.text(row, line.kind))},
      {QStringLiteral("labelWidth"), geometry.label_width / density_},
  };
}

QVariantMap HistoryInspectionLayout::prepareContent(const HistoryInspectionGeometry &geometry) {
  const auto command = input_.value(QStringLiteral("command")).toString().toUtf8();
  const auto output = input_.value(QStringLiteral("output")).toString().toUtf8();
  const auto heading = input_.value(QStringLiteral("heading")).toString().toUtf8();
  const auto records = input_.value(QStringLiteral("facts")).toList();
  std::array<QByteArray, HistoryInspectionFacts::count> texts;
  std::array<QByteArray, HistoryInspectionFacts::count> labels;
  std::array<HistoryInspectionLine, HistoryInspectionFacts::count> facts;
  const auto fact_count = std::min(facts.size(), static_cast<std::size_t>(records.size()));
  for (std::size_t index = 0; index < fact_count; ++index) {
    const auto record = records[static_cast<qsizetype>(index)].toMap();
    texts[index] = record.value(QStringLiteral("text")).toString().toUtf8();
    labels[index] = record.value(QStringLiteral("label")).toString().toUtf8();
    facts[index] = {.kind = HistoryInspectionLine::Kind::fact, .text = bytes(texts[index]), .label = bytes(labels[index]), .color = color(record.value(QStringLiteral("color")).toString()), .mono = record.value(QStringLiteral("mono")).toBool()};
  }

  HistoryInspectionLines lines{{.command = bytes(command), .facts = std::span{facts}.first(fact_count), .heading = bytes(heading), .output = bytes(output)}, geometry.columns};
  const auto total = lines.count();
  const auto maximum_scroll = static_cast<int>(total - std::min(total, static_cast<std::uint32_t>(geometry.rows)));
  const auto next_scroll = std::min(scroll_, maximum_scroll);
  if (next_scroll != scroll_) {
    scroll_ = next_scroll;
    emit scrollChanged();
  }

  for (int skipped = 0; skipped < scroll_; ++skipped) {
    static_cast<void>(lines.next());
  }

  QVariantList visible;
  for (std::uint16_t index = 0; geometry.columns != 0 && index < geometry.rows; ++index) {
    const auto line = lines.next();
    if (!line) {
      break;
    }

    visible.append(projectLine(*line, geometry, index));
  }

  return {
      {QStringLiteral("content"), logical(geometry.content)},
      {QStringLiteral("lines"), visible},
      {QStringLiteral("lineCount"), total},
      {QStringLiteral("maximumScroll"), maximum_scroll},
  };
}

QVariantList HistoryInspectionLayout::prepareButtons(const HistoryInspectionGeometry &geometry, ChromeMetrics chrome) const {
  std::array<float, HistoryInspectionGeometry::maximum_actions> measured{};
  const auto action_count = std::min(measured.size(), static_cast<std::size_t>(advances_.size()));
  for (std::size_t index = 0; index < action_count; ++index) {
    measured[index] = physical(advances_[static_cast<qsizetype>(index)]);
  }

  QVariantList buttons;
  for (const auto button : geometry.buttons(std::span{measured}.first(action_count), chrome)) {
    buttons.append(logical(geometry.columns == 0 ? Rect{} : button));
  }

  return buttons;
}

void HistoryInspectionLayout::updatePolish() {
  const auto ratio = input_.value(QStringLiteral("ratio"), 1).toDouble();
  if (!std::isfinite(ratio) || ratio <= 0) {
    return;
  }

  density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
  const auto chrome = metrics(ratio);
  const auto geometry = HistoryInspectionGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, chrome, {.x = physical(input_.value(QStringLiteral("cellWidth"))), .y = physical(input_.value(QStringLiteral("cellHeight")))});
  layout_ = prepareContent(geometry);
  layout_.insert(QStringLiteral("buttons"), prepareButtons(geometry, chrome));
  layout_.insert(QStringLiteral("buttonRadius"), HistoryInspectionGeometry::button_radius * ratio);
  layout_.insert(QStringLiteral("disabledAlpha"), HistoryInspectionGeometry::disabled_alpha);
  layout_.insert(QStringLiteral("pressedAlpha"), HistoryInspectionGeometry::pressed_alpha);
  emit layoutChanged();
}

void HistoryInspectionLayout::componentComplete() {
  QQuickItem::componentComplete();
  updatePolish();
}

void HistoryInspectionLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  polish();
}

void HistoryInspectionLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    polish();
  }
}

void HistoryInspectionLayout::wheelEvent(QWheelEvent *event) {
  if (input_.value(QStringLiteral("interactive")).toBool()) {
    const auto lines = wheel_.consume(scrollSample(*event, input_.value(QStringLiteral("cellHeight")).toDouble()));
    setScroll(scroll_ + lines);
  }

  event->accept();
}

}
