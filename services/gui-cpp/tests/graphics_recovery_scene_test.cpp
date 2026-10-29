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
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_handshake.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_handshake.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_client/serializers/telar_serializer.hpp"
#include "transport/frame_stream.hpp"
#include "ui/bundled_fonts.hpp"
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
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <vector>

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

class WireRuntime {
public:
  explicit WireRuntime(QLocalSocket &socket)
      : socket_(socket),
        stream_(memory_) {
    QObject::connect(&socket_, &QLocalSocket::readyRead, &socket_, [this] {
      const auto bytes = socket_.readAll();
      const auto consume = [this](std::span<const Byte> payload) {
        if (!greeted_) {
          static_cast<void>(HandshakeCodec::decode<ClientHello>(payload));
          greeted_ = true;
        } else {
          received_.emplace_back(payload.begin(), payload.end());
        }
      };
      stream_.feed(byteView({bytes.constData(), static_cast<std::size_t>(bytes.size())}), consume);
    });
    write(HandshakeCodec::encode(ServerAccept{handshake::schema_id}));
  }

  ~WireRuntime() {
    QObject::disconnect(&socket_, nullptr, &socket_, nullptr);
  }

  WireRuntime(const WireRuntime &) = delete;
  WireRuntime &operator=(const WireRuntime &) = delete;
  WireRuntime(WireRuntime &&) = delete;
  WireRuntime &operator=(WireRuntime &&) = delete;

  template <typename Message>
  void send(const Message &message) {
    std::vector<Byte> bytes(Codec::encodedSize(message));
    write(Codec::encode(message, bytes));
  }

  [[nodiscard]] std::size_t count(ClientTag tag) const {
    return static_cast<std::size_t>(std::ranges::count_if(received_, [tag](const auto &bytes) {
      return bytes.front() == static_cast<Byte>(tag);
    }));
  }

  template <typename Message>
  [[nodiscard]] Message last() const {
    const auto found = std::find_if(received_.rbegin(), received_.rend(), [](const auto &bytes) {
      return bytes.front() == static_cast<Byte>(MessageSchema<Message>::tag);
    });

    DecodeStorage storage{decode_};

    return Codec::decode<Message>(*found, storage);
  }

  void failedSnapshot(std::uint64_t revision) {
    const GraphicsHeader snapshot{.pane_id = 1, .revision = revision};
    send(GraphicsSnapshot{.header = snapshot, .phase = SnapshotPhase::begin});
    constexpr auto overflow = GraphicsStore<SystemAllocator>::image_capacity + 1;
    for (std::uint32_t id = 1; id <= overflow; ++id) {
      send(GraphicsImage{.header = snapshot, .image = {.key = {.image_id = id, .generation = 1}, .format = ImageFormat::rgba, .width = image_side, .height = image_side, .byte_len = pixel_bytes}});
    }

    send(GraphicsSnapshot{.header = snapshot, .phase = SnapshotPhase::end});
  }

private:
  void write(std::span<const Byte> payload) {
    std::array<Byte, frame_prefix_size> prefix{};
    std::span<Byte> output{prefix};
    u32::encode(static_cast<std::uint32_t>(payload.size()), output);
    const auto prefix_text = textView(prefix);
    const auto payload_text = textView(payload);
    socket_.write(prefix_text.data(), static_cast<qint64>(prefix_text.size()));
    socket_.write(payload_text.data(), static_cast<qint64>(payload_text.size()));
  }

  QLocalSocket &socket_;
  SystemAllocator memory_;
  FrameStream<SystemAllocator> stream_;
  std::vector<std::vector<Byte>> received_;
  static constexpr std::size_t decode_capacity = 4096;
  mutable std::array<Byte, decode_capacity> decode_{};
  bool greeted_ = false;
};

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
      runtime.failedSnapshot(revision);
    }

    QTRY_COMPARE_WITH_TIMEOUT(runtime.count(ClientTag::request_graphics_snapshot), 3, wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(label->isVisible(), wait_ms);
    QCOMPARE(label->property("text").toString(), QStringLiteral("images paused"));
    QCOMPARE(application.notifications().items().size(), 1);
    QCOMPARE(application.notifications().items().front().title.view(), std::string_view{"Images paused in pane 1: nvim"});
    QCOMPARE(runtime.count(ClientTag::report_limit), 1);

    constexpr auto window_ns = GraphicsPauses::healthy_window_ns;
    ControlledAwakeClock::set(window_ns - NotificationInput::nanoseconds_per_millisecond);
    runtime.failedSnapshot(4);
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
  ui::bundledFonts();
  QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
  GraphicsRecoverySceneTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "graphics_recovery_scene_test.moc"
