#pragma once

#include "machines/connection_policy.hpp"
#include "machines/discovery.hpp"
#include "machines/failure.hpp"
#include "machines/field_rules.hpp"
#include "machines/remote_command.hpp"
#include "platform/file_descriptor.hpp"
#include "platform/managed_directory.hpp"
#include "platform/path_limits.hpp"
#include "platform/stdio_socket.hpp"
#include "ssh_options.hpp"
#include "transport/runtime_protocol.hpp"
#include <QByteArray>
#include <QFutureWatcher>
#include <QIODevice>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QtConcurrent/QtConcurrentRun>
#include <array>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <string_view>
#include <utility>

namespace telar::gui::qt {

using RemoteDiscovery = MachineDiscovery<platform::PathLimits::path_bytes>;

struct RemoteTarget {
  QString destination;
  QString program;
  QString local_endpoint;
  bool prepare_directory = false;
};

struct NativeSshHost {
  static constexpr auto discovery_timeout = std::chrono::seconds{30};

  static void start(QProcess &process, const QStringList &arguments) {
    process.start(QStringLiteral("ssh"), arguments, QIODevice::ReadWrite);
  }
};

template <typename Host>
concept SshHost = requires(QProcess &process, const QStringList &arguments) {
  { Host::start(process, arguments) } -> std::same_as<void>;
};

template <typename Observer>
concept RemoteBridgeObserver = requires(Observer &observer, const RemoteDiscovery &discovery, runtime::FileDescriptor channel, MachineError error, std::string_view detail) {
  { observer.remoteDiscovered(discovery) } -> std::same_as<void>;
  { observer.remoteChannelReady(std::move(channel)) } -> std::same_as<void>;
  { observer.remoteFailed(error, detail) } -> std::same_as<void>;
};

template <SshHost Host, typename Observer>
class RemoteBridge final {
public:
  static constexpr auto discovery_timeout = Host::discovery_timeout;
  static constexpr qsizetype error_limit = qsizetype{16} * 1024;
  static constexpr std::size_t read_chunk_bytes = 8192;

  explicit RemoteBridge(Observer &observer)
      : observer_(observer) {
    static_assert(RemoteBridgeObserver<Observer>);
    deadline_.setSingleShot(true);
    QObject::connect(&deadline_, &QTimer::timeout, &context_, [this] {
      fail(MachineError::endpoint_unavailable);
    });
    QObject::connect(&options_task_, &QFutureWatcher<OptionsResult>::finished, &context_, [this] {
      optionsPrepared();
    });
    QObject::connect(&process_, &QProcess::readyReadStandardOutput, &context_, [this] {
      drain(QProcess::StandardOutput);
    });
    QObject::connect(&process_, &QProcess::readyReadStandardError, &context_, [this] {
      drain(QProcess::StandardError);
    });
    QObject::connect(&process_, &QProcess::started, &context_, [this] {
      if (running_ && phase_ == Phase::bridge) {
        sockets_.child.reset();
        observer_.remoteChannelReady(std::move(sockets_.local));
      }
    });
    QObject::connect(&process_, &QProcess::errorOccurred, &context_, [this](QProcess::ProcessError error) {
      if (running_ && error != QProcess::Crashed) {
        fail(MachineError::endpoint_unavailable);
      }
    });
    QObject::connect(&process_, &QProcess::finished, &context_, [this](int status, QProcess::ExitStatus outcome) {
      finished(status, outcome);
    });
  }

  ~RemoteBridge() {
    process_.disconnect(&context_);
    options_task_.disconnect(&context_);
    close();
    if (process_.state() != QProcess::NotRunning) {
      constexpr int shutdown_timeout_ms = 1000;
      static_cast<void>(process_.waitForFinished(shutdown_timeout_ms));
    }
  }

  RemoteBridge(const RemoteBridge &) = delete;
  RemoteBridge &operator=(const RemoteBridge &) = delete;
  RemoteBridge(RemoteBridge &&) = delete;
  RemoteBridge &operator=(RemoteBridge &&) = delete;

  void open(RemoteTarget target) {
    const auto destination = target.destination.toUtf8();
    MachineFieldRules::profileDestination(view(destination));
    const auto program = target.program.toUtf8();
    if (!program.isEmpty()) {
      MachineFieldRules::program(view(program));
    }

    close();
    target_ = std::move(target);
    closed_ = false;
    waiting_ = true;
    resume();
  }

  void close() {
    closed_ = true;
    running_ = false;
    waiting_ = false;
    ++generation_;
    deadline_.stop();
    sockets_ = {};
    discovery_.reset();
    output_.clear();
    errors_.clear();
    options_.clear();
    program_bytes_.clear();
    if (process_.state() != QProcess::NotRunning) {
      process_.kill();
    }
  }

  [[nodiscard]] bool active() const noexcept {
    return !closed_;
  }

private:
  enum class Phase : std::uint8_t {
    discovery,
    bridge,
  };

  struct OptionsResult {
    QStringList arguments;
    std::optional<MachineError> error = std::nullopt;
    std::uint64_t generation = 0;
  };

  [[nodiscard]] static std::string_view view(const QByteArray &bytes) noexcept {
    return {bytes.constData(), static_cast<std::size_t>(bytes.size())};
  }

  void resume() {
    if (closed_ || !waiting_ || options_task_.isRunning() || process_.state() != QProcess::NotRunning) {
      return;
    }

    waiting_ = false;
    const auto request = target_;
    const auto generation = generation_;
    options_task_.setFuture(QtConcurrent::run([request, generation] {
      OptionsResult result{.arguments = {}, .generation = generation};
      try {
        if (request.prepare_directory) {
          const auto endpoint = request.local_endpoint.toUtf8();
          const auto directory = view(endpoint).substr(0, view(endpoint).rfind('/'));
          platform::prepareManagedDirectory(directory);
        }

        result.arguments = SshOptions::prepare(request.local_endpoint, request.destination.toUtf8());
      } catch (const MachineFailure &failure) {
        result.error = failure.code();
      } catch (...) {
        result.error = MachineError::invalid_runtime_directory;
      }

      return result;
    }));
  }

  void optionsPrepared() {
    if (closed_) {
      return;
    }

    const auto result = options_task_.result();
    if (result.generation != generation_) {
      resume();

      return;
    }

    if (result.error) {
      fail(*result.error);

      return;
    }

    options_ = result.arguments;
    phase_ = Phase::discovery;
    output_.clear();
    errors_.clear();
    process_.setChildProcessModifier({});
    process_.setProcessChannelMode(QProcess::SeparateChannels);
    process_.setInputChannelMode(QProcess::ManagedInputChannel);
    process_.setStandardInputFile(QProcess::nullDevice());
    deadline_.start(discovery_timeout);
    launch(MachineRemoteCommand::discovery(program()).view());
  }

  [[nodiscard]] std::optional<std::string_view> program() {
    program_bytes_ = target_.program.toUtf8();

    return program_bytes_.isEmpty() ? std::nullopt : std::optional{view(program_bytes_)};
  }

  void launch(std::string_view command) {
    auto arguments = options_;
    arguments.prepend(QStringLiteral("-T"));
    arguments.append(QStringLiteral("--"));
    arguments.append(target_.destination);
    arguments.append(QString::fromUtf8(command.data(), static_cast<qsizetype>(command.size())));
    running_ = true;
    try {
      Host::start(process_, arguments);
    } catch (const std::exception &) {
      fail(MachineError::endpoint_unavailable);
    }
  }

  void drain(QProcess::ProcessChannel channel) {
    process_.setReadChannel(channel);
    std::array<char, read_chunk_bytes> chunk{};
    while (process_.bytesAvailable() > 0) {
      const auto received = process_.read(chunk.data(), static_cast<qint64>(chunk.size()));
      if (received <= 0) {
        return;
      }

      if (!running_) {
        continue;
      }

      if (channel == QProcess::StandardError) {
        errors_.append(chunk.data(), static_cast<qsizetype>(received));
        if (errors_.size() > error_limit) {
          errors_.remove(0, errors_.size() - error_limit);
        }
      } else if (phase_ == Phase::discovery) {
        if (std::cmp_greater(output_.size() + received, RemoteDiscovery::max_output_bytes)) {
          fail(MachineError::discovery_unreadable);

          return;
        }

        output_.append(chunk.data(), static_cast<qsizetype>(received));
      }
    }
  }

  void finished(int status, QProcess::ExitStatus outcome) {
    drain(QProcess::StandardOutput);
    drain(QProcess::StandardError);
    if (!running_) {
      resume();

      return;
    }

    running_ = false;
    deadline_.stop();
    if (phase_ == Phase::bridge || outcome != QProcess::NormalExit || status != 0) {
      constexpr int maximum_exit_status = 255;
      const auto exited = outcome == QProcess::NormalExit && status >= 0 && status <= maximum_exit_status;
      fail(MachineConnectionPolicy::failure({.exit_status = exited ? std::optional{static_cast<std::uint8_t>(status)} : std::nullopt, .standard_error = view(errors_)}));

      return;
    }

    try {
      discovery_ = RemoteDiscovery::parse(view(output_));
      if (!RuntimeProtocol::supports(discovery_->schema())) {
        fail(MachineError::remote_program_incompatible);

        return;
      }

      const auto generation = generation_;
      observer_.remoteDiscovered(*discovery_);
      if (closed_ || generation != generation_) {
        return;
      }

      QTimer::singleShot(std::chrono::milliseconds{0}, &context_, [this, generation] {
        if (!closed_ && generation == generation_) {
          startBridge();
        }
      });
    } catch (const MachineFailure &failure) {
      fail(failure.code());
    } catch (const std::exception &) {
      fail(MachineError::endpoint_unavailable);
    }
  }

  void startBridge() {
    try {
      sockets_ = platform::openStdioSocket();
      phase_ = Phase::bridge;
      errors_.clear();
      process_.setStandardInputFile({});
      process_.setInputChannelMode(QProcess::ForwardedInputChannel);
      process_.setProcessChannelMode(QProcess::ForwardedOutputChannel);
      const auto descriptor = sockets_.child.get();
      process_.setChildProcessModifier([this, descriptor] {
        const auto error = platform::bindStandardIo(descriptor);
        if (error != 0) {
          process_.failChildProcessModifier("Bind SSH bridge standard input/output", error);
        }
      });
      launch(MachineRemoteCommand::bridge(program()).view());
    } catch (const std::exception &) {
      fail(MachineError::endpoint_unavailable);
    }
  }

  void fail(MachineError error) {
    if (closed_) {
      return;
    }

    closed_ = true;
    running_ = false;
    deadline_.stop();
    sockets_ = {};
    if (process_.state() != QProcess::NotRunning) {
      process_.kill();
    }

    observer_.remoteFailed(error, {errors_.constData(), static_cast<std::size_t>(errors_.size())});
  }

  Observer &observer_;
  QObject context_;
  QProcess process_;
  QTimer deadline_;
  QFutureWatcher<OptionsResult> options_task_;
  RemoteTarget target_;
  QStringList options_;
  QByteArray output_;
  QByteArray errors_;
  QByteArray program_bytes_;
  std::optional<RemoteDiscovery> discovery_;
  platform::StdioSocket sockets_;
  std::uint64_t generation_ = 0;
  Phase phase_ = Phase::discovery;
  bool running_ = false;
  bool closed_ = true;
  bool waiting_ = false;
};

}
