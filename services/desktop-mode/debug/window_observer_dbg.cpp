// Measures watching other applications' windows from a thread of its own, as the desktop's window
// observer will. The observer attaches Accessibility observers to every application with a Dock
// icon, on a thread with its own run loop, and records when each notification arrives.
//
// It reports how long attaching to each running application takes, then drives a helper
// application, this program with --serve, that creates, moves, focuses and closes windows and
// stamps each action with the system's uptime clock, and reports how long each notification takes
// to arrive. With the helper frozen it times attaching to it again, and compares reading a
// window's frame from the window server with reading it through Accessibility, alive and frozen.

#include "support/external_window_probe.hpp"
#include "support/samples.hpp"
#include "support/window_observer_probe.hpp"
#include <QColor>
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QPainter>
#include <QProcess>
#include <QRasterWindow>
#include <QSocketNotifier>
#include <QThread>
#include <QTimer>
#include <array>
#include <cstring>
#include <string>
#include <chrono>
#include <cstdio>
#include <memory>
#include <optional>
#include <stdexcept>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
  using Clock = std::chrono::steady_clock;
  using Milliseconds = std::chrono::duration<double, std::milli>;
  using window_observer_probe::Kind;

  constexpr auto helper_deadline = std::chrono::seconds{10};
  constexpr auto event_deadline = std::chrono::seconds{2};
  constexpr auto poll = std::chrono::milliseconds{1};
  constexpr auto pause = std::chrono::milliseconds{150};
  constexpr int reads = 200;
  constexpr int window_step = 40;
  constexpr QRect first_window{300, 300, 500, 350};

  class Swatch final : public QRasterWindow {
  protected:
    void paintEvent(QPaintEvent *) override {
      QPainter(this).fillRect(QRect(QPoint(), size()), QColor(90, 140, 110));
    }
  };

  void stamp(const char *what) {
    std::printf("%s %llu\n", what, static_cast<unsigned long long>(window_observer_probe::now()));
    std::fflush(stdout);
  }

  // The helper: windows created, moved, focused and closed on request, each stamped.
  int serve(QGuiApplication &application) {
    std::vector<std::unique_ptr<Swatch>> windows;
    QSocketNotifier input(STDIN_FILENO, QSocketNotifier::Read);
    QObject::connect(&input, &QSocketNotifier::activated, &application, [&] {
      std::array<char, 64> line{};
      const auto count = ::read(STDIN_FILENO, line.data(), line.size() - 1);
      int seconds = 0;
      if (count <= 0) {
        QCoreApplication::quit();
        return;
      }

      const std::string command(line.data());
      if (command.starts_with("create")) {
        auto window = std::make_unique<Swatch>();
        window->setGeometry(
            first_window.translated(window_step * static_cast<int>(windows.size()),
                                    window_step * static_cast<int>(windows.size())));
        stamp("created");
        window->show();
        windows.push_back(std::move(window));
      } else if (command.starts_with("move") && !windows.empty()) {
        stamp("moved");
        windows.back()->setPosition(windows.back()->position() + QPoint(window_step, 0));
      } else if (command.starts_with("focus") && windows.size() > 1) {
        stamp("focused");
        windows.front()->requestActivate();
        windows.front()->raise();
      } else if (command.starts_with("close") && !windows.empty()) {
        stamp("closed");
        windows.pop_back();
      } else if (std::sscanf(line.data(), "hang %d", &seconds) == 1) {
        stamp("hanging");
        QThread::sleep(seconds);
      }
    });

    QTimer::singleShot(0, &application, [] {
      stamp("ready");
    });
    return application.exec();
  }

  class Bench final {
  public:
    Bench()
        : observer_(timeout_) {}

    void attachEverything() {
      const auto pids = window_observer_probe::regularApplications();
      std::vector<double> times;
      int silent = 0;
      for (const auto &attachment : observer_.attach(pids)) {
        times.push_back(attachment.milliseconds);
        silent += !attachment.answered;
      }

      std::printf("attaching to %zu running applications\n", pids.size());
      samples::report("attach", times);
      std::printf("  applications that did not answer everything: %d\n", silent);
      observer_.take();
    }

    void start() {
      helper_.setProcessChannelMode(QProcess::ForwardedErrorChannel);
      helper_.start(QCoreApplication::applicationFilePath(), {QStringLiteral("--serve")});
      expect("ready");
      pid_ = static_cast<std::int64_t>(helper_.processId());
      observer_.attach({pid_});
    }

    void measure(int rounds) {
      std::vector<double> created, moved, focused, destroyed;
      int missed = 0;
      for (int round = 0; round < rounds; ++round) {
        auto at = command("create\n", "created");
        missed += !latency(Kind::created, at, created);
        std::this_thread::sleep_for(pause);
        at = command("create\n", "created");
        missed += !latency(Kind::created, at, created);
        std::this_thread::sleep_for(pause);
        at = command("move\n", "moved");
        missed += !latency(Kind::moved, at, moved);
        std::this_thread::sleep_for(pause);
        at = command("focus\n", "focused");
        missed += !latency(Kind::focused, at, focused);
        std::this_thread::sleep_for(pause);
        at = command("close\n", "closed");
        missed += !latency(Kind::destroyed, at, destroyed);
        std::this_thread::sleep_for(pause);
        at = command("close\n", "closed");
        missed += !latency(Kind::destroyed, at, destroyed);
        std::this_thread::sleep_for(pause);
      }

      std::printf("notification latency over %d rounds, from the helper's action\n", rounds);
      samples::report("created", created);
      samples::report("moved", moved);
      samples::report("focused", focused);
      samples::report("closed", destroyed);
      std::printf("  notifications that never arrived within %llds: %d\n",
                  static_cast<long long>(event_deadline.count()),
                  missed);
    }

    // Compares the two ways of reading a window's frame, then repeats them with the helper frozen,
    // together with attaching to it again.
    void readsAndHang(int seconds) {
      command("create\n", "created");
      std::this_thread::sleep_for(pause);
      auto windows = external_window_probe::windowsOf(pid_);
      if (windows.empty()) {
        throw std::runtime_error("The helper's window is not listed");
      }

      auto &window = windows.front();
      window.setTimeout(timeout_);
      compare(window, "alive");
      helper_.write(QByteArray("hang ") + QByteArray::number(seconds) + '\n');
      expect("hanging");
      compare(window, "frozen");
      const auto attached = observer_.attach({pid_}).front();
      std::printf("  attaching to the frozen application: %.1f ms, %s\n",
                  attached.milliseconds,
                  attached.answered ? "answered" : "did not answer");
      std::this_thread::sleep_for(std::chrono::seconds{seconds});
    }

    ~Bench() {
      helper_.closeWriteChannel();
      helper_.waitForFinished();
    }

  private:
    std::uint64_t expect(const char *what) {
      const auto deadline = Clock::now() + helper_deadline;
      while (Clock::now() < deadline) {
        while (helper_.canReadLine()) {
          const auto line = helper_.readLine();
          if (line.startsWith(what)) {
            return line.mid(static_cast<qsizetype>(std::strlen(what)) + 1).trimmed().toULongLong();
          }
        }

        helper_.waitForReadyRead(100);
      }

      throw std::runtime_error(std::string("The helper did not report ") + what);
    }

    std::uint64_t command(const char *text, const char *reply) {
      observer_.take();
      helper_.write(text);
      helper_.waitForBytesWritten();
      return expect(reply);
    }

    bool latency(Kind kind, std::uint64_t at, std::vector<double> &into) {
      const auto deadline = Clock::now() + event_deadline;
      while (Clock::now() < deadline) {
        for (const auto &event : observer_.take()) {
          if (event.kind == kind && event.pid == pid_) {
            into.push_back(static_cast<double>(event.at - at) / 1e6);
            return true;
          }
        }

        std::this_thread::sleep_for(poll);
      }

      return false;
    }

    void compare(external_window_probe::Window &window, const char *state) {
      std::vector<double> server, accessibility;
      for (int index = 0; index < reads; ++index) {
        auto begin = Clock::now();
        window_observer_probe::serverBounds(window.id());
        server.push_back(Milliseconds(Clock::now() - begin).count());
        if (index < reads / 20) {
          begin = Clock::now();
          window.frame();
          accessibility.push_back(Milliseconds(Clock::now() - begin).count());
        }
      }

      std::printf("reading a window's frame, application %s\n", state);
      samples::report("server", server);
      samples::report("ax", accessibility);
    }

    double timeout_ = 0.05;
    window_observer_probe::Observer observer_;
    QProcess helper_;
    std::int64_t pid_ = 0;
  };
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  QCommandLineParser parser;
  parser.setApplicationDescription("Measures watching other applications' windows.");
  parser.addHelpOption();
  const QCommandLineOption serve_option("serve", "Run as the helper application.");
  const QCommandLineOption rounds_option("rounds",
                                         "Rounds of window actions (default 10).",
                                         "count",
                                         "10");
  const QCommandLineOption hang_option("hang",
                                       "Seconds to freeze the helper (default 2).",
                                       "seconds",
                                       "2");
  parser.addOptions({serve_option, rounds_option, hang_option});
  parser.process(application);

  if (parser.isSet(serve_option)) {
    return serve(application);
  }

  if (!external_window_probe::trusted()) {
    std::fprintf(stderr, "window_observer_dbg: grant Accessibility to the terminal that runs it\n");
    return 1;
  }

  try {
    Bench bench;
    bench.attachEverything();
    bench.start();
    bench.measure(std::max(1, parser.value(rounds_option).toInt()));
    bench.readsAndHang(std::max(1, parser.value(hang_option).toInt()));
  } catch (const std::exception &error) {
    std::fprintf(stderr, "window_observer_dbg: %s\n", error.what());
    return 1;
  }

  return 0;
}
