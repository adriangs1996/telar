// Measures how long a Space switch takes to show, through the same SkyLight bridge the desktop
// uses. It creates a temporary Space on the focused display, puts a window of its own on that
// Space and another on the current one, and switches between them. Each switch reports when the
// window server shows the destination's window and drops the origin's: a switch without an
// animation lands within a frame or two, macOS's slide takes hundreds of milliseconds. The
// temporary Space is removed afterwards.

#include "native-backends/macos/spaces_bridge.hpp"
#include "support/external_window_probe.hpp"
#include "support/samples.hpp"
#include "support/window_hide_probe.hpp"
#include <QColor>
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QPainter>
#include <QRasterWindow>
#include <QScreen>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
  using Clock = std::chrono::steady_clock;
  using Milliseconds = std::chrono::duration<double, std::milli>;

  constexpr auto poll = std::chrono::milliseconds{1};
  constexpr auto deadline = std::chrono::seconds{3};
  constexpr auto rest = std::chrono::milliseconds{300};
  constexpr auto settle = std::chrono::milliseconds{500};
  constexpr QRect probe_rect{200, 200, 600, 400};

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

  bool onScreen(std::uint32_t window) {
    return external_window_probe::visibleArea(window) > 0;
  }

  // Lets the window server and AppKit catch up without blocking the run loop.
  void pump(std::chrono::milliseconds duration) {
    const auto until = Clock::now() + duration;
    while (Clock::now() < until) {
      QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    }
  }

  DesktopState waitFor(auto predicate) {
    const auto until = Clock::now() + deadline;
    while (Clock::now() < until) {
      auto state = macos::spaces::snapshot();
      if (predicate(state)) {
        return state;
      }

      pump(std::chrono::milliseconds{20});
    }

    throw std::runtime_error("macOS did not reach the expected Spaces state");
  }

  struct Switch {
    double shown = -1;
    double dropped = -1;
    double overlap = 0;
  };

  // Activates `space` and watches both windows until the destination's is on screen and the
  // origin's is gone, or the deadline passes.
  Switch measure(std::uint64_t space, std::uint32_t incoming, std::uint32_t outgoing) {
    const auto state = macos::spaces::snapshot();
    Switch result;
    const auto start = Clock::now();
    macos::spaces::activate(state, space);
    auto last = start;
    while (Clock::now() - start < deadline && (result.shown < 0 || result.dropped < 0)) {
      const bool in = onScreen(incoming);
      const bool out = onScreen(outgoing);
      const auto now = Clock::now();
      if (in && out) {
        result.overlap += Milliseconds(now - last).count();
      }

      if (in && result.shown < 0) {
        result.shown = Milliseconds(now - start).count();
      }

      if (!out && result.dropped < 0) {
        result.dropped = Milliseconds(now - start).count();
      }

      last = now;
      QCoreApplication::processEvents(QEventLoop::AllEvents, 1);
      std::this_thread::sleep_for(poll);
    }

    return result;
  }
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  QCommandLineParser parser;
  parser.setApplicationDescription("Measures how long a Space switch takes to show.");
  parser.addHelpOption();
  const QCommandLineOption switches_option("switches", "Switches (default 20).", "count", "20");
  parser.addOption(switches_option);
  parser.process(application);
  const int switches = std::max(1, parser.value(switches_option).toInt());

  std::uint64_t temporary = 0;
  std::uint64_t home = 0;
  int status = 0;
  try {
    auto state = macos::spaces::snapshot();
    home = state.focused_space;
    const auto home_space = std::ranges::find(state.spaces, home, &DesktopSpace::id);
    if (home_space == state.spaces.end()) {
      throw std::runtime_error("No focused Space");
    }

    const auto display =
        *std::ranges::find(state.displays, home_space->display, &DesktopDisplay::id);
    temporary = macos::spaces::create();
    state = waitFor([&](const DesktopState &next) {
      return std::ranges::find(next.spaces, temporary, &DesktopSpace::id) != next.spaces.end();
    });

    const auto created = std::ranges::find(state.spaces, temporary, &DesktopSpace::id);
    if (created->display != display.id) {
      const auto count = std::ranges::count(state.spaces, display.id, &DesktopSpace::display);
      macos::spaces::move(temporary, display, static_cast<unsigned>(count));
      waitFor([&](const DesktopState &next) {
        const auto found = std::ranges::find(next.spaces, temporary, &DesktopSpace::id);
        return found != next.spaces.end() && found->display == display.id;
      });
    }

    Swatch home_window(QColor(70, 120, 200));
    Swatch away_window(QColor(200, 120, 70));
    for (auto *window : {&home_window, &away_window}) {
      window->setFlags(Qt::Window | Qt::FramelessWindowHint);
      window->setGeometry(
          probe_rect.translated(QGuiApplication::screens().front()->geometry().topLeft()));
      window->show();
    }

    pump(settle);
    const auto home_id = window_hide_probe::windowNumber(home_window);
    const auto away_id = window_hide_probe::windowNumber(away_window);
    macos::spaces::moveWindow(away_id, temporary);
    pump(settle);

    std::vector<double> shown, dropped, overlap;
    int late = 0;
    for (int done = 0; done < switches; ++done) {
      const bool going = done % 2 == 0;
      const auto result =
          measure(going ? temporary : home, going ? away_id : home_id, going ? home_id : away_id);
      if (result.shown < 0 || result.dropped < 0) {
        ++late;
      } else {
        shown.push_back(result.shown);
        dropped.push_back(result.dropped);
        overlap.push_back(result.overlap);
      }

      pump(rest);
    }

    std::printf("%d Space switches on display %u\n", switches, display.id);
    samples::report("shown", shown);
    samples::report("dropped", dropped);
    samples::report("overlap", overlap);
    std::printf("  switches not settled within %llds: %d\n",
                static_cast<long long>(deadline.count()),
                late);
  } catch (const std::exception &error) {
    std::fprintf(stderr, "space_switch_dbg: %s\n", error.what());
    status = 1;
  }

  try {
    if (temporary) {
      macos::spaces::activate(macos::spaces::snapshot(), home);
      pump(settle);
      macos::spaces::remove(temporary);
      waitFor([&](const DesktopState &next) {
        return std::ranges::find(next.spaces, temporary, &DesktopSpace::id) == next.spaces.end();
      });
    }
  } catch (const std::exception &error) {
    std::fprintf(stderr, "space_switch_dbg: cleanup: %s\n", error.what());
    status = 1;
  }

  return status;
}
