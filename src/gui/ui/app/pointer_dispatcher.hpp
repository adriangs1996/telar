#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tbc/view.hpp"
#include "ui/foundation/input/history_scroll_events.hpp"
#include "ui/foundation/input/native_pointer_events.hpp"
#include <QKeyEvent>
#include <QMouseEvent>
#include <QObject>
#include <QPointF>
#include <QPointer>
#include <QQuickWindow>
#include <QString>
#include <array>
#include <cstddef>
#include <cstring>
#include <string_view>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  class ActivityController;
  class AttachmentsController;
  class HistoryController;
  class Store;
  class TabsController;
  class TerminalController;
  class TerminalItem;
  class WindowDisplay;

  // Routes the window's pointer before the items under it: the tab strip, the history modal, the
  // attachment shelf, the activity list, and the terminals that hold a button. It holds every
  // recipient a pointer event can have.
  class PointerDispatcher final : public QObject {
    Q_OBJECT

  public:
    struct Parts {
      WindowDisplay& display;
      ApplicationAllocator& memory;
      Store& store;
      TabsController& tabs;
      HistoryController& history;
      ActivityController& activity;
      AttachmentsController& attachments;
      TerminalController& terminals;
    };

    // Keeps what the parts refer to, region `a`, not the parts themselves.
    explicit PointerDispatcher(tbc::holds<const Parts&, tbc::lt::a> parts);
    ~PointerDispatcher() override = default;
    PointerDispatcher(const PointerDispatcher&) = delete;
    PointerDispatcher& operator=(const PointerDispatcher&) = delete;
    PointerDispatcher(PointerDispatcher&&) = delete;
    PointerDispatcher& operator=(PointerDispatcher&&) = delete;
    void setWindow(QQuickWindow& window);
    void presentHistoryActions(const application::history::HistoryActionSurface& surface);
    void ungrab(TerminalItem& terminal);
    bool eventFilter(QObject* watched, QEvent* event) override;
    bool handleNativeScroll(std::string_view event_type, const void* message);

  signals:
    void failed(const QString& message);

  private:
    // The history actions a press holds, by button; the terminals hold theirs in their controller.
    [[nodiscard]] application::history::HistoryActionCapture* capture(Qt::MouseButton button) noexcept;
    [[nodiscard]] bool occupied() const noexcept;
    void cancel();
    bool press(QMouseEvent& event);
    bool move(QMouseEvent& event);
    bool release(QMouseEvent& event);

    tbc::view<WindowDisplay&, tbc::lt::a> display_;
    tbc::view<Store&, tbc::lt::a> store_;
    tbc::view<TabsController&, tbc::lt::a> tabs_;
    tbc::view<HistoryController&, tbc::lt::a> history_;
    tbc::view<ActivityController&, tbc::lt::a> activity_;
    tbc::view<AttachmentsController&, tbc::lt::a> attachments_;
    tbc::view<TerminalController&, tbc::lt::a> terminals_;
    NativePointerEvents native_events_;
    tbc::view<ActiveHistoryScrollEvents<PointerDispatcher>, tbc::lt::self> history_scroll_events_;
    QPointer<QQuickWindow> window_;
    ds::Array<application::history::HistoryActionCapture, static_cast<std::size_t>(application::terminal::input::MouseButton::none)> captures_;
    bool delivering_ = false;
    bool handing_off_ = false;
  };

}
