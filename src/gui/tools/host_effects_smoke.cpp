#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/app/overlays/notifications/sound_player.hpp"
#include "ui/app/overlays/notifications/system_notifier.hpp"
#include "ui/foundation/process/command_process.hpp"
#include <QByteArray>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <iostream>
#include <optional>
#include <string_view>
#include <utility>

import telar.gui.foundation.system;

namespace {

  using namespace telar::gui;
  using namespace telar::gui::qt;
  using telar::AgentSound;

  enum class ExitStatus : std::uint8_t {
    success,
    failed,
    usage,
  };
  enum class Argument : std::uint8_t {
    executable,
    mode,
    title,
    message,
    count,
  };

  QString failureText(std::optional<CommandFailure> failure) {
    if (!failure) {
      return QStringLiteral("none");
    }

    switch (*failure) {
    case CommandFailure::launch:
      return QStringLiteral("launch");
    case CommandFailure::process:
      return QStringLiteral("process");
    case CommandFailure::timeout:
      return QStringLiteral("timeout");
    case CommandFailure::output_limit:
      return QStringLiteral("output-limit");
    }

    return QStringLiteral("unknown");
  }

  class Observer {
  public:
    explicit Observer(QString mode)
        : mode_(std::move(mode)) {
      elapsed_.start();
    }

    void commandFinished(std::optional<CommandFailure> failure) const {
      const QJsonObject result{
          {QStringLiteral("mode"), mode_},
          {QStringLiteral("succeeded"), !failure},
          {QStringLiteral("failure"), failureText(failure)},
          {QStringLiteral("elapsed_ms"), elapsed_.elapsed()},
      };

      const auto output = QJsonDocument{result}.toJson(QJsonDocument::Compact);

      std::cout << output.constData() << '\n';
      QCoreApplication::exit(static_cast<int>(failure ? ExitStatus::failed : ExitStatus::success));
    }

    void soundPlaybackFinished(std::optional<CommandFailure> failure) const {
      commandFinished(failure);
    }

  private:
    QString mode_;
    QElapsedTimer elapsed_;
  };

}

int main(int argc, char** argv) try {
  const QCoreApplication application{argc, argv};
  const auto arguments = QCoreApplication::arguments();
  const auto mode = arguments.value(static_cast<qsizetype>(Argument::mode));
  Observer observer{mode};
  CommandProcess<NativeNotificationHost, NotificationPayload, Observer> notice{observer};
  SoundPlayer<NativeSoundHost, Observer> sound{observer};
  constexpr qsizetype sound_argument_count = 2;

  if (arguments.size() == static_cast<qsizetype>(Argument::count) && mode == QStringLiteral("notify")) {
    const auto title = arguments[static_cast<qsizetype>(Argument::title)].toUtf8();
    const auto message = arguments[static_cast<qsizetype>(Argument::message)].toUtf8();

    notice.start(NotificationPayload::create({title.constData(), static_cast<std::size_t>(title.size())}, {message.constData(), static_cast<std::size_t>(message.size())}));
  } else if (arguments.size() == sound_argument_count && (mode == QStringLiteral("ready") || mode == QStringLiteral("needs-input"))) {
    sound.start(mode == QStringLiteral("ready") ? AgentSound::ready : AgentSound::needs_input);
  } else {
    std::cerr << "usage: gui-host-effects-smoke notify TITLE MESSAGE | ready | needs-input\n";

    return static_cast<int>(ExitStatus::usage);
  }

  return QCoreApplication::exec();
} catch (const std::exception& error) {
  std::cerr << error.what() << '\n';

  return static_cast<int>(ExitStatus::failed);
}
