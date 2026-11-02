#include "application/dependencies.hpp"
#include "application/notification_item.hpp"
#include "controlled_awake_clock.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "graphics/pauses.hpp"
#include "graphics/store.hpp"
#include "qml_fixture.hpp"
#include "qt/application.hpp"
#include "qt/list_model.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "qt/bundled_fonts.hpp"
#include "wire_runtime.hpp"
#include <QAbstractItemModel>
#include <QFont>
#include <QGuiApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QObject>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QString>
#include <QTemporaryDir>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr int header_width = 460;
constexpr int header_height = 30;
constexpr std::uint32_t image_side = 2;
constexpr std::uint64_t pixel_bytes = std::uint64_t{image_side} * image_side * 4;

void failedSnapshot(WireRuntime &runtime, std::uint64_t revision) {
  const GraphicsHeader snapshot{.pane_id = 1, .revision = revision};
  runtime.send(GraphicsSnapshot{.header = snapshot, .phase = SnapshotPhase::begin});
  constexpr auto overflow = GraphicsStore<SystemAllocator>::image_capacity + 1;
  for (std::uint32_t id = 1; id <= overflow; ++id) {
    runtime.send(GraphicsImage{.header = snapshot, .image = {.key = {.image_id = id, .generation = 1}, .format = ImageFormat::rgba, .width = image_side, .height = image_side, .byte_len = pixel_bytes}});
  }

  runtime.send(GraphicsSnapshot{.header = snapshot, .phase = SnapshotPhase::end});
}

QVariantMap paneChrome(Application &application) {
  const auto *model = application.panes();

  return model->data(model->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("chrome")).toMap();
}

class GraphicsRecoverySceneTest : public QObject {
  Q_OBJECT

  Q_SLOT static void pauseNoticeHeaderAndTimerFollowTheRuntimeWire() {
    ControlledAwakeClock::set(0);
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer listener;
    const auto endpoint = directory.filePath(QStringLiteral("runtime.sock"));
    QVERIFY(listener.listen(endpoint));
    ApplicationAllocator memory;
    Application application{memory};
    application.open(endpoint);
    QTRY_VERIFY_WITH_TIMEOUT(listener.hasPendingConnections(), wait_ms);
    const std::unique_ptr<QLocalSocket> socket{listener.nextPendingConnection()};
    WireRuntime runtime{*socket};
    QTRY_VERIFY_WITH_TIMEOUT(application.connected(), wait_ms);
    runtime.send(ClientLayoutSnapshot{});
    QTRY_COMPARE_WITH_TIMEOUT(runtime.count(ClientTag::open_pane), 1, wait_ms);
    const auto opening = runtime.last<OpenPane>();
    const TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
    runtime.send(PaneOpened{.request_id = opening.request_id, .pane_id = 1, .location = location, .created = true, .pane_generation = 1});
    const std::array<PaneDescriptor, 1> descriptors{{{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}}};
    runtime.send(TabSnapshot{.request_id = 1, .location = location, .panes = descriptors});
    runtime.send(PaneForeground{.pane_id = 1, .name = "nvim"});
    QTRY_COMPARE_WITH_TIMEOUT(application.panes()->rowCount(), 1, wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(paneChrome(application).value(QStringLiteral("program")).toString(), QStringLiteral("nvim"), wait_ms);

    QQmlEngine engine;
    QQuickWindow window;
    window.resize(header_width, header_height);
    const ChromeMetrics metrics;
    auto item = createChrome(engine, QStringLiteral("PaneHeader"), {{QStringLiteral("record"), paneChrome(application)}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("typography"), QVariantMap{{QStringLiteral("body"), metrics.body}, {QStringLiteral("small"), metrics.small}}}});
    item->setParentItem(window.contentItem());
    item->setSize(window.size());
    QObject::connect(application.panes(), &QAbstractItemModel::dataChanged, item.get(), [&] {
      item->setProperty("record", paneChrome(application));
    });
    const auto labels = visualItems(*item, QStringLiteral("paneImagesPaused"));
    QCOMPARE(labels.size(), 1);
    const auto *label = labels.front();
    QVERIFY(!label->isVisible());
    window.show();
    for (std::uint64_t revision = 1; revision <= 3; ++revision) {
      failedSnapshot(runtime, revision);
    }

    QTRY_COMPARE_WITH_TIMEOUT(runtime.count(ClientTag::request_graphics_snapshot), 3, wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(label->isVisible(), wait_ms);
    QCOMPARE(label->property("text").toString(), QStringLiteral("images paused"));
    QCOMPARE(application.notifications().items().size(), 1);
    QCOMPARE(application.notifications().items().front().title.view(), std::string_view{"Images paused in pane 1: nvim"});
    QCOMPARE(runtime.count(ClientTag::report_limit), 1);

    constexpr auto window_ns = GraphicsPauses::healthy_window_ns;
    ControlledAwakeClock::set(window_ns - NotificationInput::nanoseconds_per_millisecond);
    failedSnapshot(runtime, 4);
    QTRY_COMPARE_WITH_TIMEOUT(application.pane(1)->graphics.revision(), 4, wait_ms);
    QCOMPARE(runtime.count(ClientTag::request_graphics_snapshot), 3);
    ControlledAwakeClock::set(window_ns);
    QTRY_COMPARE_WITH_TIMEOUT(runtime.count(ClientTag::request_graphics_snapshot), 4, wait_ms);
    QVERIFY(application.connected());
    QVERIFY(label->isVisible());
    const GraphicsHeader resumed{.pane_id = 1, .revision = 5};
    runtime.send(GraphicsSnapshot{.header = resumed, .phase = SnapshotPhase::begin});
    runtime.send(GraphicsSnapshot{.header = resumed, .phase = SnapshotPhase::end});
    QTRY_VERIFY_WITH_TIMEOUT(!label->isVisible(), wait_ms);
    QVERIFY(!paneChrome(application).value(QStringLiteral("imagesPaused")).toBool());

    const QSignalSpy connection_changes{&application, &Application::stateChanged};
    runtime.send(GraphicsImageChunk{.header = resumed, .key = {.image_id = 1, .generation = 1}, .bytes = std::array<Byte, pixel_bytes>{}});
    QTRY_VERIFY_WITH_TIMEOUT(!application.connected(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(socket->state(), QLocalSocket::UnconnectedState, wait_ms);
    QVERIFY(connection_changes.count() > 0);
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  bundledFonts();
  QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
  GraphicsRecoverySceneTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "graphics_recovery_scene_test.moc"
