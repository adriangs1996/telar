#include "native_mode_layout.hpp"
#include "cell_text_grid.hpp"
#include "core/geometry.hpp"
#include "core/theme_values.hpp"
#include "input/binding.hpp"
#include "presentation/mode_bar_layout.hpp"
#include "presentation/mode_hints.hpp"
#include <QByteArray>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <exception>
#include <stdexcept>
#include <string_view>

namespace telar::gui::qt {
namespace {

QRectF logical(Rect bounds, qreal scale) {
  return {bounds.x / scale, bounds.y / scale, bounds.width / scale, bounds.height / scale};
}

ModeHint readHint(const QVariantMap &value, QByteArray &storage) {
  const auto kind = value.value(QStringLiteral("key")).toInt();
  if (kind < static_cast<int>(KeyChord::Key::character) || kind > static_cast<int>(KeyChord::Key::back_tab)) {
    throw std::invalid_argument{"InvalidModeHintKey"};
  }

  storage = value.value(QStringLiteral("label")).toString().toUtf8();

  return {.key = {.key = static_cast<KeyChord::Key>(kind), .character = value.value(QStringLiteral("character")).toUInt(), .modifiers = value.value(QStringLiteral("modifiers")).toUInt()}, .label = {storage.constData(), static_cast<std::size_t>(storage.size())}};
}

}

NativeModeLayout::NativeModeLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

QVariantMap NativeModeLayout::mode() const {
  return mode_;
}

QVariantMap NativeModeLayout::grid() const {
  return grid_;
}

qreal NativeModeLayout::ratio() const noexcept {
  return ratio_;
}

QVariantList NativeModeLayout::labels() const {
  return labels_;
}

QRectF NativeModeLayout::chip() const noexcept {
  return chip_;
}

qreal NativeModeLayout::chipRadius() const noexcept {
  return ModeBarLayout::chip_radius * ratio_;
}

void NativeModeLayout::setMode(const QVariantMap &mode) {
  if (mode_ != mode) {
    mode_ = mode;
    emit modeChanged();
    polish();
  }
}

void NativeModeLayout::setGrid(const QVariantMap &grid) {
  if (grid_ != grid) {
    grid_ = grid;
    emit gridChanged();
    polish();
  }
}

void NativeModeLayout::setRatio(qreal ratio) {
  if (std::isfinite(ratio) && ratio > 0 && ratio_ != ratio) {
    ratio_ = ratio;
    emit ratioChanged();
    polish();
  }
}

void NativeModeLayout::refreshLayout() {
  QVariantList labels;
  QRectF chip;
  try {
    const auto scale = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    const auto grid = CellTextGrid::resolve(grid_, scale);
    const auto kind = mode_.value(QStringLiteral("kind")).toInt();
    if (kind < static_cast<int>(StatusMode::normal) || kind > static_cast<int>(StatusMode::copy)) {
      throw std::invalid_argument{"InvalidStatusMode"};
    }

    ModeBarRequest request{.mode = static_cast<StatusMode>(kind), .bounds = {.width = static_cast<float>(width() * scale), .height = static_cast<float>(height() * scale)}, .ratio = static_cast<float>(ratio_ * scale), .cell_width = static_cast<float>(grid.metrics.width)};
    const auto hints = mode_.value(QStringLiteral("hints")).toList();
    std::array<QByteArray, ModeHints::capacity> text_storage;
    const auto count = std::min(hints.size(), static_cast<qsizetype>(text_storage.size()));
    for (qsizetype index = 0; index < count; ++index) {
      request.hints.append(readHint(hints[index].toMap(), text_storage[static_cast<std::size_t>(index)]));
    }

    const auto layout = ModeBarLayout::measure(request);
    chip = logical(layout.chip(), scale);
    for (const auto &label : layout.labels()) {
      const auto text = label.text.view();
      labels.append(QVariantMap{
          {QStringLiteral("text"), QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()))},
          {QStringLiteral("bounds"), logical(label.bounds, scale)},
          {QStringLiteral("bold"), label.bold},
          {QStringLiteral("ink"), QString::fromLatin1(palette_names[static_cast<std::size_t>(label.ink)])},
      });
    }
  } catch (const std::exception &) {
    labels.clear();
    chip = {};
  }

  if (chip_ != chip || labels_ != labels) {
    chip_ = chip;
    labels_ = labels;
    emit layoutChanged();
  }
}

void NativeModeLayout::updatePolish() {
  refreshLayout();
}

void NativeModeLayout::componentComplete() {
  QQuickItem::componentComplete();
  refreshLayout();
}

void NativeModeLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  polish();
}

void NativeModeLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    polish();
  }
}

}
