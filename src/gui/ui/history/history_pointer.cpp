#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "history_controller.hpp"
#include "history_filters_layout.hpp"
#include "history_footer_layout.hpp"
#include "history_inspection_layout.hpp"
#include "history_meta_layout.hpp"
#include "history_row_layout.hpp"
#include "input/wheel_accumulator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "ui/foundation/input/scroll_event.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QString>
#include <QStringView>
#include <QWheelEvent>
#include <QtCore/qobject.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <utility>
#include <variant>

#include "application/dependencies.hpp"
#include "history_meta_layout.hpp"
#include "history_row_layout.hpp"
#include "input/wheel_accumulator.hpp"
#include "ui/foundation/input/scroll_event.hpp"

import telar.gui.input.child_mouse;
import telar.gui.presentation.history_pointer;
import telar.gui.history.browser;
import telar.gui.presentation.history_filter_geometry;
import telar.gui.presentation.history_meta_geometry;
import telar.gui.core.metrics;
import telar.gui.presentation.history_inspection_geometry;

namespace telar::gui::qt {

  void HistoryController::registerPanel(QQuickItem* panel) {
    panel_ = panel;
    search_host_ = panel == nullptr ? nullptr : panel->property("searchHost").value<QQuickItem*>();
    viewport_ = panel == nullptr ? nullptr : panel->property("rowsView").value<QQuickItem*>();
    content_ = viewport_ == nullptr ? nullptr : viewport_->property("contentItem").value<QQuickItem*>();
  }

  int HistoryController::hoveredRow() const {
    const auto& identity = hover_.hovered();
    const auto* row = identity ? std::get_if<HistoryChoice>(&identity->action) : nullptr;

    return row == nullptr ? static_cast<int>(HistoryRowLayout::Index::missing) : static_cast<int>(row->index);
  }

  QString HistoryController::hoveredRowRevision() const {
    const auto& identity = hover_.hovered();
    if (!identity || !std::holds_alternative<HistoryChoice>(identity->action)) {
      return {};
    }

    return hover_revision_;
  }

  QString HistoryController::hoveredCardAction() const {
    const auto& identity = hover_.hovered();
    const auto* action = identity ? std::get_if<HistoryCardAction>(&identity->action) : nullptr;
    if (action == nullptr) {
      return {};
    }

    switch (*action) {
    case HistoryCardAction::copy:
      return QStringLiteral("copy");
    case HistoryCardAction::erase:
      return QStringLiteral("erase");
    case HistoryCardAction::visit:
      return QStringLiteral("visit");
    }

    return {};
  }

  void HistoryController::registerInspector(QQuickItem* inspector) {
    inspector_ = inspector;
  }

  QString HistoryController::hoveredInspectionAction() const {
    const auto& identity = hover_.hovered();
    const auto* inspection = identity ? std::get_if<HistoryInspectionIdentity>(&identity->action) : nullptr;
    if (inspection == nullptr) {
      return {};
    }

    switch (inspection->action) {
    case HistoryInspectionAction::submit:
      return QStringLiteral("submit");
    case HistoryInspectionAction::alternate:
      return QStringLiteral("alternate");
    case HistoryInspectionAction::copy:
      return QStringLiteral("copy");
    case HistoryInspectionAction::erase:
      return QStringLiteral("erase");
    case HistoryInspectionAction::visit:
      return QStringLiteral("visit");
    }

    return {};
  }

  int HistoryController::hoveredInspectionIndex() const {
    const auto& identity = hover_.hovered();
    const auto* inspection = identity ? std::get_if<HistoryInspectionIdentity>(&identity->action) : nullptr;

    return inspection != nullptr && inspection->submission() ? static_cast<int>(inspection->choice.index) : static_cast<int>(HistoryRowLayout::Index::missing);
  }

  QString HistoryController::hoveredInspectionRevision() const {
    const auto& identity = hover_.hovered();
    const auto* inspection = identity ? std::get_if<HistoryInspectionIdentity>(&identity->action) : nullptr;

    return inspection != nullptr && inspection->submission() ? hover_revision_ : QString{};
  }

  void HistoryController::registerFilters(QQuickItem* filters) {
    filter_layout_ = filters;
  }

  QString HistoryController::hoveredFilterAction() const {
    const auto& identity = hover_.hovered();
    const auto* action = identity ? std::get_if<HistoryFilterAction>(&identity->action) : nullptr;
    if (action == nullptr) {
      return {};
    }

    switch (*action) {
    case HistoryFilterAction::global:
      return QStringLiteral("global");
    case HistoryFilterAction::workspace:
      return QStringLiteral("workspace");
    case HistoryFilterAction::cwd:
      return QStringLiteral("cwd");
    case HistoryFilterAction::pane:
      return QStringLiteral("pane");
    case HistoryFilterAction::human:
      return QStringLiteral("human");
    case HistoryFilterAction::agent:
      return QStringLiteral("agent");
    case HistoryFilterAction::all:
      return QStringLiteral("all");
    case HistoryFilterAction::failed:
      return QStringLiteral("failed");
    }

    return {};
  }

  void HistoryController::registerFooter(QQuickItem* footer) {
    footer_ = footer;
  }

  QString HistoryController::hoveredFooterAction() const {
    const auto& identity = hover_.hovered();
    const auto* footer = identity ? std::get_if<HistoryFooterIdentity>(&identity->action) : nullptr;
    if (footer == nullptr) {
      return {};
    }

    switch (footer->action) {
    case HistoryFooterAction::submit:
      return QStringLiteral("submit");
    case HistoryFooterAction::alternate:
      return QStringLiteral("alternate");
    case HistoryFooterAction::inspect:
      return QStringLiteral("inspect");
    case HistoryFooterAction::visit:
      return QStringLiteral("visit");
    case HistoryFooterAction::none:
      return {};
    }

    return {};
  }

  int HistoryController::hoveredFooterIndex() const {
    const auto& identity = hover_.hovered();
    const auto* footer = identity ? std::get_if<HistoryFooterIdentity>(&identity->action) : nullptr;

    return footer != nullptr && footer->submission() ? static_cast<int>(footer->choice.index) : static_cast<int>(HistoryRowLayout::Index::missing);
  }

  QString HistoryController::hoveredFooterRevision() const {
    const auto& identity = hover_.hovered();
    const auto* footer = identity ? std::get_if<HistoryFooterIdentity>(&identity->action) : nullptr;

    return footer != nullptr && footer->submission() ? hover_revision_ : QString{};
  }

  void HistoryController::registerActions(QQuickItem* actions) {
    actions_ = actions;
  }

  HistoryActionSurface HistoryController::actionSurface() const {
    const auto* actions = qobject_cast<const HistoryMetaLayout*>(actions_.data());
    if (!isOpen() || actions == nullptr || actions->window() != window_) {
      return {};
    }

    return actions->actionSurface(store_.dialog().generation);
  }

  void HistoryController::activate(HistoryCardAction action, HistoryChoice choice) {
    if (!store_.session().historyBrowser().accepts(choice)) {
      return;
    }

    switch (action) {
    case HistoryCardAction::copy:
      execute(Action::copy);
      break;
    case HistoryCardAction::erase:
      execute(Action::erase);
      break;
    case HistoryCardAction::visit:
      execute(Action::visit);
      break;
    }
  }

  HistoryScrollSurface HistoryController::scrollSurface(HoverFrame& hover) const {
    const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
    const auto& browser = store_.session().historyBrowser();
    const auto generation = store_.dialog().generation;

    hover.generation = generation;
    hover.scale = density;
    HistoryScrollSurface surface{
        .generation = generation,
        .revision = browser.revision(),
        .row_height = metrics_.cell_height,
        .cell_height = metrics_.cell_height,
        .scale = density,
    };

    if (panel_ == nullptr || panel_->window() != window_ || !panel_->isVisible()) {
      return surface;
    }

    const auto bounds = panel_->mapRectToScene(panel_->boundingRect());

    surface.bounds = {.x = static_cast<float>(bounds.x() * density), .y = static_cast<float>(bounds.y() * density), .width = static_cast<float>(bounds.width() * density), .height = static_cast<float>(bounds.height() * density)};
    surface.delivered = bounds.width() > 0 && bounds.height() > 0 && search_host_ != nullptr && search_host_->isVisible() && search_host_->width() > 0 && search_host_->height() > 0;
    if (viewport_ == nullptr || content_ == nullptr) {
      return surface;
    }

    const auto viewport = viewport_->mapRectToScene(viewport_->boundingRect());
    std::optional<float> row_height;

    for (const auto* delegate : content_->childItems()) {
      for (const auto* item : delegate->childItems()) {
        const auto* row = qobject_cast<const HistoryRowLayout*>(item);
        if (row == nullptr || !row->isVisible()) {
          continue;
        }

        const auto frame = row->physicalFrame();
        if (frame.empty() || !row->mapRectToScene(toQRectF(frame, density)).intersects(viewport)) {
          continue;
        }

        row_height = row_height ? std::min(*row_height, frame.height) : frame.height;
        const auto index = row->historyIndex();
        if (index >= 0 && std::cmp_less(index, HistoryBrowser<Memory>::page_entries)) {
          const auto bounds = row->mapRectToScene(toQRectF(frame, density)).intersected(viewport);

          hover.append({.identity = {.action = HistoryChoice{.index = static_cast<std::size_t>(index), .revision = browser.revision()}, .generation = generation}, .bounds = {.x = static_cast<float>(bounds.x() * density), .y = static_cast<float>(bounds.y() * density), .width = static_cast<float>(bounds.width() * density), .height = static_cast<float>(bounds.height() * density)}});
        }
      }
    }

    surface.row_height = row_height.value_or(metrics_.cell_height);
    surface.has_rows = row_height.has_value();

    return surface;
  }

  void HistoryController::prepare(Frame& frame) const {
    if (!isOpen()) {
      return;
    }

    const auto& session = store_.session();
    const auto& browser = session.historyBrowser();
    const auto generation = store_.dialog().generation;

    frame.actions = actionSurface();
    auto& hover = frame.hover.emplace();
    const auto* filters = qobject_cast<const HistoryFiltersLayout*>(filter_layout_.data());
    if (filters != nullptr && filters->window() == window_) {
      hover.count += filters->hoverTargets(generation, std::span{hover.targets}.subspan(hover.count));
    }

    const auto surface = scrollSurface(hover);

    for (const auto& target : frame.actions.targets) {
      hover.append({.identity = {.action = target.action, .generation = frame.actions.generation}, .bounds = target.bounds});
    }

    const auto* inspector = qobject_cast<const HistoryInspectionLayout*>(inspector_.data());
    if (inspector != nullptr && inspector->window() == window_) {
      hover.count += inspector->hoverTargets(generation, std::span{hover.targets}.subspan(hover.count));
    }

    const auto* footer = qobject_cast<const HistoryFooterLayout*>(footer_.data());
    if (footer != nullptr && footer->window() == window_) {
      hover.count += footer->hoverTargets(generation, std::span{hover.targets}.subspan(hover.count));
    }

    // Only state QML already received is presented: the frame shows what changed() announced.
    if (!busy() && synchronized_ && synchronized_->view_version == browser.viewVersion()) {
      frame.surface = surface;
      if (const auto choice = browser.choice()) {
        frame.history = Presented{.choice = *choice, .dialog_generation = generation, .enter_runs = session.configuration().history.enter_runs};
      }
    }
  }

  void HistoryController::present(const Frame& frame) {
    presented_ = frame.history;
    presented_surface_ = frame.surface;
    presented_actions_ = frame.actions;
    presented_hover_ = frame.hover;
    if (hover_.present(presented_hover_ ? presented_hover_->view() : std::span<const HistoryHoverTarget>{})) {
      notifyHover();
    }
  }

  void HistoryController::retire() {
    presented_.reset();
    presented_surface_ = {};
    presented_actions_ = {};
    presented_hover_.reset();
    retireHover();
  }

  void HistoryController::setWindow(QQuickWindow* window) {
    window_ = window;
    presented_.reset();
    presented_surface_ = {};
    presented_actions_ = {};
    presented_hover_.reset();
  }

  const HistoryActionSurface& HistoryController::presentedActions() const noexcept {
    return presented_actions_;
  }

  bool HistoryController::hosted() const {
    return store_.dialog().line_search_pane != 0 && !store_.session().historyBrowser().state().inspecting;
  }

  bool HistoryController::handleWheel(QWheelEvent& event) {
    if (!isOpen()) {
      return false;
    }

    if (wheel_sequence_.compatibilityEvent(event)) {
      event.accept();

      return true;
    }

    scroll({.x = event.position().x(), .y = event.position().y()}, scrollSample(event, 1));
    event.accept();

    return true;
  }

  void HistoryController::scroll(HistoryScrollPosition pointer, ScrollSample sample) {
    const auto& browser = store_.session().historyBrowser();
    const auto& view = browser.state();
    const HistoryScrollState state{.generation = store_.dialog().generation, .revision = browser.revision(), .ready = !busy() && view.phase == HistoryPhase::ready, .inspecting = view.inspecting};
    const auto& surface = presented_surface_;

    if (sample.precise) {
      sample.delta *= surface.scale;
    }

    const HistoryScrollPosition physical{.x = pointer.x * surface.scale, .y = pointer.y * surface.scale};
    if (!std::isfinite(physical.x) || !std::isfinite(physical.y) || !std::isfinite(sample.delta)) {
      return;
    }

    const auto steps = scroll_.consume(state, surface, physical, sample);
    if (steps != 0) {
      if (view.inspecting) {
        emit inspectionScrolled(steps);
      } else {
        interact([&] {
          moveRows(steps);
        });
      }
    }
  }

  void HistoryController::moveRows(std::int32_t steps) {
    auto& session = store_.session();
    const auto& browser = session.historyBrowser();

    for (std::int32_t remaining = std::abs(steps); remaining > 0; --remaining) {
      if (busy() || browser.rows().empty()) {
        break;
      }

      const auto selected = browser.state().selection;

      if (steps < 0) {
        if (selected + 1 < browser.rows().size()) {
          session.selectHistoryRow(selected + 1);
        } else {
          session.pageHistory(HistoryPage::older);
        }
      } else if (selected > 0) {
        session.selectHistoryRow(selected - 1);
      } else {
        session.pageHistory(HistoryPage::newer);
      }
    }
  }

  void HistoryController::notifyHover() {
    const auto& identity = hover_.hovered();
    const auto* row = identity ? std::get_if<HistoryChoice>(&identity->action) : nullptr;

    if (const auto* footer = identity ? std::get_if<HistoryFooterIdentity>(&identity->action) : nullptr; footer != nullptr && footer->submission()) {
      row = &footer->choice;
    }

    if (const auto* inspection = identity ? std::get_if<HistoryInspectionIdentity>(&identity->action) : nullptr; inspection != nullptr && inspection->submission()) {
      row = &inspection->choice;
    }

    if (row != nullptr && hover_revision_value_ != row->revision) {
      hover_revision_value_ = row->revision;
      hover_revision_ = QString::number(row->revision);
    }

    emit hoverChanged();
  }

  void HistoryController::retireHover() {
    if (hover_.cancel()) {
      notifyHover();
    }
  }

  void HistoryController::observeHover(QPointF position, HistoryHover::Observation observation) {
    const auto& frame = presented_hover_;
    if (!isOpen() || !frame || frame->generation != store_.dialog().generation) {
      retireHover();

      return;
    }

    if (hover_.observe(frame->view(), {.x = position.x() * frame->scale, .y = position.y() * frame->scale}, observation)) {
      notifyHover();
    }
  }

  QVariantMap HistoryController::geometry() const {
    const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
    const auto geometry = HistoryModalGeometry::measure(metrics_, store_.session().historyBrowser().state().inspecting);
    const auto local = [&](Rect area) {
      area.x -= geometry.bounds.x;
      area.y -= geometry.bounds.y;

      return toQRectF(area, density);
    };

    return {
        {QStringLiteral("bounds"), toQRectF(geometry.bounds, density)},
        {QStringLiteral("header"), local(geometry.header)},
        {QStringLiteral("results"), local(geometry.results)},
        {QStringLiteral("inspection"), local(geometry.inspection)},
        {QStringLiteral("search"), local(geometry.search)},
        {QStringLiteral("footer"), local(geometry.footer)},
        {QStringLiteral("inspectionContent"), local(geometry.inspectionContent(metrics_.chrome))},
        {QStringLiteral("inspectionActions"), local(geometry.inspectionActions(metrics_.chrome))},
        {QStringLiteral("rowHeight"), geometry.row_height / density},
        {QStringLiteral("groupHeight"), geometry.group_height / density},
        {QStringLiteral("compact"), geometry.compact},
        {QStringLiteral("density"), density},
    };
  }

}
