#pragma once

#include <QRectF>
#include <QString>
#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

class QObject;
class QWindow;

namespace workbench::native {
  struct Display {
    QRectF available;
    double scale = 1;
  };

  Display display(std::uint32_t identifier);
  QRect frame(QWindow &window);
  void setFrame(QWindow &window, QRect frame);
  void place(QWindow &window, std::uint64_t space);
  void raise(QWindow &window);
  void setVisible(QWindow &window, bool visible);
  // Prepares the window that holds the keyboard for the panes: present on every Space, and
  // invisible to the mouse, Mission Control and the window cycle.
  void prepareInputWindow(QWindow &window);
  // Commits the input method composition in progress in the window, if there is one.
  void commitComposition(QWindow &window);

  // Another application's window, as the window server and Accessibility describe it. Frames are
  // in global coordinates with the origin at the top left of the main display.
  struct ForeignWindow {
    std::uint32_t id = 0;
    std::int64_t pid = 0;
    // The bundle identifier, or the application's name when it has none.
    QString application;
    QString title;
    QRectF frame;
    std::uint64_t space = 0;
    // Dialogs, sheets and windows that cannot be resized float instead of tiling.
    bool floating = false;

    bool operator==(const ForeignWindow &) const = default;
  };

  struct ForeignWindows {
    std::vector<ForeignWindow> windows;
    // The active application's focused window, when it is one of the windows above.
    std::uint32_t focused = 0;

    bool operator==(const ForeignWindows &) const = default;
  };

  // Observes application windows and applies workbench policy through the platform's
  // window server. Linux owns the surfaces; macOS uses its window server and Accessibility.
  class WindowObserver final {
  public:
    using Delivery = std::function<void(ForeignWindows windows)>;

    // Deliveries run on the thread `receiver` belongs to, which must outlive the observer, and
    // only when something changed.
    WindowObserver(QObject &receiver, Delivery deliver);
    ~WindowObserver();
    WindowObserver(const WindowObserver &) = delete;
    WindowObserver &operator=(const WindowObserver &) = delete;

    void place(std::uint32_t window, QRectF frame);
    void move(std::uint32_t window, QPointF position);
    void hide(std::uint32_t window, QRectF frame);
    void focus(std::uint32_t window);
    // Presses the window's close button, as clicking it would.
    void close(std::uint32_t window);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
  };
} // namespace workbench::native
