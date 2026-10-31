#include "application.hpp"
#include "core/geometry.hpp"
#include "input/tab_drag.hpp"
#include "input/tab_drop_slots.hpp"
#include "input/tab_drop_surface.hpp"
#include "pointer_dispatcher.hpp"
#include "tab_strip_layout.hpp"
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPointF>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui::qt {

void Application::registerTabStrip(QQuickItem *strip) {
  tab_strip_ = strip;
  synchronizeTabStrip();
}

void Application::synchronizeTabStrip() {
  if (auto *strip = qobject_cast<TabStripLayout *>(tab_strip_.data())) {
    const auto *active = session().activeTab();
    strip->setContext(machine_view_revision_, active == nullptr ? std::nullopt : std::optional{active->location.workspace});
  }
}

void Application::selectCapturedTab() {
  const auto captured = pointer_dispatcher_.capturedTab();
  if (!captured) {
    return;
  }
  const auto id = captured->tab_id;
  const auto *active = session().activeTab();
  const auto &surface = presented_tabs_;
  if (active == nullptr || !dialog_.isEmpty() || surface.machine_view != machine_view_revision_ || surface.workspace.kind != active->location.workspace.kind || surface.workspace.id != active->location.workspace.id || std::ranges::find(surface.view(), id, &TabDropSlot::id) == surface.view().end()) {
    return;
  }

  const auto &tabs = session().tabs();
  if (std::ranges::any_of(tabs, [&](const auto &tab) {
        return tab->location.tab_id == id && tab->location.workspace.kind == surface.workspace.kind && tab->location.workspace.id == surface.workspace.id;
      })) {
    execute(Action::select_tab, QString::number(id));
  }
}

TabDropSurface Application::tabDropSurface() const {
  TabDropSurface result;
  const auto *strip = qobject_cast<const TabStripLayout *>(tab_strip_.data());
  const auto *active = session().activeTab();
  if (!dialog_.isEmpty() || strip == nullptr || active == nullptr || strip->window() != window_ || window_ == nullptr) {
    return result;
  }

  result.workspace = active->location.workspace;
  result.machine_view = machine_view_revision_;
  result.scale = window_->effectiveDevicePixelRatio();
  result.viewport = {.width = static_cast<float>(window_->width() * result.scale), .height = static_cast<float>(window_->height() * result.scale)};
  result.threshold = TabDrag::logical_threshold * chromeRatio() * result.scale;
  result.count = strip->dropSlots(result.targets);
  const auto origin = strip->mapToScene(QPointF{});
  const auto create = strip->plus();
  result.create = {.x = static_cast<float>((origin.x() + create.x()) * result.scale), .y = static_cast<float>((origin.y() + create.y()) * result.scale), .width = static_cast<float>(create.width() * result.scale), .height = static_cast<float>(create.height() * result.scale)};

  return result;
}

void PointerDispatcher::observeTabHover(std::optional<QPointF> position) {
  auto *strip = qobject_cast<TabStripLayout *>(application_.tab_strip_.data());
  if (strip == nullptr) {
    return;
  }
  const auto &surface = application_.presented_tabs_;
  const auto *target = position && application_.dialog_.isEmpty() && surface.machine_view == application_.machine_view_revision_ ? surface.at({position->x() * surface.scale, position->y() * surface.scale}) : nullptr;
  strip->setPointerHover(target == nullptr ? std::nullopt : std::optional{target->id});
}

bool PointerDispatcher::tabKey(QKeyEvent &event) {
  if (event.key() != Qt::Key_Escape) {
    return false;
  }
  if (event.type() == QEvent::KeyRelease && tab_escape_held_) {
    if (!event.isAutoRepeat()) {
      tab_escape_held_ = false;
    }
    return true;
  }
  if (!tab_drag_.captured() || event.type() == QEvent::KeyRelease) {
    return false;
  }
  if (event.type() == QEvent::KeyPress) {
    tab_escape_held_ = true;
    cancelTabDrag();
  }
  event.accept();

  return true;
}

void PointerDispatcher::cancelTabDrag() {
  if (tab_drag_.source()) {
    tab_drag_.cancel();
    updateTabDragVisual();
  }
}

void PointerDispatcher::updateTabDragVisual() {
  auto *strip = qobject_cast<TabStripLayout *>(application_.tab_strip_.data());
  if (strip != nullptr) {
    const auto source = tab_drag_.dragging() && tab_drag_.source() ? std::optional{tab_drag_.source()->tab_id} : std::nullopt;
    strip->setDrag(tab_drag_.preview().has_value() ? tab_drag_.preview() : pending_tab_move_, source, tab_pointer_, tab_grab_offset_);
  }
}

void PointerDispatcher::presentTabs(const TabDropSurface &surface) {
  if (pending_tab_move_ && (!application_.session().tabOperationPending() || surface.machine_view != tab_capture_surface_.machine_view || surface.workspace.kind != pending_tab_move_->location.workspace.kind || surface.workspace.id != pending_tab_move_->location.workspace.id)) {
    pending_tab_move_.reset();
    updateTabDragVisual();
  }

  if (!tab_drag_.source()) {
    return;
  }

  const auto *active = application_.session().activeTab();
  if (active == nullptr || active->location.workspace.kind != tab_capture_surface_.workspace.kind || active->location.workspace.id != tab_capture_surface_.workspace.id) {
    cancelTabDrag();
    return;
  }

  if (surface.machine_view != tab_capture_surface_.machine_view || surface.viewport != tab_capture_surface_.viewport || surface.threshold != tab_capture_surface_.threshold || std::ranges::find(surface.view(), tab_drag_.source()->tab_id, &TabDropSlot::id) == surface.view().end()) {
    cancelTabDrag();
    return;
  }

  std::array<std::uint64_t, TabDropSlots::capacity> tabs{};
  std::size_t count = 0;
  for (const auto &tab : application_.session().tabs()) {
    if (tab->location.workspace.kind == surface.workspace.kind && tab->location.workspace.id == surface.workspace.id && count < tabs.size()) {
      tabs[count++] = tab->location.tab_id;
    }
  }
  tab_drag_.validate(surface.workspace, std::span{tabs}.first(count), !application_.dialog_.isEmpty());
  if (!tab_drag_.source()) {
    updateTabDragVisual();
  }
}

bool PointerDispatcher::pressTab(QMouseEvent &event) {
  if (event.button() != Qt::LeftButton || !application_.dialog_.isEmpty()) {
    return false;
  }

  const auto &surface = application_.presented_tabs_;
  if (surface.machine_view != application_.machine_view_revision_ || surface.scale <= 0 || surface.threshold <= 0 || !std::isfinite(event.position().x()) || !std::isfinite(event.position().y())) {
    return false;
  }

  const auto x = event.position().x() * surface.scale;
  const auto y = event.position().y() * surface.scale;
  if (const auto *slot = surface.at({x, y})) {
    tab_drag_.begin({.workspace = surface.workspace, .tab_id = slot->id}, {x / surface.threshold, y / surface.threshold});
    tab_drop_slots_.capture(surface.view());
    tab_capture_surface_ = surface;
    tab_pointer_ = event.position();
    tab_grab_offset_ = (x - slot->bounds.x) / surface.scale;
    return true;
  }

  return false;
}

bool PointerDispatcher::updateTabDrag(QMouseEvent &event, bool released) {
  if (!tab_drag_.captured() || (!released && !event.buttons().testFlag(Qt::LeftButton))) {
    return false;
  }

  presentTabs(application_.presented_tabs_);
  if (!application_.dialog_.isEmpty() || tab_capture_surface_.machine_view != application_.machine_view_revision_) {
    cancelTabDrag();
  }

  tab_pointer_ = event.position();
  const TabDrag::Position point{event.position().x() * tab_capture_surface_.scale, event.position().y() * tab_capture_surface_.scale};
  tab_drag_.update({point[0] / tab_capture_surface_.threshold, point[1] / tab_capture_surface_.threshold}, tab_drop_slots_.at(point));
  if (released) {
    if (const auto move = tab_drag_.finish(); move && application_.session().requestTabMove(*move)) {
      pending_tab_move_ = move;
    }
    event.setExclusiveGrabber(event.point(0), nullptr);
  }
  updateTabDragVisual();

  return true;
}

}
