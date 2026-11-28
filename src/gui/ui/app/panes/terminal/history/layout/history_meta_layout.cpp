module telar.gui.ui.app.panes.terminal.history.layout;

import std;
import telar.gui.qt;
import telar.gui.ui.design;
import telar.gui.application;
import telar.base.ds;
import telar.wire.vocabulary;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    QString actionName(application::history::HistoryCardAction action) {
      switch (action) {
      case application::history::HistoryCardAction::copy:
        return u"copy"_s;
      case application::history::HistoryCardAction::erase:
        return u"erase"_s;
      case application::history::HistoryCardAction::visit:
        return u"visit"_s;
      }

      return {};
    }

    std::string_view metaBytes(const QByteArray& text) noexcept {
      return {text.constData(), static_cast<std::size_t>(text.size())};
    }

  }

  HistoryMetaLayout::HistoryMetaLayout(QQuickItem* parent)
      : QQuickItem(parent) {}

  QVariantMap HistoryMetaLayout::input() const {
    return input_;
  }

  void HistoryMetaLayout::setInput(const QVariantMap& input) {
    if (input_ != input) {
      input_ = input;
      prepareLabels();
      inputChanged();
      labelsChanged();
      polish();
    }
  }

  QVariantMap HistoryMetaLayout::measurements() const {
    return measurements_;
  }

  void HistoryMetaLayout::setMeasurements(const QVariantMap& measurements) {
    if (measurements_ != measurements) {
      measurements_ = measurements;
      measurementsChanged();
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
    const auto record = input_.value(u"record"_s).toMap();
    const auto directory = record.value(u"compactCwd"_s, record.value(u"cwd"_s)).toString().toUtf8();
    const auto provider = record.value(u"provider"_s).toString().toUtf8();
    const auto duration = record.value(u"duration"_s).toString().toUtf8();
    const auto age = record.value(u"age"_s).toString().toUtf8();
    const auto style = input_.value(u"macStyle"_s).toBool() ? application::history::HistoryKeyStyle::mac : application::history::HistoryKeyStyle::pc;
    const application::history::HistoryFactData data{
        .directory = metaBytes(directory),
        .provider = metaBytes(provider),
        .duration = metaBytes(duration),
        .age = metaBytes(age),
        .exit_code = record.contains(u"exitCode"_s) ? ds::Option{record.value(u"exitCode"_s).toInt()} : ds::none,
        .status = static_cast<HistoryStatus>(record.value(u"status"_s).toInt()),
        .key_style = style,
        .more = static_cast<std::uint16_t>(std::clamp(input_.value(u"more"_s).toInt(), 0, static_cast<int>(application::history::HistoryCard::more_bound))),
        .truncated = record.value(u"truncated"_s).toBool(),
        .loaded = input_.value(u"loaded"_s, true).toBool(),
        .show_directory = input_.value(u"showDirectory"_s, true).toBool(),
        .has_time = record.contains(u"timestamp"_s) && record.value(u"timestamp"_s).toLongLong() >= 0,
        .agent = record.value(u"author"_s).toString() == u"agent"_s,
    };

    facts_.clear();
    auto append = [this](std::string_view text, PaletteRole color) {
      facts_.append(QVariantMap{
          {u"text"_s, QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()))},
          {u"color"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(color)])},
      });
    };

    application::history::HistoryFacts::visit(data, append);
    actions_.clear();
    for (const auto label : application::history::HistoryActions::labels(style)) {
      actions_.append(QVariantMap{
          {u"key"_s, QString::fromUtf8(label.key.data(), static_cast<qsizetype>(label.key.size()))},
          {u"word"_s, QString::fromUtf8(label.word.data(), static_cast<qsizetype>(label.word.size()))},
          {u"action"_s, actionName(label.action)},
      });
    }
  }

  QRectF HistoryMetaLayout::logical(Rect area) const noexcept {
    return {static_cast<qreal>(area.x) / density_, static_cast<qreal>(area.y) / density_, static_cast<qreal>(area.width) / density_, static_cast<qreal>(area.height) / density_};
  }

  QVariantMap HistoryMetaLayout::layout() const {
    QVariantList facts;

    for (const auto area : geometry_.facts) {
      facts.append(logical(area));
    }

    QVariantList actions;

    for (const auto& geometry : geometry_.actions) {
      actions.append(historyHintRecord(geometry, density_));
    }

    auto result = historyHintStyle(ratio_);

    result.insert(u"facts"_s, facts);
    result.insert(u"actions"_s, actions);
    result.insert(u"factCount"_s, static_cast<qulonglong>(geometry_.fact_count));
    result.insert(u"actionCount"_s, static_cast<qulonglong>(geometry_.action_count));

    return result;
  }

  application::history::HistoryActionSurface HistoryMetaLayout::actionSurface(std::uint64_t generation) const {
    application::history::HistoryActionSurface result{.generation = generation, .scale = density_};
    bool valid_revision = false;
    const auto revision = input_.value(u"revision"_s).toString().toULongLong(&valid_revision);
    const auto history_index = input_.value(u"historyIndex"_s, -1).toInt();
    if (valid_revision && history_index >= 0) {
      result.choice = application::history::HistoryChoice{.index = static_cast<std::size_t>(history_index), .revision = revision};
    }

    if (!isVisible() || window() == nullptr) {
      return result;
    }

    const auto labels = application::history::HistoryActions::labels(application::history::HistoryKeyStyle::pc);

    for (std::size_t index = 0; index < geometry_.action_count; ++index) {
      auto bounds = mapRectToScene(logical(geometry_.actions[index].bounds));

      for (const auto* ancestor = parentItem(); ancestor != nullptr; ancestor = ancestor->parentItem()) {
        if (ancestor->clip()) {
          bounds = bounds.intersected(ancestor->mapRectToScene(ancestor->boundingRect()));
        }
      }

      result.targets.atMut(index) = {.action = labels[index].action, .bounds = {.x = static_cast<float>(bounds.x() * density_), .y = static_cast<float>(bounds.y() * density_), .width = static_cast<float>(bounds.width() * density_), .height = static_cast<float>(bounds.height() * density_)}, .enabled = isEnabled()};
    }

    return result;
  }

  void HistoryMetaLayout::updatePolish() {
    density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    const auto ratio = input_.value(u"ratio"_s, 1).toDouble();
    if (!std::isfinite(ratio) || ratio <= 0) {
      return;
    }

    ratio_ = ratio;
    ChromeMetrics chrome;

    chrome.ratio = static_cast<float>(ratio * density_);
    const auto small = input_.value(u"smallPixels"_s).toDouble() * density_;

    chrome.small = std::isfinite(small) ? static_cast<std::uint16_t>(std::clamp(std::round(small), qreal{0}, qreal{std::numeric_limits<std::uint16_t>::max()})) : 0;
    const auto advance = [this](const QVariant& value) {
      const auto measured = value.toDouble();

      return std::isfinite(measured) && measured > 0 ? static_cast<float>(measured * density_) : 0;
    };

    const auto facts = measurements_.value(u"facts"_s).toList();
    const auto actions = measurements_.value(u"actions"_s).toList();
    application::history::HistoryMetaMeasurements measured;

    measured.fact_count = std::min(static_cast<std::size_t>(facts_.size()), application::history::HistoryFacts::capacity);
    measured.selected = input_.value(u"selected"_s, true).toBool();
    measured.pane_open = input_.value(u"paneOpen"_s).toBool();
    for (std::size_t index = 0; index < measured.fact_count; ++index) {
      measured.facts.atMut(index) = advance(facts.value(static_cast<qsizetype>(index)));
    }

    for (std::size_t index = 0; index < measured.actions.size(); ++index) {
      const auto value = actions.value(static_cast<qsizetype>(index)).toMap();

      measured.actions.atMut(index) = {.key = advance(value.value(u"key"_s)), .word = advance(value.value(u"word"_s))};
    }

    geometry_ = application::history::HistoryMetaGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, chrome, measured);
    layoutChanged();
  }

  void HistoryMetaLayout::componentComplete() {
    QQuickItem::componentComplete();
    updatePolish();
  }

  void HistoryMetaLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    polish();
  }

  void HistoryMetaLayout::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
      polish();
    }
  }

}
