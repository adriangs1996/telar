#include "input/history_action_capture.hpp"
#include "input/history_hover.hpp"
#include "application/dependencies.hpp"
#include "history/browser.hpp"
#include <cstddef>
#include <cmath>
#include <utility>
#include "history/choice.hpp"
#include "presentation/history_actions.hpp"
#include "presentation/history_footer.hpp"
#include "application.hpp"
#include "core/geometry.hpp"
#include "history/entry.hpp"
#include "input/history_scroll.hpp"
#include "input/wheel_accumulator.hpp"
#include "presentation/history_modal_geometry.hpp"
#include "projection.hpp"
#include "qt/history_row_layout.hpp"
#include "qt/history_meta_layout.hpp"
#include "qt/scroll_event.hpp"
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QStringView>
#include <QString>
#include <QtCore/qstringliteral.h>
#include <variant>
#include <QWheelEvent>
#include <QtCore/qobject.h>
#include <QtCore/qtmetamacros.h>
#include <algorithm>
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

void Application::registerHistoryPanel(QQuickItem *panel) {
  history_panel_ = panel;
  history_search_host_ = panel == nullptr ? nullptr : panel->property("searchHost").value<QQuickItem *>();
  history_viewport_ = panel == nullptr ? nullptr : panel->property("rowsView").value<QQuickItem *>();
  history_content_ = history_viewport_ == nullptr ? nullptr : history_viewport_->property("contentItem").value<QQuickItem *>();
}

int Application::historyHoveredRow() const {
  const auto &identity = pointer_dispatcher_.historyHover().hovered();
  const auto *row = identity ? std::get_if<HistoryChoice>(&identity->action) : nullptr;

  return row == nullptr ? static_cast<int>(HistoryRowLayout::Index::missing) : static_cast<int>(row->index);
}

QString Application::historyHoveredRowRevision() const {
  const auto &identity = pointer_dispatcher_.historyHover().hovered();
  if (!identity || !std::holds_alternative<HistoryChoice>(identity->action)) {
    return {};
  }

  return pointer_dispatcher_.historyHoverRevision();
}

QString Application::historyHoveredCardAction() const {
  const auto &identity = pointer_dispatcher_.historyHover().hovered();
  const auto *action = identity ? std::get_if<HistoryCardAction>(&identity->action) : nullptr;
  if (action == nullptr) {
    return {};
  }

  switch (*action) {
  case HistoryCardAction::copy: return QStringLiteral("copy");
  case HistoryCardAction::erase: return QStringLiteral("erase");
  case HistoryCardAction::visit: return QStringLiteral("visit");
  }

  return {};
}

void Application::registerHistoryInspector(QQuickItem *inspector) {
  history_inspector_ = inspector;
}

QString Application::historyHoveredInspectionAction() const {
  const auto &identity = pointer_dispatcher_.historyHover().hovered();
  const auto *inspection = identity ? std::get_if<HistoryInspectionIdentity>(&identity->action) : nullptr;
  if (inspection == nullptr) {
    return {};
  }

  switch (inspection->action) {
  case HistoryInspectionAction::submit: return QStringLiteral("submit");
  case HistoryInspectionAction::alternate: return QStringLiteral("alternate");
  case HistoryInspectionAction::copy: return QStringLiteral("copy");
  case HistoryInspectionAction::erase: return QStringLiteral("erase");
  case HistoryInspectionAction::visit: return QStringLiteral("visit");
  }

  return {};
}

int Application::historyHoveredInspectionIndex() const {
  const auto &identity = pointer_dispatcher_.historyHover().hovered();
  const auto *inspection = identity ? std::get_if<HistoryInspectionIdentity>(&identity->action) : nullptr;

  return inspection != nullptr && inspection->submission() ? static_cast<int>(inspection->choice.index) : static_cast<int>(HistoryRowLayout::Index::missing);
}

QString Application::historyHoveredInspectionRevision() const {
  const auto &identity = pointer_dispatcher_.historyHover().hovered();
  const auto *inspection = identity ? std::get_if<HistoryInspectionIdentity>(&identity->action) : nullptr;

  return inspection != nullptr && inspection->submission() ? pointer_dispatcher_.historyHoverRevision() : QString{};
}

void Application::registerHistoryFilters(QQuickItem *filters) {
  history_filter_layout_ = filters;
}

QString Application::historyHoveredFilterAction() const {
  const auto &identity = pointer_dispatcher_.historyHover().hovered();
  const auto *action = identity ? std::get_if<HistoryFilterAction>(&identity->action) : nullptr;
  if (action == nullptr) {
    return {};
  }

  switch (*action) {
  case HistoryFilterAction::global: return QStringLiteral("global");
  case HistoryFilterAction::workspace: return QStringLiteral("workspace");
  case HistoryFilterAction::cwd: return QStringLiteral("cwd");
  case HistoryFilterAction::pane: return QStringLiteral("pane");
  case HistoryFilterAction::human: return QStringLiteral("human");
  case HistoryFilterAction::agent: return QStringLiteral("agent");
  case HistoryFilterAction::all: return QStringLiteral("all");
  case HistoryFilterAction::failed: return QStringLiteral("failed");
  }

  return {};
}

void Application::registerHistoryFooter(QQuickItem *footer) {
  history_footer_ = footer;
}

QString Application::historyHoveredFooterAction() const {
  const auto &identity = pointer_dispatcher_.historyHover().hovered();
  const auto *footer = identity ? std::get_if<HistoryFooterIdentity>(&identity->action) : nullptr;
  if (footer == nullptr) {
    return {};
  }

  switch (footer->action) {
  case HistoryFooterAction::submit: return QStringLiteral("submit");
  case HistoryFooterAction::alternate: return QStringLiteral("alternate");
  case HistoryFooterAction::inspect: return QStringLiteral("inspect");
  case HistoryFooterAction::visit: return QStringLiteral("visit");
  case HistoryFooterAction::none: return {};
  }

  return {};
}

int Application::historyHoveredFooterIndex() const {
  const auto &identity = pointer_dispatcher_.historyHover().hovered();
  const auto *footer = identity ? std::get_if<HistoryFooterIdentity>(&identity->action) : nullptr;

  return footer != nullptr && footer->submission() ? static_cast<int>(footer->choice.index) : static_cast<int>(HistoryRowLayout::Index::missing);
}

QString Application::historyHoveredFooterRevision() const {
  const auto &identity = pointer_dispatcher_.historyHover().hovered();
  const auto *footer = identity ? std::get_if<HistoryFooterIdentity>(&identity->action) : nullptr;

  return footer != nullptr && footer->submission() ? pointer_dispatcher_.historyHoverRevision() : QString{};
}

void Application::registerHistoryActions(QQuickItem *actions) {
  history_actions_ = actions;
}

HistoryActionSurface Application::historyActionSurface() const {
  const auto *actions = qobject_cast<const HistoryMetaLayout *>(history_actions_.data());
  if (dialog_ != QStringView{u"history"} || actions == nullptr || actions->window() != window_) {
    return {};
  }

  return actions->actionSurface(dialog_generation_);
}

void Application::activateHistoryCardAction(HistoryCardAction action, HistoryChoice choice) {
  if (!session().historyBrowser().accepts(choice)) {
    return;
  }

  switch (action) {
  case HistoryCardAction::copy: executeHistory(HistoryAction::copy); break;
  case HistoryCardAction::erase: executeHistory(HistoryAction::erase); break;
  case HistoryCardAction::visit: executeHistory(HistoryAction::visit); break;
  }
}

HistoryScrollSurface Application::historyScrollSurface(const HistoryModalMetrics &metrics, HistoryHoverFrame &hover) const {
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto &browser = session().historyBrowser();
  hover.generation = dialog_generation_;
  hover.scale = density;
  HistoryScrollSurface surface{
      .generation = dialog_generation_,
      .revision = browser.revision(),
      .row_height = metrics.cell_height,
      .cell_height = metrics.cell_height,
      .scale = density,
  };
  if (history_panel_ == nullptr || history_panel_->window() != window_ || !history_panel_->isVisible()) {
    return surface;
  }

  const auto bounds = history_panel_->mapRectToScene(history_panel_->boundingRect());
  surface.bounds = {.x = static_cast<float>(bounds.x() * density), .y = static_cast<float>(bounds.y() * density), .width = static_cast<float>(bounds.width() * density), .height = static_cast<float>(bounds.height() * density)};
  surface.delivered = bounds.width() > 0 && bounds.height() > 0 && history_search_host_ != nullptr && history_search_host_->isVisible() && history_search_host_->width() > 0 && history_search_host_->height() > 0;
  if (history_viewport_ == nullptr || history_content_ == nullptr) {
    return surface;
  }

  const auto viewport = history_viewport_->mapRectToScene(history_viewport_->boundingRect());
  std::optional<float> row_height;
  for (const auto *delegate : history_content_->childItems()) {
    for (const auto *item : delegate->childItems()) {
      const auto *row = qobject_cast<const HistoryRowLayout *>(item);
      if (row == nullptr || !row->isVisible()) {
        continue;
      }

      const auto frame = row->physicalFrame();
      if (frame.empty() || !row->mapRectToScene(toQRectF(frame, density)).intersects(viewport)) {
        continue;
      }

      row_height = row_height ? std::min(*row_height, frame.height) : frame.height;
      const auto index = row->historyIndex();
      if (index >= 0 && std::cmp_less(index, HistoryBrowser<ApplicationAllocator>::page_entries)) {
        const auto bounds = row->mapRectToScene(toQRectF(frame, density)).intersected(viewport);
        hover.append({.identity = {.action = HistoryChoice{.index = static_cast<std::size_t>(index), .revision = browser.revision()}, .generation = dialog_generation_}, .bounds = {.x = static_cast<float>(bounds.x() * density), .y = static_cast<float>(bounds.y() * density), .width = static_cast<float>(bounds.width() * density), .height = static_cast<float>(bounds.height() * density)}});
      }
    }
  }

  surface.row_height = row_height.value_or(metrics.cell_height);
  surface.has_rows = row_height.has_value();

  return surface;
}

bool Application::handleHistoryWheel(QWheelEvent &event) {
  if (dialog_ != QStringView{u"history"}) {
    return false;
  }

  if (history_wheel_sequence_.compatibilityEvent(event)) {
    event.accept();

    return true;
  }

  scrollHistory({.x = event.position().x(), .y = event.position().y()}, scrollSample(event, 1));
  event.accept();

  return true;
}

void Application::scrollHistory(HistoryScrollPosition pointer, ScrollSample sample) {
  const auto &browser = session().historyBrowser();
  const auto &view = browser.state();
  const HistoryScrollState state{.generation = dialog_generation_, .revision = browser.revision(), .ready = !historyLoading() && view.phase == HistoryPhase::ready, .inspecting = view.inspecting};
  const auto &surface = presented_history_surface_;

  if (sample.precise) {
    sample.delta *= surface.scale;
  }

  const HistoryScrollPosition physical{.x = pointer.x * surface.scale, .y = pointer.y * surface.scale};
  if (!std::isfinite(physical.x) || !std::isfinite(physical.y) || !std::isfinite(sample.delta)) {
    return;
  }

  pointerDispatcher().retireTerminalScroll();
  const auto steps = history_scroll_.consume(state, surface, physical, sample);
  if (steps != 0) {
    if (view.inspecting) {
      emit historyInspectionScrolled(steps);
    } else {
      applyInteraction([&] {
        moveHistoryRows(steps);
      });
    }
  }
}

void Application::moveHistoryRows(std::int32_t steps) {
  const auto &browser = session().historyBrowser();
  for (std::int32_t remaining = std::abs(steps); remaining > 0; --remaining) {
    if (historyLoading() || browser.rows().empty()) {
      break;
    }

    const auto selected = browser.state().selection;
    if (steps < 0) {
      if (selected + 1 < browser.rows().size()) {
        session().selectHistoryRow(selected + 1);
      } else {
        session().pageHistory(HistoryPage::older);
      }
    } else if (selected > 0) {
      session().selectHistoryRow(selected - 1);
    } else {
      session().pageHistory(HistoryPage::newer);
    }
  }
}

}
