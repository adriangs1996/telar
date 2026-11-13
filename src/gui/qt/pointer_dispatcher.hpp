#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tbc/view.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <optional>
#include <cstddef>
#include <array>
#include <string_view>
#include <utility>
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <span>
#include <variant>
#include <limits>
#include <ranges>
#include "native_pointer_events.hpp"
#include "history_scroll_events.hpp"
#include <QMouseEvent>
#include <QKeyEvent>
#include <QPointF>
#include <QString>
#include <QObject>
#include <QPointer>
#include <QQuickWindow>

#pragma once


import telar.gui.input.child_mouse;

namespace telar::gui::qt {

class Application;
class TerminalItem;

class PointerDispatcher final : public QObject {
public:
  explicit PointerDispatcher(Application &application);
  ~PointerDispatcher() override = default;
  PointerDispatcher(const PointerDispatcher &) = delete;
  PointerDispatcher &operator=(const PointerDispatcher &) = delete;
  PointerDispatcher(PointerDispatcher &&) = delete;
  PointerDispatcher &operator=(PointerDispatcher &&) = delete;
  void setWindow(QQuickWindow &window);
  void acquire(TerminalItem &terminal, Qt::MouseButton button);
  void beginChild(const ChildMouseView &view, ChildMouseSample sample);
  void release(Qt::MouseButton button);
  void presentHistoryActions(const HistoryActionSurface &surface);
  void presentTabs(const TabDropSurface &surface);
  [[nodiscard]] std::optional<TabLocation> capturedTab() const noexcept { return tab_drag_.source(); }
  void retireHistoryHover();
  [[nodiscard]] const HistoryHover &historyHover() const noexcept { return history_hover_; }
  void presentHistoryHover(std::span<const HistoryHoverTarget> targets);
  [[nodiscard]] const QString &historyHoverRevision() const noexcept { return history_hover_revision_; }
  void abandon(TerminalItem &terminal);
  void ungrab(TerminalItem &terminal);
  void observeTerminalScroll(TerminalItem &terminal);
  void retireTerminalScroll();
  bool eventFilter(QObject *watched, QEvent *event) override;
  bool handleNativeScroll(std::string_view event_type, const void *message);

private:
  struct Capture {
    QPointer<TerminalItem> terminal;
    ChildMouseGesture child{};
    HistoryActionCapture history;
    std::uint64_t pane_id = 0;
    bool held = false;
  };

  struct Recipient {
    QPointer<TerminalItem> terminal;
    Qt::MouseButtons view_buttons;
    Qt::MouseButtons child_buttons;
  };

  using Recipients = std::array<Recipient, static_cast<std::size_t>(MouseButton::none)>;

  [[nodiscard]] Capture *capture(Qt::MouseButton button) noexcept;
  [[nodiscard]] Recipients recipients() const;
  [[nodiscard]] ChildMouseView view(const Capture &lease) const;
  [[nodiscard]] static ChildMouseSample sample(const QMouseEvent &event, MousePhase phase, MouseButton button);
  [[nodiscard]] bool occupied() const noexcept;
  void observeHistoryHover(QPointF position, HistoryHover::Observation observation);
  void notifyHistoryHover();
  void report(std::uint64_t pane_id, const std::optional<ChildMouseReport> &report);
  void cancelPane(std::uint64_t pane_id);
  void cancel();
  void cancelTabDrag();
  void observeTabHover(std::optional<QPointF> position);
  [[nodiscard]] bool tabKey(QKeyEvent &event);
  void updateTabDragVisual();
  [[nodiscard]] bool pressTab(QMouseEvent &event);
  [[nodiscard]] bool updateTabDrag(QMouseEvent &event, bool released);
  bool press(QMouseEvent &event);
  bool move(QMouseEvent &event);
  bool release(QMouseEvent &event);
  static void deliver(TerminalItem &terminal, const QMouseEvent &event, Qt::MouseButtons buttons);

  Application &application_;
  NativePointerEvents native_events_;
  tbc::view<ActiveHistoryScrollEvents, tbc::lt::self> history_scroll_events_;
  QPointer<QQuickWindow> window_;
  QPointer<TerminalItem> terminal_scroll_owner_;
  std::array<Capture, static_cast<std::size_t>(MouseButton::none)> captures_;
  HistoryHover history_hover_;
  std::optional<std::uint64_t> history_hover_revision_value_;
  QString history_hover_revision_;
  TabDrag tab_drag_;
  TabDropSlots tab_drop_slots_;
  std::optional<TabDragMove> pending_tab_move_;
  TabDropSurface tab_capture_surface_;
  QPointF tab_pointer_;
  qreal tab_grab_offset_ = 0;
  bool tab_escape_held_ = false;
  bool delivering_ = false;
  bool handing_off_ = false;
};

}
