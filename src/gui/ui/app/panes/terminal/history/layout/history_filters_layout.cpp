module telar.gui.ui.app.panes.terminal.history.layout;

import std;
import telar.gui.qt;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    QString label(std::string_view value) {
      return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
    }

  }

  HistoryFiltersLayout::HistoryFiltersLayout(QQuickItem* parent)
      : QQuickItem(parent) {}

  QVariantMap HistoryFiltersLayout::input() const {
    return input_;
  }

  void HistoryFiltersLayout::setInput(const QVariantMap& input) {
    if (input_ != input) {
      input_ = input;
      prepareLabels();
      inputChanged();
      labelsChanged();
      polish();
    }
  }

  QVariantMap HistoryFiltersLayout::measurements() const {
    return measurements_;
  }

  void HistoryFiltersLayout::setMeasurements(const QVariantMap& measurements) {
    if (measurements_ != measurements) {
      measurements_ = measurements;
      measurementsChanged();
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
    const auto scope = input_.value(u"scope"_s).toString();
    const auto author = input_.value(u"author"_s).toString();
    const auto value = input_.value(u"scopeValue"_s).toString();

    scope_choices_.clear();
    for (const auto& choice : application::history::HistoryFilterLabels::scopes) {
      const auto route = label(choice.value);
      const auto selected = route == scope;

      scope_choices_.append(QVariantMap{{u"text"_s, label(choice.text)}, {u"value"_s, route}, {u"detail"_s, selected ? value : QString{}}, {u"selected"_s, selected}});
    }

    author_choices_.clear();
    for (const auto& choice : application::history::HistoryFilterLabels::authors) {
      const auto route = label(choice.value);

      author_choices_.append(QVariantMap{{u"text"_s, label(choice.text)}, {u"value"_s, route}, {u"selected"_s, route == author}});
    }

    key_labels_.clear();
    const auto keys = application::history::HistoryFilterLabels::keys(input_.value(u"macStyle"_s).toBool() ? application::history::HistoryKeyStyle::mac : application::history::HistoryKeyStyle::pc);

    for (const auto key : keys) {
      key_labels_.append(label(key));
    }
  }

  QRectF HistoryFiltersLayout::logical(Rect area) const noexcept {
    return {static_cast<qreal>(area.x) / density_, static_cast<qreal>(area.y) / density_, static_cast<qreal>(area.width) / density_, static_cast<qreal>(area.height) / density_};
  }

  QVariantMap HistoryFiltersLayout::chipRecord(const application::history::HistoryFilterChipGeometry& chip) const {
    const auto local = [&chip](Rect area) {
      area.x -= chip.bounds.x;
      area.y -= chip.bounds.y;

      return area;
    };

    return {{u"bounds"_s, logical(chip.bounds)}, {u"label"_s, logical(local(chip.label))}, {u"value"_s, logical(local(chip.value))}};
  }

  QVariantMap HistoryFiltersLayout::layout() const {
    QVariantList scopes;

    for (const auto& chip : geometry_.scopes) {
      scopes.append(chipRecord(chip));
    }

    QVariantList authors;

    for (const auto& chip : geometry_.authors) {
      authors.append(chipRecord(chip));
    }

    QVariantList keys;

    for (const auto& area : geometry_.keys) {
      keys.append(logical(area));
    }

    return {
        {u"scopes"_s, scopes},
        {u"authors"_s, authors},
        {u"keys"_s, keys},
        {u"failed"_s, chipRecord(geometry_.failed)},
        {u"scopeGroup"_s, logical(geometry_.scope_group)},
        {u"authorGroup"_s, logical(geometry_.author_group)},
        {u"separator"_s, logical(geometry_.separator)},
        {u"showKeys"_s, geometry_.show_keys},
        {u"showRight"_s, geometry_.show_right},
        {u"visible"_s, geometry_.visible},
        {u"groupRadius"_s, static_cast<qreal>(application::history::HistoryFilterGeometry::group_radius) * ratio_},
        {u"chipRadius"_s, static_cast<qreal>(application::history::HistoryFilterChipGeometry::corner_radius) * ratio_},
        {u"ringWidth"_s, static_cast<qreal>(application::history::HistoryFilterChipGeometry::ring_width) * ratio_},
        {u"dangerRingAlpha"_s, application::history::HistoryFilterChipGeometry::danger_ring_alpha},
    };
  }

  std::size_t HistoryFiltersLayout::hoverTargets(std::uint64_t generation, std::span<application::history::HistoryHoverTarget> destination) const {
    if (!isVisible() || window() == nullptr || !geometry_.visible) {
      return 0;
    }

    std::size_t count = 0;
    const auto append = [&](application::history::HistoryFilterAction action, Rect area) {
      if (count == destination.size() || area.empty()) {
        return;
      }

      const auto bounds = mapRectToScene(logical(area));

      destination[count++] = {.identity = {.action = action, .generation = generation}, .bounds = {.x = static_cast<float>(bounds.x() * density_), .y = static_cast<float>(bounds.y() * density_), .width = static_cast<float>(bounds.width() * density_), .height = static_cast<float>(bounds.height() * density_)}};
    };

    constexpr ds::Array scopes{application::history::HistoryFilterAction::global, application::history::HistoryFilterAction::workspace, application::history::HistoryFilterAction::cwd, application::history::HistoryFilterAction::pane};

    for (std::size_t index = 0; index < scopes.size(); ++index) {
      append(scopes[index], geometry_.scopes[index].bounds);
    }

    if (geometry_.show_right) {
      append(application::history::HistoryFilterAction::failed, geometry_.failed.bounds);
      constexpr ds::Array authors{application::history::HistoryFilterAction::human, application::history::HistoryFilterAction::agent, application::history::HistoryFilterAction::all};

      for (std::size_t index = 0; index < authors.size(); ++index) {
        append(authors[index], geometry_.authors[index].bounds);
      }
    }

    return count;
  }

  void HistoryFiltersLayout::updatePolish() {
    const auto ratio = input_.value(u"ratio"_s, 1).toDouble();
    if (!std::isfinite(ratio) || ratio <= 0) {
      return;
    }

    ratio_ = ratio;
    density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    ChromeMetrics chrome;

    chrome.ratio = static_cast<float>(ratio_ * density_);
    const auto advance = [this](const QVariant& value) {
      const auto width = value.toDouble();

      return std::isfinite(width) && width > 0 ? static_cast<float>(width * density_) : 0.0F;
    };

    const auto scope_widths = measurements_.value(u"scopes"_s).toList();
    const auto author_widths = measurements_.value(u"authors"_s).toList();
    const auto key_widths = measurements_.value(u"keys"_s).toList();
    application::history::HistoryFilterMeasurements measured;

    for (std::size_t index = 0; index < measured.scopes.size(); ++index) {
      const auto widths = scope_widths.value(static_cast<qsizetype>(index)).toMap();
      const auto choice = scope_choices_.value(static_cast<qsizetype>(index)).toMap();

      measured.scopes.atMut(index) = {.label = advance(widths.value(u"label"_s)), .value = advance(widths.value(u"value"_s)), .has_value = !choice.value(u"detail"_s).toString().isEmpty()};
    }

    for (std::size_t index = 0; index < measured.authors.size(); ++index) {
      measured.authors.atMut(index).label = advance(author_widths.value(static_cast<qsizetype>(index)));
    }

    for (std::size_t index = 0; index < measured.keys.size(); ++index) {
      measured.keys.atMut(index) = advance(key_widths.value(static_cast<qsizetype>(index)));
    }

    measured.failed = advance(measurements_.value(u"failed"_s));
    geometry_ = application::history::HistoryFilterGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, chrome, measured);
    layoutChanged();
  }

  void HistoryFiltersLayout::componentComplete() {
    QQuickItem::componentComplete();
    updatePolish();
  }

  void HistoryFiltersLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    polish();
  }

  void HistoryFiltersLayout::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
      polish();
    }
  }

}
