#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "surface_command.hpp"
#include <cstdint>
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <QByteArray>
#include <QCoreApplication>
#include <QIODevice>
#include <QProcess>
#include <QString>
#include <QStringLiteral>
#include <QTimer>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <exception>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <utility>



import telar.gui.platform.private_file_stamp;

namespace telar::gui::qt {

SurfaceCommand::SurfaceCommand() {
  deadline_.setSingleShot(true);
  deadline_.setTimerType(Qt::PreciseTimer);
  grace_.setSingleShot(true);
  constexpr std::chrono::milliseconds termination_grace{200};
  grace_.setInterval(termination_grace);
  QObject::connect(&deadline_, &QTimer::timeout, &context_, [this] {
    stop(SurfaceCommandFailure::timeout);
  });
  QObject::connect(&grace_, &QTimer::timeout, &context_, [this] {
    platform::signalProcessGroup(group_, true);
    if (exited_) {
      drain();
    } else {
      process_.kill();
    }
  });
  QObject::connect(&process_, &QProcess::started, &context_, [this] {
    group_ = process_.processId();
    if (result_.failure) {
      platform::signalProcessGroup(group_, false);
    } else {
      process_.write(payload_);
      process_.closeWriteChannel();
    }
  });
  QObject::connect(&process_, &QProcess::readyReadStandardOutput, &context_, [this] {
    drain();
  });
  QObject::connect(&process_, &QProcess::finished, &context_, [this](int code, QProcess::ExitStatus status) {
    if (!running_) {
      return;
    }

    result_.exit_code = code;
    exited_ = true;
    normal_exit_ = status == QProcess::NormalExit;
    drain();
  });
  QObject::connect(&process_, &QProcess::errorOccurred, &context_, [this](QProcess::ProcessError error) {
    if (running_ && error == QProcess::FailedToStart) {
      result_.failure = SurfaceCommandFailure::launch;
      exited_ = true;
      finish();
    }
  });
}

SurfaceCommand::~SurfaceCommand() {
  process_.disconnect(&context_);
  deadline_.stop();
  grace_.stop();
  if (running_) {
    platform::signalProcessGroup(group_, true);
  }

  if (process_.state() != QProcess::NotRunning) {
    process_.kill();
    constexpr std::chrono::milliseconds shutdown_wait{1000};
    static_cast<void>(process_.waitForFinished(static_cast<int>(shutdown_wait.count())));
  }
}

bool SurfaceCommand::active() const noexcept {
  return running_;
}

void SurfaceCommand::start(const SurfaceCommandRequest &request, Completion complete) {
  if (running_) {
    throw std::logic_error{"A surface command is already running"};
  }

  constexpr std::chrono::milliseconds minimum_timeout{100};
  constexpr std::chrono::milliseconds maximum_timeout{60000};
  if (request.arguments.isEmpty() || request.arguments.first().isEmpty() || request.timeout < minimum_timeout || request.timeout > maximum_timeout) {
    throw std::invalid_argument{"Invalid surface command bounds"};
  }

  constexpr qsizetype maximum_arguments = 32;
  constexpr qsizetype maximum_argument_bytes = 4096;
  qsizetype argument_bytes = 0;
  for (const auto &argument : request.arguments) {
    argument_bytes += argument.size();
    if (argument.contains('\0') || argument_bytes > maximum_argument_bytes) {
      throw std::invalid_argument{"Invalid surface command argument"};
    }
  }

  if (request.arguments.size() > maximum_arguments) {
    throw std::invalid_argument{"Too many surface command arguments"};
  }

  request_ = request;
  payload_.clear();
  payload_.append(static_cast<char>(request.arguments.size()));
  for (const auto &argument : request.arguments) {
    payload_.append(argument);
    payload_.append('\0');
  }

  result_ = {};
  complete_ = std::move(complete);
  group_ = 0;
  exited_ = false;
  normal_exit_ = true;
  running_ = true;
  QProcess::UnixProcessParameters parameters;
  parameters.flags = QProcess::UnixProcessFlag::CloseFileDescriptors | QProcess::UnixProcessFlag::CreateNewSession | QProcess::UnixProcessFlag::ResetSignalHandlers;
  process_.setUnixProcessParameters(parameters);
  process_.setStandardInputFile(QString{});
  process_.setStandardErrorFile(QProcess::nullDevice());
  process_.setStandardOutputFile(request.output == SurfaceOutputUse::ignored ? QProcess::nullDevice() : QString{});
  process_.setWorkingDirectory(request.directory);
  process_.setProgram(QCoreApplication::applicationDirPath() + QStringLiteral("/telar-gui-command"));
  process_.setArguments({});
  deadline_.start(request.timeout);
  process_.start(QIODevice::ReadWrite);
}

void SurfaceCommand::cancel() {
  stop(SurfaceCommandFailure::cancelled);
}

void SurfaceCommand::stop(std::optional<SurfaceCommandFailure> failure) {
  if (!running_ || grace_.isActive()) {
    return;
  }

  if (failure) {
    result_.failure = failure;
  }
  deadline_.stop();
  platform::signalProcessGroup(group_, false);
  grace_.start();
}

std::size_t SurfaceCommand::outputLimit() const noexcept {
  switch (request_.output) {
  case SurfaceOutputUse::line:
    return SurfaceCommandRequest::line_output_bytes + 2;
  case SurfaceOutputUse::lines:
    return SurfaceCommandRequest::bar_output_bytes;
  case SurfaceOutputUse::options:
    return SurfaceCommandRequest::pick_output_bytes;
  case SurfaceOutputUse::ignored:
    return 0;
  }

  return 0;
}

void SurfaceCommand::drain() {
  constexpr std::size_t chunk_bytes = 4096;
  constexpr std::size_t maximum_chunks = 16;
  std::array<char, chunk_bytes> buffer{};
  std::size_t chunks = 0;
  while (process_.bytesAvailable() > 0 && chunks++ < maximum_chunks) {
    const auto count = process_.read(buffer.data(), static_cast<qint64>(buffer.size()));
    if (count <= 0) {
      break;
    }

    if (result_.truncated || result_.failure || request_.output == SurfaceOutputUse::ignored) {
      continue;
    }

    result_.observed_bytes += static_cast<std::size_t>(count);
    const auto room = outputLimit() - static_cast<std::size_t>(result_.output.size());
    const auto kept = std::min(room, static_cast<std::size_t>(count));
    result_.output.append(buffer.data(), static_cast<qsizetype>(kept));
    if (std::cmp_not_equal(kept, count)) {
      result_.truncated = true;
      stop(std::nullopt);
    }
  }

  if (process_.bytesAvailable() > 0) {
    QTimer::singleShot(std::chrono::milliseconds{0}, &context_, [this] {
      if (running_) {
        drain();
      }
    });
  }
  finishWhenDrained();
}

void SurfaceCommand::normalizeOutput() {
  if (result_.failure || request_.output == SurfaceOutputUse::ignored) {
    return;
  }

  std::string_view text{result_.output.constData(), static_cast<std::size_t>(result_.output.size())};
  const bool rendered = request_.output != SurfaceOutputUse::line;
  if (result_.truncated && rendered) {
    const auto last = text.find_last_of('\n');
    text = last == std::string_view::npos ? std::string_view{} : text.substr(0, last);
  }

  constexpr std::string_view whitespace = " \t\r\n";
  const auto first = text.find_first_not_of(whitespace);
  text = first == std::string_view::npos ? std::string_view{} : text.substr(first, text.find_last_not_of(whitespace) - first + 1);
  if (!rendered && text.size() > SurfaceCommandRequest::line_output_bytes) {
    text = runtime::utf8Prefix(text, SurfaceCommandRequest::line_output_bytes);
    result_.truncated = true;
  }

  constexpr unsigned first_printable = 0x20;
  constexpr unsigned delete_control = 0x7f;
  try {
    validateUtf8(text);
    for (const auto byte : text) {
      const auto value = static_cast<unsigned char>(byte);
      const bool line_break = byte == '\n' || byte == '\r' || byte == '\t';
      if ((!rendered || !line_break) && (value < first_printable || value == delete_control)) {
        result_.failure = SurfaceCommandFailure::invalid_output;
      }
    }
  } catch (const std::exception &) {
    result_.failure = SurfaceCommandFailure::invalid_output;
  }

  result_.output = QByteArray{text.data(), static_cast<qsizetype>(text.size())};
}

void SurfaceCommand::finishWhenDrained() {
  if (!running_ || !exited_ || grace_.isActive() || process_.bytesAvailable() != 0) {
    return;
  }

  if (!result_.failure && !result_.truncated && (result_.exit_code != 0 || !normal_exit_)) {
    result_.failure = SurfaceCommandFailure::process;
  }

  finish();
}

void SurfaceCommand::finish() {
  normalizeOutput();
  running_ = false;
  deadline_.stop();
  grace_.stop();
  group_ = 0;
  const auto complete = std::move(complete_);
  if (complete) {
    complete(std::move(result_));
  }
}

}
