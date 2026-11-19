#include "foundation/core/memory.hpp"
#include "qt_case.hpp"
#include "ui/app/local_runtime_endpoint.hpp"
#include <QByteArray>
#include <QCoreApplication>
#include <QDir>
#include <QLocalServer>
#include <QLocalSocket>
#include <QString>
#include <QStringLiteral>
#include <QTemporaryDir>
#include <QtCore/qtmetamacros.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <cstddef>
#include <memory>
#include <stdexcept>
#include <string_view>

namespace {

  using namespace telar::gui;
  using namespace telar::gui::qt;

  struct Variables {
    std::string_view socket;
    std::string_view pane_socket;
    std::string_view runtime_directory;
  };

  struct Environment final : telar::runtime::EnvironmentSource {
    explicit Environment(const Variables& variables) noexcept
        : variables(variables) {}

    Variables variables;

    [[nodiscard]] std::string_view lookup(const char* name) const noexcept override {
      const std::string_view key{name};
      if (key == "TELAR_SOCKET") {
        return variables.socket;
      }

      if (key == "TELAR_SOCKET_PATH") {
        return variables.pane_socket;
      }

      return key == "XDG_RUNTIME_DIR" ? variables.runtime_directory : std::string_view{};
    }
  };

  struct Startup {
    inline static std::size_t calls = 0;

    [[nodiscard]] static QString resolve() {
      ++calls;

      return QStringLiteral("/owned-startup/runtime.sock");
    }
  };

  class LocalRuntimeEndpointTest : public QObject {
    Q_OBJECT

  private:
    Q_SLOT static void init() {
      Startup::calls = 0;
    }

    Q_SLOT static void existingManagedSocketAvoidsRuntimeStartup() {
      const QTemporaryDir directory{QStringLiteral("/tmp/telar-endpoint-XXXXXX")};

      QVERIFY(directory.isValid());
      QVERIFY(QDir{directory.path()}.mkdir(QStringLiteral("telar")));
      const auto base = directory.path().toUtf8();
      const Environment environment{{.runtime_directory = {base.constData(), static_cast<std::size_t>(base.size())}}};
      const auto endpoint = directory.filePath(QStringLiteral("telar/runtime.sock"));
      QLocalServer server;

      QVERIFY(server.listen(endpoint));
      SystemAllocator memory;

      QCOMPARE(LocalRuntimeEndpoint<Startup>::resolve(memory, environment), endpoint);
      QCOMPARE(Startup::calls, std::size_t{0});
      QTRY_VERIFY(server.hasPendingConnections());
      const std::unique_ptr<QLocalSocket> probe{server.nextPendingConnection()};

      QVERIFY(probe != nullptr);
      QCOMPARE(probe->bytesAvailable(), 0);
      QTRY_COMPARE(probe->state(), QLocalSocket::UnconnectedState);
    }

    Q_SLOT static void explicitAndPaneEndpointsKeepTheirPrecedence() {
      const QTemporaryDir directory{QStringLiteral("/tmp/telar-endpoint-XXXXXX")};

      QVERIFY(directory.isValid());
      const auto explicit_path = directory.filePath(QStringLiteral("explicit.sock"));
      const auto pane_path = directory.filePath(QStringLiteral("pane.sock"));
      QLocalServer explicit_server;
      QLocalServer pane_server;

      QVERIFY(explicit_server.listen(explicit_path));
      QVERIFY(pane_server.listen(pane_path));
      const auto explicit_bytes = explicit_path.toUtf8();
      const auto pane_bytes = pane_path.toUtf8();
      Environment environment{{.socket = {explicit_bytes.constData(), static_cast<std::size_t>(explicit_bytes.size())}, .pane_socket = {pane_bytes.constData(), static_cast<std::size_t>(pane_bytes.size())}}};
      SystemAllocator memory;

      QCOMPARE(LocalRuntimeEndpoint<Startup>::resolve(memory, environment), explicit_path);
      environment.variables.socket = {};
      QCOMPARE(LocalRuntimeEndpoint<Startup>::resolve(memory, environment), pane_path);
      QCOMPARE(Startup::calls, std::size_t{0});
    }

    Q_SLOT static void missingSocketUsesTheConfiguredStartup() {
      const QTemporaryDir directory{QStringLiteral("/tmp/telar-endpoint-XXXXXX")};

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("missing.sock")).toUtf8();
      const Environment environment{{.socket = {path.constData(), static_cast<std::size_t>(path.size())}}};
      SystemAllocator memory;

      QCOMPARE(LocalRuntimeEndpoint<Startup>::resolve(memory, environment), QStringLiteral("/owned-startup/runtime.sock"));
      QCOMPARE(Startup::calls, std::size_t{1});
    }

    Q_SLOT static void invalidPathsCannotLaunchARuntime() {
      const Environment environment{{.socket = "relative.sock"}};
      SystemAllocator memory;

      QVERIFY_THROWS_EXCEPTION(std::invalid_argument, static_cast<void>(LocalRuntimeEndpoint<Startup>::resolve(memory, environment)));
      QCOMPARE(Startup::calls, std::size_t{0});
    }
  };

  using telar::gui::test::QtCase;

  const QtCase<LocalRuntimeEndpointTest, "existingManagedSocketAvoidsRuntimeStartup"> case_existing_managed_socket_avoids_runtime_startup{"local_runtime_endpoint.existing_managed_socket_avoids_runtime_startup"};
  const QtCase<LocalRuntimeEndpointTest, "explicitAndPaneEndpointsKeepTheirPrecedence"> case_explicit_and_pane_endpoints_keep_their_precedence{"local_runtime_endpoint.explicit_and_pane_endpoints_keep_their_precedence"};
  const QtCase<LocalRuntimeEndpointTest, "missingSocketUsesTheConfiguredStartup"> case_missing_socket_uses_the_configured_startup{"local_runtime_endpoint.missing_socket_uses_the_configured_startup"};
  const QtCase<LocalRuntimeEndpointTest, "invalidPathsCannotLaunchARuntime"> case_invalid_paths_cannot_launch_a_runtime{"local_runtime_endpoint.invalid_paths_cannot_launch_a_runtime"};

}

#include "local_runtime_endpoint_test.moc"
