#pragma once

#include <QPointF>
#include <QRectF>
#include <QString>
#include <cstdint>
#include <vector>

namespace external_window_probe {
  // Whether this process may drive other applications' windows through Accessibility.
  bool trusted();

  // A window of another application, reached through Accessibility.
  class Window final {
  public:
    Window(const void *element, std::uint32_t id);
    ~Window();
    Window(Window &&other) noexcept;
    Window &operator=(Window &&other) noexcept;
    Window(const Window &) = delete;
    Window &operator=(const Window &) = delete;

    std::uint32_t id() const;
    QRectF frame() const;
    // Each returns whether the application accepted the change.
    bool setPosition(QPointF position);
    bool setMinimized(bool minimized);
    // Brings the window in front of the others, as clicking it would.
    bool raise();
    // How long a call waits for an application that does not answer.
    void setTimeout(double seconds);

  private:
    const void *element_;
    std::uint32_t id_;
  };

  // A window of this process at the normal level, covering a rectangle given in the global
  // coordinates Qt and Accessibility use, with the origin at the top left of the main display.
  class Wall final {
  public:
    explicit Wall(QRectF frame);
    ~Wall();
    Wall(const Wall &) = delete;
    Wall &operator=(const Wall &) = delete;

    // Places the wall right below another window, whichever application owns it.
    void orderBelow(std::uint32_t window);
    void orderOut();
    std::uint32_t id() const;

  private:
    void *window_;
  };

  // The process of the active application.
  std::int64_t frontmost();
  // Activates an application as the Dock does, or with all of its windows brought forward.
  void activate(std::int64_t pid, bool all_windows);

  // The process of a running application, by name or bundle identifier; 0 when none.
  std::int64_t processNamed(const QString &name);
  // The application's standard windows, in Accessibility order.
  std::vector<Window> windowsOf(std::int64_t pid);
  // The part of the window the user can see, in square points: what lies on a display and is not
  // covered by a window in front of it. Zero when it is minimized or on a Space no display shows.
  double visibleArea(std::uint32_t id);
  // The window's place among those on screen, from the front; -1 when it is not on screen.
  int stackIndex(std::uint32_t id);
} // namespace external_window_probe
