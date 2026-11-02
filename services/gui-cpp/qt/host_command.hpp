#pragma once

#include "platform/command_line.hpp"
#include "projection.hpp"
#include <QIODevice>
#include <QProcess>
#include <QStringList>
#include <QtCore/qtypes.h>

namespace telar::gui::qt {

inline void startHostCommand(QProcess &process, const platform::CommandLine &command) {
  QStringList arguments;
  arguments.reserve(static_cast<qsizetype>(command.count));
  for (const auto argument : command.arguments()) {
    arguments.append(toQString(argument));
  }

  process.start(toQString(command.executable), arguments, QIODevice::ReadOnly);
}

}
