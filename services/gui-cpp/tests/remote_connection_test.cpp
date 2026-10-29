#include "application/dependencies.hpp"
#include "machines/failure.hpp"
#include "runtime_connection.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <QByteArray>
#include <QByteArrayView>
#include <QCoreApplication>
#include <QFile>
#include <QString>
#include <QTemporaryDir>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qscopeguard.h>
#include <QtCore/qstring.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <cstddef>
#include <vector>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;

class RemoteConnectionTest : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void framedSshTransportAndPermanentFailure() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QVERIFY(QFile::link(QCoreApplication::applicationDirPath() + QStringLiteral("/gui-ssh-runtime-fixture"), directory.filePath(QStringLiteral("ssh"))));
    const auto previous_path = qgetenv("PATH");
    const auto restore = qScopeGuard([previous_path] {
      static_cast<void>(qputenv("PATH", previous_path));
    });
    QVERIFY(qputenv("PATH", directory.path().toUtf8()));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    std::size_t handshakes = 0;
    std::size_t disconnects = 0;
    QByteArray received;
    QByteArray home;
    QStringList errors;
    QObject::connect(&connection, &RuntimeConnection::errorChanged, &connection, [&] {
      errors.append(connection.error());
    });
    QObject::connect(&connection, &RuntimeConnection::connected, &connection, [&] {
      ++handshakes;
    });
    QObject::connect(&connection, &RuntimeConnection::disconnected, &connection, [&] {
      ++disconnects;
    });
    QObject::connect(&connection, &RuntimeConnection::discovered, &connection, [&](QByteArrayView remote_home, QByteArrayView, QByteArrayView) {
      home = remote_home.toByteArray();
    });
    QObject::connect(&connection, &RuntimeConnection::payloadReceived, &connection, [&](QByteArrayView payload) {
      received = payload.toByteArray();
    });
    connection.openRemote({.destination = QStringLiteral("remote"), .program = {}, .local_endpoint = directory.filePath(QStringLiteral("runtime.sock"))});
    QTRY_VERIFY2(connection.ready(), qPrintable(errors.join(QStringLiteral("; "))));
    QCOMPARE(handshakes, std::size_t{1});
    QCOMPARE(home, QByteArray{"/home/remote"});
    const ReportLimit report{.reach = {.name = "fixture.limit", .noun = "cells", .value = 1, .requested = 2, .route = "gui"}, .hits = 1};
    connection.send(report);
    QTRY_VERIFY(!received.isEmpty());
    std::vector<Byte> storage(Codec::encodedSize(report));
    const auto expected = textView(Codec::encode(report, storage));
    QCOMPARE(received, QByteArray(expected.data(), static_cast<qsizetype>(expected.size())));
    connection.close();
    QVERIFY(!connection.ready());
    connection.openRemote({.destination = QStringLiteral("denied"), .program = {}, .local_endpoint = directory.filePath(QStringLiteral("runtime.sock"))});
    QTRY_VERIFY(connection.remoteError().has_value());
    QCOMPARE(connection.remoteError(), std::optional{MachineError::authentication_failed});
    QVERIFY(connection.error().contains(QStringLiteral("Permission denied")));
    QCOMPARE(disconnects, std::size_t{1});
    constexpr int beyond_retry_ms = RuntimeConnection::reconnect_delay_ms + 100;
    QTest::qWait(beyond_retry_ms);
    QCOMPARE(disconnects, std::size_t{1});
    QCOMPARE(handshakes, std::size_t{1});
    QVERIFY(!connection.ready());
  }
};

}

int main(int argc, char **argv) {
  const QCoreApplication application{argc, argv};
  RemoteConnectionTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "remote_connection_test.moc"
