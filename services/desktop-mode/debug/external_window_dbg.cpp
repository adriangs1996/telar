// Measures hiding another application's windows on a tab switch, as the workbench will have to
// with external windows. A helper process, this program with --serve, owns two tabs of windows:
// a grid filling the screen and a row across its bottom half, so the first tab's windows would
// show above the second's unless they are hidden. Each switch shows the incoming tab's windows
// and hides the outgoing tab's.
//
//   minimize   Accessibility minimizes and restores them.
//   offscreen  Accessibility moves them to the bottom right corner of their display and back,
//              leaving --sliver points on screen.
//   layer      SkyLight moves them into a hidden layer, an unmanaged Space, and back to the
//              desktop.
//   behind     A window of this process at the normal level, the wall, covers the display:
//              showing raises the incoming windows through Accessibility, and hiding is one
//              window server call that orders the wall right below them.
//
// For each strategy it reports how long the calls block the thread that makes them, how long the
// window server takes to show the result, and how much of a hidden window stays visible. Then it
// activates the helper, as the Dock and Cmd+Tab do and with all of its windows, and reports how
// much of the hidden tab comes into view. --hang then freezes the helper's main thread and times
// one hide and one show per strategy, as with an application that stopped answering. --app runs
// the switches on a running application's windows instead of the helper's.

#include "native-backends/macos/spaces_bridge.hpp"
#include "support/external_window_probe.hpp"
#include "support/samples.hpp"
#include <QColor>
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QPainter>
#include <QProcess>
#include <QRasterWindow>
#include <QScreen>
#include <QSocketNotifier>
#include <QThread>
#include <QTimer>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <memory>
#include <optional>
#include <stdexcept>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
  using Clock = std::chrono::steady_clock;
  using Milliseconds = std::chrono::duration<double, std::milli>;
  using external_window_probe::Window;

  constexpr int maximum_windows = 16;
  constexpr int tab_count = 2;
  constexpr int screen_margin = 80;
  constexpr int window_gap = 12;
  // Below every desktop window; hidden anyway.
  constexpr int parking_level = -1;
  constexpr auto helper_deadline = std::chrono::seconds{10};
  constexpr auto settle_poll = std::chrono::milliseconds{2};
  constexpr auto settle_deadline = std::chrono::seconds{2};
  constexpr auto pause = std::chrono::milliseconds{150};
  constexpr auto hang_margin = std::chrono::milliseconds{500};
  // How long the leak test watches the hidden tab after activating the application.
  constexpr auto leak_window = std::chrono::milliseconds{500};
  // A hidden window counts as gone when no more than this share of its area stays visible.
  constexpr double hidden_share = 0.01;
  // A shown window counts as back when this share of its area is visible.
  constexpr double shown_share = 0.9;

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

  // The helper: an ordinary application whose windows the bench drives from another process.
  int serve(QGuiApplication &application, int per_tab) {
    const auto area =
        QGuiApplication::primaryScreen()->availableGeometry().adjusted(screen_margin,
                                                                       screen_margin,
                                                                       -screen_margin,
                                                                       -screen_margin);
    const int columns = static_cast<int>(std::ceil(std::sqrt(per_tab)));
    const int rows = (per_tab + columns - 1) / columns;
    const int width = (area.width() - window_gap * (columns - 1)) / columns;
    const int height = (area.height() - window_gap * (rows - 1)) / rows;
    std::vector<std::unique_ptr<Swatch>> windows;

    // The first tab's windows are created first, so their window numbers are the lower ones.
    for (int tab = 0; tab < tab_count; ++tab) {
      for (int index = 0; index < per_tab; ++index) {
        auto window = std::make_unique<Swatch>(QColor::fromHsv(tab * 180 + index * 9, 110, 120));
        window->setTitle(QStringLiteral("external tab %1 window %2").arg(tab).arg(index));
        if (tab == 0) {
          window->setGeometry(area.x() + index % columns * (width + window_gap),
                              area.y() + index / columns * (height + window_gap),
                              width,
                              height);
        } else {
          const int slot = (area.width() - window_gap * (per_tab - 1)) / per_tab;
          window->setGeometry(area.x() + index * (slot + window_gap),
                              area.center().y(),
                              slot,
                              area.height() / 2);
        }

        window->show();
        windows.push_back(std::move(window));
      }
    }

    QSocketNotifier input(STDIN_FILENO, QSocketNotifier::Read);
    QObject::connect(&input, &QSocketNotifier::activated, &application, [&] {
      std::array<char, 64> line{};
      const auto count = ::read(STDIN_FILENO, line.data(), line.size() - 1);
      int seconds = 0;
      if (count <= 0) {
        QCoreApplication::quit();
        return;
      }

      if (std::sscanf(line.data(), "hang %d", &seconds) == 1) {
        std::printf("hanging\n");
        std::fflush(stdout);
        QThread::sleep(seconds);
      }
    });

    QTimer::singleShot(0, &application, [] {
      std::printf("ready\n");
      std::fflush(stdout);
    });

    return application.exec();
  }

  struct Placed {
    Window window;
    // Where the window was before it was first hidden, for strategies that move it away.
    QRectF frame;
  };

  using Tab = std::vector<Placed>;

  struct Strategy {
    const char *name;
    std::function<bool(Placed &)> hide;
    std::function<bool(Placed &)> show;
    // Around each switch, for strategies that act on a tab rather than on each window.
    std::function<void()> begin = [] {
    };
    std::function<void()> end = [] {
    };
  };

  bool hidden(const Placed &placed) {
    return external_window_probe::visibleArea(placed.window.id()) <=
           hidden_share * placed.frame.width() * placed.frame.height();
  }

  bool shown(const Placed &placed) {
    return external_window_probe::visibleArea(placed.window.id()) >=
           shown_share * placed.frame.width() * placed.frame.height();
  }

  class Bench final {
  public:
    Bench(std::int64_t pid, QProcess *helper, double timeout, double sliver)
        : pid_(pid),
          helper_(helper),
          sliver_(sliver) {
      auto windows = external_window_probe::windowsOf(pid);
      if (windows.size() < tab_count) {
        throw std::runtime_error("The application needs at least two standard windows");
      }

      if (helper_) {
        std::ranges::sort(windows, {}, &Window::id);
      }

      const auto half = windows.size() / tab_count;
      for (std::size_t index = 0; index < half * tab_count; ++index) {
        if (timeout > 0) {
          windows[index].setTimeout(timeout);
        }

        const auto frame = windows[index].frame();
        tabs_[index / half].push_back({std::move(windows[index]), frame});
      }
    }

    ~Bench() {
      if (parking_) {
        try {
          const std::uint64_t layers[] = {parking_};
          macos::spaces::evacuate(layers);
          macos::spaces::destroyLayer(parking_);
        } catch (const std::exception &error) {
          std::printf("could not remove the parking layer: %s\n", error.what());
        }
      }
    }

    std::vector<Strategy> strategies() {
      return {
          {"minimize",
           [](Placed &placed) {
             return placed.window.setMinimized(true);
           },
           [](Placed &placed) {
             return placed.window.setMinimized(false);
           }},
          {"offscreen",
           [this](Placed &placed) {
             const auto *screen = QGuiApplication::screenAt(placed.frame.center().toPoint());
             const auto bounds =
                 QRectF(screen ? screen->geometry() : QGuiApplication::primaryScreen()->geometry());
             return placed.window.setPosition(bounds.bottomRight() - QPointF(sliver_, sliver_));
           },
           [](Placed &placed) {
             return placed.window.setPosition(placed.frame.topLeft());
           }},
          {"layer",
           [this](Placed &placed) {
             return move(placed, parking());
           },
           [this](Placed &placed) {
             return move(placed, home_);
           }},
          {"behind",
           [this](Placed &) {
             // The wall goes right below the lowest incoming window, which covers the whole tab.
             if (!walled_) {
               wall().orderBelow(anchor_);
               walled_ = true;
             }

             return true;
           },
           [this](Placed &placed) {
             const bool raised = placed.window.raise();
             activated_ += external_window_probe::frontmost() == pid_;
             ++raises_;
             if (!anchor_) {
               anchor_ = placed.window.id();
             }

             return raised;
           },
           [this] {
             anchor_ = 0;
             walled_ = false;
           },
           [this] {
             wall().orderOut();
           }},
      };
    }

    void run(const Strategy &strategy, int switches) {
      std::vector<double> hides, shows, calls, appeared, vanished, residues;
      int refused = 0, unsettled = 0;
      raises_ = 0;
      activated_ = 0;
      // Nothing of the helper's is active, so a raise that activates it shows.
      external_window_probe::activate(getpid(), false);
      strategy.begin();
      for (auto &placed : tabs_[0]) {
        refused += !strategy.show(placed);
      }

      for (auto &placed : tabs_[1]) {
        refused += !strategy.hide(placed);
      }

      wait(tabs_[0], shown);
      wait(tabs_[1], hidden);

      for (int done = 0; done < switches; ++done) {
        auto &outgoing = tabs_[current_];
        auto &incoming = tabs_[1 - current_];
        external_window_probe::activate(getpid(), false);
        std::this_thread::sleep_for(pause);
        const auto start = Clock::now();
        strategy.begin();
        for (auto &placed : incoming) {
          const auto begin = Clock::now();
          refused += !strategy.show(placed);
          shows.push_back(Milliseconds(Clock::now() - begin).count());
        }

        for (auto &placed : outgoing) {
          const auto begin = Clock::now();
          refused += !strategy.hide(placed);
          hides.push_back(Milliseconds(Clock::now() - begin).count());
        }

        calls.push_back(Milliseconds(Clock::now() - start).count());
        unsettled += !wait(incoming, shown);
        appeared.push_back(Milliseconds(Clock::now() - start).count());
        unsettled += !wait(outgoing, hidden);
        vanished.push_back(Milliseconds(Clock::now() - start).count());
        for (const auto &placed : outgoing) {
          residues.push_back(external_window_probe::visibleArea(placed.window.id()));
        }

        current_ = 1 - current_;
        std::this_thread::sleep_for(pause);
      }

      std::printf("%s: %d switches of %zu windows\n", strategy.name, switches, tabs_[0].size());
      samples::report("show", shows);
      samples::report("hide", hides);
      samples::report("switch", calls);
      samples::report("appeared", appeared);
      samples::report("vanished", vanished);
      std::ranges::sort(residues);
      std::printf("  refused calls %d, waits not settled within %llds %d, "
                  "largest visible remainder of a hidden window %.0f pt²\n",
                  refused,
                  static_cast<long long>(settle_deadline.count()),
                  unsettled,
                  residues.empty() ? 0.0 : residues.back());
      if (raises_) {
        std::printf("  raises that activated the application: %d of %d\n", activated_, raises_);
      }

      leaks();
      restore(strategy);
    }

    // One hide and one show of a window while the helper's main thread is frozen.
    void hang(const Strategy &strategy, int seconds) {
      auto &placed = tabs_[current_].front();
      freeze(seconds);
      auto begin = Clock::now();
      const bool hid = strategy.hide(placed);
      const auto hide_time = Milliseconds(Clock::now() - begin).count();
      begin = Clock::now();
      const bool showed = strategy.show(placed);
      const auto show_time = Milliseconds(Clock::now() - begin).count();
      std::printf("%s with the application frozen for %ds: hide %.1f ms (%s), show %.1f ms (%s)\n",
                  strategy.name,
                  seconds,
                  hide_time,
                  hid ? "accepted" : "refused",
                  show_time,
                  showed ? "accepted" : "refused");
      std::this_thread::sleep_until(frozen_until_);
      strategy.show(placed);
      wait(tabs_[current_], shown);
    }

  private:
    // Activates the helper as the Dock and Cmd+Tab do, then with all of its windows, and reports
    // the most of a hidden window that came into view.
    void leaks() {
      const auto &hidden_tab = tabs_[current_ == 0 ? 1 : 0];
      for (const bool all : {false, true}) {
        external_window_probe::activate(getpid(), false);
        std::this_thread::sleep_for(pause);
        double before = 0;
        for (const auto &placed : hidden_tab) {
          const auto area = placed.frame.width() * placed.frame.height();
          before = std::max(before, external_window_probe::visibleArea(placed.window.id()) / area);
        }

        external_window_probe::activate(pid_, all);
        double worst = 0;
        bool ahead = false;
        const auto deadline = Clock::now() + leak_window;
        while (Clock::now() < deadline) {
          for (const auto &placed : hidden_tab) {
            const auto area = placed.frame.width() * placed.frame.height();
            worst = std::max(worst, external_window_probe::visibleArea(placed.window.id()) / area);
            if (wall_ && walled_) {
              const auto index = external_window_probe::stackIndex(placed.window.id());
              ahead =
                  ahead || (index >= 0 && index < external_window_probe::stackIndex(wall_->id()));
            }
          }

          std::this_thread::sleep_for(settle_poll);
        }

        std::printf("  activating the application%s: %.0f%% of a hidden window in view before, "
                    "up to %.0f%% after%s\n",
                    all ? " with all its windows" : "",
                    before * 100,
                    worst * 100,
                    ahead ? ", hidden windows in front of the wall" : "");
      }
    }

    external_window_probe::Wall &wall() {
      if (!wall_) {
        const auto *screen = QGuiApplication::screenAt(tabs_[0].front().frame.center().toPoint());
        wall_.emplace(QRectF((screen ? screen : QGuiApplication::primaryScreen())->geometry()));
      }

      return *wall_;
    }

    // A hidden layer, made on first use, and the desktop the windows return to.
    std::uint64_t parking() {
      if (parking_) {
        return parking_;
      }

      home_ = macos::spaces::snapshot().focused_space;
      parking_ = macos::spaces::createLayer(parking_level);
      const std::uint64_t hidden[] = {parking_};
      macos::spaces::showLayers({}, hidden);
      std::printf("created parking layer %llu\n", static_cast<unsigned long long>(parking_));
      return parking_;
    }

    bool move(Placed &placed, std::uint64_t space) {
      try {
        const std::uint32_t windows[] = {placed.window.id()};
        macos::spaces::moveToLayer(windows, space);
        return true;
      } catch (const std::exception &) {
        return false;
      }
    }

    bool wait(const Tab &tab, bool (*done)(const Placed &)) {
      const auto deadline = Clock::now() + settle_deadline;
      while (Clock::now() < deadline) {
        if (std::ranges::all_of(tab, done)) {
          return true;
        }

        std::this_thread::sleep_for(settle_poll);
      }

      return false;
    }

    void restore(const Strategy &strategy) {
      for (auto &tab : tabs_) {
        for (auto &placed : tab) {
          strategy.show(placed);
        }
      }

      strategy.end();

      wait(tabs_[0], shown);
      wait(tabs_[1], shown);
      current_ = 0;
    }

    void freeze(int seconds) {
      if (!helper_) {
        throw std::runtime_error("--hang needs the helper application");
      }

      helper_->write(QByteArray("hang ") + QByteArray::number(seconds) + '\n');
      helper_->waitForBytesWritten();
      while (!helper_->readAllStandardOutput().contains("hanging")) {
        helper_->waitForReadyRead(static_cast<int>(
            std::chrono::duration_cast<std::chrono::milliseconds>(helper_deadline).count()));
      }

      frozen_until_ = Clock::now() + std::chrono::seconds{seconds} + hang_margin;
    }

    std::int64_t pid_;
    QProcess *helper_;
    double sliver_;
    std::optional<external_window_probe::Wall> wall_;
    std::uint32_t anchor_ = 0;
    bool walled_ = false;
    int raises_ = 0;
    int activated_ = 0;
    std::array<Tab, tab_count> tabs_;
    int current_ = 0;
    std::uint64_t home_ = 0;
    std::uint64_t parking_ = 0;
    Clock::time_point frozen_until_;
  };

  std::int64_t startHelper(QProcess &helper, int per_tab) {
    helper.setProcessChannelMode(QProcess::ForwardedErrorChannel);
    helper.start(QCoreApplication::applicationFilePath(),
                 {QStringLiteral("--serve"), QString::number(per_tab)});
    const auto deadline = Clock::now() + helper_deadline;
    QByteArray output;
    while (!output.contains("ready") && Clock::now() < deadline) {
      helper.waitForReadyRead(100);
      output += helper.readAllStandardOutput();
    }

    if (!output.contains("ready")) {
      throw std::runtime_error("The helper application did not start");
    }

    // Accessibility lists a window only once the window server has it.
    const auto pid = static_cast<std::int64_t>(helper.processId());
    while (external_window_probe::windowsOf(pid).size() < static_cast<std::size_t>(per_tab * 2) &&
           Clock::now() < deadline) {
      std::this_thread::sleep_for(pause);
    }

    return pid;
  }
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  QCommandLineParser parser;
  parser.setApplicationDescription(
      "Measures hiding another application's windows on a tab switch.");
  parser.addHelpOption();
  const QCommandLineOption serve_option("serve", "Run as the helper application.", "per-tab");
  const QCommandLineOption strategy_option("strategy",
                                           "minimize, offscreen, layer, behind or all (default).",
                                           "strategy",
                                           "all");
  const QCommandLineOption windows_option("windows",
                                          "Helper windows per tab, 1 to 16 (default 4).",
                                          "count",
                                          "4");
  const QCommandLineOption switches_option("switches", "Tab switches (default 20).", "count", "20");
  const QCommandLineOption hang_option("hang",
                                       "Then freeze the helper this many seconds per strategy.",
                                       "seconds");
  const QCommandLineOption timeout_option(
      "timeout",
      "Accessibility messaging timeout in seconds (default: the system's).",
      "seconds");
  const QCommandLineOption sliver_option("sliver",
                                         "Points offscreen leaves on screen (default 1).",
                                         "points",
                                         "1");
  const QCommandLineOption app_option(
      "app",
      "Use a running application's windows, by name or bundle identifier.",
      "name");
  parser.addOptions({serve_option,
                     strategy_option,
                     windows_option,
                     switches_option,
                     hang_option,
                     timeout_option,
                     sliver_option,
                     app_option});
  parser.process(application);

  bool windows_valid = false, switches_valid = false;
  const int windows = parser.value(windows_option).toInt(&windows_valid);
  const int switches = parser.value(switches_option).toInt(&switches_valid);
  if (!windows_valid || windows < 1 || windows > maximum_windows || !switches_valid ||
      switches < 1) {
    parser.showHelp(1);
  }

  if (parser.isSet(serve_option)) {
    return serve(application, parser.value(serve_option).toInt());
  }

  if (!external_window_probe::trusted()) {
    std::fprintf(stderr,
                 "external_window_dbg: grant Accessibility to the terminal that runs it, in "
                 "System Settings > Privacy & Security > Accessibility\n");
    return 1;
  }

  QProcess helper;
  try {
    std::int64_t pid = 0;
    if (parser.isSet(app_option)) {
      pid = external_window_probe::processNamed(parser.value(app_option));
      if (!pid) {
        throw std::runtime_error("No running application has that name");
      }
    } else {
      pid = startHelper(helper, windows);
    }

    Bench bench(pid,
                parser.isSet(app_option) ? nullptr : &helper,
                parser.value(timeout_option).toDouble(),
                parser.value(sliver_option).toDouble());
    const auto chosen = parser.value(strategy_option);
    for (const auto &strategy : bench.strategies()) {
      if (chosen != "all" && chosen != strategy.name) {
        continue;
      }

      bench.run(strategy, switches);
      if (parser.isSet(hang_option)) {
        bench.hang(strategy, parser.value(hang_option).toInt());
      }
    }
  } catch (const std::exception &error) {
    std::fprintf(stderr, "external_window_dbg: %s\n", error.what());
    helper.kill();
    helper.waitForFinished();
    return 1;
  }

  helper.closeWriteChannel();
  helper.waitForFinished();
  return 0;
}
