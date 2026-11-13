#include "application/dependencies.hpp"
#include "qt/runtime_connection.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <QCoreApplication>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <span>

int main(int argc, char **argv) {
  const QCoreApplication application{argc, argv};
  const auto arguments = QCoreApplication::arguments();
  if (arguments.size() != 2) {
    std::cerr << "Usage: gui-runtime-compatibility-probe ABSOLUTE_SOCKET\n";

    return EXIT_FAILURE;
  }

  telar::gui::ApplicationAllocator memory;
  telar::gui::qt::RuntimeConnection connection{memory};
  QTimer watchdog;
  watchdog.setSingleShot(true);
  constexpr std::chrono::milliseconds observation_deadline{10000};
  QObject::connect(&watchdog, &QTimer::timeout, &application, [] {
    std::cerr << "Handshake observation deadline expired\n";
    QCoreApplication::exit(EXIT_FAILURE);
  });
  QObject::connect(&connection, &telar::gui::qt::RuntimeConnection::errorChanged, &application, [&] {
    if (!connection.error().isEmpty()) {
      std::cerr << connection.error().toStdString() << '\n';
      QCoreApplication::exit(EXIT_FAILURE);
    }
  });
  QObject::connect(&connection, &telar::gui::qt::RuntimeConnection::connected, &application, [&] {
    const auto schema = telar::textView(std::span{connection.schema()});
    std::cout << "schema=" << schema << " handshake_only=true\n";
    connection.close();
    QCoreApplication::exit(EXIT_SUCCESS);
  });
  watchdog.start(observation_deadline);
  connection.open(arguments[1]);

  return QCoreApplication::exec();
}
