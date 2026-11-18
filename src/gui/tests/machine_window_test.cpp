#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "frame_fixture.hpp"
#include "gui_wait.hpp"
#include "qml_fixture.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/protocol/runtime.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/foundation/plugins/plugin_worker.hpp"
#include <QByteArray>
#include <QColor>
#include <algorithm>
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits.h>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <tuple>
#include <utility>
#if (defined(__APPLE__))
#include "ui/app/panes/attachments/attachment_shelf.hpp"
#endif
#if (defined(__APPLE__))
#include "ui/foundation/input/key_adapter.hpp"
#endif
#if (defined(__APPLE__))
#include "platform/private_clipboard.hpp"
#endif
#if (defined(__APPLE__))
#include <QBuffer>
#endif
#if (defined(__APPLE__))
#include <QRectF>
#endif
#if (defined(__APPLE__))
#include <QImage>
#endif
#if (defined(__APPLE__))
#include <QDebug>
#endif
#if (defined(__APPLE__))
#include <QtCore/qlogging.h>
#endif
#if (defined(__APPLE__))
#include <QSGRendererInterface>
#endif
#if (defined(__APPLE__))
#include <QFont>
#endif
#if (defined(__APPLE__))
#include <QScopeGuard>
#endif
#if (defined(__APPLE__))
#include <QtGui/qtestsupport_gui.h>
#endif
#include "telar_wire/codecs/telar_cells.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "ui/app/chrome/components/machine_chrome/machine_chrome_layout.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include "ui/foundation/fonts/bundled_fonts.hpp"
#include "ui/foundation/links/external_link_opener.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/models/list_model.hpp"
#include "wire_runtime.hpp"
#include <QAbstractItemModel>
#include <QCoreApplication>
#include <QEvent>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIODevice>
#include <QKeyEvent>
#include <QLocalServer>
#include <QLocalSocket>
#include <QObject>
#include <QPoint>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QSize>
#include <QString>
#include <QStringList>
#include <QStringLiteral>
#include <QTemporaryDir>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QSignalSpy>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestkeyboard.h>
#include <QtTest/qtestmouse.h>
#include <chrono>
#include <memory>

#ifdef __APPLE__
#include "platform/private_clipboard.hpp"
#include "ui/app/panes/attachments/attachment_shelf.hpp"
#include "ui/foundation/input/key_adapter.hpp"
#include <QBuffer>
#include <QDebug>
#include <QFont>
#include <QImage>
#include <QRectF>
#include <QSGRendererInterface>
#include <QScopeGuard>
#include <QtCore/qlogging.h>
#include <QtGui/qtestsupport_gui.h>
#endif

import telar.gui.tests.activity_fixture;
import telar.gui.tests.metrics_fixture;
import telar.gui.application;
import telar.gui.features.plugins;
import telar.gui.features.machines;
#if (defined(__APPLE__))
#endif
import telar.gui.features.notifications;
import telar.wire.agents;
import telar.wire.content;
import telar.wire.layout;
import telar.base.ds;

namespace telar::gui::test {

  using namespace telar::gui::features::machines;
  using namespace telar::gui::features::plugins;

  struct MachineWindow {
    static qt::LinksController& links(qt::ApplicationController& application) {
      return application.links_;
    }

    static void armPlugin(qt::ApplicationController& application, MachineClientKey source, std::uint64_t execution, std::uint64_t runtime_generation) {
      application.plugins_.owner_ = qt::PluginRunner::Owner{.source = source, .runtime_generation = runtime_generation, .execution = execution};
    }

    static bool pendingPlugin(const qt::ApplicationController& application) {
      return application.plugins_.owner_.hasValue();
    }

    static void completePluginFailure(qt::ApplicationController& application, std::uint64_t execution) {
      PluginInvocation invocation;

      invocation.configuration_generation = application.configuration_source_.configurationGeneration();
      qt::PluginWorkerResult result;

      result.error = QStringLiteral("OwnedPluginFailure");
      application.plugins_.pluginWorkerFinished(execution, invocation, result);
    }

    static MachineClientKey add(qt::ApplicationController& application, const QString& endpoint) {
      const auto slot = application.store_.machinesMut().add({.label = "Build", .destination = "dev@build"});
      auto& client = application.machines_.createClient(slot);

      application.display_.layoutWorkbench();
      client.connection.open(endpoint);

      return client.key;
    }

    static void select(qt::ApplicationController& application, MachineToken target) {
      application.machines_.select(target);
    }

    static qt::MachineClient& client(qt::ApplicationController& application, Machines::Slot slot) {
      return application.machines_.clientAt(slot);
    }

    static void refreshActivity(qt::ApplicationController& application) {
      application.activity_.synchronize();
    }

    static std::uint64_t activityRebuilds(qt::ApplicationController& application) {
      return application.activity()->rebuilds();
    }

    static bool pendingActivity(const qt::ApplicationController& application) {
      return application.activity_selection_.pending_.hasValue();
    }

    static void pointerMoved(qt::ApplicationController& application) {
      application.activity_.observePointer();
    }

    static void pointerMoved(qt::ApplicationController& application, QPointF position) {
      application.activity_.observePointer(true, position);
    }

    static void rename(qt::ApplicationController& application, Machines::Slot slot, std::string_view label) {
      const auto& row = application.store_.machines().row(slot);

      application.store_.machinesMut().update(slot, {.label = label, .destination = row.destination.view()});
      application.machines_.publishList();
    }

    static void recolor(qt::ApplicationController& application, Machines::Slot slot, std::string_view color) {
      const auto& row = application.store_.machines().row(slot);

      application.store_.machinesMut().update(slot, {.id = row.id, .label = row.label.view(), .destination = row.destination.view(), .color = color, .enabled = row.enabled, .program = row.program.view()});
      application.machines_.publishList();
    }

    static MachineClientKey reuse(qt::ApplicationController& application, Machines::Slot slot) {
      application.roster_.retire(slot, qt::MachineRoster::Retirement::removed);
      application.store_.clientsMut().atMut(slot).reset();
      application.store_.machinesMut().remove(slot);
      const auto added = application.store_.machinesMut().add({.label = "Replacement", .destination = "dev@replacement"}, slot);
      const auto key = application.machines_.createClient(added).key;

      application.machines_.publishList();

      return key;
    }

    static auto capture(qt::ApplicationController& application) {
      qt::FramePresenter::PresentedFrame frame;

      application.frames_.prepareFrame(frame);
      const auto* pane = application.session().focusedPane();
      if (pane != nullptr) {
        frame.pane_count = 1;
        frame.panes.atMut(0).frame.pane = {.pane_id = pane->id, .frame_id = pane->screen.frameId(), .attached = pane->attached, .attachment_generation = pane->attachment_generation};
      }

      return frame;
    }

    static void present(qt::ApplicationController& application, const auto& frame) {
      application.frames_.present(frame);
    }

    static MachineClientKey replace(qt::ApplicationController& application, Machines::Slot slot) {
      return application.machines_.createClient(slot).key;
    }

    static bool contains(const qt::ApplicationController& application, MachineClientKey key) {
      return application.machines_.findClient(key) != nullptr;
    }
  };

}

namespace {

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::plugins;
  using namespace telar::gui::features::machines;
  using namespace telar::gui::features::notifications;
  using namespace telar::gui::qt;
  using namespace telar::gui::test;

  constexpr int wait_ms = 5000;
  constexpr std::uint64_t pane_id = 1;
  constexpr TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};

  bool finishOpening(WireRuntime& runtime) {
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

    const ds::Array descriptors{PaneDescriptor{.pane_id = pane_id, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

    runtime.send(TabSnapshot{.request_id = runtime.last<RequestTabSnapshot>().request_id, .location = location, .panes = descriptors});
    const ds::Array tabs{TabDescriptor{.tab_id = location.tab_id, .pane_count = 1}};

    runtime.send(WorkspaceSnapshot{.request_id = runtime.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});

    return true;
  }

  void sendFrame(WireRuntime& runtime) {
    constexpr std::size_t cell_capacity = 64;
    const ds::Array cells{Cell{.text = byteView("X")}};
    ds::Array<Byte, cell_capacity> encoded{};
    const ds::Array spans{FrameSpan{.start = 0, .count = 1, .cells = CellRunCodec::encode(cells, encoded.viewMut())}};
    const ds::Array<Byte, 1> flags{};

    runtime.send(PaneFrame{FrameBody{.pane_id = pane_id, .frame_id = 1, .cols = 1, .rows = 1, .scroll = {.total_rows = 1}, .text_metadata = TextMetadata{.row_flags = flags}, .spans = spans}});
  }

#ifdef __APPLE__
  void sendAttachmentFrame(WireRuntime& runtime) {
    constexpr std::string_view marker = "[Image #1]";
    constexpr std::size_t columns = 12;
    constexpr std::size_t encoded_capacity = 512;
    ds::Array<Cell, columns> cells{};

    cells.fill(Cell{.text = byteView(" ")});
    for (std::size_t index = 0; index < marker.size(); ++index) {
      cells.atMut(index).text = byteView(marker.substr(index, 1));
    }

    ds::Array<Byte, encoded_capacity> encoded{};
    const ds::Array spans{FrameSpan{.start = 0, .count = cells.size(), .cells = CellRunCodec::encode(cells, encoded.viewMut())}};
    const ds::Array<Byte, 1> flags{};

    runtime.send(PaneFrame{FrameBody{.pane_id = pane_id, .frame_id = 2, .cols = columns, .rows = 1, .cursor = {.visible = true, .x = marker.size()}, .scroll = {.total_rows = 1}, .text_metadata = TextMetadata{.row_flags = flags}, .spans = spans}});
  }

  bool captureAttachmentImage(const QImage& image, const char* setting) {
    const auto path = qEnvironmentVariable(setting);

    return path.isEmpty() || image.save(path);
  }

  bool attachmentRendererMatchesRequest(const QQuickWindow& window) {
    const auto api = window.rendererInterface()->graphicsApi();

    qInfo() << "Attachment graphics API" << api;

    return qEnvironmentVariable("QSG_RHI_BACKEND") != QStringLiteral("metal") || api == QSGRendererInterface::Metal;
  }

#endif

  QVariantMap activityRow(ApplicationController& application, int row) {
    const auto* model = application.activity()->rows();

    return model->data(model->index(row, 0), ListModel::record_role).toMap();
  }

  QVariantMap activityNamed(ApplicationController& application, const QString& title) {
    for (int row = 0; row < application.activity()->rows()->rowCount(); ++row) {
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
    ApplicationMemory application_memory;
    ApplicationAllocator& memory = application_memory.memory();
    ApplicationController application{memory};
    MachineClientKey remote;
    std::unique_ptr<WireRuntime> local_runtime;
    std::unique_ptr<WireRuntime> remote_runtime;

    bool start() {
      if (!directory_.isValid() || !local_listener_.listen(directory_.filePath(QStringLiteral("local.sock"))) || !remote_listener_.listen(directory_.filePath(QStringLiteral("remote.sock")))) {
        return false;
      }

      application.machines()->open(local_listener_.fullServerName());
      if (!waitForGuiCondition([&] {
            return local_listener_.hasPendingConnections();
          },
              wait_ms)) {
        return false;
      }

      local_socket_.reset(local_listener_.nextPendingConnection());
      local_runtime = std::make_unique<WireRuntime>(*local_socket_);
      if (!waitForGuiCondition([&] {
            return application.status()->connected();
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
    MachineFixture(const MachineFixture&) = delete;
    MachineFixture& operator=(const MachineFixture&) = delete;
    MachineFixture(MachineFixture&&) = delete;
    MachineFixture& operator=(MachineFixture&&) = delete;

    QTemporaryDir directory_;
    QLocalServer local_listener_;
    QLocalServer remote_listener_;
    std::unique_ptr<QLocalSocket> local_socket_;
    std::unique_ptr<QLocalSocket> remote_socket_;
  };

  class MachineWindowTest : public QObject {
    Q_OBJECT

    Q_SLOT static void pluginCompletionStaysWithItsExecutionMachineAndRuntime() {
      MachineFixture fixture;

      QVERIFY(fixture.start());
      auto& application = fixture.application;
      const auto& local = MachineWindow::client(application, Machines::local_slot);
      constexpr std::uint64_t execution = 1;

      MachineWindow::armPlugin(application, local.key, execution, local.runtime_generation);
      MachineWindow::completePluginFailure(application, execution + 1);
      QVERIFY(MachineWindow::pendingPlugin(application));
      QCOMPARE(application.status()->error(), QString{});

      MachineWindow::select(application, fixture.remote.machine);
      MachineWindow::completePluginFailure(application, execution);
      QVERIFY(!MachineWindow::pendingPlugin(application));
      QCOMPARE(application.status()->error(), QString{});
      MachineWindow::select(application, local.key.machine);

      MachineWindow::armPlugin(application, local.key, execution, local.runtime_generation + 1);
      MachineWindow::completePluginFailure(application, execution);
      QVERIFY(!MachineWindow::pendingPlugin(application));
      QCOMPARE(application.status()->error(), QString{});

      const auto& remote = MachineWindow::client(application, fixture.remote.machine.slot);

      MachineWindow::armPlugin(application, remote.key, execution, remote.runtime_generation);
      const auto replacement = MachineWindow::replace(application, fixture.remote.machine.slot);

      MachineWindow::completePluginFailure(application, execution);
      QVERIFY(!MachineWindow::pendingPlugin(application));
      QCOMPARE(application.status()->error(), QString{});
      QVERIFY(replacement != fixture.remote);

      MachineWindow::armPlugin(application, local.key, execution, local.runtime_generation);
      MachineWindow::completePluginFailure(application, execution);
      QVERIFY(!MachineWindow::pendingPlugin(application));
      QCOMPARE(application.status()->error(), QStringLiteral("OwnedPluginFailure"));
    }

#ifdef __APPLE__
    Q_SLOT static void clipboardCaptureFinishesWhileLocalClientIsHidden() {
      PrivateClipboard board;
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      AttachmentShelf shelf{memory};
      const MachineClientKey key{.machine = {.generation = 1}, .generation = 1};
      const AttachmentPrompt prompt{.source = key, .runtime_generation = 1, .target = {.pane_id = pane_id, .pane_generation = 1}, .attachment_generation = 1};

      shelf.setSource({.source = key, .runtime_generation = 1});
      shelf.setPrompt(prompt);
      const QSignalSpy adopted{&shelf, &AttachmentShelf::adopted};
      QImage image{2, 3, QImage::Format_RGBA8888};

      image.fill(Qt::red);
      QByteArray png;
      QBuffer output{&png};

      QVERIFY(output.open(QIODevice::WriteOnly) && image.save(&output, "PNG"));
      board.setPng(std::as_bytes(std::span{png.constData(), static_cast<std::size_t>(png.size())}));
      shelf.requestCapture();
      shelf.setPrompt(prompt, false);
      QVERIFY(!shelf.prompt() && shelf.items().isEmpty());
      QTRY_COMPARE_WITH_TIMEOUT(adopted.count(), 1, wait_ms);
      QVERIFY(shelf.items().isEmpty());
      shelf.setPrompt(prompt);
      QCOMPARE(shelf.items().size(), 1);

      shelf.requestCapture();
      auto replacement = prompt;

      ++replacement.runtime_generation;
      shelf.setSource({.source = key, .runtime_generation = replacement.runtime_generation});
      shelf.setPrompt(replacement);
      shelf.requestCapture();
      QTRY_COMPARE_WITH_TIMEOUT(adopted.count(), 2, wait_ms);
      QCOMPARE(shelf.items().size(), 1);
      QCOMPARE(shelf.items().front().toMap().value(QStringLiteral("id")).toString(), QStringLiteral("3"));

      const QSignalSpy failed{&shelf, &AttachmentShelf::failed};
      constexpr std::string_view invalid = "invalid PNG";

      board.setPng(std::as_bytes(std::span{invalid.data(), invalid.size()}));
      shelf.requestCapture();
      shelf.setPrompt(replacement, false);
      QTRY_COMPARE_WITH_TIMEOUT(failed.count(), 1, wait_ms);
      QCOMPARE(adopted.count(), 2);
      shelf.setPrompt(replacement);
      QCOMPARE(shelf.items().size(), 1);
    }

    static void verifyAttachmentHoverReactivation(ApplicationController& application, QQuickWindow& window) {
      QVERIFY(!application.attachments()->shelf()->hoverReady());
      QTest::mouseMove(&window, window.contentItem()->boundingRect().topLeft().toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(application.attachments()->shelf()->hoverReady(), wait_ms);
    }

    static void verifyAttachmentModalHost(ApplicationController& application) {
      const auto modal_geometry = application.attachments()->modalGeometry();
      const auto modal_host = modal_geometry.value(QStringLiteral("host")).toRectF();
      const auto terminal_region = application.display()->geometry().value(QStringLiteral("terminal")).toRectF();

      QCOMPARE(modal_host.topLeft(), terminal_region.topLeft());
      QVERIFY(terminal_region.contains(modal_host));
      QVERIFY(modal_host.left() > 0 && modal_host.top() > 0);
      QVERIFY(modal_host.contains(modal_geometry.value(QStringLiteral("bounds")).toRectF()));
    }

    static void verifyAttachmentBackdropOwnership(ApplicationController& application, QQuickWindow& window, const QString& identity) {
      const auto host = application.attachments()->modalGeometry().value(QStringLiteral("host")).toRectF();
      const auto point = (host.topLeft() + QPointF{1, 1}).toPoint();
      const ds::Array buttons{Qt::LeftButton, Qt::RightButton, Qt::MiddleButton};

      for (const auto button : buttons) {
        application.attachments()->shelf()->open(identity);
        QTest::mousePress(&window, button, Qt::NoModifier, point);
        const bool held = !application.attachments()->shelf()->modal().isEmpty();

        QTest::mouseRelease(&window, button, Qt::NoModifier, point);
        const bool closed = application.attachments()->shelf()->modal().isEmpty();

        application.attachments()->shelf()->close();
        QVERIFY2(held, "A held backdrop press must retain the preview's modal input ownership");
        QCOMPARE(closed, button == Qt::LeftButton);
      }
    }

    Q_SLOT static void clipboardImagesReservePaneRowsAndOwnModalKeys() {
      PrivateClipboard board;
      MachineFixture fixture;
      auto& application = fixture.application;
      QQuickWindow window;
      constexpr QSize size{800, 600};

      window.resize(size);
      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      sendFrame(*fixture.local_runtime);
      auto agent = activityAgent("Clipboard");

      agent.attachments = AgentAttachmentMarkers::ordered;
      const ds::Array agents{agent};

      fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      QTRY_VERIFY_WITH_TIMEOUT(application.attachments()->shelf()->prompt().hasValue(), wait_ms);
      const auto before = application.panes()->rows()->data(application.panes()->rows()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("height")).toReal();

      QImage image{2, 3, QImage::Format_RGBA8888};

      image.fill(Qt::red);
      QByteArray png;
      QBuffer output{&png};

      QVERIFY(output.open(QIODevice::WriteOnly) && image.save(&output, "PNG"));
      board.setPng(std::as_bytes(std::span{png.constData(), static_cast<std::size_t>(png.size())}));
      TerminalItem terminal{window.contentItem()};

      terminal.setController(application.terminals());
      terminal.setPaneId(QString::number(pane_id));
      const auto previous_font = QGuiApplication::font();
      const auto restore_font = qScopeGuard([&] {
        QGuiApplication::setFont(previous_font);
      });

      QFont chrome_font{QStringLiteral("IBM Plex Sans")};
      constexpr int chrome_pixels = 13;

      chrome_font.setPixelSize(chrome_pixels);
      QGuiApplication::setFont(chrome_font);
      QQmlEngine engine;
      const QVariantMap properties{
          {QStringLiteral("controller"), QVariant::fromValue(application.attachments())},
          {QStringLiteral("colors"), application.colors()},
          {QStringLiteral("typography"), application.display()->geometry().value(QStringLiteral("typography"))},
      };

      auto shelf_properties = properties;

      shelf_properties.insert(QStringLiteral("ratio"), application.display()->chromeRatio());
      const auto shelf_view = createChrome(engine, QStringLiteral("AttachmentShelf"), shelf_properties);
      const auto modal_view = createChrome(engine, QStringLiteral("AttachmentModal"), properties);

      shelf_view->setParentItem(window.contentItem());
      modal_view->setParentItem(window.contentItem());
      modal_view->setSize(size);
      window.show();
      QVERIFY(QTest::qWaitForWindowExposed(&window, wait_ms));
      const auto ready = qEnvironmentVariable("TELAR_GUI_TEST_WINDOW_READY");
      if (!ready.isEmpty()) {
        QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(ready), wait_ms);
      }

      QVERIFY(waitForSynchronizedFrame(window, wait_ms));
      const auto previous_input = fixture.local_runtime->count(ClientTag::pane_input);
      QKeyEvent paste{QEvent::KeyPress, Qt::Key_V, NativeKeyAdapter::control_modifier};

      QCoreApplication::sendEvent(&terminal, &paste);
      QTRY_COMPARE_WITH_TIMEOUT(application.attachments()->shelf()->items().size(), 1, wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::pane_input), previous_input + 1, wait_ms);
      const auto delivered = fixture.local_runtime->last<PaneInput>();

      QCOMPARE(textView(delivered.bytes), std::string_view{"\x16"});
      QTRY_VERIFY_WITH_TIMEOUT(application.attachments()->geometry().value(QStringLiteral("height")).toReal() > 0, wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(shelf_view->isVisible(), wait_ms);
      QVERIFY(waitForSynchronizedFrame(window, wait_ms));
      const auto shelf_pixels = window.grabWindow();

      QVERIFY(!shelf_pixels.isNull());
      QVERIFY(attachmentRendererMatchesRequest(window));
      QVERIFY(captureAttachmentImage(shelf_pixels, "TELAR_GUI_TEST_ATTACHMENT_SHELF_CAPTURE"));
      const auto pointingAreas = [](QQuickItem& root) {
        const auto items = visualItems(root, QString{});

        return std::ranges::count_if(items, [](const QQuickItem* item) {
          return item->inherits("QQuickMouseArea") && item->cursor().shape() == Qt::PointingHandCursor;
        });
      };

      QCOMPARE(pointingAreas(*shelf_view), 2);
      QCOMPARE(pointingAreas(*modal_view), 1);
      const auto after = application.panes()->rows()->data(application.panes()->rows()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("height")).toReal();
      const auto rows = application.display()->geometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid")).toMap().value(QStringLiteral("cellHeight")).toReal();

      QCOMPARE(before - after, PaneBottomReservation::shelf_rows * rows);

      const auto identity = application.attachments()->shelf()->items().front().toMap().value(QStringLiteral("id")).toString();

      application.attachments()->shelf()->open(identity);
      QVERIFY(!application.attachments()->shelf()->modal().isEmpty());
      QTRY_VERIFY_WITH_TIMEOUT(modal_view->isVisible(), wait_ms);
      verifyAttachmentModalHost(application);
      QVERIFY(waitForSynchronizedFrame(window, wait_ms));
      const auto modal_pixels = window.grabWindow();

      QVERIFY(!modal_pixels.isNull() && modal_pixels != shelf_pixels);
      QVERIFY(captureAttachmentImage(modal_pixels, "TELAR_GUI_TEST_ATTACHMENT_MODAL_CAPTURE"));
      QKeyEvent blocked{QEvent::KeyPress, Qt::Key_X, Qt::NoModifier, QStringLiteral("x")};

      QVERIFY(application.commands()->handleKey(blocked, terminal));
      QKeyEvent escape{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier};

      QVERIFY(application.commands()->handleKey(escape, terminal));
      QVERIFY(application.attachments()->shelf()->modal().isEmpty());
      verifyAttachmentHoverReactivation(application, window);
      verifyAttachmentBackdropOwnership(application, window, identity);
      QCOMPARE(fixture.local_runtime->count(ClientTag::pane_input), previous_input + 1);

      sendAttachmentFrame(*fixture.local_runtime);
      QTRY_COMPARE_WITH_TIMEOUT(application.pane(pane_id)->screen.cursor().x, 10, wait_ms);
      application.attachments()->shelf()->dismiss(identity);
      QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::pane_input), previous_input + 2, wait_ms);
      QCOMPARE(textView(fixture.local_runtime->last<PaneInput>().bytes), std::string_view{"\x7f"});
      QTRY_VERIFY_WITH_TIMEOUT(application.attachments()->shelf()->items().isEmpty() && application.attachments()->geometry().isEmpty(), wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(application.panes()->rows()->data(application.panes()->rows()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("height")).toReal(), before, wait_ms);

      QCoreApplication::sendEvent(&terminal, &paste);
      QTRY_COMPARE_WITH_TIMEOUT(application.attachments()->shelf()->items().size(), 1, wait_ms);
      QKeyEvent submit{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier};

      QCoreApplication::sendEvent(&terminal, &submit);
      QTRY_VERIFY_WITH_TIMEOUT(application.attachments()->shelf()->items().isEmpty() && application.attachments()->geometry().isEmpty(), wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::pane_input), previous_input + 4, wait_ms);
      QCOMPARE(textView(fixture.local_runtime->last<PaneInput>().bytes), std::string_view{"\r"});
    }
#endif

    Q_SLOT static void attachmentShelfAndModalLoadFromTheRegisteredQmlModule() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController application{memory};
      QQuickWindow window;
      constexpr QSize size{800, 600};

      window.resize(size);
      application.setWindow(window);
      QQmlEngine engine;
      const QVariantMap properties{
          {QStringLiteral("controller"), QVariant::fromValue(application.attachments())},
          {QStringLiteral("colors"), application.colors()},
          {QStringLiteral("typography"), application.display()->geometry().value(QStringLiteral("typography"))},
      };

      auto shelf_properties = properties;

      shelf_properties.insert(QStringLiteral("ratio"), application.display()->chromeRatio());
      const auto shelf = createChrome(engine, QStringLiteral("AttachmentShelf"), shelf_properties);
      const auto modal = createChrome(engine, QStringLiteral("AttachmentModal"), properties);

      QVERIFY(shelf != nullptr && modal != nullptr);
      QVERIFY(!shelf->isVisible() && !modal->isVisible());
    }

    enum class TerminalStatus : std::uint8_t {
      stopping,
      last_tab,
      closed_workspace,
    };

    Q_SLOT static void terminalRemoteKeepsItsSummaryUntilReselection() {
      verifyTerminalSession(TerminalStatus::stopping, true);
    }

    Q_SLOT static void lastRemoteTabFinishesItsReceiveLoop() {
      verifyTerminalSession(TerminalStatus::last_tab, true);
    }

    Q_SLOT static void closedRemoteWorkspaceFinishesItsReceiveLoop() {
      verifyTerminalSession(TerminalStatus::closed_workspace, true);
    }

    Q_SLOT static void hiddenTerminalRemoteKeepsItsSummaryUntilSelection() {
      verifyTerminalSession(TerminalStatus::stopping, false);
    }

    static void verifyTerminalSession(TerminalStatus status, bool presented) {
      MachineFixture fixture;
      QQuickWindow window;
      constexpr QSize size{800, 600};

      window.resize(size);
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      if (presented) {
        MachineWindow::select(application, fixture.remote.machine);
        QVERIFY(finishOpening(*fixture.remote_runtime));
      }

      window.show();
      const auto& remote = MachineWindow::client(application, fixture.remote.machine.slot);
      constexpr std::uint8_t retained_cpu = 92;
      constexpr std::uint8_t trailing_cpu = 13;

      fixture.remote_runtime->send(hostSample(1, retained_cpu));
      QTRY_COMPARE_WITH_TIMEOUT(application::status_bar::metrics(remote.session).sample().cpu_percent, retained_cpu, wait_ms);
      switch (status) {
      case TerminalStatus::stopping:
        fixture.remote_runtime->send(RuntimeStopping{});
        break;
      case TerminalStatus::last_tab:
        fixture.remote_runtime->send(TabClosed{.location = location, .workspace_closed = true});
        break;
      case TerminalStatus::closed_workspace:
        fixture.remote_runtime->send(ResyncRequired{.workspace = location.workspace, .workspace_closed = true});
        break;
      }

      fixture.remote_runtime->send(hostSample(2, trailing_cpu));
      QTRY_VERIFY_WITH_TIMEOUT(!remote.session.ready(), wait_ms);
      QVERIFY(!remote.session.presented());
      QVERIFY(MachineWindow::client(application, Machines::local_slot).session.presented());
      QCOMPARE(remote.phase, MachinePhase::connected);
      QCOMPARE(application::status_bar::metrics(remote.session).sample().cpu_percent, retained_cpu);
      fixture.remote_runtime.reset();
      fixture.remote_socket_->disconnectFromServer();
      constexpr int observe_retry_ms = application::RuntimeLink::first_retry_ms * 2;

      QTest::qWait(observe_retry_ms);
      QCOMPARE(remote.phase, MachinePhase::connected);
      QVERIFY(!fixture.remote_listener_.hasPendingConnections());
      QVERIFY(window.isVisible());
      const auto identity = remote.identity;
      const auto generation = remote.runtime_generation;

      MachineWindow::select(application, fixture.remote.machine);
      QTRY_VERIFY_WITH_TIMEOUT(fixture.remote_listener_.hasPendingConnections(), wait_ms);
      fixture.remote_socket_.reset(fixture.remote_listener_.nextPendingConnection());
      fixture.remote_runtime = std::make_unique<WireRuntime>(*fixture.remote_socket_);
      QTRY_VERIFY_WITH_TIMEOUT(remote.session.ready(), wait_ms);
      QCOMPARE(remote.identity, identity);
      QVERIFY(remote.runtime_generation > generation);
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.remote_runtime));
      application.terminals()->input(pane_id, QByteArrayLiteral("REMOTE_AFTER_TERMINAL_STATUS"));
      QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::pane_input), 1, wait_ms);
      QCOMPARE(textView(fixture.remote_runtime->last<PaneInput>().bytes), std::string_view{"REMOTE_AFTER_TERMINAL_STATUS"});
      QCOMPARE(fixture.local_runtime->count(ClientTag::pane_input), 0);
    }

    Q_SLOT static void remoteRuntimeStoppingReturnsToLocalWithoutClosingWindow() {
      MachineFixture fixture;
      QQuickWindow window;
      constexpr QSize size{800, 600};

      window.resize(size);
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      MachineWindow::select(application, fixture.remote.machine);
      QVERIFY(finishOpening(*fixture.remote_runtime));
      window.show();
      fixture.remote_runtime->send(RuntimeStopping{});
      const auto& local = MachineWindow::client(application, Machines::local_slot).session;
      const auto& remote = MachineWindow::client(application, fixture.remote.machine.slot).session;

      QTRY_VERIFY_WITH_TIMEOUT(local.presented(), wait_ms);
      QVERIFY(!remote.presented());
      QVERIFY(!remote.ready());
      QVERIFY(window.isVisible());
      QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::open_pane), 2, wait_ms);
      const auto opening = fixture.local_runtime->last<OpenPane>();

      fixture.local_runtime->send(PaneOpened{.request_id = opening.request_id, .pane_id = pane_id, .location = location, .pane_generation = 1});
      QTRY_VERIFY_WITH_TIMEOUT(local.findPane(pane_id) != nullptr && local.findPane(pane_id)->attached, wait_ms);
      application.terminals()->input(pane_id, QByteArrayLiteral("LOCAL_AFTER_REMOTE_STOP"));
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
      auto& application = fixture.application;

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
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      window.show();
      fixture.remote_runtime->send(RuntimeStopping{});
      QTRY_VERIFY_WITH_TIMEOUT(!MachineWindow::client(application, fixture.remote.machine.slot).session.ready(), wait_ms);
      QVERIFY(MachineWindow::client(application, Machines::local_slot).session.presented());
      QVERIFY(window.isVisible());
      application.terminals()->input(pane_id, QByteArrayLiteral("LOCAL_WITH_HIDDEN_STOP"));
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
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      MachineWindow::select(application, fixture.remote.machine);
      QVERIFY(finishOpening(*fixture.remote_runtime));
      window.show();
      fixture.remote_socket_->disconnectFromServer();
      const auto& remote = MachineWindow::client(application, fixture.remote.machine.slot).session;

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
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      const QSignalSpy changed{application.status(), &WindowStatus::hostMetricsChanged};
      constexpr std::uint8_t local_cpu = 11;
      constexpr std::uint8_t remote_cpu = 92;
      constexpr std::uint8_t replacement_cpu = 37;
      constexpr std::uint64_t revision = 9;
      const auto percent = [&] {
        return application.status()->hostMetrics().value(QStringLiteral("cpu")).toMap().value(QStringLiteral("percent")).toInt();
      };

      fixture.local_runtime->send(hostSample(revision, local_cpu));
      QTRY_COMPARE_WITH_TIMEOUT(percent(), local_cpu, wait_ms);
      const auto local_changes = changed.size();
      const auto& remote = MachineWindow::client(application, fixture.remote.machine.slot);

      fixture.remote_runtime->send(hostSample(revision, remote_cpu));
      QTRY_COMPARE_WITH_TIMEOUT(application::status_bar::metrics(remote.session).sample().cpu_percent, remote_cpu, wait_ms);
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
      QVERIFY(!application.status()->hostMetrics().value(QStringLiteral("cpu")).toMap().value(QStringLiteral("available")).toBool());
      fixture.remote_runtime->send(hostSample(1, replacement_cpu));
      QTRY_COMPARE_WITH_TIMEOUT(percent(), replacement_cpu, wait_ms);
      MachineWindow::select(application, MachineWindow::client(application, Machines::local_slot).key.machine);
      QCOMPARE(percent(), local_cpu);
    }

    Q_SLOT static void machineListShowsOtherMachinesWithTheirAgentStack() {
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
      ds::Array agents{activityAgent("Remote waiting"), activityAgent("Remote working"), activityAgent("Remote idle")};

      agents.atMut(0).status = AgentStatus::blocked;
      agents.atMut(0).blocked_reason = AgentBlockedReason::question;
      agents.atMut(1).status = AgentStatus::working;
      agents.atMut(1).pane_id = 2;
      agents.atMut(2).status = AgentStatus::ready;
      agents.atMut(2).pane_id = 3;
      fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      constexpr qreal row_width = 300;
      constexpr qreal row_height = 32;
      auto chrome = createChrome(engine, QStringLiteral("MachineChrome"), {{QStringLiteral("controller"), QVariant::fromValue(fixture.application.machineChrome())}, {QStringLiteral("colors"), fixture.application.colors()}, {QStringLiteral("width"), row_width}, {QStringLiteral("height"), row_height}});

      chrome->setParentItem(window.contentItem());
      window.show();
      auto* layout = qobject_cast<MachineChromeLayout*>(chrome.get());

      QVERIFY(layout != nullptr);
      const auto row = [&] {
        return layout->items()->data(layout->items()->index(0, 0), ListModel::record_role).toMap();
      };

      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, wait_ms);
      QCOMPARE(row().value(QStringLiteral("text")).toString(), QStringLiteral("Build"));
      QTRY_COMPARE_WITH_TIMEOUT(row().value(QStringLiteral("cards")).toList().size(), 2, wait_ms);
      const auto cards = row().value(QStringLiteral("cards")).toList();

      QVERIFY2(!cards[0].toMap().value(QStringLiteral("attentionColor")).toString().isEmpty(), "the agent that waits goes in front, tinted");
      QVERIFY(cards[1].toMap().value(QStringLiteral("attentionColor")).toString().isEmpty());
      QVERIFY(cards[0].toMap().value(QStringLiteral("layer")).toInt() > cards[1].toMap().value(QStringLiteral("layer")).toInt());
      const auto preferred = layout->preferredWidth();

      QVERIFY(preferred > 0);
      chrome->setVisible(false);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 0, wait_ms);
      QCOMPARE(layout->preferredWidth(), preferred);
      chrome->setVisible(true);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, wait_ms);
      const auto bounds = row().value(QStringLiteral("bounds")).toRectF();

      QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, bounds.center().toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(MachineWindow::client(fixture.application, fixture.remote.machine.slot).session.presented(), wait_ms);
      QVERIFY(!MachineWindow::client(fixture.application, Machines::local_slot).session.presented());
      QTRY_VERIFY_WITH_TIMEOUT(row().value(QStringLiteral("text")).toString() != QStringLiteral("Build"), wait_ms);
    }

    Q_SLOT static void machineInlineFactsTrackHiddenSources() {
      QTest::failOnWarning(QRegularExpression{QStringLiteral("^qrc:.*")});
      MachineFixture fixture;
      QQuickWindow window;
      QQmlEngine engine;
      constexpr QSize size{640, 240};

      window.resize(size);
      auto& application = fixture.application;

      window.setColor(application.colors().value(QStringLiteral("panelBackground")).value<QColor>());
      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      constexpr qreal row_width = 600;
      constexpr qreal row_height = 26;
      auto chrome = createChrome(engine, QStringLiteral("MachineChrome"), {{QStringLiteral("controller"), QVariant::fromValue(application.machineChrome())}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("width"), row_width}, {QStringLiteral("height"), row_height}});

      chrome->setParentItem(window.contentItem());
      auto* layout = qobject_cast<MachineChromeLayout*>(chrome.get());

      QVERIFY(layout != nullptr);
      QVERIFY(layout->setProperty("inlineFacts", true));
      window.show();
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 2, wait_ms);
      const auto row = [&](int index) {
        return layout->items()->data(layout->items()->index(index, 0), ListModel::record_role).toMap();
      };

      constexpr std::uint8_t local_cpu = 11;
      constexpr std::uint8_t remote_cpu = 92;

      fixture.local_runtime->send(hostSample(1, local_cpu));
      fixture.remote_runtime->send(hostSample(1, remote_cpu));
      QTRY_COMPARE_WITH_TIMEOUT(row(0).value(QStringLiteral("cpu")).toString(), QStringLiteral("11%"), wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(row(1).value(QStringLiteral("cpu")).toString(), QStringLiteral("92%"), wait_ms);
      QCOMPARE(row(0).value(QStringLiteral("glyph")).toString(), QStringLiteral("●"));
      QCOMPARE(row(1).value(QStringLiteral("text")).toString(), QStringLiteral("Build"));
      QVERIFY(row(0).value(QStringLiteral("bold")).toBool());
      QVERIFY(!row(1).value(QStringLiteral("bold")).toBool());
      QVERIFY(!MachineWindow::client(application, fixture.remote.machine.slot).session.presented());
      layout->activate(row(1).value(QStringLiteral("key")).toString());
      QVERIFY(!MachineWindow::client(application, fixture.remote.machine.slot).session.presented());
      QVERIFY(layout->setProperty("inlineFacts", false));
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, wait_ms);
      QVERIFY(layout->setProperty("inlineFacts", true));
      QTRY_COMPARE_WITH_TIMEOUT(row(1).value(QStringLiteral("cpu")).toString(), QStringLiteral("92%"), wait_ms);
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_MACHINE_FACTS_SCREENSHOT");
      if (!screenshot.isEmpty()) {
        const auto ready = qEnvironmentVariable("TELAR_GUI_TEST_WINDOW_READY");
        if (!ready.isEmpty()) {
          QTRY_VERIFY_WITH_TIMEOUT(QFile::exists(ready), wait_ms);
        }

        QVERIFY(waitForSynchronizedFrame(window, wait_ms));
        QVERIFY(window.grabWindow().save(screenshot, "PNG"));
      }

      const QTemporaryDir theme_directory;

      QVERIFY(theme_directory.isValid());
      const auto theme_path = theme_directory.filePath(QStringLiteral("config.lua"));
      QFile theme_file{theme_path};

      QVERIFY(theme_file.open(QIODevice::WriteOnly));
      const QByteArray theme_source{"return {api_version=2,theme={colors={green='default'}}}"};

      QCOMPARE(theme_file.write(theme_source), theme_source.size());
      theme_file.close();
      application.loadConfiguration(theme_path, {}, {});
      QVERIFY2(application.status()->error().isEmpty(), qPrintable(application.status()->error()));
      const auto default_ink = application.colors().value(QStringLiteral("green")).value<QColor>();

      QVERIFY(default_ink.alpha() > 0);
      QTRY_COMPARE_WITH_TIMEOUT(row(0).value(QStringLiteral("ink")).value<QColor>(), default_ink, wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(row(1).value(QStringLiteral("ink")).value<QColor>(), default_ink, wait_ms);
      const auto default_screenshot = qEnvironmentVariable("TELAR_GUI_TEST_MACHINE_DEFAULT_INK_SCREENSHOT");
      if (!default_screenshot.isEmpty()) {
        QVERIFY(waitForSynchronizedFrame(window, wait_ms));
        QVERIFY(window.grabWindow().save(default_screenshot, "PNG"));
      }

      fixture.remote_listener_.close();
      fixture.remote_socket_->disconnectFromServer();
      QTRY_VERIFY_WITH_TIMEOUT(!MachineWindow::client(application, fixture.remote.machine.slot).session.ready(), wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(row(1).value(QStringLiteral("glyph")).toString(), QStringLiteral("✕"), wait_ms);
      QCOMPARE(row(1).value(QStringLiteral("cpu")).toString(), QString{});
      const auto preferred = layout->preferredWidth();

      QVERIFY(preferred > 0);
      chrome->setVisible(false);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 0, wait_ms);
      QCOMPARE(layout->preferredWidth(), preferred);
      chrome->setVisible(true);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 2, wait_ms);
      QCOMPARE(row(1).value(QStringLiteral("cpu")).toString(), QString{});
    }

    Q_SLOT static void machineSegmentCarriesAttentionAndProfileInk() {
      MachineFixture fixture;
      QQuickWindow window;
      QQmlEngine engine;
      constexpr QSize size{400, 240};

      window.resize(size);
      fixture.application.setWindow(window);
      QVERIFY(fixture.start());
      const ds::Array agents{activityAgent("Remote waiting")};
      auto blocked = agents;

      blocked.atMut(0).status = AgentStatus::blocked;
      blocked.atMut(0).blocked_reason = AgentBlockedReason::question;
      fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = blocked});
      constexpr qreal segment_width = 200;
      constexpr qreal segment_height = 26;
      auto chrome = createChrome(engine, QStringLiteral("MachineChrome"), {{QStringLiteral("controller"), QVariant::fromValue(fixture.application.machineChrome())}, {QStringLiteral("colors"), fixture.application.colors()}, {QStringLiteral("width"), segment_width}, {QStringLiteral("height"), segment_height}});

      chrome->setParentItem(window.contentItem());
      auto* layout = qobject_cast<MachineChromeLayout*>(chrome.get());

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
      const auto preferred = layout->preferredWidth();

      chrome->setVisible(false);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 0, wait_ms);
      QCOMPARE(layout->preferredWidth(), preferred);
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
      constexpr qreal row_height = 32;
      auto chrome = createChrome(engine, QStringLiteral("MachineChrome"), {{QStringLiteral("controller"), QVariant::fromValue(fixture.application.machineChrome())}, {QStringLiteral("colors"), fixture.application.colors()}, {QStringLiteral("width"), row_width}, {QStringLiteral("height"), row_height}});

      chrome->setParentItem(window.contentItem());
      window.show();
      auto* layout = qobject_cast<MachineChromeLayout*>(chrome.get());

      QVERIFY(layout != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, wait_ms);
      const auto remote_key = [&] {
        return layout->items()->data(layout->items()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString();
      };

      const auto retired = remote_key();
      const auto bounds = layout->items()->data(layout->items()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("bounds")).toRectF();

      QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, bounds.center().toPoint());
      const auto admitted = MachineWindow::reuse(fixture.application, fixture.remote.machine.slot);

      QTRY_VERIFY_WITH_TIMEOUT(remote_key() != retired, wait_ms);
      QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, bounds.center().toPoint());
      QVERIFY(fixture.application.status()->connected());
      QVERIFY(!MachineWindow::client(fixture.application, admitted.machine.slot).session.presented());
      layout->activate(retired);
      QVERIFY(fixture.application.status()->connected());
      QVERIFY(!MachineWindow::client(fixture.application, admitted.machine.slot).session.presented());
      fixture.application.setWindow(replacement);
      layout->activate(remote_key());
      QVERIFY(fixture.application.status()->connected());
      QVERIFY(!MachineWindow::client(fixture.application, admitted.machine.slot).session.presented());
      fixture.application.setWindow(window);
      layout->activate(remote_key());
      QVERIFY(MachineWindow::client(fixture.application, admitted.machine.slot).session.presented());
      QVERIFY(!fixture.application.status()->connected());
    }

    Q_SLOT static void activityButtonsRoutePrimaryAndSecondaryOnPress() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController application{memory};
      QQuickWindow window;
      QQmlEngine engine;
      constexpr QSize size{400, 240};

      window.resize(size);
      application.setWindow(window);
      const auto geometry = application.sidebar()->regions().value(QStringLiteral("cards")).toMap();
      QVariantMap record{{QStringLiteral("key"), QStringLiteral("owned")}, {QStringLiteral("enabled"), true}, {QStringLiteral("selected"), false}, {QStringLiteral("depth"), 0}, {QStringLiteral("command"), false}};
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
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      constexpr std::uint64_t inspected_pane = 9;
      auto agent = activityAgent("Remote inspected");

      agent.pane_id = inspected_pane;
      agent.session_id.atMut(0) = 1;
      // Another machine lists only the agents that wait on the person.
      agent.status = AgentStatus::blocked;
      agent.blocked_reason = AgentBlockedReason::question;
      ds::Array agents{agent};

      fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 1, wait_ms);
      const auto key = activityRow(application, 0).value(QStringLiteral("key")).toString();

      application.commands()->peekActivity(key);
      QVERIFY(MachineWindow::pendingActivity(application));
      QVERIFY(finishOpening(*fixture.remote_runtime));
      QTRY_COMPARE_WITH_TIMEOUT(application.dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::peek, wait_ms);
      QCOMPARE(application.activity()->hovered(), key);
      QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::read_pane), 1, wait_ms);
      QCOMPARE(fixture.local_runtime->count(ClientTag::read_pane), 0);
      QVERIFY(MachineWindow::client(application, fixture.remote.machine.slot).session.findPane(inspected_pane) == nullptr);
      const auto read = fixture.remote_runtime->last<ReadPane>();

      QCOMPARE(read.pane_id, inspected_pane);
      fixture.remote_runtime->send(PaneText{.request_id = read.request_id, .pane_id = inspected_pane, .text = "OWNED_REMOTE_PEEK", .exit_code = {}});
      QTRY_VERIFY_WITH_TIMEOUT(application.peek()->state().value(QStringLiteral("lines")).toStringList().contains(QStringLiteral("OWNED_REMOTE_PEEK")), wait_ms);
      const auto bounds = application.peek()->geometry().value(QStringLiteral("bounds")).toRectF();
      auto panel = createChrome(engine, QStringLiteral("PeekPanel"), {{QStringLiteral("controller"), QVariant::fromValue(application.peek())}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("typography"), application.display()->geometry().value(QStringLiteral("typography"))}, {QStringLiteral("width"), bounds.width()}, {QStringLiteral("height"), bounds.height()}});

      panel->setParentItem(window.contentItem());
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.activeFocusItem() != nullptr && window.activeFocusItem()->objectName() == QStringLiteral("commandSearch"), wait_ms);
      QTest::mouseMove(&window, QPoint{});
      QTRY_VERIFY_WITH_TIMEOUT(application.activity()->hovered().isEmpty(), wait_ms);
      for (const auto byte : std::string_view{"Continue the remote task"}) {
        QTest::keyClick(&window, byte);
      }

      QTRY_COMPARE_WITH_TIMEOUT(application.peek()->state().value(QStringLiteral("editorText")).toString(), QStringLiteral("Continue the remote task"), wait_ms);
      QTest::keyClick(&window, Qt::Key_Return);
      QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::send_pane_text), 1, wait_ms);
      const auto message = fixture.remote_runtime->last<SendPaneText>();

      QCOMPARE(message.pane_id, inspected_pane);
      QCOMPARE(message.mode, PaneTextMode::prompt);
      QCOMPARE(message.text, "Continue the remote task");
      QCOMPARE(fixture.local_runtime->count(ClientTag::send_pane_text), 0);
      QCOMPARE(application.dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      panel.reset();
      fixture.remote_runtime->send(RequestCompleted{.request_id = message.request_id});
      QTRY_VERIFY_WITH_TIMEOUT(!MachineWindow::client(application, fixture.remote.machine.slot).session.requestsPending(), wait_ms);
      application.commands()->peekActivity(key);
      QTRY_COMPARE_WITH_TIMEOUT(application.dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::peek, wait_ms);
      const auto stale_revision = application.peek()->state().value(QStringLiteral("revision")).toString();

      QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::read_pane), 2, wait_ms);
      const auto retired = fixture.remote_runtime->last<ReadPane>();

      ++agents.atMut(0).session_id.atMut(0);
      fixture.remote_runtime->send(AgentSnapshot{.revision = 2, .entries = agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none, wait_ms);
      application.peek()->search(QStringLiteral("/stop"));
      application.peek()->submit(stale_revision);
      QCOMPARE(fixture.remote_runtime->count(ClientTag::interrupt_agent), 0);
      fixture.remote_runtime->send(PaneText{.request_id = retired.request_id, .pane_id = inspected_pane, .text = "RETIRED_PEEK", .exit_code = {}});
      QVERIFY(application.peek()->state().value(QStringLiteral("lines")).toStringList().isEmpty());
    }

    Q_SLOT static void peekSubmissionsRejectRetiredWindowsAndDialogRevisions() {
      MachineFixture fixture;
      QQuickWindow window;
      QQuickWindow replacement;
      constexpr QSize size{800, 600};

      window.resize(size);
      replacement.resize(size);
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      const ds::Array agents{activityAgent("Local inspected")};

      fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 1, wait_ms);
      const auto key = activityRow(application, 0).value(QStringLiteral("key")).toString();

      application.commands()->peekActivity(key);
      QCOMPARE(application.dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::peek);
      const auto retired = application.peek()->state().value(QStringLiteral("revision")).toString();

      QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::read_pane), 1, wait_ms);
      const auto retired_read = fixture.local_runtime->last<ReadPane>();

      application.setWindow(replacement);
      QCOMPARE(application.dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      application.peek()->search(QStringLiteral("/stop"));
      application.peek()->submit(retired);
      QCOMPARE(fixture.local_runtime->count(ClientTag::interrupt_agent), 0);
      fixture.local_runtime->send(PaneText{.request_id = retired_read.request_id, .pane_id = pane_id, .text = "Retired window", .exit_code = {}});
      QTRY_VERIFY_WITH_TIMEOUT(!MachineWindow::client(application, Machines::local_slot).session.requestsPending(), wait_ms);
      application.setWindow(window);
      application.commands()->peekActivity(key);
      QCOMPARE(application.dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::peek);
      application.peek()->search(QStringLiteral("/stop"));
      application.peek()->submit(retired);
      QCOMPARE(fixture.local_runtime->count(ClientTag::interrupt_agent), 0);
      application.peek()->submit(application.peek()->state().value(QStringLiteral("revision")).toString());
      QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::interrupt_agent), 1, wait_ms);
      QCOMPARE(fixture.local_runtime->last<InterruptAgent>().pane_id, pane_id);
    }

    Q_SLOT static void aPointerMoveWhilePeekWaitsDoesNotRestoreOldHover() {
      MachineFixture fixture;
      QQuickWindow window;
      constexpr QSize size{800, 600};

      window.resize(size);
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      ds::Array agents{activityAgent("Remote inspected")};

      // Another machine lists only the agents that wait on the person.
      agents.atMut(0).status = AgentStatus::blocked;
      fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 1, wait_ms);
      application.commands()->peekActivity(activityRow(application, 0).value(QStringLiteral("key")).toString());
      QVERIFY(MachineWindow::pendingActivity(application));
      MachineWindow::pointerMoved(application);
      QVERIFY(finishOpening(*fixture.remote_runtime));
      QTRY_COMPARE_WITH_TIMEOUT(application.dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::peek, wait_ms);
      QVERIFY(application.activity()->hovered().isEmpty());
    }

    Q_SLOT static void restoredRootReceivesTheLatestWindowAndSidebarGeometry() {
      verifyRestoredRootGeometry(false);
    }

    Q_SLOT static void hiddenRestoredRootReceivesTheLatestWindowAndSidebarGeometry() {
      verifyRestoredRootGeometry(true);
    }

    static void verifyRestoredRootGeometry(bool hidden_remote) {
      const auto external_window_ready = qEnvironmentVariable("TELAR_GUI_TEST_WINDOW_READY");
      if (!external_window_ready.isEmpty()) {
        static_cast<void>(QFile::remove(external_window_ready));
      }

      MachineFixture fixture;
      auto& application = fixture.application;
      QQmlApplicationEngine engine;

      engine.rootContext()->setContextProperty(QStringLiteral("telar"), &application);
      const QSignalSpy warnings{&engine, &QQmlEngine::warnings};

      engine.loadFromModule(QStringLiteral("Telar.Gui"), QStringLiteral("Main"));
      QCOMPARE(engine.rootObjects().size(), 1);
      auto* window = qobject_cast<QQuickWindow*>(engine.rootObjects().front());

      QVERIFY(window != nullptr);
      constexpr QSize original_size{1200, 800};
      constexpr QSize latest_size{900, 600};

      window->resize(original_size);
      application.setWindow(*window);
      if (!external_window_ready.isEmpty()) {
        QTRY_VERIFY2_WITH_TIMEOUT(QFileInfo::exists(external_window_ready), "External native window setup did not complete", wait_ms);
        QVERIFY(waitForSynchronizedFrame(*window, wait_ms));
        window->resize(original_size);
      }

      QVERIFY(fixture.start());
      if (hidden_remote) {
        fixture.local_runtime->send(ClientLayoutSnapshot{});
        QVERIFY(finishOpening(*fixture.local_runtime));
      } else {
        fixture.remote_runtime->send(ClientLayoutSnapshot{});
      }

      auto& runtime = hidden_remote ? *fixture.remote_runtime : *fixture.local_runtime;
      const auto slot = hidden_remote ? fixture.remote.machine.slot : Machines::local_slot;
      auto& session = MachineWindow::client(application, slot).session;
      const ds::Array<ClientLayoutNode, 1> nodes{ClientLayoutPane{pane_id}};
      const ds::Array layouts{ClientTabLayout{.location = location, .focused_pane = pane_id, .workspace_active = true, .nodes = nodes}};
      constexpr std::uint16_t restored_sidebar_columns = 32;

      runtime.send(ClientLayoutSnapshot{.restored = true, .sidebar_visible = false, .sidebar_width = restored_sidebar_columns, .active_tab = location, .tabs = layouts});
      if (hidden_remote) {
        QTRY_VERIFY_WITH_TIMEOUT(!session.configuration().sidebar_visible, wait_ms);
        QCOMPARE(runtime.count(ClientTag::open_pane), 0);
        QVERIFY(application.pane(pane_id) != nullptr && application.pane(pane_id)->attached);
        MachineWindow::select(application, fixture.remote.machine);
      }

      QTRY_COMPARE_WITH_TIMEOUT(runtime.count(ClientTag::open_pane), 1, wait_ms);
      QVERIFY(!application.display()->sidebarVisible());
      const auto opening = runtime.last<OpenPane>();

      QVERIFY(!opening.launch);
      window->resize(latest_size);
      application.commands()->execute(window_actions::Action::toggle_sidebar);
      QTRY_COMPARE_WITH_TIMEOUT(application.display()->geometry().value(QStringLiteral("navigation")).toRectF().width(), latest_size.width(), wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(application.display()->geometry().value(QStringLiteral("status")).toRectF().bottom(), latest_size.height(), wait_ms);
      const auto geometry_changed = [&] {
        const auto size = application::workbench::geometry(session).launchSize();

        return size && (size->cols != opening.size.cols || size->rows != opening.size.rows);
      };

      QTRY_VERIFY2_WITH_TIMEOUT(geometry_changed(), qPrintable(QStringLiteral("window=%1x%2 open=%3x%4 area=%5x%6").arg(window->width()).arg(window->height()).arg(opening.size.cols).arg(opening.size.rows).arg(application::workbench::geometry(session).area.width).arg(application::workbench::geometry(session).area.height)), wait_ms);
      QVERIFY(application.display()->sidebarVisible());
      const auto terminal = application.display()->geometry().value(QStringLiteral("terminal")).toRectF();

      QCOMPARE(application::workbench::geometry(session).area.width, terminal.width() * window->effectiveDevicePixelRatio());
      QCOMPARE(application::workbench::geometry(session).area.height, terminal.height() * window->effectiveDevicePixelRatio());
      const auto expected = application::workbench::geometry(session).launchSize();

      QVERIFY(expected.hasValue());
      QVERIFY(expected->cols != opening.size.cols || expected->rows != opening.size.rows);
      QVERIFY(finishOpening(runtime));
      QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr && application.pane(pane_id)->attached, wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(application.pane(pane_id)->size.cols, expected->cols, wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(application.pane(pane_id)->size.rows, expected->rows, wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(runtime.count(ClientTag::pane_resize) != 0, wait_ms);
      const auto resized = runtime.last<PaneResize>();

      QCOMPARE(resized.size.cols, expected->cols);
      QCOMPARE(resized.size.rows, expected->rows);
      QCOMPARE(resized.size.cell_width_px, expected->cell_width_px);
      QCOMPARE(resized.size.cell_height_px, expected->cell_height_px);
      QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), hidden_remote ? 1 : 0);
      QCOMPARE(fixture.local_runtime->count(ClientTag::open_pane), 1);
      QCOMPARE(warnings.count(), 0);
      QCOMPARE(application.status()->error(), QString{});
    }

    Q_SLOT static void activityHoverChangesOnlyDuringDeliveredPointerInput() {
      MachineFixture fixture;
      QQuickWindow window;
      constexpr QSize size{800, 600};

      window.resize(size);
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      ds::Array local_agents{activityAgent("Local hover")};

      local_agents.atMut(0).session_id.atMut(0) = 1;
      ds::Array remote_agents{activityAgent("Remote hover")};

      remote_agents.atMut(0).session_id.atMut(0) = 2;
      // Another machine lists only the agents that wait on the person.
      remote_agents.atMut(0).status = AgentStatus::blocked;
      fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = local_agents});
      fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = remote_agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 2, wait_ms);
      const auto local = activityNamed(application, QStringLiteral("Local hover")).value(QStringLiteral("key")).toString();
      const auto remote = activityNamed(application, QStringLiteral("Remote hover")).value(QStringLiteral("key")).toString();

      application.activity()->hover(local);
      QVERIFY(application.activity()->hovered().isEmpty());
      MachineWindow::pointerMoved(application);
      application.activity()->hover(local);
      QCOMPARE(application.activity()->hovered(), local);
      QCoreApplication::processEvents();
      application.activity()->hover(remote);
      application.activity()->hover(QString{});
      QCOMPARE(application.activity()->hovered(), local);
      MachineWindow::pointerMoved(application);
      application.activity()->hover(remote);
      QCOMPARE(application.activity()->hovered(), remote);
      QCoreApplication::processEvents();
      MachineWindow::pointerMoved(application);
      application.activity()->hover(QStringLiteral("retired-activity"));
      QTRY_VERIFY_WITH_TIMEOUT(application.activity()->hovered().isEmpty(), wait_ms);
      MachineWindow::pointerMoved(application);
      application.activity()->hover(local);
      application.activity()->hover(QString{});
      QVERIFY(application.activity()->hovered().isEmpty());
    }

    Q_SLOT static void activityHoverRejectsCardsOutsideDeliveredPointer() {
      constexpr QSize window_size{800, 600};
      constexpr QPointF card_origin{20, 40};
      constexpr QSizeF clip_size{80, 80};
      constexpr QSizeF card_size{120, 80};
      constexpr QPointF clipped_pointer{130, 60};
      constexpr QPointF visible_pointer{30, 60};
      constexpr qreal moved_card_x = 200;
      constexpr QPointF moved_pointer{210, 60};
      constexpr QPointF terminal_pointer{600, 300};
      MachineFixture fixture;
      QQuickWindow window;

      window.resize(window_size);
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      ds::Array agents{activityAgent("Pointer geometry")};

      agents.atMut(0).session_id.atMut(0) = 1;
      fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 1, wait_ms);
      const auto identity = activityNamed(application, QStringLiteral("Pointer geometry")).value(QStringLiteral("key")).toString();

      QQuickItem clipper{window.contentItem()};

      clipper.setPosition(card_origin);
      clipper.setSize(clip_size);
      clipper.setClip(true);
      QQuickItem card{&clipper};

      card.setSize(card_size);
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);

      MachineWindow::pointerMoved(application, clipped_pointer);
      application.activity()->hover(identity, &card);
      QTRY_VERIFY_WITH_TIMEOUT(application.activity()->hovered().isEmpty(), wait_ms);
      MachineWindow::pointerMoved(application, visible_pointer);
      application.activity()->hover(identity, &card);
      QCOMPARE(application.activity()->hovered(), identity);
      QCoreApplication::processEvents();

      clipper.setX(moved_card_x);
      MachineWindow::pointerMoved(application, visible_pointer);
      application.activity()->hover(identity, &card);
      QTRY_VERIFY_WITH_TIMEOUT(application.activity()->hovered().isEmpty(), wait_ms);
      MachineWindow::pointerMoved(application, moved_pointer);
      application.activity()->hover(identity, &card);
      QCOMPARE(application.activity()->hovered(), identity);

      const QQuickWindow foreign_window;
      QQuickItem foreign_card{foreign_window.contentItem()};

      application.activity()->hover(QString{}, &foreign_card);
      QCOMPARE(application.activity()->hovered(), identity);

      QQuickItem peer_card{&clipper};

      peer_card.setSize(card_size);
      application.activity()->hover(identity, &peer_card);
      application.activity()->hover(identity, &card);
      QCoreApplication::processEvents();
      application.activity()->hover(QString{}, &peer_card);
      QCOMPARE(application.activity()->hovered(), identity);

      card.setParentItem(nullptr);
      application.activity()->hover(QString{}, &card);
      QVERIFY(application.activity()->hovered().isEmpty());
      card.setParentItem(&clipper);
      QCoreApplication::processEvents();

      MachineWindow::pointerMoved(application, terminal_pointer);
      application.activity()->hover(identity, &card);
      QTRY_VERIFY_WITH_TIMEOUT(application.activity()->hovered().isEmpty(), wait_ms);
      application.activity()->hover(identity, &card);
      QVERIFY(application.activity()->hovered().isEmpty());
    }

    Q_SLOT static void resizingPeekShowsTheRecentTailAndRetiresItsHiddenEditor() {
      MachineFixture fixture;
      QQuickWindow window;
      QQmlEngine engine;
      constexpr QSize wide{800, 600};
      constexpr QSize narrow{800, 300};
      constexpr QSize tiny{800, 80};

      window.resize(wide);
      auto& application = fixture.application;

      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      const ds::Array agents{activityAgent("Local inspected")};

      fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 1, wait_ms);
      application.commands()->peekActivity(activityRow(application, 0).value(QStringLiteral("key")).toString());
      QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::read_pane), 1, wait_ms);
      const auto read = fixture.local_runtime->last<ReadPane>();

      fixture.local_runtime->send(PaneText{.request_id = read.request_id, .pane_id = pane_id, .text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\nRECENT_TAIL", .exit_code = {}});
      constexpr qsizetype line_count = 11;

      QTRY_COMPARE_WITH_TIMEOUT(application.peek()->state().value(QStringLiteral("lines")).toStringList().size(), line_count, wait_ms);
      const auto bounds = application.peek()->geometry().value(QStringLiteral("bounds")).toRectF();
      auto panel = createChrome(engine, QStringLiteral("PeekPanel"), {{QStringLiteral("controller"), QVariant::fromValue(application.peek())}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("typography"), application.display()->geometry().value(QStringLiteral("typography"))}, {QStringLiteral("width"), bounds.width()}, {QStringLiteral("height"), bounds.height()}});

      panel->setParentItem(window.contentItem());
      const auto lines = [&] {
        return panel->property("state").toMap().value(QStringLiteral("lines")).toStringList();
      };

      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.activeFocusItem() != nullptr && window.activeFocusItem()->objectName() == QStringLiteral("commandSearch"), wait_ms);
      const auto* editor = window.activeFocusItem();

      window.resize(narrow);
      QTRY_VERIFY_WITH_TIMEOUT(lines().size() < line_count, wait_ms);
      QVERIFY(!lines().isEmpty());
      QCOMPARE(lines().back(), QStringLiteral("RECENT_TAIL"));
      window.resize(wide);
      QTRY_COMPARE_WITH_TIMEOUT(lines().size(), line_count, wait_ms);
      window.resize(tiny);
      QTRY_VERIFY2_WITH_TIMEOUT(!editor->isEnabled() && !editor->hasActiveFocus(), qPrintable(QStringLiteral("window=%1x%2 field=%3x%4 enabled=%5 focused=%6 owner=%7 dialog=%8 model=%9 qml=%10").arg(window.width()).arg(window.height()).arg(editor->width()).arg(editor->height()).arg(editor->isEnabled()).arg(editor->hasActiveFocus()).arg(window.activeFocusItem() == nullptr ? QStringLiteral("none") : window.activeFocusItem()->objectName()).arg(static_cast<int>(application.dialogs()->kind())).arg(application.peek()->geometry().value(QStringLiteral("field")).toRectF().height()).arg(panel->property("regions").toMap().value(QStringLiteral("field")).toRectF().height())), wait_ms);
      // The panel asks to close; the window, here the test, runs the cancel.
      const QSignalSpy cancelled{panel.get(), SIGNAL(cancelled())};

      QTest::keyClick(&window, Qt::Key_Escape);
      QTRY_COMPARE_WITH_TIMEOUT(cancelled.count(), 1, wait_ms);
      application.commands()->execute(window_actions::Action::cancel);
      QTRY_VERIFY_WITH_TIMEOUT((application.dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::none), wait_ms);
    }

    Q_SLOT static void activityCombinesSourcesWithoutOpeningHiddenScreens() {
      MachineFixture fixture;

      QVERIFY(fixture.start());
      auto& application = fixture.application;
      const auto& remote = MachineWindow::client(application, fixture.remote.machine.slot);

      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr && application.pane(pane_id)->attached, wait_ms);
      ds::Array local_agents{activityAgent("Local agent")};

      local_agents.atMut(0).session_id.atMut(0) = 1;
      ds::Array remote_agents{activityAgent("Remote agent")};

      remote_agents.atMut(0).session_id.atMut(0) = 2;
      // Another machine lists only the agents that wait on the person.
      remote_agents.atMut(0).status = AgentStatus::blocked;
      const ds::Array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project", .branch = "own-branch"}, WorkspaceListEntry{.workspace = 2, .name = "command", .path = "/command"}};
      ds::Array local_tasks{worktreeEntry()};

      local_tasks.atMut(0).title = "Local command";
      local_tasks.atMut(0).command_state = CommandState::running;
      ds::Array remote_tasks{local_tasks.front()};

      remote_tasks.atMut(0).title = "Remote command";
      remote_tasks.atMut(0).created_by.reset();
      remote_tasks.atMut(0).coordinator = coordinatorReference(pane_id);
      fixture.local_runtime->send(WorkspaceList{.revision = 1, .entries = projects, .worktrees = local_tasks});
      fixture.remote_runtime->send(WorkspaceList{.revision = 1, .entries = projects, .worktrees = remote_tasks});
      fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = local_agents});
      fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = remote_agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 3, wait_ms);
      const auto local = activityNamed(application, QStringLiteral("Local agent"));
      const auto hidden = activityNamed(application, QStringLiteral("Remote agent"));

      QVERIFY(local.value(QStringLiteral("selected")).toBool());
      QVERIFY(!hidden.value(QStringLiteral("selected")).toBool());
      QVERIFY(hidden.value(QStringLiteral("project")).toString().contains(QStringLiteral("Build")));
      QVERIFY(local.value(QStringLiteral("key")) != hidden.value(QStringLiteral("key")));
      QVERIFY2(activityNamed(application, QStringLiteral("Remote command")).isEmpty(), "another machine's tracked commands stay on that machine");
      QVERIFY(!activityNamed(application, QStringLiteral("Local command")).isEmpty());
      QVERIFY(application.status()->connected());
      QVERIFY(remote.session.panes().empty());
      QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 0);
      QCOMPARE(fixture.remote_runtime->count(ClientTag::acknowledge_agent), 0);
      const auto rebuilds = MachineWindow::activityRebuilds(application);
      constexpr std::size_t unchanged_refreshes = 256;

      for (std::size_t iteration = 0; iteration < unchanged_refreshes; ++iteration) {
        MachineWindow::refreshActivity(application);
        QCOMPARE(MachineWindow::activityRebuilds(application), rebuilds);
      }

      remote_agents.atMut(0).session_title = "Remote still waiting";
      fixture.remote_runtime->send(AgentSnapshot{.revision = 2, .entries = remote_agents});
      QTRY_VERIFY_WITH_TIMEOUT(!activityNamed(application, QStringLiteral("Remote still waiting")).isEmpty(), wait_ms);
      QVERIFY(remote.session.panes().empty());
      QCOMPARE(fixture.remote_runtime->count(ClientTag::acknowledge_agent), 0);
      const auto identity = hidden.value(QStringLiteral("key"));

      MachineWindow::rename(application, fixture.remote.machine.slot, "Renamed");
      QTRY_VERIFY_WITH_TIMEOUT(activityNamed(application, QStringLiteral("Remote still waiting")).value(QStringLiteral("project")).toString().contains(QStringLiteral("Renamed")), wait_ms);
      QCOMPARE(activityNamed(application, QStringLiteral("Remote still waiting")).value(QStringLiteral("key")), identity);
      fixture.remote_socket_->disconnectFromServer();
      QTRY_VERIFY_WITH_TIMEOUT(!activityNamed(application, QStringLiteral("Remote still waiting")).value(QStringLiteral("enabled")).toBool(), wait_ms);
      QCOMPARE(activityNamed(application, QStringLiteral("Remote still waiting")).value(QStringLiteral("statusWord")).toString(), QStringLiteral("offline"));
      application.commands()->execute(window_actions::Action::select_agent, identity.toString());
      QVERIFY(application.status()->connected());
      QCOMPARE(application.pane(pane_id)->attached, true);
    }

    Q_SLOT static void activityRejectsReusedSessionsAndWaitsForCanonicalSnapshots() {
      MachineFixture fixture;

      QVERIFY(fixture.start());
      auto& application = fixture.application;

      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      constexpr std::uint64_t agent_pane = 9;
      ds::Array agents{activityAgent("Remote target")};

      agents.atMut(0).pane_id = agent_pane;
      agents.atMut(0).session_id.atMut(0) = 1;
      // Another machine lists only the agents that wait on the person.
      agents.atMut(0).status = AgentStatus::blocked;
      fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 1, wait_ms);
      const auto retired = activityRow(application, 0).value(QStringLiteral("key")).toString();

      agents.atMut(0).session_id.atMut(0) = 2;
      fixture.remote_runtime->send(AgentSnapshot{.revision = 2, .entries = agents});
      QTRY_VERIFY_WITH_TIMEOUT(activityRow(application, 0).value(QStringLiteral("key")).toString() != retired, wait_ms);
      application.commands()->execute(window_actions::Action::select_agent, retired);
      QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 0);
      QVERIFY(!MachineWindow::pendingActivity(application));
      const auto current = activityRow(application, 0).value(QStringLiteral("key")).toString();

      application.commands()->execute(window_actions::Action::select_agent, current);
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
      application.commands()->execute(window_actions::Action::select_agent, current);
      QVERIFY(!MachineWindow::pendingActivity(application));
      QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 2);
    }

    Q_SLOT static void commandTargetsRejectWorkspaceReuseDuringHandoff() {
      MachineFixture fixture;

      QVERIFY(fixture.start());
      auto& application = fixture.application;

      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      ds::Array tasks{worktreeEntry()};

      tasks.atMut(0).created_by.reset();
      tasks.atMut(0).command_state = CommandState::running;
      tasks.atMut(0).title = "Remote command";
      constexpr std::uint64_t replacement_workspace = 3;
      const ds::Array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}, WorkspaceListEntry{.workspace = 2, .name = "command", .path = "/command"}, WorkspaceListEntry{.workspace = replacement_workspace, .name = "replacement", .path = "/replacement"}};

      // Only the active machine lists its tracked commands; the remote one is selected but still opening.
      MachineWindow::select(application, fixture.remote.machine);
      fixture.remote_runtime->send(WorkspaceList{.revision = 1, .entries = projects, .worktrees = tasks});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 1, wait_ms);
      const auto retired = activityRow(application, 0).value(QStringLiteral("key")).toString();

      application.commands()->execute(window_actions::Action::select_agent, retired);
      QVERIFY(MachineWindow::pendingActivity(application));
      tasks.atMut(0).workspace = replacement_workspace;
      fixture.remote_runtime->send(WorkspaceList{.revision = 2, .entries = projects, .worktrees = tasks});
      QTRY_VERIFY_WITH_TIMEOUT(!MachineWindow::pendingActivity(application), wait_ms);
      QVERIFY(finishOpening(*fixture.remote_runtime));
      const auto workspace_requests = fixture.remote_runtime->count(ClientTag::request_workspace_snapshot);
      const auto local_requests = fixture.local_runtime->count(ClientTag::request_workspace_snapshot);
      const auto openings = fixture.remote_runtime->count(ClientTag::open_pane);
      const auto local_openings = fixture.local_runtime->count(ClientTag::open_pane);

      application.commands()->execute(window_actions::Action::select_agent, retired);
      QCOMPARE(fixture.remote_runtime->count(ClientTag::request_workspace_snapshot), workspace_requests);
      QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), openings);
      const auto current = activityRow(application, 0).value(QStringLiteral("key")).toString();

      QVERIFY(current != retired);
      application.commands()->execute(window_actions::Action::select_agent, current);
      QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::open_pane), openings + 1, wait_ms);
      const auto opening = fixture.remote_runtime->last<OpenPane>();

      QCOMPARE(opening.target.kind, PaneTarget::Kind::workspace);
      QCOMPARE(opening.target.id, replacement_workspace);
      QVERIFY(!opening.launch);
      QCOMPARE(fixture.remote_runtime->count(ClientTag::request_workspace_snapshot), workspace_requests);
      QCOMPARE(fixture.local_runtime->count(ClientTag::request_workspace_snapshot), local_requests);
      QCOMPARE(fixture.local_runtime->count(ClientTag::open_pane), local_openings);
      QCOMPARE(fixture.remote_runtime->count(ClientTag::create_pane), 0);
    }

    Q_SLOT static void aLaterInteractionCancelsPendingActivity() {
      MachineFixture fixture;

      QVERIFY(fixture.start());
      auto& application = fixture.application;

      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      constexpr std::uint64_t agent_pane = 9;
      ds::Array agents{activityAgent("Pending agent")};

      agents.atMut(0).pane_id = agent_pane;
      fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 1, wait_ms);
      application.commands()->execute(window_actions::Action::select_agent, activityRow(application, 0).value(QStringLiteral("key")).toString());
      QVERIFY(MachineWindow::pendingActivity(application));
      application.commands()->execute(window_actions::Action::cancel);
      QVERIFY(!MachineWindow::pendingActivity(application));
      QVERIFY(finishOpening(*fixture.local_runtime));
      QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr && application.pane(pane_id)->attached, wait_ms);
      QCOMPARE(fixture.local_runtime->count(ClientTag::open_pane), 1);
      QCOMPARE(application.pane(pane_id)->id, pane_id);
    }

    Q_SLOT static void reconnectingRuntimeInvalidatesActivityWithRestartedRevisions() {
      MachineFixture fixture;

      QVERIFY(fixture.start());
      auto& application = fixture.application;
      const auto& remote = MachineWindow::client(application, fixture.remote.machine.slot);

      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      ds::Array agents{activityAgent("Before reconnect")};

      // Another machine lists only the agents that wait on the person, not its tracked commands.
      agents.atMut(0).status = AgentStatus::blocked;
      const ds::Array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}};

      fixture.remote_runtime->send(WorkspaceList{.revision = 1, .entries = projects});
      fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), 1, wait_ms);
      const auto old_agent = activityNamed(application, QStringLiteral("Before reconnect")).value(QStringLiteral("key")).toString();

      fixture.remote_socket_->disconnectFromServer();
      QTRY_VERIFY_WITH_TIMEOUT(!remote.session.ready(), wait_ms);
      fixture.remote_runtime.reset();
      fixture.remote_socket_ = nullptr;
      QTRY_VERIFY_WITH_TIMEOUT(fixture.remote_listener_.hasPendingConnections(), wait_ms);
      fixture.remote_socket_.reset(fixture.remote_listener_.nextPendingConnection());
      fixture.remote_runtime = std::make_unique<WireRuntime>(*fixture.remote_socket_);
      QTRY_VERIFY_WITH_TIMEOUT(remote.session.ready(), wait_ms);
      agents.atMut(0).session_title = "After reconnect";
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(WorkspaceList{.revision = 1, .entries = projects});
      fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      QTRY_VERIFY_WITH_TIMEOUT(!activityNamed(application, QStringLiteral("After reconnect")).isEmpty(), wait_ms);
      QVERIFY(activityNamed(application, QStringLiteral("After reconnect")).value(QStringLiteral("key")).toString() != old_agent);
      application.commands()->execute(window_actions::Action::select_agent, old_agent);
      QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 0);
      QVERIFY(!MachineWindow::pendingActivity(application));
      QVERIFY(remote.session.panes().empty());
      application.commands()->execute(window_actions::Action::select_agent, activityNamed(application, QStringLiteral("After reconnect")).value(QStringLiteral("key")).toString());
      QVERIFY(MachineWindow::pendingActivity(application));
      QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::open_pane), 1, wait_ms);
    }

    Q_SLOT static void retiredNotificationFocusKeepsItsWindowAndMachine() {
      MachineFixture fixture;
      auto& application = fixture.application;
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

      old_terminal.setController(application.terminals());
      old_terminal.setPaneId(QString::number(pane_id));
      TerminalItem terminal{current.contentItem()};

      terminal.setController(application.terminals());
      terminal.setPaneId(QString::number(pane_id));
      application.notifications()->publish({.title = "Local", .message = "local focus", .link = {}});
      const auto local_key = application.notifications()->identity(application.notifications()->center().items().front().id);

      previous.contentItem()->forceActiveFocus();
      application.notifications()->retireFocus(local_key);
      application.setWindow(current);
      current.contentItem()->forceActiveFocus();
      QCoreApplication::sendPostedEvents(application.notifications(), QEvent::MetaCall);
      QCOMPARE(current.activeFocusItem(), current.contentItem());
      application.notifications()->retireFocus(local_key, &old_terminal);
      QCoreApplication::sendPostedEvents(application.notifications(), QEvent::MetaCall);
      QCOMPARE(current.activeFocusItem(), current.contentItem());

      application.notifications()->retireFocus(local_key);
      QCoreApplication::sendPostedEvents(application.notifications(), QEvent::MetaCall);
      QCOMPARE(current.activeFocusItem(), &terminal);
      terminal.setFocus(false);
      current.contentItem()->forceActiveFocus();
      QCOMPARE(current.activeFocusItem(), current.contentItem());
      application.notifications()->retireFocus(local_key);
      QQuickItem editor{current.contentItem()};

      editor.forceActiveFocus();
      QCoreApplication::sendPostedEvents(application.notifications(), QEvent::MetaCall);
      QCOMPARE(current.activeFocusItem(), &editor);

      MachineWindow::select(application, fixture.remote.machine);
      QVERIFY(finishOpening(*fixture.remote_runtime));
      QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr && application.pane(pane_id)->attached, wait_ms);
      application.notifications()->publish({.title = "Remote", .message = "remote focus", .link = {}});
      const auto remote_key = application.notifications()->identity(application.notifications()->center().items().front().id);

      editor.setFocus(false);
      current.contentItem()->forceActiveFocus();
      QCOMPARE(current.activeFocusItem(), current.contentItem());
      application.notifications()->retireFocus(local_key);
      QCoreApplication::sendPostedEvents(application.notifications(), QEvent::MetaCall);
      QCOMPARE(current.activeFocusItem(), current.contentItem());
      application.notifications()->retireFocus(remote_key);
      QCoreApplication::sendPostedEvents(application.notifications(), QEvent::MetaCall);
      QCOMPARE(current.activeFocusItem(), &terminal);
    }

    Q_SLOT static void heldKeysCannotRepeatOnAnotherMachine() {
      MachineFixture fixture;

      QVERIFY(fixture.start());
      auto& application = fixture.application;

      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane_id) != nullptr, wait_ms);
      TerminalItem terminal;

      terminal.setController(application.terminals());
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
      auto& application = fixture.application;
      const auto& local = MachineWindow::client(application, Machines::local_slot);
      const auto& remote = MachineWindow::client(application, fixture.remote.machine.slot);

      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      QTRY_VERIFY_WITH_TIMEOUT(local.session.activeTab() != nullptr, wait_ms);
      QVERIFY(remote.session.panes().empty());
      QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 0);
      sendFrame(*fixture.local_runtime);
      QTRY_COMPARE_WITH_TIMEOUT(local.session.findPane(pane_id)->screen.frameId(), 1, wait_ms);
      const auto previous_view = application.terminals()->viewVersion();
      const auto old_frame = MachineWindow::capture(application);

      MachineWindow::select(application, fixture.remote.machine);
      QVERIFY(finishOpening(*fixture.remote_runtime));
      QTRY_VERIFY_WITH_TIMEOUT(local.session.panes().empty() && remote.session.activeTab() != nullptr, wait_ms);
      QVERIFY(application.terminals()->viewVersion().machine != previous_view.machine);
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
      auto& application = fixture.application;

      application.notifications()->publish({.title = "Local", .message = "local notice", .link = {}});
      const auto old_id = application.notifications()->center().items().front().id;
      const auto old_key = application.notifications()->identity(old_id);

      MachineWindow::select(application, fixture.remote.machine);
      application.notifications()->publish({.title = "Remote", .message = "remote notice", .link = {}});
      const auto current_id = application.notifications()->center().items().front().id;

      QCOMPARE(old_id.value, current_id.value);
      application.notifications()->dismiss(old_key);
      QCOMPARE(application.notifications()->center().items().front().phase, NotificationItem::Phase::entering);
      application.notifications()->activate(old_key);
      QCOMPARE(application.notifications()->center().items().front().phase, NotificationItem::Phase::entering);
      application.notifications()->dismiss(application.notifications()->identity(current_id));
      QCOMPARE(application.notifications()->center().items().front().phase, NotificationItem::Phase::exiting);
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
      auto& application = fixture.application;
      const auto& local = MachineWindow::client(application, Machines::local_slot);
      const auto original = local.key;

      MachineWindow::select(application, fixture.remote.machine);
      MachineWindow::links(application).linkOpeningFinished(original, LinkOpeningFailure::launch);
      QVERIFY(application.notifications()->center().items().empty());
      QCOMPARE(application::notifications::center(local.session).items().size(), 1);
      const auto retired = fixture.remote;

      static_cast<void>(MachineWindow::replace(application, retired.machine.slot));
      MachineWindow::links(application).linkOpeningFinished(retired, LinkOpeningFailure::process);
      QVERIFY(application.notifications()->center().items().empty());
    }
  };

}

int main(int argc, char** argv) {
  const QGuiApplication application{argc, argv};

  QQuickStyle::setStyle(QStringLiteral("Basic"));
  bundledFonts();
  MachineWindowTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "machine_window_test.moc"
