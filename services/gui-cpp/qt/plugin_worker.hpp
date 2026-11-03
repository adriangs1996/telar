#pragma once

#include "application/dependencies.hpp"
#include "command_process.hpp"
#include "config/plugin_effects.hpp"
#include "config/plugin_invocation.hpp"
#include "core/memory.hpp"
#include "plugin_packages.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_platform/temporary_directory.hpp"
#include "telar_plugins/package_copy_storage.hpp"
#include "telar_plugins/package_inspection.hpp"
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
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace telar::gui::qt {

struct PluginWorkerCommand {
  QString program;
  QString entry;
  QString action;
  BindingContext context;
};

struct NativePluginWorkerHost {
  static constexpr auto timeout = std::chrono::seconds{2};
  static constexpr std::size_t stdout_limit = PluginEffects::maximum_bytes;

  static void start(QProcess &process, const PluginWorkerCommand &command) {
    process.setProcessEnvironment(QProcessEnvironment{});
    process.setWorkingDirectory(QStringLiteral("/"));
    process.setUnixProcessParameters(QProcess::UnixProcessFlag::CloseFileDescriptors | QProcess::UnixProcessFlag::ResetSignalHandlers);
    process.start(command.program,
                  {QStringLiteral("plugin-worker"), command.entry, command.action, QString::number(static_cast<int>(command.context.sidebar_visible)), QString::number(command.context.tab_count), QString::number(command.context.active_tab_index), QString::number(command.context.pane_count), QString::number(command.context.focused_pane_id)},
                  QIODevice::ReadOnly);
  }
};

struct PluginWorkerSnapshot {
  explicit PluginWorkerSnapshot(ApplicationAllocator &memory, const PluginInvocation &invocation, const QString &program) {
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

using PreparedPluginWorker = Owned<PluginWorkerSnapshot, ApplicationAllocator>;

struct PluginWorkerPreparation {
  explicit PluginWorkerPreparation(ApplicationAllocator &memory)
      : snapshot(nullptr, runtime::AllocationDeleter<PluginWorkerSnapshot, ApplicationAllocator>{memory}) {}

  PreparedPluginWorker snapshot;
  QString error;
};

struct PluginWorkerResult {
  std::optional<PluginEffects> effects;
  QString error;
};

template <typename Observer>
class PluginWorker final {
public:
  explicit PluginWorker(ApplicationAllocator &memory, Observer &observer)
      : memory_(memory),
        observer_(observer),
        snapshot_(nullptr, runtime::AllocationDeleter<PluginWorkerSnapshot, ApplicationAllocator>{memory}),
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
      } catch (const std::exception &error) {
        qWarning() << "Plugin worker preparation failed during shutdown:" << error.what();
      }
    }
  }

  PluginWorker(const PluginWorker &) = delete;
  PluginWorker &operator=(const PluginWorker &) = delete;
  PluginWorker(PluginWorker &&) = delete;
  PluginWorker &operator=(PluginWorker &&) = delete;

  [[nodiscard]] bool active() const noexcept {
    return invocation_.has_value();
  }

  void start(const PluginInvocation &invocation, std::uint64_t execution, const QString &program) {
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
      preparation_.setFuture(QtConcurrent::run([&memory = memory_, invocation, executable] {
        PluginWorkerPreparation result{memory};
        try {
          result.snapshot = makeOwned<PluginWorkerSnapshot>(memory, memory, invocation, executable);
        } catch (const std::exception &error) {
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
    std::memcpy(output_.data() + output_length_, bytes.data(), bytes.size());
    output_length_ += bytes.size();
  }

  void commandFinished(std::optional<CommandFailure> failure) {
    PluginWorkerResult result;
    if (failure) {
      result.error = *failure == CommandFailure::timeout ? QStringLiteral("PluginWorkerTimedOut") : QStringLiteral("PluginWorkerFailed");
    } else {
      try {
        result.effects = PluginEffects::decode(std::span{output_}.first(output_length_));
      } catch (const std::exception &error) {
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
        deliver({.effects = std::nullopt, .error = prepared.error});

        return;
      }

      snapshot_ = std::move(prepared.snapshot);
      process_.start(snapshot_->command);
    } catch (const std::exception &error) {
      deliver({.effects = std::nullopt, .error = QString::fromUtf8(error.what())});
    }
  }

  void deliver(const PluginWorkerResult &result) {
    auto invocation = std::exchange(invocation_, std::nullopt);
    const auto execution = std::exchange(execution_, 0);
    snapshot_.reset();
    if (invocation) {
      observer_.pluginWorkerFinished(execution, *invocation, result);
    }
  }

  ApplicationAllocator &memory_;
  Observer &observer_;
  QFutureWatcher<PluginWorkerPreparation> preparation_;
  PreparedPluginWorker snapshot_;
  std::optional<PluginInvocation> invocation_;
  std::array<Byte, PluginEffects::maximum_bytes> output_{};
  std::size_t output_length_ = 0;
  std::uint64_t execution_ = 0;
  CommandProcess<NativePluginWorkerHost, PluginWorkerCommand, PluginWorker> process_;
  QObject context_;
};

}
