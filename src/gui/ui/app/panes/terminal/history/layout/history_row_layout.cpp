module telar.gui.ui.app.panes.terminal.history.layout;

import std;
import telar.gui.qt;
import telar.gui.foundation.text;
import telar.gui.ui.kit.models;
import telar.gui.application;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  HistoryRowLayout::HistoryRowLayout(QQuickItem* parent)
      : QQuickItem(parent) {}

  QVariantMap HistoryRowLayout::measurements() const {
    return measurements_;
  }

  void HistoryRowLayout::setMeasurements(const QVariantMap& measurements) {
    if (measurements_ != measurements) {
      measurements_ = measurements;
      measurements_dirty_ = true;
      measurementsChanged();
      polish();
    }
  }

  void HistoryRowLayout::setRanges(const QVariantList& ranges) {
    if (ranges_ == ranges) {
      return;
    }

    ranges_ = ranges;
    prepareMatches();
    query_dirty_ = true;
    rangesChanged();
    polish();
  }

  void HistoryRowLayout::publishLines() {
    query_dirty_ = false;
    lineLayoutChanged();
    layoutChanged();
  }

  QRectF HistoryRowLayout::logical(Rect area) const noexcept {
    return {static_cast<qreal>(area.x) / density_, static_cast<qreal>(area.y) / density_, static_cast<qreal>(area.width) / density_, static_cast<qreal>(area.height) / density_};
  }

  QVariantMap HistoryRowLayout::layout() const {
    auto result = geometryLayout();

    result.insert(u"needed"_s, static_cast<qreal>(command_width_) / density_);
    result.insert(u"lines"_s, commandLines());

    return result;
  }

  HistoryRowLayout::GeometryState HistoryRowLayout::geometryState() const noexcept {
    return {.row = geometry_, .density = density_, .ratio = ratio_, .card_height = card_.height, .meta = card_.meta, .more = card_.more};
  }

  QVariantMap HistoryRowLayout::geometryLayout() const {
    return {
        {u"frame"_s, logical(geometry_.frame)},
        {u"status"_s, logical(geometry_.status)},
        {u"command"_s, logical(geometry_.command)},
        {u"provider"_s, logical(geometry_.provider)},
        {u"cwd"_s, logical(geometry_.cwd)},
        {u"time"_s, logical(geometry_.time)},
        {u"detail"_s, logical(geometry_.detail)},
        {u"radius"_s, static_cast<qreal>(application::history::HistoryRowGeometry::corner_radius) * ratio_},
        {u"stroke"_s, ratio_},
        {u"providerRadius"_s, static_cast<qreal>(application::history::HistoryRowGeometry::provider_radius) * ratio_},
        {u"selectionTintAlpha"_s, application::history::HistoryRowGeometry::selection_tint_alpha},
        {u"selectionRingAlpha"_s, application::history::HistoryRowGeometry::selection_ring_alpha},
        {u"hoverAlpha"_s, application::history::HistoryRowGeometry::hover_alpha},
        {u"cwdAlpha"_s, application::history::HistoryRowGeometry::cwd_alpha},
        {u"cardHeight"_s, static_cast<qreal>(card_.height) / density_},
        {u"meta"_s, logical(card_.meta)},
        {u"more"_s, card_.more},
        {u"moreBound"_s, application::history::HistoryCard::more_bound},
    };
  }

  void HistoryRowLayout::setHistoryIndex(int index) {
    if (history_index_ != index) {
      history_index_ = index;
      historyIndexChanged();
    }
  }

  Rect HistoryRowLayout::physicalFrame() const noexcept {
    return geometry_.frame;
  }

  QVariantMap HistoryRowLayout::commandLine(std::string_view text, std::size_t offset, Rect bounds, bool continues, HistoryMatchHighlight& highlight) const {
    const auto needed = static_cast<float>(cellTextColumns(text)) * cell_width_;
    const auto line = application::history::HistoryCommandLine::derive(bounds, {.needed = needed, .cell_width = cell_width_, .continues = continues});
    QVariantList matches;
    auto record = [&](Rect area, std::string_view cluster) {
      matches.append(QVariantMap{
          {u"bounds"_s, logical(area)},
          {u"text"_s, QString::fromUtf8(cluster.data(), static_cast<qsizetype>(cluster.size()))},
      });
    };

    highlight.paint(text, offset, line.text, cell_width_, record);

    return {
        {u"runs"_s, styledRuns(text, offset, line.text)},
        {u"text"_s, QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()))},
        {u"bounds"_s, logical(line.text)},
        {u"markerBounds"_s, logical(line.marker)},
        {u"marker"_s, QString::fromUtf8(line.mark.data(), static_cast<qsizetype>(line.mark.size()))},
        {u"matches"_s, matches},
    };
  }

  QVariantList HistoryRowLayout::commandLines() const {
    HistoryMatchHighlight highlight{matches_};
    QVariantList result;

    if (!expanded_) {
      const std::string_view text{command_bytes_.constData(), static_cast<std::size_t>(command_bytes_.size())};
      const auto end = text.find_first_of("\r\n");

      result.append(commandLine(text.substr(0, end), 0, geometry_.command, end != std::string_view::npos, highlight));

      return result;
    }

    const std::string_view command{command_bytes_.constData(), static_cast<std::size_t>(command_bytes_.size())};

    for (std::uint16_t index = 0; index < card_.shown; ++index) {
      const Rect area{.x = geometry_.command.x, .y = card_.text_y + (static_cast<float>(index) * cell_height_), .width = geometry_.command.width, .height = cell_height_};

      result.append(commandLine(application::history::HistoryCard::line(command, card_.lines[index]), card_.lines[index].offset, area, false, highlight));
    }

    return result;
  }

  void HistoryRowLayout::prepareCommand() {
    const auto text = measurements_.value(u"commandText"_s).toString();
    if (command_text_ != text) {
      command_text_ = text;
      command_bytes_ = text.toUtf8();
      const std::string_view bytes{command_bytes_.constData(), static_cast<std::size_t>(command_bytes_.size())};

      first_line_columns_ = cellTextColumns(bytes.substr(0, bytes.find_first_of("\r\n")));
      prepareMatches();
      styled_ = false;
    }
  }

  namespace {

    // The theme role a style of shell syntax takes, and the chrome colour a theme without it
    // gives, as the prompt line's editor colours them.
    std::pair<QString, QString> styleRole(application::prompt::Style style) {
      switch (style) {
      case application::prompt::Style::command:
        return {u"syntax_func"_s, u"text"_s};
      case application::prompt::Style::option:
      case application::prompt::Style::variable:
        return {u"syntax_parameter"_s, u"text"_s};
      case application::prompt::Style::string:
        return {u"syntax_string"_s, u"text"_s};
      case application::prompt::Style::shell_operator:
        return {u"syntax_operator"_s, u"subtext0"_s};
      case application::prompt::Style::keyword:
        return {u"syntax_keyword"_s, u"accent"_s};
      case application::prompt::Style::comment:
        return {u"syntax_comment"_s, u"subtext0"_s};
      case application::prompt::Style::error:
      case application::prompt::Style::missing:
      case application::prompt::Style::hidden:
      // An option its command refuses reads as the editor marks it, an error.
      case application::prompt::Style::rejected:
        return {u"red"_s, u"red"_s};
      case application::prompt::Style::plain:
      case application::prompt::Style::pending:
      case application::prompt::Style::ghost:
      case application::prompt::Style::path:
        break;
      }

      return {u"text"_s, u"text"_s};
    }

  }

  void HistoryRowLayout::prepareStyles() {
    // Only the card shows the command whole, in the shell's colours.
    if (!expanded_ || styled_) {
      return;
    }

    const std::string_view command{command_bytes_.constData(), static_cast<std::size_t>(command_bytes_.size())};

    styles_.clear();
    styles_.resize(command.size(), application::prompt::Style::plain);
    application::prompt::classify(command, styles_.viewMut(), tokens_);
    styled_ = true;
  }

  QVariantList HistoryRowLayout::styledRuns(std::string_view text, std::size_t offset, Rect bounds) const {
    if (!styled_ || offset + text.size() > styles_.size()) {
      return {};
    }

    QVariantList runs;

    std::size_t start = 0;
    std::uint32_t column = 0;

    // One run per style, at the cells the text before it takes.
    while (start < text.size()) {
      const auto style = styles_[offset + start];
      auto end = start + 1;

      while (end < text.size() && styles_[offset + end] == style) {
        ++end;
      }

      const auto piece = text.substr(start, end - start);
      const auto columns = cellTextColumns(piece);
      const auto [role, fallback] = styleRole(style);
      const Rect area{.x = bounds.x + (static_cast<float>(column) * cell_width_), .y = bounds.y, .width = static_cast<float>(columns) * cell_width_, .height = bounds.height};

      runs.append(QVariantMap{
          {u"text"_s, QString::fromUtf8(piece.data(), static_cast<qsizetype>(piece.size()))},
          {u"role"_s, role},
          {u"fallback"_s, fallback},
          {u"bounds"_s, logical(area)},
      });

      column += columns;
      start = end;
    }

    return runs;
  }

  void HistoryRowLayout::prepareMatches() {
    matches_ = historyMatches(ranges_, static_cast<std::size_t>(command_bytes_.size()));
  }

  void HistoryRowLayout::updatePolish() {
    if (!measurements_dirty_) {
      if (query_dirty_) {
        publishLines();
      }

      return;
    }

    const auto density = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    const auto advance = [&](const QString& name) {
      const auto value = measurements_.value(name).toDouble();

      return std::isfinite(value) && value > 0 ? static_cast<float>(value * density) : 0;
    };

    const auto ratio = measurements_.value(u"ratio"_s, 1).toDouble();
    if (!std::isfinite(ratio) || ratio <= 0) {
      return;
    }

    ChromeMetrics chrome;

    chrome.ratio = static_cast<float>(ratio * density);
    chrome.small = static_cast<std::uint16_t>(std::clamp(std::round(advance(u"smallPixels"_s)), 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
    prepareCommand();
    const auto cell_width = std::max(1.0F, std::round(advance(u"cellWidth"_s)));
    const auto cell_height = std::max(1.0F, std::round(advance(u"cellHeight"_s)));
    const auto command_width = static_cast<float>(first_line_columns_) * cell_width;
    const application::history::HistoryRowMeasurements measured{
        .command = command_width,
        .cwd = advance(u"cwd"_s),
        .time = advance(u"time"_s),
        .detail = advance(u"detail"_s),
        .agent = measurements_.value(u"agent"_s).toBool(),
        .show_cwd = measurements_.value(u"showCwd"_s).toBool(),
        .has_cwd = measurements_.value(u"hasCwd"_s).toBool(),
        .has_time = measurements_.value(u"hasTime"_s).toBool(),
        .has_detail = measurements_.value(u"hasDetail"_s).toBool(),
        .expanded = measurements_.value(u"expanded"_s).toBool(),
    };

    const auto row_height = advance(u"rowHeight"_s);
    const auto geometry = application::history::HistoryRowGeometry::derive({.width = static_cast<float>(width() * density), .height = static_cast<float>(height() * density)}, chrome, row_height, measured);
    if (geometry != geometry_ || std::not_equal_to<>{}(density, density_) || std::not_equal_to<>{}(ratio, ratio_) || std::not_equal_to<>{}(command_width, command_width_) || measurements_dirty_) {
      const auto previous_geometry = geometryState();

      geometry_ = geometry;
      density_ = density;
      ratio_ = ratio;
      command_width_ = command_width;
      cell_width_ = cell_width;
      cell_height_ = cell_height;
      expanded_ = measured.expanded;
      prepareStyles();

      card_ = expanded_ ? application::history::HistoryCard::measure(geometry_, chrome, {.cell_width = cell_width, .cell_height = cell_height, .row_height = row_height, .viewport_height = advance(u"viewportHeight"_s)}, {command_bytes_.constData(), static_cast<std::size_t>(command_bytes_.size())}) : application::history::HistoryCard{};
      if (expanded_) {
        const auto raw_open = measurements_.value(u"open"_s, 1).toFloat();
        const auto open = std::isfinite(raw_open) ? std::clamp(raw_open, 0.0F, 1.0F) : 0.0F;
        const auto delta = std::max(0.0F, card_.intrinsic_height - row_height) * open;
        const auto opened = std::round(row_height + delta);
        const auto viewport_height = advance(u"viewportHeight"_s);
        const auto tallest = std::max(row_height, viewport_height - chrome.px(application::history::HistoryCard::viewport_clearance));

        card_.height = viewport_height > 0 ? std::min(tallest, opened) : opened;
      }

      measurements_dirty_ = false;
      if (geometryState() != previous_geometry) {
        geometryLayoutChanged();
      }

      publishLines();
    }
  }

  void HistoryRowLayout::componentComplete() {
    QQuickItem::componentComplete();
    updatePolish();
  }

  void HistoryRowLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    if (current.size() != previous.size()) {
      measurements_dirty_ = true;
      polish();
    }
  }

  void HistoryRowLayout::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
      measurements_dirty_ = true;
      polish();
    }
  }

}
