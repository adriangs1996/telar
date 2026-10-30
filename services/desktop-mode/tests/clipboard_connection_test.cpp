#include "ui/workbench/runtime_connection.hpp"
#include "ui/workbench/clipboard_consent.hpp"
#include "ui/workbench/clipboard_paste.hpp"
#include "ui/workbench/terminal_item.hpp"
#include <QKeySequence>
#include "telar_client/codecs/telar_handshake.hpp"
#include <QGuiApplication>
#include <QClipboard>
#include <QLocalServer>
#include <QTemporaryDir>
#include <QThread>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <memory>
#include <stdexcept>

// One-shot, exact-size faults exercise the real frame allocations.
// The test binary delegates all other new/delete calls to malloc/free.
namespace allocation_fault {
thread_local std::size_t rejected_size = 0;
}

void *operator new(std::size_t size) {
  if (size != 0 && size == allocation_fault::rejected_size) {
    allocation_fault::rejected_size = 0;
    throw std::bad_alloc{};
  }
  if (auto *pointer = std::malloc(size == 0 ? 1 : size)) {
    return pointer;
  }
  throw std::bad_alloc{};
}

void *operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void *pointer) noexcept { std::free(pointer); }
void operator delete[](void *pointer) noexcept { std::free(pointer); }
void operator delete(void *pointer, std::size_t) noexcept { std::free(pointer); }
void operator delete[](void *pointer, std::size_t) noexcept { std::free(pointer); }

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

struct CopyingPaste {
  bool &reject;
  unsigned &calls;
  std::array<char, 128> storage{};

  CopyingPaste(bool &reject, unsigned &calls) : reject(reject), calls(calls) {}
  CopyingPaste(const CopyingPaste &other) : reject(other.reject), calls(other.calls) {
    if (reject) {
      throw std::bad_alloc{};
    }
  }
  CopyingPaste(CopyingPaste &&) noexcept = default;
  void operator()(bool) const { ++calls; }
};

class ReentrantPasteData final : public QMimeData {
public:
  explicit ReentrantPasteData(std::function<void()> enter) : enter_(std::move(enter)) {}
  QStringList formats() const override {
    enter_();
    return {QStringLiteral("text/plain")};
  }

private:
  std::function<void()> enter_;
};

enum class Replacement { pane, pane_generation, client_generation, connection_epoch };
enum class DeferredEvent { prompt, answer, execution };
enum class AllocationStage { preparation, denial, execution, reader };
}

namespace workbench {
struct ClipboardConnectionTest {
  static void realDeadline() {
    require(QGuiApplication::platformName() == "offscreen", "Deadline fixture requires a private offscreen clipboard");
    QTemporaryDir directory{QStringLiteral("/tmp/telar-clipboard-deadline-XXXXXX")};
    require(directory.isValid(), "Could not create deadline directory");
    const auto path = directory.filePath(QStringLiteral("runtime.sock"));
    QLocalServer server;
    require(server.listen(path), "Could not listen on deadline socket");
    RuntimeConnection connection{path, telar::WorkspaceLocation{.id = 1}};
    connection.socket_.connectToServer(path);
    pumpUntil([&] { return connection.socket_.state() == QLocalSocket::ConnectedState && server.hasPendingConnections(); });
    std::unique_ptr<QLocalSocket> peer{server.nextPendingConnection()};
    receiveFrame(*peer);
    connection.handshake_ = true;
    const telar::ClipboardTicket ticket{7, 11, 13, 17};
    connection.attached_.insert(ticket.pane_id);
    connection.generations_[ticket.pane_id] = ticket.pane_generation;
    QElapsedTimer elapsed;
    elapsed.start();
    connection.clipboardRequest(telar::ClipboardDesktopRequest{.ticket = ticket, .prompt = true, .name = "Deadline fixture"});
    pumpUntil([&] { return connection.clipboard_operations_.at(ticket.nonce)->prompt != nullptr; });
    while (connection.clipboard_operations_.contains(ticket.nonce)) {
      require(elapsed.elapsed() < 33000, "Real clipboard deadline did not expire");
      QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
      QThread::msleep(1);
    }
    const auto duration = elapsed.elapsed();
    require(duration >= 28000, "Clipboard request expired before its real timer");
    const auto wire = receiveFrame(*peer);
    std::array<telar::Byte, 4096> arena;
    telar::DecodeStorage storage{arena};
    const auto result = telar::Codec::decode<telar::CompleteClipboardDesktop>({reinterpret_cast<const telar::Byte *>(wire.constData()), static_cast<std::size_t>(wire.size())}, storage);
    require(result.ticket == ticket && result.prepared && result.status == telar::ClipboardDesktopStatus::denied && result.contents.empty() && result.available.empty(), "Real timer did not send exactly the pending ticket's preparation denial");
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    require(connection.clipboard_operations_.empty() && peer->bytesAvailable() == 0 && connection.socket_.bytesToWrite() == 0, "Real deadline retained an operation or duplicated its denial");
    std::printf("{\"case\":\"real_qt_clipboard_deadline\",\"elapsed_ms\":%lld,\"matching_denials\":1,\"clipboard_read\":false}\n", static_cast<long long>(duration));
  }

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

  static QByteArray receiveFrame(QLocalSocket &peer) {
    pumpUntil([&] { return peer.bytesAvailable() >= static_cast<qint64>(telar::frame_prefix_size); });
    const auto prefix = peer.read(telar::frame_prefix_size);
    auto encoded = std::span{reinterpret_cast<const telar::Byte *>(prefix.constData()), static_cast<std::size_t>(prefix.size())};
    const auto length = telar::u32::decode(encoded);
    require(length <= telar::max_payload_size, "Invalid private peer frame length");
    pumpUntil([&] { return peer.bytesAvailable() >= length; });
    return peer.read(length);
  }

  static void pasteWire() {
    QTemporaryDir directory{QStringLiteral("/tmp/telar-clipboard-paste-XXXXXX")};
    require(directory.isValid(), "Could not create private paste directory");
    const auto path = directory.filePath(QStringLiteral("runtime.sock"));
    QLocalServer server;
    require(server.listen(path), "Could not listen on private paste socket");
    RuntimeConnection connection{path, telar::WorkspaceLocation{.id = 1}};
    connection.socket_.connectToServer(path);
    pumpUntil([&] { return connection.socket_.state() == QLocalSocket::ConnectedState && server.hasPendingConnections(); });
    std::unique_ptr<QLocalSocket> peer{server.nextPendingConnection()};
    const auto hello = receiveFrame(*peer);
    require(hello.size() == telar::HandshakeCodec::encode(telar::ClientHello{}).size(), "Missing private client hello");
    connection.handshake_ = true;
    connection.attached_.insert(7);
    connection.generations_[7] = 11;
    const QString oversized(telar::clipboard_content_limit + 1, QChar{'x'});
    const QStringList formats{QStringLiteral("text/plain"), QStringLiteral("text/html")};
    for (const bool listing_only : {true, false}) {
      const auto text = listing_only ? oversized : QString::fromUtf8("hello 界");
      connection.sendPaste(7, text, formats, listing_only);
      const auto wire = receiveFrame(*peer);
      std::array<telar::Byte, 4096> arena;
      telar::DecodeStorage storage{arena};
      const auto request = telar::Codec::decode<telar::PastePaneClipboard>({reinterpret_cast<const telar::Byte *>(wire.constData()), static_cast<std::size_t>(wire.size())}, storage);
      require(request.pane_id == 7 && request.pane_generation == 11 && request.listing_only == listing_only, "Paste wire identity or kind changed");
      require(request.available.size() == 2 && request.available[0] == "text/plain" && request.available[1] == "text/html", "Paste wire MIME listing changed");
      const auto expected = listing_only ? QByteArray{} : text.toUtf8();
      require(std::string_view{reinterpret_cast<const char *>(request.text.data()), request.text.size()} == std::string_view{expected.constData(), static_cast<std::size_t>(expected.size())}, "Paste wire text changed");
    }
    for (const bool reconnect : {false, true}) {
      const auto request_before = connection.request_;
      const auto generation_before = connection.generations_.at(7);
      ReentrantPasteData source{[&] {
        if (reconnect) {
          connection.disconnected();
          connection.retry_.stop();
          connection.handshake_ = true;
          connection.attached_.insert(7);
          connection.generations_[7] = generation_before;
        } else {
          ++connection.generations_[7];
        }
      }};
      connection.pasteFrom(7, true, [&](bool listing) { return readClipboardPaste(&source, listing); });
      require(connection.request_ == request_before, "Reentrant read retargeted a paste to a replacement connection or pane generation");
    }
    const auto original_epoch = connection.clipboard_epoch_;
    connection.pasteFrom(7, true, [&](bool) -> std::optional<ClipboardPaste> {
      const auto generation = connection.generations_.at(7);
      connection.disconnected();
      connection.retry_.stop();
      connection.handshake_ = true;
      connection.attached_.insert(7);
      connection.generations_[7] = generation;
      throw std::bad_alloc{};
    });
    require(connection.ready() && connection.clipboard_epoch_ != original_epoch, "Old reader allocation failure closed the replacement connection");
    const telar::ClipboardTicket replacement{7, connection.generations_.at(7), 13, 17};
    connection.clipboardRequest(telar::ClipboardDesktopRequest{.ticket = replacement});
    receiveFrame(*peer);
    connection.clipboardAllocationFailed(&connection, replacement, original_epoch);
    auto stale = replacement;
    ++stale.client_generation;
    connection.clipboardAllocationFailed(&connection, stale, connection.clipboard_epoch_);
    require(connection.ready() && connection.clipboard_operations_.contains(replacement.nonce), "Old window allocation failure closed the replacement operation");
    connection.sendPaste(7, oversized, formats, false);
    require(connection.error_ == "Paste exceeds the clipboard limit", "Oversized ordinary paste was not rejected");
    bool delivered = false;
    QTimer::singleShot(0, &connection, [&] { delivered = true; });
    pumpUntil([&] { return delivered; });
    require(peer->bytesAvailable() == 0 && connection.socket_.bytesToWrite() == 0, "Rejected paste was sent to the runtime");
  }

  static void allocationFailure(AllocationStage stage) {
    QTemporaryDir directory{QStringLiteral("/tmp/telar-clipboard-allocation-XXXXXX")};
    require(directory.isValid(), "Could not create private allocation directory");
    const auto path = directory.filePath(QStringLiteral("runtime.sock"));
    QLocalServer server;
    require(server.listen(path), "Could not listen on private allocation socket");
    RuntimeConnection connection{path, telar::WorkspaceLocation{.id = 1}};
    connection.socket_.connectToServer(path);
    pumpUntil([&] { return connection.socket_.state() == QLocalSocket::ConnectedState && server.hasPendingConnections(); });
    std::unique_ptr<QLocalSocket> peer{server.nextPendingConnection()};
    receiveFrame(*peer);
    connection.handshake_ = true;
    const telar::ClipboardTicket ticket{7, 11, 13, 17};
    connection.attached_.insert(ticket.pane_id);
    connection.generations_[ticket.pane_id] = ticket.pane_generation;
    const QPointer<RuntimeConnection> lifetime{&connection};
    const auto epoch = connection.clipboard_epoch_;
    const telar::CompleteClipboardDesktop completion{.ticket = ticket, .status = telar::ClipboardDesktopStatus::success, .prepared = true};
    if (stage == AllocationStage::preparation) {
      allocation_fault::rejected_size = telar::Codec::encodedSize(completion);
      connection.clipboardRequest(telar::ClipboardDesktopRequest{.ticket = ticket});
    } else if (stage == AllocationStage::reader) {
      connection.pasteFrom(ticket.pane_id, true, [](bool) -> std::optional<ClipboardPaste> { throw std::bad_alloc{}; });
    } else {
      require(!QGuiApplication::clipboard()->supportsSelection(), "Offscreen fault fixture requires unavailable primary selection");
      connection.clipboardRequest(telar::ClipboardDesktopRequest{.ticket = ticket, .primary = true});
      receiveFrame(*peer);
      if (stage == AllocationStage::denial) {
        allocation_fault::rejected_size = telar::Codec::encodedSize(completion);
        connection.completeClipboard(ticket, epoch, ClipboardConsent::deny);
      } else {
        connection.desktop_[ticket.pane_id] = telar::ConfigurePaneDesktop{.pane_id = ticket.pane_id, .pane_generation = ticket.pane_generation, .visible = true, .clipboard = true};
        connection.consume(telar::Codec::encode(telar::ClipboardDesktopExecute{.ticket = ticket}));
        allocation_fault::rejected_size = telar::Codec::encodedSize(completion);
        pumpUntil([&] { return !connection.ready(); });
      }
    }
    require(allocation_fault::rejected_size == 0, "Clipboard frame allocation fault was not reached");
    require(!connection.ready() && connection.clipboard_epoch_ != epoch, "Allocation failure retained a live clipboard connection");
    pumpUntil([&] { return peer->state() == QLocalSocket::UnconnectedState && connection.socket_.state() == QLocalSocket::UnconnectedState; });
    require(connection.clipboard_operations_.empty(), "Disconnected allocation failure retained clipboard operations");
    require(peer->bytesAvailable() == 0, "Failed completion published a partial response");
  }

  static void pasteCallbackCopy() {
    auto screen = std::make_shared<TerminalScreen>();
    TerminalItem item{screen, nullptr};
    bool reject = false;
    unsigned calls = 0;
    item.paste = CopyingPaste{reject, calls};
    const auto sequence = QKeySequence::keyBindings(QKeySequence::Paste).front()[0];
    for (const bool failure : {true, false}) {
      reject = failure;
      QKeyEvent event{QEvent::KeyPress, sequence.key(), sequence.keyboardModifiers()};
      require(event.matches(QKeySequence::Paste), "Private input fixture did not select Paste");
      QCoreApplication::sendEvent(&item, &event);
      require(calls == (failure ? 0u : 1u), "Paste callback copy failure admitted a gesture or uninstalled the handler");
    }
  }

  static void destroyedFailureReceiver() {
    auto connection = std::make_unique<RuntimeConnection>(QStringLiteral("/unused/clipboard-destroyed.sock"), telar::WorkspaceLocation{.id = 1});
    connection->clipboardCallback([&] {
      connection.reset();
      throw std::bad_alloc{};
    });
    require(!connection, "Allocation failure resurrected its destroyed receiver");
  }

  static void run() {
    destroyedFailureReceiver();
    pasteCallbackCopy();
    for (const auto stage : {AllocationStage::preparation, AllocationStage::denial, AllocationStage::execution, AllocationStage::reader}) {
      allocationFailure(stage);
    }
    pasteWire();
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
    if (argc == 2 && std::string_view{argv[1]} == "--deadline-only") {
      workbench::ClipboardConnectionTest::realDeadline();
    } else {
      workbench::ClipboardConnectionTest::run();
    }
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    std::puts("Deferred clipboard completion identity tests passed; no desktop resource executed");
    return 0;
  } catch (const std::exception &error) {
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
