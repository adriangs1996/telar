#include "application/dependencies.hpp"
#include "application/notification_item.hpp"
#include "core/view_version.hpp"
#include "gui_wait.hpp"
#include "machines/machine_token.hpp"
#include "machines/machines.hpp"
#include "qt/application.hpp"
#include "qt/external_link_opener.hpp"
#include "qt/machine_client.hpp"
#include "qt/machine_client_key.hpp"
#include "qt/terminal_item.hpp"
#include "telar_client/codecs/telar_cells.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "ui/bundled_fonts.hpp"
#include "wire_runtime.hpp"
#include <QAbstractItemModel>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QLocalServer>
#include <QLocalSocket>
#include <QObject>
#include <QString>
#include <QTemporaryDir>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>

namespace telar::gui::test {

struct MachineWindow {
  static qt::MachineClientKey add(qt::Application &application, const QString &endpoint) {
    const auto slot = application.machines_.add({.label = "Build", .destination = "dev@build"});
    auto &client = application.createClient(slot);
    application.synchronizeWorkbenchGeometry();
    client.connection.open(endpoint);

    return client.key;
  }

  static void select(qt::Application &application, MachineToken target) {
    application.selectMachine(target);
  }

  static qt::MachineClient &client(qt::Application &application, Machines::Slot slot) {
    return application.clientAt(slot);
  }

  static auto capture(qt::Application &application) {
    qt::Application::PresentedFrame frame;
    application.prepareFrame(frame);
    const auto *pane = application.session().focusedPane();
    if (pane != nullptr) {
      frame.pane_count = 1;
      frame.panes[0].frame.pane = {.pane_id = pane->id, .frame_id = pane->screen.frameId(), .attached = pane->attached, .attachment_generation = pane->attachment_generation};
    }

    return frame;
  }

  static void present(qt::Application &application, const auto &frame) {
    application.present(frame);
  }

  static qt::MachineClientKey replace(qt::Application &application, Machines::Slot slot) {
    return application.createClient(slot).key;
  }

  static bool contains(const qt::Application &application, qt::MachineClientKey key) {
    return application.findClient(key) != nullptr;
  }
};

}

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr std::uint64_t pane_id = 1;
constexpr TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};

bool finishOpening(WireRuntime &runtime) {
  if (!waitForGuiCondition([&] {
        return runtime.count(ClientTag::open_pane) != 0;
      },
                           wait_ms)) {
    return false;
  }

  const auto opening = runtime.last<OpenPane>();
  runtime.send(PaneOpened{.request_id = opening.request_id, .pane_id = pane_id, .location = location, .created = true, .pane_generation = 1});
  if (!waitForGuiCondition([&] {
        return runtime.count(ClientTag::request_tab_snapshot) != 0 && runtime.count(ClientTag::request_workspace_snapshot) != 0;
      },
                           wait_ms)) {
    return false;
  }

  const std::array descriptors{PaneDescriptor{.pane_id = pane_id, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  runtime.send(TabSnapshot{.request_id = runtime.last<RequestTabSnapshot>().request_id, .location = location, .panes = descriptors});
  const std::array tabs{TabDescriptor{.tab_id = location.tab_id, .pane_count = 1}};
  runtime.send(WorkspaceSnapshot{.request_id = runtime.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});

  return true;
}

void sendFrame(WireRuntime &runtime) {
  constexpr std::size_t cell_capacity = 64;
  const std::array cells{Cell{.text = byteView("X")}};
  std::array<Byte, cell_capacity> encoded{};
  const std::array spans{FrameSpan{.start = 0, .count = 1, .cells = CellRunCodec::encode(cells, encoded)}};
  const std::array<Byte, 1> flags{};
  runtime.send(PaneFrame{FrameBody{.pane_id = pane_id, .frame_id = 1, .cols = 1, .rows = 1, .scroll = {.total_rows = 1}, .text_metadata = TextMetadata{.row_flags = flags}, .spans = spans}});
}

struct MachineFixture {
  ApplicationAllocator memory;
  Application application{memory};
  MachineClientKey remote;
  std::unique_ptr<WireRuntime> local_runtime;
  std::unique_ptr<WireRuntime> remote_runtime;

  bool start() {
    if (!directory_.isValid() || !local_listener_.listen(directory_.filePath(QStringLiteral("local.sock"))) || !remote_listener_.listen(directory_.filePath(QStringLiteral("remote.sock")))) {
      return false;
    }

    application.open(local_listener_.fullServerName());
    if (!waitForGuiCondition([&] {
          return local_listener_.hasPendingConnections();
        },
                             wait_ms)) {
      return false;
    }

    local_socket_.reset(local_listener_.nextPendingConnection());
    local_runtime = std::make_unique<WireRuntime>(*local_socket_);
    if (!waitForGuiCondition([&] {
          return application.connected();
        },
                             wait_ms)) {
      return false;
    }

    remote = MachineWindow::add(application, remote_listener_.fullServerName());
    if (!waitForGuiCondition([&] {
          return remote_listener_.hasPendingConnections();
        },
                             wait_ms)) {
      return false;
    }

    remote_socket_.reset(remote_listener_.nextPendingConnection());
    remote_runtime = std::make_unique<WireRuntime>(*remote_socket_);

    return waitForGuiCondition([&] {
      return MachineWindow::client(application, remote.machine.slot).session.ready();
    },
                               wait_ms);
  }

  ~MachineFixture() {
    remote_runtime.reset();
    local_runtime.reset();
  }

  MachineFixture() = default;
  MachineFixture(const MachineFixture &) = delete;
  MachineFixture &operator=(const MachineFixture &) = delete;
  MachineFixture(MachineFixture &&) = delete;
  MachineFixture &operator=(MachineFixture &&) = delete;

  QTemporaryDir directory_;
  QLocalServer local_listener_;
  QLocalServer remote_listener_;
  std::unique_ptr<QLocalSocket> local_socket_;
  std::unique_ptr<QLocalSocket> remote_socket_;
};

class MachineWindowTest : public QObject {
  Q_OBJECT

  Q_SLOT static void heldKeysCannotRepeatOnAnotherMachine() {
    MachineFixture fixture;
    QVERIFY(fixture.start());
    auto &application = fixture.application;
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr, wait_ms);
    TerminalItem terminal;
    terminal.setApplication(&application);
    terminal.setPaneId(QString::number(pane_id));
    QKeyEvent press{QEvent::KeyPress, Qt::Key_A, Qt::NoModifier, QStringLiteral("a")};
    QCoreApplication::sendEvent(&terminal, &press);
    QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::pane_input), 1, wait_ms);
    MachineWindow::select(application, fixture.remote.machine);
    QVERIFY(finishOpening(*fixture.remote_runtime));
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr, wait_ms);
    QKeyEvent repeat{QEvent::KeyPress, Qt::Key_A, Qt::NoModifier, QStringLiteral("a"), true};
    QCoreApplication::sendEvent(&terminal, &repeat);
    QKeyEvent release{QEvent::KeyRelease, Qt::Key_A, Qt::NoModifier, QStringLiteral("a")};
    QCoreApplication::sendEvent(&terminal, &release);
    QCoreApplication::sendEvent(&terminal, &press);
    QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::pane_input), 1, wait_ms);
    const auto input = fixture.remote_runtime->last<PaneInput>();
    QCOMPARE(textView(input.bytes), std::string_view{"a"});
  }

  Q_SLOT static void hiddenSessionsAndOldFramesKeepTheirMachine() {
    MachineFixture fixture;
    QVERIFY(fixture.start());
    auto &application = fixture.application;
    const auto &local = MachineWindow::client(application, Machines::local_slot);
    const auto &remote = MachineWindow::client(application, fixture.remote.machine.slot);
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    QTRY_VERIFY_WITH_TIMEOUT(local.session.activeTab() != nullptr, wait_ms);
    QVERIFY(remote.session.panes().empty());
    QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 0);
    sendFrame(*fixture.local_runtime);
    QTRY_COMPARE_WITH_TIMEOUT(local.session.findPane(pane_id)->screen.frameId(), 1, wait_ms);
    const auto previous_view = application.viewVersion();
    const auto old_frame = MachineWindow::capture(application);
    MachineWindow::select(application, fixture.remote.machine);
    QVERIFY(finishOpening(*fixture.remote_runtime));
    QTRY_VERIFY_WITH_TIMEOUT(local.session.panes().empty() && remote.session.activeTab() != nullptr, wait_ms);
    QVERIFY(application.viewVersion().machine != previous_view.machine);
    QCOMPARE(fixture.local_runtime->count(ClientTag::detach_pane), 1);
    QCOMPARE(fixture.local_runtime->count(ClientTag::close_pane), 0);
    sendFrame(*fixture.remote_runtime);
    QTRY_COMPARE_WITH_TIMEOUT(remote.session.findPane(pane_id)->screen.frameId(), 1, wait_ms);
    QCOMPARE(remote.session.findPane(pane_id)->attachment_generation, old_frame.panes[0].frame.pane.attachment_generation);
    MachineWindow::present(application, old_frame);
    QCOMPARE(remote.session.findPane(pane_id)->acknowledged_frame, 0);
    MachineWindow::present(application, MachineWindow::capture(application));
    QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::frame_ack), 1, wait_ms);
    QCOMPARE(remote.session.findPane(pane_id)->acknowledged_frame, 1);
    QCOMPARE(fixture.local_runtime->count(ClientTag::frame_ack), 0);
  }

  Q_SLOT static void notificationsRejectCallbacksFromAnotherPresentation() {
    MachineFixture fixture;
    QVERIFY(fixture.start());
    auto &application = fixture.application;
    application.publishNotification({.title = "Local", .message = "local notice", .link = {}});
    const auto old_id = application.notifications().items().front().id;
    const auto old_key = application.notificationIdentity(old_id);
    MachineWindow::select(application, fixture.remote.machine);
    application.publishNotification({.title = "Remote", .message = "remote notice", .link = {}});
    const auto current_id = application.notifications().items().front().id;
    QCOMPARE(old_id.value, current_id.value);
    application.dismissNotification(old_key);
    QCOMPARE(application.notifications().items().front().phase, NotificationItem::Phase::entering);
    application.activateNotification(old_key);
    QCOMPARE(application.notifications().items().front().phase, NotificationItem::Phase::entering);
    application.dismissNotification(application.notificationIdentity(current_id));
    QCOMPARE(application.notifications().items().front().phase, NotificationItem::Phase::exiting);
  }

  Q_SLOT static void rebuildingAClientRejectsItsPreviousAdmission() {
    MachineFixture fixture;
    QVERIFY(fixture.start());
    const auto previous = fixture.remote;
    const auto replacement = MachineWindow::replace(fixture.application, previous.machine.slot);
    QCOMPARE(previous.machine, replacement.machine);
    QVERIFY(previous.generation != replacement.generation);
    QVERIFY(!MachineWindow::contains(fixture.application, previous));
    QVERIFY(MachineWindow::contains(fixture.application, replacement));
  }

  Q_SLOT static void linkFailuresStayWithTheirOriginalClient() {
    MachineFixture fixture;
    QVERIFY(fixture.start());
    auto &application = fixture.application;
    const auto &local = MachineWindow::client(application, Machines::local_slot);
    const auto original = local.key;
    MachineWindow::select(application, fixture.remote.machine);
    application.linkOpeningFinished(original, LinkOpeningFailure::launch);
    QVERIFY(application.notifications().items().empty());
    QCOMPARE(local.session.notifications().items().size(), 1);
    const auto retired = fixture.remote;
    static_cast<void>(MachineWindow::replace(application, retired.machine.slot));
    application.linkOpeningFinished(retired, LinkOpeningFailure::process);
    QVERIFY(application.notifications().items().empty());
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  ui::bundledFonts();
  MachineWindowTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "machine_window_test.moc"
