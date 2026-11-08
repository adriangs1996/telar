#pragma once

#include "tbc/view.hpp"
#include <QByteArray>
#include <QList>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QTimer>
#include <QtCore/qtypes.h>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>

namespace telar::gui::qt {

enum class SurfaceCommandFailure : std::uint8_t {
  launch,
  process,
  timeout,
  cancelled,
  invalid_output,
};

enum class SurfaceOutputUse : std::uint8_t {
  line,
  lines,
  options,
  ignored,
};

struct SurfaceCommandRequest {
  static constexpr std::size_t bar_output_bytes = std::size_t{64} * 1024;
  static constexpr std::size_t pick_output_bytes = std::size_t{256} * 1024;
  static constexpr std::chrono::milliseconds default_timeout{2000};
  QList<QByteArray> arguments;
  QString directory;
  std::chrono::milliseconds timeout = default_timeout;
  static constexpr std::size_t line_output_bytes = 4096;
  SurfaceOutputUse output = SurfaceOutputUse::lines;
};

struct SurfaceCommandResult {
  QByteArray output;
  std::optional<SurfaceCommandFailure> failure = std::nullopt;
  bool truncated = false;
  int exit_code = -1;
  std::size_t observed_bytes = 0;
};

class SurfaceCommand {
public:
  using Completion = std::function<void(SurfaceCommandResult)>;
  SurfaceCommand();
  ~SurfaceCommand();
  SurfaceCommand(const SurfaceCommand &) = delete;
  SurfaceCommand &operator=(const SurfaceCommand &) = delete;
  SurfaceCommand(SurfaceCommand &&) = delete;
  SurfaceCommand &operator=(SurfaceCommand &&) = delete;
  // The command keeps the completion, and what it captures, region `a`, until it runs.
  void start(const SurfaceCommandRequest &request, tbc::view<Completion, tbc::lt::a> complete);
  void cancel();
  [[nodiscard]] bool active() const noexcept;

private:
  void stop(std::optional<SurfaceCommandFailure> failure);
  [[nodiscard]] std::size_t outputLimit() const noexcept;
  void normalizeOutput();
  void drain();
  void finish();
  void finishWhenDrained();
  QProcess process_;
  QTimer deadline_;
  QTimer grace_;
  SurfaceCommandRequest request_;
  SurfaceCommandResult result_;
  tbc::view<Completion, tbc::lt::a> complete_;
  QByteArray payload_;
  qint64 group_ = 0;
  bool running_ = false;
  bool exited_ = false;
  bool normal_exit_ = true;
  QObject context_;
};

}
