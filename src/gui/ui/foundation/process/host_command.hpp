#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/models/projection.hpp"
#include <QIODevice>
#include <QProcess>
#include <QStringList>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <span>
#include <string_view>

#pragma once

import telar.gui.foundation.system;

namespace telar::gui::qt {

  inline void startHostCommand(QProcess& process, const system::CommandLine& command) {
    QStringList arguments;

    arguments.reserve(static_cast<qsizetype>(command.count));
    for (const auto argument : command.arguments()) {
      arguments.append(toQString(argument));
    }

    process.start(toQString(command.executable), arguments, QIODevice::ReadOnly);
  }

}
