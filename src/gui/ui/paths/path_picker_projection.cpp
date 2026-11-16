#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "path_picker_controller.hpp"
#include "platform/window.hpp"
#include "terminal/cell_position.hpp"
#include "ui/app/projection.hpp"
#include "ui/fonts/chrome_fonts.hpp"
#include <QVariantList>
#include <QVariantMap>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>
#include <utility>

import telar.gui.core.unicode_scalar;
import telar.gui.core.metrics;
import telar.gui.fonts.face;
import telar.gui.paths.label;
import telar.gui.presentation.form_field_geometry;
import telar.gui.text.bounded_editor;

namespace telar::gui::qt {
  namespace {

    QString pathRunColor(PathLabelTone tone) {
      switch (tone) {
      case PathLabelTone::match:
        return QStringLiteral("accent");
      case PathLabelTone::name:
        return QStringLiteral("text");
      default:
        return QStringLiteral("subtext0");
      }
    }

    template <typename MapBounds>
    QVariantList pathRows(const PathPickerPage& page, const PathPickerGeometry& geometry, std::size_t selection, MapBounds local) {
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
        PathLabel label;

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

          runs.append(QVariantMap{{QStringLiteral("text"), toQString(run.text)}, {QStringLiteral("bounds"), local(run_bounds)}, {QStringLiteral("colorRole"), pathRunColor(run.tone)}, {QStringLiteral("bold"), run.tone == PathLabelTone::match}});
          available.x = static_cast<std::uint16_t>(available.x + columns);
          available.width = static_cast<std::uint16_t>(available.width - columns);
        }

        auto icon = row.bounds;
        const auto inset = std::min(icon.width, icon_inset);

        icon.x = static_cast<std::uint16_t>(icon.x + inset);
        icon.width = static_cast<std::uint16_t>(std::min<std::uint16_t>(1, icon.width - inset));
        rows.append(QVariantMap{
            {QStringLiteral("path"), toQString(page.path(match))},
            {QStringLiteral("bounds"), local(row.bounds)},
            {QStringLiteral("iconBounds"), local(icon)},
            {QStringLiteral("directory"), match.kind == PathKind::directory},
            {QStringLiteral("selected"), row.index == selection},
            {QStringLiteral("runs"), std::move(runs)},
        });
      }

      return rows;
    }

  }

  QVariantList PathPickerController::rows(int columns, int first, int count) const {
    const auto& page = store_.session().pathPicker();
    const auto& matches = page.matches();
    const auto begin = std::min(static_cast<std::size_t>(std::max(0, first)), matches.size());
    const auto end = std::min(matches.size(), begin + static_cast<std::size_t>(std::max(0, count)));
    const auto width = static_cast<std::uint16_t>(std::clamp(columns, 1, static_cast<int>(std::numeric_limits<std::uint16_t>::max())));
    QVariantList rows;

    rows.reserve(static_cast<qsizetype>(end - begin));
    for (auto index = begin; index < end; ++index) {
      const auto& match = matches[index];
      PathLabel label;

      label.layout(page.path(match), match.highlights(), width);
      QVariantList runs;

      runs.reserve(static_cast<qsizetype>(label.runs().size()));
      for (const auto& run : label.runs()) {
        runs.append(QVariantMap{{QStringLiteral("text"), toQString(run.text)}, {QStringLiteral("colorRole"), pathRunColor(run.tone)}, {QStringLiteral("bold"), run.tone == PathLabelTone::match}});
      }

      rows.append(QVariantMap{
          {QStringLiteral("index"), static_cast<qulonglong>(index)},
          {QStringLiteral("path"), toQString(page.path(match))},
          {QStringLiteral("directory"), match.kind == PathKind::directory},
          {QStringLiteral("selected"), index == selection_},
          {QStringLiteral("runs"), std::move(runs)},
      });
    }

    return rows;
  }

  PathPickerPlacement PathPickerController::placement() const {
    // Arranging the layout caches its placements, so the session is read through its mutable side.
    auto& session = store_.session();
    const auto& workbench = session.workbenchGeometry();
    const auto host = workbench.cellArea();
    auto* tab = session.activeTab();
    std::optional<CellPosition> cursor;

    if (tab != nullptr) {
      const auto fullscreen = tab->fullscreen ? std::optional{tab->focused_pane} : std::nullopt;

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

    return PathPickerPlacement::forPage(host, cursor, static_cast<std::uint16_t>(session.pathPicker().matches().size()));
  }

  QVariantMap PathPickerController::geometry() const {
    const auto& display = display_;
    const auto density = display.density;
    const auto& workbench = store_.session().workbenchGeometry();
    const auto& page = store_.session().pathPicker();
    const auto placement = this->placement();
    const auto count_text = PathPickerLabels::count(page);
    const auto geometry = PathPickerGeometry::measure(placement, page.matches().size(), selection_, {
                                                                                                        .root = static_cast<std::uint16_t>(cellTextColumns(PathPickerLabels::root(page.root()))),
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

    const auto fonts = ChromeFonts::shared();
    const auto footer = PathPickerFooter::measure(geometry.footer, PathPickerLabels::status(page).view(), platform::usesCommandKey(), [&](std::string_view text) {
      const auto advance = fonts->face(false).shape(text, display.chrome.body).advance();

      return static_cast<std::uint32_t>(std::ceil(static_cast<double>(std::max(0, advance)) / std::max<std::uint16_t>(1, workbench.grid.cell_width_px)));
    });

    QVariantList hints;

    hints.reserve(static_cast<qsizetype>(footer.count));
    for (std::size_t index = 0; index < footer.count; ++index) {
      const auto& hint = footer.hints[index];

      hints.append(QVariantMap{{QStringLiteral("key"), toQString(hint.label.key)}, {QStringLiteral("word"), toQString(hint.label.word)}, {QStringLiteral("keyBounds"), local(hint.key)}, {QStringLiteral("wordBounds"), local(hint.word)}});
    }

    return {
        {QStringLiteral("bounds"), toQRectF(bounds, density)},
        {QStringLiteral("root"), local(geometry.root_label)},
        {QStringLiteral("query"), local(geometry.query)},
        {QStringLiteral("count"), local(geometry.count_label)},
        {QStringLiteral("footer"), local(geometry.footer)},
        {QStringLiteral("empty"), local(geometry.empty)},
        {QStringLiteral("flipped"), placement.flipped},
        {QStringLiteral("rows"), pathRows(page, geometry, selection_, local)},
        {QStringLiteral("hints"), std::move(hints)},
    };
  }

}
