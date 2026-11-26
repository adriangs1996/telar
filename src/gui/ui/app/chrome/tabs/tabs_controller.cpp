#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tabs_controller.hpp"
#include "tab_strip_layout.hpp"
#include "ui/kit/models/projection.hpp"
#include <QList>
#include <QtCore/qnamespace.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <functional>
#include <span>
#include <utility>

import telar.wire.vocabulary;
import telar.base.ds;
import telar.base.memory.allocators;

namespace telar::gui::qt {

  TabsController::TabsController(Store& store, ElementSlots& elements, QObject* parent)
      : QObject(parent),
        store_(store),
        elements_(elements) {}

  QAbstractItemModel* TabsController::rows() noexcept {
    return &rows_;
  }

  int TabsController::count() const noexcept {
    return rows_.rowCount();
  }

  void TabsController::forget() {
    rows_.reconcile({});
    synchronized_.reset();
  }

  TabsController::Inputs TabsController::inputs() const {
    const auto& client = store_.client(store_.machines().active());
    const auto& session = client.session;
    const auto view = session.viewVersion();

    return {
        .machine_view = store_.machineView(),
        .runtime_generation = client.runtime_generation,
        .tabs = view.tabs,
        .active_tab = view.active_tab,
        .panes = view.panes,
        .configuration = view.configuration,
        .chrome = session.chromeRevision(),
        .agents = session.agentRevision(),
        .elements = elements_.revision(),
    };
  }

  std::uint64_t TabsController::rebuilds() const noexcept {
    return rebuilds_;
  }

  void TabsController::synchronize() {
    const auto next = inputs();
    if (synchronized_ == next) {
      return;
    }

    ++rebuilds_;

    const auto& session = store_.session();
    const auto* active = session.activeTab();
    QList<const Tab<Memory>*> ordered;

    for (const auto& tab : session.tabs) {
      if (active != nullptr && sameWorkspace(tab->location.workspace, active->location.workspace)) {
        ordered.append(&tab.get());
      }
    }

    std::ranges::stable_sort(ordered, [](const auto* left, const auto* right) {
      return left->position < right->position;
    });

    QList<QVariantMap> tabs;

    elements_.begin(ElementSlots::tab_slots);
    for (const auto* tab : ordered) {
      const auto* pane = session.findPane(tab->focused_pane);
      auto record = tabRecord(*tab, pane, session.panes, std::span<const Agent<Memory>>{session.agents()}, tab == active);

      if (elements_.active()) {
        record.insert(QStringLiteral("elements"), elements_.elements(ElementSlots::tab_slots, record.value(QStringLiteral("key")).toString(), ElementSlots::tabItem(record, static_cast<int>(tabs.size()))));
      }

      tabs.append(std::move(record));
    }

    synchronized_ = next;
    rows_.reconcile(std::move(tabs));
    elements_.finish(ElementSlots::tab_slots);
  }

  void TabsController::registerStrip(QQuickItem* strip) {
    strip_ = qobject_cast<TabStripLayout*>(strip);
    synchronizeStrip();
  }

  void TabsController::synchronizeStrip() {
    if (strip_ != nullptr) {
      const auto* active = store_.session().activeTab();

      strip_->setContext(store_.machineView(), active == nullptr ? ds::none : ds::Option{active->location.workspace});
    }
  }

  void TabsController::setWindow(QQuickWindow& window) {
    window_ = &window;
  }

  void TabsController::selectCaptured() {
    const auto captured = drag_.source();
    if (!captured) {
      return;
    }

    const auto id = captured->tab_id;
    const auto& session = store_.session();
    const auto* active = session.activeTab();
    const auto& surface = presented_;
    if (active == nullptr || store_.dialog().kind != Store::Dialog::none || surface.machine_view != store_.machineView() || surface.workspace.kind != active->location.workspace.kind || surface.workspace.id != active->location.workspace.id || std::ranges::find(surface.view(), id, &application::workbench::TabDropSlot::id) == surface.view().end()) {
      return;
    }

    if (std::ranges::any_of(session.tabs, [&](const auto& tab) {
          return tab->location.tab_id == id && tab->location.workspace.kind == surface.workspace.kind && tab->location.workspace.id == surface.workspace.id;
        })) {
      emit selectRequested(id);
    }
  }

  application::workbench::TabDropSurface TabsController::dropSurface(qreal ratio) const {
    application::workbench::TabDropSurface result;
    const auto* active = store_.session().activeTab();
    if (store_.dialog().kind != Store::Dialog::none || strip_ == nullptr || active == nullptr || strip_->window() != window_ || window_ == nullptr) {
      return result;
    }

    result.workspace = active->location.workspace;
    result.machine_view = store_.machineView();
    result.scale = window_->effectiveDevicePixelRatio();
    result.viewport = {.width = static_cast<float>(window_->width() * result.scale), .height = static_cast<float>(window_->height() * result.scale)};
    result.threshold = application::workbench::TabDrag::logical_threshold * ratio * result.scale;
    result.count = strip_->dropSlots(result.targets.viewMut());
    const auto origin = strip_->mapToScene(QPointF{});
    const auto create = strip_->plus();

    result.create = {.x = static_cast<float>((origin.x() + create.x()) * result.scale), .y = static_cast<float>((origin.y() + create.y()) * result.scale), .width = static_cast<float>(create.width() * result.scale), .height = static_cast<float>(create.height() * result.scale)};

    return result;
  }

  void TabsController::observeHover(ds::Option<QPointF> position) {
    if (strip_ == nullptr) {
      return;
    }

    const auto& surface = presented_;
    const auto* target = position && store_.dialog().kind == Store::Dialog::none && surface.machine_view == store_.machineView() ? surface.at({position->x() * surface.scale, position->y() * surface.scale}) : nullptr;

    strip_->setPointerHover(target == nullptr ? ds::none : ds::Option{target->id});
  }

  bool TabsController::key(QKeyEvent& event) {
    if (event.key() != Qt::Key_Escape) {
      return false;
    }

    if (event.type() == QEvent::KeyRelease && escape_held_) {
      if (!event.isAutoRepeat()) {
        escape_held_ = false;
      }

      return true;
    }

    if (!drag_.captured() || event.type() == QEvent::KeyRelease) {
      return false;
    }

    if (event.type() == QEvent::KeyPress) {
      escape_held_ = true;
      cancelDrag();
    }

    event.accept();

    return true;
  }

  void TabsController::cancelDrag() {
    if (drag_.source()) {
      drag_.cancel();
      updateDragVisual();
    }
  }

  void TabsController::leave() {
    observeHover(ds::none);
    if (drag_.captured()) {
      const auto scale = capture_surface_.scale / capture_surface_.threshold;

      drag_.update({pointer_.x() * scale, pointer_.y() * scale}, ds::none);
      updateDragVisual();
    }
  }

  void TabsController::updateDragVisual() {
    if (strip_ != nullptr) {
      const auto source = drag_.dragging() && drag_.source() ? ds::Option{drag_.source()->tab_id} : ds::none;

      strip_->setDrag(drag_.preview().hasValue() ? drag_.preview() : pending_move_, source, pointer_, grab_offset_);
    }
  }

  void TabsController::present(const application::workbench::TabDropSurface& surface) {
    presented_ = surface;
    validateDrag();
  }

  void TabsController::validateDrag() {
    const auto& surface = presented_;
    const auto& session = store_.session();
    if (pending_move_ && (!application::workbench::tabOperationPending(session) || surface.machine_view != capture_surface_.machine_view || surface.workspace.kind != pending_move_->location.workspace.kind || surface.workspace.id != pending_move_->location.workspace.id)) {
      pending_move_.reset();
      updateDragVisual();
    }

    if (!drag_.source()) {
      return;
    }

    const auto* active = session.activeTab();
    if (active == nullptr || active->location.workspace.kind != capture_surface_.workspace.kind || active->location.workspace.id != capture_surface_.workspace.id) {
      cancelDrag();
      return;
    }

    if (surface.machine_view != capture_surface_.machine_view || surface.viewport != capture_surface_.viewport || std::not_equal_to<>{}(surface.threshold, capture_surface_.threshold) || std::ranges::find(surface.view(), drag_.source()->tab_id, &application::workbench::TabDropSlot::id) == surface.view().end()) {
      cancelDrag();
      return;
    }

    ds::Array<std::uint64_t, application::workbench::TabDropSlots::capacity> tabs{};
    std::size_t count = 0;

    for (const auto& tab : session.tabs) {
      if (tab->location.workspace.kind == surface.workspace.kind && tab->location.workspace.id == surface.workspace.id && count < tabs.size()) {
        tabs.atMut(count++) = tab->location.tab_id;
      }
    }

    drag_.validate(surface.workspace, std::span{tabs}.first(count), store_.dialog().kind != Store::Dialog::none);
    if (!drag_.source()) {
      updateDragVisual();
    }
  }

  bool TabsController::press(QMouseEvent& event, qreal ratio) {
    if (event.button() != Qt::LeftButton || store_.dialog().kind != Store::Dialog::none) {
      return false;
    }

    const auto& surface = presented_;
    if (surface.machine_view != store_.machineView() || surface.scale <= 0 || surface.threshold <= 0 || !std::isfinite(event.position().x()) || !std::isfinite(event.position().y())) {
      return false;
    }

    const auto x = event.position().x() * surface.scale;
    const auto y = event.position().y() * surface.scale;
    if (const auto* slot = surface.at({x, y})) {
      // A queued tab snapshot can overlap another widget after the bar moves.
      const auto current = dropSurface(ratio);
      const auto* target = current.at({event.position().x() * current.scale, event.position().y() * current.scale});
      if (target == nullptr || target->id != slot->id || current.workspace.kind != surface.workspace.kind || current.workspace.id != surface.workspace.id || current.viewport != surface.viewport || std::not_equal_to<>{}(current.scale, surface.scale) || std::not_equal_to<>{}(current.threshold, surface.threshold)) {
        return false;
      }

      drag_.begin({.workspace = surface.workspace, .tab_id = slot->id}, {x / surface.threshold, y / surface.threshold});
      drop_slots_.capture(surface.view());
      capture_surface_ = surface;
      pointer_ = event.position();
      grab_offset_ = (x - static_cast<double>(slot->bounds.x)) / surface.scale;
      return true;
    }

    return false;
  }

  bool TabsController::drag(QMouseEvent& event, bool released) {
    if (!drag_.captured() || (!released && !event.buttons().testFlag(Qt::LeftButton))) {
      return false;
    }

    validateDrag();
    if (store_.dialog().kind != Store::Dialog::none || capture_surface_.machine_view != store_.machineView()) {
      cancelDrag();
    }

    pointer_ = event.position();
    const application::workbench::TabDrag::Position point{event.position().x() * capture_surface_.scale, event.position().y() * capture_surface_.scale};

    drag_.update({point[0] / capture_surface_.threshold, point[1] / capture_surface_.threshold}, drop_slots_.at(point));
    if (released) {
      if (const auto move = drag_.finish(); move && application::workbench::dropTab(store_.sessionMut(), *move)) {
        pending_move_ = move;
      }

      event.setExclusiveGrabber(event.point(0), nullptr);
    }

    updateDragVisual();

    return true;
  }

}
