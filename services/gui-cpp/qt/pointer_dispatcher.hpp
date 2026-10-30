#pragma once

#include "input/child_mouse.hpp"
#include "input/history_action_capture.hpp"
#include "native_pointer_events.hpp"
#include <QMouseEvent>
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <array>
#include <cstddef>

namespace telar::gui::qt {

class Application;
class TerminalItem;

class PointerDispatcher final : public QObject {
public:
  explicit PointerDispatcher(Application &application);
  void setWindow(QQuickWindow &window);
  void acquire(TerminalItem &terminal, Qt::MouseButton button);
  void beginChild(const ChildMouseView &view, ChildMouseSample sample);
  void release(Qt::MouseButton button);
  void presentHistoryActions(const HistoryActionSurface &surface);
  [[nodiscard]] bool historyRowHoverEnabled() const noexcept { return history_row_hover_enabled_; }
  void abandon(TerminalItem &terminal);
  void ungrab(TerminalItem &terminal);
  bool eventFilter(QObject *watched, QEvent *event) override;

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
  [[nodiscard]] bool historyGestureHeld() const noexcept;
  void allowHistoryRowHover(bool allowed);
  void report(std::uint64_t pane_id, const std::optional<ChildMouseReport> &report);
  void cancelPane(std::uint64_t pane_id);
  void cancel();
  bool press(QMouseEvent &event);
  bool move(QMouseEvent &event);
  bool release(QMouseEvent &event);
  static void deliver(TerminalItem &terminal, const QMouseEvent &event, Qt::MouseButtons buttons);

  Application &application_;
  NativePointerEvents native_events_;
  QPointer<QQuickWindow> window_;
  std::array<Capture, static_cast<std::size_t>(MouseButton::none)> captures_;
  bool history_row_hover_enabled_ = true;
  bool delivering_ = false;
  bool handing_off_ = false;
};

}
