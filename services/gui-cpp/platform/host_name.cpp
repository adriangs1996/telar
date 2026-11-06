module;

#include <QByteArray>
#include <QString>
#include <QSysInfo>

module telar.gui.platform.login_shell;



namespace telar::gui::platform {

QByteArray hostName() {
  const auto name = QSysInfo::machineHostName().toUtf8();

  return name.isEmpty() ? QByteArrayLiteral("localhost") : name;
}

}
