#include "host_name.hpp"
#include <QByteArray>
#include <QString>
#include <QSysInfo>

namespace telar::gui::platform {

QByteArray hostName() {
  const auto name = QSysInfo::machineHostName().toUtf8();

  return name.isEmpty() ? QByteArrayLiteral("localhost") : name;
}

}
