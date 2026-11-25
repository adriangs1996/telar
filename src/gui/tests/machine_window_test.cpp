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
#include "ui/kit/plugins/plugin_worker.hpp"
#include <QByteArray>
#include <QColor>
#include <algorithm>
#include <array>
#include <charconv>
#include <climits>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <tuple>
#include <utility>
#ifdef __APPLE__
#include "ui/app/panes/attachments/attachment_shelf.hpp"
#endif
#ifdef __APPLE__
#include "ui/kit/input/key_adapter.hpp"
#endif
#ifdef __APPLE__
#include "platform/private_clipboard.hpp"
#include "platform/promised_file.hpp"
#endif
#ifdef __APPLE__
#include <QBuffer>
#endif
#ifdef __APPLE__
#include <QRectF>
#endif
#ifdef __APPLE__
#include <QImage>
#endif
#ifdef __APPLE__
#include <QDebug>
#endif
#ifdef __APPLE__
#include <QtCore/qlogging.h>
#endif
#ifdef __APPLE__
#include <QSGRendererInterface>
#endif
#ifdef __APPLE__
#include <QFont>
#endif
#ifdef __APPLE__
#include <QScopeGuard>
#endif
#ifdef __APPLE__
#include <QtGui/qtestsupport_gui.h>
#endif
#include "telar_wire/codecs/telar_cells.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "ui/app/chrome/components/machine_chrome/machine_chrome_layout.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include "ui/kit/fonts/bundled_fonts.hpp"
#include "ui/kit/links/external_link_opener.hpp"
#include "ui/kit/machines/machine_client.hpp"
#include "ui/kit/models/list_model.hpp"
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
#include <QSizeF>
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
#endif

import telar.gui.tests.activity_fixture;
import telar.gui.tests.metrics_fixture;
import telar.gui.application;
import telar.gui.features.plugins;
import telar.gui.features.machines;
#ifdef __APPLE__
#endif
import telar.gui.features.notifications;
import telar.wire.agents;
import telar.wire.content;
import telar.wire.files;
import telar.wire.layout;
import telar.wire.monitor;
import telar.wire.nvim;
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

    // Names and colors a machine of the window, as its profile would.
    static void label(qt::ApplicationController& application, Machines::Slot slot, std::string_view label, std::string_view color) {
      const auto& row = application.store_.machines().row(slot);
      // The row's own text is what the update writes over.
      const std::string destination{row.destination.view()};

      application.store_.machinesMut().update(slot, {.id = row.id, .label = label, .destination = destination, .color = color, .enabled = row.enabled});
      emit application.machines_.listChanged();
    }

    static void select(qt::ApplicationController& application, MachineToken target) {
      application.machines_.select(target);
    }

    static qt::MachineClient& client(qt::ApplicationController& application, Machines::Slot slot) {
      return application.machines_.clientAtMut(slot);
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

  // The mouse areas under root that show the pointing cursor.
  qsizetype pointingAreaCount(QQuickItem& root) {
    const auto items = visualItems(root, QString{});

    return std::ranges::count_if(items, [](const QQuickItem* item) {
      return item->inherits("QQuickMouseArea") && item->cursor().shape() == Qt::PointingHandCursor;
    });
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

  // Two processes a runtime's monitor lists, and the cores of a large machine.
  constexpr ProcessInstance first_process{.pid = 101, .started_seconds = 1};
  constexpr ProcessInstance second_process{.pid = 102, .started_seconds = 1};
  constexpr std::size_t many_cores = 128;
  const ds::Array<MonitorProcess, 2> monitored{
      MonitorProcess{.instance = first_process, .name = "alpha", .measured = true},
      MonitorProcess{.instance = second_process, .name = "beta", .measured = true},
  };

  // A runtime's monitor: each query the window sends gets the processes and a new reading.
  struct MonitorReplies {
    WireRuntime& runtime;
    std::span<const std::uint16_t> cores;
    std::size_t answered = 0;
    std::uint64_t sample = 0;

    // Answers the query in flight, if one left since the last answer.
    void serve() {
      const auto asked_count = runtime.count(ClientTag::query_monitor);
      if (asked_count == answered) {
        return;
      }

      answered = asked_count;
      const auto asked = runtime.last<QueryMonitor>();
      MonitorSnapshot snapshot{
          .request_id = asked.request_id,
          .sections = MonitorSections::all,
          .sample = ++sample,
          .cores = cores,
          .process_count = monitored.size(),
          .matched = monitored.size(),
          .processes = monitored.view(),
      };

      for (const auto& process : monitored) {
        if (process.instance == asked.detail) {
          snapshot.detail.emplace(MonitorDetail{.process = process});
        }
      }

      runtime.send(snapshot);
    }
  };

  QVariantMap monitorRecord(ApplicationController& application, int row) {
    const auto* model = application.monitor()->rows();

    return model->data(model->index(row, 0), ListModel::record_role).toMap();
  }

  // Whether the monitor lists both processes, answering the queries it sends meanwhile.
  bool monitorLists(ApplicationController& application, MonitorReplies& replies) {
    return waitForGuiCondition([&] {
      replies.serve();

      return application.monitor()->rows()->rowCount() == 2 && monitorRecord(application, 1).value(QStringLiteral("kind")) == QStringLiteral("process");
    },
        wait_ms);
  }

  // Selects the listing's first process and waits for its detail.
  bool monitorSelectsFirst(ApplicationController& application, MonitorReplies& replies) {
    application.monitor()->selectRow(0);

    return waitForGuiCondition([&] {
      replies.serve();

      return application.monitor()->detail().value(QStringLiteral("pid")).toInt() == first_process.pid;
    },
        wait_ms);
  }

  // A machine's runtime as the explorer asks it: where its home is, the one directory it lists,
  // and what git says of it. It answers what was asked since it last served, a request of a kind
  // at a time, which is how an explorer that unfolds nothing asks.
  struct ExplorerReplies {
    WireRuntime& runtime;
    std::string_view home;
    std::string_view directory;
    std::span<const DirectoryEntry> entries;
    std::string_view branch;
    std::span<const FileChange> changes;
    // A directory below it, and what that one lists.
    std::string_view below;
    std::span<const DirectoryEntry> below_entries;
    std::size_t homes = 0;
    std::size_t listings = 0;
    std::size_t queries = 0;
    std::size_t measures = 0;
    std::size_t inspections = 0;

    // Whether one more request of `tag` arrived than `served` counts, which then counts it.
    [[nodiscard]] bool asked(ClientTag tag, std::size_t& served) const {
      const auto count = runtime.count(tag);
      if (count == served) {
        return false;
      }

      served = count;
      return true;
    }

    void serve() {
      if (asked(ClientTag::locate_home, homes)) {
        runtime.send(HomeLocated{.request_id = runtime.last<LocateHome>().request_id, .path = home});
      }

      if (asked(ClientTag::list_directory, listings)) {
        const auto listing = runtime.last<ListDirectory>();
        const std::string path{listing.path};
        const auto listed = path == directory ? entries : !below.empty() && path == below ? below_entries
                                                                                          : std::span<const DirectoryEntry>{};

        runtime.send(DirectoryContents{.request_id = listing.request_id, .path = path, .total = static_cast<std::uint32_t>(listed.size()), .entries = listed});
      }

      if (asked(ClientTag::query_changes, queries)) {
        const auto query = runtime.last<QueryChanges>();
        const std::string path{query.path};
        const bool inside = !branch.empty() && path == directory;

        runtime.send(RepositoryChanges{.request_id = query.request_id, .path = path, .root = inside ? directory : std::string_view{}, .branch = branch, .changes = inside ? changes : std::span<const FileChange>{}});
      }

      if (asked(ClientTag::measure_directory, measures)) {
        const auto measure = runtime.last<MeasureDirectory>();
        const std::string path{measure.path};

        runtime.send(DirectorySizes{.request_id = measure.request_id, .path = path});
      }

      if (asked(ClientTag::inspect_file, inspections)) {
        const auto inspect = runtime.last<InspectFile>();
        const std::string path{inspect.path};

        runtime.send(FileInspection{.request_id = inspect.request_id, .path = path, .size = 120, .text = "#!/bin/sh\nexec telar \"$@\"\n"});
      }
    }
  };

  int activeMachine(ApplicationController& application) {
    for (const auto& machine : application.monitor()->machines()) {
      const auto row = machine.toMap();
      if (row.value(QStringLiteral("active")).toBool()) {
        return row.value(QStringLiteral("slot")).toInt();
      }
    }

    return -1;
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

    static qreal paneRowHeight(ApplicationController& application) {
      return application.panes()->rows()->data(application.panes()->rows()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("height")).toReal();
    }

    // Connects the machine and gives its pane an agent that accepts ordered attachments.
    static void openClipboardAgent(MachineFixture& fixture, QQuickWindow& window, QSize size) {
      auto& application = fixture.application;

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
    }

    static void copyRedPng(PrivateClipboard& board) {
      QImage image{2, 3, QImage::Format_RGBA8888};

      image.fill(Qt::red);
      QByteArray png;
      QBuffer output{&png};

      QVERIFY(output.open(QIODevice::WriteOnly) && image.save(&output, "PNG"));
      board.setPng(std::as_bytes(std::span{png.constData(), static_cast<std::size_t>(png.size())}));
    }

    static void verifyShelfReservesPaneRows(ApplicationController& application, qreal before) {
      const auto after = paneRowHeight(application);
      const auto rows = application.display()->geometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid")).toMap().value(QStringLiteral("cellHeight")).toReal();

      QCOMPARE(before - after, PaneBottomReservation::shelf_rows * rows);
    }

    static void verifyModalOwnsKeys(ApplicationController& application, TerminalItem& terminal) {
      QKeyEvent blocked{QEvent::KeyPress, Qt::Key_X, Qt::NoModifier, QStringLiteral("x")};

      QVERIFY(application.commands()->handleKey(blocked, terminal));
      QKeyEvent escape{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier};

      QVERIFY(application.commands()->handleKey(escape, terminal));
      QVERIFY(application.attachments()->shelf()->modal().isEmpty());
    }

    static void verifyDismissDeletesTheMarker(MachineFixture& fixture, qreal before, const QString& identity, std::size_t previous_input) {
      auto& application = fixture.application;

      sendAttachmentFrame(*fixture.local_runtime);
      QTRY_COMPARE_WITH_TIMEOUT(application.pane(pane_id)->screen.cursor().x, 10, wait_ms);
      application.attachments()->shelf()->dismiss(identity);
      QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::pane_input), previous_input + 2, wait_ms);
      QCOMPARE(textView(fixture.local_runtime->last<PaneInput>().bytes), std::string_view{"\x7f"});
      QTRY_VERIFY_WITH_TIMEOUT(application.attachments()->shelf()->items().isEmpty() && application.attachments()->geometry().isEmpty(), wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(paneRowHeight(application), before, wait_ms);
    }

    static void verifySubmitSendsTheShelf(MachineFixture& fixture, TerminalItem& terminal, QKeyEvent& paste, std::size_t previous_input) {
      auto& application = fixture.application;

      QCoreApplication::sendEvent(&terminal, &paste);
      QTRY_COMPARE_WITH_TIMEOUT(application.attachments()->shelf()->items().size(), 1, wait_ms);
      QKeyEvent submit{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier};

      QCoreApplication::sendEvent(&terminal, &submit);
      QTRY_VERIFY_WITH_TIMEOUT(application.attachments()->shelf()->items().isEmpty() && application.attachments()->geometry().isEmpty(), wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(fixture.local_runtime->count(ClientTag::pane_input), previous_input + 4, wait_ms);
      QCOMPARE(textView(fixture.local_runtime->last<PaneInput>().bytes), std::string_view{"\r"});
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

      openClipboardAgent(fixture, window, size);
      QVERIFY(!QTest::currentTestFailed());
      const auto before = paneRowHeight(application);

      copyRedPng(board);
      QVERIFY(!QTest::currentTestFailed());
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

      shelf_properties.insert(QStringLiteral("ratio"), WindowDisplay::chromeRatio());
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
      QCOMPARE(pointingAreaCount(*shelf_view), 2);
      QCOMPARE(pointingAreaCount(*modal_view), 1);
      verifyShelfReservesPaneRows(application, before);
      QVERIFY(!QTest::currentTestFailed());

      const auto identity = application.attachments()->shelf()->items().front().toMap().value(QStringLiteral("id")).toString();

      application.attachments()->shelf()->open(identity);
      QVERIFY(!application.attachments()->shelf()->modal().isEmpty());
      QTRY_VERIFY_WITH_TIMEOUT(modal_view->isVisible(), wait_ms);
      verifyAttachmentModalHost(application);
      QVERIFY(waitForSynchronizedFrame(window, wait_ms));
      const auto modal_pixels = window.grabWindow();

      QVERIFY(!modal_pixels.isNull() && modal_pixels != shelf_pixels);
      QVERIFY(captureAttachmentImage(modal_pixels, "TELAR_GUI_TEST_ATTACHMENT_MODAL_CAPTURE"));
      verifyModalOwnsKeys(application, terminal);
      QVERIFY(!QTest::currentTestFailed());
      verifyAttachmentHoverReactivation(application, window);
      verifyAttachmentBackdropOwnership(application, window, identity);
      QCOMPARE(fixture.local_runtime->count(ClientTag::pane_input), previous_input + 1);

      verifyDismissDeletesTheMarker(fixture, before, identity, previous_input);
      QVERIFY(!QTest::currentTestFailed());

      verifySubmitSendsTheShelf(fixture, terminal, paste, previous_input);
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

      shelf_properties.insert(QStringLiteral("ratio"), WindowDisplay::chromeRatio());
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

    // The top bar reads machine, workspaces, tabs; the sidebar lists no machine; and every card
    // fills its three rows whatever its agent or process does. TELAR_GUI_TEST_CHROME_SCREENSHOTS
    // names a directory that receives the window as each assertion finds it.
    Q_SLOT static void chromeOrdersMachineWorkspacesAndTabsAndFillsEveryCardRow() {
      MachineFixture fixture;
      auto& application = fixture.application;
      QQmlApplicationEngine engine;

      engine.rootContext()->setContextProperty(QStringLiteral("telar"), &application);
      engine.loadFromModule(QStringLiteral("Telar.Gui"), QStringLiteral("Main"));
      QCOMPARE(engine.rootObjects().size(), 1);
      auto* window = qobject_cast<QQuickWindow*>(engine.rootObjects().front());

      QVERIFY(window != nullptr);
      constexpr QSize wide{1440, 1320};
      constexpr QSize narrow{900, 1320};
      constexpr qreal sidebar_width = 300;

      window->resize(wide);
      application.setWindow(*window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      window->show();
      QVERIFY(QTest::qWaitForWindowExposed(window));
      application.display()->setSidebarWidth(sidebar_width);
      MachineWindow::label(application, Machines::local_slot, "Workstation", "teal");
      MachineWindow::label(application, fixture.remote.machine.slot, "Build", "mauve");
      const ds::Array projects{
          WorkspaceListEntry{.workspace = 1, .name = "telar", .path = "/home/dev/telar", .tab_count = 2, .branch = "main", .dirty = true},
          WorkspaceListEntry{.workspace = 2, .name = "storefront", .path = "/home/dev/storefront", .tab_count = 3, .branch = "main"},
          WorkspaceListEntry{.workspace = 3, .name = "labs", .path = "/home/dev/labs", .tab_count = 1},
          WorkspaceListEntry{.workspace = 4, .name = "billing", .path = "/home/dev/billing", .tab_count = 1, .branch = "release"},
          WorkspaceListEntry{.workspace = 5, .name = "fleet", .path = "/home/dev/fleet", .tab_count = 2, .branch = "main"},
      };
      const auto placed = [](std::uint64_t pane, std::uint64_t workspace, std::string_view title, std::string_view project) {
        auto agent = activityAgent(title);

        agent.pane_id = pane;
        agent.location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = workspace}, .tab_id = pane};
        agent.workspace_label = project;
        agent.provider = AgentProvider::claude;
        agent.provider_name = "claude";
        agent.session_id.atMut(0) = static_cast<Byte>(pane);

        return agent;
      };

      ds::Array agents{
          placed(11, 2, "Migrate the orders table", "storefront"),
          placed(12, 1, "Sidebar cards", "telar"),
          placed(13, 2, "Review payments", "storefront"),
          placed(14, 4, "Invoice exporter", "billing"),
          placed(15, 5, "Set up the dev machines", "fleet"),
          placed(16, 2, "Stop the staging cluster", "storefront"),
          placed(17, 2, "Queue reviews", "storefront"),
          placed(18, 3, "Challenge notes", "labs"),
      };

      agents.atMut(0).last_event = "» Bash W=\"$(mktemp -d /private/tmp/migrate)\"";
      agents.atMut(0).status_age_s = 300;
      agents.atMut(0).tab_label = "db";
      agents.atMut(0).cwd_label = "~/storefront";
      agents.atMut(1).plan_step = "Lay out the third row";
      agents.atMut(1).plan_done = 3;
      agents.atMut(1).plan_total = 7;
      agents.atMut(1).status_age_s = 180;
      agents.atMut(1).cwd_label = "~/telar";
      agents.atMut(2).status = AgentStatus::blocked;
      agents.atMut(2).blocked_reason = AgentBlockedReason::permission;
      agents.atMut(2).last_event = "Bash: rails db:migrate RAILS_ENV=production";
      agents.atMut(2).status_age_s = 120;
      agents.atMut(2).tab_label = "payments";
      agents.atMut(3).status = AgentStatus::failed;
      agents.atMut(3).last_event = "API Error: 529 Overloaded";
      agents.atMut(3).status_age_s = 60;
      agents.atMut(4).status = AgentStatus::done;
      agents.atMut(4).final_message = "Both machines start with the new profile.";
      agents.atMut(4).status_age_s = 200;
      agents.atMut(5).status = AgentStatus::ready;
      agents.atMut(5).final_message = "Cluster stopped, billing at zero.";
      agents.atMut(5).status_age_s = 54000;
      agents.atMut(6).status = AgentStatus::unknown;
      agents.atMut(6).provider = AgentProvider::pi;
      agents.atMut(6).provider_name = "pi";
      agents.atMut(7).status = AgentStatus::ready;
      agents.atMut(7).status_age_s = 54000;
      ds::Array waiting{activityAgent("Deploy staging")};

      waiting.atMut(0).status = AgentStatus::blocked;
      waiting.atMut(0).blocked_reason = AgentBlockedReason::question;
      waiting.atMut(0).last_event = "Promote the build to staging?";
      waiting.atMut(0).session_id.atMut(0) = 99;
      const ds::Array<std::uint16_t, 3> served{3000, 9229, 9230};
      const ds::Array panes{
          PaneListEntry{.pane_id = pane_id, .pane_generation = 1, .location = location, .foreground = "zsh", .foreground_age_s = 5, .shell = true},
          PaneListEntry{.pane_id = 21, .pane_generation = 1, .location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 2}, .tab_id = 21}, .foreground = "node", .foreground_age_s = 720, .ports = served.view()},
          PaneListEntry{.pane_id = 22, .pane_generation = 1, .location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 5}, .tab_id = 22}, .foreground = "zsh", .foreground_age_s = 46800, .shell = true},
          PaneListEntry{.pane_id = 23, .pane_generation = 1, .location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 3}, .tab_id = 23}, .foreground = "zsh", .foreground_age_s = 8, .shell = true},
          PaneListEntry{.pane_id = 24, .pane_generation = 1, .location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 24}, .foreground = "nvim", .foreground_age_s = 1500},
      };
      constexpr std::uint32_t failed_ms = 4000;
      constexpr std::uint32_t console_ms = 12000;

      fixture.local_runtime->send(WorkspaceList{.revision = 1, .entries = projects});
      fixture.remote_runtime->send(WorkspaceList{.revision = 1, .entries = projects});
      fixture.local_runtime->send(AgentSnapshot{.revision = 1, .entries = agents});
      fixture.remote_runtime->send(AgentSnapshot{.revision = 1, .entries = waiting});
      fixture.local_runtime->send(PaneList{.revision = 1, .entries = panes});
      // What each pane's shell runs or ran last and where; the last pane's shell ran nothing yet.
      fixture.local_runtime->send(PaneFacts{.pane_id = pane_id, .pane_generation = 1, .command_state = PaneCommandState::finished, .command = "just gui-case sidebar", .exit_code = 1, .duration_ms = failed_ms, .directory = "~/telar", .in_workspace = true, .branch = "main", .dirty = true});
      fixture.local_runtime->send(PaneFacts{.pane_id = 21, .pane_generation = 1, .command_state = PaneCommandState::running, .command = "npm run dev -- --inspect", .directory = "~/storefront/web", .in_workspace = true, .branch = "main"});
      fixture.local_runtime->send(PaneFacts{.pane_id = 22, .pane_generation = 1, .command_state = PaneCommandState::finished, .command = "ansible-playbook site.yml", .exit_code = 0, .duration_ms = console_ms, .directory = "~/fleet", .in_workspace = true, .branch = "main"});
      fixture.local_runtime->send(PaneFacts{.pane_id = 23, .pane_generation = 1, .directory = "~/labs", .in_workspace = true});
      // An editor has no command: its facts name the file its focused window shows.
      fixture.local_runtime->send(PaneFacts{.pane_id = 24, .pane_generation = 1, .directory = "~/telar/docs", .in_workspace = true, .document = "sidebar.md +"});
      // Eight agents here, the one that waits elsewhere, the processes' header and five processes.
      constexpr int listed = 15;

      QTRY_COMPARE_WITH_TIMEOUT(application.activity()->rows()->rowCount(), listed, wait_ms);
      QVERIFY(waitForSynchronizedFrame(*window, wait_ms));
      const auto shots = qEnvironmentVariable("TELAR_GUI_TEST_CHROME_SCREENSHOTS");
      const auto capture = [&](const char* name) {
        return shots.isEmpty() || (waitForSynchronizedFrame(*window, wait_ms) && window->grabWindow().save(QDir{shots}.filePath(QString::fromLatin1(name)), "PNG"));
      };
      const auto textOf = [](const QQuickItem* item) {
        return item->property("text").toString();
      };
      auto* content = window->contentItem();
      const auto one = [&](const char* name) -> QQuickItem* {
        const auto found = visualItems(*content, QString::fromLatin1(name));

        return found.size() == 1 ? found.front() : nullptr;
      };

      // The bar, left to right: the machine, its workspaces, the tabs of the one in front.
      auto* machine = one("topBarMachine");
      auto* track = one("workspaceTrack");
      auto* strip = one("tabStripLayout");

      QVERIFY(machine != nullptr && track != nullptr && strip != nullptr);
      QVERIFY(machine->isVisible() && track->isVisible());
      QCOMPARE(textOf(one("topBarMachineLabel")), QStringLiteral("Workstation"));
      QCOMPARE(textOf(one("topBarMachineInitial")), QStringLiteral("W"));
      QVERIFY(machine->mapToScene({machine->width(), 0}).x() <= track->mapToScene({0, 0}).x());
      QVERIFY(track->mapToScene({track->width(), 0}).x() <= strip->mapToScene({0, 0}).x());
      const auto segments = visualItems(*track, QStringLiteral("workspaceSegment"));

      QCOMPARE(segments.size(), projects.size());
      const auto named = [&] {
        return std::ranges::count_if(visualItems(*track, QStringLiteral("workspaceSegmentName")), [](const QQuickItem* name) {
          return name->isVisible();
        });
      };

      // Five workspaces: every mark shows, and only the one in front keeps its name.
      QCOMPARE(named(), qsizetype{1});
      QCOMPARE(track->property("shownCount").toInt(), static_cast<int>(projects.size()));
      QVERIFY(visualItems(*content, QStringLiteral("topBarTelarMark")).isEmpty());
      QVERIFY(visualItems(*content, QStringLiteral("projectSwitcher")).isEmpty());
      QVERIFY(visualItems(*content, QStringLiteral("sidebarMachineList")).isEmpty());

      // Every card says what happens and where, in every state.
      const auto cards = visualItems(*content, QStringLiteral("agentCard"));

      QVERIFY(!cards.isEmpty());
      for (auto* card : cards) {
        const auto signal = visualItems(*card, QStringLiteral("agentSignal"));
        const auto where = visualItems(*card, QStringLiteral("agentProjectLabel"));
        const auto title = textOf(visualItems(*card, QStringLiteral("agentTitleLabel")).front());

        QCOMPARE(signal.size(), 1);
        QCOMPARE(where.size(), 1);
        QVERIFY2(!textOf(signal.front()).isEmpty(), qPrintable(title));
        QVERIFY2(!textOf(where.front()).isEmpty(), qPrintable(title));
        QVERIFY2(signal.front()->mapToScene({0, 0}).y() < where.front()->mapToScene({0, 0}).y(), qPrintable(title));
      }

      // What a card says of the pane with `title`: its second row, its place and its branch.
      const auto said = [&](const QString& title, const char* piece) {
        for (auto* card : cards) {
          if (textOf(visualItems(*card, QStringLiteral("agentTitleLabel")).front()) == title) {
            return textOf(visualItems(*card, QString::fromLatin1(piece)).front());
          }
        }

        return QString{};
      };
      const auto shown = [&](const QString& signal, const char* piece) {
        qsizetype count = 0;

        for (auto* card : cards) {
          if (textOf(visualItems(*card, QStringLiteral("agentSignal")).front()) == signal) {
            for (const auto* item : visualItems(*card, QString::fromLatin1(piece))) {
              count += static_cast<qsizetype>(item->isVisible());
            }
          }
        }

        return count;
      };

      // An agent's place is its project, its tab and its directory, and its workspace's branch closes the row.
      QCOMPARE(said(QStringLiteral("Migrate the orders table"), "agentProjectLabel"), QStringLiteral("storefront · db · ~/storefront"));
      QCOMPARE(said(QStringLiteral("Migrate the orders table"), "agentBranchLabel"), QStringLiteral("main"));
      QCOMPARE(said(QStringLiteral("Sidebar cards"), "agentProjectLabel"), QStringLiteral("telar · ~/telar"));
      QCOMPARE(said(QStringLiteral("Challenge notes"), "agentSignal"), QStringLiteral("No final message"));
      QCOMPARE(said(QStringLiteral("Stop the staging cluster"), "agentSignal"), QStringLiteral("Cluster stopped, billing at zero."));
      // A process's second row is its command and what that left: its ports while it serves,
      // a mark and how long it took when it ended well, its exit status when it failed.
      QCOMPARE(said(QStringLiteral("node"), "agentSignal"), QStringLiteral("npm run dev -- --inspect"));
      QCOMPARE(said(QStringLiteral("node"), "agentProjectLabel"), QStringLiteral("storefront · ~/storefront/web"));
      // An editor's second row is the file it shows, where another program would say `No command`.
      QCOMPARE(said(QStringLiteral("nvim"), "agentSignal"), QStringLiteral("sidebar.md +"));
      QCOMPARE(said(QStringLiteral("nvim"), "agentProjectLabel"), QStringLiteral("telar · ~/telar/docs"));
      QCOMPARE(shown(QStringLiteral("npm run dev -- --inspect"), "processPort"), qsizetype{3});
      QCOMPARE(shown(QStringLiteral("npm run dev -- --inspect"), "processResult"), qsizetype{0});
      QCOMPARE(shown(QStringLiteral("just gui-case sidebar"), "processResultGlyph"), qsizetype{1});
      QCOMPARE(shown(QStringLiteral("ansible-playbook site.yml"), "processResultGlyph"), qsizetype{1});
      QCOMPARE(shown(QStringLiteral("No commands yet"), "processResult"), qsizetype{0});
      const auto results = [&](const QString& signal) {
        for (auto* card : cards) {
          if (textOf(visualItems(*card, QStringLiteral("agentSignal")).front()) == signal) {
            return textOf(visualItems(*card, QStringLiteral("processResult")).front());
          }
        }

        return QString{};
      };

      QCOMPARE(results(QStringLiteral("just gui-case sidebar")), QStringLiteral("1"));
      QCOMPARE(results(QStringLiteral("ansible-playbook site.yml")), QStringLiteral("12s"));
      QVERIFY(capture("chrome-wide.png"));

      // The machine's menu lists both machines, the one in front marked.
      QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, machine->mapToScene({machine->width() / 2, machine->height() / 2}).toPoint());
      auto* menu = window->findChild<QObject*>(QStringLiteral("machineMenu"));

      QVERIFY(menu != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(menu->property("opened").toBool(), wait_ms);
      auto* roster = window->findChild<MachineChromeLayout*>(QStringLiteral("machineMenuList"));

      QVERIFY(roster != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(roster->items()->rowCount(), 2, wait_ms);
      const auto machineRow = [&](int row) {
        return roster->items()->data(roster->items()->index(row, 0), ListModel::record_role).toMap();
      };

      QVERIFY(machineRow(0).value(QStringLiteral("active")).toBool());
      QVERIFY(!machineRow(1).value(QStringLiteral("active")).toBool());
      QCOMPARE(machineRow(1).value(QStringLiteral("text")).toString(), QStringLiteral("Build"));
      QVERIFY(machineRow(1).value(QStringLiteral("attention")).toBool());
      QVERIFY(capture("machine-menu.png"));
      QVERIFY(QMetaObject::invokeMethod(menu, "close"));
      QTRY_VERIFY_WITH_TIMEOUT(!menu->property("visible").toBool(), wait_ms);

      // The workspaces' menu holds what the track has no room for.
      auto* more = one("workspaceTrackMore");

      QVERIFY(more != nullptr);
      QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, more->mapToScene({more->width() / 2, more->height() / 2}).toPoint());
      auto* workspaces = window->findChild<QObject*>(QStringLiteral("workspaceMenu"));

      QVERIFY(workspaces != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(workspaces->property("opened").toBool(), wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(workspaces->property("rows").toList().size(), static_cast<qsizetype>(projects.size()), wait_ms);
      QVERIFY(capture("workspace-menu.png"));
      QVERIFY(QMetaObject::invokeMethod(workspaces, "close"));
      QTRY_VERIFY_WITH_TIMEOUT(!workspaces->property("visible").toBool(), wait_ms);

      // A narrow bar still holds every workspace's mark and the name of the one in front.
      window->resize(narrow);
      QVERIFY(waitForSynchronizedFrame(*window, wait_ms));
      QCOMPARE(named(), qsizetype{1});
      QCOMPARE(track->property("shownCount").toInt(), static_cast<int>(projects.size()));
      QVERIFY(track->mapToScene({track->width(), 0}).x() <= strip->mapToScene({0, 0}).x());
      QVERIFY(capture("chrome-narrow.png"));
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
      QVariantMap record{{QStringLiteral("key"), QStringLiteral("owned")}, {QStringLiteral("enabled"), true}, {QStringLiteral("selected"), false}, {QStringLiteral("command"), false}};
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
        QTRY_VERIFY_WITH_TIMEOUT(!session.configuration.sidebar_visible, wait_ms);
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
      QVERIFY(remote.session.panes.empty());
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
      QVERIFY(remote.session.panes.empty());
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
      QVERIFY(remote.session.panes.empty());
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
      QVERIFY(remote.session.panes.empty());
      QCOMPARE(fixture.remote_runtime->count(ClientTag::open_pane), 0);
      sendFrame(*fixture.local_runtime);
      QTRY_COMPARE_WITH_TIMEOUT(local.session.findPane(pane_id)->screen.frameId(), 1, wait_ms);
      const auto previous_view = application.terminals()->viewVersion();
      const auto old_frame = MachineWindow::capture(application);

      MachineWindow::select(application, fixture.remote.machine);
      QVERIFY(finishOpening(*fixture.remote_runtime));
      QTRY_VERIFY_WITH_TIMEOUT(local.session.panes.empty() && remote.session.activeTab() != nullptr, wait_ms);
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

    // The monitor's list of machines shows another one in the monitor, with that machine's filter in
    // the filter's field; on a machine of many cores the table keeps its rows with the detail open.
    // Another machine runs the window's editor configuration: the window brings it there when it
    // connects, and keeps it from the machine it runs on, whose runtime reads the same directory.
    Q_SLOT static void editorConfigurationIsBroughtToAnotherMachine() {
      const QDir editor{qEnvironmentVariable("XDG_CONFIG_HOME") + QStringLiteral("/telar/editor")};
      const auto removed = qScopeGuard([&] {
        QDir{editor}.removeRecursively();
      });

      QVERIFY(editor.mkpath(QStringLiteral(".")));
      {
        QFile init{editor.filePath(QStringLiteral("init.lua"))};

        QVERIFY(init.open(QIODevice::WriteOnly));
        init.write("vim.o.number = true\n");
      }

      MachineFixture fixture;
      QQuickWindow window;

      fixture.application.setWindow(window);
      QVERIFY(fixture.start());
      QTRY_COMPARE_WITH_TIMEOUT(fixture.remote_runtime->count(ClientTag::nvim_configuration), std::size_t{1}, wait_ms);

      const auto brought = fixture.remote_runtime->last<NvimConfiguration>();

      QCOMPARE(brought.files.size(), std::size_t{1});
      QCOMPARE(brought.files[0].path, std::string_view{"init.lua"});
      QCOMPARE(fixture.local_runtime->count(ClientTag::nvim_configuration), std::size_t{0});
    }

    Q_SLOT static void monitorShowsAnotherMachineWithItsFilter() {
      MachineFixture fixture;
      auto& application = fixture.application;
      QQmlApplicationEngine engine;

      engine.rootContext()->setContextProperty(QStringLiteral("telar"), &application);
      engine.loadFromModule(QStringLiteral("Telar.Gui"), QStringLiteral("Main"));
      QCOMPARE(engine.rootObjects().size(), 1);
      auto* window = qobject_cast<QQuickWindow*>(engine.rootObjects().front());

      QVERIFY(window != nullptr);
      constexpr QSize small_window{1000, 640};

      window->resize(small_window);
      application.setWindow(*window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      window->show();
      QVERIFY(QTest::qWaitForWindowExposed(window));

      const ds::Array<std::uint16_t, many_cores> cores{};
      MonitorReplies local{.runtime = *fixture.local_runtime, .cores = cores.view()};
      MonitorReplies remote{.runtime = *fixture.remote_runtime, .cores = cores.view()};
      auto* monitor = application.monitor();
      auto* overlay = window->findChild<QQuickItem*>(QStringLiteral("monitorOverlay"));
      auto* table = window->findChild<QQuickItem*>(QStringLiteral("monitorTable"));
      auto* details = window->findChild<QQuickItem*>(QStringLiteral("monitorDetails"));
      auto* filter = window->findChild<QQuickItem*>(QStringLiteral("monitorFilter"));
      const auto filterText = [&] {
        return filter->property("text").toString();
      };

      QVERIFY(overlay != nullptr && table != nullptr && details != nullptr && filter != nullptr);
      application.commands()->execute(window_actions::Action::monitor);
      QCOMPARE(application.dialogs()->kind(), ApplicationController::Dialog::monitor);
      QVERIFY(monitorLists(application, local));
      monitor->setFilter(QStringLiteral("alpha"));
      QVERIFY(monitorLists(application, local));
      QCOMPARE(filterText(), QStringLiteral("alpha"));

      // The cores' panel scrolls; five rows of the table stay above the detail.
      constexpr int least_rows = 5;
      const auto line = overlay->property("line").toReal();

      QVERIFY(monitorSelectsFirst(application, local));
      QTRY_VERIFY_WITH_TIMEOUT(details->isVisible(), wait_ms);
      QVERIFY2(table->height() >= least_rows * line - 0.5, qPrintable(QStringLiteral("table %1, line %2").arg(table->height()).arg(line)));
      QVERIFY(table->mapToScene({0, table->height()}).y() <= details->mapToScene({0, 0}).y() + 0.5);

      monitor->selectMachine(fixture.remote.machine.slot);
      QVERIFY(finishOpening(*fixture.remote_runtime));
      QCOMPARE(activeMachine(application), fixture.remote.machine.slot);
      QCOMPARE(application.dialogs()->kind(), ApplicationController::Dialog::monitor);
      QVERIFY(monitorLists(application, remote));
      QCOMPARE(filterText(), QString{});

      monitor->setFilter(QStringLiteral("beta"));
      QVERIFY(monitorLists(application, remote));
      monitor->selectMachine(Machines::local_slot);
      QCOMPARE(application.dialogs()->kind(), ApplicationController::Dialog::monitor);
      QVERIFY(monitorLists(application, local));
      QCOMPARE(filterText(), QStringLiteral("alpha"));
    }

    // A confirmation acts on the process and the machine it named: moving to another process or
    // machine cancels it, and the palette's TERM asks as the monitor's key does.
    Q_SLOT static void monitorConfirmsOnTheProcessItNamed() {
      MachineFixture fixture;
      QQuickWindow window;
      auto& application = fixture.application;
      constexpr QSize size{800, 600};

      window.resize(size);
      application.setWindow(window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));

      const ds::Array<std::uint16_t, 4> cores{};
      MonitorReplies local{.runtime = *fixture.local_runtime, .cores = cores.view()};
      auto* monitor = application.monitor();
      const auto signals_sent = [&](WireRuntime& runtime) {
        return runtime.count(ClientTag::request_process_signal);
      };

      application.commands()->execute(window_actions::Action::monitor);
      monitor->setTable(QSizeF{800, 400}, QSizeF{8, 16});
      QVERIFY(monitorLists(application, local));
      QVERIFY(monitorSelectsFirst(application, local));

      monitor->ask(QStringLiteral("TERM"));
      QCOMPARE(monitor->confirmation().value(QStringLiteral("target")).toString(), QStringLiteral("alpha (101)"));
      monitor->move(1);
      QVERIFY(monitor->confirmation().isEmpty());
      monitor->confirm();
      QCOMPARE(signals_sent(*fixture.local_runtime), 0);

      monitor->ask(QStringLiteral("KILL"));
      QCOMPARE(monitor->confirmation().value(QStringLiteral("target")).toString(), QStringLiteral("beta (102)"));
      monitor->confirm();
      QTRY_COMPARE_WITH_TIMEOUT(signals_sent(*fixture.local_runtime), 1, wait_ms);
      const auto sent = fixture.local_runtime->last<RequestProcessSignal>();

      QVERIFY(sent.process == second_process && sent.signal == ProcessSignal::kill);
      fixture.local_runtime->send(RequestCompleted{.request_id = sent.request_id});

      // The palette's TERM waits in the monitor for a yes; showing another machine forgets it.
      application.commands()->execute(window_actions::Action::process_terminate);
      QCOMPARE(monitor->confirmation().value(QStringLiteral("action")).toString(), QStringLiteral("TERM"));
      QCOMPARE(signals_sent(*fixture.local_runtime), 1);
      monitor->selectMachine(fixture.remote.machine.slot);
      QVERIFY(finishOpening(*fixture.remote_runtime));
      QVERIFY(monitor->confirmation().isEmpty());
      monitor->confirm();
      QCOMPARE(signals_sent(*fixture.local_runtime) + signals_sent(*fixture.remote_runtime), 1);
    }

    // The explorer with a window on each of two machines: each lists what its own runtime
    // answers and asks the other for nothing, and one plan is sent to both. With
    // TELAR_EXPLORER_MACHINE_SHOTS it takes pictures of them into that directory.
    Q_SLOT static void explorerShowsWindowsOnTwoMachines() {
      MachineFixture fixture;
      auto& application = fixture.application;
      QQmlApplicationEngine engine;

      engine.rootContext()->setContextProperty(QStringLiteral("telar"), &application);
      engine.loadFromModule(QStringLiteral("Telar.Gui"), QStringLiteral("Main"));
      QCOMPARE(engine.rootObjects().size(), 1);
      auto* window = qobject_cast<QQuickWindow*>(engine.rootObjects().front());

      QVERIFY(window != nullptr);
      constexpr QSize window_size{1492, 917};

      window->resize(window_size);
      application.setWindow(*window);
      QVERIFY(fixture.start());
      fixture.local_runtime->send(ClientLayoutSnapshot{});
      fixture.remote_runtime->send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(*fixture.local_runtime));
      // The machine has the name its user gave it, whatever the host that runs the test is called.
      MachineWindow::rename(application, Machines::local_slot, "macbook");
      window->show();

      const ds::Array near_entries{
          DirectoryEntry{.name = "src", .kind = FileKind::directory, .directory = true, .identity = {.inode = 2, .modified_seconds = 5}},
          DirectoryEntry{.name = "README.md", .kind = FileKind::file, .size = 5500, .identity = {.inode = 3, .modified_seconds = 10}},
      };
      const ds::Array far_entries{
          DirectoryEntry{.name = "logs", .kind = FileKind::directory, .directory = true, .identity = {.inode = 8, .modified_seconds = 15}},
          DirectoryEntry{.name = "deploy.sh", .kind = FileKind::file, .size = 300, .identity = {.inode = 9, .modified_seconds = 20}},
      };
      const ds::Array near_changes{FileChange{.path = "README.md", .unstaged = FileState::modified, .added = 2, .removed = 1}};
      ExplorerReplies near{.runtime = *fixture.local_runtime, .home = "/home/dev", .directory = "/work/project", .entries = near_entries.view(), .branch = "main", .changes = near_changes.view()};
      const ds::Array logs_entries{
          DirectoryEntry{.name = "app.log", .kind = FileKind::file, .size = 300, .identity = {.inode = 21, .modified_seconds = 25}},
          DirectoryEntry{.name = "latest", .kind = FileKind::link, .identity = {.inode = 22, .modified_seconds = 26}},
      };
      ExplorerReplies far{.runtime = *fixture.remote_runtime, .home = "/home/ops", .directory = "/home/ops", .entries = far_entries.view(), .below = "/home/ops/logs", .below_entries = logs_entries.view()};
      auto* explorer = application.explorer();
      const auto shows = [&](auto shown) {
        return waitForGuiCondition([&] {
          near.serve();
          far.serve();

          return shown();
        },
            wait_ms);
      };
      const auto pane = [&](int index) {
        return explorer->windows().value(index).toMap();
      };
      const auto name = [&](int index, int row) {
        return explorer->rows(index)->index(row, 0).data(ListModel::record_role).toMap().value(QStringLiteral("name")).toString();
      };
      const auto shots = qEnvironmentVariable("TELAR_EXPLORER_MACHINE_SHOTS");
      const auto shoot = [&](const QString& file) {
        if (!shots.isEmpty()) {
          QVERIFY(waitForSynchronizedFrame(*window, wait_ms));
          QVERIFY(window->grabWindow().save(shots + QLatin1Char('/') + file + QStringLiteral(".png"), "PNG"));
        }
      };

      application.commands()->execute(window_actions::Action::explorer);
      QVERIFY(explorer->showing());
      explorer->run(QStringLiteral("e /work/project"));
      QVERIFY(shows([&] {
        return explorer->rows(0)->rowCount() == 2 && pane(0).value(QStringLiteral("repository")).toBool();
      }));
      QVERIFY(pane(0).value(QStringLiteral("local")).toBool());
      QCOMPARE(pane(0).value(QStringLiteral("machine")).toString(), QStringLiteral("macbook"));
      // A machine with no window is asked for nothing.
      QCOMPARE(fixture.remote_runtime->count(ClientTag::locate_home) + fixture.remote_runtime->count(ClientTag::list_directory) + fixture.remote_runtime->count(ClientTag::query_changes), 0);

      // A second window, at the home of the other machine: its runtime says where that is.
      const auto listed = fixture.local_runtime->count(ClientTag::list_directory);

      explorer->run(QStringLiteral("vs Build:~"));
      QVERIFY(shows([&] {
        return explorer->windows().size() == 2 && explorer->rows(1)->rowCount() == 2;
      }));
      QCOMPARE(pane(1).value(QStringLiteral("machine")).toString(), QStringLiteral("Build"));
      QVERIFY(!pane(1).value(QStringLiteral("local")).toBool() && !pane(1).value(QStringLiteral("repository")).toBool());
      QCOMPARE(pane(1).value(QStringLiteral("root")).toString(), QStringLiteral("~"));
      QCOMPARE(name(1, 0), QStringLiteral("logs"));
      QCOMPARE(name(0, 0), QStringLiteral("src"));
      QCOMPARE(pane(0).value(QStringLiteral("branch")).toString(), QStringLiteral("main"));
      QCOMPARE(fixture.remote_runtime->last<ListDirectory>().path, std::string_view{"/home/ops"});
      QCOMPARE(fixture.local_runtime->count(ClientTag::list_directory), listed);
      QVERIFY(shows([&] {
        return far.measures == 1;
      }));
      shoot(QStringLiteral("explorer-two-machines"));

      // A row of the other machine dragged out of the window is text that says its machine, and
      // no file URL: nothing of it is on this one.
      QCOMPARE(explorer->grab(1, 0), 1);
      {
        const auto outside = explorer->draggedData();

        QCOMPARE(outside->text(), QStringLiteral("Build:/home/ops/logs"));
        QVERIFY(!outside->hasUrls());
      }

      explorer->release();

      // A file removed on each machine, and one plan that says the machine of each line.
      explorer->type(QStringLiteral("jdd"));
      explorer->type(QStringLiteral("<C-w>h"));
      explorer->type(QStringLiteral("jdd"));
      explorer->run(QStringLiteral("w"));

      const auto plan = explorer->plan();

      QCOMPARE(plan.size(), 2);
      QCOMPARE(plan.value(0).toMap().value(QStringLiteral("machine")).toString(), QStringLiteral("Build"));
      QCOMPARE(plan.value(1).toMap().value(QStringLiteral("machine")).toString(), QStringLiteral("macbook"));
      shoot(QStringLiteral("explorer-plan-two-machines"));
      explorer->type(QStringLiteral("y"));
      QVERIFY(shows([&] {
        return fixture.local_runtime->count(ClientTag::change_files) == 1 && fixture.remote_runtime->count(ClientTag::change_files) == 1;
      }));

      const auto sent_near = fixture.local_runtime->last<ChangeFiles>();

      QVERIFY(sent_near.operations.size() == 1 && sent_near.operations[0].source == "/work/project/README.md");

      const auto near_request = sent_near.request_id;
      const auto sent_far = fixture.remote_runtime->last<ChangeFiles>();

      QVERIFY(sent_far.operations.size() == 1 && sent_far.operations[0].source == "/home/ops/deploy.sh");

      const ds::Array results{FileResult{.outcome = FileOutcome::done}};

      fixture.remote_runtime->send(FilesChanged{.request_id = sent_far.request_id, .undoable = true, .results = results.view()});
      fixture.local_runtime->send(FilesChanged{.request_id = near_request, .undoable = true, .results = results.view()});
      QVERIFY(shows([&] {
        return explorer->line().value(QStringLiteral("said")).toString() == QStringLiteral(":w · 2 of 2 applied by the runtime · u takes it back");
      }));

      // A file yanked on one machine and pasted on the other: the plan names both, and the
      // window carries it, a chunk read on one runtime and written on the other.
      explorer->type(QStringLiteral("<C-w>l"));
      explorer->type(QStringLiteral("ggjyy"));
      explorer->type(QStringLiteral("<C-w>h"));
      explorer->type(QStringLiteral("p"));
      explorer->run(QStringLiteral("w"));
      QCOMPARE(explorer->plan().size(), 1);
      QCOMPARE(explorer->plan().value(0).toMap().value(QStringLiteral("source")).toString(), QStringLiteral("Build:/home/ops/deploy.sh"));
      QCOMPARE(explorer->plan().value(0).toMap().value(QStringLiteral("machine")).toString(), QStringLiteral("macbook"));
      shoot(QStringLiteral("explorer-plan-transfer"));
      explorer->type(QStringLiteral("y"));
      QVERIFY(shows([&] {
        return fixture.remote_runtime->count(ClientTag::read_file) == 1;
      }));

      const auto read = fixture.remote_runtime->last<ReadFile>();
      const std::vector<Byte> first(200, Byte{'a'});
      const std::vector<Byte> second(100, Byte{'b'});
      const std::string_view arriving_partial = "/work/project/.telar-partial-0011223344556677";

      QVERIFY(read.path == "/home/ops/deploy.sh" && read.offset == 0 && read.identity.inode == 9);
      fixture.remote_runtime->send(FileChunk{.request_id = read.request_id, .offset = 0, .size = 300, .end = false, .bytes = first});
      QVERIFY(shows([&] {
        return fixture.local_runtime->count(ClientTag::write_file) == 1;
      }));

      const auto write = fixture.local_runtime->last<WriteFile>();

      QVERIFY(write.target == "/work/project/deploy.sh" && write.partial.empty() && write.bytes.size() == first.size());
      QCOMPARE(fixture.remote_runtime->count(ClientTag::read_file), 1);
      fixture.local_runtime->send(FileWritten{.request_id = write.request_id, .partial = arriving_partial, .size = 200});
      QVERIFY(shows([&] {
        return fixture.remote_runtime->count(ClientTag::read_file) == 2;
      }));

      // On its way it is a row where it will be, a line of the sidebar and a count in the status.
      const auto arriving = [&] {
        for (int row = 0; row < explorer->rows(0)->rowCount(); ++row) {
          const auto record = explorer->rows(0)->index(row, 0).data(ListModel::record_role).toMap();

          if (record.value(QStringLiteral("arriving")).toBool()) {
            return record;
          }
        }

        return QVariantMap{};
      };

      QVERIFY(shows([&] {
        return arriving().value(QStringLiteral("note")).toString() == QStringLiteral("arriving from Build · 200B of 300B");
      }));
      QCOMPARE(arriving().value(QStringLiteral("name")).toString(), QStringLiteral("deploy.sh"));
      QCOMPARE(explorer->transfers().size(), 1);
      QCOMPARE(explorer->transfers().value(0).toMap().value(QStringLiteral("route")).toString(), QStringLiteral("Build → macbook"));
      QCOMPARE(explorer->transfers().value(0).toMap().value(QStringLiteral("progress")).toString(), QStringLiteral("200B of 300B"));
      QCOMPARE(pane(0).value(QStringLiteral("carried")).toInt(), 1);
      QCOMPARE(pane(1).value(QStringLiteral("carried")).toInt(), 1);

      auto* listed_transfers = window->findChild<QQuickItem*>(QStringLiteral("sidebarTransfers"));

      QVERIFY(listed_transfers != nullptr && listed_transfers->isVisible() && listed_transfers->height() > 0);
      shoot(QStringLiteral("explorer-transfer"));

      // It goes on with the explorer closed, and the sidebar still lists it.
      explorer->close();
      QVERIFY(!explorer->showing());

      const auto next = fixture.remote_runtime->last<ReadFile>();

      QCOMPARE(next.offset, std::uint64_t{200});
      fixture.remote_runtime->send(FileChunk{.request_id = next.request_id, .offset = 200, .size = 300, .end = true, .bytes = second});
      QVERIFY(shows([&] {
        return fixture.local_runtime->count(ClientTag::write_file) == 2;
      }));

      const auto last = fixture.local_runtime->last<WriteFile>();

      QVERIFY(last.partial == arriving_partial && last.offset == 200 && last.bytes.size() == second.size());
      fixture.local_runtime->send(FileWritten{.request_id = last.request_id, .partial = arriving_partial, .size = 300});
      QVERIFY(shows([&] {
        return fixture.local_runtime->count(ClientTag::end_file_write) == 1;
      }));

      const auto ended = fixture.local_runtime->last<EndFileWrite>();

      QVERIFY(ended.keep && ended.partial == arriving_partial && ended.target == "/work/project/deploy.sh");
      fixture.local_runtime->send(FileWriteEnded{.request_id = ended.request_id, .outcome = FileOutcome::done, .path = "/work/project/deploy.sh"});
      QVERIFY(shows([&] {
        return explorer->transfers().value(0).toMap().value(QStringLiteral("ended")).toBool();
      }));
      QCOMPARE(explorer->transfers().value(0).toMap().value(QStringLiteral("phase")).toString(), QStringLiteral("arrived"));
      QVERIFY(listed_transfers->isVisible());
      // A copy leaves its original: nothing more was asked of its machine.
      QCOMPARE(fixture.remote_runtime->count(ClientTag::change_files), 1);

      // Carries the file the window reads next from the other machine to where it is written
      // on this one, whole: says where that was. With `halfway` it stops once the first part
      // of it is written, and says the partial that holds it.
      const auto carryToHere = [&](bool halfway) {
        const auto reads = fixture.remote_runtime->count(ClientTag::read_file);
        const auto writes = fixture.local_runtime->count(ClientTag::write_file);
        const auto ends = fixture.local_runtime->count(ClientTag::end_file_write);
        const auto asked = fixture.remote_runtime->last<ReadFile>();

        if (asked.path != "/home/ops/deploy.sh" || asked.identity.inode != 9 || asked.offset != 0) {
          return std::string{};
        }

        fixture.remote_runtime->send(FileChunk{.request_id = asked.request_id, .offset = 0, .size = 300, .end = false, .bytes = first});
        if (!shows([&] {
              return fixture.local_runtime->count(ClientTag::write_file) == writes + 1;
            })) {
          return std::string{};
        }

        const auto put = fixture.local_runtime->last<WriteFile>();
        const std::string target{put.target};
        const auto held = target.substr(0, target.rfind('/')) + "/.telar-partial-8899aabbccddeeff";

        fixture.local_runtime->send(FileWritten{.request_id = put.request_id, .partial = held, .size = 200});
        if (!shows([&] {
              return fixture.remote_runtime->count(ClientTag::read_file) == reads + 1;
            })) {
          return std::string{};
        }

        if (halfway) {
          return held;
        }

        const auto rest = fixture.remote_runtime->last<ReadFile>();

        fixture.remote_runtime->send(FileChunk{.request_id = rest.request_id, .offset = 200, .size = 300, .end = true, .bytes = second});
        if (!shows([&] {
              return fixture.local_runtime->count(ClientTag::write_file) == writes + 2;
            })) {
          return std::string{};
        }

        fixture.local_runtime->send(FileWritten{.request_id = fixture.local_runtime->last<WriteFile>().request_id, .partial = held, .size = 300});
        if (!shows([&] {
              return fixture.local_runtime->count(ClientTag::end_file_write) == ends + 1;
            })) {
          return std::string{};
        }

        const auto kept = fixture.local_runtime->last<EndFileWrite>();

        if (!kept.keep || kept.partial != held || kept.target != target) {
          return std::string{};
        }

        fixture.local_runtime->send(FileWriteEnded{.request_id = kept.request_id, .outcome = FileOutcome::done, .path = target});
        return target;
      };
      // The transfer that is on its way, which the explorer lists first; and one by its number.
      const auto running = [&] {
        const auto listed = explorer->transfers().value(0).toMap();

        return listed.value(QStringLiteral("ended"), true).toBool() ? QVariantMap{} : listed;
      };
      const auto transferOf = [&](int id) {
        for (const auto& listed : explorer->transfers()) {
          if (listed.toMap().value(QStringLiteral("id")).toInt() == id) {
            return listed.toMap();
          }
        }

        return QVariantMap{};
      };

      // A file of the other machine dragged out of the window, where the system asks for no
      // file: it is carried first to a directory of the cache, and the system's drag has its
      // URL once it is whole.
      application.commands()->execute(window_actions::Action::explorer);
      QVERIFY(explorer->showing());
      QVERIFY(shows([&] {
        return explorer->windows().size() == 2 && explorer->rows(1)->rowCount() == 2;
      }));
      QCOMPARE(name(1, 1), QStringLiteral("deploy.sh"));

      const QTemporaryDir cache;
      const auto cached_reads = fixture.remote_runtime->count(ClientTag::read_file);

      explorer->carryOutAs(application::explorer::Outside::caches, cache.filePath(QStringLiteral("dragged")));
      QCOMPARE(explorer->grab(1, 1), 1);
      explorer->dragOut(window);
      QVERIFY(shows([&] {
        return fixture.remote_runtime->count(ClientTag::read_file) == cached_reads + 1;
      }));
      QCOMPARE(explorer->draggedData()->text(), QStringLiteral("Build:/home/ops/deploy.sh"));
      QVERIFY(!explorer->draggedData()->hasUrls());

      const auto first_out = running().value(QStringLiteral("id")).toInt();
      const auto cached = QString::fromStdString(carryToHere(false));

      QVERIFY(cached.startsWith(cache.filePath(QStringLiteral("dragged/drag-"))) && cached.endsWith(QStringLiteral("/deploy.sh")));
      QVERIFY(QFileInfo{cached}.dir().exists());
      QVERIFY(shows([&] {
        return explorer->draggedData()->hasUrls();
      }));
      QCOMPARE(explorer->draggedData()->urls(), QList<QUrl>{QUrl::fromLocalFile(cached)});
      QCOMPARE(explorer->draggedData()->text(), QStringLiteral("Build:/home/ops/deploy.sh"));
      QVERIFY(first_out != 0);
      QCOMPARE(transferOf(first_out).value(QStringLiteral("phase")).toString(), QStringLiteral("arrived"));

      // Let go before its file is here, the file is stopped and what had arrived is removed.
      const auto dropped_ends = fixture.local_runtime->count(ClientTag::end_file_write);

      QCOMPARE(explorer->grab(1, 1), 1);
      explorer->dragOut(window);
      QVERIFY(shows([&] {
        return fixture.remote_runtime->count(ClientTag::read_file) == cached_reads + 3;
      }));

      const auto second_out = running().value(QStringLiteral("id")).toInt();
      const auto let_go = carryToHere(true);

      QVERIFY(!let_go.empty() && second_out != 0 && second_out != first_out);
      explorer->release();
      fixture.remote_runtime->send(FileChunk{.request_id = fixture.remote_runtime->last<ReadFile>().request_id, .offset = 200, .size = 300, .end = true, .bytes = second});
      QVERIFY(shows([&] {
        return fixture.local_runtime->count(ClientTag::end_file_write) == dropped_ends + 1;
      }));

      const auto removed = fixture.local_runtime->last<EndFileWrite>();

      QVERIFY(!removed.keep && removed.partial == let_go);
      fixture.local_runtime->send(FileWriteEnded{.request_id = removed.request_id, .outcome = FileOutcome::done});
      QVERIFY(shows([&] {
        return transferOf(second_out).value(QStringLiteral("phase")).toString() == QStringLiteral("cancelled");
      }));
      QVERIFY(!explorer->draggedData()->hasUrls());

#ifdef Q_OS_MACOS
      // Where the system asks for the file once the row is let go, nothing is carried before:
      // the row is a promise, and its file is one more transfer to where the system says.
      const QTemporaryDir desktop;
      const auto promised_reads = fixture.remote_runtime->count(ClientTag::read_file);
      const auto arrived = std::make_shared<PromiseAnswer>();
      const auto wanted = desktop.filePath(QStringLiteral("deploy 2.sh")).toStdString();

      explorer->carryOutAs(application::explorer::Outside::promises, cache.filePath(QStringLiteral("dragged")));
      QCOMPARE(explorer->grab(1, 1), 1);
      explorer->dragOut(window);
      QCOMPARE(promisedName(explorer->draggedOut(), 0), std::string{"deploy.sh"});
      // The row left as a promise, and nothing is carried for it until the system asks.
      QVERIFY(running().isEmpty());
      QVERIFY(askPromisedFile(explorer->draggedOut(), 0, wanted, arrived));
      QVERIFY(shows([&] {
        return fixture.remote_runtime->count(ClientTag::read_file) == promised_reads + 1;
      }));
      QVERIFY(!carryToHere(true).empty());
      // It shows as any file on its way does, and the system waits.
      QVERIFY(shows([&] {
        return running().value(QStringLiteral("progress")).toString() == QStringLiteral("200B of 300B");
      }));
      QCOMPARE(running().value(QStringLiteral("route")).toString(), QStringLiteral("Build → macbook"));
      QCOMPARE(running().value(QStringLiteral("name")).toString(), QStringLiteral("deploy 2.sh"));
      QVERIFY(listed_transfers->isVisible());
      QVERIFY(!arrived->answered);

      const auto promised_writes = fixture.local_runtime->count(ClientTag::write_file);
      const auto promised_ends = fixture.local_runtime->count(ClientTag::end_file_write);

      QCOMPARE(std::string{fixture.local_runtime->last<WriteFile>().target}, wanted);
      fixture.remote_runtime->send(FileChunk{.request_id = fixture.remote_runtime->last<ReadFile>().request_id, .offset = 200, .size = 300, .end = true, .bytes = second});
      QVERIFY(shows([&] {
        return fixture.local_runtime->count(ClientTag::write_file) == promised_writes + 1;
      }));

      const auto last_part = fixture.local_runtime->last<WriteFile>();
      const std::string promised_partial{last_part.partial};

      fixture.local_runtime->send(FileWritten{.request_id = last_part.request_id, .partial = promised_partial, .size = 300});
      QVERIFY(shows([&] {
        return fixture.local_runtime->count(ClientTag::end_file_write) == promised_ends + 1;
      }));

      const auto placed = fixture.local_runtime->last<EndFileWrite>();

      QVERIFY(placed.keep && !placed.overwrite && std::string{placed.target} == wanted);
      QVERIFY(!arrived->answered);
      fixture.local_runtime->send(FileWriteEnded{.request_id = placed.request_id, .outcome = FileOutcome::done, .path = wanted});
      QVERIFY(shows([&] {
        return arrived->answered;
      }));
      QVERIFY2(arrived->failure.empty(), arrived->failure.c_str());

      // Stopped on its way, what had arrived is removed and the system is told it did not come.
      const auto stopped = std::make_shared<PromiseAnswer>();
      const auto stopped_reads = fixture.remote_runtime->count(ClientTag::read_file);

      QVERIFY(askPromisedFile(explorer->draggedOut(), 0, wanted, stopped));
      QVERIFY(shows([&] {
        return fixture.remote_runtime->count(ClientTag::read_file) == stopped_reads + 1;
      }));

      const auto half = carryToHere(true);

      QVERIFY(!half.empty());
      QVERIFY(!running().isEmpty());
      explorer->cancelTransfer(running().value(QStringLiteral("id")).toInt());
      fixture.remote_runtime->send(FileChunk{.request_id = fixture.remote_runtime->last<ReadFile>().request_id, .offset = 200, .size = 300, .end = true, .bytes = second});
      QVERIFY(shows([&] {
        return fixture.local_runtime->count(ClientTag::end_file_write) == promised_ends + 2;
      }));

      const auto unwound = fixture.local_runtime->last<EndFileWrite>();

      QVERIFY(!unwound.keep && unwound.partial == half);
      QVERIFY(!stopped->answered);
      fixture.local_runtime->send(FileWriteEnded{.request_id = unwound.request_id, .outcome = FileOutcome::done});
      QVERIFY(shows([&] {
        return stopped->answered;
      }));
      QVERIFY(!stopped->failure.empty());

      // A name that is no entry of the directory the system gave is refused at once.
      const auto refused = std::make_shared<PromiseAnswer>();

      QVERIFY(askPromisedFile(explorer->draggedOut(), 0, (desktop.path() + QStringLiteral("/..")).toStdString(), refused));
      QVERIFY(refused->answered && !refused->failure.empty());

      // A directory of the other machine is a promise too, and what the system asks for is its
      // tree: the directory made where the system wants it, then what it holds, a link as a
      // link and a file as its bytes, each below the directory that was made and nowhere else.
      const auto changesHere = [&] {
        return fixture.local_runtime->count(ClientTag::change_files);
      };
      const ds::Array done_once{FileResult{.outcome = FileOutcome::done}};
      // Answers the directory the tree asks this machine to make; says where that was.
      const auto makeRoot = [&](std::size_t before) {
        if (!shows([&] {
              return changesHere() == before + 1;
            })) {
          return std::string{};
        }

        const auto made = fixture.local_runtime->last<ChangeFiles>();

        if (made.operations.size() != 1 || made.operations[0].kind != FileOperationKind::create_directory) {
          return std::string{};
        }

        const std::string root{made.operations[0].target};
        const ds::Array created{FileResult{.outcome = FileOutcome::done, .path = root}};

        fixture.local_runtime->send(FilesChanged{.request_id = made.request_id, .undoable = true, .results = created.view()});
        return root;
      };
      const auto whole_tree = std::make_shared<PromiseAnswer>();
      const auto wanted_tree = desktop.filePath(QStringLiteral("logs 2")).toStdString();
      auto tree_changes = changesHere();
      auto tree_reads = fixture.remote_runtime->count(ClientTag::read_file);
      const auto tree_writes = fixture.local_runtime->count(ClientTag::write_file);
      const auto tree_ends = fixture.local_runtime->count(ClientTag::end_file_write);

      QCOMPARE(explorer->grab(1, 0), 1);
      explorer->dragOut(window);
      QCOMPARE(promisedName(explorer->draggedOut(), 0), std::string{"logs"});
      QVERIFY(askPromisedFile(explorer->draggedOut(), 0, wanted_tree, whole_tree));
      QCOMPARE(makeRoot(tree_changes), wanted_tree);
      // Its link is read as what it says, and made as a link that says it.
      QVERIFY(shows([&] {
        return fixture.remote_runtime->count(ClientTag::read_file) == tree_reads + 1;
      }));

      const auto says = fixture.remote_runtime->last<ReadFile>();
      const std::string_view link_text = "app.log";
      const std::vector<Byte> said(link_text.begin(), link_text.end());

      QVERIFY(says.path == "/home/ops/logs/latest" && says.link && says.identity.inode == 22);
      fixture.remote_runtime->send(FileChunk{.request_id = says.request_id, .offset = 0, .size = said.size(), .end = true, .bytes = said});
      QVERIFY(shows([&] {
        return changesHere() == tree_changes + 2;
      }));

      const auto linked = fixture.local_runtime->last<ChangeFiles>();

      QVERIFY(linked.operations.size() == 1 && linked.operations[0].kind == FileOperationKind::link && linked.operations[0].source == link_text);
      QCOMPARE(std::string{linked.operations[0].target}, wanted_tree + "/latest");
      fixture.local_runtime->send(FilesChanged{.request_id = linked.request_id, .undoable = true, .results = done_once.view()});
      // Its file is read whole and written below the directory.
      QVERIFY(shows([&] {
        return fixture.remote_runtime->count(ClientTag::read_file) == tree_reads + 2;
      }));

      const auto nested = fixture.remote_runtime->last<ReadFile>();
      const std::vector<Byte> nested_bytes(300, Byte{'l'});

      QVERIFY(nested.path == "/home/ops/logs/app.log" && !nested.link && nested.identity.inode == 21);
      QVERIFY(!whole_tree->answered);
      QCOMPARE(running().value(QStringLiteral("name")).toString(), QStringLiteral("logs 2"));
      fixture.remote_runtime->send(FileChunk{.request_id = nested.request_id, .offset = 0, .size = 300, .end = true, .bytes = nested_bytes});
      QVERIFY(shows([&] {
        return fixture.local_runtime->count(ClientTag::write_file) == tree_writes + 1;
      }));

      const auto nested_write = fixture.local_runtime->last<WriteFile>();
      const auto nested_target = wanted_tree + "/app.log";
      const auto nested_partial = wanted_tree + "/.telar-partial-0123456789abcdef";

      QCOMPARE(std::string{nested_write.target}, nested_target);
      fixture.local_runtime->send(FileWritten{.request_id = nested_write.request_id, .partial = nested_partial, .size = 300});
      QVERIFY(shows([&] {
        return fixture.local_runtime->count(ClientTag::end_file_write) == tree_ends + 1;
      }));

      const auto nested_end = fixture.local_runtime->last<EndFileWrite>();

      QVERIFY(nested_end.keep && nested_end.partial == nested_partial && nested_end.target == nested_target);
      fixture.local_runtime->send(FileWriteEnded{.request_id = nested_end.request_id, .outcome = FileOutcome::done, .path = nested_target});
      QVERIFY(shows([&] {
        return whole_tree->answered;
      }));
      QVERIFY2(whole_tree->failure.empty(), whole_tree->failure.c_str());
      // A copy leaves the directory it came from.
      QCOMPARE(fixture.remote_runtime->count(ClientTag::change_files), 1);

      // Stopped on its way, the directory it had made goes to the trash with what had arrived,
      // and the system is told the tree did not come.
      const auto stopped_tree = std::make_shared<PromiseAnswer>();

      tree_changes = changesHere();
      tree_reads = fixture.remote_runtime->count(ClientTag::read_file);
      QVERIFY(askPromisedFile(explorer->draggedOut(), 0, wanted_tree, stopped_tree));
      QCOMPARE(makeRoot(tree_changes), wanted_tree);
      QVERIFY(shows([&] {
        return fixture.remote_runtime->count(ClientTag::read_file) == tree_reads + 1;
      }));
      QVERIFY(!running().isEmpty());
      explorer->cancelTransfer(running().value(QStringLiteral("id")).toInt());
      fixture.remote_runtime->send(FileChunk{.request_id = fixture.remote_runtime->last<ReadFile>().request_id, .offset = 0, .size = said.size(), .end = true, .bytes = said});
      QVERIFY(shows([&] {
        return changesHere() == tree_changes + 2;
      }));

      const auto cleared = fixture.local_runtime->last<ChangeFiles>();

      QVERIFY(cleared.operations.size() == 1 && cleared.operations[0].kind == FileOperationKind::trash);
      QCOMPARE(std::string{cleared.operations[0].source}, wanted_tree);
      QVERIFY(!stopped_tree->answered);
      fixture.local_runtime->send(FilesChanged{.request_id = cleared.request_id, .undoable = true, .results = done_once.view()});
      QVERIFY(shows([&] {
        return stopped_tree->answered;
      }));
      QVERIFY(!stopped_tree->failure.empty());

      // A name that was taken where the system wanted the directory leaves the tree beside it,
      // under another: the system is told it is not where it asked.
      const auto beside_tree = std::make_shared<PromiseAnswer>();

      tree_changes = changesHere();
      QVERIFY(askPromisedFile(explorer->draggedOut(), 0, wanted_tree, beside_tree));
      QVERIFY(shows([&] {
        return changesHere() == tree_changes + 1;
      }));

      const auto taken = fixture.local_runtime->last<ChangeFiles>();
      const auto other_root = wanted_tree + "-1";
      const ds::Array renamed{FileResult{.outcome = FileOutcome::renamed, .path = other_root}};

      far.below_entries = {};
      fixture.local_runtime->send(FilesChanged{.request_id = taken.request_id, .undoable = true, .results = renamed.view()});
      QVERIFY(shows([&] {
        return beside_tree->answered;
      }));
      QVERIFY(!beside_tree->failure.empty());
#endif

      // A path of the other machine is completed by what that machine lists, from a window that
      // is not on it.
      explorer->release();
      explorer->type(QStringLiteral("<C-w>h"));
      explorer->type(QStringLiteral(":"));
      explorer->complete(QStringLiteral("e Build:~/lo"));
      QVERIFY(shows([&] {
        return explorer->line().value(QStringLiteral("completion")).toString() == QStringLiteral("e Build:~/logs/");
      }));
      explorer->cancel();

      // The other machine goes away: its window keeps what it last listed, marked, and no change
      // is typed there.
      explorer->type(QStringLiteral("<C-w>l"));
      QVERIFY(!pane(1).value(QStringLiteral("away")).toBool());
      fixture.remote_socket_->disconnectFromServer();
      QVERIFY(shows([&] {
        return pane(1).value(QStringLiteral("away")).toBool();
      }));
      QCOMPARE(explorer->rows(1)->rowCount(), 2);
      QCOMPARE(name(1, 0), QStringLiteral("logs"));
      QCOMPARE(pane(1).value(QStringLiteral("following")).toString(), QStringLiteral("[stale]"));
      QVERIFY(!pane(0).value(QStringLiteral("away")).toBool());
      explorer->type(QStringLiteral("dd"));
      QCOMPARE(explorer->line().value(QStringLiteral("said")).toString(), QStringLiteral("Build does not answer: what it lists is what it last said, and nothing changes there until it is back"));
      shoot(QStringLiteral("explorer-stale"));
    }
  };

}

int main(int argc, char** argv) {
  // What a window reads of its configuration directory, as the editor's it brings another
  // machine, is the test's: never that of whoever runs it.
  const QTemporaryDir configuration;

  qputenv("XDG_CONFIG_HOME", configuration.path().toUtf8());
  const QGuiApplication application{argc, argv};

  QQuickStyle::setStyle(QStringLiteral("Basic"));
  bundledFonts();
  MachineWindowTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "machine_window_test.moc"
