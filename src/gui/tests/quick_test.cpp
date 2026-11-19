#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "agent_report_fixture.hpp"
#include "appearance_fixture.hpp"
#include "clipboard_fixture.hpp"
#include "foundation/core/application_memory.hpp"
#include "foundation/core/memory.hpp"
#include "frame_fixture.hpp"
#include "frame_pacing_fixture.hpp"
#include "gui_wait.hpp"
#include "history_card_wait_trace.hpp"
#include "history_presentation_fixture.hpp"
#include "platform/window.hpp"
#include "platform/window_activation.hpp"
#include "qml_fixture.hpp"
#include "screen_fixture.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_wire/codecs/telar_codec.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/protocol/clients.hpp"
#include "telar_wire/protocol/runtime.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "terminal_cursor_fixture.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/app/chrome/mode_bar/native_mode_layout.hpp"
#include "ui/app/overlays/notifications/notification_layout.hpp"
#include "ui/app/panes/pane_motion_layout.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include "ui/design/controls/modal_reveal_layout.hpp"
#include "ui/design/controls/native_form_field.hpp"
#include "ui/foundation/fonts/bundled_fonts.hpp"
#include "ui/foundation/input/key_adapter.hpp"
#include "ui/foundation/machines/runtime_connection.hpp"
#include "ui/foundation/models/list_model.hpp"
#include "ui/foundation/models/pane_attention_value.hpp"
#include "ui/foundation/models/projection.hpp"
#include "ui/foundation/scene/window_animation_clock.hpp"
#include <QAccessible>
#include <QByteArray>
#include <QClipboard>
#include <QCursor>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QInputMethodEvent>
#include <QList>
#include <QMimeData>
#include <QPoint>
#include <QPointer>
#include <QProcess>
#include <QProcessEnvironment>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlExpression>
#include <QQmlIncubationController>
#include <QQuickStyle>
#include <QRegularExpression>
#include <QScreen>
#include <QSemaphore>
#include <QSignalSpy>
#include <QSizeF>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QThreadPool>
#include <QTimer>
#include <QUrl>
#include <QVariant>
#include <QWheelEvent>
#include <QWindow>
#include <QtCore/qbytearrayview.h>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qcoreapplication.h>
#include <QtCore/qcoreevent.h>
#include <QtCore/qlist.h>
#include <QtCore/qlogging.h>
#include <QtCore/qmath.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qscopeguard.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtGui/qaccessible_base.h>
#include <QtGui/qevent.h>
#include <QtGui/qfont.h>
#include <QtGui/qguiapplication.h>
#include <QtGui/qtestsupport_gui.h>
#include <QtQml/qqml.h>
#include <QtQml/qqmlerror.h>
#include <QtQuick/qquickitem.h>
#include <QtQuick/qquickitemgrabresult.h>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestkeyboard.h>
#include <QtTest/qtestmouse.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <charconv>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <ghostty/vt/unicode.h>
#include <limits>
#include <memory>
#include <optional>
#include <ranges>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <tuple>
#include <utility>
#include <variant>

import telar.gui.tests.json_fixture;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.application;
import telar.gui.features.components;
import telar.gui.features.terminal.graphics;
import telar.gui.features.workbench;
import telar.base.text.json;
import telar.base.text.utf8;
import telar.plugins;
import telar.gui.features.notifications;
import telar.wire.history;
import telar.gui.features.window;
import telar.base.ds;

namespace telar::gui::test {

  struct ComponentActions {
    struct Action {
      BindingAction action;
      NamedActionDescription destination;
      std::shared_ptr<const qt::ComponentSlotState::Panel> rendered;
    };

    [[nodiscard]] static ds::Option<Action> retain(const qt::ApplicationController& application) {
      const auto& rendered = application.components_.surfaces_.panel.panel;
      if (!rendered || rendered->content.nodes().empty()) {
        return ds::none;
      }

      const auto& content = rendered->content;
      const auto action = content.action(content.nodes().front());
      if (!action) {
        return ds::none;
      }

      const auto destination = application.configuration_source_.namedAction(*action, &rendered->actions);

      return destination ? ds::Option{Action{.action = *action, .destination = *destination, .rendered = rendered}} : ds::none;
    }

    static bool run(qt::ApplicationController& application, const Action& action) {
      return application.commands()->runBinding(action.action, &action.rendered->actions);
    }

    [[nodiscard]] static bool luaIdle(const qt::ApplicationController& application) {
      return application.configuration_source_.luaIdle();
    }

    [[nodiscard]] static bool pluginIdle(const qt::ApplicationController& application) {
      return application.plugins_.idle();
    }
  };

}

namespace {

  using telar::gui::test::requiredJsonField;
  using telar::gui::test::screenGrid;
  using telar::gui::test::screenText;
  using telar::gui::test::ScreenTextLayout;

  using namespace telar::gui;

  using namespace telar::gui::features::notifications;

  using namespace telar::gui::features::window;

  using namespace telar::gui::features::terminal::graphics;
  using namespace telar::gui::qt;

  bool visibleWindowText(const QString& text) {
    for (const auto* candidate : QGuiApplication::allWindows()) {
      const auto* window = qobject_cast<const QQuickWindow*>(candidate);
      if (window == nullptr || !window->isVisible()) {
        continue;
      }

      for (const auto* item : test::visualItems(*window->contentItem(), QString{})) {
        if (item->isVisible() && item->property("text").toString() == text) {
          return true;
        }
      }
    }

    return false;
  }

  QQuickItem* historyCardHint(const QQuickWindow& window, int selected, const QString& action) {
    for (auto* row : test::visualItems(*window.contentItem(), QStringLiteral("historyResult"))) {
      if (row->property("index").toInt() != selected) {
        continue;
      }

      for (auto* hint : test::visualItems(*row, QStringLiteral("historyHint"))) {
        const auto* card = hint->parentItem();

        while (card != nullptr && card->objectName() != QStringLiteral("historyRow")) {
          card = card->parentItem();
        }

        if (card != nullptr && card->property("open").toReal() == 1 && hint->isVisible() && hint->property("label").toMap().value(QStringLiteral("action")).toString() == action) {
          return hint;
        }
      }
    }

    return nullptr;
  }

  QQuickItem* historyFooterHint(const QQuickWindow& window, const QString& action) {
    auto* footer = window.findChild<QQuickItem*>(QStringLiteral("historyFooter"));
    if (footer == nullptr) {
      return nullptr;
    }

    for (auto* hint : test::visualItems(*footer, QStringLiteral("historyHint"))) {
      if (hint->isVisible() && hint->property("label").toMap().value(QStringLiteral("action")).toString() == action) {
        return hint;
      }
    }

    return nullptr;
  }

  constexpr int runtime_wait_ms = 10'000;
  constexpr int frame_settle_ms = 100;
  constexpr int chrome_font_pixels = 13;
  constexpr qreal divider_drag_pixels = 60;
  constexpr std::size_t response_capacity = 4096;

  struct TabRestorePoint {
    int count = 0;
    std::uint64_t pane_id = 0;
  };

  // A mouse button pressed over a history card, and where it is to be released.
  struct HeldCardPress {
    Qt::MouseButton button = Qt::LeftButton;
    QPoint position;
    bool held = false;
  };

  enum class ChildMouseEncoding : std::uint8_t {
    sgr,
    legacy,
  };

  enum class TerminalSuppression : std::uint8_t {
    hidden,
    no_contents,
  };

  constexpr auto binding_configuration = R"(
return {api_version = 2, client = {
  prefix = 'ctrl+a', input = {sequence_timeout_ms = 20},
  keybindings = {
    telar.bind({'s'}, function(context) return require('helper')(context) end),
    telar.bind_global({'g', 'g'}, telar.action.toggle_workspace_list()),
    telar.bind_expr_global({'alt+p'}, function()
      return telar.input.paste("printf 'GUI_BINDING_PASTE\\n'")
    end),
    telar.bind_expr_global({'alt+k'}, function()
      return telar.input.keys({'G','U','I','_','B','I','N','D','I','N','G','_','K','E','Y','S'})
    end),
    telar.bind_expr_global({'alt+v'}, function() return telar.input.consume() end)
  }
}}
)";

  QString modeTitle(const NativeModeLayout& mode) {
    return mode.title();
  }

  void writeTestFile(const QString& path, const char* source) {
    QFile file{path};
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate) || file.write(source) < 0) {
      throw std::runtime_error{"Cannot write GUI integration fixture"};
    }
  }

  // The command a history submission test imports; it prints GUI_HISTORY_RENDER_DONE_<tag> when run.
  QString renderedHistoryCommand(const QString& tag) {
    return QStringLiteral("printf 'GUI_HISTORY_RENDER_%s_%1\\n' DONE").arg(tag);
  }

  // A file's bytes, or none while nothing has written it yet.
  QByteArray readTestFile(const QString& path) {
    QFile file{path};

    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray{};
  }

  telar::ds::Option<std::uint32_t> logicalRowStart(const Screen<telar::Memory>& screen, std::size_t requested_line) {
    const auto grid = screenGrid(screen);
    std::size_t line = 0;

    for (std::uint32_t row = 0; row < screen.rows(); ++row) {
      if (line == requested_line) {
        return row;
      }

      const auto end = (static_cast<std::size_t>(row) + 1) * screen.columns();
      if (end == 0 || !grid.next(end - 1)) {
        ++line;
      }
    }

    return telar::ds::none;
  }

  QString shellLiteral(QString text) {
    text.replace(QLatin1Char('\''), QLatin1StringView("'\\''"));

    return QLatin1Char('\'') + text + QLatin1Char('\'');
  }

  TerminalItem* terminalIn(QQuickItem* root) {
    QList<QQuickItem*> pending{root};

    while (!pending.isEmpty()) {
      auto* item = pending.takeLast();
      if (item == nullptr) {
        continue;
      }

      if (auto* terminal = qobject_cast<TerminalItem*>(item)) {
        return terminal;
      }

      const auto children = item->childItems();

      for (auto* child : children | std::views::reverse) {
        pending.append(child);
      }
    }

    return nullptr;
  }

  TerminalItem* focusedTerminalBeside(QQuickWindow& window, const TerminalItem& current) {
    TerminalItem* focused = nullptr;
    const bool ready = QTest::qWaitFor([&window, &current, &focused] {
      focused = qobject_cast<TerminalItem*>(window.activeFocusItem());

      return focused != nullptr && focused != &current;
    },
        runtime_wait_ms);

    return ready ? focused : nullptr;
  }

  QString windowObservation(const QQuickWindow& window) {
    QString result;
    QDebug stream{&result};
    const auto* terminal = qobject_cast<TerminalItem*>(window.activeFocusItem());

    stream.nospace() << "state=" << window.windowState() << " visibility=" << window.visibility() << " active=" << window.isActive() << " size=" << window.size() << " focused=" << window.activeFocusItem() << " focusedPane=" << (terminal == nullptr ? 0 : terminal->paneIdentity());

    return result;
  }

  QPoint cellCenter(const TerminalItem& terminal, CellPosition cell) {
    const auto size = terminal.cellSize();

    return terminal.mapToScene({(cell.x * size.width()) + (size.width() / 2), (cell.y * size.height()) + (size.height() / 2)}).toPoint();
  }

  void sendMouse(QQuickWindow& window, QEvent::Type phase, Qt::MouseButton button, Qt::MouseButtons held, QPoint position) {
    QMouseEvent event{phase, QPointF{position}, QPointF{window.mapToGlobal(position)}, button, held, Qt::NoModifier};

    QCoreApplication::sendEvent(&window, &event);
  }

#ifdef TELAR_GUI_CUSTOM_LINK_HOST
  class RecordedLinks {
  public:
    explicit RecordedLinks(QString path)
        : path_(std::move(path)),
          previous_(qgetenv("TELAR_GUI_TEST_LINK_RECORD")) {
      if (!qputenv("TELAR_GUI_TEST_LINK_RECORD", path_.toUtf8())) {
        throw std::runtime_error{"Cannot configure the external link recorder"};
      }
    }

    ~RecordedLinks() {
      if (previous_.isNull()) {
        static_cast<void>(qunsetenv("TELAR_GUI_TEST_LINK_RECORD"));
      } else {
        static_cast<void>(qputenv("TELAR_GUI_TEST_LINK_RECORD", previous_));
      }
    }

    RecordedLinks(const RecordedLinks&) = delete;
    RecordedLinks& operator=(const RecordedLinks&) = delete;
    RecordedLinks(RecordedLinks&&) = delete;
    RecordedLinks& operator=(RecordedLinks&&) = delete;

    [[nodiscard]] QStringList targets() const {
      QFile file{path_};
      if (!file.open(QIODevice::ReadOnly)) {
        return {};
      }

      return QString::fromUtf8(file.readAll()).split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    }

  private:
    QString path_;
    QByteArray previous_;
  };
#endif

  struct CommandOutcome {
    std::uint64_t request_id = 0;
    telar::ClientCommandStatus status = telar::ClientCommandStatus::request;
    QString text;
    std::int64_t value = 0;
  };

  class CommandPeer final : public QObject {
  public:
    explicit CommandPeer(ApplicationAllocator& memory)
        : connection_(memory) {
      connect(&connection_, &RuntimeConnection::connected, this, [this] {
        connection_.send(telar::QueryClients{.request_id = 1});
      });

      connect(&connection_, &RuntimeConnection::payloadReceived, this, [this](QByteArrayView payload) {
        consume(telar::byteView({payload.data(), static_cast<std::size_t>(payload.size())}));
      });

      connect(&connection_, &RuntimeConnection::errorChanged, this, [this] {
        error_ = connection_.error();
      });
    }

    void open(const QString& endpoint) {
      connection_.open(endpoint);
    }

    void request(telar::ClientAction action, std::uint64_t request_id, std::string_view text = {}, std::int64_t value = 0) {
      request(telar::ClientCommand{.request_id = request_id, .action = action, .value = value, .text = text});
    }

    void request(const telar::ClientCommand& message) {
      telar::RequestClientCommand command;

      static_cast<telar::ClientCommand&>(command) = message;
      command.route = route_;
      connection_.send(command);
    }

    void showNotification(const telar::ShowNotification& message) {
      connection_.send(message);
    }

    [[nodiscard]] bool ready() const noexcept {
      return route_.id != 0;
    }

    [[nodiscard]] const CommandOutcome& result() const noexcept {
      return result_;
    }

    [[nodiscard]] const QString& error() const noexcept {
      return error_;
    }

  private:
    void consume(std::span<const telar::Byte> payload) {
      try {
        telar::DecodeStorage storage{storage_.viewMut()};

        if (payload.front() == static_cast<telar::Byte>(telar::ServerTag::client_list)) {
          selectClient(telar::Codec::decode<telar::ClientList>(payload, storage));
        } else if (payload.front() == static_cast<telar::Byte>(telar::ServerTag::client_command_result)) {
          const auto reply = telar::Codec::decode<telar::ClientCommandResult>(payload, storage);

          result_ = {.request_id = reply.request_id, .status = reply.status, .text = toQString(reply.text), .value = reply.value};
        }
      } catch (const std::exception& error) {
        error_ = QString::fromUtf8(error.what());
      }
    }

    void selectClient(const telar::ClientList& clients) {
      for (const auto& entry : clients.entries) {
        if (entry.identity != 0) {
          route_ = {.id = entry.id, .generation = entry.generation};

          break;
        }
      }
    }

    RuntimeConnection connection_;
    telar::ClientRoute route_;
    CommandOutcome result_;
    QString error_;
    telar::ds::Array<telar::Byte, response_capacity> storage_{};
  };

  enum class PluginCatalogRequest : std::uint8_t {
    unconfigured = 2,
    disabled_list,
    enabled_list,
    metadata,
    first_action,
    last_action,
    stale_generation,
    invalid_page,
    missing,
    failed_reload,
    retained_catalog,
    recover_reload,
    old_generation,
  };

  [[nodiscard]] constexpr std::uint64_t pluginCatalogRequestId(PluginCatalogRequest request) noexcept {
    return std::to_underlying(request);
  }

  constexpr auto plugin_catalog_configuration = "return {api_version=2,plugins={{path='missing-disabled',enabled=false},{path='example'}}}";

  class QuickTest final : public QObject {
    Q_OBJECT

  private:
    Q_SLOT void initTestCase() {
      const auto executable = qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME");

      QVERIFY2(!executable.isEmpty() && QFileInfo::exists(executable), "Set TELAR_GUI_TEST_RUNTIME to a Telar runtime executable");
      QVERIFY(directory_.isValid());
      socket_ = directory_.filePath(QStringLiteral("runtime.sock"));
      runtime_.setProgram(executable);
      auto arguments = QProcess::splitCommand(qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME_ARGUMENTS"));
      if (arguments.isEmpty()) {
        arguments = {QStringLiteral("server"), QStringLiteral("--no-config"), QStringLiteral("--fresh")};
      }

      arguments.append({QStringLiteral("--socket"), socket_});
      runtime_.setArguments(arguments);
      auto environment = QProcessEnvironment::systemEnvironment();

      for (const auto& name : environment.keys()) {
        if (name.startsWith(QLatin1StringView("TELAR_"))) {
          environment.remove(name);
        }
      }

      environment.remove(QStringLiteral("ENV"));
      environment.remove(QStringLiteral("BASH_ENV"));
      environment.insert(QStringLiteral("TELAR_HISTORY"), directory_.filePath(QStringLiteral("history.db")));
      environment.insert(QStringLiteral("HISTFILE"), directory_.filePath(QStringLiteral("shell-history")));
      environment.insert(QStringLiteral("XDG_DATA_HOME"), directory_.filePath(QStringLiteral("data")));
      runtime_.setProcessEnvironment(environment);
      runtime_.start();
      QVERIFY(runtime_.waitForStarted());
      QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(socket_), runtime_wait_ms);
      bundledFonts();
      QFont chrome_font{QStringLiteral("IBM Plex Sans")};

      chrome_font.setPixelSize(chrome_font_pixels);
      QGuiApplication::setFont(chrome_font);
      openWindow();
      QVERIFY2(window_ != nullptr, qPrintable(errors_));
      const auto external_window_ready = qEnvironmentVariable("TELAR_GUI_TEST_WINDOW_READY");
      if (!external_window_ready.isEmpty()) {
        QTRY_VERIFY2_WITH_TIMEOUT(QFileInfo::exists(external_window_ready), "External native window setup did not complete", runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(test::windowManagerReady(*window_), runtime_wait_ms);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      }

      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->screen.frameId() > 0, runtime_wait_ms);
      seedHistory();
    }

    Q_SLOT void nativeWindowClosesAndReopens() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto pane_id = firstPane()->id;
      const auto quit_on_close = QGuiApplication::quitOnLastWindowClosed();
      const QPointer<QQuickWindow> lifetime{window_};

      QGuiApplication::setQuitOnLastWindowClosed(false);
      const auto restore = qScopeGuard([&] {
        if (!lifetime.isNull() && (!lifetime->isVisible() || !lifetime->isActive())) {
          lifetime->show();
          test::activateWindow(*lifetime);
        }

        QGuiApplication::setQuitOnLastWindowClosed(quit_on_close);
      });

      QQmlComponent cancellation{engine_.get()};

      cancellation.setData("import QtQuick; Connections { function onClosing(close) { close.accepted = false } }", QUrl{});
      auto gate = std::unique_ptr<QObject>{cancellation.createWithInitialProperties({{QStringLiteral("target"), QVariant::fromValue(window_)}})};

      QVERIFY2(gate != nullptr, qPrintable(cancellation.errorString()));
      QVERIFY(!window_->close());
      QVERIFY(window_->isVisible());
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      gate.reset();
      QVERIFY(window_->close());
      QVERIFY(!lifetime.isNull());
      QTRY_VERIFY_WITH_TIMEOUT(!window_->isVisible() && !window_->isExposed(), runtime_wait_ms);
      window_->show();
      test::activateWindow(*window_);
      QTRY_VERIFY_WITH_TIMEOUT(window_->isVisible() && window_->isExposed(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(window_->isActive(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(test::windowManagerReady(*window_), runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      QCOMPARE(firstPane()->id, pane_id);
      QCOMPARE(errors_, QString{});
    }

    Q_SLOT void terminalInputAndRendering() {
      auto* terminal = terminalIn(window_->contentItem());
      if (terminal == nullptr) {
        QFAIL("Required terminal fixture is missing");
      }

      QVERIFY(terminal->width() > 0 && terminal->height() > 0);
      terminal->forceActiveFocus();

      const QString command = QStringLiteral("printf 'TELAR_QT_INPUT_OK\\n'");

      for (const auto character : command) {
        QKeyEvent event{QEvent::KeyPress, character.toUpper().unicode(), Qt::NoModifier, QString{character}};

        QCoreApplication::sendEvent(terminal, &event);
      }

      QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

      QCoreApplication::sendEvent(terminal, &enter);
      const auto printed = [&] {
        const auto lines = screenText(firstPane()->screen).split(QLatin1Char('\n'));

        return std::ranges::any_of(lines, [](const auto& line) {
          return line.trimmed() == QLatin1StringView("TELAR_QT_INPUT_OK");
        });
      };

      QTRY_VERIFY2_WITH_TIMEOUT(printed(), qPrintable(screenText(firstPane()->screen)), runtime_wait_ms);

      const auto image = window_->grabWindow();

      QVERIFY(!image.isNull());
      QCOMPARE(client_->status()->error(), QString{});
    }

    // The monitor lists every process its runtime reads, and the detail of the one selected; with
    // TELAR_MONITOR_SHOT set, the window as it shows them is saved there.
    Q_SLOT void monitorListsTheRuntimeProcesses() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      auto* monitor = client_->monitor();

      client_->commands()->execute(window_actions::Action::monitor);
      QCOMPARE(client_->dialogs()->kind(), Store::Dialog::monitor);
      QVERIFY(monitor->available());
      QTRY_VERIFY_WITH_TIMEOUT(monitor->rows()->rowCount() > 1, runtime_wait_ms);
      QVERIFY(monitor->host().value(QStringLiteral("processes")).toInt() > 1);

      const auto first = monitor->rows()->index(0, 0).data(ListModel::record_role).toMap();

      monitor->select(first.value(QStringLiteral("pid")).toInt(), first.value(QStringLiteral("started")).toString());
      QTRY_COMPARE_WITH_TIMEOUT(monitor->detail().value(QStringLiteral("pid")).toInt(), first.value(QStringLiteral("pid")).toInt(), runtime_wait_ms);
      if (const auto shot = qEnvironmentVariable("TELAR_MONITOR_SHOT"); !shot.isEmpty()) {
        QVERIFY(window_->grabWindow().save(shot));
      }

      monitor->close();
      QCOMPARE(client_->dialogs()->kind(), Store::Dialog::none);
    }

    // A program in a pane hands the window a document: it covers the pane while the program
    // runs, scrolls by key, and goes away when the program quits.
    Q_SLOT void nativeDocumentCoversThePane() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      auto* terminal = terminalIn(window_->contentItem());

      QVERIFY(terminal != nullptr);
      terminal->forceActiveFocus();
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      QFile source{directory.filePath(QStringLiteral("document.md"))};

      QVERIFY(source.open(QIODevice::WriteOnly));
      QByteArray markdown = "# Native document\n\nSome **strong** text, `code` and a [link](https://example.com).\n\n"
                            "> [!NOTE]\n> A callout.\n\n| Name | Value |\n| :--- | ----: |\n| one | 1 |\n\n```sh\necho code\n```\n\n";

      // Enough items that the document overflows the pane and the view scrolls.
      constexpr int list_items = 60;

      for (int index = 0; index < list_items; ++index) {
        markdown += "- item " + QByteArray::number(index) + "\n";
      }

      source.write(markdown);
      source.close();
      const auto pane_id = firstPane()->id;
      const auto command = QStringLiteral("'%1' render markdown --format native --pager '%2'\r").arg(qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME"), source.fileName());

      QVERIFY(client_->terminals()->input(pane_id, command.toUtf8()));
      QTRY_VERIFY_WITH_TIMEOUT(firstPane()->document_shown, runtime_wait_ms);
      const auto* view = test::visualItems(*window_->contentItem(), QStringLiteral("documentView")).value(0);
      const auto* list = test::visualItems(*window_->contentItem(), QStringLiteral("documentList")).value(0);

      QVERIFY(view != nullptr && list != nullptr);
      QTRY_VERIFY(view->isVisible() && list->property("count").toInt() == static_cast<int>(firstPane()->document.blocks.size()));

      const auto top = list->property("contentY").toReal();
      QKeyEvent down{QEvent::KeyPress, Qt::Key_J, Qt::NoModifier, QStringLiteral("j")};

      QCoreApplication::sendEvent(terminal, &down);
      QTRY_VERIFY(list->property("contentY").toReal() > top);

      QKeyEvent quit{QEvent::KeyPress, Qt::Key_Q, Qt::NoModifier, QStringLiteral("q")};

      QCoreApplication::sendEvent(terminal, &quit);
      QTRY_VERIFY_WITH_TIMEOUT(!firstPane()->document_shown, runtime_wait_ms);
      QTRY_VERIFY(!view->isVisible());
      QCOMPARE(client_->status()->error(), QString{});
    }

    // A program prints a document's text between the sequences that begin and end it: the window
    // draws the document in place of those rows, in the rows it takes, and the shell goes on below.
    Q_SLOT void inlineDocumentTakesThePlaceOfItsRows() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      auto* terminal = terminalIn(window_->contentItem());

      QVERIFY(terminal != nullptr);
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      QFile source{directory.filePath(QStringLiteral("inline.md"))};

      QVERIFY(source.open(QIODevice::WriteOnly));
      source.write("# Inline document\n\nSome **strong** text and `code`.\n\n- one\n- two\n\n| Name | Value |\n| :--- | ----: |\n| one | 1 |\n");
      source.close();
      const auto pane_id = firstPane()->id;
      const auto command = QStringLiteral("clear; '%1' render markdown --format native '%2'; printf 'AFTER_INLINE\\n'\r").arg(qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME"), source.fileName());

      QVERIFY(client_->terminals()->input(pane_id, command.toUtf8()));
      const auto placed = [&] {
        const auto documents = terminal->property("documents").toList();

        return documents.size() == 1 && documents.front().toMap().value(QStringLiteral("placed")).toBool();
      };

      QTRY_VERIFY_WITH_TIMEOUT(placed(), runtime_wait_ms);
      const auto& document = firstPane()->inline_documents.front();

      QVERIFY(document.shown && document.view_rows > 0 && document.rows > 0);
      QTRY_VERIFY_WITH_TIMEOUT(screenText(firstPane()->screen).contains(QStringLiteral("AFTER_INLINE")), runtime_wait_ms);

      // A document taller than the pane, printed at its end, leaves the view at the end: the rows
      // after it show, and nothing waits below.
      QFile tall{directory.filePath(QStringLiteral("tall.md"))};

      QVERIFY(tall.open(QIODevice::WriteOnly));
      constexpr int tall_sections = 12;

      for (int section = 0; section < tall_sections; ++section) {
        tall.write("## Section " + QByteArray::number(section) + "\n\nA paragraph long enough to wrap in a narrow pane, with **strong** text.\n\n- one\n- two\n\n");
      }

      tall.close();
      const auto tall_command = QStringLiteral("'%1' render markdown --format native '%2'; printf 'AFTER_TALL\\n'\r").arg(qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME"), tall.fileName());

      QVERIFY(client_->terminals()->input(pane_id, tall_command.toUtf8()));
      QTRY_VERIFY_WITH_TIMEOUT(firstPane()->inline_documents.size() == 2 && firstPane()->inline_documents.back().view_rows > static_cast<std::uint32_t>(firstPane()->screen.rows()), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(screenText(firstPane()->screen).contains(QStringLiteral("AFTER_TALL")), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(terminal->property("rowsBelow").toInt(), 0, runtime_wait_ms);
      const auto cursor_row = terminal->property("cursorRow").toInt();

      QVERIFY2(cursor_row >= 0 && std::cmp_less(cursor_row, firstPane()->screen.rows()), qPrintable(QString::number(cursor_row)));
      // Read from the top, the way back to the end is the jump the view offers.
      QVERIFY(QMetaObject::invokeMethod(terminal, "scrollToFraction", Q_ARG(qreal, 0.0), Q_ARG(bool, false)));
      QTRY_VERIFY_WITH_TIMEOUT(terminal->property("rowsBelow").toInt() > 0, runtime_wait_ms);
      QVERIFY(QMetaObject::invokeMethod(terminal, "scrollToEnd"));
      QTRY_COMPARE_WITH_TIMEOUT(terminal->property("rowsBelow").toInt(), 0, runtime_wait_ms);

      // Once the text they stand for is erased, scrollback and screen, the documents go and the rows
      // show what they hold.
      QVERIFY(client_->terminals()->input(pane_id, QByteArrayLiteral("printf '\\033[3J\\033[2J\\033[HSCREEN_CLEARED\\n'\r")));
      QTRY_VERIFY_WITH_TIMEOUT(firstPane()->inline_documents.empty() && terminal->property("documents").toList().isEmpty(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(screenText(firstPane()->screen).contains(QStringLiteral("SCREEN_CLEARED")), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(terminal->property("cursorRow").toInt(), static_cast<int>(firstPane()->screen.cursor().y), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void keyRestoresCursorBlinkPhase() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      auto* terminal = terminalIn(window_->contentItem());

      QVERIFY(terminal != nullptr);
      terminal->forceActiveFocus();
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* pane = firstPane();

      QVERIFY(pane != nullptr && pane->screen.cursor().visible);
      const auto position = pane->screen.cursor();
      const auto cell = terminal->cellSize();
      const auto origin = terminal->mapToScene(QPointF{position.x * cell.width(), position.y * cell.height()});
      const auto scale = window_->effectiveDevicePixelRatio();
      const auto rectangle = QRectF{origin * scale, cell * scale}.toAlignedRect();
      test::TerminalCursor cursor{*terminal};

      cursor.setVisible(true);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto visible = window_->grabWindow().copy(rectangle);

      QVERIFY(!visible.isNull());
      cursor.setVisible(false);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto hidden = window_->grabWindow().copy(rectangle);

      QVERIFY(visible != hidden);

      for (const bool starts_visible : {false, true}) {
        cursor.setVisible(starts_visible);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        QKeyEvent event{QEvent::KeyPress, Qt::Key_Shift, Qt::ShiftModifier};

        QCoreApplication::sendEvent(terminal, &event);
        QVERIFY(event.isAccepted());
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        QCOMPARE(window_->grabWindow().copy(rectangle), visible);
        QCOMPARE(pane->screen.cursor().x, position.x);
        QCOMPARE(pane->screen.cursor().y, position.y);
      }
    }

    Q_SLOT void singlePaneIsFramedInsideTheWorkbench() {
      const auto* terminal = terminalIn(window_->contentItem());
      if (terminal == nullptr) {
        QFAIL("Required terminal fixture is missing");
      }

      QCOMPARE(client_->panes()->rows()->rowCount(), 1);
      const auto fits_framed_content = [this, terminal] {
        const auto bounds = client_->display()->geometry().value(QStringLiteral("terminal")).toRectF();
        const auto density = window_->effectiveDevicePixelRatio();
        const auto resolved = client_->resolveFont(density);
        constexpr std::uint16_t border_cells = 2;
        const auto header_cells = static_cast<std::uint16_t>(std::ceil(ChromeMetrics::logical_pane_header * density / resolved.grid.height));
        const auto columns = static_cast<std::uint16_t>(std::floor(bounds.width() * density / resolved.grid.width) - border_cells);
        const auto rows = static_cast<std::uint16_t>(std::floor(bounds.height() * density / resolved.grid.height) - header_cells - 1);
        const QSizeF expected{columns * resolved.grid.width / density, rows * resolved.grid.height / density};
        const QRectF placed{terminal->mapToScene(QPointF{}), expected};
        if (terminal->size() != expected || placed.left() <= bounds.left() || placed.top() <= bounds.top() || !bounds.contains(placed)) {
          return false;
        }

        const auto* pane = firstPane();

        return pane != nullptr && pane->screen.columns() == columns && pane->screen.rows() == rows;
      };

      QVERIFY2(telar::gui::test::waitForGuiCondition(fits_framed_content, runtime_wait_ms), qPrintable(QStringLiteral("window=%1x%2 terminal=%3x%4").arg(window_->width()).arg(window_->height()).arg(terminal->width()).arg(terminal->height())));
    }

    Q_SLOT void tabSwitchKeepsTerminalViewport() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto original_id = firstPane()->id;
      const auto original_tab = QString::number(firstPane()->location.tab_id);
      const auto original_size = firstPane()->size;
      const auto tab_count = client_->tabs()->rows()->rowCount();
      QString temporary_tab;
      const auto restore = qScopeGuard([&] {
        if (!temporary_tab.isEmpty()) {
          client_->commands()->execute(window_actions::Action::select_tab, temporary_tab);
          closeTemporaryTab({.count = tab_count, .pane_id = original_id});
        }
      });

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != original_id, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      temporary_tab = QString::number(firstPane()->location.tab_id);
      const auto viewport = client_->terminals()->viewVersion().viewport;

      constexpr int repetitions = 7;

      for (int index = 0; index < repetitions; ++index) {
        client_->commands()->execute(window_actions::Action::select_tab, original_tab);
        QCOMPARE(client_->terminals()->viewVersion().viewport, viewport);
        const auto* pane = client_->pane(original_id);

        QVERIFY(pane != nullptr);
        QCOMPARE(pane->size.cols, original_size.cols);
        QCOMPARE(pane->size.rows, original_size.rows);
        QCOMPARE(pane->size.cell_width_px, original_size.cell_width_px);
        QCOMPARE(pane->size.cell_height_px, original_size.cell_height_px);
        QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == original_id, runtime_wait_ms);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        QCOMPARE(client_->terminals()->viewVersion().viewport, viewport);

        client_->commands()->execute(window_actions::Action::select_tab, temporary_tab);
        QCOMPARE(client_->terminals()->viewVersion().viewport, viewport);
        QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != original_id, runtime_wait_ms);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        QCOMPARE(client_->terminals()->viewVersion().viewport, viewport);
      }
    }

    Q_SLOT void componentOwnership() {
      TerminalItem terminal;

      {
        ApplicationController isolated{memory_};

        terminal.setController(isolated.terminals());
        QCOMPARE(terminal.controller(), isolated.terminals());
      }

      QCOMPARE(terminal.controller(), nullptr);
    }

    Q_SLOT void promptDialogRenamesTab() {
      const auto tab_label = [&] {
        return client_->tabs()->rows()->data(client_->tabs()->rows()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("label")).toString();
      };

      const auto original_label = tab_label();
      const auto cleanup = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      auto* motion = window_->findChild<ModalRevealLayout*>(QStringLiteral("promptModalMotion"));

      QVERIFY(motion != nullptr);
      qreal lowest_reveal = 1;
      const auto connection = QObject::connect(motion, &ModalRevealLayout::frameChanged, window_, [&] {
        lowest_reveal = std::min(lowest_reveal, motion->reveal());
      });

      const auto disconnect = qScopeGuard([connection] {
        QObject::disconnect(connection);
      });

      client_->commands()->execute(window_actions::Action::rename_tab);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::rename_tab);
      const auto* field = window_->findChild<NativeFormField*>(QStringLiteral("commandSearch"));
      const auto* submit = window_->findChild<QQuickItem*>(QStringLiteral("promptSubmit"));

      QVERIFY(field != nullptr && submit != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(field->hasActiveFocus(), runtime_wait_ms);
      // The prompt enters from transparent on the first frame after it opens.
      QTRY_VERIFY_WITH_TIMEOUT(lowest_reveal < 1, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(motion->reveal(), qreal{1}, runtime_wait_ms);
      QVERIFY(!submit->property("interactive").toBool());

      const auto renamed = QStringLiteral("Renamed by keys");

      typeText(renamed);
      QTRY_COMPARE_WITH_TIMEOUT(field->text(), renamed, runtime_wait_ms);
      QVERIFY(submit->property("interactive").toBool());
      captureArtifact(QStringLiteral("prompt-rename-tab"));

      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_COMPARE_WITH_TIMEOUT(tab_label(), renamed, runtime_wait_ms);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);

      client_->commands()->execute(window_actions::Action::rename_tab);
      QTRY_VERIFY_WITH_TIMEOUT(field->hasActiveFocus(), runtime_wait_ms);
      typeText(QStringLiteral("discarded"));
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none, runtime_wait_ms);
      QCOMPARE(tab_label(), renamed);

      client_->commands()->execute(window_actions::Action::rename_tab);
      client_->commands()->submitDialog({{QStringLiteral("text"), original_label}, {QStringLiteral("path"), QString{}}});
      QTRY_COMPARE_WITH_TIMEOUT(tab_label(), original_label, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void workspaceFormCompletesFoldersAndCreatesMissingOnes() {
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const QDir root{QFileInfo{directory.path()}.canonicalFilePath()};

      for (const auto* name : {"alpha", "beta", ".hidden"}) {
        QVERIFY(root.mkdir(QString::fromLatin1(name)));
      }

      writeTestFile(root.filePath(QStringLiteral("notes.txt")), "file");
      const auto workspaces = client_->workspaces()->rows()->rowCount();
      const auto original_workspace = client_->workspaces()->context().value(QStringLiteral("key")).toString();
      const auto original_workspace_id = firstPane()->location.workspace.id;
      const auto cleanup = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      const auto entries = [this] {
        return client_->workspaceForm()->state().value(QStringLiteral("entries")).toStringList();
      };

      const auto focused = [this] {
        return window_->activeFocusItem() == nullptr ? QString{} : window_->activeFocusItem()->objectName();
      };

      client_->commands()->execute(window_actions::Action::new_workspace);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::new_workspace);
      QTRY_COMPARE_WITH_TIMEOUT(focused(), QStringLiteral("commandSearch"), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_COMPARE_WITH_TIMEOUT(focused(), QStringLiteral("workspaceDirectory"), runtime_wait_ms);
      const auto* field = window_->findChild<NativeFormField*>(QStringLiteral("workspaceDirectory"));

      QVERIFY(field != nullptr);
      QCOMPARE(field->text(), QString{});

      typeText(root.path() + QLatin1Char('/'));
      QTRY_COMPARE_WITH_TIMEOUT(entries(), (QStringList{QStringLiteral("alpha"), QStringLiteral("beta")}), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Down);
      QTRY_COMPARE_WITH_TIMEOUT(client_->workspaceForm()->state().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);
      captureArtifact(QStringLiteral("workspace-folders"));
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_COMPARE_WITH_TIMEOUT(field->text(), root.filePath(QStringLiteral("beta")) + QLatin1Char('/'), runtime_wait_ms);
      QCOMPARE(focused(), QStringLiteral("workspaceDirectory"));
      QTest::keyClick(window_, Qt::Key_Backtab);
      QTRY_COMPARE_WITH_TIMEOUT(focused(), QStringLiteral("commandSearch"), runtime_wait_ms);

      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_COMPARE_WITH_TIMEOUT(focused(), QStringLiteral("workspaceDirectory"), runtime_wait_ms);
      typeText(QStringLiteral("gamma"));
      const auto missing = root.filePath(QStringLiteral("beta/gamma"));

      QTRY_COMPARE_WITH_TIMEOUT(field->text(), missing, runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_VERIFY_WITH_TIMEOUT(client_->workspaceForm()->state().value(QStringLiteral("confirmCreate")).toBool(), runtime_wait_ms);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::new_workspace);
      QVERIFY(!QFileInfo::exists(missing));
      captureArtifact(QStringLiteral("workspace-confirm"));

      const auto workspace_names = [this] {
        QStringList names;

        for (int row = 0; row < client_->workspaces()->rows()->rowCount(); ++row) {
          names.append(client_->workspaces()->rows()->data(client_->workspaces()->rows()->index(row, 0), ListModel::record_role).toMap().value(QStringLiteral("name")).toString());
        }

        return names;
      };

      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->workspaces()->rows()->rowCount(), workspaces + 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(QFileInfo{missing}.isDir(), runtime_wait_ms);
      QVERIFY2(workspace_names().contains(QStringLiteral("gamma")), qPrintable(workspace_names().join(QLatin1Char(','))));
      // Wait for the workspace snapshot before closing its last tab.
      QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->location.workspace.id != original_workspace_id && terminalReady(), runtime_wait_ms);
      const auto created_workspace = client_->workspaces()->context().value(QStringLiteral("key")).toString();

      for (const auto& key : {original_workspace, created_workspace}) {
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        const QQuickItem* target = nullptr;

        for (const auto* mark : test::visualItems(*window_->contentItem(), QStringLiteral("projectSwitcherMark"))) {
          if (mark->property("record").toMap().value(QStringLiteral("key")).toString() == key) {
            target = mark;
            break;
          }
        }

        QVERIFY(target != nullptr);
        QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, target->mapRectToScene(target->boundingRect()).center().toPoint());
        QTRY_COMPARE_WITH_TIMEOUT(client_->workspaces()->context().value(QStringLiteral("key")).toString(), key, runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      }

      captureArtifact(QStringLiteral("project-switcher"));
      client_->commands()->execute(window_actions::Action::close_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->workspaces()->rows()->rowCount(), workspaces, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void qmlActionBindings() {
      const auto original_tabs = client_->tabs()->rows()->rowCount();
      const auto cleanup = qScopeGuard([this, original_tabs] {
        closeExtraTabs(original_tabs);
      });

      auto* context = qmlContext(window_);
      if (context == nullptr) {
        QFAIL("The GUI window must have its QML context");
      }

      QQmlExpression open{context, window_, QStringLiteral("telar.commands.execute(WindowActions.Action.palette)")};

      static_cast<void>(open.evaluate());
      QVERIFY2(!open.hasError(), qPrintable(open.error().toString()));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);

      QQmlExpression cancel{context, window_, QStringLiteral("telar.commands.execute(WindowActions.Action.cancel)")};

      static_cast<void>(cancel.evaluate());
      QVERIFY2(!cancel.hasError(), qPrintable(cancel.error().toString()));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);

      const auto tab_label = [&] {
        return client_->tabs()->rows()->data(client_->tabs()->rows()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("label")).toString();
      };

      const auto original_label = tab_label();

      client_->commands()->execute(window_actions::Action::rename_tab);
      QQmlExpression rename{context, window_, QStringLiteral("telar.commands.submitDialog({text: 'QML renamed tab', path: ''})")};

      static_cast<void>(rename.evaluate());
      QVERIFY2(!rename.hasError(), qPrintable(rename.error().toString()));
      QTRY_COMPARE_WITH_TIMEOUT(tab_label(), QStringLiteral("QML renamed tab"), runtime_wait_ms);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      client_->commands()->execute(window_actions::Action::rename_tab);
      client_->commands()->submitDialog({{QStringLiteral("text"), original_label}, {QStringLiteral("path"), QString{}}});
      QTRY_COMPARE_WITH_TIMEOUT(tab_label(), original_label, runtime_wait_ms);

      client_->commands()->execute(window_actions::Action::palette);
      client_->palette()->search(QStringLiteral(">New tab"));
      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));
      if (search == nullptr) {
        QFAIL("Required command search fixture is missing");
      }

      search->forceActiveFocus();
      QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), QStringLiteral(">New tab"), runtime_wait_ms);
      QKeyEvent activate{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier};

      QCoreApplication::sendEvent(search, &activate);
      QTRY_COMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_tabs + 1, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::close_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_tabs, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->screen.frameId() > 0, runtime_wait_ms);
    }

    Q_SLOT void workspaceListVisibility() {
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QTRY_VERIFY(!client_->display()->geometry().value(QStringLiteral("rail")).toBool());
      QVERIFY(window_->findChild<QQuickItem*>(QStringLiteral("workspaceList")) == nullptr);
      const auto* projects = window_->findChild<QQuickItem*>(QStringLiteral("projectSwitcher"));
      auto* terminal = terminalIn(window_->contentItem());
      if (projects == nullptr || terminal == nullptr) {
        QFAIL("Required project switcher and terminal fixtures are missing");
      }

      QTRY_VERIFY(projects->isVisible());
      const auto focused_pane = firstPane()->id;
      const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
      QKeyEvent prefix{QEvent::KeyPress, Qt::Key_B, control};
      QKeyEvent collapse{QEvent::KeyPress, Qt::Key_W, Qt::NoModifier, QStringLiteral("w")};

      QCoreApplication::sendEvent(terminal, &prefix);
      QCoreApplication::sendEvent(terminal, &collapse);
      QVERIFY(client_->display()->workspaceListCollapsed());
      QTRY_VERIFY(projects->isVisible());
      QCOMPARE(firstPane()->id, focused_pane);

      client_->commands()->execute(window_actions::Action::toggle_workspace_list);
      QVERIFY(!client_->display()->workspaceListCollapsed());
      QTRY_VERIFY(projects->isVisible());
      client_->commands()->execute(window_actions::Action::toggle_sidebar);
      QTRY_COMPARE(client_->display()->geometry().value(QStringLiteral("sidebar")).toRectF().width(), qreal{0});
      QTRY_VERIFY(projects->isVisible());
      QCOMPARE(firstPane()->id, focused_pane);
      client_->commands()->execute(window_actions::Action::toggle_sidebar);
    }

    Q_SLOT void pointerSelection() {
      auto* clipboard = QGuiApplication::clipboard();
      auto saved_clipboard = test::copyClipboard();
      const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved_clipboard)] mutable {
        clipboard->setMimeData(saved.release());
      });

      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      auto* terminal = terminalIn(window_->contentItem());
      const auto* pane = firstPane();
      if (terminal == nullptr || pane == nullptr) {
        QFAIL("Required terminal and pane fixtures are missing");
      }

      constexpr auto path = QLatin1StringView("/tmp/telar/file.cpp");

      client_->terminals()->input(pane->id, "printf '\\033[2J\\033[H/tmp/telar/file.cpp\\n'\r");
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).startsWith(path), runtime_wait_ms);
      terminal->forceActiveFocus();
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto cell = terminal->cellSize();
      const auto clicked = terminal->mapToScene({cell.width() * 2, cell.height() / 2}).toPoint();

      clipboard->setText(QStringLiteral("unchanged clipboard"));
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, clicked);
      QCOMPARE(clipboard->text(), QStringLiteral("unchanged clipboard"));
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, clicked);
      QTRY_COMPARE_WITH_TIMEOUT(clipboard->text(), path, runtime_wait_ms);
      QVERIFY(!client_->copy()->active());
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, clicked);
      QVERIFY(client_->copy()->state() && client_->copy()->state()->linewise);
      QTest::keyClick(window_, Qt::Key_X);
      QVERIFY(!client_->copy()->state());
      client_->terminals()->input(pane->id, "\x15");
      const auto click_wait_ms = static_cast<int>(application::terminal::copy_mode::ClickTracker::interval.count()) + 1;

      QTest::qWait(click_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto beginning = terminal->mapToScene({cell.width() / 2, cell.height() / 2}).toPoint();
      const auto end = terminal->mapToScene({(cell.width() * 3) + (cell.width() / 2), cell.height() / 2}).toPoint();

      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, beginning);
      QTest::mouseMove(window_, end);
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, end);
      QTRY_COMPARE_WITH_TIMEOUT(clipboard->text(), QStringLiteral("/tmp"), runtime_wait_ms);
      QTest::qWait(click_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      clipboard->setText(QStringLiteral("pending recovery"));
      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, beginning);
      QTest::mouseMove(window_, end);
      terminal->ungrabMouse();
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, end);
      QTRY_COMPARE_WITH_TIMEOUT(clipboard->text(), QStringLiteral("/tmp"), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_X);
      client_->terminals()->input(pane->id, "\x15");
      client_->commands()->execute(window_actions::Action::copy_mode);
      QInputMethodEvent committed;

      committed.setCommitString(QStringLiteral("q"));
      QCoreApplication::sendEvent(terminal, &committed);
      QVERIFY(!client_->copy()->active());
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void detectedLinkHoverAndCopy() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(window_->isExposed(), runtime_wait_ms);
      if (!window_->isActive()) {
        test::activateWindow(*window_);
      }

      QTRY_VERIFY_WITH_TIMEOUT(window_->isActive(), runtime_wait_ms);
      auto* terminal = terminalIn(window_->contentItem());
      const auto* pane = firstPane();
      if (terminal == nullptr || pane == nullptr) {
        QFAIL("Required terminal and pane fixtures are missing");
      }

      auto* clipboard = QGuiApplication::clipboard();
      const auto restore_clipboard = qScopeGuard([clipboard, saved = test::copyClipboard()] mutable {
        clipboard->setMimeData(saved.release());
      });

      client_->terminals()->input(pane->id, "printf '\\033[2J\\033[H[docs](https://plain.test/x)\\n/tmp/telar/source.cpp:12:3\\n\\033]8;;https://destination.test\\033\\\\https://label.test\\033]8;;\\033\\\\\\nLINK_HOVER_READY\\n'\r");
      QTRY_VERIFY2_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).startsWith(QLatin1StringView("[docs](https://plain.test/x)")) && screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("LINK_HOVER_READY")), qPrintable(QStringLiteral("columns=%1 contents=%2").arg(pane->screen.columns()).arg(screenText(pane->screen))), runtime_wait_ms);
      const auto path_row = logicalRowStart(pane->screen, 1);
      const auto osc_row = logicalRowStart(pane->screen, 2);
      const auto blank_row = logicalRowStart(pane->screen, 4);

      QVERIFY(path_row.hasValue() && osc_row.hasValue() && blank_row.hasValue());
      terminal->forceActiveFocus();
      QTest::mouseMove(window_, cellCenter(*terminal, {.x = 2}));
      QTRY_VERIFY2(terminal->hoveredLink() == QStringLiteral("https://plain.test/x"), qPrintable(QStringLiteral("hover=%1 active=%2 itemFocus=%3 copy=%4 modifiers=%5 frame=%6/%7 cursor=%8,%9").arg(terminal->hoveredLink()).arg(window_->isActive()).arg(terminal->hasActiveFocus()).arg(client_->copy()->active()).arg(client_->terminals()->pointerModifiers().toInt()).arg(pane->acknowledged_frame).arg(pane->screen.frameId()).arg(QCursor::pos().x()).arg(QCursor::pos().y())));
      QCOMPARE(terminal->cursor().shape(), Qt::PointingHandCursor);
      QTRY_VERIFY(terminal->linkPreview().value(QStringLiteral("visible")).toBool());
      QVERIFY(test::waitForGuiCondition([&] {
        return pane->acknowledged_frame == pane->screen.frameId() && !terminal->prepareLinkPresentation();
      },
          runtime_wait_ms));
      QTest::mouseClick(window_, Qt::RightButton, Qt::NoModifier, cellCenter(*terminal, {.x = 2}));
      QTRY_COMPARE(clipboard->text(), QStringLiteral("https://plain.test/x"));

      QTest::mouseMove(window_, cellCenter(*terminal, {.x = 0, .y = *blank_row}));
      QTest::qWait(frame_settle_ms);
      const auto path_position = cellCenter(*terminal, {.x = 2, .y = *path_row});

      QTest::mouseMove(window_, path_position);
      QTRY_COMPARE(terminal->hoveredLink(), QString{});
      QCOMPARE(terminal->cursor().shape(), Qt::IBeamCursor);
      QTest::qWait(frame_settle_ms);
      QTest::keyPress(window_, Qt::Key_Control, Qt::ControlModifier);
      QCOMPARE(client_->terminals()->pointerModifiers(), Qt::KeyboardModifiers{Qt::ControlModifier});
      QVERIFY(terminal->hasActiveFocus());
      QVERIFY(window_->isActive());
      QTRY_VERIFY2(terminal->hoveredLink() == QStringLiteral("/tmp/telar/source.cpp:12:3"), qPrintable(QStringLiteral("Modifiers: %1; cursor: %2; preview: %3; copy: %4; contents: %5").arg(client_->terminals()->pointerModifiers().toInt()).arg(terminal->cursor().shape()).arg(terminal->linkPreview().value(QStringLiteral("visible")).toBool()).arg(client_->copy()->active()).arg(screenText(pane->screen))));
      QTest::keyRelease(window_, Qt::Key_Control);
      QTRY_COMPARE(terminal->hoveredLink(), QString{});
      QTest::qWait(frame_settle_ms);
      QTest::mouseClick(window_, Qt::RightButton, Qt::NoModifier, path_position);
      QTRY_COMPARE(clipboard->text(), QStringLiteral("/tmp/telar/source.cpp:12:3"));

      QTest::mouseMove(window_, cellCenter(*terminal, {.x = 2, .y = *osc_row}));
      QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://destination.test"));
      QTest::qWait(frame_settle_ms);
      QTest::keyPress(window_, Qt::Key_Alt, Qt::AltModifier);
      QTRY_COMPARE(terminal->hoveredLink(), QString{});
      QCOMPARE(terminal->cursor().shape(), Qt::PointingHandCursor);
      QTest::keyRelease(window_, Qt::Key_Alt);
      QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://destination.test"));
      QTest::mouseMove(window_, cellCenter(*terminal, {.y = *blank_row}));
      QTRY_COMPARE(terminal->hoveredLink(), QString{});
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void wheelReportingAndCopyOwnership() {
      const auto original_tabs = client_->tabs()->rows()->rowCount();
      const auto* original_pane = firstPane();

      QVERIFY(original_pane != nullptr);
      const auto original_identity = original_pane->id;

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_tabs + 1, runtime_wait_ms);
      auto restore = qScopeGuard([this, original_tabs, original_identity] {
        closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
      });

      QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->id != original_identity && firstPane()->screen.frameId() > 0, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      auto* terminal = terminalIn(window_->contentItem());
      const auto* pane = firstPane();
      if (terminal == nullptr || pane == nullptr) {
        QFAIL("Required terminal and pane fixtures are missing");
      }

      terminal->forceActiveFocus();
      constexpr std::string_view expected = "\x1b[<0;1;1M\x1b[<0;2;1m\x1b[<68;1;1M\x1b[<64;1;1M";
      const auto capture = QStringLiteral("stty raw -echo; printf '\\033[?1000h\\033[?1006h'; dd bs=1 count=%1 2>/dev/null | od -An -tx1 | tr -d ' \\n'; printf '\\033[?1000l\\033[?1006l'; stty sane\r").arg(expected.size());

      client_->terminals()->input(pane->id, capture.toUtf8());
      QTRY_VERIFY_WITH_TIMEOUT(pane->screen.mouse().sgr && pane->screen.mouse().tracking == telar::MouseTracking::normal, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::copy_mode);
      QVERIFY(client_->copy()->active());
      constexpr int wheel_notch = 120;
      const QPointF local{1, 1};
      QWheelEvent owned{local, terminal->mapToGlobal(local), {}, {0, wheel_notch}, Qt::NoButton, Qt::ShiftModifier, Qt::NoScrollPhase, false};

      QCoreApplication::sendEvent(terminal, &owned);
      QTest::qWait(frame_settle_ms);
      QVERIFY(pane->screen.mouse().sgr && client_->copy()->active());
      client_->commands()->execute(window_actions::Action::cancel);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::ShiftModifier, terminal->mapToScene(local).toPoint());
      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, terminal->mapToScene(local).toPoint());
      const auto moved = terminal->mapToScene({terminal->cellSize().width() + 1, 1}).toPoint();

      QTest::mouseMove(window_, moved);
      terminal->ungrabMouse();
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, moved);
      QWheelEvent report{local, terminal->mapToGlobal(local), {}, {0, wheel_notch}, Qt::NoButton, Qt::ShiftModifier, Qt::NoScrollPhase, false};

      QCoreApplication::sendEvent(terminal, &report);
      QTest::keyClick(window_, Qt::Key_B, NativeKeyAdapter::control_modifier);
      QTest::keyClick(window_, Qt::Key_Minus);
      const auto expected_hex = QString::fromLatin1(QByteArray{expected.data(), static_cast<qsizetype>(expected.size())}.toHex());

      QTRY_VERIFY2_WITH_TIMEOUT(screenText(pane->screen).remove(QLatin1Char('\n')).contains(expected_hex), qPrintable(QStringLiteral("Expected %1, columns %2, screen:\n%3").arg(expected_hex).arg(pane->screen.columns()).arg(screenText(pane->screen))), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!pane->screen.mouse().sgr, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
      closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
      restore.dismiss();
    }

    Q_SLOT void simultaneousChildMouseButtons() {
      constexpr std::string_view expected = "\x1b[<0;1;1M\x1b[<1;1;1M\x1b[<0;1;1m\x1b[<33;2;1M\x1b[<1;2;1m";

      verifyChildMouse(expected, [](QQuickWindow& window, TerminalItem& terminal) {
        const auto first = cellCenter(terminal, {});
        const auto second = cellCenter(terminal, {.x = 1});

        sendMouse(window, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, first);
        sendMouse(window, QEvent::MouseButtonPress, Qt::MiddleButton, Qt::LeftButton | Qt::MiddleButton, first);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::MiddleButton, first);
        sendMouse(window, QEvent::MouseMove, Qt::NoButton, Qt::MiddleButton, second);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::MiddleButton, Qt::NoButton, second);
      });
    }

    Q_SLOT void cancelChildMouseButtons() {
      constexpr std::string_view expected = "\x1b[<0;1;1M\x1b[<1;1;1M\x1b[<32;2;2M\x1b[<33;2;2M\x1b[<0;2;2m\x1b[<1;2;2m";

      verifyChildMouse(expected, [](QQuickWindow& window, TerminalItem& terminal) {
        const auto first = cellCenter(terminal, {});
        const auto second = cellCenter(terminal, {.x = 1, .y = 1});
        const auto held = Qt::LeftButton | Qt::MiddleButton;

        sendMouse(window, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, first);
        sendMouse(window, QEvent::MouseButtonPress, Qt::MiddleButton, held, first);
        sendMouse(window, QEvent::MouseMove, Qt::NoButton, held, second);
        terminal.ungrabMouse();
        sendMouse(window, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::MiddleButton, second);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::MiddleButton, Qt::NoButton, second);
      });
    }

    Q_SLOT void legacyChildTrackingIsIgnored() {
      verifyChildMouse({}, [](QQuickWindow& window, TerminalItem& terminal) {
        const auto position = cellCenter(terminal, {});

        sendMouse(window, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, position);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, position);
        constexpr int wheel_notch = 120;
        const QPointF local{terminal.cellSize().width() / 2, terminal.cellSize().height() / 2};
        QWheelEvent wheel{local, terminal.mapToGlobal(local), {}, {0, wheel_notch}, Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false};

        QCoreApplication::sendEvent(&terminal, &wheel);
      },
          ChildMouseEncoding::legacy);
    }

    Q_SLOT void childMouseSurvivesPaneFocusChange() {
      constexpr std::string_view expected = "\x1b[<0;1;1M\x1b[<1;1;1M\x1b[<32;2;2M\x1b[<33;2;2M\x1b[<0;2;2m\x1b[<1;2;2m";

      verifyChildMouse(expected, [this](QQuickWindow& window, TerminalItem& terminal) {
        const QPointer<TerminalItem> retained{&terminal};
        const auto first = cellCenter(terminal, {});
        const auto held = Qt::LeftButton | Qt::MiddleButton;

        sendMouse(window, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, first);
        sendMouse(window, QEvent::MouseButtonPress, Qt::MiddleButton, held, first);
        client_->commands()->execute(window_actions::Action::split_horizontal);
        QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
        QVERIFY(retained != nullptr);
        QTRY_VERIFY_WITH_TIMEOUT(!retained->hasActiveFocus(), runtime_wait_ms);
        const auto second = cellCenter(terminal, {.x = 1, .y = 1});

        sendMouse(window, QEvent::MouseMove, Qt::NoButton, held, second);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::MiddleButton, second);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::MiddleButton, Qt::NoButton, second);
      });
    }

    Q_SLOT void childMouseAcrossPanes() {
      constexpr std::string_view expected = "\x1b[<0;1;1M\x1b[<32;2;2M\x1b[<0;2;2m";

      verifyChildMouse(expected, [this](QQuickWindow& window, TerminalItem& terminal) {
        client_->commands()->execute(window_actions::Action::split_horizontal);
        QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
        auto* other = focusedTerminalBeside(window, terminal);
        if (other == nullptr) {
          QFAIL("Required second terminal fixture is missing");
        }

        QVERIFY(other != &terminal);
        QVERIFY(other->mapToScene({}).x() > terminal.mapToScene({terminal.width(), 0}).x());
        constexpr std::string_view other_expected = "\x1b[<1;1;1M\x1b[<33;1;2M\x1b[<1;2;2m";

        beginChildMouseCapture(*other, other_expected.size());
        QTRY_COMPARE_WITH_TIMEOUT(client_->pane(terminal.paneIdentity())->acknowledged_frame, client_->pane(terminal.paneIdentity())->screen.frameId(), runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(!terminal.prepareLinkPresentation(), runtime_wait_ms);
        const auto first = cellCenter(terminal, {});
        const auto second = cellCenter(*other, {});
        const auto moved = cellCenter(terminal, {.x = 1, .y = 1});
        const auto held = Qt::LeftButton | Qt::MiddleButton;

        sendMouse(window, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, first);
        sendMouse(window, QEvent::MouseButtonPress, Qt::MiddleButton, held, second);
        sendMouse(window, QEvent::MouseMove, Qt::NoButton, held, moved);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::MiddleButton, moved);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::MiddleButton, Qt::NoButton, cellCenter(*other, {.x = 1, .y = 1}));
        finishChildMouseCapture(other->paneIdentity(), other_expected);
      });
    }

    Q_SLOT void cancelChildMouseAcrossPanes() {
      constexpr std::string_view expected = "\x1b[<0;1;1M\x1b[<0;1;1m";

      verifyChildMouse(expected, [this](QQuickWindow& window, TerminalItem& terminal) {
        client_->commands()->execute(window_actions::Action::split_horizontal);
        QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
        auto* other = focusedTerminalBeside(window, terminal);

        QVERIFY(other != nullptr && other != &terminal);
        constexpr std::string_view other_expected = "\x1b[<1;1;1M\x1b[<1;1;1m";

        beginChildMouseCapture(*other, other_expected.size());
        QTRY_COMPARE_WITH_TIMEOUT(client_->pane(terminal.paneIdentity())->acknowledged_frame, client_->pane(terminal.paneIdentity())->screen.frameId(), runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(!terminal.prepareLinkPresentation(), runtime_wait_ms);
        const auto first = cellCenter(terminal, {});
        const auto second = cellCenter(*other, {});

        sendMouse(window, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, first);
        sendMouse(window, QEvent::MouseButtonPress, Qt::MiddleButton, Qt::LeftButton | Qt::MiddleButton, second);
        other->ungrabMouse();
        sendMouse(window, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::MiddleButton, second);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::MiddleButton, Qt::NoButton, first);
        finishChildMouseCapture(other->paneIdentity(), other_expected);
      });
    }

    Q_SLOT void childMouseSurvivesHiddenView() {
      constexpr std::string_view expected = "\x1b[<0;1;1M\x1b[<32;2;2M\x1b[<0;2;2m";

      verifyChildMouse(expected, [](QQuickWindow& window, TerminalItem& terminal) {
        const auto first = cellCenter(terminal, {});
        const auto moved = cellCenter(terminal, {.x = 1, .y = 1});

        sendMouse(window, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, first);
        terminal.setVisible(false);
        const auto restore = qScopeGuard([&terminal] {
          terminal.setVisible(true);
        });

        QVERIFY(!terminal.isVisible());
        sendMouse(window, QEvent::MouseMove, Qt::NoButton, Qt::LeftButton, moved);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, moved);
      });
    }

    Q_SLOT void closingOnePointerOwnerPreservesAnother() {
      constexpr std::string_view expected = "\x1b[<0;1;1M\x1b[<32;2;2M\x1b[<0;2;2m";

      verifyChildMouse(expected, [this, expected](QQuickWindow& window, TerminalItem& terminal) {
        client_->commands()->execute(window_actions::Action::split_horizontal);
        QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
        auto* other = focusedTerminalBeside(window, terminal);

        QVERIFY(other != nullptr && other != &terminal);
        const auto other_id = other->paneIdentity();

        beginChildMouseCapture(*other, expected.size());
        QTRY_COMPARE_WITH_TIMEOUT(client_->pane(terminal.paneIdentity())->acknowledged_frame, client_->pane(terminal.paneIdentity())->screen.frameId(), runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(!terminal.prepareLinkPresentation(), runtime_wait_ms);
        sendMouse(window, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, cellCenter(terminal, {}));
        sendMouse(window, QEvent::MouseButtonPress, Qt::MiddleButton, Qt::LeftButton | Qt::MiddleButton, cellCenter(*other, {}));
        client_->commands()->execute(window_actions::Action::close_pane, QString::number(other_id));
        QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 1, runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(client_->pane(other_id) == nullptr, runtime_wait_ms);
        const auto* remaining = terminalIn(window.contentItem());

        QVERIFY(remaining != nullptr);
        const auto* pane = client_->pane(remaining->paneIdentity());

        QVERIFY(pane != nullptr);
        QTRY_COMPARE_WITH_TIMEOUT(pane->acknowledged_frame, pane->screen.frameId(), runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(!remaining->prepareLinkPresentation(), runtime_wait_ms);
        const auto moved = cellCenter(*remaining, {.x = 1, .y = 1});

        sendMouse(window, QEvent::MouseMove, Qt::NoButton, Qt::LeftButton | Qt::MiddleButton, moved);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::MiddleButton, Qt::LeftButton, moved);
        sendMouse(window, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, moved);
      });
    }

    Q_SLOT void copyModeKeyboardSearch() {
      auto* clipboard = QGuiApplication::clipboard();
      auto saved_clipboard = test::copyClipboard();
      const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved_clipboard)] mutable {
        clipboard->setMimeData(saved.release());
      });

      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      auto* terminal = terminalIn(window_->contentItem());
      const auto* pane = firstPane();
      if (terminal == nullptr || pane == nullptr) {
        QFAIL("Required terminal and pane fixtures are missing");
      }

      client_->terminals()->input(pane->id, "printf 'COPY_MODE_WORD_1\\nCOPY_MODE_WORD_2\\n'\r");
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).contains(QLatin1StringView("COPY_MODE_WORD_2")), runtime_wait_ms);
      terminal->forceActiveFocus();
      QTest::keyClick(window_, Qt::Key_B, NativeKeyAdapter::control_modifier);
      QTest::keyClick(window_, Qt::Key_BracketLeft);
      QVERIFY(client_->copy()->active());
      const auto* mode_bar = window_->findChild<NativeModeLayout*>();

      QVERIFY(mode_bar != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(modeTitle(*mode_bar), QStringLiteral("COPY"), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Slash);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::copy_search);
      client_->commands()->submitDialog({{QStringLiteral("text"), QStringLiteral("COPY_MODE_WORD_1")}});
      // The match found holds the cursor, nothing selected; y copies the match.
      QTRY_VERIFY_WITH_TIMEOUT(client_->copy()->state() && !client_->copy()->state()->anchor.hasValue() && client_->copy()->searchState().value(QStringLiteral("count")).toInt() > 0, runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Y);
      QVERIFY(!client_->copy()->active());
      QTRY_COMPARE_WITH_TIMEOUT(clipboard->text(), QStringLiteral("COPY_MODE_WORD_1"), runtime_wait_ms);

      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY_WITH_TIMEOUT(peer.ready(), runtime_wait_ms);
      peer.request(telar::ClientAction::client_copy_mode, 1);
      QTRY_VERIFY_WITH_TIMEOUT(client_->copy()->active(), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{1}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QTest::keyPress(window_, Qt::Key_Q);
      QVERIFY(!client_->copy()->active());
      QTest::qWait(frame_settle_ms);
      const auto before_repeat = screenText(pane->screen);
      QKeyEvent repeated{QEvent::KeyPress, Qt::Key_Q, Qt::NoModifier, QStringLiteral("q"), true};

      QCoreApplication::sendEvent(window_, &repeated);
      QTest::keyRelease(window_, Qt::Key_Q);
      QTest::qWait(frame_settle_ms);
      QCOMPARE(screenText(pane->screen), before_repeat);
      QCOMPARE(client_->status()->error(), QString{});
    }

#ifdef TELAR_GUI_CUSTOM_LINK_HOST
    Q_SLOT void pointerLinkOpening() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const RecordedLinks recorder{directory_.filePath(QStringLiteral("pointer links.txt"))};
      auto* terminal = terminalIn(window_->contentItem());
      const auto* pane = firstPane();
      QVERIFY(terminal != nullptr && pane != nullptr);
      const auto link_presented = [terminal, pane] {
        return pane->acknowledged_frame == pane->screen.frameId() && !terminal->prepareLinkPresentation();
      };
      client_->terminals()->input(pane->id, "printf '\\033[2J\\033[Hhttps://pointer.test/x\\nPOINTER_LINK_READY\\n'\r");
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).startsWith(QLatin1StringView("https://pointer.test/x")) && screenText(pane->screen).contains(QLatin1StringView("POINTER_LINK_READY")), runtime_wait_ms);
      terminal->forceActiveFocus();
      const auto position = cellCenter(*terminal, {.x = 2});
      QTest::mouseMove(window_, position);
      QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://pointer.test/x"));
      QTest::qWait(frame_settle_ms);
      QVERIFY(test::waitForGuiCondition(link_presented, runtime_wait_ms));
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, position);
      QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), (QStringList{QStringLiteral("https://pointer.test/x")}), runtime_wait_ms);
      QTest::mousePress(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
      const auto dragged = position + QPoint{1, 0};
      QMouseEvent move{QEvent::MouseMove, QPointF{dragged}, QPointF{window_->mapToGlobal(dragged)}, Qt::NoButton, Qt::LeftButton, NativeKeyAdapter::link_modifier};
      QCoreApplication::sendEvent(window_, &move);
      QTest::mouseRelease(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, dragged);
      QTest::qWait(frame_settle_ms);
      QCOMPARE(recorder.targets().size(), 1);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::AltModifier, position);
      QTest::qWait(frame_settle_ms);
      QCOMPARE(recorder.targets().size(), 1);
      QTest::keyClick(window_, Qt::Key_X);
      client_->terminals()->input(pane->id, "\x15");

      client_->terminals()->input(pane->id, "printf '\\033[?1000h'\r");
      QTRY_COMPARE(pane->screen.mouse().tracking, telar::MouseTracking::normal);
      const auto restore_tracking = qScopeGuard([this, identity = pane->id] {
        client_->terminals()->input(identity, "printf '\\033[?1000l'\r");
      });
      QTest::mouseMove(window_, position);
      QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://pointer.test/x"));
      QTest::qWait(frame_settle_ms);
      QTest::mouseClick(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
      QTest::qWait(frame_settle_ms);
      QCOMPARE(recorder.targets().size(), 1);
      client_->terminals()->input(pane->id, "\x15");
      QVERIFY(test::waitForGuiCondition(link_presented, runtime_wait_ms));
      QTest::mouseClick(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier | Qt::ShiftModifier, position);
      QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), (QStringList{QStringLiteral("https://pointer.test/x"), QStringLiteral("https://pointer.test/x")}), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void pointerLinkRevalidation() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const RecordedLinks recorder{directory_.filePath(QStringLiteral("revalidated links.txt"))};
      auto* terminal = terminalIn(window_->contentItem());
      const auto* pane = firstPane();
      QVERIFY(terminal != nullptr && pane != nullptr);
      const auto link_presented = [terminal, pane] {
        return pane->acknowledged_frame == pane->screen.frameId() && !terminal->prepareLinkPresentation();
      };
      constexpr auto first_output = "printf '\\033[2J\\033[Hhttps://original.test\\nORIGINAL_READY\\n'\r";
      client_->terminals()->input(pane->id, first_output);
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).startsWith(QLatin1StringView("https://original.test")) && screenText(pane->screen).contains(QLatin1StringView("ORIGINAL_READY")), runtime_wait_ms);
      terminal->forceActiveFocus();
      const auto position = cellCenter(*terminal, {.x = 2});
      QTest::mouseMove(window_, position);
      QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://original.test"));
      QTest::qWait(frame_settle_ms);
      QVERIFY(test::waitForGuiCondition(link_presented, runtime_wait_ms));
      QTest::mousePress(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
      client_->terminals()->input(pane->id, "printf '\\033[2J\\033[Hhttps://replaced.test\\nREPLACED_READY\\n'\r");
      QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://replaced.test"));
      client_->terminals()->input(pane->id, first_output);
      QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://original.test"));
      QTest::qWait(frame_settle_ms);
      QTest::mouseRelease(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
      QTest::qWait(frame_settle_ms);
      QVERIFY(recorder.targets().isEmpty());

      QVERIFY(test::waitForGuiCondition(link_presented, runtime_wait_ms));
      QTest::mousePress(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
      client_->commands()->execute(window_actions::Action::toggle_sidebar);
      client_->commands()->execute(window_actions::Action::toggle_sidebar);
      QTest::qWait(frame_settle_ms);
      QTest::mouseRelease(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
      QTest::qWait(frame_settle_ms);
      QVERIFY(recorder.targets().isEmpty());
      QVERIFY(test::waitForGuiCondition(link_presented, runtime_wait_ms));
      QTest::mouseClick(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
      QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), (QStringList{QStringLiteral("https://original.test")}), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void textualAndRoutedLinks() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const RecordedLinks recorder{directory_.filePath(QStringLiteral("opened links ñ.txt"))};
      const auto* pane = firstPane();
      auto* terminal = terminalIn(window_->contentItem());
      QVERIFY(pane != nullptr && terminal != nullptr);
      constexpr std::string_view copy_uri = "https://copy.test/x";
      client_->terminals()->input(pane->id, "printf '\\033[2J\\033[Hhttps://copy.test/x\\nLINK_COPY_READY\\n'\r");
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).startsWith(QLatin1StringView("https://copy.test/x")) && screenText(pane->screen).contains(QLatin1StringView("LINK_COPY_READY")), runtime_wait_ms);
      terminal->forceActiveFocus();
      client_->commands()->execute(window_actions::Action::copy_mode);
      QTest::keyClick(window_, Qt::Key_Home);
      QTest::keyClick(window_, Qt::Key_Up);
      QTest::keyClick(window_, Qt::Key_Up);
      QTest::keyClick(window_, Qt::Key_O);
      QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), (QStringList{toQString(copy_uri)}), runtime_wait_ms);
      QVERIFY(client_->copy()->active());
      QTest::keyClick(window_, Qt::Key_Q);

      CommandPeer peer{memory_};
      peer.open(socket_);
      QTRY_VERIFY_WITH_TIMEOUT(peer.ready(), runtime_wait_ms);
      constexpr std::string_view routed_uri = "https://cli.test/$(id);date/中";
      peer.request(telar::ClientAction::client_open_link, 1, routed_uri);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{1}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), (QStringList{toQString(copy_uri), toQString(routed_uri)}), runtime_wait_ms);
      peer.request(telar::ClientAction::client_open_link, 2, "javascript:alert(1)");
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("InvalidLink"));

      client_->terminals()->input(pane->id, "printf '\\033[2J\\033[H\\033]8;;https://osc8.test\\033\\\\SAFE\\033]8;;\\033\\\\\\n'\r");
      QTRY_COMPARE_WITH_TIMEOUT(toQString(pane->screen.linkAt(0)), QStringLiteral("https://osc8.test"), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(pane->acknowledged_frame, pane->screen.frameId(), runtime_wait_ms);
      const auto cell = terminal->cellSize();
      const auto clicked = terminal->mapToScene({cell.width() / 2, cell.height() / 2}).toPoint();
      QTest::mouseClick(window_, Qt::LeftButton, Qt::ControlModifier, clicked);
      QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), (QStringList{toQString(copy_uri), toQString(routed_uri), QStringLiteral("https://osc8.test")}), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void configuredComponentUrlsAndActions() {
      const RecordedLinks recorder{directory_.filePath(QStringLiteral("configured links λ.txt"))};
      const auto cleanup = qScopeGuard([this] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
      });
      const QTemporaryDir directory;
      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = R"(
      local t=require('telar')
      local ui=t.ui
      return {api_version=2,client={
        keybindings={t.bind_global({'alt+u'},t.action.open_panel('usage'))},
        bars={bottom={
          left=t.bar.static(ui.group({on_click=t.action.open_panel('usage'),url='https://bar-action.test',ui.label('Action λ')})),
          center=t.bar.tabs(),
          right=t.bar.static(ui.group({url='https://bar-only.test',ui.label('Bar URL')})),
        }},
        panels={usage=t.panel({title='Configured links',render=function() return ui.actions({
          ui.button({text='Close action',action=t.action.close_panel(),url='https://panel-action.test'}),
          ui.button({text='Panel URL',url='https://panel-only.test'}),
        }) end})},
      }}
    )";
      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      const auto click = [this](const QString& kind, const QString& caption) {
        if (!test::waitForSynchronizedFrame(*window_, runtime_wait_ms)) {
          return false;
        }

        const auto* item = componentItem(kind, caption);
        if (item == nullptr) {
          return false;
        }

        QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, item->mapRectToScene(item->boundingRect()).center().toPoint());
        return true;
      };
      QVERIFY(click(QStringLiteral("label"), QStringLiteral("Action λ")));
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("Configured links"));
      QVERIFY(click(QStringLiteral("button"), QStringLiteral("Close action")));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QVERIFY(click(QStringLiteral("label"), QStringLiteral("Bar URL")));
      const QStringList bar_targets{QStringLiteral("https://bar-only.test")};
      QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), bar_targets, runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QVERIFY(click(QStringLiteral("button"), QStringLiteral("Panel URL")));
      const QStringList all_targets{QStringLiteral("https://bar-only.test"), QStringLiteral("https://panel-only.test")};
      QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), all_targets, runtime_wait_ms);
      QVERIFY(client_->components()->panel().value(QStringLiteral("open")).toBool());
      QCOMPARE(client_->status()->error(), QString{});
    }

#endif

    Q_SLOT void configuredFileEditor() {
      const auto original_tabs = client_->tabs()->rows()->rowCount();
      const auto* original = firstPane();

      QVERIFY(original != nullptr);
      const auto original_id = original->id;

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_tabs + 1, runtime_wait_ms);
      auto restore = qScopeGuard([this, original_tabs, original_id] {
        client_->loadConfiguration({}, {}, {});
        closeTemporaryTab({.count = original_tabs, .pane_id = original_id});
      });

      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != original_id, runtime_wait_ms);
      const auto source_id = firstPane()->id;
      const auto editor_path = directory_.filePath(QStringLiteral("link editor ñ"));

      writeTestFile(editor_path, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\nprintf 'FILE_EDITOR_READY\\n'\nexec /bin/sh\n");
      QVERIFY(QFile::setPermissions(editor_path, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
      const auto file_path = directory_.filePath(QStringLiteral("a $(id); 中.cpp"));

      writeTestFile(file_path, "file-link fixture\n");
      const auto config_path = directory_.filePath(QStringLiteral("file-editor.lua"));
      const auto source = QStringLiteral("return {api_version=2, client={editor=[[%1]]}}").arg(editor_path).toUtf8();

      writeTestFile(config_path, source.constData());
      client_->loadConfiguration(config_path, {}, {});
      QCOMPARE(toQString(client_->configuration().editor.view()), editor_path);
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY_WITH_TIMEOUT(peer.ready(), runtime_wait_ms);
      const auto uri = QUrl::fromLocalFile(file_path).toEncoded();

      client_->commands()->execute(window_actions::Action::copy_mode);
      QVERIFY(client_->copy()->active());
      peer.request(telar::ClientAction::client_open_link, 1, {uri.constData(), static_cast<std::size_t>(uri.size())});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{1}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(readTestFile(editor_path + QStringLiteral(".args")), file_path.toUtf8() + '\n', runtime_wait_ms);
      const auto editor_ready = [&] {
        for (int row = 0; row < client_->panes()->rows()->rowCount(); ++row) {
          const auto record = client_->panes()->rows()->data(client_->panes()->rows()->index(row, 0), ListModel::record_role).toMap();
          const auto* pane = client_->pane(record.value(QStringLiteral("key")).toString().toULongLong());
          if (pane != nullptr && pane->id != source_id && screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("FILE_EDITOR_READY"))) {
            return true;
          }
        }

        return false;
      };

      QTRY_VERIFY_WITH_TIMEOUT(editor_ready(), runtime_wait_ms);
      QTRY_VERIFY2_WITH_TIMEOUT(qobject_cast<TerminalItem*>(window_->activeFocusItem()) != nullptr && qobject_cast<TerminalItem*>(window_->activeFocusItem())->paneIdentity() != source_id, qPrintable(windowObservation(*window_)), runtime_wait_ms);
      QVERIFY(client_->copy()->active());
      QTest::keyClick(window_, Qt::Key_Q);
      QVERIFY(!client_->copy()->active());
      const auto next_editor_directory = directory_.filePath(QStringLiteral("next-editor"));

      QVERIFY(QDir{}.mkpath(next_editor_directory));
      const auto next_editor = QDir{next_editor_directory}.filePath(QStringLiteral("nvim"));

      writeTestFile(next_editor, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\nexec /bin/sh\n");
      QVERIFY(QFile::setPermissions(next_editor, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
      const auto next_source = QStringLiteral("return {api_version=2, client={editor=[[%1]]}}").arg(next_editor).toUtf8();

      writeTestFile(config_path, next_source.constData());
      client_->loadConfiguration(config_path, {}, {});
      const auto positioned_uri = uri + "#L12C3";

      peer.request(telar::ClientAction::client_open_link, 2, {positioned_uri.constData(), static_cast<std::size_t>(positioned_uri.size())});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QTRY_COMPARE_WITH_TIMEOUT(readTestFile(next_editor + QStringLiteral(".args")), QByteArray{"+call cursor(12, 3)\n"} + file_path.toUtf8() + '\n', runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 3, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::focus_pane, QString::number(source_id));
      const QSignalSpy feedback{client_->notifications(), &NotificationsController::changed};
      const auto missing_uri = uri + ".missing";

      peer.request(telar::ClientAction::client_open_link, 3, {missing_uri.constData(), static_cast<std::size_t>(missing_uri.size())});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
      QVERIFY2(peer.result().status == telar::ClientCommandStatus::admitted, qPrintable(peer.result().text));
      QTRY_VERIFY2_WITH_TIMEOUT(!feedback.empty(), qPrintable(client_->status()->error()), runtime_wait_ms);
      QVERIFY(!client_->notifications()->center().items().empty());
      QCOMPARE(client_->notifications()->center().items().front().title.view(), std::string_view{"Could not open link"});
      QCOMPARE(client_->notifications()->center().items().front().message.view(), std::string_view{"FileNotFound"});
      dismissNotification();
      QCOMPARE(client_->status()->error(), QString{});
      client_->loadConfiguration({}, {}, {});
      closeTemporaryTab({.count = original_tabs, .pane_id = original_id});
      restore.dismiss();
    }

    Q_SLOT void kittyKeyboardInput() {
      const auto original_tabs = client_->tabs()->rows()->rowCount();
      const auto* original_pane = firstPane();

      QVERIFY(original_pane != nullptr);
      const auto original_identity = original_pane->id;

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_tabs + 1, runtime_wait_ms);
      auto restore = qScopeGuard([this, original_tabs, original_identity] {
        closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
      });

      QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->id != original_identity && firstPane()->screen.frameId() > 0, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      auto* terminal = terminalIn(window_->contentItem());
      const auto* pane = firstPane();
      if (terminal == nullptr || pane == nullptr) {
        QFAIL("Required terminal and pane fixtures are missing");
      }

      terminal->forceActiveFocus();
      constexpr telar::Byte kitty_flags = 31;
      constexpr std::string_view expected = "\x1b[100;5u\x1b[100;5:3u";
      const auto capture = QStringLiteral("stty raw -echo; printf '\\033[>31u'; dd bs=1 count=%1 2>/dev/null | od -An -tx1 | tr -d ' \\n'; printf '\\033[<u'; stty sane\r").arg(expected.size());

      client_->terminals()->input(pane->id, capture.toUtf8());
      QTRY_COMPARE_WITH_TIMEOUT(pane->screen.modes().kitty_keyboard_flags, kitty_flags, runtime_wait_ms);
      QKeyEvent command{QEvent::KeyPress, Qt::Key_F1, NativeKeyAdapter::super_modifier};

      QCoreApplication::sendEvent(terminal, &command);
      QKeyEvent press{QEvent::KeyPress, Qt::Key_D, NativeKeyAdapter::control_modifier, QStringLiteral("\x04")};

      QCoreApplication::sendEvent(terminal, &press);
      QKeyEvent release{QEvent::KeyRelease, Qt::Key_D, Qt::NoModifier, QStringLiteral("d")};

      QCoreApplication::sendEvent(terminal, &release);
      const auto expected_hex = QString::fromLatin1(QByteArray{expected.data(), static_cast<qsizetype>(expected.size())}.toHex());

      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).remove(QLatin1Char('\n')).contains(expected_hex), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(pane->screen.modes().kitty_keyboard_flags, telar::Byte{0}, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
      closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
      restore.dismiss();
    }

    Q_SLOT void runtimeNotificationDeliveryAndRoutedDismissal() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY_WITH_TIMEOUT(peer.ready(), runtime_wait_ms);
      peer.showNotification({.request_id = 2, .notification = {.level = telar::NotificationLevel::success, .duration_ms = telar::max_notification_duration_ms, .title = "Runtime notice", .message = "Delivered over the real protocol", .link = "https://example.com/notice"}});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->notifications()->center().items().empty() && client_->notifications()->center().items().front().title.view() == "Runtime notice", runtime_wait_ms);
      const auto id = client_->notifications()->center().items().front().id;

      QCOMPARE(client_->notifications()->center().items().front().link.view(), std::string_view{"https://example.com/notice"});
      QTRY_VERIFY_WITH_TIMEOUT(!telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("notificationCard")).empty(), runtime_wait_ms);
      const auto* body = telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("notificationBody")).front();
      const auto body_point = body->mapToScene({body->width() / 2, body->height() / 2}).toPoint();

      QTest::mouseMove(window_, body_point);
      QTRY_VERIFY_WITH_TIMEOUT(body->property("hovered").toBool(), runtime_wait_ms);
      const auto* underline = telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("notificationUnderline")).front();

      QTRY_VERIFY_WITH_TIMEOUT(underline->isVisible(), runtime_wait_ms);
      peer.request(telar::ClientCommand{.request_id = 3, .action = telar::ClientAction::notification_dismiss, .target_id = id.value});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QTRY_VERIFY_WITH_TIMEOUT(client_->notifications()->center().find(id) == nullptr, runtime_wait_ms);
      peer.request(telar::ClientCommand{.request_id = 4, .action = telar::ClientAction::notification_dismiss, .target_id = id.value});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{4}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("NotificationNotFound"));

      constexpr std::uint64_t focus_notice_request = 5;

      peer.showNotification({.request_id = focus_notice_request, .notification = {.level = telar::NotificationLevel::info, .duration_ms = telar::max_notification_duration_ms, .title = "Dismiss and type", .message = "Keep the terminal ready"}});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->notifications()->center().items().empty() && client_->notifications()->center().items().front().title.view() == "Dismiss and type", runtime_wait_ms);
      const auto focus_id = client_->notifications()->center().items().front().id;
      const auto focus_key = client_->notifications()->identity(focus_id);
      const auto closes = [&] {
        auto items = telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("notificationClose"));

        items.removeIf([&](const QQuickItem* item) {
          return item->property("identity").toString() != focus_key || !item->isEnabled();
        });

        return items;
      };

      QTRY_COMPARE_WITH_TIMEOUT(closes().size(), 1, runtime_wait_ms);
      const auto trace_focus = qEnvironmentVariableIsSet("TELAR_GUI_TEST_FOCUS_TRACE");
      const auto observation = [this, trace_focus] {
        if (trace_focus) {
          const auto* terminal = terminalIn(window_->contentItem());

          qInfo().noquote() << "notification focus" << windowObservation(*window_) << "terminal=" << terminal << "visible=" << (terminal != nullptr && terminal->isVisible()) << "focus=" << (terminal != nullptr && terminal->hasActiveFocus()) << "dialog=" << static_cast<int>(client_->dialogs()->kind());
        }
      };

      const auto focus_connection = QObject::connect(window_, &QQuickWindow::activeFocusItemChanged, window_, observation);
      const auto stop_observation = qScopeGuard([&] {
        QObject::disconnect(focus_connection);
      });

      const auto* close = closes().front();
      const auto point = close->mapToScene({close->width() / 2, close->height() / 2}).toPoint();

      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, point);
      auto release_click = qScopeGuard([&] {
        QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, point);
      });

      QVERIFY(client_->notifications()->center().find(focus_id) != nullptr);
      QCOMPARE(client_->notifications()->center().find(focus_id)->phase, telar::gui::features::notifications::NotificationItem::Phase::exiting);
      observation();
      QTRY_VERIFY2_WITH_TIMEOUT(window_->activeFocusItem() == terminalIn(window_->contentItem()), qPrintable(windowObservation(*window_)), runtime_wait_ms);
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, point);
      release_click.dismiss();
      QTRY_VERIFY_WITH_TIMEOUT(client_->notifications()->center().items().empty(), runtime_wait_ms);
    }

    Q_SLOT void routedDismissalOfFocusedNotificationReturnsToTerminal() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY_WITH_TIMEOUT(peer.ready(), runtime_wait_ms);
      peer.showNotification({.request_id = 1, .notification = {.level = telar::NotificationLevel::info, .duration_ms = telar::max_notification_duration_ms, .title = "Focused notice", .message = "Remove the focused widget"}});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->notifications()->center().items().empty() && client_->notifications()->center().items().front().title.view() == "Focused notice", runtime_wait_ms);
      const auto identity = client_->notifications()->center().items().front().id;
      const auto key = client_->notifications()->identity(identity);
      const auto closes = [&] {
        auto items = test::visualItems(*window_->contentItem(), QStringLiteral("notificationClose"));

        items.removeIf([&](const QQuickItem* item) {
          return item->property("identity").toString() != key || !item->isEnabled();
        });

        return items;
      };

      QTRY_COMPARE_WITH_TIMEOUT(closes().size(), 1, runtime_wait_ms);
      const auto cleanup = qScopeGuard([this, key] {
        client_->notifications()->dismiss(key);
      });

      const QPointer<QQuickItem> close{closes().front()};

      QCOMPARE(close->property("identity").toString(), key);
      QVERIFY(close->isEnabled());
      close->forceActiveFocus(Qt::TabFocusReason);
      QTRY_VERIFY2_WITH_TIMEOUT(close != nullptr && window_->activeFocusItem() == close.data(), qPrintable(windowObservation(*window_)), runtime_wait_ms);
      peer.request(telar::ClientCommand{.request_id = 2, .action = telar::ClientAction::notification_dismiss, .target_id = identity.value});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QTRY_VERIFY_WITH_TIMEOUT(client_->notifications()->center().items().empty(), runtime_wait_ms);
      QTRY_VERIFY2_WITH_TIMEOUT(window_->activeFocusItem() == terminalIn(window_->contentItem()), qPrintable(windowObservation(*window_)), runtime_wait_ms);
      sendTextKeys(QLatin1StringView{"printf 'NOTICE_FOCUS_RESTORED\\n'"});
      QTest::keyClick(window_, Qt::Key_Return);
      const auto restored_output = [this] {
        const auto rows = screenText(firstPane()->screen, ScreenTextLayout::logical).split(QLatin1Char('\n'));

        return std::ranges::any_of(rows, [](const QString& row) {
          return row.trimmed() == QLatin1StringView("NOTICE_FOCUS_RESTORED");
        });
      };

      QTRY_VERIFY2_WITH_TIMEOUT(restored_output(), qPrintable(screenText(firstPane()->screen, ScreenTextLayout::logical)), runtime_wait_ms);
    }

    Q_SLOT void removingFocusedNotificationWithoutDisabledFrameReturnsToTerminal() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      client_->notifications()->publish({.level = telar::NotificationLevel::info, .title = "Removed delivered control", .message = "No intermediate disabled record", .link = {}, .duration_ns = telar::max_notification_duration_ms * NotificationInput::nanoseconds_per_millisecond});
      const auto closes = [&] {
        return test::visualItems(*window_->contentItem(), QStringLiteral("notificationClose"));
      };

      QTRY_COMPARE_WITH_TIMEOUT(closes().size(), 1, runtime_wait_ms);
      const auto identity = client_->notifications()->identity(client_->notifications()->center().items().front().id);
      const auto cleanup = qScopeGuard([this, identity] {
        client_->notifications()->dismiss(identity);
      });

      auto* close = closes().front();

      QVERIFY(close->isEnabled());
      close->forceActiveFocus(Qt::TabFocusReason);
      QTRY_COMPARE_WITH_TIMEOUT(window_->activeFocusItem(), close, runtime_wait_ms);
      auto* owner = close->parentItem();

      while (owner != nullptr && qobject_cast<NotificationLayout*>(owner) == nullptr) {
        owner = owner->parentItem();
      }

      auto* layout = qobject_cast<NotificationLayout*>(owner);

      QVERIFY(layout != nullptr);
      auto* records = dynamic_cast<ListModel*>(layout->cards());

      QVERIFY(records != nullptr);
      QCOMPARE(records->rowCount(), 1);
      records->reconcile({});
      QTRY_VERIFY2_WITH_TIMEOUT(window_->activeFocusItem() == terminalIn(window_->contentItem()), qPrintable(windowObservation(*window_)), runtime_wait_ms);
    }

    // Lua bindings run on the Lua thread; wait until their results have been applied.
    void settleLua() {
      QTRY_VERIFY_WITH_TIMEOUT(test::ComponentActions::luaIdle(*client_), runtime_wait_ms);
      QCoreApplication::processEvents();
    }

    Q_SLOT void configuredBindings() {
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, binding_configuration);
      writeTestFile(directory.filePath(QStringLiteral("helper.lua")), "return function(context) assert(context.focused_pane_id > 0 and context.pane_count > 0) return telar.action.toggle_sidebar() end");
      const auto restore = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      client_->loadConfiguration(path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      const auto commands = client_->commands()->list();

      QVERIFY(std::ranges::any_of(commands, [](const auto& entry) {
        const auto record = entry.toMap();

        const auto shortcut = platform::usesCommandKey() ? QStringLiteral("⌃A C") : QStringLiteral("Ctrl+a c");

        return record.value(QStringLiteral("action")).template value<window_actions::Action>() == window_actions::Action::new_tab && record.value(QStringLiteral("shortcut")) == shortcut;
      }));

      auto* terminal = terminalIn(window_->contentItem());
      const auto* pane = firstPane();
      if (terminal == nullptr || pane == nullptr) {
        QFAIL("Required terminal and pane fixtures are missing");
      }

      const auto clear_input = qScopeGuard([this, identity = pane->id] {
        client_->terminals()->input(identity, "\x15");
      });

      terminal->forceActiveFocus();
      const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
      const auto visible = client_->display()->sidebarVisible();
      const QSignalSpy configuration_events{client_.get(), &ApplicationController::configurationChanged};
      const QSignalSpy focus_events{window_, &QQuickWindow::activeFocusItemChanged};

      QTest::keyClick(window_, Qt::Key_A, control);
      QVERIFY(client_->status()->prefixPending());
      const auto* mode_bar = window_->findChild<NativeModeLayout*>();

      QVERIFY(mode_bar != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(modeTitle(*mode_bar), QStringLiteral("PREFIX"), runtime_wait_ms);
      writeTestFile(directory.filePath(QStringLiteral("unused.lua")), "return {}");
      constexpr int prefix_wait_ms = 1100;

      QTest::qWait(prefix_wait_ms);
      QVERIFY(client_->status()->prefixPending());
      QTest::keyPress(window_, Qt::Key_S);
      QVERIFY(!client_->status()->prefixPending());
      settleLua();
      QCOMPARE(client_->status()->error(), QString{});
      QVERIFY2(client_->display()->sidebarVisible() == !visible, qPrintable(QStringLiteral("Configuration reloads: %1; focus changes: %2; dialog: %3; copy mode: %4").arg(configuration_events.count()).arg(focus_events.count()).arg(static_cast<int>(client_->dialogs()->kind())).arg(static_cast<int>(client_->copy()->active()))));
      QKeyEvent repeated{QEvent::KeyPress, Qt::Key_S, Qt::NoModifier, QStringLiteral("s"), true};

      QCoreApplication::sendEvent(window_, &repeated);
      QCOMPARE(client_->display()->sidebarVisible(), !visible);
      QTest::keyRelease(window_, Qt::Key_S);
      QTest::keyClick(window_, Qt::Key_A, control);
      QVERIFY(client_->status()->prefixPending());
      QTest::keyClick(window_, Qt::Key_S);
      QVERIFY(!client_->status()->prefixPending());
      settleLua();
      QCOMPARE(client_->display()->sidebarVisible(), visible);

      QTest::keyClick(window_, Qt::Key_A, control);
      QVERIFY(client_->status()->prefixPending());
      QTest::keyClick(window_, Qt::Key_Escape);
      QVERIFY(!client_->status()->prefixPending());
      QTest::keyClick(window_, Qt::Key_A, control);
      QVERIFY(client_->status()->prefixPending());
      client_->commands()->execute(window_actions::Action::palette);
      QVERIFY(!client_->status()->prefixPending());
      client_->commands()->execute(window_actions::Action::cancel);
      terminal->forceActiveFocus();

      const auto collapsed = client_->display()->workspaceListCollapsed();

      sendTextKeys(QLatin1StringView("gg"));
      QCOMPARE(client_->display()->workspaceListCollapsed(), !collapsed);
      sendTextKeys(QLatin1StringView("gg"));
      QCOMPARE(client_->display()->workspaceListCollapsed(), collapsed);
      sendTextKeys(QLatin1StringView("gk"));
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).contains(QLatin1StringView("gk")), runtime_wait_ms);
      client_->terminals()->input(pane->id, "\x15");

      verifyExpressionBindings(*pane);
      QVERIFY(!QTest::currentTestFailed());
      QCOMPARE(client_->status()->error(), QString{});
    }

    // The expression bindings of binding_configuration paste text, type keys and consume a key.
    void verifyExpressionBindings(const application::Pane<telar::Memory>& pane) {
      QTest::keyClick(window_, Qt::Key_P, Qt::AltModifier);
      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane.screen).contains(QLatin1StringView("GUI_BINDING_PASTE")), runtime_wait_ms);
      client_->terminals()->input(pane.id, "printf '");
      QTest::keyClick(window_, Qt::Key_K, Qt::AltModifier);
      settleLua();
      client_->terminals()->input(pane.id, "\\n'\r");
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane.screen).contains(QLatin1StringView("\nGUI_BINDING_KEYS ")), runtime_wait_ms);
      QTest::qWait(frame_settle_ms);
      const auto before_consume = screenText(pane.screen);

      QTest::keyClick(window_, Qt::Key_V, Qt::AltModifier);
      QTest::qWait(frame_settle_ms);
      const auto after_consume = screenText(pane.screen);

      QVERIFY2(after_consume == before_consume, qPrintable(QStringLiteral("Before consume:\n%1\nAfter consume:\n%2\n%3").arg(before_consume, after_consume, windowObservation(*window_))));
    }

    Q_SLOT void bindingReloadOwnership() {
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, "return {api_version=2, client={prefix='ctrl+a', keybindings={telar.bind({'s'}, function() return telar.action.toggle_sidebar() end)}}}");
      const auto restore = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      client_->loadConfiguration(path, {}, {});
      auto* terminal = terminalIn(window_->contentItem());

      QVERIFY(terminal != nullptr);
      terminal->forceActiveFocus();
      const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;

      QTest::keyClick(window_, Qt::Key_A, control);
      QTest::keyPress(window_, Qt::Key_S);
      writeTestFile(path, "return {api_version=2, client={keybindings={telar.bind_global({'s'}, telar.action.toggle_workspace_list())}}}");
      client_->loadConfiguration(path, {}, {});
      const auto collapsed = client_->display()->workspaceListCollapsed();
      QKeyEvent repeated{QEvent::KeyPress, Qt::Key_S, Qt::NoModifier, QStringLiteral("s"), true};

      QCoreApplication::sendEvent(window_, &repeated);
      QCOMPARE(client_->display()->workspaceListCollapsed(), collapsed);
      QTest::keyRelease(window_, Qt::Key_S);
      QTest::keyClick(window_, Qt::Key_S);
      QCOMPARE(client_->display()->workspaceListCollapsed(), !collapsed);
      QTest::keyClick(window_, Qt::Key_S);
      QCOMPARE(client_->display()->workspaceListCollapsed(), collapsed);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void paneSurfacesShareTheChromeStyle() {
      client_->commands()->execute(window_actions::Action::split_horizontal);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::split_vertical);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 3, runtime_wait_ms);
      // A new pane grows from zero size while the layout animates; a loaded machine can still be
      // on the first animation frame after any fixed wait.
      const auto settled = [this] {
        const auto surfaces = test::visualItems(*window_->contentItem(), QStringLiteral("paneSurface"));

        return surfaces.size() == 3 && std::ranges::all_of(surfaces, [](const QQuickItem* surface) {
          return surface->isVisible() && !surface->parentItem()->property("resizing").toBool();
        });
      };

      QTRY_VERIFY_WITH_TIMEOUT(settled(), runtime_wait_ms);
      const auto surfaces = test::visualItems(*window_->contentItem(), QStringLiteral("paneSurface"));
      const auto frames = test::visualItems(*window_->contentItem(), QStringLiteral("paneFrame"));

      QCOMPARE(surfaces.size(), 3);
      QCOMPARE(frames.size(), surfaces.size());
      for (qsizetype index = 0; index < surfaces.size(); ++index) {
        const auto* surface = surfaces[index];
        const auto* frame = frames[index];

        QVERIFY(surface->isVisible());
        QCOMPARE(surface->position(), frame->position());
        QCOMPARE(surface->size(), frame->size());
        // A pane surface and its frame share one radius, the pane decoration's.
        QCOMPARE(surface->property("radius").toReal(), frame->property("radius").toReal());
        QCOMPARE(frame->property("radius").toReal(), telar::gui::features::workbench::PaneDecorationGeometry::frame_radius * client_->display()->chromeRatio());
      }

      // Focus is a full accent frame on one pane; the others keep a faint hairline.
      constexpr qreal accent_alpha_threshold = 0.5;

      QCOMPARE(std::ranges::count_if(frames, [](const auto* frame) {
        return frame->property("borderAlpha").toReal() > accent_alpha_threshold;
      }),
          1);
      captureArtifact(QStringLiteral("chrome-split-panes"));

      // The focused pane offers its four actions as visible buttons.
      auto actions = test::visualItems(*window_->contentItem(), QStringLiteral("paneAction"));

      actions.removeIf([](const QQuickItem* action) {
        return !action->isVisible();
      });

      QCOMPARE(actions.size(), 4);
      captureArtifact(QStringLiteral("chrome-pane-actions"));
      const auto split = std::ranges::find_if(actions, [](const auto* action) {
        return action->property("modelData").toMap().value(QStringLiteral("label")).toString() == QLatin1StringView("Split right");
      });

      QVERIFY(split != actions.end());
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, (*split)->mapToScene((*split)->boundingRect().center()).toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 4, runtime_wait_ms);
      while (client_->panes()->rows()->rowCount() > 1) {
        const auto count = client_->panes()->rows()->rowCount();
        const auto key = client_->panes()->rows()->data(client_->panes()->rows()->index(count - 1, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString();

        // Model projections can arrive before the acknowledgement releases the
        // preceding pane operation. Wait for that operation before closing again.
        QTRY_VERIFY_WITH_TIMEOUT(!test::FramePacing::requestsPending(*client_), runtime_wait_ms);
        client_->commands()->execute(window_actions::Action::close_pane, key);
        QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), count - 1, runtime_wait_ms);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      }

      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void paneTransitionsResizeTheTerminalOnlyOnce() {
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const QPointer<TerminalItem> terminal{terminalIn(window_->contentItem())};

      QVERIFY(terminal != nullptr);
      const QSignalSpy widths{terminal, &QQuickItem::widthChanged};
      const QSignalSpy heights{terminal, &QQuickItem::heightChanged};

      client_->commands()->execute(window_actions::Action::split_horizontal);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      const auto split_id = client_->panes()->rows()->data(client_->panes()->rows()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString();
      auto* layout = window_->findChild<PaneMotionLayout*>();

      QVERIFY(layout != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 2, runtime_wait_ms);
      const auto settled = [&] {
        const auto* model = layout->items();

        for (int index = 0; index < model->rowCount(); ++index) {
          const auto record = model->data(model->index(index, 0), ListModel::record_role).toMap();
          if (record.value(QStringLiteral("visualBounds")).toRectF() != QRectF{record.value(QStringLiteral("x")).toReal(), record.value(QStringLiteral("y")).toReal(), record.value(QStringLiteral("width")).toReal(), record.value(QStringLiteral("height")).toReal()}) {
            return false;
          }
        }

        return true;
      };

      QTRY_VERIFY_WITH_TIMEOUT(settled(), runtime_wait_ms);
      QVERIFY(terminal != nullptr);
      QCOMPARE(widths.size(), 1);
      QVERIFY(heights.size() <= 1);
      client_->commands()->execute(window_actions::Action::close_pane, split_id);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 1, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(settled(), runtime_wait_ms);
      QVERIFY(terminal != nullptr);
      QCOMPARE(widths.size(), 2);
      QVERIFY(heights.size() <= 2);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void splitCloseAndTabs() {
      auto* terminal = terminalIn(window_->contentItem());
      if (terminal == nullptr) {
        QFAIL("Required terminal fixture is missing");
      }

      const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
      QKeyEvent prefix{QEvent::KeyPress, Qt::Key_B, control};
      QKeyEvent split{QEvent::KeyPress, Qt::Key_Percent, Qt::NoModifier, QStringLiteral("%")};

      QCoreApplication::sendEvent(terminal, &prefix);
      QCoreApplication::sendEvent(terminal, &split);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      QCOMPARE(client_->panes()->dividers()->rowCount(), 1);
      const auto divider = client_->panes()->dividers()->data(client_->panes()->dividers()->index(0, 0), ListModel::record_role).toMap();
      const auto first_width = client_->panes()->rows()->data(client_->panes()->rows()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("width")).toReal();

      client_->panes()->resizeDivider(divider.value(QStringLiteral("key")).toString().toInt(), divider.value(QStringLiteral("x")).toReal() + divider_drag_pixels, divider.value(QStringLiteral("y")).toReal(), true);
      const auto resized_width = client_->panes()->rows()->data(client_->panes()->rows()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("width")).toReal();

      QVERIFY(resized_width > first_width);
      const auto split_id = client_->panes()->rows()->data(client_->panes()->rows()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString();

      QTRY_VERIFY_WITH_TIMEOUT(client_->pane(split_id.toULongLong())->screen.frameId() > 0, runtime_wait_ms);
      const auto first_index = client_->panes()->rows()->index(0, 0);
      const auto first_record = client_->panes()->rows()->data(first_index, ListModel::record_role).toMap();
      constexpr qsizetype bottom_band_index = 1;
      const auto bands = first_record.value(QStringLiteral("panels")).toList();

      QVERIFY(bands.size() > bottom_band_index);
      const auto bottom_band = bands[bottom_band_index].toRectF();
      const auto frame_origin = QPointF{first_record.value(QStringLiteral("x")).toReal(), first_record.value(QStringLiteral("y")).toReal()};
      const auto workbench_origin = client_->display()->geometry().value(QStringLiteral("terminal")).toRectF().topLeft();

      QTest::qWait(frame_settle_ms);
      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, (workbench_origin + frame_origin + bottom_band.center()).toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(client_->panes()->rows()->data(first_index, ListModel::record_role).toMap().value(QStringLiteral("focused")).toBool(), runtime_wait_ms);
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, (workbench_origin + frame_origin + bottom_band.center()).toPoint());
      client_->commands()->execute(window_actions::Action::focus_pane, split_id);

      const QTemporaryDir configuration_directory;

      QVERIFY(configuration_directory.isValid());
      const auto configuration_path = configuration_directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(configuration_path, R"(
return {api_version=2, client={keybindings={
  telar.bind_global({'alt+h'}, function() return {telar.action.navigate_pane{direction='left'}} end),
  telar.bind_global({'alt+l'}, telar.action.navigate_pane{direction='right'})
}}}
)");
      const auto restore_configuration = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      client_->loadConfiguration(configuration_path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      // alt+h runs a Lua callback, whose result reaches the event loop after the Lua thread
      // returns; alt+l waits behind it.
      QTest::keyClick(window_, Qt::Key_H, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(client_->panes()->rows()->data(client_->panes()->rows()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("focused")).toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_L, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(client_->panes()->rows()->data(client_->panes()->rows()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("focused")).toBool(), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
      client_->commands()->execute(window_actions::Action::close_pane, split_id);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 1, runtime_wait_ms);

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), 2, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->screen.frameId() > 0, runtime_wait_ms);
      const auto first_tab = client_->tabs()->rows()->data(client_->tabs()->rows()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString();

      client_->commands()->execute(window_actions::Action::select_tab, first_tab);
      QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->screen.frameId() > 0, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    // One change of the dialog that moves the line search to another pane and another kind
    // reaches every prompt line as one value: the line it leaves never hosts the new kind, not even
    // between the kind and the pane.
    Q_SLOT void lineSearchMovesBetweenPanesAtOnce() {
      auto* terminal = terminalIn(window_->contentItem());
      if (terminal == nullptr) {
        QFAIL("Required terminal fixture is missing");
      }

      const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
      QKeyEvent prefix{QEvent::KeyPress, Qt::Key_B, control};
      QKeyEvent split{QEvent::KeyPress, Qt::Key_Percent, Qt::NoModifier, QStringLiteral("%")};

      QCoreApplication::sendEvent(terminal, &prefix);
      QCoreApplication::sendEvent(terminal, &split);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      const auto key = [this](int row) {
        return client_->panes()->rows()->data(client_->panes()->rows()->index(row, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString();
      };

      const auto first = key(0);
      const auto second = key(1);
      const auto line = [this](const QString& pane) -> QQuickItem* {
        for (auto* item : test::visualItems(*window_->contentItem(), QString{})) {
          if (item->property("scrollbackSearch").isValid() && item->property("paneId").toString() == pane) {
            return item;
          }
        }

        return nullptr;
      };

      // The search leaves the first pane, which has no focus, so its line hosts nothing before
      // or after.
      client_->commands()->execute(window_actions::Action::focus_pane, second);
      QTRY_VERIFY_WITH_TIMEOUT(client_->panes()->rows()->data(client_->panes()->rows()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("focused")).toBool(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(line(first) != nullptr && line(second) != nullptr, runtime_wait_ms);
      const auto* first_line = line(first);
      const auto* second_line = line(second);

      test::HistoryPresentation::showLineSearch(*client_, Store::Dialog::history, first.toULongLong());
      QVERIFY(!first_line->property("searching").toBool());
      const QSignalSpy first_scrollback{first_line, SIGNAL(scrollbackSearchChanged())};
      const QSignalSpy first_search{first_line, SIGNAL(searchChanged())};

      // The scrollback search would show on the first pane's line if the kind arrived before the
      // pane.
      test::HistoryPresentation::showLineSearch(*client_, Store::Dialog::copy_search, second.toULongLong());
      QVERIFY(second_line->property("scrollbackSearch").toBool());
      QCOMPARE(first_scrollback.count(), 0);
      QCOMPARE(first_search.count(), 0);

      test::HistoryPresentation::showLineSearch(*client_, Store::Dialog::none, 0);
      QVERIFY(!second_line->property("searching").toBool());
      client_->commands()->execute(window_actions::Action::close_pane, second);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void kittyGraphicsRendering() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      auto const* pane = firstPane();
      if (pane == nullptr) {
        QFAIL("Required pane fixture is missing");
      }

      QByteArray pixels;
      constexpr unsigned source_pixels = 4;
      constexpr unsigned full_channel = 255;

      for (unsigned index = 0; index < source_pixels; ++index) {
        pixels.append(static_cast<char>(full_channel));
        pixels.append(static_cast<char>(0));
        pixels.append(static_cast<char>(0));
        pixels.append(static_cast<char>(full_channel));
      }

      const auto command = QByteArray{"printf '\\033_Ga=T,f=32,s=2,v=2,i=37,c=8,r=4,q=2;"} + pixels.toBase64() + "\\033\\\\'\r";

      client_->terminals()->input(pane->id, command);
      QTRY_VERIFY_WITH_TIMEOUT(!pane->graphics.placements().empty(), runtime_wait_ms);
      const auto placement = pane->graphics.placements().front();

      QTRY_VERIFY_WITH_TIMEOUT(pane->graphics.readyImage(placement.key) != nullptr, runtime_wait_ms);
      const auto* image = pane->graphics.readyImage(placement.key);
      if (image == nullptr) {
        QFAIL("Required image fixture is missing");
      }

      QCOMPARE(image->pixels().size(), std::size_t{16});
      auto const* terminal = terminalIn(window_->contentItem());
      if (terminal == nullptr) {
        QFAIL("Required terminal fixture is missing");
      }

      const auto cell = terminal->cellSize();
      const auto geometry = ImageGeometry::resolve(placement, image->description(), {.x = static_cast<float>(cell.width()), .y = static_cast<float>(cell.height())}, static_cast<float>(window_->devicePixelRatio()));
      const auto back = static_cast<qint64>(pane->screen.scroll().total_rows) - pane->screen.rows() - pane->screen.scroll().offset;
      const auto point = terminal->mapToScene(QPointF{geometry.destination.x + (geometry.destination.width / 2), geometry.destination.y + (static_cast<qreal>(back) * cell.height()) + (geometry.destination.height / 2)});

      QTest::qWait(frame_settle_ms);
      const auto captured = window_->grabWindow();

      QVERIFY(!captured.isNull());
      const auto pixel = captured.pixelColor((point * window_->devicePixelRatio()).toPoint());
      const bool expected_pixel = pixel.red() > 200 && pixel.green() < 50 && pixel.blue() < 50;
      const auto failure_capture = qEnvironmentVariable("TELAR_GUI_TEST_FAILURE_CAPTURE");
      if (!expected_pixel && !failure_capture.isEmpty()) {
        QVERIFY(captured.save(failure_capture));
      }

      const auto diagnostic = QStringLiteral("pixel=%1 scene=%2,%3 terminal=%4,%5 back=%6 imageY=%7 capturedHeight=%8")
                                  .arg(pixel.name())
                                  .arg(point.x())
                                  .arg(point.y())
                                  .arg(terminal->width())
                                  .arg(terminal->height())
                                  .arg(back)
                                  .arg(geometry.destination.y)
                                  .arg(captured.height());

      QVERIFY2(expected_pixel, qPrintable(diagnostic));
      client_->terminals()->input(pane->id, "printf '\\033_Ga=d,d=I,i=37,q=2;\\033\\\\'\r");
      QTRY_VERIFY_WITH_TIMEOUT(pane->graphics.placements().empty(), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void paletteModesKeepQueriesAndRejectStaleChoices() {
      const auto original_panes = client_->panes()->rows()->rowCount();

      client_->commands()->execute(window_actions::Action::palette);
      client_->palette()->search(QStringLiteral(">Split right"));
      QCOMPARE(client_->palette()->state().value(QStringLiteral("count")).toInt(), 1);
      const auto state = client_->palette()->state();
      const auto key = state.value(QStringLiteral("selectedKey")).toString();
      const auto revision = state.value(QStringLiteral("revision")).toString();

      QVERIFY(!key.isEmpty());
      client_->palette()->search(QStringLiteral(">no matching command exists here"));
      client_->palette()->activate({{QStringLiteral("key"), key}, {QStringLiteral("revision"), revision}});
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      QCOMPARE(client_->panes()->rows()->rowCount(), original_panes);
      client_->palette()->search(QStringLiteral(">Split right"));
      const auto previous = client_->palette()->state();

      client_->commands()->execute(window_actions::Action::cancel);
      client_->commands()->execute(window_actions::Action::palette);
      client_->palette()->search(QStringLiteral(">Split right"));
      client_->palette()->activate({{QStringLiteral("key"), previous.value(QStringLiteral("selectedKey"))}, {QStringLiteral("revision"), previous.value(QStringLiteral("revision"))}});
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      QCOMPARE(client_->panes()->rows()->rowCount(), original_panes);
      client_->commands()->execute(window_actions::Action::cancel);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void paletteSearchesEveryKindWithoutPrefix() {
      const auto rows = [&] {
        return client_->palette()->geometry().value(QStringLiteral("rows")).toList();
      };

      client_->commands()->execute(window_actions::Action::palette);
      QCOMPARE(client_->palette()->state().value(QStringLiteral("editorText")).toString(), QString{});
      QCOMPARE(client_->palette()->state().value(QStringLiteral("mode")).toInt(), static_cast<int>(application::palette::PaletteMode::all));
      client_->palette()->search(QStringLiteral("Split right"));
      QCOMPARE(client_->palette()->state().value(QStringLiteral("selectedKind")).toString(), QStringLiteral("action"));
      QVERIFY(rows().size() >= 2);
      QCOMPARE(rows().back().toMap().value(QStringLiteral("key")).toString(), QStringLiteral("suggest:query"));

      // "cl" also matches Close tab and Close pane, which a two-letter guess must not preselect.
      client_->palette()->search(QStringLiteral("cl"));
      QVERIFY(!rows().empty());
      QVERIFY(!rows().front().toMap().value(QStringLiteral("destructive")).toBool());

      // A prefix narrows the search to one kind and drops the suggestion row.
      client_->palette()->search(QStringLiteral(">Split right"));
      QCOMPARE(client_->palette()->state().value(QStringLiteral("count")).toInt(), 1);
      client_->commands()->execute(window_actions::Action::cancel);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void suggestionPaletteKeepsUnavailableRequestsEditable() {
      client_->commands()->execute(window_actions::Action::suggest_command);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      QCOMPARE(client_->palette()->state().value(QStringLiteral("editorText")).toString(), QStringLiteral("?"));
      QVERIFY(!client_->palette()->suggestion().value(QStringLiteral("canSubmit")).toBool());
      client_->palette()->search(QStringLiteral("?list files"));
      auto const* search = window_->findChild<NativeFormField*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(search->text(), QStringLiteral("?list files"), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Return);
      const auto suggestion = [this] {
        return client_->palette()->suggestion();
      };

      QTRY_VERIFY_WITH_TIMEOUT(suggestion().value(QStringLiteral("failed")).toBool(), runtime_wait_ms);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      QCOMPARE(suggestion().value(QStringLiteral("message")).toString(), QStringLiteral("Configure runtime.engine to enable suggestions."));
      const auto obsolete = suggestion().value(QStringLiteral("revision")).toString();

      client_->palette()->search(QStringLiteral("?new task"));
      QCOMPARE(suggestion().value(QStringLiteral("heading")).toString(), QStringLiteral("Start with a task"));
      client_->palette()->submitSuggestion(obsolete);
      QCOMPARE(suggestion().value(QStringLiteral("heading")).toString(), QStringLiteral("Start with a task"));
      QTRY_COMPARE_WITH_TIMEOUT(search->text(), QStringLiteral("?new task"), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_VERIFY_WITH_TIMEOUT(suggestion().value(QStringLiteral("failed")).toBool(), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void suggestionBackRestoresItsActionQueryAndEditorSelection() {
      client_->commands()->execute(window_actions::Action::palette);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
        client_->commands()->execute(window_actions::Action::cancel);
      });

      const auto query = QStringLiteral(">Suggest a command");

      client_->palette()->search(query);
      QCOMPARE(client_->palette()->state().value(QStringLiteral("count")).toInt(), 1);
      const QPointer<NativeFormField> search{window_->findChild<NativeFormField*>(QStringLiteral("commandSearch"))};

      QVERIFY(search != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(search->text(), query, runtime_wait_ms);
      constexpr int anchor = 7;
      constexpr int cursor = 3;

      search->select(anchor, cursor);
      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_COMPARE_WITH_TIMEOUT(client_->palette()->state().value(QStringLiteral("editorText")).toString(), QStringLiteral("?"), runtime_wait_ms);
      QVERIFY(client_->palette()->suggestion().value(QStringLiteral("hasParent")).toBool());
      QVERIFY(search != nullptr);
      QCOMPARE(window_->findChild<NativeFormField*>(QStringLiteral("commandSearch")), search.data());
      client_->palette()->search(QStringLiteral("?child task"));
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_COMPARE_WITH_TIMEOUT(client_->palette()->state().value(QStringLiteral("editorText")).toString(), query, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(search->text(), query, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(search->cursorPosition(), cursor, runtime_wait_ms);
      QCOMPARE(search->selectionStart(), cursor);
      QCOMPARE(search->selectionEnd(), anchor);
      QVERIFY(!client_->palette()->suggestion().value(QStringLiteral("hasParent")).toBool());
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void paletteNavigationChoosesAnExistingTab() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto original_pane = firstPane()->id;
      const auto original_tab = firstPane()->location.tab_id;
      const auto original_tabs = client_->tabs()->rows()->rowCount();

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_tabs + 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != original_pane, runtime_wait_ms);
      const auto destination = firstPane()->id;
      const auto destination_tab = firstPane()->location.tab_id;

      client_->commands()->execute(window_actions::Action::rename_tab);
      client_->commands()->submitDialog({{QStringLiteral("text"), QStringLiteral("PALETTE_DESTINATION")}});
      client_->commands()->execute(window_actions::Action::select_tab, QString::number(original_tab));
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == original_pane, runtime_wait_ms);
      terminalIn(window_->contentItem())->forceActiveFocus();
      QTest::keyClick(window_, Qt::Key_B, NativeKeyAdapter::control_modifier);
      QTest::keyClick(window_, Qt::Key_G);
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette, runtime_wait_ms);
      client_->palette()->search(QStringLiteral("@PLT_DST"));
      QTRY_COMPARE_WITH_TIMEOUT(client_->palette()->state().value(QStringLiteral("count")).toInt(), 1, runtime_wait_ms);
      const auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), QStringLiteral("@PLT_DST"), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == destination, runtime_wait_ms);
      QCOMPARE(client_->tabs()->rows()->rowCount(), original_tabs + 1);
      client_->commands()->execute(window_actions::Action::close_tab, QString::number(destination_tab));
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_tabs, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::select_tab, QString::number(original_tab));
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == original_pane, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void pathPickerBrowsesAndInsertsWithoutExecuting() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && !firstPane()->cwd.empty(), runtime_wait_ms);
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto root = QFileInfo{directory.path()}.canonicalFilePath();

      QVERIFY(QDir{root}.mkdir(QStringLiteral("folder")));
      writeTestFile(root + QStringLiteral("/folder/a b'c.txt"), "path fixture");
      const auto original = toQString(firstPane()->cwd);
      const auto pane_id = firstPane()->id;
      const auto change_directory = [this, pane_id](QString path) {
        path.replace(QLatin1Char('\''), QLatin1StringView("'\\''"));
        client_->terminals()->input(pane_id, QByteArray{"\x15"
                                                        "cd '"} +
                                                 path.toUtf8() + "' && pwd\r");
      };

      const auto restore = qScopeGuard([&] {
        client_->commands()->execute(window_actions::Action::cancel);
        change_directory(original);
      });

      change_directory(root);
      QTRY_COMPARE_WITH_TIMEOUT(toQString(firstPane()->cwd), root, runtime_wait_ms);
      terminalIn(window_->contentItem())->forceActiveFocus();
      QTest::keyClick(window_, Qt::Key_B, NativeKeyAdapter::control_modifier);
      QTest::keyClick(window_, Qt::Key_F);
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::paths, runtime_wait_ms);
      client_->paths()->search(QStringLiteral("folder/"));
      QTRY_VERIFY_WITH_TIMEOUT(client_->paths()->state().value(QStringLiteral("count")).toInt() >= 1, runtime_wait_ms);
      auto const* panel = window_->findChild<QQuickItem*>(QStringLiteral("pathPickerPanel"));

      QVERIFY(panel != nullptr);
      auto const* search = panel->findChild<QQuickItem*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), QStringLiteral("folder/"), runtime_wait_ms);
      QVERIFY(!search->property("formControl").toBool());
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->paths()->state().value(QStringLiteral("root")).toString(), root + QStringLiteral("/folder"), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), QString{}, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->paths()->state().value(QStringLiteral("count")).toInt(), 1, runtime_wait_ms);
      const auto stale = client_->paths()->state().value(QStringLiteral("revision"));

      QTest::keyClick(window_, Qt::Key_Backtab, Qt::ShiftModifier);
      QTRY_COMPARE_WITH_TIMEOUT(client_->paths()->state().value(QStringLiteral("root")).toString(), root, runtime_wait_ms);
      client_->paths()->activate({{QStringLiteral("revision"), stale}, {QStringLiteral("path"), QStringLiteral("a b'c.txt")}});
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::paths);
      client_->paths()->search(QStringLiteral("a b"));
      QTRY_COMPARE_WITH_TIMEOUT(client_->paths()->state().value(QStringLiteral("count")).toInt(), 1, runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none, runtime_wait_ms);
      QTRY_VERIFY2_WITH_TIMEOUT(screenText(firstPane()->screen, ScreenTextLayout::logical).contains(QStringLiteral("'folder/a b'\\''c.txt'")), qPrintable(screenText(firstPane()->screen, ScreenTextLayout::logical)), runtime_wait_ms);
      QCOMPARE(toQString(firstPane()->cwd), root);
      client_->terminals()->input(pane_id, "\x15");
      change_directory(original);
      QTRY_COMPARE_WITH_TIMEOUT(toQString(firstPane()->cwd), original, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void pathPickerQueryLimitPreservesCompleteUtf8() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && !firstPane()->cwd.empty(), runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::path_picker);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::paths);
      constexpr int path_query_bytes = 64;

      QCOMPARE(client_->paths()->state().value(QStringLiteral("maximumQueryBytes")).toInt(), path_query_bytes);
      auto const* panel = window_->findChild<QQuickItem*>(QStringLiteral("pathPickerPanel"));

      QVERIFY(panel != nullptr);
      auto* search = panel->findChild<QQuickItem*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      const QString retained(path_query_bytes - 1, QLatin1Char('x'));
      QInputMethodEvent commit;

      commit.setCommitString(retained + QStringLiteral("🧵"));
      QCoreApplication::sendEvent(search, &commit);
      QCOMPARE(search->property("text").toString(), retained);
      QCOMPARE(client_->paths()->state().value(QStringLiteral("editorText")).toString(), retained);
      const auto notices = [this] {
        return std::ranges::find_if(client_->notifications()->center().items(), [](const auto& item) {
          return item.title.view() == "Limit reached" && item.message.view().contains("prompt.path_query_bytes");
        });
      };

      QTRY_VERIFY_WITH_TIMEOUT(notices() != client_->notifications()->center().items().end(), runtime_wait_ms);
      const auto identity = notices()->id;

      client_->notifications()->dismiss(client_->notifications()->identity(identity));
      QTRY_VERIFY_WITH_TIMEOUT(client_->notifications()->center().find(identity) == nullptr, runtime_wait_ms);
    }

    Q_SLOT void staleTabHitsDoNotCaptureConfiguredWidgets() {
      telar::ds::Option<QPoint> held;
      const auto cleanup = qScopeGuard([this, &held] {
        if (held) {
          sendMouse(*window_, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, *held);
        }

        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
        test::waitForSynchronizedFrame(*window_, runtime_wait_ms);
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = R"(
      local t=require('telar')
      return {api_version=2,client={
        bars={bottom={left=t.bar.static(t.ui.group({on_click=t.action.open_panel('usage'),t.ui.label('Configured action')})),right=t.bar.tabs()}},
        panels={usage=t.panel({title='Tab-safe action',render=function() return t.ui.text('Widget retains its click') end})},
      }}
    )";

      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTRY_VERIFY_WITH_TIMEOUT(client_->tabs()->dropSurface(client_->display()->chromeRatio()).count > 0, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* label = componentItem(QStringLiteral("label"), QStringLiteral("Configured action"));

      QVERIFY(label != nullptr);
      const auto bounds = label->mapRectToScene(label->boundingRect());
      const auto point = bounds.center().toPoint();
      const auto live = client_->tabs()->dropSurface(client_->display()->chromeRatio());

      QVERIFY(live.at({point.x() * live.scale, point.y() * live.scale}) == nullptr);
      auto stale = live;

      stale.count = 1;
      stale.create = {};
      stale.targets.atMut(0).bounds = {.x = static_cast<float>(bounds.x() * live.scale), .y = static_cast<float>(bounds.y() * live.scale), .width = static_cast<float>(bounds.width() * live.scale), .height = static_cast<float>(bounds.height() * live.scale)};
      client_->tabs()->present(stale);
      held = point;
      sendMouse(*window_, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, point);
      QVERIFY2(!client_->tabs()->capturedTab().hasValue(), "A stale tab hit must not capture a different configured widget");
      sendMouse(*window_, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, point);
      held.reset();
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("Tab-safe action"));
    }

    Q_SLOT void tabDragReordersOnlyAfterRelease() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto original = QString::number(firstPane()->location.tab_id);
      QStringList created;
      const auto restore = qScopeGuard([&] {
        cleanupGestureTabs(created, original);
      });

      QVERIFY(prepareGestureTabs(created));
      const auto before = tabKeys();
      const auto* source = tabPill(created.front());
      const auto* destination = tabPill(created.back());

      QVERIFY(source != nullptr && destination != nullptr);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      sendMouse(*window_, QEvent::MouseMove, Qt::NoButton, Qt::NoButton, source->mapToScene({source->width() / 2, source->height() / 2}).toPoint());
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto beginning = source->mapToScene({source->width() / 2, source->height() / 2}).toPoint();
      constexpr qreal trailing_half = 0.75;
      const auto ending = destination->mapToScene({destination->width() * trailing_half, destination->height() / 2}).toPoint();

      sendMouse(*window_, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, beginning);
      QCOMPARE(firstPane()->location.tab_id, created.front().toULongLong());
      sendMouse(*window_, QEvent::MouseMove, Qt::NoButton, Qt::LeftButton, ending);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QCOMPARE(tabKeys(), before);
      const auto* layout = window_->findChild<QQuickItem*>(QStringLiteral("tabStripLayout"));

      QVERIFY(layout != nullptr && layout->property("dropMarker").toRectF().width() > 0);
      QCOMPARE(layout->property("hoveredTab").toString(), created.back());
      sendMouse(*window_, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, ending);
      auto expected = before;

      expected.removeOne(created.front());
      expected.insert(expected.indexOf(created.back()) + 1, created.front());
      QVERIFY(test::waitForGuiCondition([&] {
        return tabKeys() == expected;
      },
          runtime_wait_ms));
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QCOMPARE(layout->property("dropMarker").toRectF(), QRectF{});
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void tabDragEscapeRetiresHeldRelease() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto original = QString::number(firstPane()->location.tab_id);
      QStringList created;
      const auto restore = qScopeGuard([&] {
        cleanupGestureTabs(created, original);
      });

      QVERIFY(prepareGestureTabs(created));
      const auto before = tabKeys();
      const auto* source = tabPill(created.front());
      const auto* destination = tabPill(created.back());

      QVERIFY(source != nullptr && destination != nullptr);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto beginning = source->mapToScene({source->width() / 2, source->height() / 2}).toPoint();
      constexpr qreal trailing_half = 0.75;
      const auto ending = destination->mapToScene({destination->width() * trailing_half, destination->height() / 2}).toPoint();

      sendMouse(*window_, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, beginning);
      sendMouse(*window_, QEvent::MouseMove, Qt::NoButton, Qt::LeftButton, ending);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* layout = window_->findChild<QQuickItem*>(QStringLiteral("tabStripLayout"));

      QVERIFY(layout != nullptr && layout->property("dropMarker").toRectF().width() > 0);
      QTest::keyClick(window_, Qt::Key_Escape);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QCOMPARE(layout->property("dropMarker").toRectF(), QRectF{});
      sendMouse(*window_, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, ending);
      QCOMPARE(tabKeys(), before);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      const auto* animation = window_->findChild<QTimer*>(QStringLiteral("agentStatusAnimation"));

      QVERIFY(animation != nullptr);
      QVERIFY(test::waitForGuiCondition([&] {
        return !layout->property("transitioning").toBool();
      },
          runtime_wait_ms));
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      source = tabPill(created.front());
      destination = tabPill(created.back());
      QVERIFY(source != nullptr && destination != nullptr);
      const auto restarted = source->mapToScene({source->width() / 2, source->height() / 2}).toPoint();
      const auto restarted_ending = destination->mapToScene({destination->width() * trailing_half, destination->height() / 2}).toPoint();

      sendMouse(*window_, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, restarted);
      const auto captured = client_->tabs()->capturedTab();
      if (captured) {
        QCOMPARE(captured->tab_id, created.front().toULongLong());
      } else {
        QFAIL("The restarted gesture did not capture a tab");
      }

      sendMouse(*window_, QEvent::MouseMove, Qt::NoButton, Qt::LeftButton, restarted_ending);
      sendMouse(*window_, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, restarted_ending);
      QVERIFY(test::waitForGuiCondition([&] {
        return tabKeys() != before;
      },
          runtime_wait_ms));
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void tabDragRetiresWhenTheCapturedSourceCloses() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto original = QString::number(firstPane()->location.tab_id);
      QStringList created;
      const auto restore = qScopeGuard([&] {
        cleanupGestureTabs(created, original);
      });

      QVERIFY(prepareGestureTabs(created));
      auto expected = tabKeys();
      const auto* source = tabPill(created.front());
      const auto* destination = tabPill(created.back());

      QVERIFY(source != nullptr && destination != nullptr);
      const auto beginning = source->mapToScene({source->width() / 2, source->height() / 2}).toPoint();
      const auto ending = destination->mapToScene({destination->width() / 2, destination->height() / 2}).toPoint();

      sendMouse(*window_, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, beginning);
      sendMouse(*window_, QEvent::MouseMove, Qt::NoButton, Qt::LeftButton, ending);
      QVERIFY(client_->tabs()->capturedTab().hasValue());
      client_->commands()->execute(window_actions::Action::close_tab, created.front());
      expected.removeOne(created.front());
      QVERIFY(test::waitForGuiCondition([&] {
        return tabKeys() == expected;
      },
          runtime_wait_ms));
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QVERIFY(!client_->tabs()->capturedTab().hasValue());
      const auto* layout = window_->findChild<QQuickItem*>(QStringLiteral("tabStripLayout"));

      QVERIFY(layout != nullptr);
      QCOMPARE(layout->property("dropMarker").toRectF(), QRectF{});
      sendMouse(*window_, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, ending);
      QCOMPARE(tabKeys(), expected);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void tabDragCancelsWhenViewportChanges() {
      verifyTabDragCancellation(TabDragInterruption::viewport);
    }

    Q_SLOT void tabDragCancelsWhenModalOpens() {
      verifyTabDragCancellation(TabDragInterruption::modal);
    }

    Q_SLOT void tabDragCancelsWhenTheWindowLosesFocus() {
      verifyTabDragCancellation(TabDragInterruption::focus);
    }

    Q_SLOT void hiddenCounterPressRetainsItsSourceThroughRevealAndDrop() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto original = QString::number(firstPane()->location.tab_id);
      const auto size = window_->size();
      QStringList created;
      QPoint ending;
      bool held = false;
      const auto restore = qScopeGuard([&] {
        if (held) {
          sendMouse(*window_, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, ending);
        }

        window_->resize(size);
        cleanupGestureTabs(created, original);
      });

      constexpr int fixture_tab_groups = 4;

      for (int group = 0; group < fixture_tab_groups; ++group) {
        QVERIFY(prepareGestureTabs(created));
      }

      window_->resize(window_->minimumWidth(), size.height());
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* counter = window_->findChild<QQuickItem*>(QStringLiteral("hiddenTabCounter"));
      const auto* layout = window_->findChild<QQuickItem*>(QStringLiteral("tabStripLayout"));

      QVERIFY(counter != nullptr && layout != nullptr);
      QVERIFY(test::waitForGuiCondition([&] {
        return !layout->property("transitioning").toBool();
      },
          runtime_wait_ms));
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QTRY_VERIFY_WITH_TIMEOUT(counter->isVisible() && counter->width() > 0, runtime_wait_ms);
      sendMouse(*window_, QEvent::MouseMove, Qt::NoButton, Qt::NoButton, counter->mapToScene({counter->width() / 2, counter->height() / 2}).toPoint());
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto key = layout->property("counter").toMap().value(QStringLiteral("key")).toString();
      const auto* destination = tabPill(created.back());

      QVERIFY(destination != nullptr);
      constexpr qreal trailing_half = 0.75;

      ending = destination->mapToScene({destination->width() * trailing_half, destination->height() / 2}).toPoint();
      const QRectF viewport{0, 0, static_cast<qreal>(window_->width()), static_cast<qreal>(window_->height())};

      QVERIFY(viewport.contains(ending));
      const auto beginning = counter->mapToScene({counter->width() / 2, counter->height() / 2}).toPoint();
      const auto before = tabKeys();

      sendMouse(*window_, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, beginning);
      held = true;
      const auto captured = client_->tabs()->capturedTab();
      if (captured) {
        QCOMPARE(captured->tab_id, key.toULongLong());
      } else {
        QFAIL("The delivered hidden counter did not capture its tab");
      }

      QCOMPARE(firstPane()->location.tab_id, key.toULongLong());
      sendMouse(*window_, QEvent::MouseMove, Qt::NoButton, Qt::LeftButton, ending);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QCOMPARE(tabKeys(), before);
      sendMouse(*window_, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, ending);
      held = false;
      auto expected = before;

      expected.removeOne(key);
      expected.insert(expected.indexOf(created.back()) + 1, key);
      QVERIFY(test::waitForGuiCondition([&] {
        return tabKeys() == expected;
      },
          runtime_wait_ms));
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void paletteActionsUseOriginalLabelsAndReorderExistingTabs() {
      const auto commands = client_->commands()->list();

      QCOMPARE(commands.size(), qsizetype{41});
      QCOMPARE(commands.front().toMap().value(QStringLiteral("label")).toString(), QStringLiteral("Split right"));
      const QStringList tail{QStringLiteral("Copy process command"), QStringLiteral("Go to process pane"), QStringLiteral("Review process stack"), QStringLiteral("Review process open files"), QStringLiteral("Review process logs")};

      for (qsizetype index = 0; index < tail.size(); ++index) {
        QCOMPARE(commands[commands.size() - tail.size() + index].toMap().value(QStringLiteral("label")).toString(), tail[index]);
      }

      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto original_pane = firstPane()->id;
      const auto original_tab = firstPane()->location.tab_id;
      const auto original_count = client_->tabs()->rows()->rowCount();

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_count + 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != original_pane, runtime_wait_ms);
      const auto destination_tab = firstPane()->location.tab_id;
      auto restore = qScopeGuard([this, original_tab, destination_tab] {
        client_->commands()->execute(window_actions::Action::cancel);
        client_->commands()->execute(window_actions::Action::close_tab, QString::number(destination_tab));
        client_->commands()->execute(window_actions::Action::select_tab, QString::number(original_tab));
      });

      const auto run = [this](const QString& label) {
        client_->commands()->execute(window_actions::Action::palette);
        client_->palette()->search(QLatin1Char('>') + label);
        const auto state = client_->palette()->state();

        client_->palette()->activate({{QStringLiteral("key"), state.value(QStringLiteral("selectedKey"))}, {QStringLiteral("revision"), state.value(QStringLiteral("revision"))}});
      };

      const auto tab_keys = [this] {
        QList<QString> keys;

        for (int index = 0; index < client_->tabs()->rows()->rowCount(); ++index) {
          keys.append(client_->tabs()->rows()->data(client_->tabs()->rows()->index(index, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString());
        }

        return keys;
      };

      const auto original_order = tab_keys();
      const auto destination_index = original_order.indexOf(QString::number(destination_tab));

      QVERIFY(destination_index > 0);
      const auto previous_tab = original_order[destination_index - 1].toULongLong();

      run(QStringLiteral("Previous tab"));
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->location.tab_id == previous_tab, runtime_wait_ms);
      run(QStringLiteral("Next tab"));
      QTRY_COMPARE_WITH_TIMEOUT(firstPane()->location.tab_id, destination_tab, runtime_wait_ms);
      auto moved_order = original_order;

      moved_order.swapItemsAt(destination_index, destination_index - 1);
      run(QStringLiteral("Move tab left"));
      QTRY_COMPARE_WITH_TIMEOUT(tab_keys(), moved_order, runtime_wait_ms);
      run(QStringLiteral("Move tab right"));
      QTRY_COMPARE_WITH_TIMEOUT(tab_keys(), original_order, runtime_wait_ms);
      QCOMPARE(client_->tabs()->rows()->rowCount(), original_count + 1);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      QCOMPARE(client_->status()->error(), QString{});
      client_->commands()->execute(window_actions::Action::close_tab, QString::number(destination_tab));
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_count, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::select_tab, QString::number(original_tab));
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == original_pane, runtime_wait_ms);
      restore.dismiss();
    }

    Q_SLOT void machinePickerKeyboardRenamesAndRemovesSavedRows() {
      const auto path = directory_.filePath(QStringLiteral("machines.json"));
      QFile profiles{path};

      QVERIFY(profiles.open(QIODevice::WriteOnly));
      const QByteArray source{R"({"version":1,"machines":[{"id":"m-000000000001","label":"Offline","destination":"offline@fixture","enabled":false}]})"};

      QCOMPARE(profiles.write(source), source.size());
      QVERIFY(profiles.setPermissions(QFile::ReadOwner | QFile::WriteOwner));
      profiles.close();
      const auto cleanup = qScopeGuard([this, path] {
        client_->commands()->execute(window_actions::Action::cancel);
        static_cast<void>(QFile::remove(path));
      });

      client_->roster()->openProfiles(path);
      client_->commands()->execute(window_actions::Action::machine_picker);
      client_->palette()->search(QStringLiteral(":Offline"));
      QTRY_COMPARE_WITH_TIMEOUT(client_->palette()->state().value(QStringLiteral("count")).toInt(), 2, runtime_wait_ms);
      auto* search = window_->findChild<NativeFormField*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_R, Qt::KeyboardModifiers{ApplicationController::superModifier()});
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      QTest::keyClick(window_, Qt::Key_R, Qt::KeyboardModifiers{ApplicationController::controlModifier()});
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::machine, runtime_wait_ms);
      search = window_->findChild<NativeFormField*>(QStringLiteral("commandSearch"));
      QVERIFY(search != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
      QCOMPARE(search->text(), QStringLiteral("Offline"));
      search->selectAll();
      QInputMethodEvent commit;

      commit.setCommitString(QStringLiteral("Renamed"));
      QCoreApplication::sendEvent(search, &commit);
      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_VERIFY_WITH_TIMEOUT((client_->dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::none), runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::machine_picker);
      client_->palette()->search(QStringLiteral(":Renamed"));
      QTRY_COMPARE_WITH_TIMEOUT(client_->palette()->state().value(QStringLiteral("count")).toInt(), 2, runtime_wait_ms);
      search = window_->findChild<NativeFormField*>(QStringLiteral("commandSearch"));
      QVERIFY(search != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_D, Qt::KeyboardModifiers{ApplicationController::controlModifier()});
      QTRY_COMPARE_WITH_TIMEOUT(client_->palette()->state().value(QStringLiteral("count")).toInt(), 1, runtime_wait_ms);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
    }

    Q_SLOT void machinePromptKeepsCompositionAndByteBounds() {
      client_->commands()->execute(window_actions::Action::add_machine);
      const auto cleanup = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      auto* search = window_->findChild<NativeFormField*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
      QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};

      QCoreApplication::sendEvent(search, &preedit);
      QTRY_VERIFY_WITH_TIMEOUT(search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Escape);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::machine);
      QTRY_VERIFY_WITH_TIMEOUT(!search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
      const auto maximum = client_->machinePrompt()->state().value(QStringLiteral("maximumBytes")).toInt();
      const QString retained(maximum, QLatin1Char('x'));
      QInputMethodEvent commit;

      commit.setCommitString(retained + QStringLiteral("🧵"));
      QCoreApplication::sendEvent(search, &commit);
      QCOMPARE(search->text(), retained);
      QCOMPARE(client_->machinePrompt()->state().value(QStringLiteral("editorText")).toString(), retained);
      const auto find_notice = [this] {
        return std::ranges::find_if(client_->notifications()->center().items(), [](const auto& notice) {
          return notice.title.view() == "Limit reached" && notice.message.view().find("prompt.machine_label_bytes") != std::string_view::npos;
        });
      };

      QTRY_VERIFY_WITH_TIMEOUT(find_notice() != client_->notifications()->center().items().end(), runtime_wait_ms);
      const auto notice = find_notice()->id;

      client_->notifications()->dismiss(client_->notifications()->identity(notice));
      QTest::keyClick(window_, Qt::Key_Return);
      QCOMPARE(client_->machinePrompt()->state().value(QStringLiteral("title")).toString(), QStringLiteral("Its SSH destination: user@host or an alias"));
      QCOMPARE(search->text(), QString{});
      QTest::keyClick(window_, Qt::Key_Escape);
      QVERIFY((client_->dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::none));
    }

    Q_SLOT void paletteCompositionAndUtf8LimitsKeepTheEditorOwned() {
      client_->commands()->execute(window_actions::Action::goto_picker);
      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
      QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};

      QCoreApplication::sendEvent(search, &preedit);
      QTRY_VERIFY_WITH_TIMEOUT(search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Escape);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      QTRY_VERIFY_WITH_TIMEOUT(!search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
      const auto maximum = client_->palette()->state().value(QStringLiteral("maximumQueryBytes")).toInt();
      const QString retained(maximum - 1, QLatin1Char('x'));

      QVERIFY(QMetaObject::invokeMethod(search, "selectAll"));
      QInputMethodEvent commit;

      commit.setCommitString(retained + QStringLiteral("🧵"));
      QCoreApplication::sendEvent(search, &commit);
      QCOMPARE(search->property("text").toString(), retained);
      QCOMPARE(client_->palette()->state().value(QStringLiteral("editorText")).toString(), retained);
      const auto find_notice = [this] {
        return std::ranges::find_if(client_->notifications()->center().items(), [](const auto& notice) {
          return notice.title.view() == "Limit reached" && notice.message.view().find("prompt.field_bytes") != std::string_view::npos;
        });
      };

      QTRY_VERIFY_WITH_TIMEOUT(find_notice() != client_->notifications()->center().items().end(), runtime_wait_ms);
      const auto identity = find_notice()->id;

      client_->notifications()->dismiss(client_->notifications()->identity(identity));
      QTRY_VERIFY_WITH_TIMEOUT(client_->notifications()->center().find(identity) == nullptr, runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Escape);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void dialogsAndHistory() {
      client_->commands()->execute(window_actions::Action::palette);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      QTest::qWait(frame_settle_ms);
      client_->commands()->execute(window_actions::Action::cancel);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      client_->commands()->execute(window_actions::Action::history);
      QTRY_VERIFY_WITH_TIMEOUT(client_->history()->rows()->rowCount() > 0, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::cancel);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void historyKeyboardSubmission() {
      const auto* pane = firstPane();

      QVERIFY(pane != nullptr);
      client_->commands()->execute(window_actions::Action::history);
      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));
      if (search == nullptr) {
        QFAIL("Required history search fixture is missing");
      }

      client_->history()->search(QStringLiteral("GUI_HISTORY_FIXTURE"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() > 0, runtime_wait_ms);
      search->forceActiveFocus();
      QKeyEvent paste{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier};

      QCoreApplication::sendEvent(search, &paste);
      QTRY_COMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      QTRY_VERIFY2_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("echo GUI_HISTORY_FIXTURE")), qPrintable(QStringLiteral("columns=%1 contents=%2").arg(pane->screen.columns()).arg(screenText(pane->screen))), runtime_wait_ms);
      client_->terminals()->input(pane->id, "\x15");

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_FIXTURE"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() > 0, runtime_wait_ms);
      search->forceActiveFocus();
      QKeyEvent run{QEvent::KeyPress, Qt::Key_Return, Qt::ShiftModifier};

      QCoreApplication::sendEvent(search, &run);
      QTRY_COMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      const auto has_output = [&] {
        const auto lines = screenText(pane->screen).split(QLatin1Char('\n'));

        return std::ranges::any_of(lines, [](const auto& line) {
          return line.trimmed() == QLatin1StringView("GUI_HISTORY_FIXTURE");
        });
      };

      QTRY_VERIFY_WITH_TIMEOUT(has_output(), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void historyPointerSelectionNeverSubmits() {
      const telar::ds::Array entries{
          telar::ImportHistoryEntry{.started_at_ms = 100, .command = "echo GUI_HISTORY_POINTER_FIRST"},
          telar::ImportHistoryEntry{.started_at_ms = 101, .command = "echo GUI_HISTORY_POINTER_SECOND"},
      };

      importHistory(entries, "gui-history-pointer");
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
        if (const auto* pane = firstPane()) {
          client_->terminals()->input(pane->id, "\x15");
        }
      });

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_POINTER"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 2, runtime_wait_ms);
      if (!window_->isActive()) {
        test::activateWindow(*window_);
      }

      QQuickItem* older = nullptr;
      const auto locate = [&] {
        for (auto* row : test::visualItems(*window_->contentItem(), QStringLiteral("historyResult"))) {
          if (row->property("index").toInt() == 1) {
            older = row;
            return true;
          }
        }

        return false;
      };

      QTRY_VERIFY_WITH_TIMEOUT(locate(), runtime_wait_ms);
      if (older == nullptr) {
        QFAIL("Required older history row is missing");
      }

      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      test::FramePacing::presentSwapped(*client_);
      const auto position = older->mapToScene(QPointF{older->width() / 2, older->height() / 2}).toPoint();

      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, position);
      QTRY_COMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1);
      QVERIFY(client_->history()->state().value(QStringLiteral("canSubmit")).toBool());
      QTest::mouseDClick(window_, Qt::LeftButton, Qt::NoModifier, position);
      QTest::qWait(frame_settle_ms);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1);
      QQuickItem* copy = nullptr;
      const auto locate_copy = [&] {
        for (auto* hint : test::visualItems(*older, QStringLiteral("historyHint"))) {
          if (hint->isVisible() && hint->property("label").toMap().value(QStringLiteral("action")).toString() == QStringLiteral("copy")) {
            copy = hint;

            return true;
          }
        }

        return false;
      };

      QTRY_VERIFY_WITH_TIMEOUT(locate_copy(), runtime_wait_ms);
      auto* clipboard = QGuiApplication::clipboard();
      auto saved_clipboard = test::copyClipboard();
      const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved_clipboard)] mutable {
        clipboard->setMimeData(saved.release());
      });

      QTRY_VERIFY_WITH_TIMEOUT(test::HistoryPresentation::actionCenter(*client_, application::history::HistoryCardAction::copy).hasValue(), runtime_wait_ms);
      const auto copy_position = test::HistoryPresentation::actionCenter(*client_, application::history::HistoryCardAction::copy);

      QVERIFY(copy_position.hasValue());
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, copy_position->toPoint());
      QCOMPARE(clipboard->text(), QStringLiteral("echo GUI_HISTORY_POINTER_FIRST"));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
    }

    Q_SLOT void historyCardActionsSurviveSelectionChanges() {
      importRetainedHistory();
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_RETAINED"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 2, runtime_wait_ms);
      test::activateWindow(*window_);

      QTRY_VERIFY_WITH_TIMEOUT(selectedHistoryCopy() != nullptr, runtime_wait_ms);
      QPointer<QQuickItem> previous = selectedHistoryCopy();

      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      auto* clipboard = QGuiApplication::clipboard();
      auto saved = test::copyClipboard();
      const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved)] mutable {
        clipboard->setMimeData(saved.release());
      });

      const auto sentinel = QStringLiteral("GUI_HISTORY_RETAINED_UNCHANGED");

      clipboard->setText(sentinel);
      HeldCardPress press{.position = previous->mapToScene(QPointF{previous->width() / 2, previous->height() / 2}).toPoint(), .held = true};
      const auto release = qScopeGuard([&] {
        if (press.held) {
          QTest::mouseRelease(window_, press.button, Qt::NoModifier, press.position);
        }
      });

      const test::HistoryCardWaitTrace trace{*window_};

      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, press.position);
      client_->history()->select(1);
      QTRY_COMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1);
      QTRY_VERIFY_WITH_TIMEOUT(previous.isNull(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(selectedHistoryCopy() != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      test::FramePacing::presentSwapped(*client_);
      const auto* current = selectedHistoryCopy();

      press.position = current->mapToScene(QPointF{current->width() / 2, current->height() / 2}).toPoint();
      QTest::mouseMove(window_, press.position);
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, press.position);
      press.held = false;
      // The zero-open frame retires card targets and consumes this old release.
      QCOMPARE(clipboard->text(), sentinel);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, press.position);
      QCOMPARE(clipboard->text(), QStringLiteral("echo GUI_HISTORY_RETAINED_ONE"));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      previous = selectedHistoryCopy();
      clipboard->setText(sentinel);
      press.position = previous->mapToScene(QPointF{previous->width() / 2, previous->height() / 2}).toPoint();
      press.held = true;
      QTest::mousePress(window_, press.button, Qt::NoModifier, press.position);
      client_->commands()->execute(window_actions::Action::cancel);
      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_RETAINED"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 2, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(previous.isNull(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(selectedHistoryCopy() != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      current = selectedHistoryCopy();
      press.position = current->mapToScene(QPointF{current->width() / 2, current->height() / 2}).toPoint();
      QTest::mouseMove(window_, press.position);
      QTest::mouseRelease(window_, press.button, Qt::NoModifier, press.position);
      press.held = false;
      QCOMPARE(clipboard->text(), sentinel);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      for (const auto button : {Qt::MiddleButton, Qt::RightButton}) {
        verifyHeldCopyOutlivesSelection(press, button, sentinel);
        QVERIFY(!QTest::currentTestFailed());
      }

      verifyHeldCopyOutlivesHiddenWindow(press, sentinel);
    }

    [[nodiscard]] QQuickItem* selectedHistoryCopy() const {
      return historyCardHint(*window_, client_->history()->state().value(QStringLiteral("selection")).toInt(), QStringLiteral("copy"));
    }

    // A button held over the selected card's copy action while the selection moves releases
    // over the new card without copying.
    void verifyHeldCopyOutlivesSelection(HeldCardPress& press, Qt::MouseButton button, const QString& sentinel) {
      const QPointer<QQuickItem> previous = selectedHistoryCopy();

      press.position = previous->mapToScene(QPointF{previous->width() / 2, previous->height() / 2}).toPoint();
      press.button = button;
      press.held = true;
      QTest::mousePress(window_, press.button, Qt::NoModifier, press.position);
      const auto next = 1 - client_->history()->state().value(QStringLiteral("selection")).toInt();

      client_->history()->select(next);
      QTRY_COMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), next);
      QTRY_VERIFY_WITH_TIMEOUT(previous.isNull(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(selectedHistoryCopy() != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* current = selectedHistoryCopy();

      press.position = current->mapToScene(QPointF{current->width() / 2, current->height() / 2}).toPoint();
      QTest::mouseMove(window_, press.position);
      QTest::mouseRelease(window_, press.button, Qt::NoModifier, press.position);
      press.held = false;
      QCOMPARE(QGuiApplication::clipboard()->text(), sentinel);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
    }

    // A left button held over the copy action while the window hides and returns releases
    // without copying.
    void verifyHeldCopyOutlivesHiddenWindow(HeldCardPress& press, const QString& sentinel) {
      const auto* previous = selectedHistoryCopy();

      press.button = Qt::LeftButton;
      press.position = previous->mapToScene(QPointF{previous->width() / 2, previous->height() / 2}).toPoint();
      press.held = true;
      QTest::mousePress(window_, press.button, Qt::NoModifier, press.position);
      test::hideWindow(*window_);
      QTRY_VERIFY_WITH_TIMEOUT(!window_->isActive(), runtime_wait_ms);
      window_->show();
      test::activateWindow(*window_);
      QTRY_VERIFY_WITH_TIMEOUT(window_->isActive(), runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* current = selectedHistoryCopy();
      if (current == nullptr) {
        QFAIL("Required selected history copy action is missing");
      }

      press.position = current->mapToScene(QPointF{current->width() / 2, current->height() / 2}).toPoint();
      QTest::mouseRelease(window_, press.button, Qt::NoModifier, press.position);
      press.held = false;
      QCOMPARE(QGuiApplication::clipboard()->text(), sentinel);
    }

    Q_SLOT void historySelectionLeavesTheWorkbenchProjectionsAlone() {
      importRetainedHistory();
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_RETAINED"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 2, runtime_wait_ms);
      const auto workspaces = client_->workspaces()->rebuilds();
      const auto tabs = client_->tabs()->rebuilds();
      const auto panes = client_->panes()->rebuilds();
      const auto activity = client_->activity()->rebuilds();
      const auto palette = client_->palette()->rebuilds();
      // The window refreshes, but no property of it moves, so QML reads none of them again.
      const QSignalSpy refreshes{client_->terminals(), &TerminalController::refreshed};
      const QSignalSpy title{client_->status(), &WindowStatus::titleChanged};
      const QSignalSpy diagnostic{client_->status(), &WindowStatus::diagnosticChanged};
      const QSignalSpy copy_mode{client_->copy(), &CopyController::activeChanged};
      const QSignalSpy attachments{client_->attachments(), &AttachmentsController::geometryChanged};
      const QSignalSpy element_bars{client_->components(), &ComponentsController::elementBarsChanged};

      // Each selection commits and flushes before it returns; no runtime message runs in between.
      for (const auto row : {1, 0, 1}) {
        client_->history()->select(row);
        QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), row);
      }

      QCOMPARE(client_->workspaces()->rebuilds(), workspaces);
      QCOMPARE(client_->tabs()->rebuilds(), tabs);
      QCOMPARE(client_->panes()->rebuilds(), panes);
      QCOMPARE(client_->activity()->rebuilds(), activity);
      QCOMPARE(client_->palette()->rebuilds(), palette);
      QCOMPARE(refreshes.count(), 3);
      QCOMPARE(title.count(), 0);
      QCOMPARE(diagnostic.count(), 0);
      QCOMPARE(copy_mode.count(), 0);
      QCOMPARE(attachments.count(), 0);
      QCOMPARE(element_bars.count(), 0);
    }

    Q_SLOT void historyCardPressCannotFollowAReplacedRecord() {
      const telar::ds::Array entries{
          telar::ImportHistoryEntry{.started_at_ms = 100, .command = "echo GUI_REUSE_PRESS_A_FIRST"},
          telar::ImportHistoryEntry{.started_at_ms = 101, .command = "echo GUI_REUSE_PRESS_A_SECOND"},
          telar::ImportHistoryEntry{.started_at_ms = 102, .command = "echo GUI_REUSE_PRESS_B_FIRST"},
          telar::ImportHistoryEntry{.started_at_ms = 103, .command = "echo GUI_REUSE_PRESS_B_SECOND"},
      };

      importHistory(entries, "gui-reuse-press");
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_REUSE_PRESS_A_"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 2, runtime_wait_ms);
      const auto selected_copy = [this] {
        return historyCardHint(*window_, 0, QStringLiteral("copy"));
      };

      test::activateWindow(*window_);
      QTRY_VERIFY_WITH_TIMEOUT(selected_copy() != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto rows = test::visualItems(*window_->contentItem(), QStringLiteral("historyResult"));

      QVERIFY(!rows.isEmpty());
      const QPointer<QQuickItem> retained{rows.front()};
      auto* clipboard = QGuiApplication::clipboard();
      auto saved = test::copyClipboard();
      const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved)] mutable {
        clipboard->setMimeData(saved.release());
      });

      const auto sentinel = QStringLiteral("GUI_REUSE_PRESS_UNCHANGED");

      clipboard->setText(sentinel);
      const auto* copy = selected_copy();
      auto position = copy->mapToScene(QPointF{copy->width() / 2, copy->height() / 2}).toPoint();
      bool held = true;
      const auto release = qScopeGuard([&] {
        if (held) {
          QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, position);
        }
      });

      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, position);
      client_->history()->search(QStringLiteral("GUI_REUSE_PRESS_B_"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 2, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(selected_copy() != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QVERIFY(!retained.isNull());
      copy = selected_copy();
      position = copy->mapToScene(QPointF{copy->width() / 2, copy->height() / 2}).toPoint();
      QTest::mouseMove(window_, position);
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, position);
      held = false;
      QCOMPARE(clipboard->text(), sentinel);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, position);
      QCOMPARE(clipboard->text(), QStringLiteral("echo GUI_REUSE_PRESS_B_SECOND"));

      clipboard->setText(sentinel);
      sendMouse(*window_, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, position);
      client_->history()->select(1);
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1);
      // Release before another frame can present the changed selection.
      sendMouse(*window_, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, position);
      QCOMPARE(clipboard->text(), sentinel);
    }

    Q_SLOT void historySelectionProgressesInEventLoops() {
      const bool native_loop = !qEnvironmentVariableIsSet("TELAR_GUI_TEST_MANUAL_EVENT_LOOP_CONTROL");

      importRetainedHistory();
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_RETAINED"));
      QVERIFY(test::waitForGuiCondition([this] {
        return !client_->history()->loading() && client_->history()->rows()->rowCount() == 2;
      },
          runtime_wait_ms));
      const auto selected_copy = [this] {
        return historyCardHint(*window_, client_->history()->state().value(QStringLiteral("selection")).toInt(), QStringLiteral("copy"));
      };

      test::activateWindow(*window_);
      QVERIFY(test::waitForGuiCondition([&] {
        return selected_copy() != nullptr;
      },
          runtime_wait_ms));
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      auto* clipboard = QGuiApplication::clipboard();
      auto saved = test::copyClipboard();
      const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved)] mutable {
        clipboard->setMimeData(saved.release());
      });

      const auto sentinel = QStringLiteral("GUI_HISTORY_NATIVE_LOOP_UNCHANGED");

      clipboard->setText(sentinel);
      const test::HistoryCardWaitTrace trace{*window_};

      for (const auto button : {Qt::LeftButton, Qt::MiddleButton, Qt::RightButton}) {
        const QPointer<QQuickItem> previous = selected_copy();

        QVERIFY(!previous.isNull());
        auto position = previous->mapToScene(QPointF{previous->width() / 2, previous->height() / 2}).toPoint();
        bool held = true;
        const auto release = qScopeGuard([&] {
          if (held) {
            QTest::mouseRelease(window_, button, Qt::NoModifier, position);
          }
        });

        QTest::mousePress(window_, button, Qt::NoModifier, position);
        const auto next = 1 - client_->history()->state().value(QStringLiteral("selection")).toInt();
        const auto started = system::AwakeClock::nowNanoseconds();

        client_->history()->select(next);
        const auto ready = [&] {
          return previous.isNull() && selected_copy() != nullptr;
        };

        if (native_loop) {
          QVERIFY(test::waitForGuiCondition(ready, runtime_wait_ms));
        } else {
          QTRY_VERIFY_WITH_TIMEOUT(ready(), runtime_wait_ms);
        }

        qInfo() << "History selection progress: native loop" << native_loop << "button" << button << "elapsed ns" << system::AwakeClock::nowNanoseconds() - started;
        QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), next);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        const auto* current = selected_copy();

        QVERIFY(current != nullptr);
        position = current->mapToScene(QPointF{current->width() / 2, current->height() / 2}).toPoint();
        QTest::mouseMove(window_, position);
        QTest::mouseRelease(window_, button, Qt::NoModifier, position);
        held = false;
        QCOMPARE(clipboard->text(), sentinel);
        QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      }
    }

    Q_SLOT void historyFooterHintsUseCurrentActions() {
      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_FIXTURE"));
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
        if (const auto* pane = firstPane()) {
          client_->terminals()->input(pane->id, "\x15");
        }
      });

      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() > 0, runtime_wait_ms);
      auto* footer = window_->findChild<QQuickItem*>(QStringLiteral("historyFooter"));

      QVERIFY(footer != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(!test::visualItems(*footer, QStringLiteral("historyHint")).isEmpty(), runtime_wait_ms);
      const auto click = [&](const QString& action) {
        const auto hints = test::visualItems(*footer, QStringLiteral("historyHint"));
        const auto found = std::ranges::find_if(hints, [&](const auto* hint) {
          return hint->isVisible() && hint->property("label").toMap().value(QStringLiteral("action")).toString() == action;
        });
        if (found == hints.end()) {
          return false;
        }

        const auto* hint = *found;

        QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, hint->mapToScene(QPointF{hint->width() / 2, hint->height() / 2}).toPoint());

        return true;
      };

      if (!window_->isActive()) {
        test::activateWindow(*window_);
      }

      QVERIFY(click(QStringLiteral("inspect")));
      QTRY_VERIFY_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("inspecting")).toBool(), runtime_wait_ms);
      constexpr int inspect_hints = 4;

      QCOMPARE(footer->property("hints").toList().size(), inspect_hints);
      QVERIFY(click(QStringLiteral("inspect")));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->state().value(QStringLiteral("inspecting")).toBool(), runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      test::FramePacing::presentSwapped(*client_);
      QVERIFY(!client_->history()->state().value(QStringLiteral("enterRuns")).toBool());
      QVERIFY(click(QStringLiteral("submit")));
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none, runtime_wait_ms);
      const auto* pane = firstPane();

      QVERIFY(pane != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("echo GUI_HISTORY_FIXTURE")), runtime_wait_ms);
    }

    Q_SLOT void historyFooterRequiresDeliveredChoices() {
      const telar::ds::Array entries{
          telar::ImportHistoryEntry{.started_at_ms = 100, .command = "echo GUI_HISTORY_DELIVERY_FIRST"},
          telar::ImportHistoryEntry{.started_at_ms = 101, .command = "echo GUI_HISTORY_DELIVERY_SECOND"},
      };

      importHistory(entries, "gui-history-delivery");
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
        client_->setWindow(*window_);
        QVERIFY(test::showWindow(*window_, runtime_wait_ms));
        if (const auto* pane = firstPane()) {
          client_->terminals()->input(pane->id, "\x15");
        }
      });

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_DELIVERY"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 2, runtime_wait_ms);
      window_->hide();
      QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
      test::FramePacing::presentSwapped(*client_);
      window_->beforeSynchronizing();
      window_->frameSwapped();
      test::FramePacing::presentSwapped(*client_);
      auto* footer = window_->findChild<QQuickItem*>(QStringLiteral("historyFooter"));

      QVERIFY(footer != nullptr);
      const auto activate = [&](const QString& action) {
        const auto revision = client_->history()->state().value(QStringLiteral("revision")).toString();

        return QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, action), Q_ARG(QString, revision));
      };

      client_->history()->select(1);
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1);
      for (const auto& action : {QStringLiteral("submit"), QStringLiteral("alternate")}) {
        QVERIFY(activate(action));
        QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      }

      window_->beforeSynchronizing();
      QVERIFY(activate(QStringLiteral("submit")));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      window_->frameSwapped();
      QVERIFY(activate(QStringLiteral("submit")));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      test::FramePacing::presentSwapped(*client_);
      client_->history()->search(QStringLiteral("GUI_HISTORY_DELIVERY_FIRST"));
      QVERIFY(activate(QStringLiteral("alternate")));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 1, runtime_wait_ms);
      QVERIFY(activate(QStringLiteral("submit")));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      window_->beforeSynchronizing();
      window_->frameSwapped();
      client_->commands()->execute(window_actions::Action::cancel);
      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_DELIVERY_FIRST"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 1, runtime_wait_ms);
      QVERIFY(activate(QStringLiteral("submit")));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      window_->beforeSynchronizing();
      window_->frameSwapped();
      test::FramePacing::presentSwapped(*client_);
      QQuickWindow replacement;

      client_->setWindow(replacement);
      client_->setWindow(*window_);
      QVERIFY(activate(QStringLiteral("submit")));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      window_->beforeSynchronizing();
      window_->frameSwapped();
      test::FramePacing::presentSwapped(*client_);
      for (const auto& revision : {QString{}, QStringLiteral("not-a-revision"), QStringLiteral("18446744073709551616")}) {
        QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, QStringLiteral("submit")), Q_ARG(QString, revision)));
        QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      }

      QCOMPARE(client_->history()->state().value(QStringLiteral("error")).toString(), QString{});
      QVERIFY(activate(QStringLiteral("submit")));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      QVERIFY(test::showWindow(*window_, runtime_wait_ms));
      const auto* pane = firstPane();

      QVERIFY(pane != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("echo GUI_HISTORY_DELIVERY_FIRST")), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void historyRowsRequireTheDeliveredContentRevision() {
      const telar::ds::Array entries{
          telar::ImportHistoryEntry{.started_at_ms = 100, .command = "echo GUI_ROW_PRESENTATION_A_FIRST"},
          telar::ImportHistoryEntry{.started_at_ms = 101, .command = "echo GUI_ROW_PRESENTATION_A_SECOND"},
          telar::ImportHistoryEntry{.started_at_ms = 102, .command = "echo GUI_ROW_PRESENTATION_B_FIRST"},
          telar::ImportHistoryEntry{.started_at_ms = 103, .command = "echo GUI_ROW_PRESENTATION_B_SECOND"},
      };

      importHistory(entries, "gui-row-presentation");
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
        client_->setWindow(*window_);
        QVERIFY(test::showWindow(*window_, runtime_wait_ms));
      });

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_ROW_PRESENTATION_A_"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 2, runtime_wait_ms);
      auto* results = window_->findChild<QQuickItem*>(QStringLiteral("historyResults"));

      QVERIFY(results != nullptr);
      QVERIFY(QMetaObject::invokeMethod(results, "forceLayout"));
      QTRY_COMPARE(test::visualItems(*window_->contentItem(), QStringLiteral("historyResult")).size(), 2);
      window_->hide();
      QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
      test::FramePacing::presentSwapped(*client_);
      QQuickWindow replacement;

      client_->setWindow(replacement);
      client_->setWindow(*window_);
      const auto activate = [&](int index, const QString& revision) {
        for (const auto* result : test::visualItems(*window_->contentItem(), QStringLiteral("historyResult"))) {
          if (result->property("index").toInt() != index) {
            continue;
          }

          auto* row = result->findChild<QQuickItem*>(QStringLiteral("historyRow"));

          return row != nullptr && QMetaObject::invokeMethod(row, "activated", Q_ARG(QString, revision));
        }

        return false;
      };

      const auto original_revision = client_->history()->state().value(QStringLiteral("revision")).toString();

      QVERIFY(activate(1, original_revision));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      window_->beforeSynchronizing();
      QVERIFY(activate(1, original_revision));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      window_->frameSwapped();
      QVERIFY(activate(1, original_revision));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      test::FramePacing::presentSwapped(*client_);
      client_->history()->selectPresented(-1, original_revision);
      client_->history()->selectPresented(client_->history()->rows()->rowCount(), original_revision);
      QVERIFY(activate(1, QStringLiteral("not-a-revision")));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      QVERIFY(activate(1, original_revision));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1);
      QVERIFY(activate(0, original_revision));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      client_->history()->search(QStringLiteral("GUI_ROW_PRESENTATION_B_"));
      QVERIFY(activate(1, original_revision));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading(), runtime_wait_ms);
      QCOMPARE(client_->history()->rows()->rowCount(), 2);
      // Row retirement restores the QML model through a queued call.
      QTRY_COMPARE(results->property("count").toInt(), 2);
      QVERIFY(QMetaObject::invokeMethod(results, "forceLayout"));
      QTRY_COMPARE(test::visualItems(*window_->contentItem(), QStringLiteral("historyResult")).size(), 2);
      const auto current_revision = client_->history()->state().value(QStringLiteral("revision")).toString();

      QVERIFY(current_revision != original_revision);
      QVERIFY(activate(1, original_revision));
      QVERIFY(activate(1, current_revision));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      window_->beforeSynchronizing();
      window_->frameSwapped();
      test::FramePacing::presentSwapped(*client_);
      QVERIFY(activate(1, original_revision));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      QVERIFY(activate(1, current_revision));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1);
      QCOMPARE(client_->history()->command(), QStringLiteral("echo GUI_ROW_PRESENTATION_B_FIRST"));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      QCOMPARE(client_->history()->state().value(QStringLiteral("error")).toString(), QString{});
    }

    Q_SLOT void historyReplacementNeedsDeliveryAfterWindowShown() {
      verifyHistoryReplacementAfterRestore(false);
    }

    Q_SLOT void historyReplacementNeedsDeliveryAfterWindowUnminimized() {
      if (QGuiApplication::platformName() == QLatin1StringView("offscreen")) {
        QSKIP("Native minimization requires a window-system plugin");
      }

      verifyHistoryReplacementAfterRestore(true);
    }

    void verifyHistoryReplacementAfterRestore(bool minimize) {
      const telar::ds::Array entries{
          telar::ImportHistoryEntry{.started_at_ms = 100, .command = "echo GUI_HISTORY_RESTORE_FIRST"},
          telar::ImportHistoryEntry{.started_at_ms = 101, .command = "echo GUI_HISTORY_RESTORE_SECOND"},
      };

      importHistory(entries, "gui-history-restore");
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
        window_->showNormal();
        QVERIFY(test::showWindow(*window_, runtime_wait_ms));
        if (const auto* pane = firstPane()) {
          client_->terminals()->input(pane->id, "\x15");
        }
      });

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_RESTORE_FIRST"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 1, runtime_wait_ms);
      QVERIFY(waitForHistoryPresentation());
      const auto original_revision = client_->history()->state().value(QStringLiteral("revision")).toString();

      if (minimize) {
        window_->showMinimized();
        QTRY_COMPARE_WITH_TIMEOUT(window_->visibility(), QWindow::Minimized, runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed() || window_->visibility() != QWindow::Minimized, runtime_wait_ms);
        if (window_->visibility() != QWindow::Minimized) {
          QSKIP("The window system declined the minimization request");
        }
      } else {
        window_->hide();
      }

      QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
      client_->history()->search(QStringLiteral("GUI_HISTORY_RESTORE_SECOND"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 1, runtime_wait_ms);
      QCOMPARE(client_->history()->command(), QStringLiteral("echo GUI_HISTORY_RESTORE_SECOND"));
      const auto replacement_revision = client_->history()->state().value(QStringLiteral("revision")).toString();

      QVERIFY(replacement_revision != original_revision);
      QVERIFY(!test::HistoryPresentation::current(*client_));
      auto* footer = window_->findChild<QQuickItem*>(QStringLiteral("historyFooter"));

      QVERIFY(footer != nullptr);
      QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, QStringLiteral("submit")), Q_ARG(QString, replacement_revision)));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);

      const QSignalSpy frames{window_, &QQuickWindow::frameSwapped};

      window_->showNormal();
      QVERIFY(test::showWindow(*window_, runtime_wait_ms));
      QVERIFY(waitForHistoryPresentation());
      QVERIFY(!frames.empty());
      QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, QStringLiteral("submit")), Q_ARG(QString, original_revision)));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, QStringLiteral("submit")), Q_ARG(QString, replacement_revision)));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      const auto* pane = firstPane();

      QVERIFY(pane != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("echo GUI_HISTORY_RESTORE_SECOND")), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void historyFooterPastesInPasteMode() {
      // Disjoint digit suffixes keep fuzzy queries separate from earlier shell input.
      verifyPresentedHistorySubmitMode(false, false, QStringLiteral("paste-primary-00000000"));
    }

    Q_SLOT void historyFooterRunsTheAlternateInPasteMode() {
      verifyPresentedHistorySubmitMode(false, true, QStringLiteral("paste-alternate-11111111"));
    }

    Q_SLOT void historyFooterRunsInRunMode() {
      verifyPresentedHistorySubmitMode(true, false, QStringLiteral("run-primary-22222222"));
    }

    Q_SLOT void historyFooterPastesTheAlternateInRunMode() {
      verifyPresentedHistorySubmitMode(true, true, QStringLiteral("run-alternate-33333333"));
    }

    Q_SLOT void historyFooterCaptureSurvivesPresentedEnterModeChanges() {
      for (const bool enter_runs : {false, true}) {
        for (const bool alternate : {false, true}) {
          verifyPresentedHistorySubmitMode(enter_runs, alternate, QStringLiteral("held-%1-%2").arg(static_cast<int>(enter_runs)).arg(static_cast<int>(alternate)), true);
        }
      }
    }

    void verifyPresentedHistorySubmitMode(bool enter_runs, bool alternate, const QString& tag, bool retain_capture = false) {
      const auto original_tabs = client_->tabs()->rows()->rowCount();
      const auto* original = firstPane();

      QVERIFY(original != nullptr);
      const auto original_pane = original->id;

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_tabs + 1, runtime_wait_ms);
      const auto restore_tab = qScopeGuard([this, original_tabs, original_pane] {
        closeTemporaryTab({.count = original_tabs, .pane_id = original_pane});
      });

      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != original_pane, runtime_wait_ms);
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto initial_path = directory.filePath(QStringLiteral("initial.lua"));
      const auto final_path = directory.filePath(QStringLiteral("final.lua"));
      const char* paste_configuration = "return {api_version=2,client={history={enter='paste'}}}";
      const char* run_configuration = "return {api_version=2,client={history={enter='run'}}}";

      writeTestFile(initial_path, enter_runs ? paste_configuration : run_configuration);
      writeTestFile(final_path, enter_runs ? run_configuration : paste_configuration);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
        QVERIFY(test::showWindow(*window_, runtime_wait_ms));
        if (const auto* pane = firstPane()) {
          client_->terminals()->input(pane->id, "\x15");
        }

        client_->loadConfiguration({}, {}, {});
      });

      client_->loadConfiguration(initial_path, {}, {});
      QTRY_COMPARE_WITH_TIMEOUT(client_->configuration().history.enter_runs, !enter_runs, runtime_wait_ms);
      openRenderedHistoryCommand(tag);
      QVERIFY(!QTest::currentTestFailed());
      const auto action = alternate ? QStringLiteral("alternate") : QStringLiteral("submit");
      QPointer<QQuickItem> pressed;
      bool held = false;
      QPoint position;
      const auto release = qScopeGuard([&] {
        if (held) {
          QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, position);
        }
      });

      if (retain_capture) {
        QVERIFY(waitForHistoryPresentation());
        pressed = historyFooterHint(*window_, action);
        QVERIFY(pressed != nullptr);
        position = pressed->mapToScene(QPointF{pressed->width() / 2, pressed->height() / 2}).toPoint();
        QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, position);
        held = true;
      } else {
        presentWhileHidden();
        QVERIFY(!QTest::currentTestFailed());
      }

      const auto previous_revision = client_->history()->state().value(QStringLiteral("revision")).toString();

      client_->loadConfiguration(final_path, {}, {});
      QTRY_COMPARE_WITH_TIMEOUT(client_->configuration().history.enter_runs, enter_runs, runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("enterRuns")).toBool(), enter_runs);
      auto* footer = window_->findChild<QQuickItem*>(QStringLiteral("historyFooter"));

      QVERIFY(footer != nullptr);
      const auto revision = client_->history()->state().value(QStringLiteral("revision")).toString();

      QCOMPARE(revision, previous_revision);
      if (retain_capture) {
        QVERIFY(waitForHistoryPresentation());
        auto* updated = historyFooterHint(*window_, action);

        QVERIFY(pressed != nullptr);
        QCOMPARE(updated, pressed.data());
        position = updated->mapToScene(QPointF{updated->width() / 2, updated->height() / 2}).toPoint();
        QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, position);
        held = false;
      } else {
        QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, action), Q_ARG(QString, revision)));
        QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
        window_->beforeSynchronizing();
        window_->frameSwapped();
        test::FramePacing::presentSwapped(*client_);
        QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, action), Q_ARG(QString, revision)));
      }

      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      QVERIFY(test::showWindow(*window_, runtime_wait_ms));
      verifyRenderedHistorySubmission(tag, enter_runs != alternate);
      QVERIFY(!QTest::currentTestFailed());
      QCOMPARE(client_->status()->error(), QString{});
    }

    // Imports the command tagged `tag` as the only entry of its source and opens history on it.
    void openRenderedHistoryCommand(const QString& tag) {
      const auto encoded = renderedHistoryCommand(tag).toUtf8();
      const telar::ds::Array entries{telar::ImportHistoryEntry{.started_at_ms = 100, .command = std::string_view{encoded.constData(), static_cast<std::size_t>(encoded.size())}}};
      const auto source = QByteArray{"gui-history-render-"} + tag.toUtf8();

      importHistory(entries, source.constData());
      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_RENDER_%s_%1").arg(tag));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 1, runtime_wait_ms);
    }

    // Hides the window and presents frames while it is hidden.
    void presentWhileHidden() {
      window_->hide();
      QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
      test::FramePacing::presentSwapped(*client_);
      window_->beforeSynchronizing();
      window_->frameSwapped();
      test::FramePacing::presentSwapped(*client_);
    }

    // A command history ran shows its output in the pane; one it pasted shows only its text.
    void verifyRenderedHistorySubmission(const QString& tag, bool ran) {
      const auto* pane = firstPane();

      QVERIFY(pane != nullptr);
      const auto output = QStringLiteral("GUI_HISTORY_RENDER_DONE_%1").arg(tag);

      if (ran) {
        QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(output), runtime_wait_ms);
      } else {
        QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(renderedHistoryCommand(tag)), runtime_wait_ms);
        QVERIFY(!screenText(pane->screen, ScreenTextLayout::logical).contains(output));
      }
    }

    Q_SLOT void historyPagesAndActions() {
      seedHistoryPages();
      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_BROWSER_PAGE"));
      constexpr auto page_entries = static_cast<int>(application::history::HistoryLimits::page_entries);

      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == page_entries, runtime_wait_ms);
      QVERIFY(client_->history()->state().value(QStringLiteral("canOlder")).toBool());
      captureHistoryArtifact(QStringLiteral("history-page"));
      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));
      if (search == nullptr) {
        QFAIL("Required command search fixture is missing");
      }

      QKeyEvent select_older{QEvent::KeyPress, Qt::Key_Up, Qt::NoModifier};

      QCoreApplication::sendEvent(search, &select_older);
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1);
      QKeyEvent select_newer{QEvent::KeyPress, Qt::Key_Down, Qt::NoModifier};

      QCoreApplication::sendEvent(search, &select_newer);
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);

      QKeyEvent older{QEvent::KeyPress, Qt::Key_PageUp, Qt::NoModifier};

      QCoreApplication::sendEvent(search, &older);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 1, runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("offset")).toULongLong(), static_cast<qulonglong>(page_entries));
      const auto selected = client_->history()->rows()->data(client_->history()->rows()->index(0, 0), ListModel::record_role).toMap();

      QKeyEvent inspect{QEvent::KeyPress, Qt::Key_O, NativeKeyAdapter::control_modifier};

      QCoreApplication::sendEvent(search, &inspect);
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("outputPhase")).toString(), QStringLiteral("ready"), runtime_wait_ms);
      QCOMPARE(client_->history()->output(), QString{});
      captureHistoryArtifact(QStringLiteral("history-inspection"));
      QKeyEvent close_output{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier};

      QCoreApplication::sendEvent(search, &close_output);
      QVERIFY(!client_->history()->state().value(QStringLiteral("inspecting")).toBool());
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);

      auto* clipboard = QGuiApplication::clipboard();
      auto saved_clipboard = test::copyClipboard();

      const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved_clipboard)] mutable {
        clipboard->setMimeData(saved.release());
      });

      QKeyEvent copy{QEvent::KeyPress, Qt::Key_C, NativeKeyAdapter::super_modifier};

      search->setProperty("text", QStringLiteral("selected query"));
      QVERIFY(QMetaObject::invokeMethod(search, "selectAll"));
      QCoreApplication::sendEvent(search, &copy);
      QCOMPARE(clipboard->text(), QStringLiteral("selected query"));
      QVERIFY(QMetaObject::invokeMethod(search, "deselect"));
      search->setProperty("text", QString{});
      QCoreApplication::sendEvent(search, &copy);
      QCOMPARE(clipboard->text(), selected.value(QStringLiteral("command")).toString());
      QKeyEvent erase{QEvent::KeyPress, Qt::Key_Backspace, NativeKeyAdapter::super_modifier};

      QCoreApplication::sendEvent(search, &erase);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == page_entries, runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("offset")).toULongLong(), qulonglong{0});
      QVERIFY(!client_->history()->state().value(QStringLiteral("canOlder")).toBool());

      client_->history()->setFilters({{QStringLiteral("author"), QStringLiteral("agent")}});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 0, runtime_wait_ms);
      client_->history()->setFilters({{QStringLiteral("author"), QStringLiteral("human")}, {QStringLiteral("failedOnly"), true}});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 0, runtime_wait_ms);
      client_->history()->setFilters({{QStringLiteral("scope"), QStringLiteral("pane")}, {QStringLiteral("failedOnly"), false}});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading(), runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("effectiveScope")).toString(), QStringLiteral("pane"));
      client_->commands()->execute(window_actions::Action::cancel);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void historyScopeLabelsFollowTheFocusedContext() {
      QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && !firstPane()->cwd.empty(), runtime_wait_ms);
      const auto pane_id = firstPane()->id;
      const auto original_directory = QFileInfo{toQString(firstPane()->cwd)}.canonicalFilePath();

      QVERIFY(!original_directory.isEmpty());
      const auto change_directory = [this, pane_id](QString directory) {
        directory.replace(QLatin1Char('\''), QLatin1StringView("'\\''"));
        client_->terminals()->input(pane_id, QByteArray{"\x15"
                                                        "cd '"} +
                                                 directory.toUtf8() + "' && pwd\r");
      };

      const auto restore = qScopeGuard([&] {
        change_directory(original_directory);
        client_->commands()->execute(window_actions::Action::cancel);
      });

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->setFilters({{QStringLiteral("scope"), QStringLiteral("cwd")}});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading(), runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("effectiveScope")).toString(), QStringLiteral("cwd"));
      QCOMPARE(client_->history()->state().value(QStringLiteral("scopeValue")).toString(), toQString(application::history::HistoryPath::compact(std::string_view{firstPane()->cwd}).view()));
      const auto revision = client_->history()->state().value(QStringLiteral("revision"));
      const QTemporaryDir changed_directory;

      QVERIFY(changed_directory.isValid());
      const auto changed_path = QFileInfo{changed_directory.path()}.canonicalFilePath();

      QVERIFY(!changed_path.isEmpty());
      change_directory(changed_path);
      QTRY_VERIFY2_WITH_TIMEOUT(toQString(firstPane()->cwd) == changed_path, qPrintable(screenText(firstPane()->screen, ScreenTextLayout::logical)), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("scopeValue")).toString(), toQString(application::history::HistoryPath::compact(std::string_view{firstPane()->cwd}).view()), runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("revision")), revision);
      client_->history()->setFilters({{QStringLiteral("scope"), QStringLiteral("global")}});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading(), runtime_wait_ms);
      QVERIFY(client_->history()->state().value(QStringLiteral("scopeValue")).toString().isEmpty());
      change_directory(original_directory);
      QTRY_COMPARE_WITH_TIMEOUT(toQString(firstPane()->cwd), original_directory, runtime_wait_ms);
    }

    Q_SLOT void historyControllerUpdatesKeepTheVisibleQuerySynchronized() {
      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      const auto query = QStringLiteral("!  GUI_HISTORY_FIXTURE");

      client_->history()->search(query);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading(), runtime_wait_ms);
      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), query, runtime_wait_ms);
      QVERIFY(QMetaObject::invokeMethod(search, "select", Q_ARG(int, 0), Q_ARG(int, 1)));
      QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};

      QCoreApplication::sendEvent(search, &preedit);
      client_->history()->setFilters({{QStringLiteral("author"), QStringLiteral("agent")}});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading(), runtime_wait_ms);
      QCOMPARE(search->property("text").toString(), query);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QVERIFY(search->property("layout").toMap().value(QStringLiteral("composing")).toBool());
      QCOMPARE(search->property("selectionStart").toInt(), 0);
      QCOMPARE(search->property("selectionEnd").toInt(), 1);
      const auto replacement = QStringLiteral("GUI_HISTORY_NEW_QUERY");

      client_->history()->search(replacement);
      QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), replacement, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
    }

    Q_SLOT void historyQueryOverflowPublishesTheExistingLimitNotice() {
      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      const auto maximum = client_->history()->state().value(QStringLiteral("maximumQueryBytes")).toInt();
      const QString typed(maximum + 1, QLatin1Char('x'));
      // The notice reaches the window, not only the session.
      const QSignalSpy presented{client_->notifications(), &NotificationsController::changed};
      QInputMethodEvent commit;

      commit.setCommitString(typed);
      QCoreApplication::sendEvent(search, &commit);
      QCOMPARE(search->property("text").toString(), typed.first(maximum));
      QVERIFY(presented.count() > 0);
      const auto reached = [this] {
        return std::ranges::any_of(client_->notifications()->center().items(), [](const auto& notice) {
          return notice.title.view() == "Limit reached" && notice.message.view().find("prompt.history_query_bytes") != std::string_view::npos;
        });
      };

      QTRY_VERIFY_WITH_TIMEOUT(reached(), runtime_wait_ms);
      const auto notice = std::ranges::find_if(client_->notifications()->center().items(), [](const auto& item) {
        return item.title.view() == "Limit reached" && item.message.view().find("prompt.history_query_bytes") != std::string_view::npos;
      });

      const auto identity = notice->id;

      captureHistoryArtifact(QStringLiteral("history-query-limit"));
      client_->notifications()->dismiss(client_->notifications()->identity(identity));
      QTRY_VERIFY_WITH_TIMEOUT(client_->notifications()->center().find(identity) == nullptr, runtime_wait_ms);

      const QString retained(maximum - 1, QLatin1Char('x'));

      client_->history()->search(retained + QStringLiteral("🧵"));
      QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), retained, runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("editorText")).toString(), retained);
    }

    Q_SLOT void historyMalformedUtf16UsesTheEncodedByteLimit() {
      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        const auto notices = client_->notifications()->center().items();
        const auto found = std::ranges::find_if(notices, [](const auto& notice) {
          return notice.title.view() == "Limit reached" && notice.message.view().find("prompt.history_query_bytes") != std::string_view::npos;
        });
        if (found != notices.end()) {
          const auto identity = found->id;

          client_->notifications()->dismiss(client_->notifications()->identity(identity));
        }

        client_->commands()->execute(window_actions::Action::cancel);
      });

      const auto maximum = client_->history()->state().value(QStringLiteral("maximumQueryBytes")).toInt();
      constexpr int reserved_bytes = 8;
      constexpr int invalid_units = 12;
      constexpr int tail_units = 20;
      const QString prefix(maximum - reserved_bytes, QLatin1Char('a'));
      const QString invalid(invalid_units, QChar{Utf16Prefix::first_low_surrogate});
      const QString tail(tail_units, QLatin1Char('b'));
      const auto query = prefix + invalid + QStringLiteral("🧵") + tail;

      QVERIFY(!query.isValidUtf16());
      const auto encoded = query.toUtf8();
      const auto expected = telar::runtime::utf8Prefix({encoded.constData(), static_cast<std::size_t>(encoded.size())}, static_cast<std::size_t>(maximum));

      client_->history()->search(query);
      const auto retained = client_->history()->state().value(QStringLiteral("editorText")).toString();

      QCOMPARE(retained.toUtf8(), QByteArray(expected.data(), static_cast<qsizetype>(expected.size())));
      QVERIFY(retained.isValidUtf16());
      QVERIFY(retained.toUtf8().size() <= maximum);
    }

    Q_SLOT void historyShiftTabCyclesAuthorsForBothQtKeyForms() {
      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      client_->history()->setFilters({{QStringLiteral("scope"), QStringLiteral("global")}, {QStringLiteral("author"), QStringLiteral("human")}});
      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));
      if (search == nullptr) {
        QFAIL("History query field must exist");
      }

      search->forceActiveFocus();
      QTest::keyClick(window_, Qt::Key_Tab, Qt::ShiftModifier);
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("author")).toString(), QStringLiteral("agent"), runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("scope")).toString(), QStringLiteral("global"));
      QTest::keyClick(window_, Qt::Key_Backtab, Qt::ShiftModifier);
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("author")).toString(), QStringLiteral("all"), runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("scope")).toString(), QStringLiteral("global"));
      QVERIFY(search->hasActiveFocus());
    }

    Q_SLOT void historyEmptyRecoveryPreservesQueryAndFocus() {
      seedHistoryScroll();
      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      const auto query = QStringLiteral("GUI_SCROLL_HISTORY_NO_MATCH");

      client_->history()->setFilters({{QStringLiteral("scope"), QStringLiteral("workspace")}, {QStringLiteral("author"), QStringLiteral("all")}});
      client_->history()->search(query);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 0, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("effectiveScope")).toString(), QStringLiteral("workspace"), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(window_->findChild<QQuickItem*>(QStringLiteral("historyEmptyTitle")) != nullptr, runtime_wait_ms);
      const auto* title = window_->findChild<QQuickItem*>(QStringLiteral("historyEmptyTitle"));
      const auto* button = window_->findChild<QQuickItem*>(QStringLiteral("historySearchEverywhere"));
      const auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));
      if (title == nullptr || button == nullptr || search == nullptr) {
        QFAIL("Empty history controls and the query field must exist");
      }

      QCOMPARE(title->property("text").toString(), QStringLiteral("No matches in workspace ") + client_->workspaces()->context().value(QStringLiteral("name")).toString());
      QVERIFY(waitForHistoryPresentation());
      QVERIFY(button->isVisible());
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, button->mapToScene({button->width() / 2, button->height() / 2}).toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->state().value(QStringLiteral("effectiveScope")).toString() == QStringLiteral("global"), runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("editorText")).toString(), query);
      QVERIFY(search->hasActiveFocus());
      QTRY_COMPARE_WITH_TIMEOUT(title->property("text").toString(), QStringLiteral("No matching commands"), runtime_wait_ms);
      QVERIFY(!button->isVisible());
      client_->history()->search(QStringLiteral("GUI_SCROLL_HISTORY_A_"));
      constexpr int count = 4;

      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == count, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(window_->findChild<QQuickItem*>(QStringLiteral("historyEmptyTitle")) == nullptr, runtime_wait_ms);
    }

    Q_SLOT void historyWheelMovesSelectionAcrossTheWholeModal() {
      seedHistoryScroll();
      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      client_->history()->search(QStringLiteral("GUI_SCROLL_HISTORY_A_"));
      constexpr int count = 4;

      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == count, runtime_wait_ms);
      const auto* panel = window_->findChild<QQuickItem*>(QStringLiteral("historyPanel"));
      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));
      if (panel == nullptr || search == nullptr) {
        QFAIL("History panel and search field must exist");
      }

      search->forceActiveFocus();
      constexpr int half_notch = 60;

      for (const auto* region : {"header", "results", "search", "footer"}) {
        client_->history()->select(0);
        QVERIFY(waitForHistoryPresentation());
        const auto area = client_->history()->geometry().value(QString::fromLatin1(region)).toRectF();
        const auto position = panel->mapToScene(area.center());

        QVERIFY(sendHistoryWheel(position, {}, {0, half_notch}, Qt::ScrollBegin));
        QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
        QVERIFY(sendHistoryWheel(position, {}, {0, half_notch}, Qt::ScrollUpdate));
        QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);
        QVERIFY(search->hasActiveFocus());
        QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      }

      client_->history()->select(0);
      QVERIFY(waitForHistoryPresentation());
      auto row_height = std::numeric_limits<qreal>::max();

      for (const auto* row : test::visualItems(*window_->contentItem(), QStringLiteral("historyRow"))) {
        if (row->isVisible()) {
          row_height = std::min(row_height, row->property("layout").toMap().value(QStringLiteral("frame")).toRectF().height());
        }
      }

      if (row_height == std::numeric_limits<qreal>::max()) {
        QFAIL("A delivered history row must exist");
      }

      const auto grid = client_->display()->geometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid")).toMap();
      const auto cell_pixels = static_cast<int>(std::ceil(grid.value(QStringLiteral("cellHeight")).toDouble()));
      const auto row_pixels = static_cast<int>(std::ceil(row_height));

      QVERIFY(cell_pixels > 0 && cell_pixels < row_pixels);
      const auto position = panel->mapToScene(client_->history()->geometry().value(QStringLiteral("header")).toRectF().center());

      QVERIFY(sendHistoryWheel(position, {0, cell_pixels}, {0, cell_pixels * 2}, Qt::ScrollBegin));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      QVERIFY(sendHistoryWheel(position, {0, row_pixels - cell_pixels}, {0, (row_pixels - cell_pixels) * 2}, Qt::ScrollUpdate));
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);

      const auto selected = client_->history()->state().value(QStringLiteral("selection")).toInt();

      QVERIFY(sendHistoryWheel(panel->mapToScene({panel->width() + 1, panel->height() / 2}), {}, {0, half_notch * 2}, Qt::ScrollBegin));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), selected);
    }

    Q_SLOT void historyWheelKeepsFractionThroughAnEmptyPresentedPage() {
      seedHistoryScroll();
      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      client_->history()->search(QStringLiteral("GUI_SCROLL_HISTORY_NO_MATCH"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 0, runtime_wait_ms);
      QVERIFY(waitForHistoryPresentation());
      const auto* panel = window_->findChild<QQuickItem*>(QStringLiteral("historyPanel"));
      if (panel == nullptr) {
        QFAIL("History panel must exist");
      }

      const auto position = panel->mapToScene(client_->history()->geometry().value(QStringLiteral("header")).toRectF().center());
      constexpr int half_notch = 60;

      QVERIFY(sendHistoryWheel(position, {}, {0, half_notch}, Qt::ScrollBegin));
      client_->history()->search(QStringLiteral("GUI_SCROLL_HISTORY_A_"));
      constexpr int count = 4;

      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == count, runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      QVERIFY(waitForHistoryPresentation());
      QVERIFY(sendHistoryWheel(position, {}, {0, half_notch}, Qt::ScrollUpdate));
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);
    }

    Q_SLOT void historyWheelScrollsInspectionFromEveryBand() {
      std::string command;
      constexpr int command_lines = 80;

      for (int index = 0; index < command_lines; ++index) {
        command += "printf GUI_SCROLL_INSPECTION_" + std::to_string(index) + "\n";
      }

      const telar::ds::Array entries{telar::ImportHistoryEntry{.started_at_ms = 100, .command = command}};

      importHistory(entries, "gui-wheel-inspection");
      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      client_->history()->search(QStringLiteral("GUI_SCROLL_INSPECTION_"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 1, runtime_wait_ms);
      client_->history()->execute(HistoryController::Action::inspect);
      QTRY_VERIFY_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("commandLoaded")).toBool(), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("outputPhase")).toString(), QStringLiteral("ready"), runtime_wait_ms);
      const auto* panel = window_->findChild<QQuickItem*>(QStringLiteral("historyPanel"));
      if (panel == nullptr) {
        QFAIL("History panel must exist");
      }

      QTRY_VERIFY_WITH_TIMEOUT(window_->findChild<QQuickItem*>(QStringLiteral("historyInspector")) != nullptr, runtime_wait_ms);
      const auto* inspector = window_->findChild<QQuickItem*>(QStringLiteral("historyInspector"));
      if (inspector == nullptr) {
        QFAIL("History inspector must exist");
      }

      QTRY_VERIFY_WITH_TIMEOUT(inspector->property("layout").toMap().value(QStringLiteral("maximumScroll")).toInt() > 0, runtime_wait_ms);
      QVERIFY(waitForHistoryPresentation());
      constexpr int notch = 120;
      int expected_scroll = 0;

      for (const auto* region : {"header", "results", "search", "footer"}) {
        const auto area = client_->history()->geometry().value(QString::fromLatin1(region)).toRectF();

        QVERIFY(sendHistoryWheel(panel->mapToScene(area.center()), {}, {0, -notch}, Qt::ScrollBegin));
        ++expected_scroll;
        QTRY_COMPARE_WITH_TIMEOUT(inspector->property("scroll").toInt(), expected_scroll, runtime_wait_ms);
        QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      }

      const auto grid = client_->display()->geometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid")).toMap();
      const auto whole_cell = static_cast<int>(std::ceil(grid.value(QStringLiteral("cellHeight")).toDouble()));

      QVERIFY(whole_cell > 1);
      const auto half_cell = whole_cell / 2;
      const auto position = panel->mapToScene(client_->history()->geometry().value(QStringLiteral("header")).toRectF().center());

      QVERIFY(sendHistoryWheel(position, {0, -half_cell}, {0, -half_cell * 2}, Qt::ScrollBegin));
      QCOMPARE(inspector->property("scroll").toInt(), expected_scroll);
      QVERIFY(sendHistoryWheel(position, {0, -(whole_cell - half_cell)}, {0, -(whole_cell - half_cell) * 2}, Qt::ScrollUpdate));
      QTRY_COMPARE_WITH_TIMEOUT(inspector->property("scroll").toInt(), expected_scroll + 1, runtime_wait_ms);
    }

    Q_SLOT void historyWheelWaitsForPresentedRowsAndDialogGeneration() {
      seedHistoryScroll();
      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
        QVERIFY(test::showWindow(*window_, runtime_wait_ms));
      });

      client_->history()->search(QStringLiteral("GUI_SCROLL_HISTORY_A_"));
      constexpr int count = 4;

      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == count, runtime_wait_ms);
      QVERIFY(waitForHistoryPresentation());
      const auto* panel = window_->findChild<QQuickItem*>(QStringLiteral("historyPanel"));
      if (panel == nullptr) {
        QFAIL("History panel must exist");
      }

      const auto position = panel->mapToScene(client_->history()->geometry().value(QStringLiteral("header")).toRectF().center());

      window_->hide();
      QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
      test::FramePacing::presentSwapped(*client_);
      client_->history()->search(QStringLiteral("GUI_SCROLL_HISTORY_B_"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == count, runtime_wait_ms);
      constexpr int notch = 120;

      QVERIFY(sendHistoryWheel(position, {}, {0, notch}, Qt::ScrollBegin));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      window_->beforeSynchronizing();
      QVERIFY(sendHistoryWheel(position, {}, {0, notch}, Qt::ScrollUpdate));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      QVERIFY(test::showWindow(*window_, runtime_wait_ms));
      QVERIFY(waitForHistoryPresentation());
      QVERIFY(sendHistoryWheel(position, {}, {0, notch}, Qt::ScrollBegin));
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);
      window_->hide();
      QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::cancel);
      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_SCROLL_HISTORY_B_"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == count, runtime_wait_ms);
      QVERIFY(sendHistoryWheel(position, {}, {0, notch}, Qt::ScrollBegin));
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      QVERIFY(test::showWindow(*window_, runtime_wait_ms));
      QVERIFY(waitForHistoryPresentation());
      QVERIFY(sendHistoryWheel(position, {}, {0, notch}, Qt::ScrollBegin));
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);
    }

    Q_SLOT void historyWheelStopsAtPageAdmission() {
      constexpr auto page_count = application::history::HistoryLimits::page_entries;
      constexpr auto entry_count = page_count + 2;
      telar::ds::Array<std::string, entry_count> commands;
      telar::ds::Array<telar::ImportHistoryEntry, entry_count> entries{};

      for (std::size_t index = 0; index < entries.size(); ++index) {
        commands.atMut(index) = "echo GUI_SCROLL_PAGE_" + std::to_string(index);
        entries.atMut(index) = {.started_at_ms = static_cast<std::int64_t>(index), .command = commands[index]};
      }

      importHistory(entries, "gui-wheel-page");
      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      client_->history()->search(QStringLiteral("GUI_SCROLL_PAGE_"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == page_count, runtime_wait_ms);
      client_->history()->select(page_count - 2);
      QVERIFY(waitForHistoryPresentation());
      const auto* panel = window_->findChild<QQuickItem*>(QStringLiteral("historyPanel"));
      if (panel == nullptr) {
        QFAIL("History panel must exist");
      }

      const auto position = panel->mapToScene(client_->history()->geometry().value(QStringLiteral("header")).toRectF().center());
      constexpr int notch = 120;

      QVERIFY(sendHistoryWheel(position, {}, {0, notch * 2}, Qt::ScrollBegin));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->state().value(QStringLiteral("offset")).toInt() == page_count, runtime_wait_ms);
      QCOMPARE(client_->history()->rows()->rowCount(), 2);
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), 0);
      QVERIFY(waitForHistoryPresentation());
      QVERIFY(sendHistoryWheel(position, {}, {0, -notch}, Qt::ScrollBegin));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->state().value(QStringLiteral("offset")).toInt() == 0, runtime_wait_ms);
      QCOMPARE(client_->history()->state().value(QStringLiteral("selection")).toInt(), page_count - 1);
    }

    Q_SLOT void historyCompositionConsumesTheFirstEscape() {
      verifyHistoryCompositionEscape(HistoryView::results);
    }

    Q_SLOT void historyInspectionCompositionConsumesTheFirstEscape() {
      verifyHistoryCompositionEscape(HistoryView::inspector);
    }

    Q_SLOT void historyInspectionTracksTabRenamingAndPaneClosure() {
      const auto original_tabs = client_->tabs()->rows()->rowCount();
      const auto* original = firstPane();

      QVERIFY(original != nullptr);
      const auto original_identity = original->id;
      const auto restore = qScopeGuard([this, original_tabs, original_identity] {
        client_->commands()->execute(window_actions::Action::cancel);
        if (client_->tabs()->rows()->rowCount() > original_tabs) {
          closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
        }
      });

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_VERIFY_WITH_TIMEOUT(client_->tabs()->rows()->rowCount() == original_tabs + 1 && terminalReady() && firstPane()->id != original_identity, runtime_wait_ms);
      const auto pane_id = firstPane()->id;

      client_->terminals()->input(pane_id, "printf 'GUI_HISTORY_LIVE_METADATA\\n'\n");
      const auto printed = [&] {
        const auto lines = screenText(firstPane()->screen, ScreenTextLayout::logical).split(QLatin1Char('\n'));

        return std::ranges::any_of(lines, [](const auto& line) {
          return line.trimmed() == QLatin1StringView("GUI_HISTORY_LIVE_METADATA");
        });
      };

      QTRY_VERIFY_WITH_TIMEOUT(printed(), runtime_wait_ms);
      client_->terminals()->input(pane_id, "\x15");
      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_LIVE_METADATA"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 1, runtime_wait_ms);
      QVERIFY(client_->history()->state().value(QStringLiteral("paneOpen")).toBool());
      client_->history()->execute(HistoryController::Action::inspect);
      QTRY_VERIFY_WITH_TIMEOUT(window_->findChild<QQuickItem*>(QStringLiteral("historyInspector")) != nullptr, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("outputPhase")).toString() != QLatin1StringView("loading") && client_->history()->state().value(QStringLiteral("commandPhase")).toString() != QLatin1StringView("loading"), runtime_wait_ms);
      QVERIFY(waitForHistoryPresentation());
      const QPointer<QQuickItem> inspector = window_->findChild<QQuickItem*>(QStringLiteral("historyInspector"));
      const auto pane_fact = [&] {
        if (!inspector) {
          return QString{};
        }

        for (const auto& fact : inspector->property("details").toMap().value(QStringLiteral("facts")).toList()) {
          const auto entry = fact.toMap();
          if (entry.value(QStringLiteral("label")).toString() == QLatin1StringView("Pane")) {
            return entry.value(QStringLiteral("text")).toString();
          }
        }

        return QString{};
      };

      const auto revision = client_->history()->state().value(QStringLiteral("revision")).toString();
      const auto query = client_->history()->state().value(QStringLiteral("editorText")).toString();
      const auto command = client_->history()->command();
      const QSignalSpy rows_changed{client_->history()->rows(), &QAbstractItemModel::dataChanged};

      test::HistoryPresentation::renameTab(*client_, "Live history tab");
      const auto tab_renamed = [&] {
        for (int index = 0; index < client_->tabs()->rows()->rowCount(); ++index) {
          if (client_->tabs()->rows()->data(client_->tabs()->rows()->index(index, 0), ListModel::record_role).toMap().value(QStringLiteral("label")).toString() == QLatin1StringView("Live history tab")) {
            return true;
          }
        }

        return false;
      };

      QTRY_VERIFY_WITH_TIMEOUT(tab_renamed(), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(pane_fact(), QString::number(pane_id) + QStringLiteral("  ·  tab Live history tab"), runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::close_tab);
      QTRY_VERIFY_WITH_TIMEOUT(client_->tabs()->rows()->rowCount() == original_tabs && client_->pane(pane_id) == nullptr, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(pane_fact(), QString::number(pane_id) + QStringLiteral("  ·  closed"), runtime_wait_ms);
      QVERIFY(!inspector->property("browserState").toMap().value(QStringLiteral("paneOpen")).toBool());
      QVERIFY(!client_->history()->state().value(QStringLiteral("paneOpen")).toBool());
      QCOMPARE(client_->history()->state().value(QStringLiteral("revision")).toString(), revision);
      QCOMPARE(client_->history()->state().value(QStringLiteral("editorText")).toString(), query);
      QCOMPARE(client_->history()->command(), command);
      QCOMPARE(client_->history()->rows()->rowCount(), 1);
      QCOMPARE(rows_changed.size(), 0);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void historyEmptyReplyRetiresPendingDelegatesBeforeTheirRows() {
      verifyHistoryDelegateRetirement(QStringLiteral("GUI_HISTORY_GEOMETRY_NO_MATCH"), 0);
    }

    Q_SLOT void historyFilteredReplyRetiresPendingDelegatesBeforeTheirRows() {
      verifyHistoryDelegateRetirement(QStringLiteral("GUI_BROWSER_PAGE_DELEGATE_SINGLE_TARGET"), 1);
    }

    Q_SLOT void historyEqualSizedReplyUpdatesPendingDelegates() {
      constexpr auto entry_count = application::history::HistoryLimits::page_entries;
      telar::ds::Array<std::string, entry_count> commands;
      telar::ds::Array<telar::ImportHistoryEntry, entry_count> entries{};

      for (std::size_t index = 0; index < entries.size(); ++index) {
        commands.atMut(index) = "echo GUI_REPLACEMENT_TARGET_" + std::to_string(index);
        entries.atMut(index) = {.started_at_ms = static_cast<std::int64_t>(index) + 1, .command = commands[index]};
      }

      importHistory(entries, "gui-replacement-target");
      verifyHistoryDelegateRetirement(QStringLiteral("GUI_REPLACEMENT_TARGET"), static_cast<int>(entry_count));
    }

    Q_SLOT void historyGeometryAndFocusSurviveInspection() {
      const auto previous_size = window_->size();
      const auto restore = qScopeGuard([this, previous_size] {
        client_->commands()->execute(window_actions::Action::cancel);
        window_->resize(previous_size);
      });

      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_FIXTURE"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() > 0, runtime_wait_ms);
      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));
      const auto* panel = window_->findChild<QQuickItem*>(QStringLiteral("historyPanel"));
      const auto* results = window_->findChild<QQuickItem*>(QStringLiteral("historyResults"));

      QVERIFY(search != nullptr && panel != nullptr && results != nullptr);
      const auto search_bounds = [&] {
        return search->mapRectToScene(QRectF{QPointF{}, search->size()});
      };

      const auto expected_search = [&] {
        const auto geometry = client_->history()->geometry();

        return geometry.value(QStringLiteral("search")).toRectF().translated(geometry.value(QStringLiteral("bounds")).toRectF().topLeft());
      };

      search->forceActiveFocus();
      QTRY_COMPARE(search_bounds().top(), expected_search().top());
      QCOMPARE(search_bounds().height(), expected_search().height());
      QVERIFY(expected_search().contains(search_bounds()));
      QVERIFY(search_bounds().y() > static_cast<qreal>(window_->height()) / 2);
      const auto original_search = search_bounds();
      const auto original_panel_size = panel->size();

      client_->history()->execute(HistoryController::Action::inspect);
      QTRY_COMPARE(search_bounds(), original_search);
      QCOMPARE(panel->size(), original_panel_size);
      QVERIFY(search->hasActiveFocus());
      captureHistoryArtifact(QStringLiteral("history-geometry-wide"));

      constexpr int narrow_width = 600;

      window_->resize(narrow_width, previous_size.height());
      QTRY_COMPARE_WITH_TIMEOUT(window_->width(), narrow_width, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QTRY_COMPARE(search_bounds().top(), expected_search().top());
      QTRY_COMPARE(search_bounds().height(), expected_search().height());
      QVERIFY(expected_search().contains(search_bounds()));
      QTRY_VERIFY_WITH_TIMEOUT(!results->isVisible(), runtime_wait_ms);
      const auto narrow_search = search_bounds();
      const auto search_observation = [&] {
        QString result;
        QDebug stream{&result};

        stream.nospace() << windowObservation(*window_) << " expected=" << narrow_search << " observed=" << search_bounds() << " model=" << expected_search();

        return result;
      };

      client_->history()->execute(HistoryController::Action::inspect);
      QTRY_VERIFY_WITH_TIMEOUT(results->isVisible(), runtime_wait_ms);
      QVERIFY2(search_bounds() == narrow_search, qPrintable(search_observation()));
      QVERIFY(search->hasActiveFocus());
      captureHistoryArtifact(QStringLiteral("history-geometry-narrow"));

      client_->history()->search(QStringLiteral("GUI_HISTORY_GEOMETRY_NO_MATCH"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 0, runtime_wait_ms);
      QVERIFY2(search_bounds() == narrow_search, qPrintable(search_observation()));
      QVERIFY(search->hasActiveFocus());
    }

    Q_SLOT void historyValidationFeedback() {
      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_HISTORY_FIXTURE"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() > 0, runtime_wait_ms);
      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));
      if (search == nullptr) {
        QFAIL("Required history search fixture is missing");
      }

      QKeyEvent scope{QEvent::KeyPress, Qt::Key_Tab, Qt::NoModifier};

      QCoreApplication::sendEvent(search, &scope);
      QCOMPARE(client_->history()->state().value(QStringLiteral("scope")).toString(), QStringLiteral("workspace"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading(), runtime_wait_ms);
      QKeyEvent author{QEvent::KeyPress, Qt::Key_Backtab, Qt::ShiftModifier};

      QCoreApplication::sendEvent(search, &author);
      QCOMPARE(client_->history()->state().value(QStringLiteral("author")).toString(), QStringLiteral("agent"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == 0, runtime_wait_ms);
      client_->history()->setFilters({{QStringLiteral("scope"), QStringLiteral("global")}, {QStringLiteral("author"), QStringLiteral("human")}});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() > 0, runtime_wait_ms);
      const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
      QKeyEvent inspect{QEvent::KeyPress, Qt::Key_O, control};

      QCoreApplication::sendEvent(search, &inspect);
      QVERIFY(client_->history()->state().value(QStringLiteral("inspecting")).toBool());
      QKeyEvent close_output{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier};

      QCoreApplication::sendEvent(window_, &close_output);
      QVERIFY(!client_->history()->state().value(QStringLiteral("inspecting")).toBool());
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);

      client_->history()->use(0);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      const auto* pane = firstPane();
      if (pane == nullptr) {
        QFAIL("Required terminal fixture is missing");
      }

      client_->terminals()->input(pane->id, "\x15");
    }

    Q_SLOT void historyLongCommands() {
      using Storage = application::history::HistoryLimits;
      constexpr std::size_t command_bytes = std::size_t{48} * 1024;
      constexpr auto cached_entries = Storage::command_cache_bytes / command_bytes;
      constexpr auto entry_count = cached_entries + 1;
      telar::ds::Array<std::string, entry_count> commands;
      telar::ds::Array<telar::ImportHistoryEntry, entry_count> entries{};

      for (std::size_t index = 0; index < entries.size(); ++index) {
        commands.atMut(index) = "echo GUI_LONG_COMMAND_" + std::to_string(index) + " ";
        commands.atMut(index).resize(command_bytes, 'x');
        entries.atMut(index) = {.started_at_ms = static_cast<std::int64_t>(index) + 1, .command = commands[index]};
      }

      importHistory(entries, "gui-long-command");
      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_LONG_COMMAND"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == static_cast<int>(entry_count), runtime_wait_ms);
      const auto last = client_->history()->rows()->data(client_->history()->rows()->index(static_cast<int>(cached_entries), 0), ListModel::record_role).toMap();

      QVERIFY(last.value(QStringLiteral("command")).toString().toUtf8().size() <= static_cast<qsizetype>(Storage::command_preview_bytes));
      client_->history()->select(static_cast<int>(cached_entries));
      QTRY_COMPARE_WITH_TIMEOUT(client_->history()->state().value(QStringLiteral("commandPhase")).toString(), QStringLiteral("ready"), runtime_wait_ms);
      QVERIFY(client_->history()->state().value(QStringLiteral("canSubmit")).toBool());

      auto* clipboard = QGuiApplication::clipboard();
      auto saved_clipboard = test::copyClipboard();

      const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved_clipboard)] mutable {
        clipboard->setMimeData(saved.release());
      });

      client_->history()->execute(HistoryController::Action::copy);
      const auto* const expected = std::ranges::find_if(commands, [&](const auto& command) {
        return toQString(command).startsWith(last.value(QStringLiteral("command")).toString());
      });

      QVERIFY(expected != commands.end());
      QCOMPARE(clipboard->text(), toQString(*expected));
      QCOMPARE(client_->history()->command(), toQString(*expected));
      const auto selected_card = [&] {
        const auto cards = test::visualItems(*window_->contentItem(), QStringLiteral("historyRow"));
        const auto found = std::ranges::find_if(cards, [](const auto* card) {
          return card->property("selected").toBool();
        });

        return found == cards.end() ? nullptr : *found;
      };

      QTRY_VERIFY_WITH_TIMEOUT(selected_card() != nullptr, runtime_wait_ms);
      const auto* card = selected_card();
      if (card == nullptr) {
        QFAIL("Required selected history card is missing");
      }

      QCOMPARE(card->property("commandText").toString(), toQString(*expected));
      QTRY_COMPARE_WITH_TIMEOUT(card->property("layout").toMap().value(QStringLiteral("more")).toInt(), static_cast<int>(application::history::HistoryCard::more_bound), runtime_wait_ms);
      const auto* results = window_->findChild<QQuickItem*>(QStringLiteral("historyResults"));
      if (results == nullptr) {
        QFAIL("Required history results viewport is missing");
      }

      constexpr qreal geometry_epsilon = 0.001;
      const auto card_is_visible = [&] {
        const auto top = card->mapToItem(results, QPointF{}).y();
        const auto bottom = card->mapToItem(results, QPointF{0, card->height()}).y();

        return top >= -geometry_epsilon && bottom <= results->height() + geometry_epsilon;
      };

      QTRY_VERIFY_WITH_TIMEOUT(card_is_visible(), runtime_wait_ms);
      captureHistoryArtifact(QStringLiteral("history-selected-command"));
      client_->history()->execute(HistoryController::Action::inspect);
      const auto* command_area = window_->findChild<QQuickItem*>(QStringLiteral("historyCommand"));

      QVERIFY(command_area != nullptr);
      QCOMPARE(command_area->property("text").toString(), toQString(*expected));
      captureHistoryArtifact(QStringLiteral("history-long-command"));
      client_->commands()->execute(window_actions::Action::cancel);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void routedGoto() {
      const auto cleanup = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto stale_query = QStringLiteral("> stale query before routed goto");

      client_->commands()->execute(window_actions::Action::palette);
      client_->palette()->search(stale_query);
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);

      // Goto does not open over another prompt and leaves it as it was.
      peer.request(telar::ClientAction::client_open_goto, 1);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{1}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("ClientPromptUnavailable"));
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      QCOMPARE(client_->palette()->state().value(QStringLiteral("editorText")).toString(), stale_query);
      client_->commands()->execute(window_actions::Action::cancel);

      peer.request(telar::ClientAction::client_open_goto, 2);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QCOMPARE(peer.result().text, QString{});
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      QCOMPARE(client_->palette()->state().value(QStringLiteral("mode")).toInt(), static_cast<int>(application::palette::PaletteMode::navigate));
      QCOMPARE(client_->palette()->state().value(QStringLiteral("editorText")).toString(), QStringLiteral("@"));
      QCOMPARE(client_->palette()->state().value(QStringLiteral("query")).toString(), QString{});
      QVERIFY(client_->palette()->state().value(QStringLiteral("count")).toInt() > 0);
      const auto* search = window_->findChild<NativeFormField*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
      QCOMPARE(search->text(), QStringLiteral("@"));
      client_->commands()->execute(window_actions::Action::cancel);
      client_->commands()->execute(window_actions::Action::copy_mode);
      QVERIFY(client_->copy()->active());
      peer.request(telar::ClientAction::client_open_goto, 3);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("ClientPromptUnavailable"));
      QVERIFY(client_->copy()->active());
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none);
      QCOMPARE(peer.error(), QString{});
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void routedHistory() {
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      peer.request(telar::ClientAction::client_open_history, 2);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QCOMPARE(peer.result().text, QString{});
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      QTRY_VERIFY_WITH_TIMEOUT(client_->history()->rows()->rowCount() > 0, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::cancel);
      QCOMPARE(peer.error(), QString{});
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void routedSidebarResize() {
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      constexpr std::int64_t maximum_width = 65535;

      peer.request(telar::ClientAction::sidebar_resize, 2, {}, maximum_width);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      constexpr std::int64_t minimum_width = 42;

      QVERIFY(peer.result().value >= minimum_width && peer.result().value < maximum_width);
      const auto width = peer.result().value;
      const auto visibility = peer.result().text;
      const QSignalSpy unchanged{client_->display(), &WindowDisplay::changed};

      QVERIFY(unchanged.isValid());
      peer.request(telar::ClientAction::sidebar_resize, 3, {}, width);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
      QCOMPARE(peer.result().value, width);
      QCOMPARE(peer.result().text, visibility);
      QCOMPARE(unchanged.count(), 0);
      peer.request(telar::ClientAction::sidebar_get, 4);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{4}, runtime_wait_ms);
      QCOMPARE(peer.result().value, width);
      constexpr std::uint64_t rejected_request = 5;

      peer.request(telar::ClientAction::sidebar_resize, rejected_request, {}, -1);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, rejected_request, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("InvalidWidth"));
      QCOMPARE(unchanged.count(), 0);
      QCOMPARE(peer.error(), QString{});
    }

    Q_SLOT void translucentWindowBackgroundPreservesColor() {
      const QTemporaryDir directory;
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      const auto restore = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      auto* background = window_->findChild<QQuickItem*>(QStringLiteral("workspaceBackground"));

      QVERIFY(background != nullptr);
      constexpr telar::ds::Array opacities{0.25, 0.75, 1.0, 0.25};
      constexpr int channel_tolerance = 2;

      for (const auto opacity : opacities) {
        const auto source = QStringLiteral("return {api_version=2,gui={window={background_opacity=%1}}}").arg(opacity).toUtf8();

        writeTestFile(path, source.constData());
        client_->loadConfiguration(path, {}, {});
        QCOMPARE(client_->status()->error(), QString{});
        QCOMPARE(window_->color(), QColor{Qt::transparent});
        const auto expected = client_->colors().value(QStringLiteral("workbenchBackground")).value<QColor>();

        QCOMPARE(background->property("color").value<QColor>(), expected);
        const auto capture = background->grabToImage(QSize{64, 64});

        QVERIFY(!capture.isNull());
        QTRY_VERIFY_WITH_TIMEOUT(!capture->image().isNull(), runtime_wait_ms);
        const auto actual = capture->image().pixelColor(0, 0);

        QVERIFY(std::abs(actual.alpha() - expected.alpha()) <= 1);
        QVERIFY(std::abs(actual.red() - expected.red()) <= channel_tolerance);
        QVERIFY(std::abs(actual.green() - expected.green()) <= channel_tolerance);
        QVERIFY(std::abs(actual.blue() - expected.blue()) <= channel_tolerance);
      }
    }

    Q_SLOT void independentSurfaceOpacityDoesNotStack() {
      const QTemporaryDir directory;
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      const auto restore = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      writeTestFile(path, "return {api_version=2,gui={window={background_opacity=1},opacity={topbar=0.2,sidebar=0.4,bottombar=0.6,workspace=0.8,pane=0.3}}}");
      client_->loadConfiguration(path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto geometry = client_->display()->geometry();
      const auto sidebar = geometry.value(QStringLiteral("sidebar")).toRectF();
      const auto navigation = geometry.value(QStringLiteral("navigation")).toRectF();
      const auto status = geometry.value(QStringLiteral("status")).toRectF();
      const auto frame = window_->grabWindow();

      QVERIFY(!frame.isNull());
      // The opacities the configuration above gives each surface.
      constexpr qreal topbar_opacity = 0.2;
      constexpr qreal sidebar_opacity = 0.4;
      constexpr qreal bottombar_opacity = 0.6;
      constexpr qreal workspace_opacity = 0.8;
      constexpr qreal pane_opacity = 0.3;
      // Samples sit this far inside a surface's edge, clear of its border.
      constexpr qreal edge_inset = 2.0;
      const auto verify = [&](QPointF logical, double opacity) {
        const auto position = (logical * window_->devicePixelRatio()).toPoint();
        const auto actual = frame.pixelColor(position).alphaF();

        QVERIFY2(std::abs(actual - opacity) <= 1.0 / 255, qPrintable(QStringLiteral("At %1,%2: alpha %3, expected %4").arg(logical.x()).arg(logical.y()).arg(actual).arg(opacity)));
      };

      verify({window_->width() - edge_inset, navigation.bottom() - edge_inset}, topbar_opacity);
      verify({sidebar.right() - edge_inset, sidebar.bottom() - edge_inset}, sidebar_opacity);
      verify({window_->width() - edge_inset, status.bottom() - edge_inset}, bottombar_opacity);
      // The sidebar runs the full height and the bottom bar starts at its right edge,
      // so the workspace shows just above the bottom bar.
      verify({sidebar.right() + 4, status.top() - edge_inset}, workspace_opacity);
      const auto backgrounds = test::visualItems(*window_->contentItem(), QStringLiteral("paneTerminalBackground"));

      QVERIFY(!backgrounds.isEmpty());
      for (const auto* background : backgrounds) {
        verify(background->mapToScene({background->width() - edge_inset, background->height() - edge_inset}), pane_opacity);
      }

      captureArtifact(QStringLiteral("chrome-independent-opacity"));
    }

    Q_SLOT void appearanceChangesPreserveInputAndLayout() {
      const telar::gui::test::AppearanceFixture appearance;
      const QTemporaryDir directory;
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, "return {api_version=2,theme='terminal',gui={window={background_opacity=0.75}},client={prefix='ctrl+a',appearance={light={colors={text='#010203',accent='#040506',panel_bg='#070809'}}},keybindings={telar.bind({'s'},telar.action.toggle_sidebar())}}}");
      const auto restore = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      client_->loadConfiguration(path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      telar::gui::test::AppearanceFixture::set(Qt::ColorScheme::Unknown);
      auto* terminal = terminalIn(window_->contentItem());

      QVERIFY(terminal != nullptr);
      terminal->forceActiveFocus();
      constexpr qreal retained_width = 317;

      client_->display()->setSidebarWidth(retained_width);
      const auto before_width = client_->display()->sidebarWidth();
      const auto visible = client_->display()->sidebarVisible();
      const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;

      QTest::keyClick(window_, Qt::Key_A, control);
      telar::gui::test::AppearanceFixture::set(Qt::ColorScheme::Light);
      const QColor light_text{1, 2, 3};

      QCOMPARE(client_->colors().value(QStringLiteral("foreground")).value<QColor>(), light_text);
      constexpr auto panel_rgb = 0x070809;

      QCOMPARE(client_->colors().value(QStringLiteral("panelBackground")).value<QColor>(), QColor{Qt::transparent});
      QCOMPARE(client_->colors().value(QStringLiteral("panel_bg")).value<QColor>(), QColor::fromRgb(panel_rgb));
      QCOMPARE(client_->display()->sidebarWidth(), before_width);
      QTest::keyClick(window_, Qt::Key_S);
      QCOMPARE(client_->display()->sidebarVisible(), !visible);
      telar::gui::test::AppearanceFixture::set(Qt::ColorScheme::Dark);
      QCOMPARE(client_->display()->sidebarVisible(), !visible);
      QCOMPARE(client_->display()->sidebarWidth(), before_width);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void sidebarLayoutLeavesTheConfigurationAlone() {
      const auto visible = client_->display()->sidebarVisible();
      const auto width = client_->display()->sidebarWidth();
      const auto collapsed = client_->display()->workspaceListCollapsed();
      const auto restore = qScopeGuard([this, visible, width, collapsed] {
        if (client_->display()->sidebarVisible() != visible) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }

        if (client_->display()->workspaceListCollapsed() != collapsed) {
          client_->commands()->execute(window_actions::Action::toggle_workspace_list);
        }

        client_->display()->setSidebarWidth(width);
      });

      if (!visible) {
        client_->commands()->execute(window_actions::Action::toggle_sidebar);
      }

      // The fonts, the theme and the mods stay; only what is laid out around the sidebar moves.
      const QSignalSpy configuration{client_.get(), &ApplicationController::configurationChanged};
      const QSignalSpy sidebar{client_->display(), &WindowDisplay::changed};
      const auto terminal = [this] {
        return client_->display()->geometry().value(QStringLiteral("terminal")).toRectF().width();
      };

      const auto terminal_width = terminal();
      constexpr qreal widened = 40;

      client_->display()->setSidebarWidth(client_->display()->sidebarWidth() + widened);
      QVERIFY(terminal() < terminal_width);
      client_->commands()->execute(window_actions::Action::toggle_workspace_list);
      QCOMPARE(client_->display()->workspaceListCollapsed(), !collapsed);
      client_->commands()->execute(window_actions::Action::toggle_sidebar);
      QVERIFY(!client_->display()->sidebarVisible());
      QVERIFY(terminal() > terminal_width);
      QVERIFY(sidebar.count() >= 3);
      QCOMPARE(configuration.count(), 0);
    }

    Q_SLOT void newTabsRecoverTheFullGridAfterNestedSplits() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const TabRestorePoint before{.count = client_->tabs()->rows()->rowCount(), .pane_id = firstPane()->id};
      const auto restore = qScopeGuard([this, before] {
        closeExtraTabs(before.count);
      });

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), before.count + 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != before.pane_id, runtime_wait_ms);
      const auto bounds = client_->display()->geometry().value(QStringLiteral("terminal")).toRectF();
      const auto resolved = client_->resolveFont(window_->devicePixelRatio());
      const TerminalGrid grid{.cell_width_px = resolved.grid.width, .cell_height_px = resolved.grid.height, .scale = window_->devicePixelRatio()};
      const auto full = grid.fit(bounds.width(), bounds.height());

      QVERIFY(full.hasValue());
      constexpr std::uint16_t border_cells = 2;
      const auto header_cells = static_cast<std::uint16_t>(std::ceil(ChromeMetrics::logical_pane_header * window_->devicePixelRatio() / resolved.grid.height));
      const auto vertical_chrome = header_cells + 1;
      const auto single_columns = full->cols - border_cells;
      const auto single_rows = full->rows - vertical_chrome;

      QTRY_COMPARE_WITH_TIMEOUT(firstPane()->screen.columns(), single_columns, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(firstPane()->screen.rows(), single_rows, runtime_wait_ms);
      const auto source_id = firstPane()->id;

      client_->commands()->execute(window_actions::Action::split_horizontal);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      const auto gutter = static_cast<std::uint16_t>(client_->configuration().pane_gaps);
      const auto first_outer_columns = (full->cols - gutter) / 2;
      const auto second_outer_columns = full->cols - gutter - first_outer_columns;

      QTRY_COMPARE_WITH_TIMEOUT(client_->pane(source_id)->screen.columns(), first_outer_columns - border_cells, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->pane(source_id)->screen.rows(), full->rows - vertical_chrome, runtime_wait_ms);
      const auto second_record = client_->panes()->rows()->data(client_->panes()->rows()->index(1, 0), ListModel::record_role).toMap();
      const auto second_id = second_record.value(QStringLiteral("key")).toString().toULongLong();

      QTRY_COMPARE_WITH_TIMEOUT(client_->pane(second_id)->screen.columns(), second_outer_columns - border_cells, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->pane(second_id)->screen.rows(), full->rows - vertical_chrome, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::split_vertical);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 3, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), before.count + 2, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != source_id, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(firstPane()->screen.columns(), single_columns, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(firstPane()->screen.rows(), single_rows, runtime_wait_ms);
      const auto expected = QStringLiteral("GUI_WORKBENCH_SIZE %1 %2").arg(single_rows).arg(single_columns);

      client_->terminals()->input(firstPane()->id, "printf 'GUI_WORKBENCH_SIZE '; stty size\r");
      QTRY_VERIFY2_WITH_TIMEOUT(screenText(firstPane()->screen).contains(expected), qPrintable(screenText(firstPane()->screen)), runtime_wait_ms);
      QCOMPARE(firstPane()->size.cell_width_px, full->cell_width_px);
      QCOMPARE(firstPane()->size.cell_height_px, full->cell_height_px);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void zoomCapsuleSwitchesHiddenPanesAndRestoresTiling() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const TabRestorePoint before{.count = client_->tabs()->rows()->rowCount(), .pane_id = firstPane()->id};
      const auto restore = qScopeGuard([this, before] {
        closeTemporaryTab(before);
      });

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), before.count + 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto source_id = firstPane()->id;

      client_->commands()->execute(window_actions::Action::split_horizontal);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::fullscreen);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 1, runtime_wait_ms);
      const auto entries = [&] {
        return telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("fullscreenPaneEntry"));
      };

      QTRY_COMPARE_WITH_TIMEOUT(entries().size(), 2, runtime_wait_ms);
      const QQuickItem* hidden = nullptr;

      for (const auto* entry : entries()) {
        const auto data = entry->property("entry").toMap();
        if (data.value(QStringLiteral("key")).toString() == QString::number(source_id)) {
          QVERIFY(!data.value(QStringLiteral("focused")).toBool());
          hidden = entry;
        }
      }

      if (hidden == nullptr) {
        QFAIL("Required hidden pane entry is missing");
      }

      QVERIFY(hidden->isVisible());
      const auto* terminal = terminalIn(window_->contentItem());
      if (terminal == nullptr) {
        QFAIL("Required terminal fixture is missing");
      }

      // The selectors live in the pane's header, above its content.
      QVERIFY(hidden->mapToScene({0, hidden->height()}).y() <= terminal->mapToScene({0, 0}).y());
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, hidden->mapToScene({hidden->width() / 2, hidden->height() / 2}).toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(firstPane()->id, source_id, runtime_wait_ms);
      QCOMPARE(client_->panes()->rows()->rowCount(), 1);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && entries().size() == 2, runtime_wait_ms);
      const auto leave = [&] -> const QQuickItem* {
        for (const auto* action : telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("paneAction"))) {
          if (action->isVisible() && action->property("modelData").toMap().value(QStringLiteral("label")).toString() == QLatin1StringView("Restore panes")) {
            return action;
          }
        }

        return nullptr;
      };

      QTRY_VERIFY_WITH_TIMEOUT(leave() != nullptr, runtime_wait_ms);
      const auto* button = leave();

      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, button->mapToScene({button->width() / 2, button->height() / 2}).toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(entries().isEmpty(), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    // Reports `title` for the agent in pane `pane_id` through the runtime's command line.
    void reportAgentTitle(std::uint64_t pane_id, const QString& title) {
      QProcess title_report;

      title_report.start(runtime_.program(), {QStringLiteral("agent"), QStringLiteral("report-title"), QString::number(pane_id), title, QStringLiteral("--socket"), socket_});
      QVERIFY(title_report.waitForFinished(runtime_wait_ms));
      QCOMPARE(title_report.exitCode(), 0);
    }

    Q_SLOT void attentionRingsFollowUnfocusedAttachedPanes() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const TabRestorePoint before{.count = client_->tabs()->rows()->rowCount(), .pane_id = firstPane()->id};
      const auto original_window_size = window_->size();
      const auto restore = qScopeGuard([this, before, original_window_size] {
        window_->resize(original_window_size);
        closeTemporaryTab(before);
      });

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), before.count + 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != before.pane_id, runtime_wait_ms);
      const auto source_id = firstPane()->id;
      const telar::gui::features::workbench::PaneAttentionKey attachment{.pane_id = source_id, .attachment_generation = firstPane()->attachment_generation};
      const QPointer<TerminalItem> source_terminal{terminalIn(window_->contentItem())};

      QVERIFY(source_terminal != nullptr);
      client_->commands()->execute(window_actions::Action::split_horizontal);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      const QPointer<TerminalItem> other_terminal{focusedTerminalBeside(*window_, *source_terminal)};

      QVERIFY(other_terminal != nullptr);
      const auto other_id = other_terminal->paneIdentity();
      const auto report = QStringLiteral("stty -echo; %1 --report-blocked %2 %3 %4\r").arg(shellLiteral(QCoreApplication::applicationFilePath()), shellLiteral(socket_)).arg(source_id).arg(firstPane()->generation);

      client_->terminals()->input(source_id, report.toUtf8());
      QTRY_VERIFY2_WITH_TIMEOUT(screenText(client_->pane(source_id)->screen, ScreenTextLayout::logical).contains(QStringLiteral("GUI_ATTENTION_READY")), qPrintable(screenText(client_->pane(source_id)->screen)), runtime_wait_ms);
      reportAgentTitle(source_id, QStringLiteral("Visual state check"));
      QVERIFY(!QTest::currentTestFailed());
      // The header names the program and, beside it, what the agent reports.
      const auto captions = test::visualItems(*source_terminal->parentItem()->parentItem(), QStringLiteral("paneProgram"));
      const auto contexts = test::visualItems(*source_terminal->parentItem()->parentItem(), QStringLiteral("paneContext"));

      QCOMPARE(captions.size(), 1);
      QCOMPARE(contexts.size(), 1);
      QTRY_COMPARE_WITH_TIMEOUT(captions.front()->property("text").toString(), QStringLiteral("gui-quick-test"), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(contexts.front()->property("text").toString(), QStringLiteral("Visual state check"), runtime_wait_ms);
      const auto rings = [&] {
        return telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("paneAttentionRing"));
      };

      QTRY_VERIFY2_WITH_TIMEOUT(rings().size() == 1, qPrintable(screenText(client_->pane(source_id)->screen)), runtime_wait_ms);
      QCOMPARE(telar::gui::qt::paneAttentionKey(rings().front()->property("attachment")).valueOr(telar::gui::features::workbench::PaneAttentionKey{}), attachment);
      QTRY_COMPARE_WITH_TIMEOUT(rings().front()->property("alpha").toDouble(), 1, runtime_wait_ms);
      captureArtifact(QStringLiteral("chrome-attention"));
      const QPointer<QQuickItem> retired{rings().front()};

      client_->commands()->execute(window_actions::Action::focus_pane, QString::number(source_id));
      QTRY_VERIFY_WITH_TIMEOUT(source_terminal->hasActiveFocus(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(rings().isEmpty() && retired.isNull(), runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      captureArtifact(QStringLiteral("question-focused"));
      client_->commands()->execute(window_actions::Action::focus_pane, QString::number(other_id));
      QTRY_COMPARE_WITH_TIMEOUT(rings().size(), 1, runtime_wait_ms);
      QCOMPARE(telar::gui::qt::paneAttentionKey(rings().front()->property("attachment")).valueOr(telar::gui::features::workbench::PaneAttentionKey{}), attachment);

      QTRY_COMPARE_WITH_TIMEOUT(rings().front()->property("alpha").toDouble(), 1, runtime_wait_ms);
      captureArtifact(QStringLiteral("question-unfocused"));
      // The header words no state: the tile carries it as a dot in the state's color.
      const auto states = test::visualItems(*source_terminal->parentItem()->parentItem(), QStringLiteral("applicationStatus"));

      QCOMPARE(states.size(), 1);
      QCOMPARE(states.front()->parentItem()->property("statusColor").toString(), QStringLiteral("yellow"));
      client_->terminals()->input(source_id, "ready\r");
      QTRY_COMPARE_WITH_TIMEOUT(states.front()->parentItem()->property("statusColor").toString(), QStringLiteral("green"), runtime_wait_ms);
      QCOMPARE(contexts.front()->property("text").toString(), QStringLiteral("Visual state check"));
      QTRY_VERIFY_WITH_TIMEOUT(rings().isEmpty(), runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      captureArtifact(QStringLiteral("ready-unfocused"));
      client_->commands()->execute(window_actions::Action::focus_pane, QString::number(source_id));
      QTRY_VERIFY_WITH_TIMEOUT(source_terminal->hasActiveFocus(), runtime_wait_ms);
      captureArtifact(QStringLiteral("ready-focused"));
      constexpr int wide_window_width = 1600;

      window_->resize(wide_window_width, original_window_size.height());
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QVERIFY(source_terminal != nullptr && other_terminal != nullptr);
      captureArtifact(QStringLiteral("ready-focused-wide"));
      client_->commands()->execute(window_actions::Action::focus_pane, QString::number(other_id));
      QTRY_VERIFY_WITH_TIMEOUT(other_terminal->hasActiveFocus(), runtime_wait_ms);
      captureArtifact(QStringLiteral("ready-unfocused-wide"));
      client_->terminals()->input(source_id, "question\r");
      QTRY_COMPARE_WITH_TIMEOUT(states.front()->parentItem()->property("statusColor").toString(), QStringLiteral("yellow"), runtime_wait_ms);
      QCOMPARE(contexts.front()->property("text").toString(), QStringLiteral("Visual state check"));
      QTRY_COMPARE_WITH_TIMEOUT(rings().size(), 1, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(rings().front()->property("alpha").toDouble(), 1, runtime_wait_ms);
      captureArtifact(QStringLiteral("question-unfocused-wide"));
      client_->commands()->execute(window_actions::Action::focus_pane, QString::number(source_id));
      QTRY_VERIFY_WITH_TIMEOUT(source_terminal->hasActiveFocus() && rings().isEmpty(), runtime_wait_ms);
      captureArtifact(QStringLiteral("question-focused-wide"));
      client_->commands()->execute(window_actions::Action::focus_pane, QString::number(other_id));
      QTRY_VERIFY_WITH_TIMEOUT(other_terminal->hasActiveFocus(), runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::fullscreen);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(rings().isEmpty(), runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::fullscreen);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(rings().size(), 1, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void configuredCommandsOpenAndCloseTheirOwnTabs() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const TabRestorePoint before{.count = client_->tabs()->rows()->rowCount(), .pane_id = firstPane()->id};
      const QTemporaryDir directory;
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, R"(
      local function command(marker,label,argument)
        return telar.action.command_tab{label=label,command={'/bin/sh','-c',
          [[printf 'GUI_COMMAND_%s:%s:%s\n' "$2" "$PWD" "$1"; IFS= read -r line]],
          'telar-command',argument,marker}}
      end
      local n=0
      return {api_version=2,client={keybindings={
        telar.bind_global({'alt+s'},command('STATIC','command-static','quoted "中" $HOME $(printf IGNORED)')),
        telar.bind_global({'alt+c'},function()
          n=n+1;return {command('CALLBACK','command-callback','callback '..n),telar.action.toggle_sidebar()}
        end)}}}
    )");
      const auto restore = qScopeGuard([this, before] {
        client_->loadConfiguration({}, {}, {});
        client_->roster()->configureLaunch(directory_.path(), {QStringLiteral("/bin/sh")}, true);
        closeExtraTabs(before.count);
      });

      client_->loadConfiguration(path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), before.count + 1, runtime_wait_ms);
      QTRY_VERIFY2_WITH_TIMEOUT(terminalReady() && firstPane()->id != before.pane_id, qPrintable(QStringLiteral("pane=%1 before=%2 tabs=%3 error=%4").arg(firstPane() == nullptr ? 0 : firstPane()->id).arg(before.pane_id).arg(client_->tabs()->rows()->rowCount()).arg(client_->status()->error())), runtime_wait_ms);
      QTRY_VERIFY2_WITH_TIMEOUT(!firstPane()->cwd.empty(), qPrintable(QStringLiteral("pane=%1 frame=%2 attached=%3 error=%4").arg(firstPane()->id).arg(firstPane()->screen.frameId()).arg(firstPane()->attached).arg(client_->status()->error())), runtime_wait_ms);
      const auto source_id = firstPane()->id;
      const auto source_directory = toQString(firstPane()->cwd);
      const auto count = client_->tabs()->rows()->rowCount();
      const QTemporaryDir fallback;

      client_->roster()->configureLaunch(fallback.path(), {QStringLiteral("/bin/sh")}, true);

      struct CommandCase {
        Qt::Key key;
        const char* label;
        const char* marker;
        const char* argument;
      };

      constexpr auto cases = telar::ds::Array<CommandCase, 3>{
          {
              {.key = Qt::Key_S, .label = "command-static", .marker = "STATIC", .argument = "quoted \"中\" $HOME $(printf IGNORED)"},
              {.key = Qt::Key_C, .label = "command-callback", .marker = "CALLBACK", .argument = "callback 1"},
              {.key = Qt::Key_C, .label = "command-callback", .marker = "CALLBACK", .argument = "callback 2"},
          },
      };

      for (const auto& command : cases) {
        auto* terminal = terminalIn(window_->contentItem());

        QVERIFY(terminal != nullptr);
        terminal->forceActiveFocus();
        // macOS hands an Option dead key to the input method unless the focus item refuses it.
        QVERIFY(terminal->inputMethodQuery(Qt::ImEnabled).toBool());
        QKeyEvent override{QEvent::ShortcutOverride, command.key, Qt::AltModifier, QString{}};

        QCoreApplication::sendEvent(window_, &override);
        QVERIFY(override.isAccepted());
        QVERIFY(!terminal->inputMethodQuery(Qt::ImEnabled).toBool());
        const QPointer guarded{terminal};

        QTest::keyPress(window_, command.key, Qt::AltModifier);
        QVERIFY(guarded.isNull() || guarded->inputMethodQuery(Qt::ImEnabled).toBool());
        QTest::keyRelease(window_, command.key, Qt::AltModifier);
        QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), count + 1, runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != source_id, runtime_wait_ms);
        const auto expected = QStringLiteral("GUI_COMMAND_%1:%2:%3").arg(QString::fromUtf8(command.marker), source_directory, QString::fromUtf8(command.argument));

        QTRY_VERIFY2_WITH_TIMEOUT(screenText(firstPane()->screen).remove(QLatin1Char('\n')).contains(expected), qPrintable(screenText(firstPane()->screen)), runtime_wait_ms);
        const auto tab = client_->tabs()->rows()->data(client_->tabs()->rows()->index(count, 0), ListModel::record_role).toMap();

        QCOMPARE(tab.value(QStringLiteral("label")).toString(), QString::fromUtf8(command.label));
        client_->terminals()->input(firstPane()->id, "quit\r");
        QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), count, runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == source_id, runtime_wait_ms);
      }

      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void routedPluginOverrides() {
      const auto cleanup = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      client_->loadConfiguration({}, {}, {});
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      std::uint64_t next_request = 2;
      const auto request = [&](telar::ClientAction action, std::string_view text) {
        const auto id = next_request++;

        peer.request(action, id, text);

        return id;
      };

      auto id = request(telar::ClientAction::plugin_disable, "example");

      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, id, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("ConfigurationNotLoaded"));
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      QVERIFY(QDir{directory.path()}.mkdir(QStringLiteral("example")));
      writeTestFile(directory.filePath(QStringLiteral("example/plugin.json")), R"({"api_version":1,"id":"sample","version":"1","entry":"main.lua","source":{"url":"fixture","revision":"1"},"actions":["run"],"capabilities":[]})");
      writeTestFile(directory.filePath(QStringLiteral("example/main.lua")), "return {actions={run=function() return nil end}}");
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = "return {api_version=2,plugins={{path='example'}},client={keybindings={telar.bind({'x'},{kind='plugin',plugin='sample',action='run'}),telar.bind({'y'},'toggle-sidebar')}}}";

      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {}, directory.filePath(QStringLiteral("trust.json")));
      QCOMPARE(client_->status()->error(), QString{});
      QString metadata;
      const auto wait_enabled = [&](bool expected) {
        telar::ds::Option<std::uint64_t> pending;

        return QTest::qWaitFor([&] {
          if (!pending) {
            pending = request(telar::ClientAction::plugin_get, "example");

            return false;
          }

          if (peer.result().request_id != *pending) {
            return false;
          }

          pending.reset();
          if (peer.result().status != telar::ClientCommandStatus::applied) {
            return false;
          }

          metadata = peer.result().text;
          const auto text = metadata.toUtf8();
          const auto root = telar::runtime::JsonValue::parse({text.constData(), static_cast<std::size_t>(text.size())});
          bool matched = false;

          test::requiredJsonField(root, "entries").eachElement([&](const telar::runtime::JsonValue& entry) {
            matched = test::requiredJsonField(entry, "enabled").boolean() == expected && test::requiredJsonField(entry, "requested_enabled").boolean() == expected;
          });

          return matched;
        },
            runtime_wait_ms);
      };

      QVERIFY2(wait_enabled(true), qPrintable(metadata));
      id = request(telar::ClientAction::plugin_disable, "sample");
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, id, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QVERIFY2(wait_enabled(false), qPrintable(metadata));
      id = request(telar::ClientAction::plugin_enable, "sample");
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, id, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("PluginNotConfigured"));
      id = request(telar::ClientAction::plugin_enable, "example");
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, id, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QVERIFY2(wait_enabled(true), qPrintable(metadata));
      QFile retained{path};

      QVERIFY(retained.open(QIODevice::ReadOnly));
      QCOMPARE(retained.readAll(), QByteArray{configuration});
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void routedPluginWorker() {
      const auto program = QStandardPaths::findExecutable(QString::fromUtf8(system::runtime_endpoint::program().view()));

      QVERIFY(!program.isEmpty());
      QCOMPARE(QFileInfo{program}.canonicalFilePath(), QFileInfo{qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME")}.canonicalFilePath());
      const auto cleanup = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      QVERIFY(QDir{directory.path()}.mkdir(QStringLiteral("example")));
      const auto package = directory.filePath(QStringLiteral("example"));

      writeTestFile(package + QStringLiteral("/plugin.json"), R"({"api_version":1,"id":"sample","version":"1","entry":"main.lua","source":{"url":"fixture","revision":"1"},"actions":["toggle","denied"],"capabilities":["runtime.control"]})");
      writeTestFile(package + QStringLiteral("/main.lua"), "local t=require('telar');return {actions={toggle=function()return t.action.toggle_sidebar()end,denied=function()return {t.action.toggle_sidebar(),t.action.new_tab()}end}}");
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = "return {api_version=2,plugins={{path='example'}},client={keybindings={telar.bind_global({'alt+s'},telar.action.plugin{plugin='sample',action='toggle'}),telar.bind_global({'alt+c'},function() return telar.action.plugin{plugin='sample',action='toggle'} end)}}}";

      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {}, directory.filePath(QStringLiteral("trust.json")));
      QCOMPARE(client_->status()->error(), QString{});
      QTRY_VERIFY_WITH_TIMEOUT(client_->display()->sidebarVisible(), runtime_wait_ms);
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      enum class Request : std::uint16_t {
        toggle = 20'000,
        denied,
      };

      const auto toggle_request = static_cast<std::uint64_t>(Request::toggle);

      peer.request(telar::ClientCommand{.request_id = toggle_request, .action = telar::ClientAction::plugin_run, .target_id = telar::runtime::plugins::stableId("toggle"), .text = "sample"});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, toggle_request, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QTRY_VERIFY2_WITH_TIMEOUT(!client_->display()->sidebarVisible(), qPrintable(client_->status()->error()), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});

      const auto tabs = client_->tabs()->rows()->rowCount();
      const auto denied_request = static_cast<std::uint64_t>(Request::denied);

      peer.request(telar::ClientCommand{.request_id = denied_request, .action = telar::ClientAction::plugin_run, .target_id = telar::runtime::plugins::stableId("denied"), .text = "example"});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, denied_request, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QTRY_COMPARE_WITH_TIMEOUT(client_->status()->error(), QStringLiteral("CapabilityNotGranted"), runtime_wait_ms);
      QVERIFY(!client_->display()->sidebarVisible());
      QCOMPARE(client_->tabs()->rows()->rowCount(), tabs);

      QTest::keyClick(window_, Qt::Key_S, Qt::AltModifier);
      QTRY_VERIFY2_WITH_TIMEOUT(client_->display()->sidebarVisible(), qPrintable(client_->status()->error()), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->status()->error(), QString{}, runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_C, Qt::AltModifier);
      QTRY_VERIFY2_WITH_TIMEOUT(!client_->display()->sidebarVisible(), qPrintable(client_->status()->error()), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_S, Qt::AltModifier);
      QTRY_VERIFY2_WITH_TIMEOUT(client_->display()->sidebarVisible(), qPrintable(client_->status()->error()), runtime_wait_ms);
      verifyReloadWhilePluginPoolBusy(peer, denied_request + 1, path, directory.filePath(QStringLiteral("trust.json")));
      QVERIFY(!QTest::currentTestFailed());
      auto barrier_request = denied_request + 1;

      QTRY_VERIFY_WITH_TIMEOUT(([&] {
        if (peer.result().request_id != barrier_request) {
          return false;
        }
        if (peer.result().status == telar::ClientCommandStatus::admitted && barrier_request > denied_request + 1) {
          return true;
        }
        peer.request(telar::ClientCommand{.request_id = ++barrier_request, .action = telar::ClientAction::plugin_run, .target_id = telar::runtime::plugins::stableId("denied"), .text = "sample"});
        return false;
      })(),
          runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->status()->error(), QStringLiteral("CapabilityNotGranted"), runtime_wait_ms);
      QVERIFY(client_->display()->sidebarVisible());
      QCOMPARE(client_->tabs()->rows()->rowCount(), tabs);
      QFile retained{path};

      QVERIFY(retained.open(QIODevice::ReadOnly));
      QCOMPARE(retained.readAll(), QByteArray{configuration});
    }

    // A toggle admitted while the plugin worker's pool is busy, then a reload, leaves the reload
    // clean and the sidebar as it was.
    void verifyReloadWhilePluginPoolBusy(CommandPeer& peer, std::uint64_t stale_request, const QString& path, const QString& trust) {
      auto& pool = *QThreadPool::globalInstance();
      const int previous_threads = pool.maxThreadCount();

      pool.setMaxThreadCount(1);
      QSemaphore started;
      QSemaphore resume;
      const auto restore_pool = qScopeGuard([&] {
        resume.release();
        pool.waitForDone();
        pool.setMaxThreadCount(previous_threads);
      });

      pool.start([&] {
        started.release();
        resume.acquire();
      });

      started.acquire();
      peer.request(telar::ClientCommand{.request_id = stale_request, .action = telar::ClientAction::plugin_run, .target_id = telar::runtime::plugins::stableId("toggle"), .text = "sample"});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, stale_request, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      client_->loadConfiguration(path, {}, {}, trust);
      QCOMPARE(client_->status()->error(), QString{});
      QVERIFY(client_->display()->sidebarVisible());
    }

    Q_SLOT void configuredBarsAndPanels() {
      const auto cleanup = qScopeGuard([this] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
      });

      QVERIFY(!application::terminal::links::LinkTarget::fromUri("https://").hasValue());
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = R"(
      local t = require('telar')
      local ui = t.ui
      return {api_version=2,client={
        keybindings={t.bind_global({'alt+u'},t.action.open_panel('usage'))},
        bars={bottom={
          left=t.bar.static(ui.group({on_click=t.action.open_panel('usage'),tooltip=ui.text('Details'),ui.label('Daily λ'),ui.badge({text='C++'}),ui.mark('telar')})),
          center=t.bar.tabs(),
          right=t.bar.command({command={'/usr/bin/printf','%s','á λ'},every_ms=60000}),
        },top={right=t.bar.dynamic({every_ms=60000,render=function(ctx) return ui.clock('%H:%M') end})}},
        panels={usage=t.panel({title='Usage',render=function(ctx) return {
          ui.heading('Usage λ'),ui.meter_row({label='Session',value=0.5}),
          ui.meter_row({label='Daily quota λ',detail='Resets tomorrow',value=0.75,marker=0.9}),
          ui.text(string.rep('Daily task details remain available. ',8)),
          ui.callout({text='Status λ',detail='Ready',icon='telar_mark',button=ui.button({text='Dismiss',action=t.action.close_panel(),url='https://'})}),
          ui.actions({ui.button({text='Close',action=t.action.close_panel()})}),
        } end})},
      }}
    )";

      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      const auto slot = [&](const char* name) {
        return client_->components()->bars().value(QString::fromLatin1(name)).toMap();
      };

      QTRY_COMPARE_WITH_TIMEOUT(slot("center").value(QStringLiteral("kind")).toString(), QStringLiteral("tabs"), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(slot("right").value(QStringLiteral("nodes")).toList().size(), 1, runtime_wait_ms);
      QCOMPARE(slot("right").value(QStringLiteral("nodes")).toList().first().toMap().value(QStringLiteral("text")).toString().toUtf8(), QByteArray::fromHex("c3a120cebb"));
      QCOMPARE(slot("right").value(QStringLiteral("error")).toString(), QString{});
      auto* motion = window_->findChild<ModalRevealLayout*>(QStringLiteral("componentPanelMotion"));

      QVERIFY(motion != nullptr);
      QList<qreal> entrance_samples;
      const QObject entrance_observer;

      QObject::connect(motion, &ModalRevealLayout::frameChanged, &entrance_observer, [&] {
        entrance_samples.append(motion->reveal());
      });

      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("nodes")).toList().size(), 8, runtime_wait_ms);
      const auto* popup = window_->findChild<QObject*>(QStringLiteral("configuredPanel"));

      QVERIFY(popup != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(popup->property("visible").toBool(), runtime_wait_ms);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("error")).toString(), QString{});
      QTRY_VERIFY_WITH_TIMEOUT(entrance_samples.size() > 1 && motion->reveal() == 1, runtime_wait_ms);
      QCOMPARE(entrance_samples.front(), qreal{0});
      QCOMPARE(entrance_samples.back(), qreal{1});
      QVERIFY(std::ranges::is_sorted(entrance_samples));
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      verifyComponentMeters();
      verifyConfiguredPanelText();
      QVERIFY(!QTest::currentTestFailed());
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      const auto left = slot("left");

      client_->components()->activate(left.value(QStringLiteral("source")).toInt(), 0, left.value(QStringLiteral("generation")).toString(), left.value(QStringLiteral("revision")).toString(), QPointF{});
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      client_->components()->activate(left.value(QStringLiteral("source")).toInt(), 0, left.value(QStringLiteral("generation")).toString(), left.value(QStringLiteral("revision")).toString(), QPointF{});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      // The panel opens empty; its nodes arrive when the Lua thread renders it.
      QTRY_VERIFY_WITH_TIMEOUT(componentItem(QStringLiteral("button"), QStringLiteral("Dismiss")) != nullptr, runtime_wait_ms);
      const auto* dismiss_action = componentItem(QStringLiteral("button"), QStringLiteral("Dismiss"));

      QVERIFY(dismiss_action != nullptr);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto action_center = dismiss_action->mapToScene(dismiss_action->boundingRect().center()).toPoint();

      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, action_center);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::history);
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::cancel);
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::none, runtime_wait_ms);
    }

    // The usage panel of configuredBarsAndPanels wraps its paragraph and centers the callout's
    // action in its card.
    void verifyConfiguredPanelText() const {
      const auto* paragraph = componentItem(QStringLiteral("text"));

      QVERIFY(paragraph != nullptr);
      const auto* paragraph_text = paragraph->findChild<QQuickItem*>(QStringLiteral("componentStyledText"));

      QVERIFY(paragraph_text != nullptr);
      QVERIFY(paragraph_text->property("lineCount").toInt() > 3);
      QVERIFY(!paragraph_text->property("truncated").toBool());
      const auto* callout = componentItem(QStringLiteral("callout"));
      const auto* dismiss = componentItem(QStringLiteral("button"), QStringLiteral("Dismiss"));

      QVERIFY(callout != nullptr && dismiss != nullptr);
      const auto card_bounds = callout->mapRectToScene(callout->boundingRect());
      const auto action_bounds = dismiss->mapRectToScene(dismiss->boundingRect());

      QVERIFY(callout->height() >= callout->implicitHeight());
      QVERIFY(card_bounds.contains(action_bounds));
      QCOMPARE(action_bounds.center().y(), card_bounds.center().y());
      const auto frame = window_->grabWindow();

      QVERIFY(!frame.isNull());
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_COMPONENT_SCREENSHOT");
      if (!screenshot.isEmpty()) {
        QVERIFY(frame.save(screenshot, "PNG"));
      }
    }

    Q_SLOT void configuredTooltipsYieldToOpenSurfaces() {
      const auto cleanup = qScopeGuard([this] {
        client_->components()->closePick();
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, R"(
      local t=require('telar');local ui=t.ui
      return {api_version=2,client={
        bars={bottom={
          left=t.bar.static(ui.group({on_click=t.action.open_panel('usage'),tooltip=ui.text('Bar details'),ui.label('Bar panel')})),
          center=t.bar.tabs(),
          right=t.bar.static(ui.group({on_click=t.action.pick('mode'),tooltip=ui.text('Pick details'),ui.label('Bar pick')})),
        }},
        panels={usage=t.panel({title='Usage',render=function()
          return {ui.group({on_click=t.action.toggle_sidebar(),tooltip=ui.text('Panel details'),ui.label('Panel action')}),ui.text('Plain text')}
        end})},
        picks={mode=t.pick({items={'first'},on_select={'/usr/bin/true','{}'}})},
      }}
    )");
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTRY_VERIFY_WITH_TIMEOUT(componentGroup(QStringLiteral("Bar panel")) != nullptr, runtime_wait_ms);
      // The bar lays its groups out a frame after they appear. Pointing earlier hovers one spot and
      // clicks another, so Qt delivers the press right after a synthesized move and the open
      // tooltip loses it.
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* panel_button = componentGroup(QStringLiteral("Bar panel"));
      const auto* pick_button = componentGroup(QStringLiteral("Bar pick"));

      QVERIFY(pick_button != nullptr);
      const auto* panel_tooltip = componentTooltip(*panel_button);
      const auto* pick_tooltip = componentTooltip(*pick_button);

      QVERIFY(panel_tooltip != nullptr && pick_tooltip != nullptr);
      const auto center = [](const QQuickItem& item) {
        return item.mapRectToScene(item.boundingRect()).center().toPoint();
      };

      QTest::mouseMove(window_, center(*panel_button));
      QTRY_VERIFY_WITH_TIMEOUT(panel_tooltip->property("visible").toBool(), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(window_->cursor().shape(), Qt::PointingHandCursor, runtime_wait_ms);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, center(*panel_button));
      QTRY_VERIFY_WITH_TIMEOUT(componentGroup(QStringLiteral("Panel action")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QVERIFY(!panel_tooltip->property("visible").toBool());

      client_->components()->refreshPanel();
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QVERIFY(!panel_tooltip->property("visible").toBool());

      const auto* panel_action = componentGroup(QStringLiteral("Panel action"));
      const auto* own_tooltip = componentTooltip(*panel_action);

      QVERIFY(own_tooltip != nullptr);
      QTest::mouseMove(window_, center(*panel_action));
      QTRY_VERIFY_WITH_TIMEOUT(own_tooltip->property("visible").toBool(), runtime_wait_ms);

      const auto* plain_text = componentItem(QStringLiteral("text"), QStringLiteral("Plain text"));

      QVERIFY(plain_text != nullptr);
      QTest::mouseMove(window_, center(*plain_text));
      QTRY_COMPARE_WITH_TIMEOUT(window_->cursor().shape(), Qt::ArrowCursor, runtime_wait_ms);

      QTest::mouseMove(window_, center(*panel_button));
      QTRY_VERIFY_WITH_TIMEOUT(!own_tooltip->property("visible").toBool(), runtime_wait_ms);
      QVERIFY(!panel_tooltip->property("visible").toBool());

      client_->components()->closePanel();
      QTRY_VERIFY_WITH_TIMEOUT(panel_tooltip->property("visible").toBool(), runtime_wait_ms);

      QTest::mouseMove(window_, center(*pick_button));
      QTRY_VERIFY_WITH_TIMEOUT(pick_tooltip->property("visible").toBool(), runtime_wait_ms);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, center(*pick_button));
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->pick().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!pick_tooltip->property("visible").toBool(), runtime_wait_ms);

      QTRY_VERIFY_WITH_TIMEOUT(configuredPickRowArea() != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QTest::mouseMove(window_, center(*configuredPickRowArea()));
      QTRY_COMPARE_WITH_TIMEOUT(window_->cursor().shape(), Qt::PointingHandCursor, runtime_wait_ms);
    }

    // The mouse area of the open pick's first visible row.
    [[nodiscard]] QQuickItem* configuredPickRowArea() const {
      auto* rows = window_->findChild<QQuickItem*>(QStringLiteral("configuredPickRows"));
      if (rows == nullptr) {
        return nullptr;
      }

      for (auto* item : test::visualItems(*rows, QString{})) {
        if (item->inherits("QQuickMouseArea") && item->isVisible() && item->width() > 0) {
          return item;
        }
      }

      return nullptr;
    }

    Q_SLOT void configuredPanelKeyboardActions() {
      const auto sidebar = client_->display()->sidebarVisible();
      const auto cleanup = qScopeGuard([this, sidebar] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->sidebarVisible() != sidebar) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = R"(
      local t=require('telar')
      local ui=t.ui
      return {api_version=2,client={
        keybindings={t.bind_global({'alt+u'},t.action.open_panel('usage'))},
        panels={usage=t.panel({title='Keyboard actions',render=function() return ui.actions({
          ui.button({text='Toggle sidebar',action=t.action.toggle_sidebar()}),
          ui.button({text='Close with keyboard',action=t.action.close_panel()}),
          ui.button({text='Choose mode',action=t.action.pick('mode')}),
        }) end})},
        picks={mode=t.pick({items={'first'},on_select={'/usr/bin/true','{}'}})},
      }}
    )";

      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("error")).toString().isEmpty() || componentItem(QStringLiteral("button"), QStringLiteral("Toggle sidebar")) != nullptr, runtime_wait_ms);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("error")).toString(), QString{});
      QTRY_COMPARE_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("nodes")).toList().size(), 4, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      auto* close = componentPanelCloseButton();

      QVERIFY(close != nullptr);
      close->forceActiveFocus(Qt::TabFocusReason);
      QTRY_VERIFY_WITH_TIMEOUT(close->hasActiveFocus(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_VERIFY_WITH_TIMEOUT(componentButtonFocused(QStringLiteral("Toggle sidebar")), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Space, Qt::ShiftModifier);
      QCOMPARE(client_->display()->sidebarVisible(), sidebar);
      auto* action = window_->activeFocusItem();

      QVERIFY(action != nullptr && action->property("interactive").isValid());
      QVERIFY(action->setProperty("interactive", false));
      QTest::keyClick(window_, Qt::Key_Space);
      QCOMPARE(client_->display()->sidebarVisible(), sidebar);
      QVERIFY(action->setProperty("interactive", true));
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_PANEL_KEYBOARD_SCREENSHOT");
      if (!screenshot.isEmpty()) {
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        QVERIFY(window_->grabWindow().save(screenshot, "PNG"));
      }

      QTest::keyPress(window_, Qt::Key_Space);
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), !sidebar, runtime_wait_ms);
      QKeyEvent repeated{QEvent::KeyPress, Qt::Key_Space, Qt::NoModifier, QStringLiteral(" "), true};

      QCoreApplication::sendEvent(window_, &repeated);
      QCOMPARE(client_->display()->sidebarVisible(), !sidebar);
      QTest::keyRelease(window_, Qt::Key_Space);
      QCOMPARE(client_->display()->sidebarVisible(), !sidebar);
      QVERIFY(client_->components()->panel().value(QStringLiteral("open")).toBool());
      QTest::keyClick(window_, Qt::Key_Tab, Qt::ShiftModifier);
      QTRY_VERIFY_WITH_TIMEOUT(close->hasActiveFocus(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_VERIFY_WITH_TIMEOUT(componentButtonFocused(QStringLiteral("Toggle sidebar")), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Backtab);
      QTRY_VERIFY_WITH_TIMEOUT(close->hasActiveFocus(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_VERIFY_WITH_TIMEOUT(componentButtonFocused(QStringLiteral("Toggle sidebar")), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_VERIFY_WITH_TIMEOUT(componentButtonFocused(QStringLiteral("Close with keyboard")), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      verifyConfiguredPickReturnsKeyboardFocus();
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void configuredAccessibleGroups() {
      const bool accessibility = QAccessible::isActive();
      const auto sidebar = client_->display()->sidebarVisible();
      const auto cleanup = qScopeGuard([this, accessibility, sidebar] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->sidebarVisible() != sidebar) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }

        QAccessible::setActive(accessibility);
      });

      QAccessible::setActive(true);
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, R"(
      local t=require('telar');local ui=t.ui;local renders=0
      return {api_version=2,client={keybindings={t.bind_global({'alt+u'},t.action.open_panel('source'))},
        panels={source=t.panel({title='Accessible controls',render=function()
          renders=renders+1;return {
            ui.button({text='Named button',action=t.action.toggle_sidebar()}),
            ui.group({on_click=t.action.toggle_sidebar(),tooltip=ui.text('Separate tooltip'),
              ui.label('Named group '..renders),ui.badge({text='Ready'})}),
          }
        end})},
      }}
    )");
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      verifyAccessibleComponentName(features::components::Kind::button, QStringLiteral("Named button"), "Named button");
      QVERIFY(!QTest::currentTestFailed());
      verifyAccessibleComponentName(features::components::Kind::group, QStringLiteral("Named group 1"), "Named group 1 Ready");
      QVERIFY(!QTest::currentTestFailed());
      const QPointer<QQuickItem> before{componentActionItem(features::components::Kind::group, QStringLiteral("Named group 1"))};
      const auto revision = client_->components()->panel().value(QStringLiteral("revision")).toString();

      client_->components()->refreshPanel();
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("revision")).toString() != revision, runtime_wait_ms);
      verifyAccessibleComponentName(features::components::Kind::group, QStringLiteral("Named group 2"), "Named group 2 Ready");
      QVERIFY(!QTest::currentTestFailed());
      QCOMPARE(componentActionItem(features::components::Kind::group, QStringLiteral("Named group 2")), before.data());
      auto* interface = QAccessible::queryAccessibleInterface(before.data());
      if (interface == nullptr || interface->actionInterface() == nullptr) {
        QFAIL("The retained group has no accessible action interface");
      }

      auto* actions = interface->actionInterface();

      QVERIFY(actions->actionNames().contains(QAccessibleActionInterface::pressAction()));
      actions->doAction(QAccessibleActionInterface::pressAction());
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), !sidebar, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void configuredPluginCaptionRefresh() {
      for (const auto kind : {features::components::Kind::button, features::components::Kind::group}) {
        verifyPluginCaptionRefresh(kind, false);
        QVERIFY(!QTest::currentTestFailed());
      }
    }

    Q_SLOT void configuredPluginCaptureRefresh() {
      for (const auto kind : {features::components::Kind::button, features::components::Kind::group}) {
        verifyPluginCaptionRefresh(kind, true);
        QVERIFY(!QTest::currentTestFailed());
      }
    }

    Q_SLOT void configuredPluginRejectsMutatedTarget() {
      const auto sidebar = client_->display()->sidebarVisible();
      const auto collapsed = client_->display()->workspaceListCollapsed();
      const auto cleanup = qScopeGuard([this, sidebar, collapsed] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->sidebarVisible() != sidebar) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }

        if (client_->display()->workspaceListCollapsed() != collapsed) {
          client_->commands()->execute(window_actions::Action::toggle_workspace_list);
        }
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      writeComponentPlugin(directory);
      QVERIFY(!QTest::currentTestFailed());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, R"(
      local t=require('telar');local ui=t.ui
      local target={kind='plugin',plugin='sample',action='sidebar'}
      return {api_version=2,plugins={{path='example'}},client={
        keybindings={t.bind_global({'alt+u'},t.action.open_panel('source')),t.bind_global({'alt+m'},function()target.action='workspaces';return {} end)},
        panels={source=t.panel({title='Plugin source',render=function()return ui.button({text='Mutable plugin',action=target})end})},
      }}
    )");
      for (const bool pointer : {false, true}) {
        client_->components()->closePanel();
        client_->loadConfiguration(path, {}, {}, directory.filePath(QStringLiteral("trust.json")));
        QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
        verifyPluginTargetMutation(pointer);
        QVERIFY(!QTest::currentTestFailed());
        client_->commands()->execute(window_actions::Action::toggle_workspace_list);
        QTRY_COMPARE_WITH_TIMEOUT(client_->display()->workspaceListCollapsed(), collapsed, runtime_wait_ms);
      }
    }

    Q_SLOT void configuredPluginUsesValidatedTarget() {
      const auto sidebar = client_->display()->sidebarVisible();
      const auto collapsed = client_->display()->workspaceListCollapsed();
      const auto cleanup = qScopeGuard([this, sidebar, collapsed] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->sidebarVisible() != sidebar) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }

        if (client_->display()->workspaceListCollapsed() != collapsed) {
          client_->commands()->execute(window_actions::Action::toggle_workspace_list);
        }
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      writeComponentPlugin(directory);
      QVERIFY(!QTest::currentTestFailed());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, R"(
      local t=require('telar');local ui=t.ui
      local target={kind='plugin',plugin='sample',action='sidebar'}
      return {api_version=2,plugins={{path='example'}},client={
        keybindings={t.bind_global({'alt+u'},t.action.open_panel('source')),t.bind_global({'alt+m'},function()target.action='workspaces';return {} end)},
        panels={source=t.panel({title='Plugin source',render=function()return ui.button({text='Validated plugin',action=target})end})},
      }}
    )");
      client_->loadConfiguration(path, {}, {}, directory.filePath(QStringLiteral("trust.json")));
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(features::components::Kind::button, QStringLiteral("Validated plugin")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto retained = test::ComponentActions::retain(*client_);
      if (!retained) {
        QFAIL("The component has no validated plugin action");
      }

      const auto& saved = retained.get();
      const auto revision = client_->components()->panel().value(QStringLiteral("revision")).toString();

      QTest::keyClick(window_, Qt::Key_M, Qt::AltModifier);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("revision")).toString(), revision);
      const auto current = test::ComponentActions::retain(*client_);
      if (!current) {
        QFAIL("The mutated component has no named action");
      }

      const auto& mutated = current.get();

      QVERIFY(saved.action == mutated.action);
      QVERIFY(std::holds_alternative<PluginActionDescription>(saved.destination));
      QVERIFY(std::holds_alternative<PluginActionDescription>(mutated.destination));
      // The Lua thread resolves an action once, when its render finishes; mutating the table later changes nothing.
      QVERIFY(std::get<PluginActionDescription>(saved.destination).action == std::get<PluginActionDescription>(mutated.destination).action);
      QVERIFY(test::ComponentActions::run(*client_, saved));
      QTRY_VERIFY_WITH_TIMEOUT(test::ComponentActions::pluginIdle(*client_), runtime_wait_ms);
      QCOMPARE(client_->display()->sidebarVisible(), !sidebar);
      QCOMPARE(client_->display()->workspaceListCollapsed(), collapsed);
      QCOMPARE(client_->status()->error(), QString{});
      client_->components()->closePanel();
      QVERIFY(!test::ComponentActions::run(*client_, saved));
      QVERIFY(client_->status()->error().contains(QStringLiteral("expired")));
      client_->status()->dismiss();
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void configuredDefinitionCaptionRefresh() {
      for (const auto kind : {features::components::Kind::button, features::components::Kind::group}) {
        for (const bool picker : {false, true}) {
          verifyDefinitionCaptionRefresh(kind, picker, false);
          QVERIFY(!QTest::currentTestFailed());
        }
      }
    }

    Q_SLOT void configuredDefinitionCaptureRefresh() {
      for (const auto kind : {features::components::Kind::button, features::components::Kind::group}) {
        for (const bool picker : {false, true}) {
          verifyDefinitionCaptionRefresh(kind, picker, true);
          QVERIFY(!QTest::currentTestFailed());
        }
      }
    }

    Q_SLOT void configuredDefinitionRejectsMutatedTarget() {
      const auto cleanup = qScopeGuard([this] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, R"(
      local t=require('telar');local ui=t.ui
      local target={kind='open-panel',panel='first'}
      return {api_version=2,client={
        keybindings={t.bind_global({'alt+u'},t.action.open_panel('source')),t.bind_global({'alt+m'},function()target.panel='second';return {} end)},
        panels={source=t.panel({title='Definition source',render=function()return ui.button({text='Mutable target',action=target})end}),
          first=t.panel({title='First destination',render=function()return ui.text('First')end}),
          second=t.panel({title='Second destination',render=function()return ui.text('Second')end})},
      }}
    )");
      for (const bool pointer : {false, true}) {
        client_->components()->closePanel();
        client_->loadConfiguration(path, {}, {});
        QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
        verifyDefinitionTargetMutation(pointer);
        QVERIFY(!QTest::currentTestFailed());
      }
    }

    Q_SLOT void configuredDefinitionUsesValidatedTarget() {
      const auto cleanup = qScopeGuard([this] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, R"(
      local t=require('telar');local ui=t.ui
      local target={kind='open-panel',panel='first'}
      return {api_version=2,client={
        keybindings={t.bind_global({'alt+u'},t.action.open_panel('source')),t.bind_global({'alt+m'},function()target.panel='second';return {} end)},
        panels={source=t.panel({title='Definition source',render=function()return ui.button({text='Single resolution',action=target})end}),
          first=t.panel({title='First destination',render=function()return ui.text('Validated target')end}),
          second=t.panel({title='Second destination',render=function()return ui.text('Unexpected target')end})},
      }}
    )");
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(features::components::Kind::button, QStringLiteral("Single resolution")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto validated = test::ComponentActions::retain(*client_);
      if (!validated) {
        QFAIL("The component has no validated definition action");
      }

      const auto& validated_definition = validated.get();
      const auto revision = client_->components()->panel().value(QStringLiteral("revision")).toString();

      QTest::keyClick(window_, Qt::Key_M, Qt::AltModifier);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("revision")).toString(), revision);
      QCOMPARE(client_->status()->error(), QString{});
      const auto current = test::ComponentActions::retain(*client_);
      if (!current) {
        QFAIL("The mutated component has no current definition action");
      }

      const auto& current_definition = current.get();

      QVERIFY(validated_definition.action == current_definition.action);
      QVERIFY(std::holds_alternative<DefinitionActionDescription>(validated_definition.destination));
      QVERIFY(std::holds_alternative<DefinitionActionDescription>(current_definition.destination));
      QVERIFY(std::get<DefinitionActionDescription>(validated_definition.destination).index == std::get<DefinitionActionDescription>(current_definition.destination).index);
      QVERIFY(test::ComponentActions::run(*client_, validated_definition));
      QTRY_COMPARE_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("First destination"), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(componentItem(QStringLiteral("text"), QStringLiteral("Validated target")) != nullptr, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
      QVERIFY(!test::ComponentActions::run(*client_, validated_definition));
      QCOMPARE(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("First destination"));
      QVERIFY(client_->status()->error().contains(QStringLiteral("expired")));
      client_->status()->dismiss();
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void configuredActionCaptionRefresh() {
      const auto sidebar = client_->display()->sidebarVisible();
      const auto cleanup = qScopeGuard([this, sidebar] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->sidebarVisible() != sidebar) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      for (const auto kind : {features::components::Kind::button, features::components::Kind::group}) {
        client_->components()->closePanel();
        const auto element = kind == features::components::Kind::button ? QStringLiteral("ui.button({text=caption,action=t.action.toggle_sidebar()})") : QStringLiteral("ui.group({on_click=t.action.toggle_sidebar(),ui.label(caption)})");
        const auto config = QStringLiteral(R"(
        local t=require('telar');local ui=t.ui;local renders=0
        return {api_version=2,client={keybindings={t.bind_global({'alt+u'},t.action.open_panel('target'))},panels={target=t.panel({title='Refreshed focus',render=function()
          renders=renders+1;local caption='Stable target '..renders;return %1
        end})}}}
      )")
                                .arg(element)
                                .toUtf8();

        writeTestFile(path, config.constData());
        client_->loadConfiguration(path, {}, {});
        QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
        QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
        QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(kind, QStringLiteral("Stable target 1")) != nullptr, runtime_wait_ms);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        const QPointer<QQuickItem> before{componentActionItem(kind, QStringLiteral("Stable target 1"))};

        before->forceActiveFocus(Qt::TabFocusReason);
        QTRY_VERIFY_WITH_TIMEOUT(before->hasActiveFocus(), runtime_wait_ms);
        const auto revision = client_->components()->panel().value(QStringLiteral("revision")).toString();

        client_->components()->refreshPanel();
        QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("revision")).toString() != revision, runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(kind, QStringLiteral("Stable target 2")) != nullptr, runtime_wait_ms);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        const QPointer<QQuickItem> after{componentActionItem(kind, QStringLiteral("Stable target 2"))};

        QCOMPARE(after.data(), before.data());
        QTRY_VERIFY_WITH_TIMEOUT(after->hasActiveFocus(), runtime_wait_ms);
        QTest::keyClick(window_, Qt::Key_Space);
        QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), !sidebar, runtime_wait_ms);
        client_->commands()->execute(window_actions::Action::toggle_sidebar);
        QCOMPARE(client_->display()->sidebarVisible(), sidebar);
        verifyComponentCaptionMouseRefresh(kind, sidebar);
        QVERIFY(!QTest::currentTestFailed());
      }
    }

    Q_SLOT void configuredBarCaptionRefresh() {
      const auto sidebar = client_->display()->sidebarVisible();
      const auto cleanup = qScopeGuard([this, sidebar] {
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->sidebarVisible() != sidebar) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, R"(
      local t=require('telar');local ui=t.ui;local renders=0
      return {api_version=2,client={bars={bottom={
        left=t.bar.dynamic({every_ms=1000,render=function()
          renders=renders+1;return ui.group({on_click=t.action.toggle_sidebar(),ui.label('Live bar '..renders)})
        end}),center=t.bar.tabs(),
      }}}}
    )");
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      const auto slot = [this] {
        return client_->components()->bars().value(QStringLiteral("left")).toMap();
      };

      QTRY_COMPARE_WITH_TIMEOUT(slot().value(QStringLiteral("nodes")).toList().size(), 2, runtime_wait_ms);
      const auto caption = slot().value(QStringLiteral("nodes")).toList().last().toMap().value(QStringLiteral("text")).toString();

      QTRY_VERIFY_WITH_TIMEOUT(componentGroup(caption) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const QPointer<QQuickItem> before{componentGroup(caption)};

      before->forceActiveFocus(Qt::TabFocusReason);
      QTRY_VERIFY_WITH_TIMEOUT(before->hasActiveFocus(), runtime_wait_ms);
      const auto revision = slot().value(QStringLiteral("revision")).toString();

      QTRY_VERIFY_WITH_TIMEOUT(slot().value(QStringLiteral("revision")).toString() != revision, runtime_wait_ms);
      const auto updated = slot().value(QStringLiteral("nodes")).toList().last().toMap().value(QStringLiteral("text")).toString();

      QVERIFY(updated != caption);
      QTRY_VERIFY_WITH_TIMEOUT(componentGroup(updated) != nullptr, runtime_wait_ms);
      QCOMPARE(componentGroup(updated), before.data());
      QTRY_VERIFY_WITH_TIMEOUT(before->hasActiveFocus(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Space);
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), !sidebar, runtime_wait_ms);
    }

    Q_SLOT void configuredActionCaptureRefresh() {
      const auto sidebar = client_->display()->sidebarVisible();
      const auto collapsed = client_->display()->workspaceListCollapsed();
      const auto cleanup = qScopeGuard([this, sidebar, collapsed] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->sidebarVisible() != sidebar) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }

        if (client_->display()->workspaceListCollapsed() != collapsed) {
          client_->commands()->execute(window_actions::Action::toggle_workspace_list);
        }
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      for (const auto kind : {features::components::Kind::button, features::components::Kind::group}) {
        client_->components()->closePanel();
        const auto element = kind == features::components::Kind::button ? QStringLiteral("ui.button({text='Stable target',action=action})") : QStringLiteral("ui.group({on_click=action,ui.label('Stable target')})");
        const auto configuration = QStringLiteral(R"(
        local t=require('telar');local ui=t.ui;local renders=0
        return {api_version=2,client={
          keybindings={t.bind_global({'alt+u'},t.action.open_panel('target'))},
          panels={target=t.panel({title='Held action target',render=function()
            renders=renders+1
            local action=(renders==1 or renders==4) and t.action.toggle_sidebar() or t.action.toggle_workspace_list()
            return %1
          end})},
        }}
      )")
                                       .arg(element)
                                       .toUtf8();

        writeTestFile(path, configuration.constData());
        client_->loadConfiguration(path, {}, {});
        QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
        QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
        QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(kind, QStringLiteral("Stable target")) != nullptr, runtime_wait_ms);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        verifyConfiguredActionCapture(kind, path, sidebar, collapsed);
        QVERIFY(!QTest::currentTestFailed());
      }
    }

    Q_SLOT void configuredGroupKeyboardActions() {
      const auto sidebar = client_->display()->sidebarVisible();
      const auto cleanup = qScopeGuard([this, sidebar] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->sidebarVisible() != sidebar) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, R"(
      local t=require('telar');local ui=t.ui
      return {api_version=2,client={bars={bottom={left=t.bar.static({
        ui.group({on_click=t.action.toggle_sidebar(),ui.label('First keyboard group')}),
        ui.group({on_click=t.action.open_panel('target'),ui.label('Second keyboard group')}),
      }),center=t.bar.tabs()}},panels={target=t.panel({title='Group keyboard target',render=function()return ui.text('Keyboard group activated')end})}}}
    )");
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTRY_COMPARE_WITH_TIMEOUT(client_->components()->bars().value(QStringLiteral("left")).toMap().value(QStringLiteral("nodes")).toList().size(), 4, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(configuredKeyboardGroupsReady(), runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const QPointer<QQuickItem> first{componentGroup(QStringLiteral("First keyboard group"))};
      const QPointer<QQuickItem> second{componentGroup(QStringLiteral("Second keyboard group"))};

      QVERIFY(!first.isNull() && !second.isNull());
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, first->mapToScene(first->boundingRect().center()).toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), !sidebar, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(first->hasActiveFocus(), runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::toggle_sidebar);
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), sidebar, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QVERIFY(!first.isNull() && !second.isNull());
      first->forceActiveFocus(Qt::TabFocusReason);
      QTRY_VERIFY_WITH_TIMEOUT(first->hasActiveFocus(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_VERIFY_WITH_TIMEOUT(second->hasActiveFocus(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(second->findChild<QQuickItem*>(QStringLiteral("componentKeyboardFocus")) != nullptr, runtime_wait_ms);
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_GROUP_KEYBOARD_SCREENSHOT");
      if (!screenshot.isEmpty()) {
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        QVERIFY(window_->grabWindow().save(screenshot, "PNG"));
      }

      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("Group keyboard target"));
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      first->forceActiveFocus(Qt::TabFocusReason);
      QTest::keyClick(window_, Qt::Key_Space, Qt::ShiftModifier);
      QCOMPARE(client_->display()->sidebarVisible(), sidebar);
      QTest::keyPress(window_, Qt::Key_Space);
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), !sidebar, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(first->hasActiveFocus(), runtime_wait_ms);
      QKeyEvent repeat{QEvent::KeyPress, Qt::Key_Space, Qt::NoModifier, QStringLiteral(" "), true};

      QCoreApplication::sendEvent(window_, &repeat);
      QCOMPARE(client_->display()->sidebarVisible(), !sidebar);
      QTest::keyRelease(window_, Qt::Key_Space);
      QCOMPARE(client_->display()->sidebarVisible(), !sidebar);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* terminal = terminalIn(window_->contentItem());

      QVERIFY(terminal != nullptr);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, terminal->mapToScene(terminal->boundingRect().center()).toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(terminal->hasActiveFocus(), runtime_wait_ms);
      first->forceActiveFocus(Qt::TabFocusReason);
      verifyGroupTabFocusTransitions();
      verifyGroupPaneHeaderFocus();
      auto* escaping = componentGroup(QStringLiteral("First keyboard group"));

      QVERIFY(escaping != nullptr);
      escaping->forceActiveFocus(Qt::TabFocusReason);
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(terminalIn(window_->contentItem()) != nullptr && terminalIn(window_->contentItem())->hasActiveFocus(), runtime_wait_ms);
      auto* retiring = componentGroup(QStringLiteral("First keyboard group"));

      QVERIFY(retiring != nullptr);
      retiring->forceActiveFocus(Qt::TabFocusReason);
      client_->loadConfiguration({}, {}, {});
      QTRY_VERIFY_WITH_TIMEOUT(componentGroup(QStringLiteral("First keyboard group")) == nullptr, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalIn(window_->contentItem()) != nullptr && terminalIn(window_->contentItem())->hasActiveFocus(), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void configuredOverflowKeyboardActions() {
      QPointer<QObject> popup;
      const auto cleanup = qScopeGuard([this, &popup] {
        if (popup != nullptr && popup->property("visible").toBool()) {
          QTest::keyClick(window_, Qt::Key_Escape);
        }

        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, R"(
      local t=require('telar');local ui=t.ui
      return {api_version=2,client={bars={bottom={left=t.bar.static({
        ui.group({on_click=t.action.open_panel('target'),priority=1,ui.label(string.rep('Hidden keyboard action ',80))}),
        ui.label({text=string.rep('Overflow pressure ',80),priority=90}),
      }),center=t.bar.tabs(),right=t.bar.static(ui.label('Right'))}},
        panels={target=t.panel({title='Overflow keyboard target',render=function()return ui.text('Hidden keyboard action activated')end})},
      }}
    )");
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      const auto controls = [this] {
        auto items = test::visualItems(*window_->contentItem(), QStringLiteral("componentOverflow"));

        items.removeIf([](const QQuickItem* item) {
          return !item->isVisible();
        });

        return items;
      };

      QTRY_COMPARE_WITH_TIMEOUT(controls().size(), 1, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      auto* chip = controls().front();
      QQmlExpression expression{QQmlEngine::contextForObject(chip), chip, QStringLiteral("overflowPopup")};

      popup = expression.evaluate().value<QObject*>();
      QVERIFY2(!expression.hasError(), qPrintable(expression.error().toString()));
      QVERIFY(popup != nullptr);
      QTest::mouseMove(window_, chip->mapRectToScene(chip->boundingRect()).center().toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(window_->cursor().shape(), Qt::PointingHandCursor, runtime_wait_ms);
      chip->forceActiveFocus(Qt::TabFocusReason);
      QTest::keyClick(window_, Qt::Key_Space);
      QTRY_VERIFY_WITH_TIMEOUT(popup->property("visible").toBool(), runtime_wait_ms);
      const auto caption = QStringLiteral("Hidden keyboard action ").repeated(80);

      QTRY_VERIFY_WITH_TIMEOUT(componentGroup(caption) != nullptr, runtime_wait_ms);
      auto* close = popupCloseButton(*popup);

      QVERIFY(close != nullptr);
      close->forceActiveFocus(Qt::TabFocusReason);
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_VERIFY_WITH_TIMEOUT(componentGroup(caption)->hasActiveFocus(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("Overflow keyboard target"));
      QTRY_VERIFY_WITH_TIMEOUT(!popup->property("visible").toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      chip->forceActiveFocus(Qt::TabFocusReason);
      QTest::keyClick(window_, Qt::Key_Space);
      QTRY_VERIFY_WITH_TIMEOUT(popup->property("visible").toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(!popup->property("visible").toBool(), runtime_wait_ms);
      chip->forceActiveFocus(Qt::TabFocusReason);
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(terminalIn(window_->contentItem()) != nullptr && terminalIn(window_->contentItem())->hasActiveFocus(), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void configuredBuiltinPriority() {
      const auto original_size = window_->size();
      const auto cleanup = qScopeGuard([this, original_size] {
        client_->components()->closePanel();
        window_->resize(original_size);
        client_->loadConfiguration({}, {}, {});
        test::waitForSynchronizedFrame(*window_, runtime_wait_ms);
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = R"(
      local t = require('telar')
      return {api_version=2,client={bars={bottom={
        left=t.bar.metrics(),center=t.bar.tabs(),right=t.bar.machines(),
      },top={right=t.bar.static(t.ui.label({text=string.rep('Priority λ ',8),priority=100}))}}}}
    )";

      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      const auto nodes = [this](const char* name) {
        return client_->components()->bars().value(QString::fromLatin1(name)).toMap().value(QStringLiteral("nodes")).toList();
      };

      QTRY_COMPARE_WITH_TIMEOUT(nodes("left").size(), 4, runtime_wait_ms);
      QCOMPARE(nodes("right").size(), 1);
      for (const auto& node : nodes("left")) {
        QCOMPARE(node.toMap().value(QStringLiteral("priority")).toInt(), 40);
      }

      QCOMPARE(nodes("right").first().toMap().value(QStringLiteral("priority")).toInt(), 40);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto caption = QStringLiteral("Priority λ ").repeated(8);
      const auto* label = componentItem(QStringLiteral("label"), caption);

      QVERIFY(label != nullptr);
      const auto summary_rings = [this] {
        auto items = test::visualItems(*window_->contentItem(), QStringLiteral("systemSummaryRing"));

        items.removeIf([](const QQuickItem* item) {
          return !item->isVisible();
        });

        return items;
      };

      QTRY_VERIFY_WITH_TIMEOUT(!summary_rings().isEmpty(), runtime_wait_ms);
      const auto* summary = summary_rings().front()->parentItem();
      const auto ratio = summary->property("ratio").toReal();
      const auto full_width = summary->implicitWidth();
      constexpr qreal bar_spacing = 40;
      // The bottom bar starts right of the full-height sidebar; the summary fits or hides as one item.
      const auto bar_left = client_->display()->geometry().value(QStringLiteral("status")).toRectF().x();
      const auto narrow_width = qCeil(bar_left + label->implicitWidth() + (bar_spacing * ratio) + (full_width / 2));

      QVERIFY(narrow_width >= window_->minimumWidth());
      window_->resize(narrow_width, original_size.height());
      QTRY_VERIFY_WITH_TIMEOUT(summary_rings().isEmpty(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(componentItem(QStringLiteral("label"), caption) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* retained = componentItem(QStringLiteral("label"), caption);
      const QRectF viewport{QPointF{}, QSizeF{window_->size()}};

      QVERIFY(viewport.contains(retained->mapRectToScene(retained->boundingRect())));
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_BUILTIN_FIT_SCREENSHOT");
      if (!screenshot.isEmpty()) {
        QVERIFY(window_->grabWindow().save(screenshot, "PNG"));
      }
    }

    Q_SLOT void configuredGroupPriority() {
      const auto cleanup = qScopeGuard([this] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
      });

      QVERIFY(!application::terminal::links::LinkTarget::fromUri("https://").hasValue());
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = R"(
      local t = require('telar')
      local ui = t.ui
      return {api_version=2,client={
        bars={bottom={
          left=t.bar.static(ui.group({on_click=t.action.open_panel('kept'),url='https://',
            ui.label({text='Keep λ',priority=100}),
            ui.label({text=string.rep('Low priority ',80),priority=1}),
          })),center=t.bar.tabs(),right=t.bar.static(ui.label('Right')),
        }},
        panels={kept=t.panel({title='Kept action',render=function(ctx) return ui.text('Priority action available') end})},
      }}
    )";

      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTRY_COMPARE_WITH_TIMEOUT(client_->components()->bars().value(QStringLiteral("left")).toMap().value(QStringLiteral("nodes")).toList().size(), 3, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* kept = componentItem(QStringLiteral("label"), QStringLiteral("Keep λ"));

      QVERIFY2(kept != nullptr, "A group must retain its high-priority child when a lower-priority child does not fit");
      QVERIFY(componentItem(QStringLiteral("label"), QStringLiteral("Low priority ").repeated(80)) == nullptr);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto bounds = kept->mapRectToScene(kept->boundingRect());
      const QRectF viewport{QPointF{}, QSizeF{window_->size()}};

      QVERIFY(viewport.contains(bounds));
      const auto* group = componentItem(QStringLiteral("group"));

      QVERIFY(group != nullptr);
      const auto group_bounds = group->mapRectToScene(group->boundingRect());

      QVERIFY2(group_bounds.contains(bounds), qPrintable(QStringLiteral("Group %1 x %2 must contain child %3 x %4").arg(group->width()).arg(group->height()).arg(kept->width()).arg(kept->height())));
      // A clickable bar group is an outlined pill padded by 9 px at the default chrome text.
      constexpr qreal pill_padding = 9;
      const auto padding = pill_padding * group->property("barScale").toReal();

      QCOMPARE(group->width(), kept->width() + (2 * padding));
      QCOMPARE(bounds.left() - group_bounds.left(), padding);
      QCOMPARE(group_bounds.right() - bounds.right(), padding);
      const auto* right = componentItem(QStringLiteral("label"), QStringLiteral("Right"));

      QVERIFY2(right != nullptr, "A short right slot must remain visible after the long low-priority child hides");
      QVERIFY(viewport.contains(right->mapRectToScene(right->boundingRect())));
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_GROUP_FIT_SCREENSHOT");
      if (!screenshot.isEmpty()) {
        QVERIFY(window_->grabWindow().save(screenshot, "PNG"));
      }

      const auto surface = client_->components()->bars().value(QStringLiteral("left")).toMap();
      const auto source = surface.value(QStringLiteral("source")).toInt();
      const auto generation = surface.value(QStringLiteral("generation")).toString();
      const auto revision = surface.value(QStringLiteral("revision")).toString();

      client_->components()->activate(source, 0, generation + QStringLiteral("stale"), revision, bounds.center());
      QVERIFY(!client_->components()->panel().value(QStringLiteral("open")).toBool());
      client_->components()->activate(source, 0, generation, revision + QStringLiteral("stale"), bounds.center());
      QVERIFY(!client_->components()->panel().value(QStringLiteral("open")).toBool());
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, bounds.center().toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("Kept action"));
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
    }

    Q_SLOT void configuredGroupChromeAndGaps() {
      const auto cleanup = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr telar::ds::Array configurations{
          R"(local t=require('telar'); return {api_version=2,client={bars={bottom={left=t.bar.static(t.ui.group({t.ui.label('First λ'),t.ui.label('Second')})),right=t.bar.tabs()}}}})",
          R"(local t=require('telar'); return {api_version=2,client={bars={bottom={left=t.bar.static(t.ui.group({mark='telar',t.ui.label('First λ'),t.ui.label('Second')})),right=t.bar.tabs()}}}})",
          R"(local t=require('telar'); return {api_version=2,client={bars={bottom={left=t.bar.static(t.ui.group({})),right=t.bar.tabs()}}}})",
          R"(local t=require('telar'); return {api_version=2,client={bars={bottom={left=t.bar.static(t.ui.group({mark='telar'})),right=t.bar.tabs()}}}})",
      };

      for (std::size_t index = 0; index < configurations.size(); ++index) {
        writeTestFile(path, configurations[index]);
        client_->loadConfiguration(path, {}, {});
        QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        const auto* group = componentItem(QStringLiteral("group"));

        QVERIFY(group != nullptr);
        const bool marked = index % 2 != 0;
        const bool empty = index >= configurations.size() / 2;
        // A group without a click stays plain text: no outline and no side padding.
        constexpr qreal gap_pixels = 6;
        constexpr qreal mark_pixels = 14;
        const auto gap = gap_pixels * group->property("ratio").toReal();
        const auto mark_width = marked ? mark_pixels * group->property("barScale").toReal() : 0;
        const auto fit_nodes = group->property("fitNodes").toList();

        QVERIFY(!fit_nodes.isEmpty());
        const auto descriptor = fit_nodes.front().toMap();

        QCOMPARE(descriptor.value(QStringLiteral("width")).toReal(), mark_width);
        QCOMPARE(descriptor.value(QStringLiteral("childGap")).toReal(), gap);
        QCOMPARE(descriptor.value(QStringLiteral("leadingGap")).toReal(), marked ? gap : 0);
        if (empty) {
          QCOMPARE(group->width(), descriptor.value(QStringLiteral("width")).toReal());
          continue;
        }

        const auto* first = componentItem(QStringLiteral("label"), QStringLiteral("First λ"));
        const auto* second = componentItem(QStringLiteral("label"), QStringLiteral("Second"));

        QVERIFY(first != nullptr && second != nullptr);
        const auto group_bounds = group->mapRectToScene(group->boundingRect());
        const auto first_bounds = first->mapRectToScene(first->boundingRect());
        const auto second_bounds = second->mapRectToScene(second->boundingRect());

        QCOMPARE(first_bounds.left() - group_bounds.left(), marked ? mark_width + gap : 0);
        QCOMPARE(second_bounds.left() - first_bounds.right(), gap);
        QCOMPARE(group_bounds.right() - second_bounds.right(), qreal{0});
        const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_GROUP_SPACING_SCREENSHOT");
        if (marked && !screenshot.isEmpty()) {
          QVERIFY(window_->grabWindow().save(screenshot, "PNG"));
        }
      }
    }

    Q_SLOT void configuredOverflowCombinesSources() {
      QPointer<QObject> popup;
      const auto cleanup = qScopeGuard([this, &popup] {
        if (popup && popup->property("visible").toBool()) {
          QTest::keyClick(window_, Qt::Key_Escape);
        }

        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = R"(
      local t = require('telar')
      local ui = t.ui
      local function contents(name,caption)
        return t.bar.static({
          ui.group({mark='telar',priority=1,on_click=t.action.open_panel(name),ui.label(string.rep(name..' hidden λ ',80))}),
          ui.label({text=string.rep(name..' pressure ',80),priority=90}),
          ui.label({text=caption,priority=100}),
        })
      end
      local function panel(name)
        return t.panel({title=name..' action',render=function(ctx) return ui.text(name..' source') end})
      end
      return {api_version=2,client={
        bars={bottom={left=contents('left','Left kept'),center=t.bar.tabs(),right=contents('right','Right kept')},top={right=contents('legacy','Legacy tail')}},
        panels={left=panel('left'),right=panel('right'),legacy=panel('legacy')},
      }}
    )";

      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      const auto overflow_controls = [this] {
        auto items = test::visualItems(*window_->contentItem(), QStringLiteral("componentOverflow"));

        items.removeIf([](const QQuickItem* item) {
          return !item->isVisible();
        });

        return items;
      };

      QTRY_COMPARE_WITH_TIMEOUT(overflow_controls().size(), 1, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* legacy = componentItem(QStringLiteral("label"), QStringLiteral("Legacy tail"));
      const auto* right = componentItem(QStringLiteral("label"), QStringLiteral("Right kept"));

      QVERIFY(legacy != nullptr && right != nullptr);
      QCOMPARE(legacy->mapRectToScene(legacy->boundingRect()).center().y(), right->mapRectToScene(right->boundingRect()).center().y());
      auto* control = overflow_controls().front();
      QQmlExpression popup_expression{QQmlEngine::contextForObject(control), control, QStringLiteral("overflowPopup")};

      popup = popup_expression.evaluate().value<QObject*>();
      QVERIFY2(!popup_expression.hasError(), qPrintable(popup_expression.error().toString()));
      QVERIFY(popup != nullptr);
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_SHARED_OVERFLOW_SCREENSHOT");

      for (const auto& source : {QStringLiteral("left"), QStringLiteral("right"), QStringLiteral("legacy")}) {
        const auto bounds = control->mapRectToScene(control->boundingRect());

        QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, bounds.center().toPoint());
        QTRY_VERIFY_WITH_TIMEOUT(popup->property("visible").toBool(), runtime_wait_ms);
        const auto caption = (source + QStringLiteral(" hidden λ ")).repeated(80);

        QTRY_VERIFY_WITH_TIMEOUT(componentItem(QStringLiteral("label"), caption) != nullptr, runtime_wait_ms);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        if (source == QStringLiteral("left") && !screenshot.isEmpty()) {
          QVERIFY(window_->grabWindow().save(screenshot, "PNG"));
        }

        const auto* hidden = componentItem(QStringLiteral("label"), caption);
        const auto action_bounds = hidden->mapRectToScene(hidden->boundingRect());
        constexpr qreal action_inset = 12;
        const QPointF action_point{action_bounds.left() + action_inset, action_bounds.center().y()};
        const QRectF viewport{QPointF{}, QSizeF{window_->size()}};

        QVERIFY(viewport.contains(action_point));
        QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, action_point.toPoint());
        QTRY_COMPARE_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("title")).toString(), source + QStringLiteral(" action"), runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(componentItem(QStringLiteral("text"), source + QStringLiteral(" source")) != nullptr, runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(!popup->property("visible").toBool(), runtime_wait_ms);
        QTest::keyClick(window_, Qt::Key_Escape);
        QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      }
    }

    Q_SLOT void configuredOverflowActionReplacesItsMenu() {
      QPointer<QObject> popup;
      const auto cleanup = qScopeGuard([this, &popup] {
        if (popup && popup->property("visible").toBool()) {
          QTest::keyClick(window_, Qt::Key_Escape);
        }

        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = R"(
      local t = require('telar')
      local ui = t.ui
      return {api_version=2,client={
        bars={bottom={left=t.bar.static({ui.group({mark='telar',priority=1,on_click=t.action.open_panel('hidden'),ui.label(string.rep('Hidden action λ ',80))}),ui.label({text=string.rep('Force overflow ',80),priority=90})}),center=t.bar.tabs(),right=t.bar.static(ui.label({text='Ready',priority=100}))}},
        panels={hidden=t.panel({title='Hidden action panel',render=function(ctx) return ui.text('Hidden action retained its source') end})},
      }}
    )";

      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      const auto overflow_controls = [this] {
        auto items = test::visualItems(*window_->contentItem(), QStringLiteral("componentOverflow"));

        items.removeIf([](const QQuickItem* item) {
          return !item->isVisible();
        });

        return items;
      };

      QTRY_COMPARE_WITH_TIMEOUT(overflow_controls().size(), 1, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      auto* control = overflow_controls().front();
      QQmlExpression popup_expression{QQmlEngine::contextForObject(control), control, QStringLiteral("overflowPopup")};

      popup = popup_expression.evaluate().value<QObject*>();
      QVERIFY2(!popup_expression.hasError(), qPrintable(popup_expression.error().toString()));
      QVERIFY(popup != nullptr);
      const auto bounds = control->mapRectToScene(control->boundingRect());

      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, bounds.center().toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(popup->property("visible").toBool(), runtime_wait_ms);
      const auto caption = QStringLiteral("Hidden action λ ").repeated(80);

      QTRY_VERIFY_WITH_TIMEOUT(componentItem(QStringLiteral("label"), caption) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* hidden = componentItem(QStringLiteral("label"), caption);
      const auto action_bounds = hidden->mapRectToScene(hidden->boundingRect());
      constexpr qreal action_inset = 12;
      const QPointF action_point{action_bounds.left() + action_inset, action_bounds.center().y()};
      const QRectF viewport{QPointF{}, QSizeF{window_->size()}};

      QVERIFY(viewport.contains(action_point));
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, action_point.toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("Hidden action panel"));
      QTRY_VERIFY_WITH_TIMEOUT(componentItem(QStringLiteral("text"), QStringLiteral("Hidden action retained its source")) != nullptr, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!popup->property("visible").toBool(), runtime_wait_ms);
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_OVERFLOW_ACTION_SCREENSHOT");
      if (!screenshot.isEmpty()) {
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        QVERIFY(window_->grabWindow().save(screenshot, "PNG"));
      }

      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, bounds.center().toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(popup->property("visible").toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(!popup->property("visible").toBool(), runtime_wait_ms);
    }

    Q_SLOT void configuredBarRetainsFailedHiddenOutput() {
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto cleanup = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      const auto path = directory.filePath(QStringLiteral("config.lua"));
      const auto marker_hex = directory.filePath(QStringLiteral("first-success")).toUtf8().toHex();
      QByteArray configuration = R"(
      local t = require('telar')
      local ui = t.ui
      local marker = ('CACHE_MARKER_HEX'):gsub('..',function(h) return string.char(tonumber(h,16)) end)
      return {api_version=2,client={bars={bottom={
        left=t.bar.static(ui.label({text='Ready',priority=100})),center=t.bar.tabs(),
        right=t.bar.command({
          command={'/bin/sh','-c','if [ -e "$1" ]; then exit 1; fi; : > "$1"; printf cached','bar-cache',marker},
          every_ms=100,render=function(ctx) return ui.label({text=string.rep('Cached value λ ',80),priority=1}) end,
        }),
      }}}}
    )";

      configuration.replace("CACHE_MARKER_HEX", marker_hex);
      writeTestFile(path, configuration.constData());
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      const auto right = [this] {
        return client_->components()->bars().value(QStringLiteral("right")).toMap();
      };

      QTRY_COMPARE_WITH_TIMEOUT(right().value(QStringLiteral("nodes")).toList().size(), 1, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(right().value(QStringLiteral("error")).toString(), QStringLiteral("Command failed"), runtime_wait_ms);
      QVERIFY(componentItem(QStringLiteral("label"), QStringLiteral("Cached value λ ").repeated(80)) == nullptr);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const QQuickItem* indicator = nullptr;

      for (const auto* item : test::visualItems(*window_->contentItem(), QString{})) {
        const auto* parent = item->parentItem();
        if (item->isVisible() && parent != nullptr && item->property("text").toString() == QStringLiteral("!") && parent->property("surface").toMap().value(QStringLiteral("source")) == right().value(QStringLiteral("source"))) {
          indicator = item;
          break;
        }
      }

      QVERIFY(indicator != nullptr);
      const auto* slot = indicator->parentItem();

      QVERIFY2(slot->width() >= indicator->width(), "Fitting retained failed output into the shared menu must preserve its diagnostic target");
      const auto bounds = indicator->mapRectToScene(indicator->boundingRect());

      QVERIFY(slot->mapRectToScene(slot->boundingRect()).contains(bounds));
      QTest::mouseMove(window_, bounds.center().toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(visibleWindowText(QStringLiteral("Command failed")), runtime_wait_ms);
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_FAILED_CACHED_BAR_SCREENSHOT");
      if (!screenshot.isEmpty()) {
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        QVERIFY(window_->grabWindow().save(screenshot, "PNG"));
      }

      QTest::mouseMove(window_, QPoint{window_->width() / 2, window_->height() / 2});
      QTRY_VERIFY_WITH_TIMEOUT(!visibleWindowText(QStringLiteral("Command failed")), runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
    }

    Q_SLOT void configuredBarReportsFirstCommandFailure() {
      const auto cleanup = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      constexpr auto configuration = R"(
      local t = require('telar')
      local ui = t.ui
      return {api_version=2,client={bars={bottom={
        left=t.bar.static(ui.label('Ready')),center=t.bar.tabs(),
        right=t.bar.command({command={'/usr/bin/false'},every_ms=60000}),
      }}}}
    )";

      writeTestFile(path, configuration);
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      const auto right = [this] {
        return client_->components()->bars().value(QStringLiteral("right")).toMap();
      };

      QTRY_COMPARE_WITH_TIMEOUT(right().value(QStringLiteral("error")).toString(), QStringLiteral("Command failed"), runtime_wait_ms);
      QVERIFY(right().value(QStringLiteral("nodes")).toList().isEmpty());
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const QQuickItem* indicator = nullptr;

      for (const auto* item : test::visualItems(*window_->contentItem(), QString{})) {
        const auto* parent = item->parentItem();
        if (!item->isVisible() || parent == nullptr || item->property("text").toString() != QStringLiteral("!")) {
          continue;
        }

        const auto surface = parent->property("surface").toMap();
        if (surface.value(QStringLiteral("source")) == right().value(QStringLiteral("source")) && surface.value(QStringLiteral("error")) == right().value(QStringLiteral("error"))) {
          indicator = item;
          break;
        }
      }

      QVERIFY(indicator != nullptr);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* slot = indicator->parentItem();

      QVERIFY2(slot->width() >= indicator->width(), "A first failing command must retain a visible diagnostic target before producing output");
      const auto bounds = indicator->mapRectToScene(indicator->boundingRect());

      QVERIFY(slot->mapRectToScene(slot->boundingRect()).contains(bounds));
      QTest::mouseMove(window_, bounds.center().toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(visibleWindowText(right().value(QStringLiteral("error")).toString()), runtime_wait_ms);
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_COMPONENT_ERROR_SCREENSHOT");
      if (!screenshot.isEmpty()) {
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        QVERIFY(window_->grabWindow().save(screenshot, "PNG"));
      }

      QTest::mouseMove(window_, QPoint{window_->width() / 2, window_->height() / 2});
      QTRY_VERIFY_WITH_TIMEOUT(!visibleWindowText(right().value(QStringLiteral("error")).toString()), runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
    }

    Q_SLOT void configuredPicks() {
      const auto sidebar = client_->display()->sidebarVisible();
      const auto cleanup = qScopeGuard([this, sidebar] {
        client_->components()->closePick();
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->sidebarVisible() != sidebar) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      const auto marker = directory.filePath(QStringLiteral("choice"));
      const QByteArray marker_hex = marker.toUtf8().toHex();
      QByteArray configuration = R"(
      local t = require('telar')
      local ui = t.ui
      local marker = ('MARKER_HEX'):gsub('..', function(h) return string.char(tonumber(h,16)) end)
      local save = {'/bin/sh','-c','printf %s "$1" > "$2"','pick-test','{}',marker}
      return {api_version=2,client={
        keybindings={t.bind_global({'alt+u'},t.action.open_panel('usage')),t.bind_global({'alt+o'},t.action.pick('mode'))},
        panels={usage=t.panel({render=function(ctx) return ui.text('Retained panel') end})},
        picks={mode=t.pick({title='Daily choices',items={'first',{label='Unicode λ',value='á λ;$(literal)',detail='details',selected=true,swatch={'#000000','#abcdef','#ffffff'}}},on_select=save})},
      }}
    )";

      configuration.replace("MARKER_HEX", marker_hex);
      writeTestFile(path, configuration.constData());
      client_->loadConfiguration(path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_O, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->pick().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client_->components()->pick().value(QStringLiteral("rows")).toList().size(), 2, runtime_wait_ms);
      auto* query = window_->findChild<QQuickItem*>(QStringLiteral("configuredPickQuery"));

      QVERIFY(query != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(query->hasActiveFocus(), runtime_wait_ms);
      for (const auto visible : {!sidebar, sidebar}) {
        client_->commands()->execute(window_actions::Action::toggle_sidebar);
        QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), visible, runtime_wait_ms);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
        QVERIFY(client_->components()->panel().value(QStringLiteral("open")).toBool());
        QVERIFY(client_->components()->pick().value(QStringLiteral("open")).toBool());
        QVERIFY(query->hasActiveFocus());
      }

      for (const auto key : {Qt::Key_D, Qt::Key_E, Qt::Key_T, Qt::Key_A, Qt::Key_I, Qt::Key_L, Qt::Key_S}) {
        QTest::keyClick(window_, key);
      }

      QTRY_COMPARE_WITH_TIMEOUT(client_->components()->pick().value(QStringLiteral("rows")).toList().size(), 1, runtime_wait_ms);
      QCOMPARE(client_->components()->pick().value(QStringLiteral("rows")).toList().first().toMap().value(QStringLiteral("label")).toString(), QStringLiteral("Unicode λ"));
      QVERIFY(QMetaObject::invokeMethod(query, "select", Q_ARG(int, 0), Q_ARG(int, 3)));
      QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};

      QCoreApplication::sendEvent(query, &preedit);
      QTRY_VERIFY_WITH_TIMEOUT(query->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Escape);
      QVERIFY(client_->components()->pick().value(QStringLiteral("open")).toBool());
      QTRY_VERIFY_WITH_TIMEOUT(!query->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
      QCOMPARE(query->property("text").toString(), QStringLiteral("details"));
      QCOMPARE(query->property("selectedText").toString(), QStringLiteral("det"));
      QCOMPARE(client_->components()->pick().value(QStringLiteral("rows")).toList().size(), 1);
      QVERIFY(client_->components()->panel().value(QStringLiteral("open")).toBool());
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto frame = window_->grabWindow();

      QVERIFY(!frame.isNull());
      const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_PICK_SCREENSHOT");
      if (!screenshot.isEmpty()) {
        QVERIFY(frame.save(screenshot, "PNG"));
      }

      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->pick().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(readTestFile(marker) == QByteArray::fromHex("c3a120cebb3b24286c69746572616c29"), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->pick().value(QStringLiteral("selecting")).toBool(), runtime_wait_ms);
      QVERIFY(client_->components()->panel().value(QStringLiteral("open")).toBool());
      QTRY_VERIFY_WITH_TIMEOUT(configuredPanelFocused(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_O, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->pick().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->pick().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QVERIFY(client_->components()->panel().value(QStringLiteral("open")).toBool());
      QTest::keyClick(window_, Qt::Key_O, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->pick().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      client_->loadConfiguration(path, {}, {});
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->pick().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      client_->components()->closePanel();
    }

    // Whether the focus is in the open configured panel.
    [[nodiscard]] bool configuredPanelFocused() const {
      const auto* popup = window_->findChild<QObject*>(QStringLiteral("configuredPanel"));
      const auto* content = popup != nullptr ? popup->property("contentItem").value<QQuickItem*>() : nullptr;
      const auto* scope = content != nullptr ? content->parentItem() : nullptr;
      const auto* focus = window_->activeFocusItem();

      return scope != nullptr && focus != nullptr && (scope == focus || scope->isAncestorOf(focus));
    }

    Q_SLOT void routedPluginCatalog() {
      const auto cleanup = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      client_->loadConfiguration({}, {}, {});
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      peer.request(telar::ClientAction::plugin_list, pluginCatalogRequestId(PluginCatalogRequest::unconfigured));
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::unconfigured), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("ConfigurationNotLoaded"));
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      QVERIFY(QDir{directory.path()}.mkdir(QStringLiteral("example")));
      const auto package = directory.filePath(QStringLiteral("example"));

      writeTestFile(package + QStringLiteral("/plugin.json"), R"({"api_version":1,"id":"sample","version":"1","entry":"main.lua","source":{"url":"fixture","revision":"1"},"actions":["first","second"],"capabilities":["notifications","workspace.read"]})");
      writeTestFile(package + QStringLiteral("/main.lua"), "return {first=function() return nil end}");
      QProcess inspect;

      inspect.start(qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME"), {QStringLiteral("plugin"), QStringLiteral("inspect"), package});
      QVERIFY(inspect.waitForFinished(runtime_wait_ms));
      QCOMPARE(inspect.exitStatus(), QProcess::NormalExit);
      QCOMPARE(inspect.exitCode(), 0);
      QString expected_digest;

      for (const auto& line : QString::fromUtf8(inspect.readAllStandardOutput()).split(QLatin1Char('\n'))) {
        if (line.startsWith(QLatin1StringView("digest: "))) {
          expected_digest = line.sliced(QStringLiteral("digest: ").size());
        }
      }

      constexpr qsizetype digest_hex_bytes = 64;

      QCOMPARE(expected_digest.size(), digest_hex_bytes);
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, plugin_catalog_configuration);
      client_->loadConfiguration(path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      peer.request(telar::ClientAction::plugin_list, pluginCatalogRequestId(PluginCatalogRequest::disabled_list));
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::disabled_list), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QCOMPARE(peer.result().value, std::int64_t{1});
      auto text = peer.result().text.toUtf8();
      auto parsed = telar::runtime::JsonValue::parse({text.constData(), static_cast<std::size_t>(text.size())});
      const std::uint64_t generation = toQString(requiredJsonField(parsed, "generation").encoded()).toULongLong();

      QVERIFY(generation != 0);
      QVERIFY(peer.result().text.contains(QLatin1StringView("\"id\":null")));
      QVERIFY(peer.result().text.contains(QLatin1StringView("\"requested_enabled\":false")));
      peer.request(telar::ClientCommand{.request_id = pluginCatalogRequestId(PluginCatalogRequest::enabled_list), .action = telar::ClientAction::plugin_list, .target_id = generation, .value = 1});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::enabled_list), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QCOMPARE(peer.result().value, std::int64_t{-1});
      QVERIFY(peer.result().text.contains(QLatin1StringView("\"id\":\"sample\"")));
      peer.request(telar::ClientCommand{.request_id = pluginCatalogRequestId(PluginCatalogRequest::metadata), .action = telar::ClientAction::plugin_get, .target_id = generation, .text = "sample"});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::metadata), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QCOMPARE(peer.result().value, std::int64_t{1});
      text = peer.result().text.toUtf8();
      parsed = telar::runtime::JsonValue::parse({text.constData(), static_cast<std::size_t>(text.size())});
      verifyPluginCatalogEntry(parsed, expected_digest);
      QVERIFY(!QTest::currentTestFailed());
      peer.request(telar::ClientCommand{.request_id = pluginCatalogRequestId(PluginCatalogRequest::first_action), .action = telar::ClientAction::plugin_get, .target_id = generation, .value = 1, .text = "example"});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::first_action), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QCOMPARE(peer.result().value, std::int64_t{2});
      QVERIFY(peer.result().text.contains(QLatin1StringView("\"entries\":[\"first\"]")));
      peer.request(telar::ClientCommand{.request_id = pluginCatalogRequestId(PluginCatalogRequest::last_action), .action = telar::ClientAction::plugin_get, .target_id = generation, .value = 2, .text = "sample"});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::last_action), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QCOMPARE(peer.result().value, std::int64_t{-1});
      QVERIFY(peer.result().text.contains(QLatin1StringView("\"entries\":[\"second\"]")));
      peer.request(telar::ClientCommand{.request_id = pluginCatalogRequestId(PluginCatalogRequest::stale_generation), .action = telar::ClientAction::plugin_list, .target_id = generation + 1, .value = -1});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::stale_generation), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("StaleConfiguration"));
      peer.request(telar::ClientAction::plugin_get, pluginCatalogRequestId(PluginCatalogRequest::invalid_page), "sample", 3);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::invalid_page), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("InvalidPage"));
      peer.request(telar::ClientAction::plugin_get, pluginCatalogRequestId(PluginCatalogRequest::missing), "missing", -1);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::missing), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("PluginNotConfigured"));
      verifyPluginCatalogReload(peer, path, generation, expected_digest);
      QCOMPARE(peer.error(), QString{});
      QCOMPARE(client_->status()->error(), QString{});
    }

    // The metadata of the catalog's one plugin names its package, digest and capabilities.
    static void verifyPluginCatalogEntry(const telar::runtime::JsonValue& metadata, const QString& expected_digest) {
      const auto entries = requiredJsonField(metadata, "entries");
      std::size_t entry_count = 0;

      entries.eachElement([&](const auto& entry) {
        ++entry_count;
        QVERIFY(requiredJsonField(entry, "digest").equals(expected_digest.toStdString()));
        QVERIFY(requiredJsonField(entry, "path").equals("example"));
        QVERIFY(requiredJsonField(entry, "capabilities").encoded() == R"(["workspace.read","notifications"])");
      });

      QCOMPARE(entry_count, std::size_t{1});
    }

    void verifyPluginCatalogReload(CommandPeer& peer, const QString& path, std::uint64_t generation, const QString& expected_digest) {
      writeTestFile(path, "return {api_version=2,plugins={{path='missing-enabled'}}}");
      peer.request(telar::ClientAction::config_reload, pluginCatalogRequestId(PluginCatalogRequest::failed_reload));
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::failed_reload), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->status()->error().isEmpty(), runtime_wait_ms);
      peer.request(telar::ClientCommand{.request_id = pluginCatalogRequestId(PluginCatalogRequest::retained_catalog), .action = telar::ClientAction::plugin_get, .target_id = generation, .text = "sample"});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::retained_catalog), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QVERIFY(peer.result().text.contains(expected_digest));
      writeTestFile(path, plugin_catalog_configuration);
      const QSignalSpy adopted{client_.get(), &ApplicationController::configurationChanged};

      QVERIFY(adopted.isValid());
      peer.request(telar::ClientAction::config_reload, pluginCatalogRequestId(PluginCatalogRequest::recover_reload));
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::recover_reload), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QTRY_VERIFY_WITH_TIMEOUT(adopted.count() > 0 && client_->status()->error().isEmpty(), runtime_wait_ms);
      peer.request(telar::ClientCommand{.request_id = pluginCatalogRequestId(PluginCatalogRequest::old_generation), .action = telar::ClientAction::plugin_list, .target_id = generation});
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, pluginCatalogRequestId(PluginCatalogRequest::old_generation), runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("StaleConfiguration"));
    }

    Q_SLOT void routedClientConfigurationQuery() {
      const QTemporaryDir directory;
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, "return {api_version=2,client={window_title='work {tab}',sound={enabled=false}},profiles={chosen={client={notifications={delivery='system'}}}}}");
      const auto original_collapsed = client_->display()->workspaceListCollapsed();
      const auto restore = qScopeGuard([this, original_collapsed] {
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->workspaceListCollapsed() != original_collapsed) {
          client_->commands()->execute(window_actions::Action::toggle_workspace_list);
        }
      });

      client_->loadConfiguration(path, QStringLiteral("chosen"), {});
      QCOMPARE(client_->status()->error(), QString{});
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      peer.request(telar::ClientAction::config_show, 2, {}, -1);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      auto text = peer.result().text.toUtf8();
      auto parsed = telar::runtime::JsonValue::parse({text.constData(), static_cast<std::size_t>(text.size())});
      const std::string generation{requiredJsonField(parsed, "generation").encoded()};

      QVERIFY(requiredJsonField(parsed, "profile").equals("chosen"));
      QVERIFY(requiredJsonField(parsed, "window_title").equals("work {tab}"));
      QVERIFY(!requiredJsonField(requiredJsonField(parsed, "sound"), "enabled").boolean());
      QVERIFY(requiredJsonField(parsed, "notification_delivery").equals("system"));
      peer.request(telar::ClientAction::sidebar_get, 3);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
      const auto expected_width = std::to_string(peer.result().value);

      client_->commands()->execute(window_actions::Action::toggle_sidebar);
      client_->commands()->execute(window_actions::Action::toggle_workspace_list);
      peer.request(telar::ClientAction::config_show, 4, "client", -1);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{4}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      text = peer.result().text.toUtf8();
      parsed = telar::runtime::JsonValue::parse({text.constData(), static_cast<std::size_t>(text.size())});
      QCOMPARE(requiredJsonField(parsed, "generation").encoded(), std::string_view{generation});
      QCOMPARE(requiredJsonField(parsed, "sidebar_width").encoded(), std::string_view{expected_width});
      QCOMPARE(requiredJsonField(parsed, "sidebar_visible").boolean(), client_->display()->sidebarVisible());
      QCOMPARE(requiredJsonField(parsed, "workspace_list_collapsed").boolean(), client_->display()->workspaceListCollapsed());
      QCOMPARE(peer.error(), QString{});
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void routedBindingConfigurationQuery() {
      const QTemporaryDir directory;
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, "return {api_version=2,client={keybindings={telar.bind({'c'},telar.action.command_tab{command={'echo','snapshot'},label='kept'}),telar.bind({'s'},function() error('a query must not execute this callback') end)}}}");
      const auto restore = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      client_->loadConfiguration(path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      const auto tab_count = client_->tabs()->rows()->rowCount();
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      peer.request(telar::ClientAction::config_show, 2, "binding");
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QVERIFY(peer.result().text.contains(QStringLiteral("\"command_tab\"")));
      QVERIFY(peer.result().text.contains(QStringLiteral("\"argv\":[\"echo\",\"snapshot\"]")));
      peer.request(telar::ClientAction::config_show, 3, "binding", 1);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      QVERIFY(peer.result().text.contains(QStringLiteral("\"lua_callback\"")));
      peer.request(telar::ClientAction::config_show, 4, "binding", 2);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{4}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("BindingNotFound"));
      constexpr std::uint64_t negative_index_request = 5;

      peer.request(telar::ClientAction::config_show, negative_index_request, "binding", -1);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, negative_index_request, runtime_wait_ms);
      QCOMPARE(peer.result().text, QStringLiteral("InvalidIndex"));
      QCOMPARE(client_->tabs()->rows()->rowCount(), tab_count);
      QCOMPARE(client_->status()->error(), QString{});
      QCOMPARE(peer.error(), QString{});
    }

    Q_SLOT void routedThemeConfigurationQuery() {
      const QTemporaryDir directory;
      const auto path = directory.filePath(QStringLiteral("config.lua"));

      writeTestFile(path, "return {api_version=2,theme={base='vesper',colors={text='#010203'}}}");
      const auto restore = qScopeGuard([this] {
        client_->loadConfiguration({}, {}, {});
      });

      client_->loadConfiguration(path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      peer.request(telar::ClientAction::config_show, 2, "theme");
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      const auto text = peer.result().text.toUtf8();
      const auto query = telar::runtime::JsonValue::parse({text.constData(), static_cast<std::size_t>(text.size())});

      QVERIFY(requiredJsonField(requiredJsonField(query, "base"), "base").equals("vesper"));
      const auto palette = requiredJsonField(requiredJsonField(query, "base"), "palette");

      QCOMPARE(requiredJsonField(requiredJsonField(palette, "text"), "value").encoded(), std::string_view{R"("\u0001\u0002\u0003")"});
      QCOMPARE(peer.error(), QString{});
    }

    Q_SLOT void routedGuiAndInputConfigurationQueries() {
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      QFile file{path};

      QVERIFY(file.open(QIODevice::WriteOnly));
      const QByteArray source{"return {api_version=2,gui={font={size=18.25},window={background_opacity=0.75,padding={x=2.5}},opacity={pane=0.25,topbar=1}},client={prefix='shift+tab',input={sequence_timeout_ms=500},keybindings={telar.bind_global({'g'},telar.action.toggle_sidebar())}}}"};

      QCOMPARE(file.write(source), source.size());
      file.close();
      client_->loadConfiguration(path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      peer.request(telar::ClientAction::config_show, 2, "gui");
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      const auto gui_text = peer.result().text.toUtf8();
      const auto gui = telar::runtime::JsonValue::parse({gui_text.constData(), static_cast<std::size_t>(gui_text.size())});

      QCOMPARE(requiredJsonField(requiredJsonField(gui, "font"), "size").encoded(), std::string_view{"18.25"});
      QCOMPARE(requiredJsonField(requiredJsonField(gui, "window"), "background_opacity").encoded(), std::string_view{"0.75"});
      QCOMPARE(requiredJsonField(requiredJsonField(gui, "opacity"), "pane").encoded(), std::string_view{"0.25"});
      QCOMPARE(requiredJsonField(requiredJsonField(gui, "opacity"), "topbar").encoded(), std::string_view{"1"});
      QCOMPARE(requiredJsonField(requiredJsonField(gui, "opacity"), "workspace").encoded(), std::string_view{"0.75"});
      peer.request(telar::ClientAction::config_show, 3, "input");
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      const auto input_text = peer.result().text.toUtf8();
      const auto input = telar::runtime::JsonValue::parse({input_text.constData(), static_cast<std::size_t>(input_text.size())});

      QCOMPARE(requiredJsonField(input, "binding_count").encoded(), std::string_view{"1"});
      QCOMPARE(requiredJsonField(input, "sequence_timeout_ns").encoded(), std::string_view{"500000000"});
      QCOMPARE(requiredJsonField(requiredJsonField(input, "prefix"), "code").encoded(), std::string_view{R"({"back_tab":{}})"});
      peer.request(telar::ClientAction::config_show, 4, "gui", -1);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{4}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("InvalidIndex"));
      QCOMPARE(peer.error(), QString{});
      client_->loadConfiguration({}, {}, {});
    }

    Q_SLOT void routedRuntimeConfigurationQuery() {
      client_->loadConfiguration({}, {}, {});
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      peer.request(telar::ClientAction::config_show, 2, "missing");
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("UnknownConfigurationSection"));
      peer.request(telar::ClientAction::config_show, 3, "runtime", -1);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
      QCOMPARE(peer.result().text, QStringLiteral("ConfigurationNotLoaded"));
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      QFile file{path};

      QVERIFY(file.open(QIODevice::WriteOnly));
      const QByteArray source{"return {api_version=2,runtime={history={path='gui-query.db'},graphics={pane_mib=8,global_mib=16},session={persist=false}}}"};

      QCOMPARE(file.write(source), source.size());
      file.close();
      client_->loadConfiguration(path, {}, {});
      QCOMPARE(client_->status()->error(), QString{});
      peer.request(telar::ClientAction::config_show, 4, "runtime");
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{4}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
      const auto text = peer.result().text.toUtf8();
      const auto parsed = telar::runtime::JsonValue::parse({text.constData(), static_cast<std::size_t>(text.size())});

      QVERIFY(requiredJsonField(parsed, "history_path").equals("gui-query.db"));
      QCOMPARE(requiredJsonField(parsed, "graphics_pane_bytes").encoded(), std::string_view{"8388608"});
      QVERIFY(!requiredJsonField(parsed, "session_persist").boolean());
      QVERIFY(!QFileInfo::exists(directory.filePath(QStringLiteral("gui-query.db"))));
      QCOMPARE(runtime_.state(), QProcess::Running);
      constexpr std::uint64_t invalid_index_request = 5;

      peer.request(telar::ClientAction::config_show, invalid_index_request, "runtime", -1);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, invalid_index_request, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("InvalidIndex"));
      QCOMPARE(peer.error(), QString{});
      client_->loadConfiguration({}, {}, {});
    }

    Q_SLOT void routedConfigurationReload() {
      const auto uncapped_interval = telar::gui::qt::WindowAnimationClock::forWindow(*window_).frameInterval();
      CommandPeer peer{memory_};

      peer.open(socket_);
      QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
      peer.request(telar::ClientAction::config_reload, 2);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
      QCOMPARE(peer.result().text, QStringLiteral("ConfigurationNotLoaded"));

      const QTemporaryDir configuration_directory;

      QVERIFY(configuration_directory.isValid());
      const auto configuration_path = configuration_directory.filePath(QStringLiteral("config.lua"));
      QFile configuration_file{configuration_path};

      QVERIFY(configuration_file.open(QIODevice::WriteOnly));
      const QByteArray source{"return {api_version = 2, client = {window_title = 'configured {pane_title} @ {hostname}'}, gui = {max_fps = 30, font = {size = 18, thicken = true, thicken_strength = 128}}}"};

      QCOMPARE(configuration_file.write(source), source.size());
      configuration_file.close();
      // Read before the load, so the cached theme and font must give way to the new ones.
      QCOMPARE(client_->font().value(QStringLiteral("size")).toFloat(), client_->configuration().font.size);
      QVERIFY(!client_->colors().isEmpty());
      client_->loadConfiguration(configuration_path, {}, {});
      constexpr std::uint64_t capped_interval = 1'000'000'000 / 30;

      QCOMPARE(telar::gui::qt::WindowAnimationClock::forWindow(*window_).frameInterval(), capped_interval);
      constexpr float configured_font_size = 18;
      constexpr std::uint8_t configured_strength = 128;

      QCOMPARE(client_->configuration().font.size, configured_font_size);
      QVERIFY(client_->configuration().font.thicken);
      QCOMPARE(client_->configuration().font.thicken_strength, configured_strength);
      QVERIFY(client_->font().value(QStringLiteral("thicken")).toBool());
      QCOMPARE(client_->font().value(QStringLiteral("size")).toFloat(), configured_font_size);
      QCOMPARE(client_->colors(), telar::gui::qt::themeColors(client_->configuration()));
      QTRY_COMPARE(window_->title(), client_->status()->title());
      QVERIFY(window_->title().startsWith(QStringLiteral("configured ")));
      QVERIFY(!window_->title().contains(QStringLiteral("{hostname}")));
      const auto* pane = firstPane();

      QVERIFY(pane != nullptr);
      client_->commands()->execute(window_actions::Action::focus_pane, QString::number(pane->id));
      client_->terminals()->input(pane->id, "printf '\\033]0;cpp-title-fixture\\007'\n");
      QTRY_COMPARE_WITH_TIMEOUT(toQString(pane->title), QStringLiteral("cpp-title-fixture"), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(window_->title().startsWith(QStringLiteral("configured cpp-title-fixture @ ")), runtime_wait_ms);

      const QSignalSpy reloaded{client_.get(), &ApplicationController::configurationChanged};

      QVERIFY(reloaded.isValid());
      peer.request(telar::ClientAction::config_reload, 3);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QCOMPARE(peer.result().text, QString{});
      QTRY_VERIFY_WITH_TIMEOUT(reloaded.count() > 0, runtime_wait_ms);
      QCOMPARE(telar::gui::qt::WindowAnimationClock::forWindow(*window_).frameInterval(), capped_interval);
      QCOMPARE(client_->configuration().font.size, configured_font_size);
      QVERIFY(window_->title().startsWith(QStringLiteral("configured ")));
      QCOMPARE(peer.error(), QString{});
      QCOMPARE(client_->configuration().font.thicken_strength, configured_strength);
      QCOMPARE(client_->status()->error(), QString{});

      QVERIFY(configuration_file.open(QIODevice::WriteOnly | QIODevice::Truncate));
      const QByteArray invalid_source{"return {api_version = 2, gui = {font = {size = 0}}}"};

      QCOMPARE(configuration_file.write(invalid_source), invalid_source.size());
      configuration_file.close();
      peer.request(telar::ClientAction::config_reload, 4);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{4}, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->status()->error().isEmpty(), runtime_wait_ms);
      QCOMPARE(telar::gui::qt::WindowAnimationClock::forWindow(*window_).frameInterval(), capped_interval);
      QCOMPARE(client_->configuration().font.size, configured_font_size);

      QVERIFY(configuration_file.open(QIODevice::WriteOnly | QIODevice::Truncate));
      QCOMPARE(configuration_file.write(source), source.size());
      configuration_file.close();
      constexpr std::uint64_t recovery_request = 5;

      peer.request(telar::ClientAction::config_reload, recovery_request);
      QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, recovery_request, runtime_wait_ms);
      QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
      QTRY_COMPARE_WITH_TIMEOUT(client_->status()->error(), QString{}, runtime_wait_ms);
      QCOMPARE(client_->configuration().font.size, configured_font_size);
      client_->loadConfiguration({}, {}, {});
      QTRY_COMPARE(window_->title(), QStringLiteral("Telar"));
      QCOMPARE(telar::gui::qt::WindowAnimationClock::forWindow(*window_).frameInterval(), uncapped_interval);
    }

    Q_SLOT void hiddenTerminalFramesWaitForVisibleContent() {
      verifyTerminalFrameAdmission(TerminalSuppression::hidden);
    }

    Q_SLOT void outputResumesADeferredWindowFrame() {
      const QTemporaryDir gate_directory;

      QVERIFY(gate_directory.isValid());
      const auto release_path = gate_directory.filePath(QStringLiteral("release"));
      const auto finish = qScopeGuard([this, release_path] {
        QFile gate{release_path};
        if (gate.open(QIODevice::WriteOnly)) {
          gate.close();
        }

        telar::gui::test::FramePacing::release(*client_);
      });

      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto* pane = firstPane();

      QVERIFY(pane != nullptr);
      const auto command = QStringLiteral("printf '\\033[2J\\033[HFRAME_PACING_WAIT\\n'; while [ ! -f ") + shellLiteral(release_path) + QStringLiteral(" ]; do sleep 0.01; done; printf 'FRAME_PACING_DONE\\n'\r");

      client_->terminals()->input(pane->id, command.toUtf8());
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).startsWith(QLatin1StringView("FRAME_PACING_WAIT")), runtime_wait_ms);
      QVERIFY(telar::gui::test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
      constexpr int grace_expiry_ms = static_cast<int>(telar::gui::features::window::FramePacer::input_grace_ns / nanoseconds_per_millisecond) + 1;

      QTest::qWait(grace_expiry_ms);
      constexpr auto hold_ns = telar::gui::features::window::FramePacer::nanoseconds_per_second * 2;

      telar::gui::test::FramePacing::anchor(*client_, telar::gui::system::AwakeClock::nowNanoseconds() + hold_ns);
      window_->update();
      QVERIFY(telar::gui::test::waitForGuiCondition([&] {
        return telar::gui::test::FramePacing::pending(*client_);
      },
          runtime_wait_ms));
      telar::gui::test::FramePacing::anchor(*client_, telar::gui::system::AwakeClock::nowNanoseconds() - telar::gui::features::window::FramePacer::maximum_interval_ns);
      const auto previous = pane->screen.frameId();

      writeTestFile(release_path, "");
      constexpr int wakeup_wait_ms = 500;

      QVERIFY2(telar::gui::test::waitForGuiCondition([&] {
        return pane->screen.frameId() > previous && pane->acknowledged_frame == pane->screen.frameId() && screenText(pane->screen).contains(QLatin1StringView("FRAME_PACING_DONE"));
      },
                   wakeup_wait_ms),
          qPrintable(QStringLiteral("frame=%1 acknowledged=%2 pending=%3").arg(pane->screen.frameId()).arg(pane->acknowledged_frame).arg(telar::gui::test::FramePacing::pending(*client_))));
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void replacingTheWindowReturnsItsDeferredUpdate() {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      QVERIFY(telar::gui::test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QQuickWindow replacement;

      replacement.setScreen(window_->screen());
      replacement.resize(window_->size());
      const auto restore = qScopeGuard([this] {
        client_->setWindow(*window_);
        telar::gui::test::FramePacing::release(*client_);
      });

      constexpr auto hold_ns = telar::gui::features::window::FramePacer::nanoseconds_per_second * 2;

      telar::gui::test::FramePacing::anchor(*client_, telar::gui::system::AwakeClock::nowNanoseconds() + hold_ns);
      window_->update();
      QVERIFY(telar::gui::test::waitForGuiCondition([&] {
        return telar::gui::test::FramePacing::pending(*client_);
      },
          runtime_wait_ms));
      const QSignalSpy prepared{window_, &QQuickWindow::afterSynchronizing};

      client_->setWindow(replacement);
      QVERIFY(!telar::gui::test::FramePacing::pending(*client_));
      constexpr int return_wait_ms = 500;

      QVERIFY(telar::gui::test::waitForGuiCondition([&] {
        return !prepared.isEmpty();
      },
          return_wait_ms));
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void terminalFramesWaitForSceneSynchronization() {
      verifyTerminalFrameAdmission(TerminalSuppression::no_contents);
    }

    Q_SLOT void queuedFramesCannotSurviveAWindowBindingChange() {
      for (const bool restore_before_delivery : telar::ds::Array{false, true}) {
        QQuickWindow replacement;

        replacement.setScreen(window_->screen());
        replacement.resize(window_->size());
        const auto restore = qScopeGuard([this] {
          client_->setWindow(*window_);
          window_->show();
        });

        const auto* pane = firstPane();

        QVERIFY(pane != nullptr);
        // The runtime holds a pane's next frame until the client acknowledges the last one, and a
        // hidden window acknowledges nothing. A frame that lands while the window hides would
        // hold back the frame this test waits for, so the window shows again and hides once more.
        const auto hidden = [this] {
          return !window_->isExposed();
        };

        const auto exposed = [this] {
          return window_->isExposed();
        };

        const auto hidden_with_frames_acknowledged = [&] {
          if (pane->acknowledged_frame != pane->screen.frameId()) {
            return false;
          }

          window_->hide();

          if (!QTest::qWaitFor(hidden, runtime_wait_ms)) {
            return false;
          }

          test::FramePacing::presentSwapped(*client_);

          if (pane->acknowledged_frame == pane->screen.frameId()) {
            return true;
          }

          window_->show();
          static_cast<void>(QTest::qWaitFor(exposed, runtime_wait_ms));

          return false;
        };

        QTRY_VERIFY_WITH_TIMEOUT(hidden_with_frames_acknowledged(), runtime_wait_ms);
        const auto previous_frame = pane->screen.frameId();
        const auto acknowledged = pane->acknowledged_frame;

        client_->terminals()->input(pane->id, QByteArrayLiteral("printf 'WINDOW_FRAME_OWNER\\n'\r"));
        QTRY_VERIFY2_WITH_TIMEOUT(pane->screen.frameId() > previous_frame, qPrintable(QStringLiteral("offset %1 total %2 rows %3 acked %4 frame %5").arg(pane->screen.scroll().offset).arg(pane->screen.scroll().total_rows).arg(pane->screen.rows()).arg(pane->acknowledged_frame).arg(pane->screen.frameId())), runtime_wait_ms);
        const auto pending_frame = pane->screen.frameId();

        QVERIFY(pending_frame > acknowledged);
        window_->beforeSynchronizing();
        window_->frameSwapped();
        client_->setWindow(replacement);
        replacement.beforeSynchronizing();
        replacement.frameSwapped();
        if (restore_before_delivery) {
          client_->setWindow(*window_);
        }

        test::FramePacing::presentSwapped(*client_);
        QCOMPARE(pane->acknowledged_frame, acknowledged);
        client_->setWindow(*window_);
        window_->show();
        QTRY_VERIFY_WITH_TIMEOUT(pane->acknowledged_frame >= pending_frame, runtime_wait_ms);
        QCOMPARE(client_->status()->error(), QString{});
      }
    }

    Q_SLOT void reopeningRestoresLayout() {
      const auto previous_tabs = client_->tabs()->rows()->rowCount();
      const auto previous_pane = firstPane()->id;

      client_->commands()->execute(window_actions::Action::toggle_workspace_list);
      QVERIFY(client_->display()->workspaceListCollapsed());
      QTest::qWait(frame_settle_ms);
      engine_.reset();
      client_.reset();
      window_ = nullptr;
      QCOMPARE(runtime_.state(), QProcess::Running);
      openWindow();
      QVERIFY2(window_ != nullptr, qPrintable(errors_));
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), previous_tabs, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->id == previous_pane && firstPane()->screen.frameId() > 0, runtime_wait_ms);
      QTRY_VERIFY(client_->display()->workspaceListCollapsed());
      QCOMPARE(client_->status()->error(), QString{});
    }

    Q_SLOT void cleanupTestCase() {
      QCOMPARE(errors_, QString{});
      engine_.reset();
      client_.reset();
      runtime_.terminate();
      if (!runtime_.waitForFinished()) {
        runtime_.kill();
        runtime_.waitForFinished();
      }
    }

    enum class TabDragInterruption : std::uint8_t {
      viewport,
      modal,
      focus,
    };

    void verifyTabDragCancellation(TabDragInterruption interruption) {
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
      const auto original = QString::number(firstPane()->location.tab_id);
      const auto size = window_->size();
      QStringList created;
      const auto restore = qScopeGuard([&] {
        window_->show();
        test::activateWindow(*window_);
        client_->commands()->execute(window_actions::Action::cancel);
        window_->resize(size);
        cleanupGestureTabs(created, original);
      });

      QVERIFY(prepareGestureTabs(created));
      const auto before = tabKeys();
      const auto* source = tabPill(created.front());
      const auto* destination = tabPill(created.back());

      QVERIFY(source != nullptr && destination != nullptr);
      const auto beginning = source->mapToScene({source->width() / 2, source->height() / 2}).toPoint();
      const auto ending = destination->mapToScene({destination->width() / 2, destination->height() / 2}).toPoint();

      sendMouse(*window_, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, beginning);
      sendMouse(*window_, QEvent::MouseMove, Qt::NoButton, Qt::LeftButton, ending);
      QVERIFY(client_->tabs()->capturedTab().hasValue());
      switch (interruption) {
      case TabDragInterruption::viewport:
        window_->resize(size.width() + 1, size.height());
        break;
      case TabDragInterruption::modal:
        client_->commands()->execute(window_actions::Action::palette);
        break;
      case TabDragInterruption::focus:
        test::hideWindow(*window_);
        QTRY_VERIFY_WITH_TIMEOUT(!window_->isActive(), runtime_wait_ms);
        window_->show();
        test::activateWindow(*window_);
        QTRY_VERIFY_WITH_TIMEOUT(window_->isActive(), runtime_wait_ms);
        break;
      }

      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QVERIFY(!client_->tabs()->capturedTab().hasValue());
      sendMouse(*window_, QEvent::MouseButtonRelease, Qt::LeftButton, Qt::NoButton, ending);
      QCOMPARE(tabKeys(), before);
      QCOMPARE(client_->status()->error(), QString{});
    }

    [[nodiscard]] QStringList tabKeys() const {
      QStringList result;

      for (int index = 0; index < client_->tabs()->rows()->rowCount(); ++index) {
        result.append(client_->tabs()->rows()->data(client_->tabs()->rows()->index(index, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString());
      }

      return result;
    }

    [[nodiscard]] QQuickItem* tabPill(const QString& key) const {
      for (auto* item : test::visualItems(*window_->contentItem(), QStringLiteral("tabPill"))) {
        if (item->property("tabKey").toString() == key) {
          return item;
        }
      }

      return nullptr;
    }

    bool prepareGestureTabs(QStringList& created) {
      constexpr int added_tabs = 2;

      for (int index = 0; index < added_tabs; ++index) {
        const auto count = client_->tabs()->rows()->rowCount();

        client_->commands()->execute(window_actions::Action::new_tab);
        if (!test::waitForGuiCondition([&] {
              return client_->tabs()->rows()->rowCount() == count + 1 && terminalReady();
            },
                runtime_wait_ms)) {
          return false;
        }

        created.append(QString::number(firstPane()->location.tab_id));
      }

      if (!test::waitForSynchronizedFrame(*window_, runtime_wait_ms)) {
        return false;
      }

      const auto* layout = window_->findChild<QQuickItem*>(QStringLiteral("tabStripLayout"));
      if (layout == nullptr || !test::waitForGuiCondition([&] {
            return !layout->property("transitioning").toBool();
          },
                                   runtime_wait_ms)) {
        return false;
      }

      return test::waitForSynchronizedFrame(*window_, runtime_wait_ms);
    }

    void cleanupGestureTabs(const QStringList& created, const QString& original) {
      for (const auto& key : created) {
        if (tabKeys().contains(key)) {
          client_->commands()->execute(window_actions::Action::close_tab, key);
          static_cast<void>(test::waitForGuiCondition([&] {
            return !tabKeys().contains(key);
          },
              runtime_wait_ms));
        }
      }

      client_->commands()->execute(window_actions::Action::select_tab, original);
    }

    void openWindow() {
      client_ = std::make_unique<ApplicationController>(memory_);
      client_->roster()->configureLaunch(directory_.path(), {QStringLiteral("/bin/sh")}, true);
      client_->loadConfiguration({}, {}, {});
      engine_ = std::make_unique<QQmlApplicationEngine>();
      connect(engine_.get(), &QQmlEngine::warnings, this, [this](const QList<QQmlError>& errors) {
        for (const auto& error : errors) {
          errors_ += error.toString() + QLatin1Char('\n');
        }
      });

      engine_->rootContext()->setContextProperty(QStringLiteral("telar"), client_.get());
      test::activateApplication();
      if (const auto* screen = QGuiApplication::primaryScreen()) {
        const auto position = screen->availableGeometry().topLeft();

        engine_->setInitialProperties({{QStringLiteral("x"), position.x()}, {QStringLiteral("y"), position.y()}});
      }

      engine_->loadFromModule(QStringLiteral("Telar.Gui"), QStringLiteral("Main"));
      if (engine_->rootObjects().isEmpty()) {
        return;
      }

      window_ = qobject_cast<QQuickWindow*>(engine_->rootObjects().first());
      if (window_ != nullptr) {
        client_->setWindow(*window_);
        client_->machines()->open(socket_);
      }
    }

    enum class HistoryView : std::uint8_t {
      results,
      inspector,
    };

    void verifyHistoryDelegateRetirement(const QString& query, int expected_rows) {
      seedHistoryPages();
      const telar::ds::Array entries{telar::ImportHistoryEntry{.started_at_ms = QDateTime::currentMSecsSinceEpoch(), .command = "echo GUI_BROWSER_PAGE_DELEGATE_SINGLE_TARGET"}};

      importHistory(entries, "gui-delegate-retirement");
      auto* const previous_controller = engine_->incubationController();
      QQmlIncubationController deferred;
      const auto restore = qScopeGuard([&] {
        engine_->setIncubationController(previous_controller);
        client_->commands()->execute(window_actions::Action::cancel);
      });

      engine_->setIncubationController(&deferred);
      client_->commands()->execute(window_actions::Action::history);
      client_->history()->search(QStringLiteral("GUI_BROWSER_PAGE"));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() > 0, runtime_wait_ms);
      auto* const results = window_->findChild<QQuickItem*>(QStringLiteral("historyResults"));
      if (results == nullptr) {
        QFAIL("Required history result view is missing");
      }

      QCOMPARE(qmlEngine(results), engine_.get());
      QCOMPARE(engine_->incubationController(), &deferred);
      const auto cache_buffer = results->property("cacheBuffer");
      const auto restore_cache = qScopeGuard([&] {
        results->setProperty("cacheBuffer", cache_buffer);
      });

      QVERIFY(results->setProperty("cacheBuffer", 0));
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      // Cache delegates incubate asynchronously, independently of flick distance.
      QVERIFY(results->setProperty("cacheBuffer", results->property("contentHeight")));
      QTRY_VERIFY_WITH_TIMEOUT(deferred.incubatingObjectCount() > 0, runtime_wait_ms);
      const auto retained_snapshot = expected_rows == client_->history()->rows()->rowCount();
      const auto existing = test::visualItems(*results, QStringLiteral("historyResult"));

      QVERIFY(!existing.isEmpty());
      const QPointer<QQuickItem> retained{existing.front()};
      const QSignalSpy removed{client_->history()->rows(), &QAbstractItemModel::rowsRemoved};

      QTest::failOnWarning(QRegularExpression{QStringLiteral("DelegateModel::cancel:.*")});
      client_->history()->search(query);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() == expected_rows, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QCOMPARE(results->property("count").toInt(), expected_rows);
      if (retained_snapshot) {
        QVERIFY(removed.isEmpty());
        QVERIFY(!retained.isNull());
        QTRY_VERIFY_WITH_TIMEOUT(([&] {
          deferred.incubateFor(50);

          return deferred.incubatingObjectCount() == 0;
        })(),
            runtime_wait_ms);

        const auto delivered = test::visualItems(*results, QStringLiteral("historyResult"));

        QVERIFY(!delivered.isEmpty());
        for (const auto* item : delivered) {
          const auto index = item->property("index").toInt();

          QVERIFY(index >= 0 && index < expected_rows);
          const auto record = client_->history()->rows()->data(client_->history()->rows()->index(index, 0), ListModel::record_role).toMap();

          QVERIFY(record.value(QStringLiteral("command")).toString().contains(query));
          QCOMPARE(item->property("record").toMap(), record);
        }
      }

      QCOMPARE(deferred.incubatingObjectCount(), 0);
    }

    void verifyHistoryCompositionEscape(HistoryView view) {
      const auto inspecting = view == HistoryView::inspector;

      client_->commands()->execute(window_actions::Action::history);
      const auto restore = qScopeGuard([this] {
        client_->commands()->execute(window_actions::Action::cancel);
      });

      const auto query = QStringLiteral("GUI_HISTORY_FIXTURE");

      client_->history()->search(query);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->history()->loading() && client_->history()->rows()->rowCount() > 0, runtime_wait_ms);
      if (inspecting) {
        client_->history()->execute(HistoryController::Action::inspect);
      }

      auto* search = window_->findChild<QQuickItem*>(QStringLiteral("commandSearch"));

      QVERIFY(search != nullptr);
      QVERIFY(QMetaObject::invokeMethod(search, "select", Q_ARG(int, 0), Q_ARG(int, 3)));
      search->forceActiveFocus();
      QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};

      QCoreApplication::sendEvent(search, &preedit);
      QTRY_VERIFY_WITH_TIMEOUT(search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Escape);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
      QCOMPARE(client_->history()->state().value(QStringLiteral("inspecting")).toBool(), inspecting);
      QTRY_VERIFY_WITH_TIMEOUT(!search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
      QCOMPARE(search->property("text").toString(), query);
      QCOMPARE(search->property("selectedText").toString(), query.first(3));
      QTest::keyClick(window_, Qt::Key_Escape);
      if (inspecting) {
        QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::history);
        QVERIFY(!client_->history()->state().value(QStringLiteral("inspecting")).toBool());
        QTest::keyClick(window_, Qt::Key_Escape);
      }

      QTRY_VERIFY_WITH_TIMEOUT((client_->dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::none), runtime_wait_ms);
    }

    // Saves the window when TELAR_GUI_TEST_ARTIFACT_DIRECTORY names a directory.
    void captureArtifact(const QString& name) {
      const auto directory = qEnvironmentVariable("TELAR_GUI_TEST_ARTIFACT_DIRECTORY");
      if (directory.isEmpty()) {
        return;
      }

      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QVERIFY(QDir{directory}.mkpath(QStringLiteral(".")));
      QVERIFY(window_->grabWindow().save(QDir{directory}.filePath(name + QStringLiteral(".png"))));
    }

    // QTest types whole strings only into widgets; a window takes one key at a time.
    void typeText(const QString& text) {
      for (const auto character : text) {
        QTest::keyClick(window_, character.toLatin1());
      }
    }

    void captureHistoryArtifact(const QString& name) {
      const auto directory_path = qEnvironmentVariable("TELAR_GUI_TEST_ARTIFACT_DIRECTORY");
      if (directory_path.isEmpty()) {
        return;
      }

      const QDir directory{directory_path};

      QVERIFY(directory.mkpath(QStringLiteral(".")));
      const auto* panel = window_->findChild<QQuickItem*>(QStringLiteral("historyPanel"));
      if (panel == nullptr) {
        QFAIL("Required history panel fixture is missing");
      }

      const auto* content = panel->parentItem();
      if (content == nullptr || content->parentItem() == nullptr) {
        QFAIL("Required history popup surface is missing");
      }

      QVERIFY(QTest::qWaitForWindowExposed(window_, runtime_wait_ms));
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto captured = content->parentItem()->grabToImage();

      QVERIFY(!captured.isNull());
      QTRY_VERIFY_WITH_TIMEOUT(!captured->image().isNull(), runtime_wait_ms);
      QVERIFY(captured->saveToFile(directory.filePath(name + QStringLiteral(".png"))));
    }

    bool waitForHistoryPresentation() {
      if (!test::waitForSynchronizedFrame(*window_, runtime_wait_ms)) {
        return false;
      }

      test::FramePacing::presentSwapped(*client_);

      const auto current = QTest::qWaitFor([this] {
        window_->update();
        test::FramePacing::presentSwapped(*client_);

        return test::HistoryPresentation::current(*client_);
      },
          runtime_wait_ms);
      if (!current) {
        test::HistoryPresentation::describe(*client_);
      }

      return current;
    }

    bool sendHistoryWheel(QPointF position, QPoint pixels, QPoint angles, Qt::ScrollPhase phase) {
      const auto source = pixels.isNull() ? Qt::MouseEventNotSynthesized : Qt::MouseEventSynthesizedBySystem;
      QWheelEvent event{position, window_->mapToGlobal(position.toPoint()), pixels, angles, Qt::NoButton, Qt::NoModifier, phase, false, source};

      event.setTimestamp(++history_wheel_timestamp_);
      QCoreApplication::sendEvent(window_, &event);

      return event.isAccepted();
    }

    void seedHistoryScroll() {
      const telar::ds::Array entries{
          telar::ImportHistoryEntry{.started_at_ms = 100, .command = "echo GUI_SCROLL_HISTORY_A_0"},
          telar::ImportHistoryEntry{.started_at_ms = 101, .command = "echo GUI_SCROLL_HISTORY_A_1"},
          telar::ImportHistoryEntry{.started_at_ms = 102, .command = "echo GUI_SCROLL_HISTORY_A_2"},
          telar::ImportHistoryEntry{.started_at_ms = 103, .command = "echo GUI_SCROLL_HISTORY_A_3"},
          telar::ImportHistoryEntry{.started_at_ms = 104, .command = "echo GUI_SCROLL_HISTORY_B_0"},
          telar::ImportHistoryEntry{.started_at_ms = 105, .command = "echo GUI_SCROLL_HISTORY_B_1"},
          telar::ImportHistoryEntry{.started_at_ms = 106, .command = "echo GUI_SCROLL_HISTORY_B_2"},
          telar::ImportHistoryEntry{.started_at_ms = 107, .command = "echo GUI_SCROLL_HISTORY_B_3"},
      };

      importHistory(entries, "gui-wheel-history");
    }

    void seedHistory() {
      const telar::ds::Array<telar::ImportHistoryEntry, 1> entries{{{.started_at_ms = 100, .command = "echo GUI_HISTORY_FIXTURE"}}};

      importHistory(entries, "gui-quick-test");
    }

    void seedHistoryPages() {
      constexpr auto entry_count = application::history::HistoryLimits::page_entries + 1;
      telar::ds::Array<std::string, entry_count> commands;
      telar::ds::Array<telar::ImportHistoryEntry, entry_count> entries{};

      for (std::size_t index = 0; index < entries.size(); ++index) {
        commands.atMut(index) = "echo GUI_BROWSER_PAGE_" + std::to_string(index);
        entries.atMut(index) = {.started_at_ms = static_cast<std::int64_t>(index) + 1, .command = commands[index]};
      }

      importHistory(entries, "gui-browser-page");
    }

    void importRetainedHistory() {
      const telar::ds::Array entries{
          telar::ImportHistoryEntry{.started_at_ms = 200, .command = "echo GUI_HISTORY_RETAINED_ONE"},
          telar::ImportHistoryEntry{.started_at_ms = 201, .command = "echo GUI_HISTORY_RETAINED_TWO"},
      };

      importHistory(entries, "gui-history-retained");
    }

    void importHistory(std::span<const telar::ImportHistoryEntry> entries, std::string_view source) {
      std::uint64_t completed_request = 0;
      QString decode_error;
      RuntimeConnection peer{memory_};
      const QSignalSpy connected{&peer, &RuntimeConnection::connected};

      connect(&peer, &RuntimeConnection::payloadReceived, &peer, [&](QByteArrayView payload) {
        try {
          const auto bytes = telar::byteView({payload.data(), static_cast<std::size_t>(payload.size())});

          completed_request = telar::Codec::decode<telar::RequestCompleted>(bytes).request_id;
        } catch (const std::exception& error) {
          decode_error = QString::fromUtf8(error.what());
        }
      });

      peer.open(socket_);
      QTRY_VERIFY_WITH_TIMEOUT(!connected.isEmpty() || !peer.error().isEmpty(), runtime_wait_ms);
      QCOMPARE(peer.error(), QString{});
      QVERIFY(!connected.isEmpty());
      constexpr std::size_t maximum_import_entries = 64;
      std::size_t offset = 0;
      std::uint64_t request_id = 0;

      while (offset < entries.size()) {
        const auto count = std::min(entries.size() - offset, maximum_import_entries);

        peer.send(telar::ImportHistory{.request_id = ++request_id, .source = source, .base_sequence = offset, .entries = entries.subspan(offset, count)});
        QTRY_VERIFY_WITH_TIMEOUT(completed_request == request_id || !decode_error.isEmpty() || !peer.error().isEmpty(), runtime_wait_ms);
        QCOMPARE(decode_error, QString{});
        QCOMPARE(peer.error(), QString{});
        QCOMPARE(completed_request, request_id);
        offset += count;
      }
    }

    void verifyTerminalFrameAdmission(TerminalSuppression suppression) {
      auto* terminal = terminalIn(window_->contentItem());
      const auto* pane = firstPane();
      if (terminal == nullptr || pane == nullptr) {
        QFAIL("Required terminal and pane fixtures are missing");
      }

      QTRY_COMPARE_WITH_TIMEOUT(pane->acknowledged_frame, pane->screen.frameId(), runtime_wait_ms);
      const auto restore = qScopeGuard([terminal] {
        terminal->setVisible(true);
        terminal->setFlag(QQuickItem::ItemHasContents, true);
        terminal->update();
      });

      terminal->setVisible(suppression != TerminalSuppression::hidden);
      terminal->setFlag(QQuickItem::ItemHasContents, suppression != TerminalSuppression::no_contents);
      test::FramePacing::presentSwapped(*client_);
      const auto acknowledged = pane->acknowledged_frame;
      const auto previous_frame = pane->screen.frameId();

      client_->terminals()->input(pane->id, QByteArrayLiteral("printf 'DEFERRED_TERMINAL_FRAME\\n'\r"));
      QTRY_VERIFY_WITH_TIMEOUT(pane->screen.frameId() > previous_frame, runtime_wait_ms);
      const auto pending_frame = pane->screen.frameId();

      QVERIFY(telar::gui::test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      test::FramePacing::presentSwapped(*client_);
      QCOMPARE(pane->acknowledged_frame, acknowledged);

      terminal->setVisible(true);
      terminal->setFlag(QQuickItem::ItemHasContents, true);
      terminal->update();
      QTRY_VERIFY_WITH_TIMEOUT(pane->acknowledged_frame >= pending_frame, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    template <typename Gesture>
    void verifyChildMouse(std::string_view expected, Gesture&& gesture, ChildMouseEncoding encoding = ChildMouseEncoding::sgr) {
      const auto original_tabs = client_->tabs()->rows()->rowCount();
      const auto* original = firstPane();

      QVERIFY(original != nullptr);
      const auto original_identity = original->id;

      client_->commands()->execute(window_actions::Action::new_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), original_tabs + 1, runtime_wait_ms);
      const auto restore = qScopeGuard([this, original_tabs, original_identity] {
        closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
      });

      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != original_identity, runtime_wait_ms);
      auto* terminal = terminalIn(window_->contentItem());
      const auto* pane = firstPane();
      if (terminal == nullptr || pane == nullptr) {
        QFAIL("Required terminal and pane fixtures are missing");
      }

      terminal->forceActiveFocus();
      beginChildMouseCapture(*terminal, expected.size(), encoding);
      std::forward<Gesture>(gesture)(*window_, *terminal);
      finishChildMouseCapture(pane->id, expected);
    }

    void beginChildMouseCapture(TerminalItem& terminal, std::size_t expected_bytes, ChildMouseEncoding encoding = ChildMouseEncoding::sgr) {
      const auto* pane = client_->pane(terminal.paneIdentity());

      QVERIFY(pane != nullptr);
      const auto capture_bytes = static_cast<qsizetype>(expected_bytes) + 1;
      const auto sgr = encoding == ChildMouseEncoding::sgr;
      const auto sgr_control = sgr ? QStringLiteral("\\033[?1006h") : QStringLiteral("\\033[?1006l");
      const auto capture = QStringLiteral("stty raw -echo; printf '\\033[2J\\033[H\\033[?1002h%1MOUSE_%s:' BEGIN; dd bs=1 count=%2 2>/dev/null | tee %3 | od -v -An -tx1 | tr -d ' \\n'; printf ':MOUSE_%s\\n\\033[?1002l\\033[?1006l' END; stty sane\r").arg(sgr_control).arg(capture_bytes).arg(shellLiteral(childMouseCapturePath(pane->id)));

      client_->terminals()->input(pane->id, capture.toUtf8());
      QTRY_VERIFY_WITH_TIMEOUT(pane->screen.mouse().sgr == sgr && pane->screen.mouse().tracking == telar::MouseTracking::button, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(pane->acknowledged_frame, pane->screen.frameId(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!terminal.prepareLinkPresentation(), runtime_wait_ms);
    }

    void finishChildMouseCapture(std::uint64_t pane_id, std::string_view expected) {
      const auto* pane = client_->pane(pane_id);

      QVERIFY(pane != nullptr);
      constexpr char padding_byte = ' ';

      client_->terminals()->input(pane->id, QByteArray{static_cast<qsizetype>(expected.size()) + 1, padding_byte});
      const auto expected_bytes = QByteArray{expected.data(), static_cast<qsizetype>(expected.size())} + padding_byte;
      const auto path = childMouseCapturePath(pane_id);

      QTRY_COMPARE_WITH_TIMEOUT(QFileInfo{path}.size(), expected_bytes.size(), runtime_wait_ms);
      QFile captured{path};

      QVERIFY2(captured.open(QIODevice::ReadOnly), qPrintable(captured.errorString()));
      QCOMPARE(captured.readAll(), expected_bytes);
      QTRY_VERIFY_WITH_TIMEOUT(!pane->screen.mouse().sgr && pane->screen.mouse().tracking == telar::MouseTracking::none, runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
    }

    [[nodiscard]] QString childMouseCapturePath(std::uint64_t pane_id) const {
      return directory_.filePath(QStringLiteral("mouse-%1.bin").arg(pane_id));
    }

    void dismissNotification() {
      const auto controls = [&] {
        return telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("notificationClose"));
      };

      QTRY_VERIFY(!controls().empty());
      const auto* close = controls().front();

      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, close->mapToScene({close->width() / 2, close->height() / 2}).toPoint());
      QTRY_VERIFY(controls().empty());
    }

    [[nodiscard]] bool terminalReady() const {
      const auto* pane = firstPane();
      const auto* terminal = window_ == nullptr ? nullptr : terminalIn(window_->contentItem());

      return pane != nullptr && pane->attached && pane->screen.frameId() != 0 && terminal != nullptr && terminal->paneIdentity() == pane->id;
    }

    void closeExtraTabs(int kept_count) {
      while (client_->tabs()->rows()->rowCount() > kept_count) {
        const auto count = client_->tabs()->rows()->rowCount();

        client_->commands()->execute(window_actions::Action::close_tab);
        const auto closed = QTest::qWaitFor([this, count] {
          return client_->tabs()->rows()->rowCount() < count;
        },
            runtime_wait_ms);

        QVERIFY2(closed, "Temporary tabs must close during test cleanup");
      }
    }

    void closeTemporaryTab(TabRestorePoint destination) {
      const auto* source = client_->pane(destination.pane_id);

      QVERIFY2(source != nullptr, "Temporary tab cleanup must retain its source pane");
      const auto source_tab = source->location.tab_id;

      client_->commands()->execute(window_actions::Action::close_tab);
      const auto closed = QTest::qWaitFor([this, destination] {
        return client_->tabs()->rows()->rowCount() == destination.count;
      },
          runtime_wait_ms);

      QVERIFY2(closed, "The temporary tab must close before restoring its source");
      // Closing selects an adjacent tab; this fixture may have started elsewhere.
      client_->commands()->execute(window_actions::Action::select_tab, QString::number(source_tab));
      const auto restored = QTest::qWaitFor([this, destination] {
        return client_->tabs()->rows()->rowCount() == destination.count && terminalReady() && firstPane()->id == destination.pane_id;
      },
          runtime_wait_ms);

      QVERIFY2(restored, "The temporary tab must close and restore its source pane");
    }

    void sendTextKeys(QLatin1StringView text) {
      for (const QChar character : text) {
        const auto key = character.toUpper().unicode();
        QKeyEvent press{QEvent::KeyPress, key, Qt::NoModifier, QString{character}};
        QKeyEvent release{QEvent::KeyRelease, key, Qt::NoModifier, QString{character}};

        QCoreApplication::sendEvent(window_, &press);
        QCoreApplication::sendEvent(window_, &release);
      }
    }

    void verifyComponentMeters() const {
      const auto* detailed_meter = componentItem(QStringLiteral("meter_row"), QStringLiteral("Daily quota λ"));

      QVERIFY(detailed_meter != nullptr);
      const auto* meter_label = detailed_meter->findChild<QQuickItem*>(QStringLiteral("componentMeterLabel"));
      const auto* meter_detail = detailed_meter->findChild<QQuickItem*>(QStringLiteral("componentMeterDetail"));

      QVERIFY(meter_label != nullptr && meter_detail != nullptr);
      const auto label_bounds = meter_label->mapRectToScene(meter_label->boundingRect());
      const auto detail_bounds = meter_detail->mapRectToScene(meter_detail->boundingRect());

      QVERIFY(!label_bounds.intersects(detail_bounds));
      QVERIFY(detail_bounds.top() >= label_bounds.bottom());
      const auto* meter_track = detailed_meter->findChild<QQuickItem*>(QStringLiteral("componentMeterTrack"));
      const auto* meter_value = detailed_meter->findChild<QQuickItem*>(QStringLiteral("componentMeterValue"));

      QVERIFY(meter_track != nullptr && meter_value != nullptr);
      const auto track_bounds = meter_track->mapRectToScene(meter_track->boundingRect());
      const auto value_bounds = meter_value->mapRectToScene(meter_value->boundingRect());

      const auto meter_bounds = detailed_meter->mapRectToScene(detailed_meter->boundingRect());

      // The label and the value share the first line, the bar spans the row under them, and the
      // detail sits under the bar, all inside the row.
      QVERIFY(label_bounds.right() <= value_bounds.left());
      QCOMPARE(value_bounds.top(), label_bounds.top());
      QVERIFY(track_bounds.top() >= label_bounds.bottom());
      QVERIFY(detail_bounds.top() >= track_bounds.bottom());
      QCOMPARE(track_bounds.left(), meter_bounds.left());
      QCOMPARE(track_bounds.right(), meter_bounds.right());
      QCOMPARE(value_bounds.right(), meter_bounds.right());
      QVERIFY(detail_bounds.bottom() <= meter_bounds.bottom());
      QVERIFY(meter_value->width() >= meter_value->implicitWidth());
      QCOMPARE(meter_value->property("text").toString(), QStringLiteral("75%"));
      QCOMPARE(meter_label->property("text").toString(), QStringLiteral("Daily quota λ"));
      const auto* pace = detailed_meter->findChild<QQuickItem*>(QStringLiteral("componentMeterPace"));

      QVERIFY(pace != nullptr && pace->isVisible());
      QVERIFY(pace->mapRectToScene(pace->boundingRect()).left() >= detail_bounds.right());
      const auto* simple_meter = componentItem(QStringLiteral("meter_row"), QStringLiteral("Session"));

      QVERIFY(simple_meter != nullptr);
      QVERIFY(simple_meter->height() < detailed_meter->height());
      QVERIFY(!simple_meter->findChild<QQuickItem*>(QStringLiteral("componentMeterPace"))->isVisible());
    }

    [[nodiscard]] bool configuredKeyboardGroupsReady() const {
      const auto generation = client_->components()->bars().value(QStringLiteral("left")).toMap().value(QStringLiteral("generation")).toString();
      const auto* first = componentGroup(QStringLiteral("First keyboard group"));
      const auto* second = componentGroup(QStringLiteral("Second keyboard group"));
      const auto* first_label = componentItem(QStringLiteral("label"), QStringLiteral("First keyboard group"));
      const auto* second_label = componentItem(QStringLiteral("label"), QStringLiteral("Second keyboard group"));
      if (first == nullptr || second == nullptr || first_label == nullptr || second_label == nullptr) {
        return false;
      }

      const QRectF first_rect{first->mapToScene(QPointF{}), first->size()};
      const QRectF second_rect{second->mapToScene(QPointF{}), second->size()};

      return first->property("surface").toMap().value(QStringLiteral("generation")).toString() == generation && second->property("surface").toMap().value(QStringLiteral("generation")).toString() == generation && first_rect.width() >= first_label->implicitWidth() && second_rect.width() >= second_label->implicitWidth() && second_rect.left() >= first_rect.right();
    }

    void verifyGroupTabFocusTransitions() {
      const auto tabs = client_->tabs()->rows()->rowCount();
      const auto pane = firstPane()->id;
      const auto cleanup = qScopeGuard([this, tabs] {
        closeExtraTabs(tabs);
      });

      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* tab = tabPill(QString::number(firstPane()->location.tab_id));

      QVERIFY(tab != nullptr);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, tab->mapToScene(tab->boundingRect().center()).toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(terminalIn(window_->contentItem()) != nullptr && terminalIn(window_->contentItem())->hasActiveFocus(), runtime_wait_ms);
      auto* group = componentGroup(QStringLiteral("First keyboard group"));

      QVERIFY(group != nullptr);
      group->forceActiveFocus(Qt::TabFocusReason);
      const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;

      QTest::keyClick(window_, Qt::Key_B, control);
      QVERIFY(client_->status()->prefixPending());
      QTest::keyClick(window_, Qt::Key_C);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), tabs + 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != pane, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalIn(window_->contentItem()) != nullptr && terminalIn(window_->contentItem())->hasActiveFocus(), runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::close_tab);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rows()->rowCount(), tabs, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == pane, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalIn(window_->contentItem()) != nullptr && terminalIn(window_->contentItem())->hasActiveFocus(), runtime_wait_ms);
    }

    void verifyGroupPaneHeaderFocus() {
      QCOMPARE(client_->panes()->rows()->rowCount(), 1);
      telar::ds::Option<std::uint64_t> created;
      const auto cleanup = qScopeGuard([this, &created] {
        if (created.hasValue() && client_->panes()->rows()->rowCount() > 1) {
          client_->commands()->execute(window_actions::Action::close_pane, QString::number(*created));
          static_cast<void>(test::waitForGuiCondition([this] {
            return client_->panes()->rows()->rowCount() == 1;
          },
              runtime_wait_ms));
        }
      });

      client_->commands()->execute(window_actions::Action::split_horizontal);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 2, runtime_wait_ms);
      created = client_->panes()->rows()->data(client_->panes()->rows()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString().toULongLong();
      const auto focused = [this, &created] {
        const auto* item = qobject_cast<TerminalItem*>(window_->activeFocusItem());

        return item != nullptr && item->paneIdentity() == *created;
      };

      QTRY_VERIFY_WITH_TIMEOUT(focused(), runtime_wait_ms);
      const QPointer<TerminalItem> target{qobject_cast<TerminalItem*>(window_->activeFocusItem())};
      auto* group = componentGroup(QStringLiteral("First keyboard group"));

      QVERIFY(group != nullptr);
      group->forceActiveFocus(Qt::TabFocusReason);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      // The header sits beside the terminal's viewport, inside the pane.
      const auto labels = test::visualItems(*target->parentItem()->parentItem(), QStringLiteral("paneProgram"));

      QCOMPARE(labels.size(), 1);
      const auto* label = labels.front();

      QVERIFY(label->isVisible() && label->width() > 0);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, label->mapToScene(label->boundingRect().center()).toPoint());
      QTRY_VERIFY_WITH_TIMEOUT(target != nullptr && target->hasActiveFocus(), runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::close_pane, QString::number(*created));
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalIn(window_->contentItem()) != nullptr && terminalIn(window_->contentItem())->hasActiveFocus(), runtime_wait_ms);
    }

    void verifyAccessibleComponentName(features::components::Kind kind, const QString& caption, std::string_view name) {
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(kind, caption) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* interface = QAccessible::queryAccessibleInterface(componentActionItem(kind, caption));
      if (interface == nullptr) {
        QFAIL("The configured control has no accessible interface");
      }

      QCOMPARE(interface->role(), QAccessible::Button);
      QCOMPARE(interface->text(QAccessible::Name), QString::fromUtf8(name.data(), static_cast<qsizetype>(name.size())));
    }

    static void writeComponentPlugin(const QTemporaryDir& directory) {
      QVERIFY(QDir{directory.path()}.mkdir(QStringLiteral("example")));
      writeTestFile(directory.filePath(QStringLiteral("example/plugin.json")), R"({"api_version":1,"id":"sample","version":"1","entry":"main.lua","source":{"url":"fixture","revision":"1"},"actions":["sidebar","workspaces"],"capabilities":[]})");
      writeTestFile(directory.filePath(QStringLiteral("example/main.lua")), "local t=require('telar');return {actions={sidebar=function()return t.action.toggle_sidebar()end,workspaces=function()return t.action.toggle_workspace_list()end}}");
    }

    void verifyPluginCaptionRefresh(features::components::Kind kind, bool pointer) {
      const auto sidebar = client_->display()->sidebarVisible();
      const auto cleanup = qScopeGuard([this, sidebar] {
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
        if (client_->display()->sidebarVisible() != sidebar) {
          client_->commands()->execute(window_actions::Action::toggle_sidebar);
        }
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      writeComponentPlugin(directory);
      QVERIFY(!QTest::currentTestFailed());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      const auto element = kind == features::components::Kind::button ? QStringLiteral("ui.button({text=caption,action=action})") : QStringLiteral("ui.group({on_click=action,ui.label(caption)})");
      const auto config = QStringLiteral(R"(
      local t=require('telar');local ui=t.ui;local renders=0
      return {api_version=2,plugins={{path='example'}},client={keybindings={t.bind_global({'alt+u'},t.action.open_panel('source'))},
        panels={source=t.panel({title='Plugin source',render=function()
          renders=renders+1;local caption='Stable plugin '..renders;local action=t.action.plugin{plugin='sample',action='sidebar'};return %1
        end})},
      }}
    )")
                              .arg(element)
                              .toUtf8();

      writeTestFile(path, config.constData());
      client_->loadConfiguration(path, {}, {}, directory.filePath(QStringLiteral("trust.json")));
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(kind, QStringLiteral("Stable plugin 1")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const QPointer<QQuickItem> before{componentActionItem(kind, QStringLiteral("Stable plugin 1"))};

      before->forceActiveFocus(Qt::TabFocusReason);
      QTRY_VERIFY_WITH_TIMEOUT(before->hasActiveFocus(), runtime_wait_ms);
      const auto center = before->mapToScene(before->boundingRect().center()).toPoint();
      bool pressed = pointer;
      const auto release = qScopeGuard([&] {
        if (pressed) {
          QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
        }
      });

      if (pointer) {
        QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, center);
      }

      const auto revision = client_->components()->panel().value(QStringLiteral("revision")).toString();

      client_->components()->refreshPanel();
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("revision")).toString() != revision, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(kind, QStringLiteral("Stable plugin 2")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QCOMPARE(componentActionItem(kind, QStringLiteral("Stable plugin 2")), before.data());
      QVERIFY(before->hasActiveFocus());
      if (pointer) {
        QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
        pressed = false;
      } else {
        QTest::keyClick(window_, Qt::Key_Space);
      }

      QTRY_VERIFY_WITH_TIMEOUT(test::ComponentActions::pluginIdle(*client_), runtime_wait_ms);
      QCOMPARE(client_->display()->sidebarVisible(), !sidebar);
      QCOMPARE(client_->status()->error(), QString{});
    }

    void verifyPluginTargetMutation(bool pointer) {
      const auto sidebar = client_->display()->sidebarVisible();
      const auto collapsed = client_->display()->workspaceListCollapsed();

      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(features::components::Kind::button, QStringLiteral("Mutable plugin")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      auto* button = componentActionItem(features::components::Kind::button, QStringLiteral("Mutable plugin"));

      button->forceActiveFocus(Qt::TabFocusReason);
      const auto center = button->mapToScene(button->boundingRect().center()).toPoint();
      bool pressed = pointer;
      const auto release = qScopeGuard([&] {
        if (pressed) {
          QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
        }
      });

      if (pointer) {
        QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, center);
      }

      const auto revision = client_->components()->panel().value(QStringLiteral("revision")).toString();

      QTest::keyClick(window_, Qt::Key_M, Qt::AltModifier);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("revision")).toString(), revision);
      QCOMPARE(client_->status()->error(), QString{});
      if (pointer) {
        QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
        pressed = false;
      } else {
        QTest::keyClick(window_, Qt::Key_Space);
      }

      // The button runs the action it was rendered with: the Lua thread resolved it then, so
      // mutating the table afterwards cannot redirect a click on what is already on screen.
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), !sidebar, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(test::ComponentActions::pluginIdle(*client_), runtime_wait_ms);
      QCOMPARE(client_->display()->workspaceListCollapsed(), collapsed);
      QCOMPARE(client_->status()->error(), QString{});
      client_->components()->refreshPanel();
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("revision")).toString() != revision, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(features::components::Kind::button, QStringLiteral("Mutable plugin")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* fresh = componentActionItem(features::components::Kind::button, QStringLiteral("Mutable plugin"));

      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, fresh->mapToScene(fresh->boundingRect().center()).toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->workspaceListCollapsed(), !collapsed, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(test::ComponentActions::pluginIdle(*client_), runtime_wait_ms);
      QCOMPARE(client_->display()->sidebarVisible(), !sidebar);
      QCOMPARE(client_->status()->error(), QString{});
      client_->commands()->execute(window_actions::Action::toggle_sidebar);
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), sidebar, runtime_wait_ms);
    }

    void verifyDefinitionCaptionRefresh(features::components::Kind kind, bool picker, bool pointer) {
      const auto cleanup = qScopeGuard([this] {
        client_->components()->closePick();
        client_->components()->closePanel();
        client_->loadConfiguration({}, {}, {});
      });

      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto path = directory.filePath(QStringLiteral("config.lua"));
      const auto action = picker ? QStringLiteral("t.action.pick('destination')") : QStringLiteral("t.action.open_panel('destination')");
      const auto element = kind == features::components::Kind::button ? QStringLiteral("ui.button({text=caption,action=action})") : QStringLiteral("ui.group({on_click=action,ui.label(caption)})");
      const auto config = QStringLiteral(R"(
      local t=require('telar');local ui=t.ui;local renders=0
      return {api_version=2,client={keybindings={t.bind_global({'alt+u'},t.action.open_panel('source'))},
        panels={source=t.panel({title='Definition source',render=function()
          renders=renders+1;local caption='Stable target '..renders;local action=%1;return %2
        end}),destination=t.panel({title='Destination',render=function()return ui.text('Opened')end})},
        picks={destination=t.pick({title='Destination',items={'One'},on_select={'/usr/bin/true','{}'}})},
      }}
    )")
                              .arg(action, element)
                              .toUtf8();

      writeTestFile(path, config.constData());
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(kind, QStringLiteral("Stable target 1")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const QPointer<QQuickItem> before{componentActionItem(kind, QStringLiteral("Stable target 1"))};

      before->forceActiveFocus(Qt::TabFocusReason);
      QTRY_VERIFY_WITH_TIMEOUT(before->hasActiveFocus(), runtime_wait_ms);
      const auto center = before->mapToScene(before->boundingRect().center()).toPoint();
      bool pressed = pointer;
      const auto release = qScopeGuard([&] {
        if (pressed) {
          QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
        }
      });

      if (pointer) {
        QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, center);
      }

      const auto revision = client_->components()->panel().value(QStringLiteral("revision")).toString();

      client_->components()->refreshPanel();
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("revision")).toString() != revision, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(kind, QStringLiteral("Stable target 2")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QCOMPARE(componentActionItem(kind, QStringLiteral("Stable target 2")), before.data());
      QTRY_VERIFY_WITH_TIMEOUT(before->hasActiveFocus(), runtime_wait_ms);
      if (pointer) {
        QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
        pressed = false;
      } else {
        QTest::keyClick(window_, Qt::Key_Space);
      }

      if (picker) {
        QTRY_VERIFY_WITH_TIMEOUT(client_->components()->pick().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
        QCOMPARE(client_->components()->pick().value(QStringLiteral("title")).toString(), QStringLiteral("Destination"));
      } else {
        QTRY_COMPARE_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("Destination"), runtime_wait_ms);
      }

      QCOMPARE(client_->status()->error(), QString{});
    }

    void verifyDefinitionTargetMutation(bool pointer) {
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(features::components::Kind::button, QStringLiteral("Mutable target")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      auto* button = componentActionItem(features::components::Kind::button, QStringLiteral("Mutable target"));

      button->forceActiveFocus(Qt::TabFocusReason);
      const auto center = button->mapToScene(button->boundingRect().center()).toPoint();
      bool pressed = pointer;
      const auto release = qScopeGuard([&] {
        if (pressed) {
          QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
        }
      });

      if (pointer) {
        QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, center);
      }

      const auto revision = client_->components()->panel().value(QStringLiteral("revision")).toString();

      QTest::keyClick(window_, Qt::Key_M, Qt::AltModifier);
      QCOMPARE(client_->components()->panel().value(QStringLiteral("revision")).toString(), revision);
      QCOMPARE(client_->status()->error(), QString{});
      if (pointer) {
        QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
        pressed = false;
      } else {
        QTest::keyClick(window_, Qt::Key_Space);
      }

      // The rendered button keeps the destination it was resolved with; only a new render
      // picks up the mutated table.
      QTRY_COMPARE_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("First destination"), runtime_wait_ms);
      QCOMPARE(client_->status()->error(), QString{});
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_COMPARE_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("Definition source"), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(features::components::Kind::button, QStringLiteral("Mutable target")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      const auto* fresh = componentActionItem(features::components::Kind::button, QStringLiteral("Mutable target"));

      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, fresh->mapToScene(fresh->boundingRect().center()).toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("title")).toString(), QStringLiteral("Second destination"), runtime_wait_ms);
    }

    void verifyComponentCaptionMouseRefresh(features::components::Kind kind, bool sidebar) {
      const QPointer<QQuickItem> before{componentActionItem(kind, QStringLiteral("Stable target 2"))};

      QVERIFY(!before.isNull());
      const auto center = before->mapToScene(before->boundingRect().center()).toPoint();

      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, center);
      bool pressed = true;
      const auto release = qScopeGuard([&] {
        if (pressed) {
          QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
        }
      });

      const auto revision = client_->components()->panel().value(QStringLiteral("revision")).toString();

      client_->components()->refreshPanel();
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("revision")).toString() != revision, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(kind, QStringLiteral("Stable target 3")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QCOMPARE(componentActionItem(kind, QStringLiteral("Stable target 3")), before.data());
      QVERIFY(before->mapRectToScene(before->boundingRect()).contains(center));
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
      pressed = false;
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), !sidebar, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::toggle_sidebar);
      QCOMPARE(client_->display()->sidebarVisible(), sidebar);
    }

    void verifyConfiguredActionCapture(features::components::Kind kind, const QString& path, bool sidebar, bool collapsed) {
      const auto* target = componentActionItem(kind, QStringLiteral("Stable target"));
      const auto center = target->mapToScene(target->boundingRect().center()).toPoint();
      bool pressed = false;
      const auto release = qScopeGuard([&] {
        if (pressed) {
          QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
        }
      });

      const auto refresh = [this] {
        const auto revision = client_->components()->panel().value(QStringLiteral("revision")).toString();

        client_->components()->refreshPanel();
        QTRY_VERIFY_WITH_TIMEOUT(client_->components()->panel().value(QStringLiteral("revision")).toString() != revision, runtime_wait_ms);
        QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      };

      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, center);
      pressed = true;
      refresh();
      QVERIFY(!QTest::currentTestFailed());
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
      pressed = false;
      QCOMPARE(client_->display()->sidebarVisible(), sidebar);
      QCOMPARE(client_->display()->workspaceListCollapsed(), collapsed);
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, center);
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->workspaceListCollapsed(), !collapsed, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::toggle_workspace_list);
      QCOMPARE(client_->display()->workspaceListCollapsed(), collapsed);

      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, center);
      pressed = true;
      refresh();
      QVERIFY(!QTest::currentTestFailed());
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
      pressed = false;
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->workspaceListCollapsed(), !collapsed, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::toggle_workspace_list);
      QCOMPARE(client_->display()->workspaceListCollapsed(), collapsed);

      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, center);
      pressed = true;
      refresh();
      QVERIFY(!QTest::currentTestFailed());
      refresh();
      QVERIFY(!QTest::currentTestFailed());
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
      pressed = false;
      QCOMPARE(client_->display()->sidebarVisible(), sidebar);
      QCOMPARE(client_->display()->workspaceListCollapsed(), collapsed);

      QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, center);
      pressed = true;
      client_->loadConfiguration(path, {}, {});
      QVERIFY2(client_->status()->error().isEmpty(), qPrintable(client_->status()->error()));
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(componentActionItem(kind, QStringLiteral("Stable target")) != nullptr, runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, center);
      pressed = false;
      QCOMPARE(client_->display()->sidebarVisible(), sidebar);
      QCOMPARE(client_->display()->workspaceListCollapsed(), collapsed);
      target = componentActionItem(kind, QStringLiteral("Stable target"));
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, target->mapToScene(target->boundingRect().center()).toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(client_->display()->sidebarVisible(), !sidebar, runtime_wait_ms);
      client_->commands()->execute(window_actions::Action::toggle_sidebar);
      QCOMPARE(client_->display()->sidebarVisible(), sidebar);
    }

    [[nodiscard]] QQuickItem* componentActionItem(features::components::Kind kind, const QString& caption) const {
      if (kind == features::components::Kind::group) {
        return componentGroup(caption);
      }

      auto* node = componentItem(QStringLiteral("button"), caption);
      if (node != nullptr) {
        for (auto* item : test::visualItems(*node, QString{})) {
          if (item->isVisible() && item->property("identity").isValid() && item->property("text").toString() == caption) {
            return item;
          }
        }
      }

      return nullptr;
    }

    [[nodiscard]] QQuickItem* componentGroup(const QString& caption) const {
      auto* label = componentItem(QStringLiteral("label"), caption);

      for (auto* item = label; item != nullptr; item = item->parentItem()) {
        if (item->property("node").toMap().value(QStringLiteral("kind")).toString() == QStringLiteral("group")) {
          return item;
        }
      }

      return nullptr;
    }

    [[nodiscard]] static QObject* componentTooltip(const QQuickItem& node) {
      return node.findChild<QObject*>(QStringLiteral("componentTooltip"), Qt::FindDirectChildrenOnly);
    }

    [[nodiscard]] static QQuickItem* popupCloseButton(const QObject& popup) {
      for (auto* item : popup.findChildren<QQuickItem*>()) {
        if (item->inherits("QQuickAbstractButton") && (item->property("text").toString() == QStringLiteral("×") || item->objectName() == QStringLiteral("overlayClose"))) {
          return item;
        }
      }

      return nullptr;
    }

    [[nodiscard]] QQuickItem* componentPanelCloseButton() const {
      const auto* popup = window_->findChild<QObject*>(QStringLiteral("configuredPanel"));

      return popup != nullptr ? popupCloseButton(*popup) : nullptr;
    }

    [[nodiscard]] bool componentButtonFocused(const QString& caption) const {
      const auto* node = componentItem(QStringLiteral("button"), caption);
      const auto* focus = window_->activeFocusItem();

      return node != nullptr && focus != nullptr && (node == focus || node->isAncestorOf(focus));
    }

    void verifyConfiguredPickReturnsKeyboardFocus() {
      auto* close = componentPanelCloseButton();

      QVERIFY(close != nullptr);
      QTest::keyClick(window_, Qt::Key_U, Qt::AltModifier);
      QTRY_VERIFY_WITH_TIMEOUT(componentItem(QStringLiteral("button"), QStringLiteral("Close with keyboard")) != nullptr, runtime_wait_ms);
      close->forceActiveFocus(Qt::TabFocusReason);
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_VERIFY_WITH_TIMEOUT(componentButtonFocused(QStringLiteral("Toggle sidebar")), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_VERIFY_WITH_TIMEOUT(componentButtonFocused(QStringLiteral("Close with keyboard")), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Tab);
      QTRY_VERIFY_WITH_TIMEOUT(componentButtonFocused(QStringLiteral("Choose mode")), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Return);
      QTRY_VERIFY_WITH_TIMEOUT(client_->components()->pick().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      const auto* query = window_->findChild<QQuickItem*>(QStringLiteral("configuredPickQuery"));

      QVERIFY(query != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(query->hasActiveFocus(), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Escape);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->pick().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
      const auto* pick = window_->findChild<QObject*>(QStringLiteral("configuredPick"));

      QVERIFY(pick != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(!pick->property("visible").toBool(), runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
      QVERIFY(client_->components()->panel().value(QStringLiteral("open")).toBool());
      QTRY_VERIFY_WITH_TIMEOUT(componentButtonFocused(QStringLiteral("Choose mode")), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Tab, Qt::ShiftModifier);
      QTRY_VERIFY_WITH_TIMEOUT(componentButtonFocused(QStringLiteral("Close with keyboard")), runtime_wait_ms);
      QTest::keyClick(window_, Qt::Key_Enter, Qt::KeypadModifier);
      QTRY_VERIFY_WITH_TIMEOUT(!client_->components()->panel().value(QStringLiteral("open")).toBool(), runtime_wait_ms);
    }

    [[nodiscard]] QQuickItem* componentItem(const QString& kind, const QString& text = {}) const {
      for (auto* item : test::visualItems(*window_->contentItem(), QString{})) {
        const auto node = item->property("node").toMap();
        if (item->isVisible() && node.value(QStringLiteral("kind")).toString() == kind && (text.isEmpty() || node.value(QStringLiteral("text")).toString() == text)) {
          return item;
        }
      }

      return nullptr;
    }

    [[nodiscard]] const application::Pane<telar::Memory>* firstPane() const {
      if (client_->panes()->rows()->rowCount() == 0) {
        return nullptr;
      }

      const auto record = client_->panes()->rows()->data(client_->panes()->rows()->index(0, 0), ListModel::record_role).toMap();

      return client_->pane(record.value(QStringLiteral("key")).toString().toULongLong());
    }

    ApplicationMemory application_memory_;
    ApplicationAllocator& memory_ = application_memory_.memory();
    QTemporaryDir directory_;
    QProcess runtime_;
    QString socket_;
    QString errors_;
    std::unique_ptr<ApplicationController> client_;
    std::unique_ptr<QQmlApplicationEngine> engine_;
    QQuickWindow* window_ = nullptr;
    std::uint64_t history_wheel_timestamp_ = 0;
  };

}

int main(int argc, char** argv) {
  if (argc > 1 && std::string_view{argv[1]} == "--report-blocked") {
    return telar::gui::test::runAgentReportFixture(argc, argv);
  }

  QGuiApplication const application{argc, argv};

  QQuickStyle::setStyle(QStringLiteral("Basic"));
  QuickTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "quick_test.moc"
