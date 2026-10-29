#include "ui/workbench/runtime_connection.hpp"
#include "ui/workbench/clipboard_consent.hpp"
#include <QGuiApplication>
#include <QLocalServer>
#include <QTemporaryDir>
#include <cstdio>
#include <memory>
#include <stdexcept>

namespace {
void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void pumpUntil(auto predicate) {
  QElapsedTimer elapsed;
  elapsed.start();
  while (!predicate()) {
    require(elapsed.elapsed() < 3000, "Timed out waiting for private Qt peer");
    QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
  }
}

enum class Replacement { pane, pane_generation, client_generation, connection_epoch };
enum class DeferredEvent { prompt, answer, execution };
}

namespace workbench {
struct ClipboardConnectionTest {
  static void deferredCompletion(Replacement replacement, DeferredEvent deferred) {
    QTemporaryDir directory{QStringLiteral("/tmp/telar-clipboard-connection-XXXXXX")};
    require(directory.isValid(), "Could not create private test directory");
    const auto path = directory.filePath(QStringLiteral("runtime.sock"));
    QLocalServer server;
    require(server.listen(path), "Could not listen on private test socket");
    RuntimeConnection connection{path, telar::WorkspaceLocation{.id = 1}};
    connection.socket_.connectToServer(path);
    pumpUntil([&] { return connection.socket_.state() == QLocalSocket::ConnectedState && server.hasPendingConnections(); });
    std::unique_ptr<QLocalSocket> peer{server.nextPendingConnection()};
    connection.handshake_ = true;
    const telar::ClipboardTicket original{7, 11, 13, 17};
    const auto original_epoch = connection.clipboard_epoch_;
    connection.attached_.insert(original.pane_id);
    connection.generations_[original.pane_id] = original.pane_generation;
    connection.clipboardRequest(telar::ClipboardDesktopRequest{.ticket = original, .prompt = deferred != DeferredEvent::execution, .name = "Old request"});
    if (deferred == DeferredEvent::answer) {
      pumpUntil([&] {
        const auto found = connection.clipboard_operations_.find(original.nonce);
        return found != connection.clipboard_operations_.end() && found->second->prompt != nullptr;
      });

      // Replace the operation before its real window's posted answer arrives.
      auto *window = connection.clipboard_operations_.at(original.nonce)->prompt.get();
      auto *content = window->contentItem()->childItems().front();
      const QPointF point{80, 176};
      QMouseEvent event{QEvent::MouseButtonPress, point, point, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier};
      QCoreApplication::sendEvent(content, &event);
    }

    if (deferred == DeferredEvent::execution) {
      const auto payload = telar::Codec::encode(telar::ClipboardDesktopExecute{.ticket = original});
      connection.consume(payload);
    }

    auto current = original;
    if (replacement == Replacement::connection_epoch) {
      connection.disconnected();
      connection.handshake_ = true;
    } else {
      connection.cancelClipboard(original.pane_id);
      if (replacement == Replacement::pane) {
        ++current.pane_id;
      } else if (replacement == Replacement::pane_generation) {
        ++current.pane_generation;
      } else {
        ++current.client_generation;
      }
    }
    connection.attached_.insert(current.pane_id);
    connection.generations_[current.pane_id] = current.pane_generation;
    connection.clipboardRequest(telar::ClipboardDesktopRequest{.ticket = current, .name = "Current request"});
    require(connection.clipboard_operations_.contains(current.nonce), "Replacement operation was not admitted");
    bool delivered = false;
    QTimer::singleShot(0, &connection, [&] { delivered = true; });
    pumpUntil([&] { return delivered; });
    const auto found = connection.clipboard_operations_.find(current.nonce);
    require(found != connection.clipboard_operations_.end(), "Stale deferred callback consumed the replacement operation");
    require(found->second->task.ticket == current && found->second->prepared, "Replacement identity or preparation changed");
    require(found->second->prompt == nullptr, "Stale creation callback opened a prompt for the replacement operation");

    // The timeout enters the same completion method. Invoke its old identity
    // directly rather than advancing the event loop by thirty seconds.
    connection.completeClipboard(original, original_epoch, ClipboardConsent::deny);
    require(connection.clipboard_operations_.contains(current.nonce), "Stale timeout denied the replacement operation");
    connection.completeClipboard(current, connection.clipboard_epoch_, ClipboardConsent::deny);
    require(!connection.clipboard_operations_.contains(current.nonce), "Matching completion did not finish the current operation");
  }

  static void run() {
    for (const auto deferred : {DeferredEvent::execution, DeferredEvent::prompt, DeferredEvent::answer}) {
      for (const auto replacement : {Replacement::pane, Replacement::pane_generation, Replacement::client_generation, Replacement::connection_epoch}) {
        deferredCompletion(replacement, deferred);
      }
    }
  }
};
}

int main(int argc, char **argv) {
  QGuiApplication application{argc, argv};
  try {
    workbench::ClipboardConnectionTest::run();
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    std::puts("Deferred clipboard completion identity tests passed; no desktop resource executed");
    return 0;
  } catch (const std::exception &error) {
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
