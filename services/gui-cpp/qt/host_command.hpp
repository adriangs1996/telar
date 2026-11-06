#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <array>
#include <cstddef>
#include <span>
#include <string_view>
#include "projection.hpp"
#include <QIODevice>
#include <QProcess>
#include <QStringList>
#include <QtCore/qtypes.h>

#pragma once


import telar.gui.platform.notification_commands;

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
