#include "application.hpp"
#include "core/geometry.hpp"
#include "history/entry.hpp"
#include "input/history_scroll.hpp"
#include "presentation/history_modal_geometry.hpp"
#include "projection.hpp"
#include "qt/history_row_layout.hpp"
#include "qt/scroll_event.hpp"
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QWheelEvent>
#include <QtCore/qlatin1stringview.h>
#include <QtCore/qobject.h>
#include <QtCore/qstringfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

void Application::registerHistoryPanel(QQuickItem *panel) {
  history_panel_ = panel;
  history_search_host_ = panel == nullptr ? nullptr : panel->property("searchHost").value<QQuickItem *>();
  history_viewport_ = panel == nullptr ? nullptr : panel->property("rowsView").value<QQuickItem *>();
  history_content_ = history_viewport_ == nullptr ? nullptr : history_viewport_->property("contentItem").value<QQuickItem *>();
}

HistoryScrollSurface Application::historyScrollSurface(const HistoryModalMetrics &metrics) const {
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto &browser = session().historyBrowser();
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
    }
  }

  surface.row_height = row_height.value_or(metrics.cell_height);
  surface.has_rows = row_height.has_value();

  return surface;
}

bool Application::handleHistoryWheel(QWheelEvent &event) {
  if (dialog_ != QLatin1StringView("history")) {
    return false;
  }

  if (history_wheel_sequence_.compatibilityEvent(event)) {
    event.accept();

    return true;
  }

  const auto &browser = session().historyBrowser();
  const auto &view = browser.state();
  const HistoryScrollState state{.generation = dialog_generation_, .revision = browser.revision(), .ready = !historyLoading() && view.phase == HistoryPhase::ready, .inspecting = view.inspecting};
  const auto &surface = presented_history_surface_;
  auto sample = scrollSample(event, 1);
  if (sample.precise) {
    sample.delta *= surface.scale;
  }

  const auto steps = history_scroll_.consume(state, surface, {.x = event.position().x() * surface.scale, .y = event.position().y() * surface.scale}, sample);
  if (steps != 0) {
    if (view.inspecting) {
      emit historyInspectionScrolled(steps);
    } else {
      applyInteraction([&] {
        moveHistoryRows(steps);
      });
    }
  }

  event.accept();

  return true;
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
