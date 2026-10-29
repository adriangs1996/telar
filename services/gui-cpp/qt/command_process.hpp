#pragma once

#include <QIODevice>
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <array>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <stdexcept>
#include <utility>

namespace telar::gui::qt {

enum class CommandFailure : std::uint8_t {
  launch,
  process,
  timeout,
  output_limit,
};

template <typename Host, typename Request>
concept CommandHost = requires(QProcess &process, const Request &request) {
  { Host::start(process, request) } -> std::same_as<void>;
  { Host::timeout } -> std::convertible_to<std::chrono::milliseconds>;
};

template <typename Observer>
concept CommandObserver = requires(Observer &observer, std::optional<CommandFailure> failure) {
  { observer.commandFinished(failure) } -> std::same_as<void>;
};

template <typename Host, typename Request, typename Observer>
  requires CommandHost<Host, Request>
class CommandProcess final {
public:
  static constexpr std::size_t output_limit = 4096;

  explicit CommandProcess(Observer &observer)
      : observer_(observer) {
    static_assert(CommandObserver<Observer>);

    deadline_.setSingleShot(true);
    deadline_.setTimerType(Qt::PreciseTimer);
    QObject::connect(&deadline_, &QTimer::timeout, &context_, [this] {
      if (running_) {
        failure_ = CommandFailure::timeout;
        process_.kill();
      }
    });
    QObject::connect(&process_, &QProcess::readyReadStandardOutput, &context_, [this] {
      drain(QProcess::StandardOutput);
    });
    QObject::connect(&process_, &QProcess::readyReadStandardError, &context_, [this] {
      drain(QProcess::StandardError);
    });
    QObject::connect(&process_, &QProcess::finished, &context_, [this](int exit_code, QProcess::ExitStatus status) {
      if (!running_) {
        return;
      }

      if (!failure_ && (exit_code != 0 || status != QProcess::NormalExit)) {
        failure_ = CommandFailure::process;
      }

      finish();
    });
    QObject::connect(&process_, &QProcess::errorOccurred, &context_, [this](QProcess::ProcessError error) {
      if (!running_) {
        return;
      }

      if (!failure_) {
        failure_ = error == QProcess::FailedToStart ? CommandFailure::launch : CommandFailure::process;
      }

      if (error == QProcess::FailedToStart) {
        finish();
      } else if (process_.state() != QProcess::NotRunning) {
        process_.kill();
      }
    });
  }

  ~CommandProcess() {
    process_.disconnect(&context_);
    shutdown();
    if (process_.state() != QProcess::NotRunning) {
      constexpr auto shutdown_timeout = std::chrono::milliseconds{1000};
      static_cast<void>(process_.waitForFinished(static_cast<int>(shutdown_timeout.count())));
    }
  }

  CommandProcess(const CommandProcess &) = delete;
  CommandProcess &operator=(const CommandProcess &) = delete;
  CommandProcess(CommandProcess &&) = delete;
  CommandProcess &operator=(CommandProcess &&) = delete;

  [[nodiscard]] bool active() const noexcept {
    return pending_ || running_;
  }

  void start(const Request &request) {
    if (active() || stopping_) {
      throw std::logic_error{"CommandProcessUnavailable"};
    }

    pending_ = true;
    try {
      QTimer::singleShot(std::chrono::milliseconds{0}, &context_, [this, request] {
        pending_ = false;
        if (!stopping_) {
          launch(request);
        }
      });
    } catch (...) {
      pending_ = false;
      throw;
    }
  }

  void shutdown() {
    stopping_ = true;
    deadline_.stop();
    if (process_.state() != QProcess::NotRunning) {
      process_.kill();
    }
  }

private:
  void launch(const Request &request) {
    running_ = true;
    output_bytes_.fill(0);
    failure_.reset();
    deadline_.start(Host::timeout);
    try {
      Host::start(process_, request);
    } catch (const std::exception &) {
      failure_ = CommandFailure::launch;
      if (process_.state() == QProcess::NotRunning) {
        finish();
      } else {
        process_.kill();
      }
    }
  }

  void drain(QProcess::ProcessChannel channel) {
    if (failure_ == CommandFailure::output_limit) {
      return;
    }

    auto &total = output_bytes_[channel == QProcess::StandardOutput ? 0 : 1];
    process_.setReadChannel(channel);
    std::array<char, output_limit + 1> buffer{};
    while (process_.bytesAvailable() > 0) {
      const auto count = process_.read(buffer.data(), static_cast<qint64>(buffer.size()));
      if (count <= 0) {
        break;
      }

      total += static_cast<std::size_t>(count);
      if (total > output_limit) {
        failure_ = CommandFailure::output_limit;
        process_.kill();

        return;
      }
    }
  }

  void finish() {
    if (!running_) {
      return;
    }

    running_ = false;
    deadline_.stop();
    drain(QProcess::StandardOutput);
    drain(QProcess::StandardError);
    observer_.commandFinished(std::exchange(failure_, std::nullopt));
  }

  Observer &observer_;
  QProcess process_;
  QTimer deadline_;
  std::array<std::size_t, 2> output_bytes_{};
  std::optional<CommandFailure> failure_;
  bool running_ = false;
  bool pending_ = false;
  bool stopping_ = false;
  QObject context_;
};

}
