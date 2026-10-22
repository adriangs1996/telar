#pragma once

#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <functional>
#include <map>
#include <memory>

namespace workbench {
  // Pane windows never become the key window: each change of key window makes macOS switch the
  // input method context, with blocking round trips to its server. An invisible input window
  // stays the key window instead, while Qt treats the routed pane as its focus window, so Qt
  // Quick focus and the window's active state behave as if the pane were key. A pane that loses
  // the keyboard to another pane keeps its focus item: only its window stops being active. The
  // input window forwards key events to the pane, and the input method reaches the pane's focus
  // item through it.
  class KeyboardRouter final : public QObject {
  public:
    KeyboardRouter();
    ~KeyboardRouter() override;

    // The window never becomes the key window; a press on it calls `requested`.
    void adopt(QQuickWindow &window, std::function<void()> requested);
    // Sends the keyboard to an adopted window from now on, taking the key window back if
    // another window holds it.
    void route(QQuickWindow &window);
    // Whether the window gets the keyboard now.
    bool holds(const QQuickWindow &window) const;

  protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

  private:
    class InputWindow;

    void focusWindowChanged(QWindow *window);
    void handOver(QQuickWindow &window);
    void follow(QQuickWindow *window);

    std::unique_ptr<InputWindow> input_;
    std::map<const QObject *, std::function<void()>> clients_;
    QPointer<QQuickWindow> target_;
    QMetaObject::Connection follow_x_;
    QMetaObject::Connection follow_y_;
    bool input_key_ = false;
    bool handing_over_ = false;
  };
} // namespace workbench
