#include "qt/surface_command.hpp"
#include <QByteArray>
#include <QCoreApplication>
#include <QEventLoop>
#include <QFile>
#include <QIODevice>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QStringLiteral>
#include <QTemporaryDir>
#include <QTimer>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qobject.h>
#include <QtCore/qtypes.h>
#include <array>
#include <chrono>
#include <exception>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <utility>

namespace {

using namespace telar::gui::qt;
constexpr std::chrono::milliseconds command_timeout{2000};
constexpr int observation_timeout_ms = 5000;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

SurfaceCommandRequest request(const QStringList &arguments, SurfaceOutputUse output = SurfaceOutputUse::lines) {
  SurfaceCommandRequest result;
  for (const auto &argument : arguments) {
    result.arguments.append(argument.toUtf8());
  }
  result.output = output;
  result.timeout = command_timeout;

  return result;
}

SurfaceCommandResult run(SurfaceCommand &worker, const SurfaceCommandRequest &command, bool cancel = false) {
  QEventLoop loop;
  QTimer watchdog;
  watchdog.setSingleShot(true);
  std::optional<SurfaceCommandResult> result;
  QObject::connect(&watchdog, &QTimer::timeout, &loop, &QEventLoop::quit);
  worker.start(command, [&](SurfaceCommandResult value) {
    result = std::move(value);
    loop.quit();
  });
  if (cancel) {
    constexpr std::chrono::milliseconds cancellation_delay{20};
    QTimer::singleShot(cancellation_delay, &loop, [&] {
      worker.cancel();
    });
  }

  watchdog.start(observation_timeout_ms);
  loop.exec();
  if (!result) {
    throw std::runtime_error{"Surface command exceeded its observation deadline"};
  }

  require(!worker.active(), "completion must release the worker before notifying its observer");

  return std::move(*result);
}

void literalArgumentsAndInput(SurfaceCommand &worker) {
  const auto literal = QString::fromUtf8("  \xc3\xa1 \xce\xbb;$(literal)  ");
  const auto result = run(worker, request({QStringLiteral("/usr/bin/printf"), QStringLiteral("%s"), literal}));
  require(!result.failure && result.output == QByteArray::fromHex("c3a120cebb3b24286c69746572616c29"), "arguments must keep their UTF-8 bytes and shell metacharacters on every platform");
  auto opaque = request({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("printf %s \"$1\" | od -An -tx1"), QStringLiteral("surface-fixture")});
  opaque.arguments.append(QByteArray::fromHex("ff"));
  const auto bytes = run(worker, opaque);
  require(!bytes.failure && bytes.output == "ff", "command argv must preserve non-UTF-8 bytes accepted by the original worker");
  const auto input = run(worker, request({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("if read value; then exit 1; fi; printf ready")}));
  require(!input.failure && input.output == "ready", "the helper must replace its protocol stdin with /dev/null before executing the command");
}

void outputPolicies(SurfaceCommand &worker) {
  const auto lines = request({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("printf 'a\\nb'")});
  const auto multiline = run(worker, lines);
  require(!multiline.failure && multiline.output == "a\nb", "callback output must preserve embedded line breaks");
  auto single_line = lines;
  single_line.output = SurfaceOutputUse::line;
  require(run(worker, single_line).failure == SurfaceCommandFailure::invalid_output, "plain source text must contain one display line");
  require(run(worker, request({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("printf '\\377'")})).failure == SurfaceCommandFailure::invalid_output, "captured output must reject malformed UTF-8");
  const auto bounded = run(worker, request({QStringLiteral("/usr/bin/yes"), QStringLiteral("abc")}, SurfaceOutputUse::options));
  require(!bounded.failure && bounded.truncated && bounded.output.size() <= static_cast<qsizetype>(SurfaceCommandRequest::pick_output_bytes) && bounded.output.endsWith("abc"), "overflow must stop the child and retain complete option lines without converting truncation to a failure");
  const auto ignored = run(worker, request({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("dd if=/dev/zero bs=4096 count=100 2>/dev/null")}, SurfaceOutputUse::ignored));
  require(!ignored.failure && ignored.output.isEmpty() && !ignored.truncated, "selection output must go to /dev/null regardless of its volume");
  const auto stderr_noise = run(worker, request({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("dd if=/dev/zero bs=4096 count=32 >&2 2>/dev/null; printf ready")}));
  require(!stderr_noise.failure && stderr_noise.output == "ready", "stderr volume must not fail a successful command");
}

void failuresAndCancellation(SurfaceCommand &worker) {
  require(run(worker, request({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("exit 7")})).failure == SurfaceCommandFailure::process, "a nonzero command exit must fail");
  require(run(worker, request({QStringLiteral("/no/such/surface-command")})).failure == SurfaceCommandFailure::process, "an unavailable program must fail through the native launcher");
  auto trickle = request({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("while :; do printf x; sleep .02; done")});
  constexpr std::chrono::milliseconds short_deadline{100};
  trickle.timeout = short_deadline;
  require(run(worker, trickle).failure == SurfaceCommandFailure::timeout, "a trickle of output must not extend the absolute deadline");
  require(run(worker, request({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("sleep 2")}), true).failure == SurfaceCommandFailure::cancelled, "explicit cancellation must stop the worker separately from a timeout");
}

void successfulBackgroundHelper(SurfaceCommand &worker) {
  const QTemporaryDir directory;
  require(directory.isValid(), "background helper state must be private and disposable");
  const auto marker = directory.filePath(QStringLiteral("survived"));
  const auto result = run(worker, request({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("(sleep .2; printf survived > \"$1\") >/dev/null 2>&1 &"), QStringLiteral("surface-fixture"), marker}));
  require(!result.failure, "a successful helper must report completion");
  QEventLoop loop;
  QTimer poll;
  QObject::connect(&poll, &QTimer::timeout, &loop, [&] {
    QFile file{marker};
    if (file.open(QIODevice::ReadOnly) && file.readAll() == "survived") {
      loop.quit();
    }
  });
  constexpr std::chrono::milliseconds poll_interval{20};
  poll.start(poll_interval);
  QTimer::singleShot(command_timeout, &loop, &QEventLoop::quit);
  loop.exec();
  QFile file{marker};
  require(file.open(QIODevice::ReadOnly) && file.readAll() == "survived", "normal completion must preserve a helper intentionally left in the background");
}

void malformedLauncherRequests() {
  QByteArray unterminated;
  unterminated.append(static_cast<char>(1));
  unterminated.append("program");
  auto trailing = unterminated;
  trailing.append('\0');
  trailing.append("trailing");
  QByteArray empty_program;
  empty_program.append(static_cast<char>(1));
  empty_program.append('\0');
  constexpr qsizetype excessive_payload_bytes = 8192;
  const auto payloads = std::to_array<QByteArray>({{}, QByteArray{1, '\0'}, QByteArray{1, static_cast<char>(std::numeric_limits<unsigned char>::max())}, unterminated, trailing, empty_program, QByteArray{excessive_payload_bytes, 'a'}});
  for (const auto &payload : payloads) {
    QProcess process;
    process.setProgram(QCoreApplication::applicationDirPath() + QStringLiteral("/telar-gui-command"));
    process.start(QIODevice::ReadWrite);
    process.write(payload);
    process.closeWriteChannel();
    require(process.waitForFinished(observation_timeout_ms), "the launcher must bound malformed protocol input");
    constexpr int invalid_request_exit = 125;
    require(process.exitStatus() == QProcess::NormalExit && process.exitCode() == invalid_request_exit, "the launcher must reject invalid counts, empty programs, missing terminators, trailing bytes and excessive input before exec");
  }
}

}

int main(int argc, char **argv) {
  const QCoreApplication application{argc, argv};
  try {
    SurfaceCommand worker;
    literalArgumentsAndInput(worker);
    outputPolicies(worker);
    failuresAndCancellation(worker);
    successfulBackgroundHelper(worker);
    malformedLauncherRequests();
    std::cout << "Surface commands preserve argv, bound output and deadlines, and own cancellation\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
