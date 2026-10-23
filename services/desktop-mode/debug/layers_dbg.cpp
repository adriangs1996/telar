// Checks the layers Telar's macOS Spaces are made of, with the same VirtualSpaces the desktop uses.
// It makes two Spaces on the focused display and puts on the desktop what the desktop will: a
// full-screen wallpaper (teal) at the level of Telar's, a pane (orange) on the first Space's
// stage, and a window of its own (purple) left on the desktop, like an application Telar ignores.
//
// While the scene holds, look at it: the teal wallpaper should cover macOS's, the purple window
// should be in front of the orange pane, and clicking either should bring it in front. --app
// moves the first window of a running application onto the stage too: right-click it and open
// its menus, which should show in front of everything.
//
// Then it measures what the workbench relies on: a pane placed on the hidden second Space and
// shown transparent draws its first frame, a switch shows it and hides the first Space, and
// raising and activating it keep it on its stage. Every window returns to its desktop at the end.

#include "native-backends/macos/spaces_bridge.hpp"
#include "native-backends/macos/virtual_spaces.hpp"
#include "support/external_window_probe.hpp"
#include "support/layers_probe.hpp"
#include <QColor>
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QPainter>
#include <QQuickWindow>
#include <QRasterWindow>
#include <QScreen>
#include <chrono>
#include <cstdio>
#include <exception>
#include <optional>

namespace {
  using Clock = std::chrono::steady_clock;
  using Milliseconds = std::chrono::duration<double, std::milli>;

  constexpr auto settle = std::chrono::milliseconds{500};
  constexpr auto first_frame_deadline = std::chrono::seconds{2};
  constexpr auto switch_deadline = std::chrono::seconds{2};
  constexpr int pane_margin = 120;
  constexpr QSize desktop_window{520, 320};

  class Swatch final : public QRasterWindow {
  public:
    explicit Swatch(QColor color)
        : color_(color) {}

  protected:
    void paintEvent(QPaintEvent *) override {
      QPainter(this).fillRect(QRect(QPoint(), size()), color_);
    }

  private:
    QColor color_;
  };

  // Lets the window server and AppKit catch up without blocking the run loop.
  void pump(std::chrono::milliseconds duration) {
    const auto until = Clock::now() + duration;
    while (Clock::now() < until) {
      QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    }
  }

  // Milliseconds until the condition holds, or nothing when the deadline passes first.
  std::optional<double> until(auto condition, std::chrono::milliseconds deadline) {
    const auto start = Clock::now();
    while (Clock::now() - start < deadline) {
      if (condition()) {
        return Milliseconds(Clock::now() - start).count();
      }

      QCoreApplication::processEvents(QEventLoop::AllEvents, 1);
    }

    return std::nullopt;
  }

  void report(const char *label, std::optional<double> milliseconds) {
    if (milliseconds) {
      std::printf("  %-44s yes, %.1f ms\n", label, *milliseconds);
    } else {
      std::printf("  %-44s NO\n", label);
    }
  }

  void check(const char *label, bool value) {
    std::printf("  %-44s %s\n", label, value ? "yes" : "NO");
  }

  bool shown(std::uint32_t window) {
    return external_window_probe::stackIndex(window) >= 0;
  }

  bool inFront(std::uint32_t window, std::uint32_t other) {
    const auto index = external_window_probe::stackIndex(window);
    return index >= 0 && index < external_window_probe::stackIndex(other);
  }

  int run(int hold, const QString &application) {
    auto &spaces = macos::spaces::VirtualSpaces::get();
    auto state = macos::spaces::snapshot();
    const auto focused = std::ranges::find(state.spaces, state.focused_space, &DesktopSpace::id);
    if (focused == state.spaces.end()) {
      std::printf("no focused display\n");
      return 1;
    }

    const auto display = focused->display;
    const auto *screen = QGuiApplication::primaryScreen();
    for (auto *candidate : QGuiApplication::screens()) {
      const auto origin = candidate->geometry().topLeft();
      const auto found = std::ranges::find(state.displays, display, &DesktopDisplay::id);
      if (found != state.displays.end() && origin == QPoint(int(found->x), int(found->y))) {
        screen = candidate;
      }
    }

    spaces.prepare();
    const auto first = spaces.create(display);
    const auto second = spaces.create(display);
    spaces.overlay(state);
    std::printf("Spaces %llu (shown) and %llu (hidden) on display %u\n",
                static_cast<unsigned long long>(first),
                static_cast<unsigned long long>(second),
                display);

    Swatch wallpaper(QColor(0x1f, 0x5f, 0x5f));
    wallpaper.setFlags(Qt::FramelessWindowHint | Qt::WindowTransparentForInput |
                       Qt::WindowDoesNotAcceptFocus);
    wallpaper.setGeometry(screen->geometry());
    layers_probe::setWallpaperLevel(wallpaper);
    wallpaper.show();

    const auto area = screen->availableGeometry();
    QQuickWindow pane;
    pane.setColor(QColor(0xe0, 0x80, 0x20));
    pane.setFlags(Qt::FramelessWindowHint);
    pane.setGeometry(area.adjusted(pane_margin, pane_margin / 3, -pane_margin / 3, -pane_margin));
    const std::uint32_t pane_id[] = {layers_probe::windowNumber(pane)};
    macos::spaces::moveToLayer(pane_id, spaces.stage(first));
    pane.show();

    Swatch desktop(QColor(0x70, 0x30, 0xa0));
    desktop.setGeometry(QRect(area.topLeft() + QPoint(pane_margin / 2, area.height() / 3),
                              desktop_window));
    desktop.show();

    std::optional<std::uint32_t> foreign;
    if (!application.isEmpty()) {
      const auto pid = external_window_probe::processNamed(application);
      const auto windows = pid ? external_window_probe::windowsOf(pid)
                               : std::vector<external_window_probe::Window>{};
      if (windows.empty()) {
        std::printf("no window of %s\n", qPrintable(application));
      } else {
        foreign = windows.front().id();
        const std::uint32_t moved[] = {*foreign};
        macos::spaces::moveToLayer(moved, spaces.stage(first));
      }
    }

    pump(settle);
    const auto wallpaper_id = layers_probe::windowNumber(wallpaper);
    const auto desktop_id = layers_probe::windowNumber(desktop);
    std::printf("scene\n");
    check("pane on the first stage", macos::spaces::spaceOf(pane_id[0]) == first);
    check("pane on screen", shown(pane_id[0]));
    check("pane in front of the wallpaper", inFront(pane_id[0], wallpaper_id));
    check("purple window, shown later, in front of the pane", inFront(desktop_id, pane_id[0]));
    pane.raise();
    pump(settle);
    check("pane raised: in front of the purple window", inFront(pane_id[0], desktop_id));
    check("and still on its stage", macos::spaces::spaceOf(pane_id[0]) == first);
    if (foreign) {
      check("the application's window on the first stage",
            macos::spaces::spaceOf(*foreign) == first);
      std::printf("  right-click the application's window and open its menus\n");
    }

    std::printf("holding the scene %d s: look at it\n", hold);
    std::fflush(stdout);
    pump(std::chrono::seconds{hold});

    std::printf("a pane prewarmed on the hidden Space\n");
    QQuickWindow incoming;
    incoming.setColor(QColor(0x30, 0xa0, 0x50));
    incoming.setFlags(Qt::FramelessWindowHint);
    incoming.setGeometry(pane.geometry());
    const std::uint32_t incoming_id[] = {layers_probe::windowNumber(incoming)};
    macos::spaces::moveToLayer(incoming_id, spaces.stage(second));
    bool drew = false;
    QObject::connect(&incoming, &QQuickWindow::frameSwapped, &incoming, [&] {
      drew = true;
    });

    incoming.setOpacity(0);
    incoming.show();
    report("draws its first frame while hidden", until([&] {
             return drew;
           },
           first_frame_deadline));
    check("stays on its stage after show", macos::spaces::spaceOf(incoming_id[0]) == second);
    check("not on screen", !shown(incoming_id[0]));

    std::printf("switch to the second Space\n");
    incoming.setOpacity(1);
    spaces.show(second);
    report("the new pane comes on screen", until([&] {
             return shown(incoming_id[0]);
           },
           switch_deadline));
    report("the old pane leaves the screen", until([&] {
             return !shown(pane_id[0]);
           },
           switch_deadline));
    check("the purple window stays on screen", shown(desktop_id));
    check("the wallpaper stays on screen", shown(wallpaper_id));

    incoming.raise();
    incoming.requestActivate();
    pump(settle);
    check("raising and activating keep it on its stage",
          macos::spaces::spaceOf(incoming_id[0]) == second);

    spaces.show(first);
    report("back: the first pane comes on screen", until([&] {
             return shown(pane_id[0]);
           },
           switch_deadline));

    spaces.release();
    pump(settle);
    if (foreign) {
      check("the application's window back on its desktop",
            macos::spaces::spaceOf(*foreign) == state.focused_space);
    }

    return 0;
  }
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  QCommandLineParser parser;
  parser.addHelpOption();
  const QCommandLineOption hold_option("hold", "Seconds the scene holds.", "seconds", "20");
  const QCommandLineOption app_option(
      "app", "A running application whose first window joins the stage.", "name");
  parser.addOptions({hold_option, app_option});
  parser.process(application);

  try {
    return run(parser.value(hold_option).toInt(), parser.value(app_option));
  } catch (const std::exception &failure) {
    std::printf("failed: %s\n", failure.what());
    macos::spaces::VirtualSpaces::get().release();
    return 1;
  }
}
