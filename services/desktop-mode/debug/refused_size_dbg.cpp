// Checks that the desktop's window observer learns the size an application keeps when it
// refuses a smaller one. It puts a running application's first window on a Space of its own,
// asks for --width points of width, and waits for the observer to report the minimum. The
// window gets its frame back and returns to its desktop at the end.

#include "native-backends/macos/spaces_bridge.hpp"
#include "native-backends/macos/virtual_spaces.hpp"
#include "ui/workbench/native.hpp"
#include <QCommandLineParser>
#include <QGuiApplication>
#include <chrono>
#include <cstdio>
#include <exception>
#include <optional>

namespace {
  using Clock = std::chrono::steady_clock;
  using workbench::native::ForeignWindow;
  using workbench::native::ForeignWindows;

  constexpr auto deadline = std::chrono::seconds{5};

  // Waits for a delivery after `after` with a window meeting the condition, so a frame read before
  // a write never answers for it.
  std::optional<ForeignWindow>
  await(const ForeignWindows &current, const int &deliveries, int after, auto condition) {
    const auto start = Clock::now();
    while (Clock::now() - start < deadline) {
      QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
      if (deliveries <= after) {
        continue;
      }

      for (const auto &window : current.windows) {
        if (condition(window)) {
          return window;
        }
      }
    }

    return std::nullopt;
  }

  int run(const QString &application, double width) {
    ForeignWindows current;
    int deliveries = 0;
    workbench::native::WindowObserver observer(*qApp, [&](ForeignWindows next) {
      current = std::move(next);
      ++deliveries;
    });

    const auto found = await(current, deliveries, 0, [&](const ForeignWindow &window) {
      return window.application == application && !window.floating;
    });

    if (!found) {
      std::printf("no window of %s\n", qPrintable(application));
      return 1;
    }

    auto &spaces = macos::spaces::VirtualSpaces::get();
    auto state = macos::spaces::snapshot();
    spaces.prepare();
    const auto space = spaces.create(state.displays.front().id);
    spaces.overlay(state);

    const auto original = found->frame;
    std::printf("window %u at %.0fx%.0f; asking for %.0f points of width\n",
                found->id,
                original.width(),
                original.height(),
                width);
    auto written = deliveries;
    observer.place(found->id, space, {original.topLeft(), QSizeF(width, original.height())});

    const auto learned = await(current, deliveries, written, [&](const ForeignWindow &window) {
      return window.id == found->id && !window.minimum.isNull();
    });

    if (learned) {
      std::printf("  learned minimum %.0f x %.0f; the window is %.0f x %.0f\n",
                  learned->minimum.width(),
                  learned->minimum.height(),
                  learned->frame.width(),
                  learned->frame.height());
    } else {
      std::printf("  no minimum learned: the application accepted the size or did not answer\n");
    }

    written = deliveries;
    observer.place(found->id, space, original);
    const auto restored = await(current, deliveries, written, [&](const ForeignWindow &window) {
      return window.id == found->id && window.frame.size() == original.size();
    });

    if (!restored) {
      std::printf("  the window did not get its frame back\n");
    }

    spaces.release();
    return learned ? 0 : 1;
  }
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  QCommandLineParser parser;
  parser.addHelpOption();
  const QCommandLineOption app_option(
      "app", "The bundle identifier of a running application.", "id", "com.spotify.client");
  const QCommandLineOption width_option("width", "The width to ask for.", "points", "440");
  parser.addOptions({app_option, width_option});
  parser.process(application);

  try {
    return run(parser.value(app_option), parser.value(width_option).toDouble());
  } catch (const std::exception &failure) {
    std::printf("failed: %s\n", failure.what());
    macos::spaces::VirtualSpaces::get().release();
    return 1;
  }
}
