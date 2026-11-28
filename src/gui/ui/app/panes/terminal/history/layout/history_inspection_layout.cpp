module telar.gui.ui.app.panes.terminal.history.layout;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.input;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    std::string_view bytes(const QByteArray& text) noexcept {
      return {text.constData(), static_cast<std::size_t>(text.size())};
    }

    QString string(std::string_view text) {
      return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
    }

    PaletteRole color(const QString& name) {
      const auto encoded = name.toUtf8();
      const auto* const found = std::ranges::find(palette_names, bytes(encoded));

      return found == palette_names.end() ? PaletteRole::text : static_cast<PaletteRole>(found - palette_names.begin());
    }

  }

  HistoryInspectionLayout::HistoryInspectionLayout(QQuickItem* parent)
      : QQuickItem(parent) {}

  QVariantMap HistoryInspectionLayout::input() const {
    return input_;
  }

  void HistoryInspectionLayout::setInput(const QVariantMap& input) {
    if (input_ == input) {
      return;
    }

    const auto identity_changed = input_.value(u"identity"_s) != input.value(u"identity"_s);

    input_ = input;
    choice_ = {.index = static_cast<std::size_t>(input_.value(u"selection"_s).toULongLong()), .revision = input_.value(u"revision"_s).toULongLong()};
    pane_open_ = input_.value(u"paneOpen"_s).toBool();
    ready_ = input_.value(u"ready"_s).toBool();
    if (identity_changed) {
      setScroll(0);
    }

    inputChanged();
    polish();
  }

  QVariantList HistoryInspectionLayout::advances() const {
    return advances_;
  }

  void HistoryInspectionLayout::setAdvances(const QVariantList& advances) {
    if (advances_ != advances) {
      advances_ = advances;
      advancesChanged();
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
      scrollChanged();
      polish();
    }
  }

  QRectF HistoryInspectionLayout::logical(Rect area) const noexcept {
    return {static_cast<qreal>(area.x) / density_, static_cast<qreal>(area.y) / density_, static_cast<qreal>(area.width) / density_, static_cast<qreal>(area.height) / density_};
  }

  float HistoryInspectionLayout::physical(const QVariant& value) const {
    const auto measured = value.toDouble();

    return std::isfinite(measured) && measured > 0 ? static_cast<float>(measured * density_) : 0;
  }

  ChromeMetrics HistoryInspectionLayout::metrics(qreal ratio) const {
    const auto pixels = [&](const QString& name) {
      return static_cast<std::uint16_t>(std::clamp(std::round(physical(input_.value(name))), 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
    };

    ChromeMetrics chrome;

    chrome.ratio = static_cast<float>(ratio * density_);
    chrome.body = pixels(u"bodyPixels"_s);
    chrome.small = pixels(u"smallPixels"_s);

    return chrome;
  }

  QVariantMap HistoryInspectionLayout::projectLine(const application::history::HistoryInspectionLine& line, const application::history::HistoryInspectionGeometry& geometry, std::uint16_t index) const {
    const auto row = geometry.row(index);

    return {
        {u"command"_s, line.kind == application::history::HistoryInspectionLine::Kind::command},
        {u"fact"_s, line.kind == application::history::HistoryInspectionLine::Kind::fact},
        {u"heading"_s, line.kind == application::history::HistoryInspectionLine::Kind::heading},
        {u"text"_s, string(line.text)},
        {u"label"_s, string(line.label)},
        {u"color"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(line.color)])},
        {u"mono"_s, line.mono},
        {u"bounds"_s, logical(row)},
        {u"textBounds"_s, logical(geometry.text(row, line.kind))},
        {u"labelWidth"_s, static_cast<qreal>(geometry.label_width) / density_},
    };
  }

  QVariantMap HistoryInspectionLayout::prepareContent(const application::history::HistoryInspectionGeometry& geometry) {
    const auto command = input_.value(u"command"_s).toString().toUtf8();
    const auto output = input_.value(u"output"_s).toString().toUtf8();
    const auto heading = input_.value(u"heading"_s).toString().toUtf8();
    const auto records = input_.value(u"facts"_s).toList();
    ds::Array<QByteArray, application::history::HistoryInspectionFacts::count> texts;
    ds::Array<QByteArray, application::history::HistoryInspectionFacts::count> labels;
    ds::Array<application::history::HistoryInspectionLine, application::history::HistoryInspectionFacts::count> facts;
    const auto fact_count = std::min(facts.size(), static_cast<std::size_t>(records.size()));

    // Every text is stored before any fact views one, as Rust lends no element of an array it still
    // writes by index.
    for (std::size_t index = 0; index < fact_count; ++index) {
      const auto record = records[static_cast<qsizetype>(index)].toMap();

      texts.atMut(index) = record.value(u"text"_s).toString().toUtf8();
      labels.atMut(index) = record.value(u"label"_s).toString().toUtf8();
    }

    for (std::size_t index = 0; index < fact_count; ++index) {
      const auto record = records[static_cast<qsizetype>(index)].toMap();

      facts.atMut(index) = {.kind = application::history::HistoryInspectionLine::Kind::fact, .text = bytes(texts[index]), .label = bytes(labels[index]), .color = color(record.value(u"color"_s).toString()), .mono = record.value(u"mono"_s).toBool()};
    }

    application::history::HistoryInspectionLines lines{{.command = bytes(command), .facts = std::span{facts}.first(fact_count), .heading = bytes(heading), .output = bytes(output)}, geometry.columns};
    const auto total = lines.count();
    const auto maximum_scroll = static_cast<int>(total - std::min(total, static_cast<std::uint32_t>(geometry.rows)));
    const auto next_scroll = std::min(scroll_, maximum_scroll);
    if (next_scroll != scroll_) {
      scroll_ = next_scroll;
      scrollChanged();
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
        {u"content"_s, logical(geometry.content)},
        {u"lines"_s, visible},
        {u"lineCount"_s, total},
        {u"maximumScroll"_s, maximum_scroll},
    };
  }

  QVariantList HistoryInspectionLayout::prepareButtons(const application::history::HistoryInspectionGeometry& geometry, ChromeMetrics chrome) {
    ds::Array<float, application::history::HistoryInspectionGeometry::maximum_actions> measured{};
    const auto action_count = std::min(measured.size(), static_cast<std::size_t>(advances_.size()));

    for (std::size_t index = 0; index < action_count; ++index) {
      measured.atMut(index) = physical(advances_[static_cast<qsizetype>(index)]);
    }

    button_bounds_ = geometry.columns == 0 ? decltype(button_bounds_){} : geometry.buttons(std::span{measured}.first(action_count), chrome);
    QVariantList buttons;

    for (const auto button : button_bounds_) {
      buttons.append(logical(button));
    }

    return buttons;
  }

  std::size_t HistoryInspectionLayout::hoverTargets(std::uint64_t generation, std::span<application::history::HistoryHoverTarget> destination) const {
    if (!isVisible() || window() == nullptr) {
      return 0;
    }

    constexpr ds::Array actions{application::history::HistoryInspectionAction::submit, application::history::HistoryInspectionAction::alternate, application::history::HistoryInspectionAction::copy, application::history::HistoryInspectionAction::erase, application::history::HistoryInspectionAction::visit};
    std::size_t count = 0;

    for (std::size_t index = 0; index < actions.size() && count < destination.size(); ++index) {
      const auto action = actions[index];
      if (button_bounds_[index].empty() || (action == application::history::HistoryInspectionAction::visit && (!pane_open_ || !ready_))) {
        continue;
      }

      const auto bounds = mapRectToScene(logical(button_bounds_[index]));

      destination[count++] = {.identity = {.action = application::history::HistoryInspectionIdentity{.action = action, .choice = choice_}, .generation = generation}, .bounds = {.x = static_cast<float>(bounds.x() * density_), .y = static_cast<float>(bounds.y() * density_), .width = static_cast<float>(bounds.width() * density_), .height = static_cast<float>(bounds.height() * density_)}};
    }

    return count;
  }

  void HistoryInspectionLayout::updatePolish() {
    const auto ratio = input_.value(u"ratio"_s, 1).toDouble();
    if (!std::isfinite(ratio) || ratio <= 0) {
      return;
    }

    density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    const auto chrome = metrics(ratio);
    const auto geometry = application::history::HistoryInspectionGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, chrome, {.x = physical(input_.value(u"cellWidth"_s)), .y = physical(input_.value(u"cellHeight"_s))});

    layout_ = prepareContent(geometry);
    layout_.insert(u"buttons"_s, prepareButtons(geometry, chrome));
    layout_.insert(u"buttonRadius"_s, static_cast<double>(application::history::HistoryInspectionGeometry::button_radius) * ratio);
    layout_.insert(u"disabledAlpha"_s, application::history::HistoryInspectionGeometry::disabled_alpha);
    layout_.insert(u"pressedAlpha"_s, application::history::HistoryInspectionGeometry::pressed_alpha);
    layoutChanged();
  }

  void HistoryInspectionLayout::componentComplete() {
    QQuickItem::componentComplete();
    updatePolish();
  }

  void HistoryInspectionLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    polish();
  }

  void HistoryInspectionLayout::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
      polish();
    }
  }

  void HistoryInspectionLayout::wheelEvent(QWheelEvent* event) {
    if (input_.value(u"interactive"_s).toBool()) {
      const auto lines = wheel_.consume(scrollSample(*event, input_.value(u"cellHeight"_s).toDouble()));

      setScroll(scroll_ + lines);
    }

    event->accept();
  }

}
