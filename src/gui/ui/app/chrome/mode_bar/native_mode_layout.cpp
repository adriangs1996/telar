module telar.gui.ui.app.chrome.mode_bar;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.design;
import telar.gui.foundation.actions;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    static_assert(application::status_bar::ModeBarLabels::capacity <= application::status_bar::ModeBarMeasurements::capacity);

    QString text(std::string_view value) {
      return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
    }

    // The hint views the label it writes into the storage, region `a`.
    // A hint's label as UTF-8, which the hint views once every label is stored.
    QByteArray hintLabel(const QVariantMap& value) {
      return value.value(u"label"_s).toString().toUtf8();
    }

    tbc::val_a<application::status_bar::ModeHint> readHint(const QVariantMap& value, tbc::ref_a<QByteArray> label) {
      const auto kind = value.value(u"key"_s).toInt();
      if (kind < static_cast<int>(KeyChord::Key::character) || kind > static_cast<int>(KeyChord::Key::back_tab)) {
        throw std::invalid_argument{"InvalidModeHintKey"};
      }

      return {.key = {.key = static_cast<KeyChord::Key>(kind), .character = value.value(u"character"_s).toUInt(), .modifiers = value.value(u"modifiers"_s).toUInt()}, .label = {label.constData(), static_cast<std::size_t>(label.size())}};
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
      modeChanged();
      polish();
    }
  }

  void NativeModeLayout::setRatio(qreal ratio) {
    if (std::isfinite(ratio) && ratio > 0 && std::not_equal_to<>{}(ratio_, ratio)) {
      ratio_ = ratio;
      ratioChanged();
      polish();
    }
  }

  void NativeModeLayout::setPixelSize(qreal pixel_size) {
    if (std::isfinite(pixel_size) && pixel_size >= 0 && std::not_equal_to<>{}(pixel_size_, pixel_size)) {
      pixel_size_ = pixel_size;
      pixelSizeChanged();
      polish();
    }
  }

  void NativeModeLayout::setMeasurements(const QVariantMap& measurements) {
    if (measurements_ != measurements) {
      measurements_ = measurements;
      measurementsChanged();
      polish();
    }
  }

  void NativeModeLayout::prepareLabels() {
    QString title;
    QVariantList hints;

    try {
      const auto kind = mode_.value(u"kind"_s).toInt();
      if (kind < static_cast<int>(application::status_bar::StatusMode::normal) || kind > static_cast<int>(application::status_bar::StatusMode::copy)) {
        throw std::invalid_argument{"InvalidStatusMode"};
      }

      const auto records = mode_.value(u"hints"_s).toList();
      ds::Array<QByteArray, application::status_bar::ModeHints::capacity> storage;
      application::status_bar::ModeHints bound;
      const auto count = std::min(records.size(), static_cast<qsizetype>(storage.size()));

      // Every label is stored before any hint views one, as Rust lends no element of an array it still
      // writes by index.
      for (qsizetype index = 0; index < count; ++index) {
        storage.atMut(static_cast<std::size_t>(index)) = hintLabel(records[index].toMap());
      }

      for (qsizetype index = 0; index < count; ++index) {
        bound.append(readHint(records[index].toMap(), storage[static_cast<std::size_t>(index)]));
      }

      const auto labels = application::status_bar::ModeBarLabels::resolve(static_cast<application::status_bar::StatusMode>(kind), bound);

      title = text(labels.title());
      for (const auto& hint : labels.hints()) {
        hints.append(QVariantMap{{u"key"_s, text(hint.key.view())}, {u"word"_s, text(hint.word.view())}});
      }
    } catch (const std::exception&) {
      title.clear();
      hints.clear();
    }

    if (title_ != title || hints_ != hints) {
      title_ = std::move(title);
      hints_ = hints;
      labelsChanged();
    }
  }

  void NativeModeLayout::refreshLayout() {
    const auto density = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    ChromeMetrics chrome;

    chrome.ratio = static_cast<float>(ratio_ * density);
    chrome.small = static_cast<std::uint16_t>(std::clamp(std::round(pixel_size_ * density), qreal{0}, qreal{std::numeric_limits<std::uint16_t>::max()}));
    const auto measured_hints = measurements_.value(u"hints"_s).toList();
    application::status_bar::ModeBarMeasurements measured;

    measured.title = advance(measurements_.value(u"title"_s), density);
    measured.count = std::min({static_cast<std::size_t>(hints_.size()), static_cast<std::size_t>(measured_hints.size()), application::status_bar::ModeBarMeasurements::capacity});
    for (std::size_t index = 0; index < measured.count; ++index) {
      const auto hint = measured_hints[static_cast<qsizetype>(index)].toMap();

      measured.hints.atMut(index) = {.key = advance(hint.value(u"key"_s), density), .word = advance(hint.value(u"word"_s), density)};
    }

    const auto geometry = title_.isEmpty() ? application::status_bar::ModeBarGeometry{} : application::status_bar::ModeBarGeometry::derive({.width = static_cast<float>(width() * density), .height = static_cast<float>(height() * density)}, chrome, measured);
    QVariantList hints;

    for (std::size_t index = 0; index < geometry.count; ++index) {
      hints.append(historyHintRecord(geometry.hints[index], density));
    }

    auto layout = historyHintStyle(ratio_);
    const auto title = geometry.title;

    layout.insert(u"title"_s, QRectF{static_cast<qreal>(title.x) / density, static_cast<qreal>(title.y) / density, static_cast<qreal>(title.width) / density, static_cast<qreal>(title.height) / density});
    layout.insert(u"hints"_s, hints);
    layout.insert(u"hintCount"_s, static_cast<qulonglong>(geometry.count));
    if (layout_ != layout) {
      layout_ = layout;
      layoutChanged();
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
