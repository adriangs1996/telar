module telar.gui.ui.app.panes.terminal.history.layout;

import std;
import telar.gui.qt;
import telar.gui.ui.design;
import telar.gui.application;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    QString actionName(application::history::HistoryFooterAction action) {
      switch (action) {
      case application::history::HistoryFooterAction::none:
        return u"none"_s;
      case application::history::HistoryFooterAction::submit:
        return u"submit"_s;
      case application::history::HistoryFooterAction::alternate:
        return u"alternate"_s;
      case application::history::HistoryFooterAction::inspect:
        return u"inspect"_s;
      case application::history::HistoryFooterAction::visit:
        return u"visit"_s;
      }

      return {};
    }

    QString footerLabel(std::string_view text) {
      return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
    }

  }

  HistoryFooterLayout::HistoryFooterLayout(QQuickItem* parent)
      : QQuickItem(parent) {}

  QVariantMap HistoryFooterLayout::input() const {
    return input_;
  }

  void HistoryFooterLayout::setInput(const QVariantMap& input) {
    if (input_ != input) {
      input_ = input;
      prepareLabels();
      inputChanged();
      labelsChanged();
      polish();
    }
  }

  QVariantMap HistoryFooterLayout::measurements() const {
    return measurements_;
  }

  void HistoryFooterLayout::setMeasurements(const QVariantMap& measurements) {
    if (measurements_ != measurements) {
      measurements_ = measurements;
      measurementsChanged();
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
    const auto state = input_.value(u"state"_s).toMap();
    const application::history::HistoryFooterOptions options{
        .key_style = state.value(u"macStyle"_s).toBool() ? application::history::HistoryKeyStyle::mac : application::history::HistoryKeyStyle::pc,
        .offset = static_cast<std::uint32_t>(std::min(state.value(u"offset"_s).toULongLong(), qulonglong{std::numeric_limits<std::uint32_t>::max()})),
        .count = static_cast<std::uint16_t>(std::clamp(state.value(u"count"_s).toInt(), 0, static_cast<int>(std::numeric_limits<std::uint16_t>::max()))),
        .inspecting = state.value(u"inspecting"_s).toBool(),
        .enter_runs = state.value(u"enterRuns"_s).toBool(),
        .has_more = state.value(u"hasMore"_s).toBool(),
        .match = application::history::HistoryModes::named(state.value(u"match"_s).toString().toStdString()).valueOr(application::history::HistoryFooterOptions{}.match),
    };

    footer_ = application::history::HistoryFooter::resolve(options);
    choice_ = {.index = static_cast<std::size_t>(std::max(0, state.value(u"selection"_s).toInt())), .revision = state.value(u"revision"_s).toString().toULongLong()};

    range_ = footerLabel(application::history::HistoryFooter::range(options).view());
    hints_.clear();
    for (std::size_t index = 0; index < footer_.count; ++index) {
      const auto hint = footer_.hints[index];

      hints_.append(QVariantMap{
          {u"key"_s, footerLabel(hint.key)},
          {u"word"_s, footerLabel(hint.word)},
          {u"action"_s, actionName(hint.action)},
      });
    }
  }

  QRectF HistoryFooterLayout::logical(Rect area) const noexcept {
    return {static_cast<qreal>(area.x) / density_, static_cast<qreal>(area.y) / density_, static_cast<qreal>(area.width) / density_, static_cast<qreal>(area.height) / density_};
  }

  QVariantMap HistoryFooterLayout::layout() const {
    QVariantList hints;

    for (const auto& hint : geometry_.hints) {
      hints.append(historyHintRecord(hint, density_));
    }

    auto result = historyHintStyle(ratio_);

    result.insert(u"hints"_s, hints);
    result.insert(u"hintCount"_s, static_cast<qulonglong>(geometry_.count));
    result.insert(u"separator"_s, logical(geometry_.separator));
    result.insert(u"range"_s, logical(geometry_.range));
    result.insert(u"error"_s, logical(geometry_.error));
    result.insert(u"showRange"_s, geometry_.range_visible);
    result.insert(u"showError"_s, geometry_.error_visible);

    return result;
  }

  std::size_t HistoryFooterLayout::hoverTargets(std::uint64_t generation, std::span<application::history::HistoryHoverTarget> destination) const {
    if (!isVisible() || window() == nullptr) {
      return 0;
    }

    std::size_t count = 0;

    for (std::size_t index = 0; index < geometry_.count && count < destination.size(); ++index) {
      const auto action = footer_.hints[index].action;
      if (action == application::history::HistoryFooterAction::none) {
        continue;
      }

      const auto bounds = mapRectToScene(logical(geometry_.hints[index].bounds));

      destination[count++] = {.identity = {.action = application::history::HistoryFooterIdentity{.action = action, .choice = choice_}, .generation = generation}, .bounds = {.x = static_cast<float>(bounds.x() * density_), .y = static_cast<float>(bounds.y() * density_), .width = static_cast<float>(bounds.width() * density_), .height = static_cast<float>(bounds.height() * density_)}};
    }

    return count;
  }

  void HistoryFooterLayout::updatePolish() {
    const auto ratio = input_.value(u"ratio"_s, 1).toDouble();
    if (!std::isfinite(ratio) || ratio <= 0) {
      return;
    }

    density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    ratio_ = ratio;
    ChromeMetrics chrome;

    chrome.ratio = static_cast<float>(ratio * density_);
    const auto small = input_.value(u"smallPixels"_s).toDouble() * density_;

    chrome.small = std::isfinite(small) ? static_cast<std::uint16_t>(std::clamp(std::round(small), qreal{0}, qreal{std::numeric_limits<std::uint16_t>::max()})) : 0;
    const auto advance = [this](const QVariant& value) {
      const auto measured = value.toDouble();

      return std::isfinite(measured) && measured > 0 ? static_cast<float>(measured * density_) : 0;
    };

    const auto state = input_.value(u"state"_s).toMap();
    const auto hints = measurements_.value(u"hints"_s).toList();
    application::history::HistoryFooterMeasurements measured;

    measured.count = std::min(static_cast<std::size_t>(hints_.size()), application::history::HistoryFooter::capacity);
    measured.range = advance(measurements_.value(u"range"_s));
    measured.empty = state.value(u"count"_s).toInt() == 0;
    measured.error = !state.value(u"error"_s).toString().isEmpty();
    for (std::size_t index = 0; index < measured.count; ++index) {
      const auto hint = hints.value(static_cast<qsizetype>(index)).toMap();

      measured.hints.atMut(index) = {.key = advance(hint.value(u"key"_s)), .word = advance(hint.value(u"word"_s))};
    }

    geometry_ = application::history::HistoryFooterGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, chrome, measured);
    layoutChanged();
  }

  void HistoryFooterLayout::componentComplete() {
    QQuickItem::componentComplete();
    updatePolish();
  }

  void HistoryFooterLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    polish();
  }

  void HistoryFooterLayout::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
      polish();
    }
  }

}
