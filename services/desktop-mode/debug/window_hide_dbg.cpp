// Measures switching between two tabs of pane windows, as the workbench does: the incoming tab's
// windows appear, they draw their first frames, the keyboard moves to one of them, and the
// outgoing tab's windows go away. Both tabs share the same rectangles. The windows are adopted by
// the keyboard router like panes, the application is active, and every window runs an animation.
//
//   hide   The outgoing windows are hidden, and shown again when their tab returns.
//   alpha  The outgoing windows stay ordered in, with opacity zero, mouse events passing through
//          and their content invisible.
//
// After the switches it checks that a mouse down at the centre of each visible pane would hit
// that pane, counts the frames the outgoing windows draw in one second, and reports the process
// memory footprint. --hold keeps the windows up afterwards and prints the window each press
// reaches, to try clicks and Mission Control by hand. --keep-mouse leaves mouse events enabled on
// alpha's outgoing windows, to find out whether a transparent window takes clicks at all.

#include "support/window_hide_probe.hpp"
#include "ui/workbench/keyboard_router.hpp"
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScreen>
#include <QTimer>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <vector>

namespace {
  using Clock = std::chrono::steady_clock;
  using Milliseconds = std::chrono::duration<double, std::milli>;

  enum class Strategy { hide, alpha };

  constexpr int maximum_windows = 32;
  constexpr int tab_count = 2;
  constexpr int screen_margin = 40;
  constexpr int window_gap = 8;
  constexpr double mebibyte = 1024.0 * 1024.0;
  constexpr auto ready_poll = std::chrono::milliseconds{100};
  constexpr auto ready_deadline = std::chrono::seconds{30};
  constexpr auto first_frame_poll = std::chrono::milliseconds{2};
  constexpr auto first_frame_deadline = std::chrono::milliseconds{500};
  constexpr auto settle_delay = std::chrono::milliseconds{150};
  constexpr auto render_window = std::chrono::seconds{1};

  constexpr auto pane_source = R"qml(
import QtQuick

Rectangle {
    Rectangle {
        width: 40
        height: 40
        anchors.centerIn: parent
        color: "white"

        RotationAnimation on rotation {
            from: 0
            to: 360
            duration: 2000
            loops: Animation.Infinite
        }
    }
}
)qml";

  double percentile(const std::vector<double> &sorted, int percent) {
    const auto index = std::min(sorted.size() - 1, sorted.size() * percent / 100);
    return sorted[index];
  }

  void report(const char *label, std::vector<double> values) {
    if (values.empty()) {
      std::printf("  %-8s no samples\n", label);
      return;
    }

    std::sort(values.begin(), values.end());
    double total = 0;
    for (const auto value : values) {
      total += value;
    }

    std::printf("  %-8s p50 %7.3f ms  p95 %7.3f ms  max %7.3f ms  total %8.1f ms\n",
                label,
                percentile(values, 50),
                percentile(values, 95),
                values.back(),
                total);
  }

  struct Pane {
    std::unique_ptr<QQuickWindow> window;
    // Belongs to the window's content item.
    QQuickItem *content = nullptr;
    int frames = 0;
  };

  using Tab = std::vector<Pane>;

  class Bench final : public QObject {
  public:
    Bench(QQmlEngine &engine, Strategy strategy, int count, int switches, bool hold, bool keep_mouse)
        : strategy_(strategy),
          switches_(switches),
          hold_(hold),
          keep_mouse_(keep_mouse) {
      QQmlComponent component(&engine);
      component.setData(pane_source, QUrl());
      if (component.isError()) {
        throw std::runtime_error(component.errorString().toStdString());
      }

      const auto area = QGuiApplication::primaryScreen()->availableGeometry().adjusted(
          screen_margin, screen_margin, -screen_margin, -screen_margin);
      const int columns = static_cast<int>(std::ceil(std::sqrt(count)));
      const int rows = (count + columns - 1) / columns;
      const int width = (area.width() - window_gap * (columns - 1)) / columns;
      const int height = (area.height() - window_gap * (rows - 1)) / rows;

      for (int tab = 0; tab < tab_count; ++tab) {
        tabs_[tab].resize(count);
        for (int index = 0; index < count; ++index) {
          auto &pane = tabs_[tab][index];
          pane.window = std::make_unique<QQuickWindow>();
          pane.window->setFlags(Qt::Window | Qt::FramelessWindowHint);
          pane.window->setTitle(QStringLiteral("tab %1 pane %2").arg(tab).arg(index));
          pane.window->setGeometry(area.x() + index % columns * (width + window_gap),
                                   area.y() + index / columns * (height + window_gap),
                                   width,
                                   height);
          pane.content = qobject_cast<QQuickItem *>(component.create());
          if (!pane.content) {
            throw std::runtime_error(component.errorString().toStdString());
          }

          pane.content->setParent(pane.window->contentItem());
          pane.content->setParentItem(pane.window->contentItem());
          pane.content->setSize(QSizeF(width, height));
          pane.content->setProperty("color", QColor::fromHsv(tab * 180 + index * 7, 90, 70));
          keyboard_.adopt(*pane.window, [this, window = pane.window.get()] {
            if (finished_) {
              std::printf("press reached %s\n", qPrintable(window->title()));
              std::fflush(stdout);
            }
          });
          QObject::connect(pane.window.get(), &QQuickWindow::frameSwapped, this, [&pane] {
            ++pane.frames;
          });
        }
      }
    }

    void start() {
      for (auto &pane : tabs_[0]) {
        pane.window->show();
      }

      // Alpha keeps every window ordered in from the start; the second tab begins retired.
      if (strategy_ == Strategy::alpha) {
        for (auto &pane : tabs_[1]) {
          retire(pane);
          pane.window->show();
        }
      }

      keyboard_.route(*tabs_[0].front().window);
      waitReady(Clock::now() + ready_deadline);
    }

  private:
    void waitReady(Clock::time_point deadline) {
      if (qGuiApp->applicationState() == Qt::ApplicationActive &&
          keyboard_.holds(*tabs_[0].front().window)) {
        QTimer::singleShot(settle_delay, this, [this] {
          switchTab();
        });
        return;
      }

      if (Clock::now() > deadline) {
        std::printf("the application never became active\n");
        QCoreApplication::exit(1);
        return;
      }

      QTimer::singleShot(ready_poll, this, [this, deadline] {
        waitReady(deadline);
      });
    }

    void switchTab() {
      if (done_ == switches_) {
        check();
        return;
      }

      current_ = 1 - current_;
      auto &incoming = tabs_[current_];
      for (auto &pane : incoming) {
        pane.frames = 0;
      }

      const auto start = Clock::now();
      for (auto &pane : incoming) {
        present(pane);
      }

      presents_.push_back(Milliseconds(Clock::now() - start).count());
      awaitFrames(Clock::now() + first_frame_deadline);
    }

    void awaitFrames(Clock::time_point deadline) {
      const auto &incoming = tabs_[current_];
      const bool drawn = std::ranges::all_of(incoming, [](const Pane &pane) {
        return pane.frames > 0;
      });

      if (!drawn && Clock::now() < deadline) {
        QTimer::singleShot(first_frame_poll, this, [this, deadline] {
          awaitFrames(deadline);
        });
        return;
      }

      keyboard_.route(*tabs_[current_].front().window);
      const auto start = Clock::now();
      for (auto &pane : tabs_[1 - current_]) {
        const auto begin = Clock::now();
        retire(pane);
        windows_.push_back(Milliseconds(Clock::now() - begin).count());
      }

      retires_.push_back(Milliseconds(Clock::now() - start).count());
      ++done_;
      QTimer::singleShot(settle_delay, this, [this] {
        switchTab();
      });
    }

    void present(Pane &pane) {
      if (strategy_ == Strategy::hide) {
        pane.window->show();
        return;
      }

      pane.content->setVisible(true);
      if (!keep_mouse_) {
        window_hide_probe::setIgnoresMouse(*pane.window, false);
      }

      pane.window->setOpacity(1);
    }

    void retire(Pane &pane) {
      if (strategy_ == Strategy::hide) {
        pane.window->hide();
        return;
      }

      const auto start = Clock::now();
      pane.window->setOpacity(0);
      const auto transparent = Clock::now();
      if (!keep_mouse_) {
        window_hide_probe::setIgnoresMouse(*pane.window, true);
      }

      const auto ignoring = Clock::now();
      pane.content->setVisible(false);
      opacity_steps_.push_back(Milliseconds(transparent - start).count());
      mouse_steps_.push_back(Milliseconds(ignoring - transparent).count());
      content_steps_.push_back(Milliseconds(Clock::now() - ignoring).count());
    }

    // Runs once the switches are over, with the last tab presented.
    void check() {
      std::printf("%d tab switches of %zu windows\n", switches_, tabs_[current_].size());
      report("present", presents_);
      report("retire", retires_);
      report("window", windows_);
      if (strategy_ == Strategy::alpha) {
        report("opacity", opacity_steps_);
        report("mouse", mouse_steps_);
        report("content", content_steps_);
      }

      int misses = 0;
      for (auto &pane : tabs_[current_]) {
        const auto centre = pane.window->geometry().center();
        if (window_hide_probe::windowAt(centre) != window_hide_probe::windowNumber(*pane.window)) {
          ++misses;
        }
      }

      // Other applications' windows count too, so this is only meaningful on a quiet desktop.
      std::printf("  mouse downs at pane centres hitting another window: %d of %zu\n",
                  misses,
                  tabs_[current_].size());

      for (auto &tab : tabs_) {
        for (auto &pane : tab) {
          pane.frames = 0;
        }
      }

      QTimer::singleShot(render_window, this, [this] {
        finish();
      });
    }

    void finish() {
      const auto frames = [](const Tab &tab) {
        int total = 0;
        for (const auto &pane : tab) {
          total += pane.frames;
        }

        return total;
      };

      std::printf("  frames drawn in %llds: presented %d, retired %d\n",
                  static_cast<long long>(render_window.count()),
                  frames(tabs_[current_]),
                  frames(tabs_[1 - current_]));
      std::printf("  memory footprint %.1f MiB\n",
                  static_cast<double>(window_hide_probe::footprint()) / mebibyte);
      std::fflush(stdout);
      finished_ = true;
      if (!hold_) {
        QCoreApplication::quit();
      }
    }

    Strategy strategy_;
    int switches_;
    bool hold_;
    bool keep_mouse_;
    bool finished_ = false;
    int done_ = 0;
    int current_ = 0;
    // Declared before the windows, so it outlives them.
    workbench::KeyboardRouter keyboard_;
    std::array<Tab, tab_count> tabs_;
    std::vector<double> presents_;
    std::vector<double> retires_;
    std::vector<double> windows_;
    // Alpha's retire, step by step, including the second tab's initial retire.
    std::vector<double> opacity_steps_;
    std::vector<double> mouse_steps_;
    std::vector<double> content_steps_;
  };
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  QCommandLineParser parser;
  parser.setApplicationDescription("Measures switching between two tabs of pane windows.");
  parser.addHelpOption();
  const QCommandLineOption strategy_option(
      "strategy", "hide (default) or alpha.", "strategy", "hide");
  const QCommandLineOption windows_option(
      "windows", "Windows per tab, 1 to 32 (default 13).", "count", "13");
  const QCommandLineOption switches_option("switches", "Tab switches (default 40).", "count", "40");
  const QCommandLineOption hold_option("hold", "Keep the windows up after reporting.");
  const QCommandLineOption keep_mouse_option(
      "keep-mouse", "With alpha, leave mouse events enabled on outgoing windows.");
  parser.addOptions(
      {strategy_option, windows_option, switches_option, hold_option, keep_mouse_option});
  parser.process(application);

  const auto name = parser.value(strategy_option);
  bool windows_valid = false, switches_valid = false;
  const int windows = parser.value(windows_option).toInt(&windows_valid);
  const int switches = parser.value(switches_option).toInt(&switches_valid);
  if ((name != "hide" && name != "alpha") || !windows_valid || windows < 1 ||
      windows > maximum_windows || !switches_valid || switches < 1) {
    parser.showHelp(1);
  }

  std::printf("strategy %s\n", qPrintable(name));
  try {
    QQmlEngine engine;
    Bench bench(engine,
                name == "alpha" ? Strategy::alpha : Strategy::hide,
                windows,
                switches,
                parser.isSet(hold_option),
                parser.isSet(keep_mouse_option));
    bench.start();
    return application.exec();
  } catch (const std::exception &error) {
    std::fprintf(stderr, "window_hide_dbg: %s\n", error.what());
    return 1;
  }
}
