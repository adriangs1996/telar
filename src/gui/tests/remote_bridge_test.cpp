#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/machines/remote_bridge.hpp"
#include <QByteArray>
#include <QCoreApplication>
#include <QIODevice>
#include <QLocalSocket>
#include <QProcess>
#include <QString>
#include <QStringLiteral>
#include <QTemporaryDir>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <array>
#include <chrono>
#include <cstddef>
#include <functional>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <vector>

import telar.gui.features.machines;
import telar.client;
import telar.gui.application;
import telar.base.ds;
import telar.platform.primitives;
import telar.wire.vocabulary;

namespace {

  using namespace telar::gui;

  using namespace telar::gui::features::machines;
  using namespace telar::gui::qt;

  struct TestGatewayHost {
    static constexpr auto discovery_timeout = std::chrono::seconds{2};
    inline static std::vector<QStringList> requests;

    // The words the bridge gives the gateway program: `run DESTINATION COMMAND` to discover a
    // machine, `attach DESTINATION` to carry its runtime. The fixture reads the destination as
    // the case to play and tells the two commands apart by the second.
    static void start(QProcess& process, const QStringList& arguments) {
      requests.push_back(arguments);
      const auto destination = arguments.at(1);
      const auto command = arguments.front() == QStringLiteral("attach") ? QStringLiteral("exec attach") : arguments.back();

      if (destination == QStringLiteral("start-error")) {
        process.start(QStringLiteral("/this-test-executable-does-not-exist"));

        return;
      }

      constexpr auto script = R"(
case "$1" in
  launch) exec /this-test-executable-does-not-exist ;;
  missing) exit 127 ;;
  authentication) printf 'telar gateway: this machine is not paired with that gateway' >&2; exit 255 ;;
  host-key) printf 'telar gateway: The gateway holds another key than the one its address pins' >&2; exit 255 ;;
  protocol) printf 'telar protocol mismatch' >&2; exit 1 ;;
  transient) exit 1 ;;
  crash) kill -KILL $$ ;;
  stderr-tail) dd if=/dev/zero bs=32768 count=1 >&2 2>/dev/null; printf 'telar gateway: this machine is not paired with that gateway' >&2; exit 255 ;;
  timeout) exec sleep 60 ;;
esac
case "$2" in
  'exec '*)
    case "$1" in
      bridge-authentication) printf 'telar gateway: this machine is not paired with that gateway' >&2; exit 255 ;;
      bridge-closed) exit ;;
    esac
    exec cat ;;
esac
case "$1" in
  oversized) exec dd if=/dev/zero bs=32768 count=1 2>/dev/null ;;
  invalid) printf 'unreadable\n'; exit ;;
  legacy) printf '/home/test\n/bin/sh\n/run/test/socket\n%s\n' "$5"; exit ;;
  incompatible) printf '/home/test\n/bin/sh\n/run/test/socket\n%s\n' "$4"; exit ;;
  raw-path) printf '/home/\377\n/bin/sh\n/run/test/socket\n%s\n' "$3"; exit ;;
esac
printf '/home/test\n/bin/sh\n/run/test/socket\n%s\n' "$3"
)";
      const auto& schema = telar::handshake::schema_id;
      const auto schema_text = telar::textView(std::span{schema});
      const auto expected = QString::fromLatin1(schema_text.data(), static_cast<qsizetype>(schema_text.size()));
      const auto mismatch = QString{expected.size(), QLatin1Char('Z')};
      const auto legacy_text = telar::textView(std::span{telar::handshake::schemaOf(telar::handshake::Dialect::schema87)});
      const auto legacy = QString::fromLatin1(legacy_text.data(), static_cast<qsizetype>(legacy_text.size()));

      process.start(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), QString::fromLatin1(script), QStringLiteral("telar-gateway-fixture"), destination, command, expected, mismatch, legacy}, QIODevice::ReadWrite);
    }
  };

  struct ShortDeadlineHost : TestGatewayHost {
    static constexpr auto discovery_timeout = std::chrono::milliseconds{100};
  };

  struct Observer {
    telar::ds::Option<RemoteDiscovery> discovery;
    telar::ds::Option<MachineError> failure;
    QString detail;
    QLocalSocket channel;
    std::function<void()> on_discovery;
    std::size_t discoveries = 0;
    std::size_t channels = 0;
    std::size_t failures = 0;

    void remoteDiscovered(const RemoteDiscovery& value) {
      discovery = value;
      ++discoveries;
      if (const auto callback = std::exchange(on_discovery, {})) {
        callback();
      }
    }

    void remoteChannelReady(telar::runtime::FileDescriptor descriptor) {
      if (!channel.setSocketDescriptor(descriptor.get(), QLocalSocket::ConnectedState)) {
        throw std::runtime_error{"Adopt the gateway fixture's channel"};
      }

      static_cast<void>(descriptor.release());
      ++channels;
    }

    void remoteFailed(MachineError error, std::string_view message) {
      failure = error;
      detail = QString::fromUtf8(message.data(), static_cast<qsizetype>(message.size()));
      ++failures;
    }
  };

  RemoteTarget target(const QTemporaryDir& directory, const QString& destination) {
    return {.destination = destination, .program = {}, .local_endpoint = directory.filePath(QStringLiteral("runtime.sock"))};
  }

  class RemoteBridgeTest : public QObject {
    Q_OBJECT

  private:
    Q_SLOT static void init() {
      TestGatewayHost::requests.clear();
    }

    Q_SLOT static void discoveryAndDuplexTransport() {
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      Observer observer;
      RemoteBridge<TestGatewayHost, Observer> bridge{observer};

      bridge.open(target(directory, QStringLiteral("dev@box")));
      QTRY_COMPARE(observer.channels, std::size_t{1});
      QCOMPARE(observer.discoveries, std::size_t{1});
      QVERIFY(observer.discovery && observer.discovery->home() == "/home/test");
      QCOMPARE(TestGatewayHost::requests.size(), std::size_t{2});
      const auto& arguments = TestGatewayHost::requests.front();

      QCOMPARE(arguments.size(), qsizetype{3});
      QCOMPARE(arguments.front(), QStringLiteral("run"));
      QCOMPARE(arguments.at(1), QStringLiteral("dev@box"));
      QVERIFY(arguments.back().endsWith(QStringLiteral("server endpoint'")));
      QCOMPARE(TestGatewayHost::requests.back(), (QStringList{QStringLiteral("attach"), QStringLiteral("dev@box")}));

      const QByteArray payload{"\0first\xfflast", 11};

      QCOMPARE(observer.channel.write(payload), payload.size());
      QVERIFY(observer.channel.flush());
      QTRY_COMPARE(observer.channel.bytesAvailable(), payload.size());
      QCOMPARE(observer.channel.readAll(), payload);
      QVERIFY(!observer.failure);
      bridge.close();
      QTRY_COMPARE(observer.channel.state(), QLocalSocket::UnconnectedState);
      QCOMPARE(observer.failures, std::size_t{0});
    }

    Q_SLOT static void auditedLegacyDiscoveryStartsItsBridge() {
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      Observer observer;
      RemoteBridge<TestGatewayHost, Observer> bridge{observer};

      bridge.open(target(directory, QStringLiteral("legacy")));
      QTRY_COMPARE(observer.channels, std::size_t{1});
      if (!observer.discovery) {
        QFAIL("Legacy discovery did not publish its schema");
      }

      QCOMPARE(observer.discovery->schema(), telar::handshake::schemaOf(telar::handshake::Dialect::schema87));
      QVERIFY(!observer.failure);
      bridge.close();
    }

    Q_SLOT static void errors() {
      const telar::ds::Array cases{
          std::pair{"missing", MachineError::remote_program_missing},
          std::pair{"authentication", MachineError::authentication_failed},
          std::pair{"host-key", MachineError::host_key_rejected},
          std::pair{"protocol", MachineError::remote_runtime_incompatible},
          std::pair{"transient", MachineError::endpoint_unavailable},
          std::pair{"crash", MachineError::endpoint_unavailable},
          std::pair{"start-error", MachineError::endpoint_unavailable},
          std::pair{"stderr-tail", MachineError::authentication_failed},
          std::pair{"invalid", MachineError::discovery_unreadable},
          std::pair{"oversized", MachineError::discovery_unreadable},
          std::pair{"incompatible", MachineError::remote_program_incompatible},
          std::pair{"bridge-authentication", MachineError::authentication_failed},
          std::pair{"bridge-closed", MachineError::endpoint_unavailable},
      };

      for (const auto& [destination, expected] : cases) {
        const QTemporaryDir directory;
        Observer observer;
        RemoteBridge<TestGatewayHost, Observer> bridge{observer};

        bridge.open(target(directory, QString::fromLatin1(destination)));
        QTRY_VERIFY(observer.failure);
        QCOMPARE(observer.failure, telar::ds::Option{expected});
        QCOMPARE(observer.failures, std::size_t{1});
        QVERIFY(!bridge.active());
      }
    }

    Q_SLOT static void timeoutAndReplacement() {
      const QTemporaryDir directory;
      Observer observer;
      RemoteBridge<ShortDeadlineHost, Observer> bridge{observer};

      bridge.open(target(directory, QStringLiteral("timeout")));
      QTRY_VERIFY(observer.failure);
      QCOMPARE(observer.failure, telar::ds::Option{MachineError::endpoint_unavailable});
      observer.failure.reset();
      bridge.open(target(directory, QStringLiteral("timeout")));
      QTRY_COMPARE(TestGatewayHost::requests.size(), std::size_t{2});
      bridge.open(target(directory, QStringLiteral("replacement")));
      QTRY_COMPARE(observer.channels, std::size_t{1});
      QVERIFY(!observer.failure);
      QCOMPARE(observer.discoveries, std::size_t{1});
    }

    Q_SLOT static void cancelledPreparationAndRawPaths() {
      const QTemporaryDir directory;
      Observer observer;
      RemoteBridge<TestGatewayHost, Observer> bridge{observer};

      bridge.open(target(directory, QStringLiteral("cancelled")));
      bridge.close();
      bridge.open(target(directory, QStringLiteral("raw-path")));
      QTRY_COMPARE(observer.channels, std::size_t{1});
      QVERIFY(observer.discovery && observer.discovery->home() == "/home/\xff");
      QCOMPARE(observer.discoveries, std::size_t{1});
      QCOMPARE(TestGatewayHost::requests.size(), std::size_t{2});
      QCOMPARE(TestGatewayHost::requests.front().at(1), QStringLiteral("raw-path"));
    }

    Q_SLOT static void discoveryReplacementCannotLaunchTheOldBridge() {
      const QTemporaryDir directory;
      Observer observer;
      RemoteBridge<TestGatewayHost, Observer> bridge{observer};

      observer.on_discovery = [&] {
        bridge.open(target(directory, QStringLiteral("replacement")));
      };

      bridge.open(target(directory, QStringLiteral("original")));
      QTRY_COMPARE(observer.channels, std::size_t{1});
      QCOMPARE(observer.discoveries, std::size_t{2});
      QCOMPARE(TestGatewayHost::requests.size(), std::size_t{3});
      QCOMPARE(TestGatewayHost::requests.back().at(1), QStringLiteral("replacement"));
      QVERIFY(!observer.failure);
    }

    Q_SLOT static void validation() {
      const QTemporaryDir directory;
      const auto request = target(directory, QStringLiteral("dev@box"));
      Observer observer;
      RemoteBridge<TestGatewayHost, Observer> bridge{observer};

      QVERIFY_THROWS_EXCEPTION(MachineFailure, bridge.open(target(directory, QStringLiteral("-oProxyCommand=bad"))));
      auto invalid_program = request;

      invalid_program.program = QStringLiteral("telar;bad");
      QVERIFY_THROWS_EXCEPTION(MachineFailure, bridge.open(invalid_program));
      QVERIFY(TestGatewayHost::requests.empty());
      auto invalid_directory = request;

      invalid_directory.local_endpoint = directory.filePath(QStringLiteral("missing/runtime.sock"));
      bridge.open(invalid_directory);
      QTRY_VERIFY(observer.failure);
      QCOMPARE(*observer.failure, MachineError::invalid_runtime_directory);
      QVERIFY(TestGatewayHost::requests.empty());
    }
  };

}

int main(int argc, char** argv) {
  const QCoreApplication application{argc, argv};
  RemoteBridgeTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "remote_bridge_test.moc"
