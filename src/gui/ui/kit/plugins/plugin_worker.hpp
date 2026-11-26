#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_platform/open_directory.h"
#include "ui/kit/config/plugin_packages.hpp"
#include "ui/kit/process/command_process.hpp"
#include <QDebug>
#include <QFuture>
#include <QFutureWatcher>
#include <QProcess>
#include <QProcessEnvironment>
#include <QStandardPaths>
#include <QString>
#include <QStringList>
#include <QtConcurrentRun>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <bit>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <dirent.h>
#include <exception>
#include <fcntl.h>
#include <limits.h>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <sys/stat.h>
#include <tuple>
#include <unistd.h>
#include <utility>
#include <variant>

#pragma once

#include "tbc/view.hpp"

import telar.platform.fs;
import telar.plugins;
import telar.gui.foundation.actions;
import telar.config.client;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui::qt {

  struct PluginWorkerCommand {
    QString program;
    QString entry;
    QString action;
    BindingContext context;
  };

  struct NativePluginWorkerHost {
    static constexpr auto timeout = std::chrono::seconds{2};
    static constexpr std::size_t stdout_limit = application::plugins::PluginEffects::maximum_bytes;

    static void start(QProcess& process, const PluginWorkerCommand& command) {
      process.setProcessEnvironment(QProcessEnvironment{});
      process.setWorkingDirectory(QStringLiteral("/"));
      process.setUnixProcessParameters(QProcess::UnixProcessFlag::CloseFileDescriptors | QProcess::UnixProcessFlag::ResetSignalHandlers);
      const auto entry = command.entry.toUtf8();
      const auto action = command.action.toUtf8();
      const runtime::config::PluginWorkerOptions options{.entry = entry.constData(), .action = action.constData(), .context = command.context};
      constexpr auto worker_command = runtime::config::PluginWorkerOptions::command;
      QStringList arguments{QString::fromUtf8(worker_command.data(), static_cast<qsizetype>(worker_command.size()))};

      options.eachArgument([&](std::string_view word) {
        arguments.append(QString::fromUtf8(word.data(), static_cast<qsizetype>(word.size())));
      });

      process.start(command.program, arguments, QIODevice::ReadOnly);
    }
  };

  struct PluginWorkerSnapshot {
    explicit PluginWorkerSnapshot(ApplicationAllocator& memory, const application::plugins::PluginInvocation& invocation, const QString& program) {
      using Inspector = runtime::plugins::PackageInspection<PluginPackageHash>;
      const auto copied = runtime::plugins::PackageCopyStorage<ApplicationAllocator, Inspector>{memory}.copy(invocation.package, directory.descriptor(), directory.path());

      command = {.program = program, .entry = text(directory.path()) + QStringLiteral("/") + text(copied.manifest.entry.view()), .action = text(invocation.action.view()), .context = invocation.context};
    }

    runtime::TemporaryDirectory directory{"/tmp/telar-gui-plugin-worker-XXXXXX"};
    PluginWorkerCommand command;

  private:
    static QString text(std::string_view value) {
      return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
    }
  };

  using PreparedPluginWorker = ds::Box<PluginWorkerSnapshot, ApplicationAllocator>;

  struct PluginWorkerPreparation {
    PreparedPluginWorker snapshot;
    QString error;
  };

  struct PluginWorkerResult {
    ds::Option<application::plugins::PluginEffects> effects;
    QString error;
  };

  template <typename Observer>
  class PluginWorker final {
  public:
    explicit PluginWorker(ApplicationAllocator& memory, Observer& observer)
        : memory_(memory),
          observer_(observer),
          process_(*this) {
      QObject::connect(&preparation_, &QFutureWatcher<PluginWorkerPreparation>::finished, &context_, [this] {
        snapshotReady();
      });
    }

    ~PluginWorker() {
      preparation_.disconnect(&context_);
      process_.shutdown();
      auto future = preparation_.future();
      if (future.isValid()) {
        try {
          future.waitForFinished();
          if (future.resultCount() != 0) {
            static_cast<void>(future.takeResult());
          }
        } catch (const std::exception& error) {
          qWarning() << "Plugin worker preparation failed during shutdown:" << error.what();
        }
      }
    }

    PluginWorker(const PluginWorker&) = delete;
    PluginWorker& operator=(const PluginWorker&) = delete;
    PluginWorker(PluginWorker&&) = delete;
    PluginWorker& operator=(PluginWorker&&) = delete;

    [[nodiscard]] bool active() const noexcept {
      return invocation_.hasValue();
    }

    void start(const application::plugins::PluginInvocation& invocation, std::uint64_t execution, const QString& program) {
      if (active()) {
        throw std::runtime_error{"PluginWorkerBusy"};
      }

      const auto executable = QStandardPaths::findExecutable(program);
      if (executable.isEmpty()) {
        throw std::runtime_error{"PluginWorkerUnavailable"};
      }

      invocation_ = invocation;
      execution_ = execution;
      output_length_ = 0;
      try {
        preparation_.setFuture(QtConcurrent::run([&memory = memory_, invocation, executable] -> PluginWorkerPreparation {
          PluginWorkerPreparation result{};

          try {
            result.snapshot = ds::makeBox<PluginWorkerSnapshot>(memory, memory, invocation, executable);
          } catch (const std::exception& error) {
            result.error = QString::fromUtf8(error.what());
          }

          return result;
        }));
      } catch (...) {
        invocation_.reset();
        throw;
      }
    }

    void commandOutput(std::span<const char> bytes) noexcept {
      std::ranges::copy(bytes, output_.viewMut().subspan(output_length_, bytes.size()).begin());
      output_length_ += bytes.size();
    }

    void commandFinished(ds::Option<CommandFailure> failure) {
      PluginWorkerResult result;

      if (failure) {
        result.error = *failure == CommandFailure::timeout ? QStringLiteral("PluginWorkerTimedOut") : QStringLiteral("PluginWorkerFailed");
      } else {
        try {
          result.effects = application::plugins::PluginEffects::decode(std::span{output_}.first(output_length_));
        } catch (const std::exception& error) {
          result.error = QString::fromUtf8(error.what());
        }
      }

      deliver(result);
    }

  private:
    void snapshotReady() {
      try {
        auto prepared = preparation_.future().takeResult();
        if (!prepared.error.isEmpty()) {
          deliver({.effects = ds::none, .error = prepared.error});

          return;
        }

        snapshot_ = std::move(prepared.snapshot);
        process_.start(snapshot_->command);
      } catch (const std::exception& error) {
        deliver({.effects = ds::none, .error = QString::fromUtf8(error.what())});
      }
    }

    void deliver(const PluginWorkerResult& result) {
      const auto invocation = std::exchange(invocation_, ds::none);
      const auto execution = std::exchange(execution_, 0);

      snapshot_.reset();
      if (invocation) {
        observer_.pluginWorkerFinished(execution, *invocation, result);
      }
    }

    ApplicationAllocator& memory_;
    Observer& observer_;
    QFutureWatcher<PluginWorkerPreparation> preparation_;
    PreparedPluginWorker snapshot_;
    ds::Option<application::plugins::PluginInvocation> invocation_;
    ds::Array<Byte, application::plugins::PluginEffects::maximum_bytes> output_{};
    std::size_t output_length_ = 0;
    std::uint64_t execution_ = 0;
    // The process reports back to this worker.
    tbc::val_self<CommandProcess<NativePluginWorkerHost, PluginWorkerCommand, PluginWorker>> process_;
    QObject context_;
  };

}
