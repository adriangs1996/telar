module;

#include <QByteArray>
#include <QString>
#include <QSysInfo>

module telar.gui.foundation.system;

import std;

namespace telar::gui::inline foundation::inline system {

  QByteArray hostName() {
    const auto name = QSysInfo::machineHostName().toUtf8();

    return name.isEmpty() ? QByteArrayLiteral("localhost") : name;
  }

}
