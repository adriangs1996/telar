#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tbc/view.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/foundation/input/history_scroll_events.hpp"
#include "ui/foundation/input/native_pointer_events.hpp"
#include <QKeyEvent>
#include <QMouseEvent>
#include <QObject>
#include <QPointF>
#include <QPointer>
#include <QQuickWindow>
#include <QString>
#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <ranges>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <utility>
#include <variant>

#pragma once

import telar.gui.input.child_mouse;
import telar.gui.presentation.history_pointer;

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
    PointerDispatcher(WindowDisplay& display, ApplicationAllocator& memory, Store& store, TabsController& tabs, HistoryController& history, ActivityController& activity, AttachmentsController& attachments, TerminalController& terminals);
    ~PointerDispatcher() override = default;
    PointerDispatcher(const PointerDispatcher&) = delete;
    PointerDispatcher& operator=(const PointerDispatcher&) = delete;
    PointerDispatcher(PointerDispatcher&&) = delete;
    PointerDispatcher& operator=(PointerDispatcher&&) = delete;
    void setWindow(QQuickWindow& window);
    void presentHistoryActions(const HistoryActionSurface& surface);
    void ungrab(TerminalItem& terminal);
    bool eventFilter(QObject* watched, QEvent* event) override;
    bool handleNativeScroll(std::string_view event_type, const void* message);

  signals:
    void failed(const QString& message);

  private:
    // The history actions a press holds, by button; the terminals hold theirs in their controller.
    [[nodiscard]] HistoryActionCapture* capture(Qt::MouseButton button) noexcept;
    [[nodiscard]] bool occupied() const noexcept;
    void cancel();
    bool press(QMouseEvent& event);
    bool move(QMouseEvent& event);
    bool release(QMouseEvent& event);

    WindowDisplay& display_;
    Store& store_;
    TabsController& tabs_;
    HistoryController& history_;
    ActivityController& activity_;
    AttachmentsController& attachments_;
    TerminalController& terminals_;
    NativePointerEvents native_events_;
    tbc::view<ActiveHistoryScrollEvents<PointerDispatcher>, tbc::lt::self> history_scroll_events_;
    QPointer<QQuickWindow> window_;
    std::array<HistoryActionCapture, static_cast<std::size_t>(MouseButton::none)> captures_;
    bool delivering_ = false;
    bool handing_off_ = false;
  };

}
