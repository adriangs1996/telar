#include "activity_fixture.hpp"
#include "application/dependencies.hpp"
#include "application/notification_item.hpp"
#include "core/view_version.hpp"
#include "gui_wait.hpp"
#include "machines/machine_token.hpp"
#include "machines/machines.hpp"
#include "metrics_fixture.hpp"
#include "qml_fixture.hpp"
#include "qt/application.hpp"
#include "qt/external_link_opener.hpp"
#include "qt/list_model.hpp"
#include "qt/machine_chrome_layout.hpp"
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
#include <QEvent>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QLocalServer>
#include <QLocalSocket>
#include <QObject>
#include <QPoint>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSize>
#include <QString>
#include <QStringList>
#include <QTemporaryDir>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QSignalSpy>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestkeyboard.h>
#include <QtTest/qtestmouse.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string_view>

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

  static void refreshActivity(qt::Application &application) {
    application.refreshAgents();
  }

  static const void *cachedActivityTargets(const qt::Application &application) {
    return application.activity_targets_.data();
  }

  static bool pendingActivity(const qt::Application &application) {
    return application.pending_activity_.has_value();
  }

  static void pointerMoved(qt::Application &application) {
    application.observeActivityPointer();
  }

  static void rename(qt::Application &application, Machines::Slot slot, std::string_view label) {
    const auto &row = application.machines_.row(slot);
    application.machines_.update(slot, {.label = label, .destination = row.destination.view()});
    emit application.machinesChanged();
  }

  static void recolor(qt::Application &application, Machines::Slot slot, std::string_view color) {
    const auto &row = application.machines_.row(slot);
    application.machines_.update(slot, {.id = row.id, .label = row.label.view(), .destination = row.destination.view(), .color = color, .enabled = row.enabled, .program = row.program.view()});
    emit application.machinesChanged();
  }

  static qt::MachineClientKey reuse(qt::Application &application, Machines::Slot slot) {
    application.retireMachine(slot, qt::Application::MachineRetirement::removed);
    application.clients_[slot].reset();
    application.machines_.remove(slot);
    const auto added = application.machines_.add({.label = "Replacement", .destination = "dev@replacement"}, slot);
    const auto key = application.createClient(added).key;
    emit application.machinesChanged();

    return key;
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

QVariantMap activityRow(Application &application, int row) {
  const auto *model = application.agents();

  return model->data(model->index(row, 0), ListModel::record_role).toMap();
}

QVariantMap activityNamed(Application &application, const QString &title) {
  for (int row = 0; row < application.agents()->rowCount(); ++row) {
    const auto record = activityRow(application, row);
    if (record.value(QStringLiteral("title")).toString() == title) {
      return record;
    }
  }

  return {};
}

AgentSnapshotEntry activityAgent(std::string_view title) {
  return {.pane_id = pane_id, .pane_generation = 1, .location = location, .pane_index = 1, .workspace_label = "project", .session_title = title, .title_source = AgentTitleSource::agent, .title_state = AgentTitleState::ready, .provider = AgentProvider::codex, .provider_name = "codex", .status = AgentStatus::working, .sequence = 1};
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

  Q_SLOT static void remoteRuntimeStoppingReturnsToLocalWithoutClosingWindow() {
    MachineFixture fixture;
    QQuickWindow window;
    constexpr QSize size{800, 600};
    window.resize(size);
    auto &application = fixture.application;
    application.setWindow(window);
    QVERIFY(fixture.start());
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    MachineWindow::select(application, fixture.remote.machine);
    QVERIFY(finishOpening(*fixture.remote_runtime));
    window.show();
    fixture.remote_runtime->send(RuntimeStopping{});
    const auto &local = MachineWindow::client(application, Machines::local_slot).session;
    const auto &remote = MachineWindow::client(application, fixture.remote.machine.slot).session;
    QTRY_VERIFY_WITH_TIMEOUT(local.presented(), wait_ms);
    QVERIFY(!remote.presented());
    QVERIFY(!remote.ready());
    QVERIFY(window.isVisible());
    QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::open_pane), 2, wait_ms);
    const auto opening = fixture.local_runtime->last<OpenPane>();
    fixture.local_runtime->send(PaneOpened{.request_id = opening.request_id, .pane_id = pane_id, .location = location, .pane_generation = 1});
    QTRY_VERIFY_WITH_TIMEOUT(local.findPane(pane_id) != nullptr && local.findPane(pane_id)->attached, wait_ms);
    application.input(pane_id, QByteArrayLiteral("LOCAL_AFTER_REMOTE_STOP"));
    QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::pane_input), 1, wait_ms);
    QCOMPARE(textView(fixture.local_runtime->last<PaneInput>().bytes), std::string_view{"LOCAL_AFTER_REMOTE_STOP"});
    QCOMPARE(fixture.remote_runtime->count(ClientTag::pane_input), 0);
  }

  Q_SLOT static void lastRemoteTabReturnsToLocal() {
    verifyRemoteWorkspaceClosure(false);
  }

  Q_SLOT static void remoteWorkspaceResyncReturnsToLocal() {
    verifyRemoteWorkspaceClosure(true);
  }

  static void verifyRemoteWorkspaceClosure(bool resync) {
    MachineFixture fixture;
    QQuickWindow window;
    constexpr QSize size{800, 600};
    window.resize(size);
    auto &application = fixture.application;
    application.setWindow(window);
    QVERIFY(fixture.start());
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    MachineWindow::select(application, fixture.remote.machine);
    QVERIFY(finishOpening(*fixture.remote_runtime));
    window.show();
    if (resync) {
      fixture.remote_runtime->send(ResyncRequired{.workspace = location.workspace, .workspace_closed = true});
    } else {
      fixture.remote_runtime->send(TabClosed{.location = location, .workspace_closed = true});
    }

    QTRY_VERIFY_WITH_TIMEOUT(MachineWindow::client(application, Machines::local_slot).session.presented(), wait_ms);
    QVERIFY(!MachineWindow::client(application, fixture.remote.machine.slot).session.presented());
    QVERIFY(window.isVisible());
    QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::open_pane), 2, wait_ms);
    const auto opening = fixture.local_runtime->last<OpenPane>();
    fixture.local_runtime->send(PaneOpened{.request_id = opening.request_id, .pane_id = pane_id, .location = location, .pane_generation = 1});
  }

  Q_SLOT static void localRuntimeStoppingClosesItsWindow() {
    MachineFixture fixture;
    QQuickWindow window;
    constexpr QSize size{800, 600};
    window.resize(size);
    fixture.application.setWindow(window);
    QVERIFY(fixture.start());
    window.show();
    fixture.local_runtime->send(RuntimeStopping{});
    QTRY_VERIFY_WITH_TIMEOUT(!window.isVisible(), wait_ms);
  }

  Q_SLOT static void hiddenRemoteRuntimeStoppingPreservesLocalPresentation() {
    MachineFixture fixture;
    QQuickWindow window;
    constexpr QSize size{800, 600};
    window.resize(size);
    auto &application = fixture.application;
    application.setWindow(window);
    QVERIFY(fixture.start());
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    window.show();
    fixture.remote_runtime->send(RuntimeStopping{});
    QTRY_VERIFY_WITH_TIMEOUT(!MachineWindow::client(application, fixture.remote.machine.slot).session.ready(), wait_ms);
    QVERIFY(MachineWindow::client(application, Machines::local_slot).session.presented());
    QVERIFY(window.isVisible());
    application.input(pane_id, QByteArrayLiteral("LOCAL_WITH_HIDDEN_STOP"));
    QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::pane_input), 1, wait_ms);
    QCOMPARE(fixture.local_runtime->count(ClientTag::open_pane), 1);
    QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 0);
    QCOMPARE(fixture.remote_runtime->count(ClientTag::pane_input), 0);
  }

  Q_SLOT static void transientRemoteLossPreservesItsSelectedPresentation() {
    MachineFixture fixture;
    QQuickWindow window;
    constexpr QSize size{800, 600};
    window.resize(size);
    auto &application = fixture.application;
    application.setWindow(window);
    QVERIFY(fixture.start());
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    MachineWindow::select(application, fixture.remote.machine);
    QVERIFY(finishOpening(*fixture.remote_runtime));
    window.show();
    fixture.remote_socket_->disconnectFromServer();
    const auto &remote = MachineWindow::client(application, fixture.remote.machine.slot).session;
    QTRY_VERIFY_WITH_TIMEOUT(!remote.ready(), wait_ms);
    QVERIFY(remote.presented());
    QVERIFY(!MachineWindow::client(application, Machines::local_slot).session.presented());
    QVERIFY(window.isVisible());
  }

  Q_SLOT static void metricProjectionFollowsSelectionLossAndReplacement() {
    MachineFixture fixture;
    QQuickWindow window;
    constexpr QSize size{800, 600};
    window.resize(size);
    auto &application = fixture.application;
    application.setWindow(window);
    QVERIFY(fixture.start());
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    const QSignalSpy changed{&application, &Application::hostMetricsChanged};
    constexpr std::uint8_t local_cpu = 11;
    constexpr std::uint8_t remote_cpu = 92;
    constexpr std::uint8_t replacement_cpu = 37;
    constexpr std::uint64_t revision = 9;
    const auto percent = [&] {
      return application.hostMetrics().value(QStringLiteral("cpu")).toMap().value(QStringLiteral("percent")).toInt();
    };
    fixture.local_runtime->send(hostSample(revision, local_cpu));
    QTRY_COMPARE_WITH_TIMEOUT(percent(), local_cpu, wait_ms);
    const auto local_changes = changed.size();
    const auto &remote = MachineWindow::client(application, fixture.remote.machine.slot);
    fixture.remote_runtime->send(hostSample(revision, remote_cpu));
    QTRY_COMPARE_WITH_TIMEOUT(remote.session.metrics().cpu_percent, remote_cpu, wait_ms);
    QCOMPARE(changed.size(), local_changes);
    MachineWindow::select(application, fixture.remote.machine);
    QVERIFY(finishOpening(*fixture.remote_runtime));
    QCOMPARE(percent(), remote_cpu);
    QVERIFY(changed.size() > local_changes);
    fixture.remote_socket_->disconnectFromServer();
    QTRY_VERIFY_WITH_TIMEOUT(!remote.session.ready(), wait_ms);
    QCOMPARE(percent(), remote_cpu);
    fixture.remote_runtime.reset();
    fixture.remote_socket_ = nullptr;
    QTRY_VERIFY_WITH_TIMEOUT(fixture.remote_listener_.hasPendingConnections(), wait_ms);
    fixture.remote_socket_.reset(fixture.remote_listener_.nextPendingConnection());
    fixture.remote_runtime = std::make_unique<WireRuntime>(*fixture.remote_socket_);
    const auto lost_changes = changed.size();
    QTRY_VERIFY_WITH_TIMEOUT(remote.session.ready(), wait_ms);
    QVERIFY(changed.size() > lost_changes);
    QVERIFY(!application.hostMetrics().value(QStringLiteral("cpu")).toMap().value(QStringLiteral("available")).toBool());
    fixture.remote_runtime->send(hostSample(1, replacement_cpu));
    QTRY_COMPARE_WITH_TIMEOUT(percent(), replacement_cpu, wait_ms);
    MachineWindow::select(application, MachineWindow::client(application, Machines::local_slot).key.machine);
    QCOMPARE(percent(), local_cpu);
  }

  Q_SLOT static void machineSwitcherRoutesClicksAndFitsHiddenControls() {
    MachineFixture fixture;
    QQuickWindow window;
    QQmlEngine engine;
    constexpr QSize size{400, 240};
    window.resize(size);
    fixture.application.setWindow(window);
    QVERIFY(fixture.start());
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    constexpr qreal row_width = 300;
    constexpr qreal row_height = 17;
    auto chrome = createChrome(engine, QStringLiteral("MachineChrome"), {{QStringLiteral("controller"), QVariant::fromValue(&fixture.application)}, {QStringLiteral("colors"), fixture.application.colors()}, {QStringLiteral("width"), row_width}, {QStringLiteral("height"), row_height}});
    chrome->setParentItem(window.contentItem());
    window.show();
    auto *layout = qobject_cast<MachineChromeLayout *>(chrome.get());
    QVERIFY(layout != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 2, wait_ms);
    const auto remote = layout->items()->data(layout->items()->index(1, 0), ListModel::record_role).toMap();
    const auto bounds = remote.value(QStringLiteral("bounds")).toRectF();
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, bounds.center().toPoint());
    QTRY_VERIFY_WITH_TIMEOUT(MachineWindow::client(fixture.application, fixture.remote.machine.slot).session.presented(), wait_ms);
    QVERIFY(!MachineWindow::client(fixture.application, Machines::local_slot).session.presented());
    QVERIFY(finishOpening(*fixture.remote_runtime));
    constexpr qreal narrow_width = 20;
    chrome->setWidth(narrow_width);
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, wait_ms);
    const auto folded = layout->items()->data(layout->items()->index(0, 0), ListModel::record_role).toMap();
    QCOMPARE(folded.value(QStringLiteral("text")).toString(), QStringLiteral("+2"));
    QVERIFY(folded.value(QStringLiteral("bounds")).toRectF().width() <= narrow_width);
    layout->activate(folded.value(QStringLiteral("key")).toString());
    QCOMPARE(fixture.application.dialog(), QStringLiteral("palette"));
    fixture.application.execute(Application::Action::cancel);
  }

  Q_SLOT static void machineSegmentCarriesAttentionAndProfileInk() {
    MachineFixture fixture;
    QQuickWindow window;
    QQmlEngine engine;
    constexpr QSize size{400, 240};
    window.resize(size);
    fixture.application.setWindow(window);
    QVERIFY(fixture.start());
    const std::array agents{activityAgent("Remote waiting")};
    auto blocked = agents;
    blocked.front().status = AgentStatus::blocked;
    blocked.front().blocked_reason = AgentBlockedReason::question;
    fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = blocked});
    constexpr qreal segment_width = 200;
    constexpr qreal segment_height = 26;
    auto chrome = createChrome(engine, QStringLiteral("MachineChrome"), {{QStringLiteral("controller"), QVariant::fromValue(&fixture.application)}, {QStringLiteral("colors"), fixture.application.colors()}, {QStringLiteral("width"), segment_width}, {QStringLiteral("height"), segment_height}});
    chrome->setParentItem(window.contentItem());
    auto *layout = qobject_cast<MachineChromeLayout *>(chrome.get());
    QVERIFY(layout != nullptr);
    layout->setSegment(true);
    window.show();
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, wait_ms);
    const auto row = [&] {
      return layout->items()->data(layout->items()->index(0, 0), ListModel::record_role).toMap();
    };
    QTRY_VERIFY_WITH_TIMEOUT(row().value(QStringLiteral("attentionBounds")).toRectF().width() > 0, wait_ms);
    QVERIFY(layout->preferredWidth() > 0 && layout->preferredWidth() <= segment_width);
    QVERIFY(row().value(QStringLiteral("text")).toString().endsWith(QStringLiteral(" ▾")));
    MachineWindow::recolor(fixture.application, Machines::local_slot, "default");
    QTRY_COMPARE_WITH_TIMEOUT(row().value(QStringLiteral("ink")).value<QColor>().alpha(), 0, wait_ms);
    MachineWindow::recolor(fixture.application, Machines::local_slot, "red");
    QTRY_COMPARE_WITH_TIMEOUT(row().value(QStringLiteral("ink")).value<QColor>(), fixture.application.colors().value(QStringLiteral("red")).value<QColor>(), wait_ms);
    chrome->setVisible(false);
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 0, wait_ms);
    chrome->setVisible(true);
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, wait_ms);
  }

  Q_SLOT static void machineControlsRejectRetiredAdmissionsAndWindows() {
    MachineFixture fixture;
    QQuickWindow window;
    QQuickWindow replacement;
    QQmlEngine engine;
    constexpr QSize size{400, 240};
    window.resize(size);
    fixture.application.setWindow(window);
    QVERIFY(fixture.start());
    constexpr qreal row_width = 300;
    constexpr qreal row_height = 17;
    auto chrome = createChrome(engine, QStringLiteral("MachineChrome"), {{QStringLiteral("controller"), QVariant::fromValue(&fixture.application)}, {QStringLiteral("colors"), fixture.application.colors()}, {QStringLiteral("width"), row_width}, {QStringLiteral("height"), row_height}});
    chrome->setParentItem(window.contentItem());
    window.show();
    auto *layout = qobject_cast<MachineChromeLayout *>(chrome.get());
    QVERIFY(layout != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 2, wait_ms);
    const auto remote_key = [&] {
      return layout->items()->data(layout->items()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString();
    };
    const auto retired = remote_key();
    const auto bounds = layout->items()->data(layout->items()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("bounds")).toRectF();
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, bounds.center().toPoint());
    const auto admitted = MachineWindow::reuse(fixture.application, fixture.remote.machine.slot);
    QTRY_VERIFY_WITH_TIMEOUT(remote_key() != retired, wait_ms);
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, bounds.center().toPoint());
    QVERIFY(fixture.application.connected());
    QVERIFY(!MachineWindow::client(fixture.application, admitted.machine.slot).session.presented());
    layout->activate(retired);
    QVERIFY(fixture.application.connected());
    QVERIFY(!MachineWindow::client(fixture.application, admitted.machine.slot).session.presented());
    fixture.application.setWindow(replacement);
    layout->activate(remote_key());
    QVERIFY(fixture.application.connected());
    QVERIFY(!MachineWindow::client(fixture.application, admitted.machine.slot).session.presented());
    fixture.application.setWindow(window);
    layout->activate(remote_key());
    QVERIFY(MachineWindow::client(fixture.application, admitted.machine.slot).session.presented());
    QVERIFY(!fixture.application.connected());
  }

  Q_SLOT static void activityButtonsRoutePrimaryAndSecondaryOnPress() {
    ApplicationAllocator memory;
    Application application{memory};
    QQuickWindow window;
    QQmlEngine engine;
    constexpr QSize size{400, 240};
    window.resize(size);
    application.setWindow(window);
    const auto geometry = application.sidebarGeometry().value(QStringLiteral("cards")).toMap();
    QVariantMap record{{QStringLiteral("key"), QStringLiteral("owned")}, {QStringLiteral("enabled"), true}, {QStringLiteral("selected"), false}, {QStringLiteral("depth"), 0}, {QStringLiteral("compact"), false}, {QStringLiteral("command"), false}};
    constexpr qreal card_width = 200;
    constexpr qreal card_height = 80;
    auto frame = createChrome(engine, QStringLiteral("ActivityFrame"), {{QStringLiteral("colors"), application.colors()}, {QStringLiteral("geometry"), geometry}, {QStringLiteral("record"), record}, {QStringLiteral("width"), card_width}, {QStringLiteral("height"), card_height}});
    frame->setParentItem(window.contentItem());
    const QSignalSpy selected{frame.get(), SIGNAL(selected(QString))};
    const QSignalSpy peeked{frame.get(), SIGNAL(peekRequested(QString))};
    QVERIFY(selected.isValid() && peeked.isValid());
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    const auto point = frame->boundingRect().center().toPoint();
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, point);
    QCOMPARE(selected.count(), 1);
    QCOMPARE(peeked.count(), 0);
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, point);
    QCOMPARE(selected.count(), 1);
    QTest::mousePress(&window, Qt::RightButton, Qt::NoModifier, point);
    QCOMPARE(peeked.count(), 1);
    QCOMPARE(peeked.front().front().toString(), QStringLiteral("owned"));
    QTest::mouseRelease(&window, Qt::RightButton, Qt::NoModifier, point);
    QCOMPARE(peeked.count(), 1);
    record.insert(QStringLiteral("command"), true);
    frame->setProperty("record", record);
    QTest::mouseClick(&window, Qt::RightButton, Qt::NoModifier, point);
    QCOMPARE(peeked.count(), 1);
    QCOMPARE(selected.count(), 1);
  }

  Q_SLOT static void remotePeekReadsAndSubmitsOnlyToItsOwnedSource() {
    MachineFixture fixture;
    QQuickWindow window;
    QQmlEngine engine;
    constexpr QSize size{800, 600};
    window.resize(size);
    auto &application = fixture.application;
    application.setWindow(window);
    QVERIFY(fixture.start());
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    constexpr std::uint64_t inspected_pane = 9;
    auto agent = activityAgent("Remote inspected");
    agent.pane_id = inspected_pane;
    agent.session_id.front() = 1;
    std::array agents{agent};
    fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
    QTRY_COMPARE_WITH_TIMEOUT(application.agents()->rowCount(), 1, wait_ms);
    const auto key = activityRow(application, 0).value(QStringLiteral("key")).toString();
    application.peekActivity(key);
    QVERIFY(MachineWindow::pendingActivity(application));
    QVERIFY(finishOpening(*fixture.remote_runtime));
    QTRY_COMPARE_WITH_TIMEOUT(application.dialog(), QStringLiteral("peek"), wait_ms);
    QCOMPARE(application.activityHover(), key);
    QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::read_pane), 1, wait_ms);
    QCOMPARE(fixture.local_runtime->count(ClientTag::read_pane), 0);
    QVERIFY(MachineWindow::client(application, fixture.remote.machine.slot).session.findPane(inspected_pane) == nullptr);
    const auto read = fixture.remote_runtime->last<ReadPane>();
    QCOMPARE(read.pane_id, inspected_pane);
    fixture.remote_runtime->send(PaneText{.request_id = read.request_id, .pane_id = inspected_pane, .text = "OWNED_REMOTE_PEEK", .exit_code = {}});
    QTRY_VERIFY_WITH_TIMEOUT(application.peekState().value(QStringLiteral("lines")).toStringList().contains(QStringLiteral("OWNED_REMOTE_PEEK")), wait_ms);
    const auto bounds = application.peekGeometry().value(QStringLiteral("bounds")).toRectF();
    auto panel = createChrome(engine, QStringLiteral("PeekPanel"), {{QStringLiteral("controller"), QVariant::fromValue(&application)}, {QStringLiteral("width"), bounds.width()}, {QStringLiteral("height"), bounds.height()}});
    panel->setParentItem(window.contentItem());
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.activeFocusItem() != nullptr && window.activeFocusItem()->objectName() == QStringLiteral("commandSearch"), wait_ms);
    QTest::mouseMove(&window, QPoint{});
    QTRY_VERIFY_WITH_TIMEOUT(application.activityHover().isEmpty(), wait_ms);
    for (const auto byte : std::string_view{"Continue the remote task"}) {
      QTest::keyClick(&window, byte);
    }
    QTRY_COMPARE_WITH_TIMEOUT(application.peekState().value(QStringLiteral("editorText")).toString(), QStringLiteral("Continue the remote task"), wait_ms);
    QTest::keyClick(&window, Qt::Key_Return);
    QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::send_pane_text), 1, wait_ms);
    const auto message = fixture.remote_runtime->last<SendPaneText>();
    QCOMPARE(message.pane_id, inspected_pane);
    QCOMPARE(message.mode, PaneTextMode::prompt);
    QCOMPARE(message.text, "Continue the remote task");
    QCOMPARE(fixture.local_runtime->count(ClientTag::send_pane_text), 0);
    QCOMPARE(application.dialog(), QString{});
    panel.reset();
    fixture.remote_runtime->send(RequestCompleted{.request_id = message.request_id});
    QTRY_VERIFY_WITH_TIMEOUT(!MachineWindow::client(application, fixture.remote.machine.slot).session.requestsPending(), wait_ms);
    application.peekActivity(key);
    QTRY_COMPARE_WITH_TIMEOUT(application.dialog(), QStringLiteral("peek"), wait_ms);
    const auto stale_revision = application.peekState().value(QStringLiteral("revision")).toString();
    QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::read_pane), 2, wait_ms);
    const auto retired = fixture.remote_runtime->last<ReadPane>();
    ++agents.front().session_id.front();
    fixture.remote_runtime->send(AgentSnapshot{.revision = 2, .entries = agents});
    QTRY_COMPARE_WITH_TIMEOUT(application.dialog(), QString{}, wait_ms);
    application.searchPeek(QStringLiteral("/stop"));
    application.submitPeek(stale_revision);
    QCOMPARE(fixture.remote_runtime->count(ClientTag::interrupt_agent), 0);
    fixture.remote_runtime->send(PaneText{.request_id = retired.request_id, .pane_id = inspected_pane, .text = "RETIRED_PEEK", .exit_code = {}});
    QVERIFY(application.peekState().value(QStringLiteral("lines")).toStringList().isEmpty());
  }

  Q_SLOT static void peekSubmissionsRejectRetiredWindowsAndDialogRevisions() {
    MachineFixture fixture;
    QQuickWindow window;
    QQuickWindow replacement;
    constexpr QSize size{800, 600};
    window.resize(size);
    replacement.resize(size);
    auto &application = fixture.application;
    application.setWindow(window);
    QVERIFY(fixture.start());
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    const std::array agents{activityAgent("Local inspected")};
    fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
    QTRY_COMPARE_WITH_TIMEOUT(application.agents()->rowCount(), 1, wait_ms);
    const auto key = activityRow(application, 0).value(QStringLiteral("key")).toString();
    application.peekActivity(key);
    QCOMPARE(application.dialog(), QStringLiteral("peek"));
    const auto retired = application.peekState().value(QStringLiteral("revision")).toString();
    QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::read_pane), 1, wait_ms);
    const auto retired_read = fixture.local_runtime->last<ReadPane>();
    application.setWindow(replacement);
    QCOMPARE(application.dialog(), QString{});
    application.searchPeek(QStringLiteral("/stop"));
    application.submitPeek(retired);
    QCOMPARE(fixture.local_runtime->count(ClientTag::interrupt_agent), 0);
    fixture.local_runtime->send(PaneText{.request_id = retired_read.request_id, .pane_id = pane_id, .text = "Retired window", .exit_code = {}});
    QTRY_VERIFY_WITH_TIMEOUT(!MachineWindow::client(application, Machines::local_slot).session.requestsPending(), wait_ms);
    application.setWindow(window);
    application.peekActivity(key);
    QCOMPARE(application.dialog(), QStringLiteral("peek"));
    application.searchPeek(QStringLiteral("/stop"));
    application.submitPeek(retired);
    QCOMPARE(fixture.local_runtime->count(ClientTag::interrupt_agent), 0);
    application.submitPeek(application.peekState().value(QStringLiteral("revision")).toString());
    QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::interrupt_agent), 1, wait_ms);
    QCOMPARE(fixture.local_runtime->last<InterruptAgent>().pane_id, pane_id);
  }

  Q_SLOT static void aPointerMoveWhilePeekWaitsDoesNotRestoreOldHover() {
    MachineFixture fixture;
    QQuickWindow window;
    constexpr QSize size{800, 600};
    window.resize(size);
    auto &application = fixture.application;
    application.setWindow(window);
    QVERIFY(fixture.start());
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    const std::array agents{activityAgent("Remote inspected")};
    fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
    QTRY_COMPARE_WITH_TIMEOUT(application.agents()->rowCount(), 1, wait_ms);
    application.peekActivity(activityRow(application, 0).value(QStringLiteral("key")).toString());
    QVERIFY(MachineWindow::pendingActivity(application));
    MachineWindow::pointerMoved(application);
    QVERIFY(finishOpening(*fixture.remote_runtime));
    QTRY_COMPARE_WITH_TIMEOUT(application.dialog(), QStringLiteral("peek"), wait_ms);
    QVERIFY(application.activityHover().isEmpty());
  }

  Q_SLOT static void resizingPeekShowsTheRecentTailAndRetiresItsHiddenEditor() {
    MachineFixture fixture;
    QQuickWindow window;
    QQmlEngine engine;
    constexpr QSize wide{800, 600};
    constexpr QSize narrow{800, 300};
    constexpr QSize tiny{800, 80};
    window.resize(wide);
    auto &application = fixture.application;
    application.setWindow(window);
    QVERIFY(fixture.start());
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    const std::array agents{activityAgent("Local inspected")};
    fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
    QTRY_COMPARE_WITH_TIMEOUT(application.agents()->rowCount(), 1, wait_ms);
    application.peekActivity(activityRow(application, 0).value(QStringLiteral("key")).toString());
    QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::read_pane), 1, wait_ms);
    const auto read = fixture.local_runtime->last<ReadPane>();
    fixture.local_runtime->send(PaneText{.request_id = read.request_id, .pane_id = pane_id, .text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\nRECENT_TAIL", .exit_code = {}});
    constexpr qsizetype line_count = 11;
    QTRY_COMPARE_WITH_TIMEOUT(application.peekState().value(QStringLiteral("lines")).toStringList().size(), line_count, wait_ms);
    const auto bounds = application.peekGeometry().value(QStringLiteral("bounds")).toRectF();
    auto panel = createChrome(engine, QStringLiteral("PeekPanel"), {{QStringLiteral("controller"), QVariant::fromValue(&application)}, {QStringLiteral("width"), bounds.width()}, {QStringLiteral("height"), bounds.height()}});
    panel->setParentItem(window.contentItem());
    const auto lines = [&] {
      return panel->property("state").toMap().value(QStringLiteral("lines")).toStringList();
    };
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.activeFocusItem() != nullptr && window.activeFocusItem()->objectName() == QStringLiteral("commandSearch"), wait_ms);
    const auto *editor = window.activeFocusItem();
    window.resize(narrow);
    QTRY_VERIFY_WITH_TIMEOUT(lines().size() < line_count, wait_ms);
    QVERIFY(!lines().isEmpty());
    QCOMPARE(lines().back(), QStringLiteral("RECENT_TAIL"));
    window.resize(wide);
    QTRY_COMPARE_WITH_TIMEOUT(lines().size(), line_count, wait_ms);
    window.resize(tiny);
    QTRY_VERIFY2_WITH_TIMEOUT(!editor->isEnabled() && !editor->hasActiveFocus(), qPrintable(QStringLiteral("window=%1x%2 field=%3x%4 enabled=%5 focused=%6 owner=%7 dialog=%8 model=%9 qml=%10").arg(window.width()).arg(window.height()).arg(editor->width()).arg(editor->height()).arg(editor->isEnabled()).arg(editor->hasActiveFocus()).arg(window.activeFocusItem() == nullptr ? QStringLiteral("none") : window.activeFocusItem()->objectName()).arg(application.dialog()).arg(application.peekGeometry().value(QStringLiteral("field")).toRectF().height()).arg(panel->property("regions").toMap().value(QStringLiteral("field")).toRectF().height())), wait_ms);
    QTest::keyClick(&window, Qt::Key_Escape);
    QTRY_VERIFY_WITH_TIMEOUT(application.dialog().isEmpty(), wait_ms);
  }

  Q_SLOT static void activityCombinesSourcesWithoutOpeningHiddenScreens() {
    MachineFixture fixture;
    QVERIFY(fixture.start());
    auto &application = fixture.application;
    const auto &remote = MachineWindow::client(application, fixture.remote.machine.slot);
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr && application.pane(pane_id)->attached, wait_ms);
    std::array local_agents{activityAgent("Local agent")};
    local_agents.front().session_id.front() = 1;
    std::array remote_agents{activityAgent("Remote agent")};
    remote_agents.front().session_id.front() = 2;
    const std::array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project", .branch = "own-branch"}, WorkspaceListEntry{.workspace = 2, .name = "command", .path = "/command"}};
    std::array local_tasks{worktreeEntry()};
    local_tasks.front().title = "Local command";
    local_tasks.front().command_state = CommandState::running;
    std::array remote_tasks{local_tasks.front()};
    remote_tasks.front().title = "Remote command";
    remote_tasks.front().created_by.reset();
    remote_tasks.front().coordinator = coordinatorReference(pane_id);
    fixture.local_runtime->send(WorkspaceList{.revision = 1, .entries = projects, .worktrees = local_tasks});
    fixture.remote_runtime->send(WorkspaceList{.revision = 1, .entries = projects, .worktrees = remote_tasks});
    fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = local_agents});
    fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = remote_agents});
    QTRY_COMPARE_WITH_TIMEOUT(application.agents()->rowCount(), 4, wait_ms);
    const auto local = activityNamed(application, QStringLiteral("Local agent"));
    const auto hidden = activityNamed(application, QStringLiteral("Remote agent"));
    QVERIFY(local.value(QStringLiteral("selected")).toBool());
    QVERIFY(!hidden.value(QStringLiteral("selected")).toBool());
    QVERIFY(hidden.value(QStringLiteral("project")).toString().contains(QStringLiteral("Build")));
    QVERIFY(local.value(QStringLiteral("key")) != hidden.value(QStringLiteral("key")));
    const auto command = activityNamed(application, QStringLiteral("Remote command"));
    QCOMPARE(command.value(QStringLiteral("depth")).toUInt(), 1U);
    QVERIFY(command.value(QStringLiteral("key")) != activityNamed(application, QStringLiteral("Local command")).value(QStringLiteral("key")));
    application.peekActivity(command.value(QStringLiteral("key")).toString());
    QVERIFY(application.dialog().isEmpty());
    QVERIFY(application.connected());
    QCOMPARE(activityRow(application, 0).value(QStringLiteral("title")).toString(), QStringLiteral("Local agent"));
    QVERIFY(remote.session.panes().empty());
    QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 0);
    QCOMPARE(fixture.remote_runtime->count(ClientTag::acknowledge_agent), 0);
    const auto *cached = MachineWindow::cachedActivityTargets(application);
    constexpr std::size_t unchanged_refreshes = 256;
    for (std::size_t iteration = 0; iteration < unchanged_refreshes; ++iteration) {
      MachineWindow::refreshActivity(application);
      QCOMPARE(MachineWindow::cachedActivityTargets(application), cached);
    }

    remote_agents.front().session_title = "Remote finished";
    remote_agents.front().status = AgentStatus::done;
    fixture.remote_runtime->send(AgentSnapshot{.revision = 2, .entries = remote_agents});
    QTRY_VERIFY_WITH_TIMEOUT(!activityNamed(application, QStringLiteral("Remote finished")).isEmpty(), wait_ms);
    QVERIFY(remote.session.panes().empty());
    QCOMPARE(fixture.remote_runtime->count(ClientTag::acknowledge_agent), 0);
    const auto identity = hidden.value(QStringLiteral("key"));
    MachineWindow::rename(application, fixture.remote.machine.slot, "Renamed");
    QTRY_VERIFY_WITH_TIMEOUT(activityNamed(application, QStringLiteral("Remote finished")).value(QStringLiteral("project")).toString().contains(QStringLiteral("Renamed")), wait_ms);
    QCOMPARE(activityNamed(application, QStringLiteral("Remote finished")).value(QStringLiteral("key")), identity);
    fixture.remote_socket_->disconnectFromServer();
    QTRY_VERIFY_WITH_TIMEOUT(!activityNamed(application, QStringLiteral("Remote finished")).value(QStringLiteral("enabled")).toBool(), wait_ms);
    QCOMPARE(activityNamed(application, QStringLiteral("Remote finished")).value(QStringLiteral("statusWord")).toString(), QStringLiteral("offline"));
    application.execute(Application::Action::select_agent, identity.toString());
    QVERIFY(application.connected());
    QCOMPARE(application.pane(pane_id)->attached, true);
  }

  Q_SLOT static void activityRejectsReusedSessionsAndWaitsForCanonicalSnapshots() {
    MachineFixture fixture;
    QVERIFY(fixture.start());
    auto &application = fixture.application;
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    constexpr std::uint64_t agent_pane = 9;
    std::array agents{activityAgent("Remote target")};
    agents.front().pane_id = agent_pane;
    agents.front().session_id.front() = 1;
    fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
    QTRY_COMPARE_WITH_TIMEOUT(application.agents()->rowCount(), 1, wait_ms);
    const auto retired = activityRow(application, 0).value(QStringLiteral("key")).toString();
    agents.front().session_id.front() = 2;
    fixture.remote_runtime->send(AgentSnapshot{.revision = 2, .entries = agents});
    QTRY_VERIFY_WITH_TIMEOUT(activityRow(application, 0).value(QStringLiteral("key")).toString() != retired, wait_ms);
    application.execute(Application::Action::select_agent, retired);
    QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 0);
    QVERIFY(!MachineWindow::pendingActivity(application));
    const auto current = activityRow(application, 0).value(QStringLiteral("key")).toString();
    application.execute(Application::Action::select_agent, current);
    QVERIFY(MachineWindow::pendingActivity(application));
    QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::open_pane), 1, wait_ms);
    QVERIFY(fixture.remote_runtime->last<OpenPane>().target.id != agent_pane);
    QVERIFY(finishOpening(*fixture.remote_runtime));
    QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::open_pane), 2, wait_ms);
    const auto handoff = fixture.remote_runtime->last<OpenPane>();
    QCOMPARE(handoff.target.kind, PaneTarget::Kind::pane);
    QCOMPARE(handoff.target.id, agent_pane);
    QVERIFY(!handoff.launch);
    QVERIFY(!MachineWindow::pendingActivity(application));
    QCOMPARE(fixture.remote_runtime->count(ClientTag::create_pane), 0);
    static_cast<void>(MachineWindow::replace(application, fixture.remote.machine.slot));
    application.execute(Application::Action::select_agent, current);
    QVERIFY(!MachineWindow::pendingActivity(application));
    QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 2);
  }

  Q_SLOT static void commandTargetsRejectWorkspaceReuseDuringHandoff() {
    MachineFixture fixture;
    QVERIFY(fixture.start());
    auto &application = fixture.application;
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    std::array tasks{worktreeEntry()};
    tasks.front().created_by.reset();
    tasks.front().command_state = CommandState::running;
    tasks.front().title = "Remote command";
    const std::array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}, WorkspaceListEntry{.workspace = 2, .name = "command", .path = "/command"}};
    fixture.remote_runtime->send(WorkspaceList{.revision = 1, .entries = projects, .worktrees = tasks});
    QTRY_COMPARE_WITH_TIMEOUT(application.agents()->rowCount(), 1, wait_ms);
    const auto retired = activityRow(application, 0).value(QStringLiteral("key")).toString();
    application.execute(Application::Action::select_agent, retired);
    QVERIFY(MachineWindow::pendingActivity(application));
    constexpr std::uint64_t replacement_workspace = 3;
    tasks.front().workspace = replacement_workspace;
    fixture.remote_runtime->send(WorkspaceList{.revision = 2, .entries = projects, .worktrees = tasks});
    QTRY_VERIFY_WITH_TIMEOUT(!MachineWindow::pendingActivity(application), wait_ms);
    QVERIFY(finishOpening(*fixture.remote_runtime));
    const auto workspace_requests = fixture.remote_runtime->count(ClientTag::request_workspace_snapshot);
    const auto local_requests = fixture.local_runtime->count(ClientTag::request_workspace_snapshot);
    application.execute(Application::Action::select_agent, retired);
    QCOMPARE(fixture.remote_runtime->count(ClientTag::request_workspace_snapshot), workspace_requests);
    const auto current = activityRow(application, 0).value(QStringLiteral("key")).toString();
    QVERIFY(current != retired);
    application.execute(Application::Action::select_agent, current);
    QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::request_workspace_snapshot), workspace_requests + 1, wait_ms);
    QCOMPARE(fixture.remote_runtime->last<RequestWorkspaceSnapshot>().workspace.id, replacement_workspace);
    QCOMPARE(fixture.local_runtime->count(ClientTag::request_workspace_snapshot), local_requests);
    QCOMPARE(fixture.remote_runtime->count(ClientTag::create_pane), 0);
  }

  Q_SLOT static void aLaterInteractionCancelsPendingActivity() {
    MachineFixture fixture;
    QVERIFY(fixture.start());
    auto &application = fixture.application;
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    constexpr std::uint64_t agent_pane = 9;
    std::array agents{activityAgent("Pending agent")};
    agents.front().pane_id = agent_pane;
    fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
    QTRY_COMPARE_WITH_TIMEOUT(application.agents()->rowCount(), 1, wait_ms);
    application.execute(Application::Action::select_agent, activityRow(application, 0).value(QStringLiteral("key")).toString());
    QVERIFY(MachineWindow::pendingActivity(application));
    application.execute(Application::Action::cancel);
    QVERIFY(!MachineWindow::pendingActivity(application));
    QVERIFY(finishOpening(*fixture.local_runtime));
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr && application.pane(pane_id)->attached, wait_ms);
    QCOMPARE(fixture.local_runtime->count(ClientTag::open_pane), 1);
    QCOMPARE(application.pane(pane_id)->id, pane_id);
  }

  Q_SLOT static void reconnectingRuntimeInvalidatesActivityWithRestartedRevisions() {
    MachineFixture fixture;
    QVERIFY(fixture.start());
    auto &application = fixture.application;
    const auto &remote = MachineWindow::client(application, fixture.remote.machine.slot);
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    std::array agents{activityAgent("Before reconnect")};
    std::array tasks{worktreeEntry()};
    tasks.front().created_by.reset();
    tasks.front().command_state = CommandState::running;
    tasks.front().title = "Command";
    const std::array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}, WorkspaceListEntry{.workspace = 2, .name = "command", .path = "/command"}};
    fixture.remote_runtime->send(WorkspaceList{.revision = 1, .entries = projects, .worktrees = tasks});
    fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
    QTRY_COMPARE_WITH_TIMEOUT(application.agents()->rowCount(), 2, wait_ms);
    const auto old_agent = activityNamed(application, QStringLiteral("Before reconnect")).value(QStringLiteral("key")).toString();
    const auto old_command = activityNamed(application, QStringLiteral("Command")).value(QStringLiteral("key")).toString();
    fixture.remote_socket_->disconnectFromServer();
    QTRY_VERIFY_WITH_TIMEOUT(!remote.session.ready(), wait_ms);
    fixture.remote_runtime.reset();
    fixture.remote_socket_ = nullptr;
    QTRY_VERIFY_WITH_TIMEOUT(fixture.remote_listener_.hasPendingConnections(), wait_ms);
    fixture.remote_socket_.reset(fixture.remote_listener_.nextPendingConnection());
    fixture.remote_runtime = std::make_unique<WireRuntime>(*fixture.remote_socket_);
    QTRY_VERIFY_WITH_TIMEOUT(remote.session.ready(), wait_ms);
    agents.front().session_title = "After reconnect";
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(WorkspaceList{.revision = 1, .entries = projects, .worktrees = tasks});
    fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
    QTRY_VERIFY_WITH_TIMEOUT(!activityNamed(application, QStringLiteral("After reconnect")).isEmpty(), wait_ms);
    QVERIFY(activityNamed(application, QStringLiteral("After reconnect")).value(QStringLiteral("key")).toString() != old_agent);
    QVERIFY(activityNamed(application, QStringLiteral("Command")).value(QStringLiteral("key")).toString() != old_command);
    application.execute(Application::Action::select_agent, old_agent);
    application.execute(Application::Action::select_agent, old_command);
    QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 0);
    QVERIFY(!MachineWindow::pendingActivity(application));
    QVERIFY(remote.session.panes().empty());
    application.execute(Application::Action::select_agent, activityNamed(application, QStringLiteral("After reconnect")).value(QStringLiteral("key")).toString());
    QVERIFY(MachineWindow::pendingActivity(application));
    QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::open_pane), 1, wait_ms);
  }

  Q_SLOT static void retiredNotificationFocusKeepsItsWindowAndMachine() {
    MachineFixture fixture;
    auto &application = fixture.application;
    QQuickWindow previous;
    QQuickWindow current;
    constexpr QSize window_size{320, 240};
    previous.resize(window_size);
    current.resize(window_size);
    previous.show();
    current.show();
    current.requestActivate();
    QTRY_VERIFY_WITH_TIMEOUT(current.isActive(), wait_ms);
    application.setWindow(previous);
    QVERIFY(fixture.start());
    fixture.local_runtime->send(ClientLayoutSnapshot{});
    fixture.remote_runtime->send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(*fixture.local_runtime));
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr && application.pane(pane_id)->attached, wait_ms);
    TerminalItem old_terminal{previous.contentItem()};
    old_terminal.setApplication(&application);
    old_terminal.setPaneId(QString::number(pane_id));
    TerminalItem terminal{current.contentItem()};
    terminal.setApplication(&application);
    terminal.setPaneId(QString::number(pane_id));
    application.publishNotification({.title = "Local", .message = "local focus", .link = {}});
    const auto local_key = application.notificationIdentity(application.notifications().items().front().id);
    previous.contentItem()->forceActiveFocus();
    application.retireNotificationFocus(local_key);
    application.setWindow(current);
    current.contentItem()->forceActiveFocus();
    QCoreApplication::sendPostedEvents(&application, QEvent::MetaCall);
    QCOMPARE(current.activeFocusItem(), current.contentItem());
    application.retireNotificationFocus(local_key, &old_terminal);
    QCoreApplication::sendPostedEvents(&application, QEvent::MetaCall);
    QCOMPARE(current.activeFocusItem(), current.contentItem());

    application.retireNotificationFocus(local_key);
    QCoreApplication::sendPostedEvents(&application, QEvent::MetaCall);
    QCOMPARE(current.activeFocusItem(), &terminal);
    terminal.setFocus(false);
    current.contentItem()->forceActiveFocus();
    QCOMPARE(current.activeFocusItem(), current.contentItem());
    application.retireNotificationFocus(local_key);
    QQuickItem editor{current.contentItem()};
    editor.forceActiveFocus();
    QCoreApplication::sendPostedEvents(&application, QEvent::MetaCall);
    QCOMPARE(current.activeFocusItem(), &editor);

    MachineWindow::select(application, fixture.remote.machine);
    QVERIFY(finishOpening(*fixture.remote_runtime));
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr && application.pane(pane_id)->attached, wait_ms);
    application.publishNotification({.title = "Remote", .message = "remote focus", .link = {}});
    const auto remote_key = application.notificationIdentity(application.notifications().items().front().id);
    editor.setFocus(false);
    current.contentItem()->forceActiveFocus();
    QCOMPARE(current.activeFocusItem(), current.contentItem());
    application.retireNotificationFocus(local_key);
    QCoreApplication::sendPostedEvents(&application, QEvent::MetaCall);
    QCOMPARE(current.activeFocusItem(), current.contentItem());
    application.retireNotificationFocus(remote_key);
    QCoreApplication::sendPostedEvents(&application, QEvent::MetaCall);
    QCOMPARE(current.activeFocusItem(), &terminal);
  }

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
