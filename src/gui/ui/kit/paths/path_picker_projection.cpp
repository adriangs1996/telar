module telar.gui.ui.kit.paths;

import std;
import telar.gui.qt;
import telar.gui.qt.platform;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.foundation.terminal;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.foundation.icons;
import telar.gui.foundation.text;
import telar.wire.vocabulary;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    // A folder's icon, or a file's by its name.
    GlyphIcon iconOf(std::string_view path, PathKind kind) noexcept {
      return kind == PathKind::directory ? directoryIcon() : fileIcon(path);
    }

    template <typename MapBounds>
    QVariantList pathRows(const application::paths::PathPickerPage& page, const application::paths::PathPickerGeometry& geometry, std::size_t selection, MapBounds local) {
      constexpr std::uint16_t label_inset = 3;
      constexpr std::uint16_t icon_inset = 1;
      QVariantList rows;

      rows.reserve(static_cast<qsizetype>(geometry.row_count));
      for (std::size_t index = 0; index < geometry.row_count; ++index) {
        const auto& row = geometry.rows[index];
        const auto& match = page.matches()[row.index];
        const auto label_offset = std::min(row.bounds.width, label_inset);
        auto available = row.bounds;

        available.x = static_cast<std::uint16_t>(available.x + label_offset);
        available.width = static_cast<std::uint16_t>(available.width - label_offset);
        application::paths::PathLabel label;

        label.layout(page.path(match), match.highlights(), available.width);
        QVariantList runs;

        runs.reserve(static_cast<qsizetype>(label.runs().size()));
        for (const auto& run : label.runs()) {
          if (available.width == 0) {
            break;
          }

          const auto columns = static_cast<std::uint16_t>(std::min<std::uint32_t>(available.width, cellTextColumns(run.text)));
          auto run_bounds = available;

          run_bounds.width = columns;

          runs.append(QVariantMap{{u"text"_s, toQString(run.text)}, {u"bounds"_s, local(run_bounds)}, {u"colorRole"_s, pathRunColor(run.tone)}, {u"bold"_s, run.tone == application::paths::PathLabelTone::match}});
          available.x = static_cast<std::uint16_t>(available.x + columns);
          available.width = static_cast<std::uint16_t>(available.width - columns);
        }

        auto icon = row.bounds;
        const auto inset = std::min(icon.width, icon_inset);

        icon.x = static_cast<std::uint16_t>(icon.x + inset);
        icon.width = static_cast<std::uint16_t>(std::min<std::uint16_t>(1, icon.width - inset));
        QVariantMap record{
            {u"path"_s, toQString(page.path(match))},
            {u"bounds"_s, local(row.bounds)},
            {u"iconBounds"_s, local(icon)},
            {u"directory"_s, match.kind == PathKind::directory},
            {u"selected"_s, row.index == selection},
            {u"runs"_s, std::move(runs)},
        };

        putIcon(record, iconOf(page.path(match), match.kind));
        putChange(record, match.change);
        rows.append(std::move(record));
      }

      return rows;
    }

  }

  QVariantList PathPickerController::rows(int columns, int first, int count) const {
    const auto page = application::paths::page(store_.session());
    const auto& matches = page.matches();
    const auto begin = std::min(static_cast<std::size_t>(std::max(0, first)), matches.size());
    const auto end = std::min(matches.size(), begin + static_cast<std::size_t>(std::max(0, count)));
    const auto width = static_cast<std::uint16_t>(std::clamp(columns, 1, static_cast<int>(std::numeric_limits<std::uint16_t>::max())));
    QVariantList rows;

    rows.reserve(static_cast<qsizetype>(end - begin));
    for (auto index = begin; index < end; ++index) {
      const auto& match = matches[index];

      QVariantMap record{
          {u"index"_s, static_cast<qulonglong>(index)},
          {u"path"_s, toQString(page.path(match))},
          {u"directory"_s, match.kind == PathKind::directory},
          {u"selected"_s, index == selection_},
          {u"runs"_s, pathLabelRuns(page.path(match), match.highlights(), width)},
      };

      putIcon(record, iconOf(page.path(match), match.kind));
      putChange(record, match.change);
      rows.append(std::move(record));
    }

    return rows;
  }

  application::paths::PathPickerPlacement PathPickerController::placement() {
    // Arranging the layout caches its placements, so the session is read through its mutable side.
    auto& session = store_.sessionMut();
    const auto& workbench = application::workbench::geometry(session);
    const auto host = workbench.cellArea();
    auto* tab = session.activeTabMut();
    ds::Option<CellPosition> cursor;

    if (tab != nullptr) {
      const auto fullscreen = tab->fullscreen ? ds::Option{tab->focused_pane} : ds::none;

      for (const auto& placement : tab->layout.arrange(host, workbench.layout_metrics, fullscreen)) {
        const auto* pane = session.findPane(placement.pane_id);
        if (pane == nullptr || pane->id != tab->focused_pane || !pane->attached) {
          continue;
        }

        const auto& point = pane->screen.cursor();
        if (point.x < placement.content.width && point.y < placement.content.height) {
          cursor = CellPosition{.x = static_cast<std::uint16_t>(placement.content.x + point.x), .y = static_cast<std::uint32_t>(placement.content.y) + point.y};
        }

        break;
      }
    }

    return application::paths::PathPickerPlacement::forPage(host, cursor, static_cast<std::uint16_t>(application::paths::page(session).matches().size()));
  }

  QVariantMap PathPickerController::geometry() {
    const auto& display = display_;
    const auto density = display.density;
    const auto& workbench = application::workbench::geometry(store_.session());
    const auto page = application::paths::page(store_.session());
    const auto placement = this->placement();
    const auto count_text = application::paths::PathPickerLabels::count(page);
    const auto geometry = application::paths::PathPickerGeometry::measure(placement, page.matches().size(), selection_, {
                                                                                                                            .root = static_cast<std::uint16_t>(cellTextColumns(application::paths::PathPickerLabels::root(page.root()))),
                                                                                                                            .count = static_cast<std::uint16_t>(cellTextColumns(count_text.view())),
                                                                                                                        });

    auto bounds = workbench.pixels(placement.area);

    bounds.x += display.geometry.terminal.x;
    bounds.y += display.geometry.terminal.y;
    const auto local = [&](CellRectangle cells) {
      auto area = workbench.pixels(cells);

      area.x += display.geometry.terminal.x - bounds.x;
      area.y += display.geometry.terminal.y - bounds.y;

      return toQRectF(area, density);
    };

    auto fonts = ChromeFonts::shared();
    const auto footer = application::paths::PathPickerFooter::measure(geometry.footer, application::paths::PathPickerLabels::status(page).view(), platform::usesCommandKey(), [&](std::string_view text) {
      const auto advance = fonts->face(false).shape(text, display.chrome.body).advance();

      return static_cast<std::uint32_t>(std::ceil(static_cast<double>(std::max(0, advance)) / std::max<std::uint16_t>(1, workbench.grid.cell_width_px)));
    });

    QVariantList hints;

    hints.reserve(static_cast<qsizetype>(footer.count));
    for (std::size_t index = 0; index < footer.count; ++index) {
      const auto& hint = footer.hints[index];

      hints.append(QVariantMap{{u"key"_s, toQString(hint.label.key)}, {u"word"_s, toQString(hint.label.word)}, {u"keyBounds"_s, local(hint.key)}, {u"wordBounds"_s, local(hint.word)}});
    }

    return {
        {u"bounds"_s, toQRectF(bounds, density)},
        {u"root"_s, local(geometry.root_label)},
        {u"query"_s, local(geometry.query)},
        {u"count"_s, local(geometry.count_label)},
        {u"footer"_s, local(geometry.footer)},
        {u"empty"_s, local(geometry.empty)},
        {u"flipped"_s, placement.flipped},
        {u"rows"_s, pathRows(page, geometry, selection_, local)},
        {u"hints"_s, std::move(hints)},
    };
  }

}
