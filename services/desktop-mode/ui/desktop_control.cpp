#include "desktop_control.hpp"
#include "../desktop_registry.hpp"
#include "../desktop_session.hpp"
#include "../native-backends/application.hpp"
#include "../runtime_session.hpp"
#include <QEventLoop>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QTimer>
#include <stdexcept>

namespace {
  constexpr int takeover_timeout_ms = 5000;
  constexpr int poll_interval_ms = 20;

  void waitFor(const std::function<bool()> &ready, const char *error) {
    if (ready()) {
      return;
    }

    QEventLoop loop;
    QTimer poll;
    QTimer deadline;
    bool done = false;
    QObject::connect(&poll, &QTimer::timeout, &loop, [&] {
      if ((done = ready())) {
        loop.quit();
      }
    });
    QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
    poll.start(poll_interval_ms);
    deadline.setSingleShot(true);
    deadline.start(takeover_timeout_ms);
    loop.exec();

    if (!done) {
      throw std::runtime_error(error);
    }
  }
} // namespace

struct DesktopControl::Impl {
  QString endpoint = QString::fromStdString(DesktopRegistry::directory() + "/control.sock");
  QLockFile lock{QString::fromStdString(DesktopRegistry::directory() + "/control.lock")};
  QLocalServer server;

  Impl(ApplicationHost &host, DesktopSession &desktop, RuntimeSession &runtime) {
    // A disconnected or half-loaded replacement must never evict the current desktop.
    waitFor(
        [&] {
          return host.update() && runtime.state().connected && runtime.state().workspaces_ready;
        },
        "The replacement runtime did not provide its workspace catalog");

    lock.setStaleLockTime(0);

    if (!lock.tryLock()) {
      QLocalSocket previous;
      previous.connectToServer(endpoint);

      if (!previous.waitForConnected(takeover_timeout_ms)) {
        throw std::runtime_error("Another desktop owns the session but did not answer the handoff");
      }

      previous.write("replace\n");
      previous.flush();

      if (!previous.waitForReadyRead(takeover_timeout_ms) || previous.readLine() != "yielding\n") {
        throw std::runtime_error(
            "The active desktop is busy; retry after its Space operation finishes");
      }

      waitFor(
          [&] {
            return lock.tryLock();
          },
          "The previous desktop did not release control of the session");
    }

    QLocalServer::removeServer(endpoint);
    server.setSocketOptions(QLocalServer::UserAccessOption);

    if (!server.listen(endpoint)) {
      throw std::runtime_error("Cannot listen for desktop handoffs");
    }

    QObject::connect(&server, &QLocalServer::newConnection, &server, [&host, &desktop, this] {
      while (auto *connection = server.nextPendingConnection()) {
        connection->setReadBufferSize(32);
        QObject::connect(connection,
                         &QLocalSocket::disconnected,
                         connection,
                         &QObject::deleteLater);
        QTimer::singleShot(1000, connection, &QObject::deleteLater);
        QObject::connect(connection,
                         &QLocalSocket::readyRead,
                         connection,
                         [&host, &desktop, connection] {
                           if (!connection->canReadLine()) {
                             return;
                           }

                           const bool ready = connection->readLine() == "replace\n" &&
                                              !desktop.state().pending_operation &&
                                              !desktop.state().pending_space;
                           connection->write(ready && host.requestExit() ? "yielding\n" : "busy\n");
                           connection->flush();
                           connection->disconnectFromServer();
                         });
      }
    });
  }

  ~Impl() {
    server.close();
  }
};

DesktopControl::DesktopControl(ApplicationHost &host,
                               DesktopSession &desktop,
                               RuntimeSession &runtime)
    : impl_(std::make_unique<Impl>(host, desktop, runtime)) {}

DesktopControl::~DesktopControl() = default;
