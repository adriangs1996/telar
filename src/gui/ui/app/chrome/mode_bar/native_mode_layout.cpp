#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "native_mode_layout.hpp"
#include "tbc/view.hpp"
#include "ui/design/history_hint_projection.hpp"
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
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <stdexcept>
#include <string_view>

import telar.gui.foundation.actions;
import telar.gui.application;

namespace telar::gui::qt {
  namespace {

    static_assert(application::status_bar::ModeBarLabels::capacity <= application::status_bar::ModeBarMeasurements::capacity);

    QString text(std::string_view value) {
      return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
    }

    // The hint views the label it writes into the storage, region `a`.
    tbc::view<application::status_bar::ModeHint, tbc::lt::a> readHint(const QVariantMap& value, tbc::view<QByteArray&, tbc::lt::a> storage) {
      const auto kind = value.value(QStringLiteral("key")).toInt();
      if (kind < static_cast<int>(KeyChord::Key::character) || kind > static_cast<int>(KeyChord::Key::back_tab)) {
        throw std::invalid_argument{"InvalidModeHintKey"};
      }

      storage = value.value(QStringLiteral("label")).toString().toUtf8();

      return {.key = {.key = static_cast<KeyChord::Key>(kind), .character = value.value(QStringLiteral("character")).toUInt(), .modifiers = value.value(QStringLiteral("modifiers")).toUInt()}, .label = {storage.constData(), static_cast<std::size_t>(storage.size())}};
    }

    float advance(const QVariant& value, qreal density) {
      const auto measured = value.toDouble();

      return std::isfinite(measured) && measured > 0 ? static_cast<float>(measured * density) : 0;
    }

  }

  NativeModeLayout::NativeModeLayout(QQuickItem* parent)
      : QQuickItem(parent) {
    refreshLayout();
  }

  QVariantMap NativeModeLayout::mode() const {
    return mode_;
  }

  qreal NativeModeLayout::ratio() const noexcept {
    return ratio_;
  }

  qreal NativeModeLayout::pixelSize() const noexcept {
    return pixel_size_;
  }

  QVariantMap NativeModeLayout::measurements() const {
    return measurements_;
  }

  QString NativeModeLayout::title() const {
    return title_;
  }

  QVariantList NativeModeLayout::hints() const {
    return hints_;
  }

  QVariantMap NativeModeLayout::layout() const {
    return layout_;
  }

  void NativeModeLayout::setMode(const QVariantMap& mode) {
    if (mode_ != mode) {
      mode_ = mode;
      prepareLabels();
      emit modeChanged();
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

  void NativeModeLayout::setPixelSize(qreal pixelSize) {
    if (std::isfinite(pixelSize) && pixelSize >= 0 && pixel_size_ != pixelSize) {
      pixel_size_ = pixelSize;
      emit pixelSizeChanged();
      polish();
    }
  }

  void NativeModeLayout::setMeasurements(const QVariantMap& measurements) {
    if (measurements_ != measurements) {
      measurements_ = measurements;
      emit measurementsChanged();
      polish();
    }
  }

  void NativeModeLayout::prepareLabels() {
    QString title;
    QVariantList hints;

    try {
      const auto kind = mode_.value(QStringLiteral("kind")).toInt();
      if (kind < static_cast<int>(application::status_bar::StatusMode::normal) || kind > static_cast<int>(application::status_bar::StatusMode::copy)) {
        throw std::invalid_argument{"InvalidStatusMode"};
      }

      const auto records = mode_.value(QStringLiteral("hints")).toList();
      std::array<QByteArray, application::status_bar::ModeHints::capacity> storage;
      application::status_bar::ModeHints bound;
      const auto count = std::min(records.size(), static_cast<qsizetype>(storage.size()));

      for (qsizetype index = 0; index < count; ++index) {
        bound.append(readHint(records[index].toMap(), storage[static_cast<std::size_t>(index)]));
      }

      const auto labels = application::status_bar::ModeBarLabels::resolve(static_cast<application::status_bar::StatusMode>(kind), bound);

      title = text(labels.title());
      for (const auto& hint : labels.hints()) {
        hints.append(QVariantMap{{QStringLiteral("key"), text(hint.key.view())}, {QStringLiteral("word"), text(hint.word.view())}});
      }
    } catch (const std::exception&) {
      title.clear();
      hints.clear();
    }

    if (title_ != title || hints_ != hints) {
      title_ = title;
      hints_ = hints;
      emit labelsChanged();
    }
  }

  void NativeModeLayout::refreshLayout() {
    const auto density = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    ChromeMetrics chrome;

    chrome.ratio = static_cast<float>(ratio_ * density);
    chrome.small = static_cast<std::uint16_t>(std::clamp(std::round(pixel_size_ * density), qreal{0}, qreal{std::numeric_limits<std::uint16_t>::max()}));
    const auto measured_hints = measurements_.value(QStringLiteral("hints")).toList();
    application::status_bar::ModeBarMeasurements measured;

    measured.title = advance(measurements_.value(QStringLiteral("title")), density);
    measured.count = std::min({static_cast<std::size_t>(hints_.size()), static_cast<std::size_t>(measured_hints.size()), application::status_bar::ModeBarMeasurements::capacity});
    for (std::size_t index = 0; index < measured.count; ++index) {
      const auto hint = measured_hints[static_cast<qsizetype>(index)].toMap();

      measured.hints[index] = {.key = advance(hint.value(QStringLiteral("key")), density), .word = advance(hint.value(QStringLiteral("word")), density)};
    }

    const auto geometry = title_.isEmpty() ? application::status_bar::ModeBarGeometry{} : application::status_bar::ModeBarGeometry::derive({.width = static_cast<float>(width() * density), .height = static_cast<float>(height() * density)}, chrome, measured);
    QVariantList hints;

    for (std::size_t index = 0; index < geometry.count; ++index) {
      hints.append(historyHintRecord(geometry.hints[index], density));
    }

    auto layout = historyHintStyle(ratio_);
    const auto title = geometry.title;

    layout.insert(QStringLiteral("title"), QRectF{title.x / density, title.y / density, title.width / density, title.height / density});
    layout.insert(QStringLiteral("hints"), hints);
    layout.insert(QStringLiteral("hintCount"), static_cast<qulonglong>(geometry.count));
    if (layout_ != layout) {
      layout_ = layout;
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

  void NativeModeLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    polish();
  }

  void NativeModeLayout::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
      polish();
    }
  }

}
