#include "agent_report_fixture.hpp"
#include "appearance_fixture.hpp"
#include "application/dependencies.hpp"
#include "application/notification_item.hpp"
#include "application/records.hpp"
#include "clipboard_fixture.hpp"
#include "core/terminal_size.hpp"
#include "frame_fixture.hpp"
#include "frame_pacing_fixture.hpp"
#include "graphics/placement.hpp"
#include "gui_wait.hpp"
#include "history/browser.hpp"
#include "history/page_storage.hpp"
#include "history_presentation_fixture.hpp"
#include "input/click_tracker.hpp"
#include "json_fixture.hpp"
#include "links/link_grid.hpp"
#include "list_model.hpp"
#include "platform/awake_clock.hpp"
#include "platform/window.hpp"
#include "platform/window_activation.hpp"
#include "presentation/attention_fades.hpp"
#include "presentation/frame_pacer.hpp"
#include "presentation/history_card.hpp"
#include "presentation/history_path.hpp"
#include "projection.hpp"
#include "qml_fixture.hpp"
#include "qt/application.hpp"
#include "qt/key_adapter.hpp"
#include "qt/native_form_field.hpp"
#include "qt/native_mode_layout.hpp"
#include "qt/notification_layout.hpp"
#include "qt/pane_attention_value.hpp"
#include "qt/runtime_connection.hpp"
#include "qt/terminal_item.hpp"
#include "qt/window_animation_clock.hpp"
#include "screen_fixture.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_client/telar_client.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"
#include "text/json.hpp"
#include "ui/bundled_fonts.hpp"
#include <QClipboard>
#include <QCursor>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QInputMethodEvent>
#include <QList>
#include <QMimeData>
#include <QPointer>
#include <QProcess>
#include <QProcessEnvironment>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlExpression>
#include <QQuickStyle>
#include <QScreen>
#include <QSignalSpy>
#include <QSizeF>
#include <QTemporaryDir>
#include <QUrl>
#include <QWheelEvent>
#include <QWindow>
#include <QtCore/qbytearrayview.h>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qcoreapplication.h>
#include <QtCore/qcoreevent.h>
#include <QtCore/qhashfunctions.h>
#include <QtCore/qlist.h>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qscopeguard.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
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
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <optional>
#include <ranges>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

using telar::gui::test::requiredJsonField;
using telar::gui::test::screenGrid;
using telar::gui::test::screenText;
using telar::gui::test::ScreenTextLayout;

using namespace telar::gui;
using namespace telar::gui::qt;

constexpr int runtime_wait_ms = 10'000;
constexpr int frame_settle_ms = 100;
constexpr int chrome_font_pixels = 13;
constexpr qreal divider_drag_pixels = 60;
constexpr std::size_t response_capacity = 4096;

struct TabRestorePoint {
  int count = 0;
  std::uint64_t pane_id = 0;
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

QString modeTitle(const NativeModeLayout &mode) {
  const auto labels = mode.labels();

  return labels.empty() ? QString{} : labels.front().toMap().value(QStringLiteral("text")).toString();
}

void writeTestFile(const QString &path, const char *source) {
  QFile file{path};
  if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate) || file.write(source) < 0) {
    throw std::runtime_error{"Cannot write GUI integration fixture"};
  }
}

std::optional<std::uint32_t> logicalRowStart(const Screen<ApplicationAllocator> &screen, std::size_t requested_line) {
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

  return std::nullopt;
}

QString shellLiteral(QString text) {
  text.replace(QLatin1Char('\''), QLatin1StringView("'\\''"));

  return QLatin1Char('\'') + text + QLatin1Char('\'');
}

TerminalItem *terminalIn(QQuickItem *root) {
  QList<QQuickItem *> pending{root};
  while (!pending.isEmpty()) {
    auto *item = pending.takeLast();
    if (item == nullptr) {
      continue;
    }

    if (auto *terminal = qobject_cast<TerminalItem *>(item)) {
      return terminal;
    }

    const auto children = item->childItems();
    for (auto *child : children | std::views::reverse) {
      pending.append(child);
    }
  }

  return nullptr;
}

TerminalItem *focusedTerminalBeside(QQuickWindow &window, const TerminalItem &current) {
  TerminalItem *focused = nullptr;
  const bool ready = QTest::qWaitFor([&window, &current, &focused] {
    focused = qobject_cast<TerminalItem *>(window.activeFocusItem());

    return focused != nullptr && focused != &current;
  },
                                     runtime_wait_ms);

  return ready ? focused : nullptr;
}

QString windowObservation(const QQuickWindow &window) {
  QString result;
  QDebug stream{&result};
  const auto *terminal = qobject_cast<TerminalItem *>(window.activeFocusItem());
  stream.nospace() << "state=" << window.windowState() << " visibility=" << window.visibility() << " active=" << window.isActive() << " size=" << window.size() << " focused=" << window.activeFocusItem() << " focusedPane=" << (terminal == nullptr ? 0 : terminal->paneIdentity());

  return result;
}

QPoint cellCenter(const TerminalItem &terminal, CellPosition cell) {
  const auto size = terminal.cellSize();

  return terminal.mapToScene({(cell.x * size.width()) + (size.width() / 2), (cell.y * size.height()) + (size.height() / 2)}).toPoint();
}

void sendMouse(QQuickWindow &window, QEvent::Type phase, Qt::MouseButton button, Qt::MouseButtons held, QPoint position) {
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

  RecordedLinks(const RecordedLinks &) = delete;
  RecordedLinks &operator=(const RecordedLinks &) = delete;
  RecordedLinks(RecordedLinks &&) = delete;
  RecordedLinks &operator=(RecordedLinks &&) = delete;

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
  explicit CommandPeer(ApplicationAllocator &memory)
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

  void open(const QString &endpoint) {
    connection_.open(endpoint);
  }

  void request(telar::ClientAction action, std::uint64_t request_id, std::string_view text = {}, std::int64_t value = 0) {
    request(telar::ClientCommand{.request_id = request_id, .action = action, .value = value, .text = text});
  }

  void request(const telar::ClientCommand &message) {
    telar::RequestClientCommand command;
    static_cast<telar::ClientCommand &>(command) = message;
    command.route = route_;
    connection_.send(command);
  }

  void showNotification(const telar::ShowNotification &message) {
    connection_.send(message);
  }

  [[nodiscard]] bool ready() const noexcept {
    return route_.id != 0;
  }

  [[nodiscard]] const CommandOutcome &result() const noexcept {
    return result_;
  }

  [[nodiscard]] const QString &error() const noexcept {
    return error_;
  }

private:
  void consume(std::span<const telar::Byte> payload) {
    try {
      telar::DecodeStorage storage{storage_};
      if (payload.front() == static_cast<telar::Byte>(telar::ServerTag::client_list)) {
        selectClient(telar::Codec::decode<telar::ClientList>(payload, storage));
      } else if (payload.front() == static_cast<telar::Byte>(telar::ServerTag::client_command_result)) {
        const auto reply = telar::Codec::decode<telar::ClientCommandResult>(payload, storage);
        result_ = {.request_id = reply.request_id, .status = reply.status, .text = toQString(reply.text), .value = reply.value};
      }
    } catch (const std::exception &error) {
      error_ = QString::fromUtf8(error.what());
    }
  }

  void selectClient(const telar::ClientList &clients) {
    for (const auto &entry : clients.entries) {
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
  std::array<telar::Byte, response_capacity> storage_{};
};

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
    for (const auto &name : environment.keys()) {
      if (name.startsWith(QLatin1StringView("TELAR_"))) {
        environment.remove(name);
      }
    }

    environment.remove(QStringLiteral("ENV"));
    environment.remove(QStringLiteral("BASH_ENV"));
    environment.insert(QStringLiteral("TELAR_HISTORY"), directory_.filePath(QStringLiteral("history.db")));
    environment.insert(QStringLiteral("XDG_DATA_HOME"), directory_.filePath(QStringLiteral("data")));
    runtime_.setProcessEnvironment(environment);
    runtime_.start();
    QVERIFY(runtime_.waitForStarted());
    QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(socket_), runtime_wait_ms);
    ui::bundledFonts();
    QFont chrome_font{QStringLiteral("IBM Plex Sans")};
    chrome_font.setPixelSize(chrome_font_pixels);
    QGuiApplication::setFont(chrome_font);
    openWindow();
    QVERIFY2(window_ != nullptr, qPrintable(errors_));
    const auto external_window_ready = qEnvironmentVariable("TELAR_GUI_TEST_WINDOW_READY");
    if (!external_window_ready.isEmpty()) {
      QTRY_VERIFY2_WITH_TIMEOUT(QFileInfo::exists(external_window_ready), "External native window setup did not complete", runtime_wait_ms);
      QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
    }

    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 1, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->screen.frameId() > 0, runtime_wait_ms);
    seedHistory();
  }

  Q_SLOT void terminalInputAndRendering() {
    auto *terminal = terminalIn(window_->contentItem());
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

      return std::ranges::any_of(lines, [](const auto &line) {
        return line.trimmed() == QLatin1StringView("TELAR_QT_INPUT_OK");
      });
    };

    QTRY_VERIFY2_WITH_TIMEOUT(printed(), qPrintable(screenText(firstPane()->screen)), runtime_wait_ms);

    const auto image = window_->grabWindow();
    QVERIFY(!image.isNull());
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void singlePaneUsesAllCompleteWorkbenchCells() {
    const auto *terminal = terminalIn(window_->contentItem());
    QVERIFY(terminal != nullptr);
    QCOMPARE(client_->panes()->rowCount(), 1);
    const auto fits_current_workbench = [this, terminal] {
      const auto bounds = client_->windowGeometry().value(QStringLiteral("terminal")).toRectF();
      const auto density = window_->effectiveDevicePixelRatio();
      const auto resolved = client_->resolveFont(density);
      const auto columns = static_cast<std::uint16_t>(std::floor(bounds.width() * density / resolved.grid.width));
      const auto rows = static_cast<std::uint16_t>(std::floor(bounds.height() * density / resolved.grid.height));
      const QSizeF expected{columns * resolved.grid.width / density, rows * resolved.grid.height / density};
      const auto bottom_right = bounds.topLeft() + QPointF{expected.width(), expected.height()};
      if (terminal->size() != expected || terminal->mapToScene(QPointF{}) != bounds.topLeft() || terminal->mapToScene(QPointF{expected.width(), expected.height()}) != bottom_right) {
        return false;
      }

      const auto *pane = firstPane();

      return pane != nullptr && pane->screen.columns() == columns && pane->screen.rows() == rows;
    };
    QVERIFY2(telar::gui::test::waitForGuiCondition(fits_current_workbench, runtime_wait_ms), qPrintable(QStringLiteral("window=%1x%2 terminal=%3x%4").arg(window_->width()).arg(window_->height()).arg(terminal->width()).arg(terminal->height())));
  }

  Q_SLOT void componentOwnership() {
    TerminalItem terminal;
    {
      Application isolated{memory_};
      terminal.setApplication(&isolated);
      QCOMPARE(terminal.application(), &isolated);
    }

    QCOMPARE(terminal.application(), nullptr);
  }

  Q_SLOT void qmlActionBindings() {
    auto *context = qmlContext(window_);
    if (context == nullptr) {
      QFAIL("The GUI window must have its QML context");
    }

    QQmlExpression open{context, window_, QStringLiteral("telar.execute(GuiController.Action.palette)")};
    static_cast<void>(open.evaluate());
    QVERIFY2(!open.hasError(), qPrintable(open.error().toString()));
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));

    QQmlExpression cancel{context, window_, QStringLiteral("telar.execute(GuiController.Action.cancel)")};
    static_cast<void>(cancel.evaluate());
    QVERIFY2(!cancel.hasError(), qPrintable(cancel.error().toString()));
    QCOMPARE(client_->dialog(), QString{});

    const auto tab_label = [&] {
      return client_->tabs()->data(client_->tabs()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("label")).toString();
    };
    const auto original_label = tab_label();
    client_->execute(Application::Action::rename_tab);
    QQmlExpression rename{context, window_, QStringLiteral("telar.submitDialog({text: 'QML renamed tab', path: ''})")};
    static_cast<void>(rename.evaluate());
    QVERIFY2(!rename.hasError(), qPrintable(rename.error().toString()));
    QTRY_COMPARE_WITH_TIMEOUT(tab_label(), QStringLiteral("QML renamed tab"), runtime_wait_ms);
    QCOMPARE(client_->dialog(), QString{});
    client_->execute(Application::Action::rename_tab);
    client_->submitDialog({{QStringLiteral("text"), original_label}, {QStringLiteral("path"), QString{}}});
    QTRY_COMPARE_WITH_TIMEOUT(tab_label(), original_label, runtime_wait_ms);

    client_->execute(Application::Action::palette);
    client_->searchPalette(QStringLiteral(">New tab"));
    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    if (search == nullptr) {
      QFAIL("Required command search fixture is missing");
    }

    search->forceActiveFocus();
    QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), QStringLiteral(">New tab"), runtime_wait_ms);
    QKeyEvent activate{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier};
    QCoreApplication::sendEvent(search, &activate);
    QTRY_COMPARE(client_->dialog(), QString{});
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), 2, runtime_wait_ms);
    client_->execute(Application::Action::close_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), 1, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->screen.frameId() > 0, runtime_wait_ms);
  }

  Q_SLOT void workspaceListVisibility() {
    const auto previous_state = window_->windowState();
    const auto restore_window = qScopeGuard([this, previous_state] {
      window_->setWindowState(previous_state);
    });
    if (client_->windowGeometry().value(QStringLiteral("rail")).toBool()) {
      window_->showFullScreen();
    }

    QTRY_VERIFY(!client_->windowGeometry().value(QStringLiteral("rail")).toBool());
    const auto *workspace_list = window_->findChild<QQuickItem *>(QStringLiteral("workspaceList"));
    auto *terminal = terminalIn(window_->contentItem());
    if (workspace_list == nullptr || terminal == nullptr) {
      QFAIL("Required workspace list and terminal fixtures are missing");
    }

    QTRY_VERIFY(workspace_list->isVisible());
    const auto focused_pane = firstPane()->id;
    const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
    QKeyEvent prefix{QEvent::KeyPress, Qt::Key_B, control};
    QKeyEvent collapse{QEvent::KeyPress, Qt::Key_W, Qt::NoModifier, QStringLiteral("w")};
    QCoreApplication::sendEvent(terminal, &prefix);
    QCoreApplication::sendEvent(terminal, &collapse);
    QVERIFY(client_->workspaceListCollapsed());
    QTRY_VERIFY(workspace_list->isVisible());
    QCOMPARE(firstPane()->id, focused_pane);

    client_->execute(Application::Action::toggle_workspace_list);
    QVERIFY(!client_->workspaceListCollapsed());
    QTRY_VERIFY(workspace_list->isVisible());
  }

  Q_SLOT void pointerSelection() {
    auto *clipboard = QGuiApplication::clipboard();
    auto saved_clipboard = test::copyClipboard();
    const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved_clipboard)] mutable {
      clipboard->setMimeData(saved.release());
    });
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    auto *terminal = terminalIn(window_->contentItem());
    const auto *pane = firstPane();
    QVERIFY(terminal != nullptr && pane != nullptr);
    constexpr auto path = QLatin1StringView("/tmp/telar/file.cpp");
    client_->input(pane->id, "printf '\\033[2J\\033[H/tmp/telar/file.cpp\\n'\r");
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).startsWith(path), runtime_wait_ms);
    terminal->forceActiveFocus();
    const auto cell = terminal->cellSize();
    const auto clicked = terminal->mapToScene({cell.width() * 2, cell.height() / 2}).toPoint();
    clipboard->setText(QStringLiteral("unchanged clipboard"));
    QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, clicked);
    QCOMPARE(clipboard->text(), QStringLiteral("unchanged clipboard"));
    QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, clicked);
    QTRY_COMPARE_WITH_TIMEOUT(clipboard->text(), path, runtime_wait_ms);
    QVERIFY(!client_->copyModeActive());
    QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, clicked);
    QVERIFY(client_->copyState() && client_->copyState()->linewise);
    QTest::keyClick(window_, Qt::Key_X);
    QVERIFY(!client_->copyState());
    client_->input(pane->id, "\x15");
    const auto click_wait_ms = static_cast<int>(ClickTracker::interval.count()) + 1;
    QTest::qWait(click_wait_ms);
    const auto beginning = terminal->mapToScene({cell.width() / 2, cell.height() / 2}).toPoint();
    const auto end = terminal->mapToScene({(cell.width() * 3) + (cell.width() / 2), cell.height() / 2}).toPoint();
    QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, beginning);
    QTest::mouseMove(window_, end);
    QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, end);
    QTRY_COMPARE_WITH_TIMEOUT(clipboard->text(), QStringLiteral("/tmp"), runtime_wait_ms);
    QTest::qWait(click_wait_ms);
    clipboard->setText(QStringLiteral("pending recovery"));
    QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, beginning);
    QTest::mouseMove(window_, end);
    terminal->ungrabMouse();
    QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, end);
    QTRY_COMPARE_WITH_TIMEOUT(clipboard->text(), QStringLiteral("/tmp"), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_X);
    client_->input(pane->id, "\x15");
    client_->execute(Application::Action::copy_mode);
    QInputMethodEvent committed;
    committed.setCommitString(QStringLiteral("q"));
    QCoreApplication::sendEvent(terminal, &committed);
    QVERIFY(!client_->copyModeActive());
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void detectedLinkHoverAndCopy() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(window_->isExposed(), runtime_wait_ms);
    if (!window_->isActive()) {
      test::activateWindow(*window_);
    }

    QTRY_VERIFY_WITH_TIMEOUT(window_->isActive(), runtime_wait_ms);
    auto *terminal = terminalIn(window_->contentItem());
    const auto *pane = firstPane();
    QVERIFY(terminal != nullptr && pane != nullptr);
    auto *clipboard = QGuiApplication::clipboard();
    const auto restore_clipboard = qScopeGuard([clipboard, saved = test::copyClipboard()] mutable {
      clipboard->setMimeData(saved.release());
    });
    client_->input(pane->id, "printf '\\033[2J\\033[H[docs](https://plain.test/x)\\n/tmp/telar/source.cpp:12:3\\n\\033]8;;https://destination.test\\033\\\\https://label.test\\033]8;;\\033\\\\\\nLINK_HOVER_READY\\n'\r");
    QTRY_VERIFY2_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).startsWith(QLatin1StringView("[docs](https://plain.test/x)")) && screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("LINK_HOVER_READY")), qPrintable(QStringLiteral("columns=%1 contents=%2").arg(pane->screen.columns()).arg(screenText(pane->screen))), runtime_wait_ms);
    const auto path_row = logicalRowStart(pane->screen, 1);
    const auto osc_row = logicalRowStart(pane->screen, 2);
    const auto blank_row = logicalRowStart(pane->screen, 4);
    QVERIFY(path_row.has_value() && osc_row.has_value() && blank_row.has_value());
    terminal->forceActiveFocus();
    QTest::mouseMove(window_, cellCenter(*terminal, {.x = 2}));
    QTRY_VERIFY2(terminal->hoveredLink() == QStringLiteral("https://plain.test/x"), qPrintable(QStringLiteral("hover=%1 active=%2 itemFocus=%3 copy=%4 modifiers=%5 frame=%6/%7 cursor=%8,%9").arg(terminal->hoveredLink()).arg(window_->isActive()).arg(terminal->hasActiveFocus()).arg(client_->copyModeActive()).arg(client_->pointerModifiers().toInt()).arg(pane->acknowledged_frame).arg(pane->screen.frameId()).arg(QCursor::pos().x()).arg(QCursor::pos().y())));
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
    QCOMPARE(client_->pointerModifiers(), Qt::KeyboardModifiers{Qt::ControlModifier});
    QVERIFY(terminal->hasActiveFocus());
    QVERIFY(window_->isActive());
    QTRY_VERIFY2(terminal->hoveredLink() == QStringLiteral("/tmp/telar/source.cpp:12:3"), qPrintable(QStringLiteral("Modifiers: %1; cursor: %2; preview: %3; copy: %4; contents: %5").arg(client_->pointerModifiers().toInt()).arg(terminal->cursor().shape()).arg(terminal->linkPreview().value(QStringLiteral("visible")).toBool()).arg(client_->copyModeActive()).arg(screenText(pane->screen))));
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
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void wheelReportingAndCopyOwnership() {
    const auto original_tabs = client_->tabs()->rowCount();
    const auto *original_pane = firstPane();
    QVERIFY(original_pane != nullptr);
    const auto original_identity = original_pane->id;
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), original_tabs + 1, runtime_wait_ms);
    auto restore = qScopeGuard([this, original_tabs, original_identity] {
      closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
    });
    QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->id != original_identity && firstPane()->screen.frameId() > 0, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    auto *terminal = terminalIn(window_->contentItem());
    const auto *pane = firstPane();
    QVERIFY(terminal != nullptr && pane != nullptr);
    terminal->forceActiveFocus();
    constexpr std::string_view expected = "\x1b[<0;1;1M\x1b[<0;2;1m\x1b[<68;1;1M\x1b[<64;1;1M";
    const auto capture = QStringLiteral("stty raw -echo; printf '\\033[?1000h\\033[?1006h'; dd bs=1 count=%1 2>/dev/null | od -An -tx1 | tr -d ' \\n'; printf '\\033[?1000l\\033[?1006l'; stty sane\r").arg(expected.size());
    client_->input(pane->id, capture.toUtf8());
    QTRY_VERIFY_WITH_TIMEOUT(pane->screen.mouse().sgr && pane->screen.mouse().tracking == telar::MouseTracking::normal, runtime_wait_ms);
    client_->execute(Application::Action::copy_mode);
    QVERIFY(client_->copyModeActive());
    constexpr int wheel_notch = 120;
    const QPointF local{1, 1};
    QWheelEvent owned{local, terminal->mapToGlobal(local), {}, {0, wheel_notch}, Qt::NoButton, Qt::ShiftModifier, Qt::NoScrollPhase, false};
    QCoreApplication::sendEvent(terminal, &owned);
    QTest::qWait(frame_settle_ms);
    QVERIFY(pane->screen.mouse().sgr && client_->copyModeActive());
    client_->execute(Application::Action::cancel);
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
    QCOMPARE(client_->error(), QString{});
    closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
    restore.dismiss();
  }

  Q_SLOT void simultaneousChildMouseButtons() {
    constexpr std::string_view expected = "\x1b[<0;1;1M\x1b[<1;1;1M\x1b[<0;1;1m\x1b[<33;2;1M\x1b[<1;2;1m";
    verifyChildMouse(expected, [](QQuickWindow &window, TerminalItem &terminal) {
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
    verifyChildMouse(expected, [](QQuickWindow &window, TerminalItem &terminal) {
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
    verifyChildMouse({}, [](QQuickWindow &window, TerminalItem &terminal) {
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
    verifyChildMouse(expected, [this](QQuickWindow &window, TerminalItem &terminal) {
      const QPointer<TerminalItem> retained{&terminal};
      const auto first = cellCenter(terminal, {});
      const auto held = Qt::LeftButton | Qt::MiddleButton;
      sendMouse(window, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, first);
      sendMouse(window, QEvent::MouseButtonPress, Qt::MiddleButton, held, first);
      client_->execute(Application::Action::split_horizontal);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
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
    verifyChildMouse(expected, [this](QQuickWindow &window, TerminalItem &terminal) {
      client_->execute(Application::Action::split_horizontal);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
      auto *other = focusedTerminalBeside(window, terminal);
      QVERIFY(other != nullptr && other != &terminal);
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
    verifyChildMouse(expected, [this](QQuickWindow &window, TerminalItem &terminal) {
      client_->execute(Application::Action::split_horizontal);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
      auto *other = focusedTerminalBeside(window, terminal);
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
    verifyChildMouse(expected, [](QQuickWindow &window, TerminalItem &terminal) {
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
    verifyChildMouse(expected, [this, expected](QQuickWindow &window, TerminalItem &terminal) {
      client_->execute(Application::Action::split_horizontal);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
      auto *other = focusedTerminalBeside(window, terminal);
      QVERIFY(other != nullptr && other != &terminal);
      const auto other_id = other->paneIdentity();
      beginChildMouseCapture(*other, expected.size());
      QTRY_COMPARE_WITH_TIMEOUT(client_->pane(terminal.paneIdentity())->acknowledged_frame, client_->pane(terminal.paneIdentity())->screen.frameId(), runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!terminal.prepareLinkPresentation(), runtime_wait_ms);
      sendMouse(window, QEvent::MouseButtonPress, Qt::LeftButton, Qt::LeftButton, cellCenter(terminal, {}));
      sendMouse(window, QEvent::MouseButtonPress, Qt::MiddleButton, Qt::LeftButton | Qt::MiddleButton, cellCenter(*other, {}));
      client_->execute(Application::Action::close_pane, QString::number(other_id));
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(client_->pane(other_id) == nullptr, runtime_wait_ms);
      const auto *remaining = terminalIn(window.contentItem());
      QVERIFY(remaining != nullptr);
      const auto *pane = client_->pane(remaining->paneIdentity());
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
    auto *clipboard = QGuiApplication::clipboard();
    auto saved_clipboard = test::copyClipboard();
    const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved_clipboard)] mutable {
      clipboard->setMimeData(saved.release());
    });
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    auto *terminal = terminalIn(window_->contentItem());
    const auto *pane = firstPane();
    QVERIFY(terminal != nullptr && pane != nullptr);
    client_->input(pane->id, "printf 'COPY_MODE_WORD_1\\nCOPY_MODE_WORD_2\\n'\r");
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).contains(QLatin1StringView("COPY_MODE_WORD_2")), runtime_wait_ms);
    terminal->forceActiveFocus();
    QTest::keyClick(window_, Qt::Key_B, NativeKeyAdapter::control_modifier);
    QTest::keyClick(window_, Qt::Key_BracketLeft);
    QVERIFY(client_->copyModeActive());
    const auto *mode_bar = window_->findChild<NativeModeLayout *>();
    QVERIFY(mode_bar != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(modeTitle(*mode_bar), QStringLiteral(" COPY "), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_Slash);
    QCOMPARE(client_->dialog(), QStringLiteral("copy-search"));
    client_->submitDialog({{QStringLiteral("text"), QStringLiteral("COPY_MODE_WORD_1")}});
    QTRY_VERIFY_WITH_TIMEOUT(client_->copyState() && client_->copyState()->anchor.has_value(), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_Y);
    QVERIFY(!client_->copyModeActive());
    QTRY_COMPARE_WITH_TIMEOUT(clipboard->text(), QStringLiteral("COPY_MODE_WORD_1"), runtime_wait_ms);

    CommandPeer peer{memory_};
    peer.open(socket_);
    QTRY_VERIFY_WITH_TIMEOUT(peer.ready(), runtime_wait_ms);
    peer.request(telar::ClientAction::client_copy_mode, 1);
    QTRY_VERIFY_WITH_TIMEOUT(client_->copyModeActive(), runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{1}, runtime_wait_ms);
    QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
    QTest::keyPress(window_, Qt::Key_Q);
    QVERIFY(!client_->copyModeActive());
    QTest::qWait(frame_settle_ms);
    const auto before_repeat = screenText(pane->screen);
    QKeyEvent repeated{QEvent::KeyPress, Qt::Key_Q, Qt::NoModifier, QStringLiteral("q"), true};
    QCoreApplication::sendEvent(window_, &repeated);
    QTest::keyRelease(window_, Qt::Key_Q);
    QTest::qWait(frame_settle_ms);
    QCOMPARE(screenText(pane->screen), before_repeat);
    QCOMPARE(client_->error(), QString{});
  }

#ifdef TELAR_GUI_CUSTOM_LINK_HOST
  Q_SLOT void pointerLinkOpening() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    const RecordedLinks recorder{directory_.filePath(QStringLiteral("pointer links.txt"))};
    auto *terminal = terminalIn(window_->contentItem());
    const auto *pane = firstPane();
    QVERIFY(terminal != nullptr && pane != nullptr);
    client_->input(pane->id, "printf '\\033[2J\\033[Hhttps://pointer.test/x\\nPOINTER_LINK_READY\\n'\r");
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).startsWith(QLatin1StringView("https://pointer.test/x")) && screenText(pane->screen).contains(QLatin1StringView("POINTER_LINK_READY")), runtime_wait_ms);
    terminal->forceActiveFocus();
    const auto position = cellCenter(*terminal, {.x = 2});
    QTest::mouseMove(window_, position);
    QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://pointer.test/x"));
    QTest::qWait(frame_settle_ms);
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
    client_->input(pane->id, "\x15");

    client_->input(pane->id, "printf '\\033[?1000h'\r");
    QTRY_COMPARE(pane->screen.mouse().tracking, telar::MouseTracking::normal);
    const auto restore_tracking = qScopeGuard([this, identity = pane->id] {
      client_->input(identity, "printf '\\033[?1000l'\r");
    });
    QTest::mouseMove(window_, position);
    QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://pointer.test/x"));
    QTest::qWait(frame_settle_ms);
    QTest::mouseClick(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
    QTest::qWait(frame_settle_ms);
    QCOMPARE(recorder.targets().size(), 1);
    client_->input(pane->id, "\x15");
    QTest::mouseClick(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier | Qt::ShiftModifier, position);
    QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), (QStringList{QStringLiteral("https://pointer.test/x"), QStringLiteral("https://pointer.test/x")}), runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void pointerLinkRevalidation() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    const RecordedLinks recorder{directory_.filePath(QStringLiteral("revalidated links.txt"))};
    auto *terminal = terminalIn(window_->contentItem());
    const auto *pane = firstPane();
    QVERIFY(terminal != nullptr && pane != nullptr);
    constexpr auto first_output = "printf '\\033[2J\\033[Hhttps://original.test\\nORIGINAL_READY\\n'\r";
    client_->input(pane->id, first_output);
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).startsWith(QLatin1StringView("https://original.test")) && screenText(pane->screen).contains(QLatin1StringView("ORIGINAL_READY")), runtime_wait_ms);
    terminal->forceActiveFocus();
    const auto position = cellCenter(*terminal, {.x = 2});
    QTest::mouseMove(window_, position);
    QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://original.test"));
    QTest::qWait(frame_settle_ms);
    QTest::mousePress(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
    client_->input(pane->id, "printf '\\033[2J\\033[Hhttps://replaced.test\\nREPLACED_READY\\n'\r");
    QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://replaced.test"));
    client_->input(pane->id, first_output);
    QTRY_COMPARE(terminal->hoveredLink(), QStringLiteral("https://original.test"));
    QTest::qWait(frame_settle_ms);
    QTest::mouseRelease(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
    QTest::qWait(frame_settle_ms);
    QVERIFY(recorder.targets().isEmpty());

    QTest::mousePress(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
    client_->execute(Application::Action::toggle_sidebar);
    client_->execute(Application::Action::toggle_sidebar);
    QTest::qWait(frame_settle_ms);
    QTest::mouseRelease(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
    QTest::qWait(frame_settle_ms);
    QVERIFY(recorder.targets().isEmpty());
    QTest::mouseClick(window_, Qt::LeftButton, NativeKeyAdapter::link_modifier, position);
    QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), (QStringList{QStringLiteral("https://original.test")}), runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void textualAndRoutedLinks() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    const RecordedLinks recorder{directory_.filePath(QStringLiteral("opened links ñ.txt"))};
    const auto *pane = firstPane();
    auto *terminal = terminalIn(window_->contentItem());
    QVERIFY(pane != nullptr && terminal != nullptr);
    constexpr std::string_view copy_uri = "https://copy.test/x";
    client_->input(pane->id, "printf '\\033[2J\\033[Hhttps://copy.test/x\\nLINK_COPY_READY\\n'\r");
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).startsWith(QLatin1StringView("https://copy.test/x")) && screenText(pane->screen).contains(QLatin1StringView("LINK_COPY_READY")), runtime_wait_ms);
    terminal->forceActiveFocus();
    client_->execute(Application::Action::copy_mode);
    QTest::keyClick(window_, Qt::Key_Home);
    QTest::keyClick(window_, Qt::Key_Up);
    QTest::keyClick(window_, Qt::Key_Up);
    QTest::keyClick(window_, Qt::Key_O);
    QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), (QStringList{toQString(copy_uri)}), runtime_wait_ms);
    QVERIFY(client_->copyModeActive());
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

    client_->input(pane->id, "printf '\\033[2J\\033[H\\033]8;;https://osc8.test\\033\\\\SAFE\\033]8;;\\033\\\\\\n'\r");
    QTRY_COMPARE_WITH_TIMEOUT(toQString(pane->screen.linkAt(0)), QStringLiteral("https://osc8.test"), runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(pane->acknowledged_frame, pane->screen.frameId(), runtime_wait_ms);
    const auto cell = terminal->cellSize();
    const auto clicked = terminal->mapToScene({cell.width() / 2, cell.height() / 2}).toPoint();
    QTest::mouseClick(window_, Qt::LeftButton, Qt::ControlModifier, clicked);
    QTRY_COMPARE_WITH_TIMEOUT(recorder.targets(), (QStringList{toQString(copy_uri), toQString(routed_uri), QStringLiteral("https://osc8.test")}), runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }
#endif

  Q_SLOT void configuredFileEditor() {
    const auto original_tabs = client_->tabs()->rowCount();
    const auto *original = firstPane();
    QVERIFY(original != nullptr);
    const auto original_id = original->id;
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), original_tabs + 1, runtime_wait_ms);
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
    client_->execute(Application::Action::copy_mode);
    QVERIFY(client_->copyModeActive());
    peer.request(telar::ClientAction::client_open_link, 1, {uri.constData(), static_cast<std::size_t>(uri.size())});
    QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{1}, runtime_wait_ms);
    QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
    const auto arguments = [&] {
      QFile file{editor_path + QStringLiteral(".args")};

      return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray{};
    };
    QTRY_COMPARE_WITH_TIMEOUT(arguments(), file_path.toUtf8() + '\n', runtime_wait_ms);
    const auto editor_ready = [&] {
      for (int row = 0; row < client_->panes()->rowCount(); ++row) {
        const auto record = client_->panes()->data(client_->panes()->index(row, 0), ListModel::record_role).toMap();
        const auto *pane = client_->pane(record.value(QStringLiteral("key")).toString().toULongLong());
        if (pane != nullptr && pane->id != source_id && screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("FILE_EDITOR_READY"))) {
          return true;
        }
      }

      return false;
    };
    QTRY_VERIFY_WITH_TIMEOUT(editor_ready(), runtime_wait_ms);
    QTRY_VERIFY2_WITH_TIMEOUT(qobject_cast<TerminalItem *>(window_->activeFocusItem()) != nullptr && qobject_cast<TerminalItem *>(window_->activeFocusItem())->paneIdentity() != source_id, qPrintable(windowObservation(*window_)), runtime_wait_ms);
    QVERIFY(client_->copyModeActive());
    QTest::keyClick(window_, Qt::Key_Q);
    QVERIFY(!client_->copyModeActive());
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
    const auto positioned_arguments = [&] {
      QFile file{next_editor + QStringLiteral(".args")};

      return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray{};
    };
    QTRY_COMPARE_WITH_TIMEOUT(positioned_arguments(), QByteArray{"+call cursor(12, 3)\n"} + file_path.toUtf8() + '\n', runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 3, runtime_wait_ms);
    client_->execute(Application::Action::focus_pane, QString::number(source_id));
    const QSignalSpy feedback{client_.get(), &Application::notificationsChanged};
    const auto missing_uri = uri + ".missing";
    peer.request(telar::ClientAction::client_open_link, 3, {missing_uri.constData(), static_cast<std::size_t>(missing_uri.size())});
    QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
    QVERIFY2(peer.result().status == telar::ClientCommandStatus::admitted, qPrintable(peer.result().text));
    QTRY_VERIFY2_WITH_TIMEOUT(!feedback.empty(), qPrintable(client_->error()), runtime_wait_ms);
    QVERIFY(!client_->notifications().items().empty());
    QCOMPARE(client_->notifications().items().front().title.view(), std::string_view{"Could not open link"});
    QCOMPARE(client_->notifications().items().front().message.view(), std::string_view{"FileNotFound"});
    dismissNotification();
    QCOMPARE(client_->error(), QString{});
    client_->loadConfiguration({}, {}, {});
    closeTemporaryTab({.count = original_tabs, .pane_id = original_id});
    restore.dismiss();
  }

  Q_SLOT void kittyKeyboardInput() {
    const auto original_tabs = client_->tabs()->rowCount();
    const auto *original_pane = firstPane();
    QVERIFY(original_pane != nullptr);
    const auto original_identity = original_pane->id;
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), original_tabs + 1, runtime_wait_ms);
    auto restore = qScopeGuard([this, original_tabs, original_identity] {
      closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
    });
    QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->id != original_identity && firstPane()->screen.frameId() > 0, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    auto *terminal = terminalIn(window_->contentItem());
    const auto *pane = firstPane();
    QVERIFY(terminal != nullptr && pane != nullptr);
    terminal->forceActiveFocus();
    constexpr telar::Byte kitty_flags = 31;
    constexpr std::string_view expected = "\x1b[100;5u\x1b[100;5:3u";
    const auto capture = QStringLiteral("stty raw -echo; printf '\\033[>31u'; dd bs=1 count=%1 2>/dev/null | od -An -tx1 | tr -d ' \\n'; printf '\\033[<u'; stty sane\r").arg(expected.size());
    client_->input(pane->id, capture.toUtf8());
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
    QCOMPARE(client_->error(), QString{});
    closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
    restore.dismiss();
  }

  Q_SLOT void runtimeNotificationDeliveryAndRoutedDismissal() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    CommandPeer peer{memory_};
    peer.open(socket_);
    QTRY_VERIFY_WITH_TIMEOUT(peer.ready(), runtime_wait_ms);
    peer.showNotification({.request_id = 2, .notification = {.level = telar::NotificationLevel::success, .duration_ms = telar::max_notification_duration_ms, .title = "Runtime notice", .message = "Delivered over the real protocol", .link = "https://example.com/notice"}});
    QTRY_VERIFY_WITH_TIMEOUT(!client_->notifications().items().empty() && client_->notifications().items().front().title.view() == "Runtime notice", runtime_wait_ms);
    const auto id = client_->notifications().items().front().id;
    QCOMPARE(client_->notifications().items().front().link.view(), std::string_view{"https://example.com/notice"});
    QTRY_VERIFY_WITH_TIMEOUT(!telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("notificationCard")).empty(), runtime_wait_ms);
    const auto *body = telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("notificationBody")).front();
    const auto body_point = body->mapToScene({body->width() / 2, body->height() / 2}).toPoint();
    QTest::mouseMove(window_, body_point);
    QTRY_VERIFY_WITH_TIMEOUT(body->property("hovered").toBool(), runtime_wait_ms);
    const auto *underline = telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("notificationUnderline")).front();
    QTRY_VERIFY_WITH_TIMEOUT(underline->isVisible(), runtime_wait_ms);
    peer.request(telar::ClientCommand{.request_id = 3, .action = telar::ClientAction::notification_dismiss, .target_id = id.value});
    QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{3}, runtime_wait_ms);
    QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
    QTRY_VERIFY_WITH_TIMEOUT(client_->notifications().find(id) == nullptr, runtime_wait_ms);
    peer.request(telar::ClientCommand{.request_id = 4, .action = telar::ClientAction::notification_dismiss, .target_id = id.value});
    QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{4}, runtime_wait_ms);
    QCOMPARE(peer.result().status, telar::ClientCommandStatus::failed);
    QCOMPARE(peer.result().text, QStringLiteral("NotificationNotFound"));

    constexpr std::uint64_t focus_notice_request = 5;
    peer.showNotification({.request_id = focus_notice_request, .notification = {.level = telar::NotificationLevel::info, .duration_ms = telar::max_notification_duration_ms, .title = "Dismiss and type", .message = "Keep the terminal ready"}});
    const auto closes = [&] {
      return telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("notificationClose"));
    };
    QTRY_COMPARE_WITH_TIMEOUT(closes().size(), 1, runtime_wait_ms);
    const auto trace_focus = qEnvironmentVariableIsSet("TELAR_GUI_TEST_FOCUS_TRACE");
    const auto observation = [this, trace_focus] {
      if (trace_focus) {
        const auto *terminal = terminalIn(window_->contentItem());
        qInfo().noquote() << "notification focus" << windowObservation(*window_) << "terminal=" << terminal << "visible=" << (terminal != nullptr && terminal->isVisible()) << "focus=" << (terminal != nullptr && terminal->hasActiveFocus()) << "dialog=" << client_->dialog();
      }
    };
    const auto focus_connection = QObject::connect(window_, &QQuickWindow::activeFocusItemChanged, window_, observation);
    const auto stop_observation = qScopeGuard([&] {
      QObject::disconnect(focus_connection);
    });
    const auto *close = closes().front();
    const auto point = close->mapToScene({close->width() / 2, close->height() / 2}).toPoint();
    QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, point);
    auto release_click = qScopeGuard([&] {
      QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, point);
    });
    QCOMPARE(client_->notifications().items().front().phase, telar::gui::NotificationItem::Phase::exiting);
    observation();
    QTRY_VERIFY2_WITH_TIMEOUT(window_->activeFocusItem() == terminalIn(window_->contentItem()), qPrintable(windowObservation(*window_)), runtime_wait_ms);
    QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, point);
    release_click.dismiss();
    QTRY_VERIFY_WITH_TIMEOUT(client_->notifications().items().empty(), runtime_wait_ms);
  }

  Q_SLOT void routedDismissalOfFocusedNotificationReturnsToTerminal() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    CommandPeer peer{memory_};
    peer.open(socket_);
    QTRY_VERIFY_WITH_TIMEOUT(peer.ready(), runtime_wait_ms);
    peer.showNotification({.request_id = 1, .notification = {.level = telar::NotificationLevel::info, .duration_ms = telar::max_notification_duration_ms, .title = "Focused notice", .message = "Remove the focused widget"}});
    const auto closes = [&] {
      return test::visualItems(*window_->contentItem(), QStringLiteral("notificationClose"));
    };
    QTRY_COMPARE_WITH_TIMEOUT(closes().size(), 1, runtime_wait_ms);
    const auto identity = client_->notifications().items().front().id;
    const auto key = client_->notificationIdentity(identity);
    const auto cleanup = qScopeGuard([this, key] {
      client_->dismissNotification(key);
    });
    auto *close = closes().front();
    close->forceActiveFocus(Qt::TabFocusReason);
    QTRY_COMPARE_WITH_TIMEOUT(window_->activeFocusItem(), close, runtime_wait_ms);
    peer.request(telar::ClientCommand{.request_id = 2, .action = telar::ClientAction::notification_dismiss, .target_id = identity.value});
    QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
    QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
    QTRY_VERIFY_WITH_TIMEOUT(client_->notifications().items().empty(), runtime_wait_ms);
    QTRY_VERIFY2_WITH_TIMEOUT(window_->activeFocusItem() == terminalIn(window_->contentItem()), qPrintable(windowObservation(*window_)), runtime_wait_ms);
    sendTextKeys(QLatin1StringView{"printf 'NOTICE_FOCUS_RESTORED\\n'"});
    QTest::keyClick(window_, Qt::Key_Return);
    const auto restored_output = [this] {
      const auto rows = screenText(firstPane()->screen, ScreenTextLayout::logical).split(QLatin1Char('\n'));

      return std::ranges::any_of(rows, [](const QString &row) {
        return row.trimmed() == QLatin1StringView("NOTICE_FOCUS_RESTORED");
      });
    };
    QTRY_VERIFY2_WITH_TIMEOUT(restored_output(), qPrintable(screenText(firstPane()->screen, ScreenTextLayout::logical)), runtime_wait_ms);
  }

  Q_SLOT void removingFocusedNotificationWithoutDisabledFrameReturnsToTerminal() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    client_->publishNotification({.level = telar::NotificationLevel::info, .title = "Removed delivered control", .message = "No intermediate disabled record", .link = {}, .duration_ns = telar::max_notification_duration_ms * NotificationInput::nanoseconds_per_millisecond});
    const auto closes = [&] {
      return test::visualItems(*window_->contentItem(), QStringLiteral("notificationClose"));
    };
    QTRY_COMPARE_WITH_TIMEOUT(closes().size(), 1, runtime_wait_ms);
    const auto identity = client_->notificationIdentity(client_->notifications().items().front().id);
    const auto cleanup = qScopeGuard([this, identity] {
      client_->dismissNotification(identity);
    });
    auto *close = closes().front();
    QVERIFY(close->isEnabled());
    close->forceActiveFocus(Qt::TabFocusReason);
    QTRY_COMPARE_WITH_TIMEOUT(window_->activeFocusItem(), close, runtime_wait_ms);
    auto *owner = close->parentItem();
    while (owner != nullptr && qobject_cast<NotificationLayout *>(owner) == nullptr) {
      owner = owner->parentItem();
    }

    auto *layout = qobject_cast<NotificationLayout *>(owner);
    QVERIFY(layout != nullptr);
    auto *records = dynamic_cast<ListModel *>(layout->cards());
    QVERIFY(records != nullptr);
    QCOMPARE(records->rowCount(), 1);
    records->reconcile({});
    QTRY_VERIFY2_WITH_TIMEOUT(window_->activeFocusItem() == terminalIn(window_->contentItem()), qPrintable(windowObservation(*window_)), runtime_wait_ms);
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
    QCOMPARE(client_->error(), QString{});
    const auto commands = client_->commands();
    QVERIFY(std::ranges::any_of(commands, [](const auto &entry) {
      const auto record = entry.toMap();

      const auto shortcut = platform::usesCommandKey() ? QStringLiteral("⌃A C") : QStringLiteral("Ctrl+a c");

      return record.value(QStringLiteral("action")).template value<Application::Action>() == Application::Action::new_tab && record.value(QStringLiteral("shortcut")) == shortcut;
    }));
    auto *terminal = terminalIn(window_->contentItem());
    const auto *pane = firstPane();
    QVERIFY(terminal != nullptr && pane != nullptr);
    const auto clear_input = qScopeGuard([this, identity = pane->id] {
      client_->input(identity, "\x15");
    });
    terminal->forceActiveFocus();
    const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
    const auto visible = client_->sidebarVisible();
    const QSignalSpy configuration_events{client_.get(), &Application::configurationChanged};
    const QSignalSpy focus_events{window_, &QQuickWindow::activeFocusItemChanged};
    QTest::keyClick(window_, Qt::Key_A, control);
    QVERIFY(client_->prefixPending());
    const auto *mode_bar = window_->findChild<NativeModeLayout *>();
    QVERIFY(mode_bar != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(modeTitle(*mode_bar), QStringLiteral(" PREFIX "), runtime_wait_ms);
    writeTestFile(directory.filePath(QStringLiteral("unused.lua")), "return {}");
    constexpr int prefix_wait_ms = 1100;
    QTest::qWait(prefix_wait_ms);
    QVERIFY(client_->prefixPending());
    QTest::keyPress(window_, Qt::Key_S);
    QVERIFY(!client_->prefixPending());
    QCOMPARE(client_->error(), QString{});
    QVERIFY2(client_->sidebarVisible() == !visible, qPrintable(QStringLiteral("Configuration reloads: %1; focus changes: %2; dialog: %3; copy mode: %4").arg(configuration_events.count()).arg(focus_events.count()).arg(client_->dialog()).arg(static_cast<int>(client_->copyModeActive()))));
    QKeyEvent repeated{QEvent::KeyPress, Qt::Key_S, Qt::NoModifier, QStringLiteral("s"), true};
    QCoreApplication::sendEvent(window_, &repeated);
    QCOMPARE(client_->sidebarVisible(), !visible);
    QTest::keyRelease(window_, Qt::Key_S);
    QTest::keyClick(window_, Qt::Key_A, control);
    QVERIFY(client_->prefixPending());
    QTest::keyClick(window_, Qt::Key_S);
    QVERIFY(!client_->prefixPending());
    QCOMPARE(client_->sidebarVisible(), visible);

    QTest::keyClick(window_, Qt::Key_A, control);
    QVERIFY(client_->prefixPending());
    QTest::keyClick(window_, Qt::Key_Escape);
    QVERIFY(!client_->prefixPending());
    QTest::keyClick(window_, Qt::Key_A, control);
    QVERIFY(client_->prefixPending());
    client_->execute(Application::Action::palette);
    QVERIFY(!client_->prefixPending());
    client_->execute(Application::Action::cancel);
    terminal->forceActiveFocus();

    const auto collapsed = client_->workspaceListCollapsed();
    sendTextKeys(QLatin1StringView("gg"));
    QCOMPARE(client_->workspaceListCollapsed(), !collapsed);
    sendTextKeys(QLatin1StringView("gg"));
    QCOMPARE(client_->workspaceListCollapsed(), collapsed);
    sendTextKeys(QLatin1StringView("gk"));
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).contains(QLatin1StringView("gk")), runtime_wait_ms);
    client_->input(pane->id, "\x15");

    QTest::keyClick(window_, Qt::Key_P, Qt::AltModifier);
    QTest::keyClick(window_, Qt::Key_Return);
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).contains(QLatin1StringView("GUI_BINDING_PASTE")), runtime_wait_ms);
    client_->input(pane->id, "printf '");
    QTest::keyClick(window_, Qt::Key_K, Qt::AltModifier);
    client_->input(pane->id, "\\n'\r");
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).contains(QLatin1StringView("GUI_BINDING_KEYS")), runtime_wait_ms);
    QTest::qWait(frame_settle_ms);
    const auto before_consume = screenText(pane->screen);
    QTest::keyClick(window_, Qt::Key_V, Qt::AltModifier);
    QTest::qWait(frame_settle_ms);
    const auto after_consume = screenText(pane->screen);
    QVERIFY2(after_consume == before_consume, qPrintable(QStringLiteral("Before consume:\n%1\nAfter consume:\n%2\n%3").arg(before_consume, after_consume, windowObservation(*window_))));
    QCOMPARE(client_->error(), QString{});
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
    auto *terminal = terminalIn(window_->contentItem());
    QVERIFY(terminal != nullptr);
    terminal->forceActiveFocus();
    const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
    QTest::keyClick(window_, Qt::Key_A, control);
    QTest::keyPress(window_, Qt::Key_S);
    writeTestFile(path, "return {api_version=2, client={keybindings={telar.bind_global({'s'}, telar.action.toggle_workspace_list())}}}");
    client_->loadConfiguration(path, {}, {});
    const auto collapsed = client_->workspaceListCollapsed();
    QKeyEvent repeated{QEvent::KeyPress, Qt::Key_S, Qt::NoModifier, QStringLiteral("s"), true};
    QCoreApplication::sendEvent(window_, &repeated);
    QCOMPARE(client_->workspaceListCollapsed(), collapsed);
    QTest::keyRelease(window_, Qt::Key_S);
    QTest::keyClick(window_, Qt::Key_S);
    QCOMPARE(client_->workspaceListCollapsed(), !collapsed);
    QTest::keyClick(window_, Qt::Key_S);
    QCOMPARE(client_->workspaceListCollapsed(), collapsed);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void splitCloseAndTabs() {
    auto *terminal = terminalIn(window_->contentItem());
    if (terminal == nullptr) {
      QFAIL("Required terminal fixture is missing");
    }
    const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
    QKeyEvent prefix{QEvent::KeyPress, Qt::Key_B, control};
    QKeyEvent split{QEvent::KeyPress, Qt::Key_Percent, Qt::NoModifier, QStringLiteral("%")};
    QCoreApplication::sendEvent(terminal, &prefix);
    QCoreApplication::sendEvent(terminal, &split);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
    QCOMPARE(client_->dividers()->rowCount(), 1);
    const auto divider = client_->dividers()->data(client_->dividers()->index(0, 0), ListModel::record_role).toMap();
    const auto first_width = client_->panes()->data(client_->panes()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("width")).toReal();
    client_->resizeDivider(divider.value(QStringLiteral("key")).toString().toInt(), divider.value(QStringLiteral("x")).toReal() + divider_drag_pixels, divider.value(QStringLiteral("y")).toReal(), true);
    const auto resized_width = client_->panes()->data(client_->panes()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("width")).toReal();
    QVERIFY(resized_width > first_width);
    const auto split_id = client_->panes()->data(client_->panes()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString();
    QTRY_VERIFY_WITH_TIMEOUT(client_->pane(split_id.toULongLong())->screen.frameId() > 0, runtime_wait_ms);
    const auto first_index = client_->panes()->index(0, 0);
    const auto first_record = client_->panes()->data(first_index, ListModel::record_role).toMap();
    constexpr qsizetype bottom_band_index = 1;
    const auto bands = first_record.value(QStringLiteral("panels")).toList();
    QVERIFY(bands.size() > bottom_band_index);
    const auto bottom_band = bands[bottom_band_index].toRectF();
    const auto frame_origin = QPointF{first_record.value(QStringLiteral("x")).toReal(), first_record.value(QStringLiteral("y")).toReal()};
    const auto workbench_origin = client_->windowGeometry().value(QStringLiteral("terminal")).toRectF().topLeft();
    QTest::qWait(frame_settle_ms);
    QTest::mousePress(window_, Qt::LeftButton, Qt::NoModifier, (workbench_origin + frame_origin + bottom_band.center()).toPoint());
    QTRY_VERIFY_WITH_TIMEOUT(client_->panes()->data(first_index, ListModel::record_role).toMap().value(QStringLiteral("focused")).toBool(), runtime_wait_ms);
    QTest::mouseRelease(window_, Qt::LeftButton, Qt::NoModifier, (workbench_origin + frame_origin + bottom_band.center()).toPoint());
    client_->execute(Application::Action::focus_pane, split_id);

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
    QCOMPARE(client_->error(), QString{});
    QTest::keyClick(window_, Qt::Key_H, Qt::AltModifier);
    QVERIFY(client_->panes()->data(client_->panes()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("focused")).toBool());
    QTest::keyClick(window_, Qt::Key_L, Qt::AltModifier);
    QVERIFY(client_->panes()->data(client_->panes()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("focused")).toBool());
    QCOMPARE(client_->error(), QString{});
    client_->execute(Application::Action::close_pane, split_id);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 1, runtime_wait_ms);

    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), 2, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 1, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->screen.frameId() > 0, runtime_wait_ms);
    const auto first_tab = client_->tabs()->data(client_->tabs()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString();
    client_->execute(Application::Action::select_tab, first_tab);
    QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->screen.frameId() > 0, runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void kittyGraphicsRendering() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    auto const *pane = firstPane();
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
    client_->input(pane->id, command);
    QTRY_VERIFY_WITH_TIMEOUT(!pane->graphics.placements().empty(), runtime_wait_ms);
    const auto placement = pane->graphics.placements().front();
    QTRY_VERIFY_WITH_TIMEOUT(pane->graphics.readyImage(placement.key) != nullptr, runtime_wait_ms);
    const auto *image = pane->graphics.readyImage(placement.key);
    if (image == nullptr) {
      QFAIL("Required image fixture is missing");
    }
    QCOMPARE(image->pixels().size(), std::size_t{16});
    auto const *terminal = terminalIn(window_->contentItem());
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
    client_->input(pane->id, "printf '\\033_Ga=d,d=I,i=37,q=2;\\033\\\\'\r");
    QTRY_VERIFY_WITH_TIMEOUT(pane->graphics.placements().empty(), runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void paletteModesKeepQueriesAndRejectStaleChoices() {
    const auto original_panes = client_->panes()->rowCount();
    client_->execute(Application::Action::palette);
    client_->searchPalette(QStringLiteral(">Split right"));
    QCOMPARE(client_->paletteState().value(QStringLiteral("count")).toInt(), 1);
    const auto state = client_->paletteState();
    const auto key = state.value(QStringLiteral("selectedKey")).toString();
    const auto revision = state.value(QStringLiteral("revision")).toString();
    QVERIFY(!key.isEmpty());
    client_->searchPalette(QStringLiteral(">no matching command exists here"));
    client_->usePaletteResult({{QStringLiteral("key"), key}, {QStringLiteral("revision"), revision}});
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));
    QCOMPARE(client_->panes()->rowCount(), original_panes);
    client_->searchPalette(QStringLiteral("@context query"));
    client_->setPaletteMode('>');
    QCOMPARE(client_->paletteState().value(QStringLiteral("editorText")).toString(), QStringLiteral(">context query"));
    client_->setPaletteMode('@');
    QCOMPARE(client_->paletteState().value(QStringLiteral("editorText")).toString(), QStringLiteral("@context query"));
    client_->searchPalette(QStringLiteral(">Split right"));
    const auto previous = client_->paletteState();
    client_->execute(Application::Action::cancel);
    client_->execute(Application::Action::palette);
    client_->searchPalette(QStringLiteral(">Split right"));
    client_->usePaletteResult({{QStringLiteral("key"), previous.value(QStringLiteral("selectedKey"))}, {QStringLiteral("revision"), previous.value(QStringLiteral("revision"))}});
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));
    QCOMPARE(client_->panes()->rowCount(), original_panes);
    client_->execute(Application::Action::cancel);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void suggestionPaletteKeepsUnavailableRequestsEditable() {
    client_->execute(Application::Action::suggest_command);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));
    QCOMPARE(client_->paletteState().value(QStringLiteral("editorText")).toString(), QStringLiteral("?"));
    QVERIFY(!client_->suggestionState().value(QStringLiteral("canSubmit")).toBool());
    client_->searchPalette(QStringLiteral("?list files"));
    auto const *search = window_->findChild<NativeFormField *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(search->text(), QStringLiteral("?list files"), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_Return);
    const auto suggestion = [this] {
      return client_->suggestionState();
    };
    QTRY_VERIFY_WITH_TIMEOUT(suggestion().value(QStringLiteral("failed")).toBool(), runtime_wait_ms);
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));
    QCOMPARE(suggestion().value(QStringLiteral("message")).toString(), QStringLiteral("Configure runtime.engine to enable suggestions."));
    const auto obsolete = suggestion().value(QStringLiteral("revision")).toString();
    client_->searchPalette(QStringLiteral("?new task"));
    QCOMPARE(suggestion().value(QStringLiteral("heading")).toString(), QStringLiteral("Start with a task"));
    client_->submitSuggestion(obsolete);
    QCOMPARE(suggestion().value(QStringLiteral("heading")).toString(), QStringLiteral("Start with a task"));
    QTRY_COMPARE_WITH_TIMEOUT(search->text(), QStringLiteral("?new task"), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_Return);
    QTRY_VERIFY_WITH_TIMEOUT(suggestion().value(QStringLiteral("failed")).toBool(), runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void suggestionBackRestoresItsActionQueryAndEditorSelection() {
    client_->execute(Application::Action::palette);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
      client_->execute(Application::Action::cancel);
    });
    const auto query = QStringLiteral(">Suggest a command");
    client_->searchPalette(query);
    QCOMPARE(client_->paletteState().value(QStringLiteral("count")).toInt(), 1);
    const QPointer<NativeFormField> search{window_->findChild<NativeFormField *>(QStringLiteral("commandSearch"))};
    QVERIFY(search != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(search->text(), query, runtime_wait_ms);
    constexpr int anchor = 7;
    constexpr int cursor = 3;
    search->select(anchor, cursor);
    QTest::keyClick(window_, Qt::Key_Return);
    QTRY_COMPARE_WITH_TIMEOUT(client_->paletteState().value(QStringLiteral("editorText")).toString(), QStringLiteral("?"), runtime_wait_ms);
    QVERIFY(client_->suggestionState().value(QStringLiteral("hasParent")).toBool());
    QVERIFY(search != nullptr);
    QCOMPARE(window_->findChild<NativeFormField *>(QStringLiteral("commandSearch")), search.data());
    client_->searchPalette(QStringLiteral("?child task"));
    QTest::keyClick(window_, Qt::Key_Escape);
    QTRY_COMPARE_WITH_TIMEOUT(client_->paletteState().value(QStringLiteral("editorText")).toString(), query, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(search->text(), query, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(search->cursorPosition(), cursor, runtime_wait_ms);
    QCOMPARE(search->selectionStart(), cursor);
    QCOMPARE(search->selectionEnd(), anchor);
    QVERIFY(!client_->suggestionState().value(QStringLiteral("hasParent")).toBool());
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void paletteNavigationChoosesAnExistingTab() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    const auto original_pane = firstPane()->id;
    const auto original_tab = firstPane()->location.tab_id;
    const auto original_tabs = client_->tabs()->rowCount();
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), original_tabs + 1, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != original_pane, runtime_wait_ms);
    const auto destination = firstPane()->id;
    const auto destination_tab = firstPane()->location.tab_id;
    client_->execute(Application::Action::rename_tab);
    client_->submitDialog({{QStringLiteral("text"), QStringLiteral("PALETTE_DESTINATION")}});
    client_->execute(Application::Action::select_tab, QString::number(original_tab));
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == original_pane, runtime_wait_ms);
    terminalIn(window_->contentItem())->forceActiveFocus();
    QTest::keyClick(window_, Qt::Key_B, NativeKeyAdapter::control_modifier);
    QTest::keyClick(window_, Qt::Key_G);
    QTRY_COMPARE_WITH_TIMEOUT(client_->dialog(), QStringLiteral("palette"), runtime_wait_ms);
    client_->searchPalette(QStringLiteral("@PLT_DST"));
    QTRY_COMPARE_WITH_TIMEOUT(client_->paletteState().value(QStringLiteral("count")).toInt(), 1, runtime_wait_ms);
    const auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), QStringLiteral("@PLT_DST"), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_Return);
    QTRY_COMPARE_WITH_TIMEOUT(client_->dialog(), QString{}, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == destination, runtime_wait_ms);
    QCOMPARE(client_->tabs()->rowCount(), original_tabs + 1);
    client_->execute(Application::Action::close_tab, QString::number(destination_tab));
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), original_tabs, runtime_wait_ms);
    client_->execute(Application::Action::select_tab, QString::number(original_tab));
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == original_pane, runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
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
      client_->input(pane_id, QByteArray{"\x15"
                                         "cd '"} +
                                  path.toUtf8() + "' && pwd\r");
    };
    const auto restore = qScopeGuard([&] {
      client_->execute(Application::Action::cancel);
      change_directory(original);
    });
    change_directory(root);
    QTRY_COMPARE_WITH_TIMEOUT(toQString(firstPane()->cwd), root, runtime_wait_ms);
    terminalIn(window_->contentItem())->forceActiveFocus();
    QTest::keyClick(window_, Qt::Key_B, NativeKeyAdapter::control_modifier);
    QTest::keyClick(window_, Qt::Key_F);
    QTRY_COMPARE_WITH_TIMEOUT(client_->dialog(), QStringLiteral("paths"), runtime_wait_ms);
    client_->searchPaths(QStringLiteral("folder/"));
    QTRY_VERIFY_WITH_TIMEOUT(client_->pathPickerState().value(QStringLiteral("count")).toInt() >= 1, runtime_wait_ms);
    auto const *panel = window_->findChild<QQuickItem *>(QStringLiteral("pathPickerPanel"));
    QVERIFY(panel != nullptr);
    auto const *search = panel->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), QStringLiteral("folder/"), runtime_wait_ms);
    QVERIFY(!search->property("formControl").toBool());
    QTest::keyClick(window_, Qt::Key_Tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->pathPickerState().value(QStringLiteral("root")).toString(), root + QStringLiteral("/folder"), runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), QString{}, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(client_->pathPickerState().value(QStringLiteral("count")).toInt(), 1, runtime_wait_ms);
    const auto stale = client_->pathPickerState().value(QStringLiteral("revision"));
    QTest::keyClick(window_, Qt::Key_Backtab, Qt::ShiftModifier);
    QTRY_COMPARE_WITH_TIMEOUT(client_->pathPickerState().value(QStringLiteral("root")).toString(), root, runtime_wait_ms);
    client_->activatePath({{QStringLiteral("revision"), stale}, {QStringLiteral("path"), QStringLiteral("a b'c.txt")}});
    QCOMPARE(client_->dialog(), QStringLiteral("paths"));
    client_->searchPaths(QStringLiteral("a b"));
    QTRY_COMPARE_WITH_TIMEOUT(client_->pathPickerState().value(QStringLiteral("count")).toInt(), 1, runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_Return);
    QTRY_COMPARE_WITH_TIMEOUT(client_->dialog(), QString{}, runtime_wait_ms);
    QTRY_VERIFY2_WITH_TIMEOUT(screenText(firstPane()->screen, ScreenTextLayout::logical).contains(QStringLiteral("'folder/a b'\\''c.txt'")), qPrintable(screenText(firstPane()->screen, ScreenTextLayout::logical)), runtime_wait_ms);
    QCOMPARE(toQString(firstPane()->cwd), root);
    client_->input(pane_id, "\x15");
    change_directory(original);
    QTRY_COMPARE_WITH_TIMEOUT(toQString(firstPane()->cwd), original, runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void pathPickerQueryLimitPreservesCompleteUtf8() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && !firstPane()->cwd.empty(), runtime_wait_ms);
    client_->execute(Application::Action::path_picker);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    QCOMPARE(client_->dialog(), QStringLiteral("paths"));
    constexpr int path_query_bytes = 64;
    QCOMPARE(client_->pathPickerState().value(QStringLiteral("maximumQueryBytes")).toInt(), path_query_bytes);
    auto const *panel = window_->findChild<QQuickItem *>(QStringLiteral("pathPickerPanel"));
    QVERIFY(panel != nullptr);
    auto *search = panel->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    const QString retained(path_query_bytes - 1, QLatin1Char('x'));
    QInputMethodEvent commit;
    commit.setCommitString(retained + QStringLiteral("🧵"));
    QCoreApplication::sendEvent(search, &commit);
    QCOMPARE(search->property("text").toString(), retained);
    QCOMPARE(client_->pathPickerState().value(QStringLiteral("editorText")).toString(), retained);
    const auto notices = [this] {
      return std::ranges::find_if(client_->notifications().items(), [](const auto &item) {
        return item.title.view() == "Limit reached" && item.message.view().contains("prompt.path_query_bytes");
      });
    };
    QTRY_VERIFY_WITH_TIMEOUT(notices() != client_->notifications().items().end(), runtime_wait_ms);
    const auto identity = notices()->id;
    client_->dismissNotification(client_->notificationIdentity(identity));
    QTRY_VERIFY_WITH_TIMEOUT(client_->notifications().find(identity) == nullptr, runtime_wait_ms);
  }

  Q_SLOT void paletteActionsUseOriginalLabelsAndReorderExistingTabs() {
    const auto commands = client_->commands();
    QCOMPARE(commands.size(), qsizetype{29});
    QCOMPARE(commands.front().toMap().value(QStringLiteral("label")).toString(), QStringLiteral("Split right"));
    const QStringList tail{QStringLiteral("Insert a path"), QStringLiteral("Switch machine"), QStringLiteral("Next machine"), QStringLiteral("Previous machine"), QStringLiteral("Add machine")};
    for (qsizetype index = 0; index < tail.size(); ++index) {
      QCOMPARE(commands[commands.size() - tail.size() + index].toMap().value(QStringLiteral("label")).toString(), tail[index]);
    }
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    const auto original_pane = firstPane()->id;
    const auto original_tab = firstPane()->location.tab_id;
    const auto original_count = client_->tabs()->rowCount();
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), original_count + 1, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != original_pane, runtime_wait_ms);
    const auto destination_tab = firstPane()->location.tab_id;
    auto restore = qScopeGuard([this, original_tab, destination_tab] {
      client_->execute(Application::Action::cancel);
      client_->execute(Application::Action::close_tab, QString::number(destination_tab));
      client_->execute(Application::Action::select_tab, QString::number(original_tab));
    });
    const auto run = [this](const QString &label) {
      client_->execute(Application::Action::palette);
      client_->searchPalette(QLatin1Char('>') + label);
      const auto state = client_->paletteState();
      client_->usePaletteResult({{QStringLiteral("key"), state.value(QStringLiteral("selectedKey"))}, {QStringLiteral("revision"), state.value(QStringLiteral("revision"))}});
    };
    const auto tab_keys = [this] {
      QList<QString> keys;
      for (int index = 0; index < client_->tabs()->rowCount(); ++index) {
        keys.append(client_->tabs()->data(client_->tabs()->index(index, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString());
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
    QCOMPARE(client_->tabs()->rowCount(), original_count + 1);
    QCOMPARE(client_->dialog(), QString{});
    QCOMPARE(client_->error(), QString{});
    client_->execute(Application::Action::close_tab, QString::number(destination_tab));
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), original_count, runtime_wait_ms);
    client_->execute(Application::Action::select_tab, QString::number(original_tab));
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
      client_->execute(Application::Action::cancel);
      static_cast<void>(QFile::remove(path));
    });
    client_->openMachines(path);
    client_->execute(Application::Action::machine_picker);
    client_->searchPalette(QStringLiteral(":Offline"));
    QTRY_COMPARE_WITH_TIMEOUT(client_->paletteState().value(QStringLiteral("count")).toInt(), 2, runtime_wait_ms);
    auto *search = window_->findChild<NativeFormField *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_R, Qt::KeyboardModifiers{Application::superModifier()});
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));
    QTest::keyClick(window_, Qt::Key_R, Qt::KeyboardModifiers{Application::controlModifier()});
    QTRY_COMPARE_WITH_TIMEOUT(client_->dialog(), QStringLiteral("machine"), runtime_wait_ms);
    search = window_->findChild<NativeFormField *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
    QCOMPARE(search->text(), QStringLiteral("Offline"));
    search->selectAll();
    QInputMethodEvent commit;
    commit.setCommitString(QStringLiteral("Renamed"));
    QCoreApplication::sendEvent(search, &commit);
    QTest::keyClick(window_, Qt::Key_Return);
    QTRY_VERIFY_WITH_TIMEOUT(client_->dialog().isEmpty(), runtime_wait_ms);
    client_->execute(Application::Action::machine_picker);
    client_->searchPalette(QStringLiteral(":Renamed"));
    QTRY_COMPARE_WITH_TIMEOUT(client_->paletteState().value(QStringLiteral("count")).toInt(), 2, runtime_wait_ms);
    search = window_->findChild<NativeFormField *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_D, Qt::KeyboardModifiers{Application::controlModifier()});
    QTRY_COMPARE_WITH_TIMEOUT(client_->paletteState().value(QStringLiteral("count")).toInt(), 1, runtime_wait_ms);
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));
  }

  Q_SLOT void machinePromptKeepsCompositionAndByteBounds() {
    client_->execute(Application::Action::add_machine);
    const auto cleanup = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    auto *search = window_->findChild<NativeFormField *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
    QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};
    QCoreApplication::sendEvent(search, &preedit);
    QTRY_VERIFY_WITH_TIMEOUT(search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_Escape);
    QCOMPARE(client_->dialog(), QStringLiteral("machine"));
    QTRY_VERIFY_WITH_TIMEOUT(!search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
    const auto maximum = client_->machinePromptState().value(QStringLiteral("maximumBytes")).toInt();
    const QString retained(maximum, QLatin1Char('x'));
    QInputMethodEvent commit;
    commit.setCommitString(retained + QStringLiteral("🧵"));
    QCoreApplication::sendEvent(search, &commit);
    QCOMPARE(search->text(), retained);
    QCOMPARE(client_->machinePromptState().value(QStringLiteral("editorText")).toString(), retained);
    const auto find_notice = [this] {
      return std::ranges::find_if(client_->notifications().items(), [](const auto &notice) {
        return notice.title.view() == "Limit reached" && notice.message.view().find("prompt.machine_label_bytes") != std::string_view::npos;
      });
    };
    QTRY_VERIFY_WITH_TIMEOUT(find_notice() != client_->notifications().items().end(), runtime_wait_ms);
    const auto notice = find_notice()->id;
    client_->dismissNotification(client_->notificationIdentity(notice));
    QTest::keyClick(window_, Qt::Key_Return);
    QCOMPARE(client_->machinePromptState().value(QStringLiteral("title")).toString(), QStringLiteral("Its SSH destination: user@host or an alias"));
    QCOMPARE(search->text(), QString{});
    QTest::keyClick(window_, Qt::Key_Escape);
    QVERIFY(client_->dialog().isEmpty());
  }

  Q_SLOT void paletteCompositionAndUtf8LimitsKeepTheEditorOwned() {
    client_->execute(Application::Action::goto_picker);
    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(search->hasActiveFocus(), runtime_wait_ms);
    QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};
    QCoreApplication::sendEvent(search, &preedit);
    QTRY_VERIFY_WITH_TIMEOUT(search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_Escape);
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));
    QTRY_VERIFY_WITH_TIMEOUT(!search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
    const auto maximum = client_->paletteState().value(QStringLiteral("maximumQueryBytes")).toInt();
    const QString retained(maximum - 1, QLatin1Char('x'));
    QVERIFY(QMetaObject::invokeMethod(search, "selectAll"));
    QInputMethodEvent commit;
    commit.setCommitString(retained + QStringLiteral("🧵"));
    QCoreApplication::sendEvent(search, &commit);
    QCOMPARE(search->property("text").toString(), retained);
    QCOMPARE(client_->paletteState().value(QStringLiteral("editorText")).toString(), retained);
    const auto find_notice = [this] {
      return std::ranges::find_if(client_->notifications().items(), [](const auto &notice) {
        return notice.title.view() == "Limit reached" && notice.message.view().find("prompt.field_bytes") != std::string_view::npos;
      });
    };
    QTRY_VERIFY_WITH_TIMEOUT(find_notice() != client_->notifications().items().end(), runtime_wait_ms);
    const auto identity = find_notice()->id;
    client_->dismissNotification(client_->notificationIdentity(identity));
    QTRY_VERIFY_WITH_TIMEOUT(client_->notifications().find(identity) == nullptr, runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_Escape);
    QCOMPARE(client_->dialog(), QString{});
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void dialogsAndHistory() {
    client_->execute(Application::Action::palette);
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));
    QTest::qWait(frame_settle_ms);
    client_->execute(Application::Action::cancel);
    QCOMPARE(client_->dialog(), QString{});
    client_->execute(Application::Action::history);
    QTRY_VERIFY_WITH_TIMEOUT(client_->history()->rowCount() > 0, runtime_wait_ms);
    client_->execute(Application::Action::cancel);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void historyKeyboardSubmission() {
    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    const auto *pane = firstPane();
    if (search == nullptr || pane == nullptr) {
      QFAIL("Required history search and terminal fixtures are missing");
    }

    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_FIXTURE"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() > 0, runtime_wait_ms);
    search->forceActiveFocus();
    QKeyEvent paste{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier};
    QCoreApplication::sendEvent(search, &paste);
    QTRY_COMPARE(client_->dialog(), QString{});
    QTRY_VERIFY2_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("echo GUI_HISTORY_FIXTURE")), qPrintable(QStringLiteral("columns=%1 contents=%2").arg(pane->screen.columns()).arg(screenText(pane->screen))), runtime_wait_ms);
    client_->input(pane->id, "\x15");

    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_FIXTURE"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() > 0, runtime_wait_ms);
    search->forceActiveFocus();
    QKeyEvent run{QEvent::KeyPress, Qt::Key_Return, Qt::ShiftModifier};
    QCoreApplication::sendEvent(search, &run);
    QTRY_COMPARE(client_->dialog(), QString{});
    const auto has_output = [&] {
      const auto lines = screenText(pane->screen).split(QLatin1Char('\n'));

      return std::ranges::any_of(lines, [](const auto &line) {
        return line.trimmed() == QLatin1StringView("GUI_HISTORY_FIXTURE");
      });
    };
    QTRY_VERIFY_WITH_TIMEOUT(has_output(), runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void historyPointerSelectionNeverSubmits() {
    const std::array entries{
        telar::ImportHistoryEntry{.started_at_ms = 100, .command = "echo GUI_HISTORY_POINTER_FIRST"},
        telar::ImportHistoryEntry{.started_at_ms = 101, .command = "echo GUI_HISTORY_POINTER_SECOND"},
    };
    importHistory(entries, "gui-history-pointer");
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
      if (const auto *pane = firstPane()) {
        client_->input(pane->id, "\x15");
      }
    });
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_POINTER"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 2, runtime_wait_ms);
    if (!window_->isActive()) {
      test::activateWindow(*window_);
    }

    QQuickItem *older = nullptr;
    const auto locate = [&] {
      for (auto *row : test::visualItems(*window_->contentItem(), QStringLiteral("historyResult"))) {
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
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    const auto position = older->mapToScene(QPointF{older->width() / 2, older->height() / 2}).toPoint();
    QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, position);
    QTRY_COMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 1);
    QVERIFY(client_->historyState().value(QStringLiteral("canSubmit")).toBool());
    QTest::mouseDClick(window_, Qt::LeftButton, Qt::NoModifier, position);
    QTest::qWait(frame_settle_ms);
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 1);
    QQuickItem *copy = nullptr;
    const auto locate_copy = [&] {
      for (auto *hint : test::visualItems(*older, QStringLiteral("historyHint"))) {
        if (hint->isVisible() && hint->property("label").toMap().value(QStringLiteral("action")).toString() == QStringLiteral("copy")) {
          copy = hint;

          return true;
        }
      }

      return false;
    };
    QTRY_VERIFY_WITH_TIMEOUT(locate_copy(), runtime_wait_ms);
    auto *clipboard = QGuiApplication::clipboard();
    auto saved_clipboard = test::copyClipboard();
    const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved_clipboard)] mutable {
      clipboard->setMimeData(saved.release());
    });
    const auto copy_position = copy->mapToScene(QPointF{copy->width() / 2, copy->height() / 2}).toPoint();
    QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, copy_position);
    QCOMPARE(clipboard->text(), QStringLiteral("echo GUI_HISTORY_POINTER_FIRST"));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
  }

  Q_SLOT void historyFooterHintsUseCurrentActions() {
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_FIXTURE"));
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
      if (const auto *pane = firstPane()) {
        client_->input(pane->id, "\x15");
      }
    });
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() > 0, runtime_wait_ms);
    auto *footer = window_->findChild<QQuickItem *>(QStringLiteral("historyFooter"));
    QVERIFY(footer != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(!test::visualItems(*footer, QStringLiteral("historyHint")).isEmpty(), runtime_wait_ms);
    const auto click = [&](const QString &action) {
      const auto hints = test::visualItems(*footer, QStringLiteral("historyHint"));
      const auto found = std::ranges::find_if(hints, [&](const auto *hint) {
        return hint->isVisible() && hint->property("label").toMap().value(QStringLiteral("action")).toString() == action;
      });
      if (found == hints.end()) {
        return false;
      }

      const auto *hint = *found;
      QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, hint->mapToScene(QPointF{hint->width() / 2, hint->height() / 2}).toPoint());

      return true;
    };
    if (!window_->isActive()) {
      test::activateWindow(*window_);
    }

    QVERIFY(click(QStringLiteral("inspect")));
    QTRY_VERIFY_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("inspecting")).toBool(), runtime_wait_ms);
    constexpr int inspect_hints = 4;
    QCOMPARE(footer->property("hints").toList().size(), inspect_hints);
    QVERIFY(click(QStringLiteral("inspect")));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyState().value(QStringLiteral("inspecting")).toBool(), runtime_wait_ms);
    QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    QVERIFY(!client_->historyState().value(QStringLiteral("enterRuns")).toBool());
    QVERIFY(click(QStringLiteral("submit")));
    QTRY_COMPARE_WITH_TIMEOUT(client_->dialog(), QString{}, runtime_wait_ms);
    const auto *pane = firstPane();
    QVERIFY(pane != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("echo GUI_HISTORY_FIXTURE")), runtime_wait_ms);
  }

  Q_SLOT void historyFooterRequiresDeliveredChoices() {
    const std::array entries{
        telar::ImportHistoryEntry{.started_at_ms = 100, .command = "echo GUI_HISTORY_DELIVERY_FIRST"},
        telar::ImportHistoryEntry{.started_at_ms = 101, .command = "echo GUI_HISTORY_DELIVERY_SECOND"},
    };
    importHistory(entries, "gui-history-delivery");
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
      client_->setWindow(*window_);
      QVERIFY(test::showWindow(*window_, runtime_wait_ms));
      if (const auto *pane = firstPane()) {
        client_->input(pane->id, "\x15");
      }
    });
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_DELIVERY"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 2, runtime_wait_ms);
    window_->hide();
    QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    window_->beforeSynchronizing();
    window_->frameSwapped();
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    auto *footer = window_->findChild<QQuickItem *>(QStringLiteral("historyFooter"));
    QVERIFY(footer != nullptr);
    const auto activate = [&](const QString &action) {
      const auto revision = client_->historyState().value(QStringLiteral("revision")).toString();

      return QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, action), Q_ARG(QString, revision));
    };
    client_->selectHistoryRow(1);
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 1);
    for (const auto &action : {QStringLiteral("submit"), QStringLiteral("alternate")}) {
      QVERIFY(activate(action));
      QCOMPARE(client_->dialog(), QStringLiteral("history"));
    }

    window_->beforeSynchronizing();
    QVERIFY(activate(QStringLiteral("submit")));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    window_->frameSwapped();
    QVERIFY(activate(QStringLiteral("submit")));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_DELIVERY_FIRST"));
    QVERIFY(activate(QStringLiteral("alternate")));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 1, runtime_wait_ms);
    QVERIFY(activate(QStringLiteral("submit")));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    window_->beforeSynchronizing();
    window_->frameSwapped();
    client_->execute(Application::Action::cancel);
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_DELIVERY_FIRST"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 1, runtime_wait_ms);
    QVERIFY(activate(QStringLiteral("submit")));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    window_->beforeSynchronizing();
    window_->frameSwapped();
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    QQuickWindow replacement;
    client_->setWindow(replacement);
    client_->setWindow(*window_);
    QVERIFY(activate(QStringLiteral("submit")));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    window_->beforeSynchronizing();
    window_->frameSwapped();
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    for (const auto &revision : {QString{}, QStringLiteral("not-a-revision"), QStringLiteral("18446744073709551616")}) {
      QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, QStringLiteral("submit")), Q_ARG(QString, revision)));
      QCOMPARE(client_->dialog(), QStringLiteral("history"));
    }

    QCOMPARE(client_->historyState().value(QStringLiteral("error")).toString(), QString{});
    QVERIFY(activate(QStringLiteral("submit")));
    QCOMPARE(client_->dialog(), QString{});
    QVERIFY(test::showWindow(*window_, runtime_wait_ms));
    const auto *pane = firstPane();
    QVERIFY(pane != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("echo GUI_HISTORY_DELIVERY_FIRST")), runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void historyRowsRequireTheDeliveredContentRevision() {
    const std::array entries{
        telar::ImportHistoryEntry{.started_at_ms = 100, .command = "echo GUI_ROW_PRESENTATION_A_FIRST"},
        telar::ImportHistoryEntry{.started_at_ms = 101, .command = "echo GUI_ROW_PRESENTATION_A_SECOND"},
        telar::ImportHistoryEntry{.started_at_ms = 102, .command = "echo GUI_ROW_PRESENTATION_B_FIRST"},
        telar::ImportHistoryEntry{.started_at_ms = 103, .command = "echo GUI_ROW_PRESENTATION_B_SECOND"},
    };
    importHistory(entries, "gui-row-presentation");
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
      client_->setWindow(*window_);
      QVERIFY(test::showWindow(*window_, runtime_wait_ms));
    });
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_ROW_PRESENTATION_A_"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 2, runtime_wait_ms);
    auto *results = window_->findChild<QQuickItem *>(QStringLiteral("historyResults"));
    QVERIFY(results != nullptr);
    QVERIFY(QMetaObject::invokeMethod(results, "forceLayout"));
    QTRY_COMPARE(test::visualItems(*window_->contentItem(), QStringLiteral("historyResult")).size(), 2);
    window_->hide();
    QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    QQuickWindow replacement;
    client_->setWindow(replacement);
    client_->setWindow(*window_);
    const auto activate = [&](int index, const QString &revision) {
      for (const auto *result : test::visualItems(*window_->contentItem(), QStringLiteral("historyResult"))) {
        if (result->property("index").toInt() != index) {
          continue;
        }

        auto *row = result->findChild<QQuickItem *>(QStringLiteral("historyRow"));

        return row != nullptr && QMetaObject::invokeMethod(row, "activated", Q_ARG(QString, revision));
      }

      return false;
    };
    const auto original_revision = client_->historyState().value(QStringLiteral("revision")).toString();
    QVERIFY(activate(1, original_revision));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    window_->beforeSynchronizing();
    QVERIFY(activate(1, original_revision));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    window_->frameSwapped();
    QVERIFY(activate(1, original_revision));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    client_->selectPresentedHistoryRow(-1, original_revision);
    client_->selectPresentedHistoryRow(client_->history()->rowCount(), original_revision);
    QVERIFY(activate(1, QStringLiteral("not-a-revision")));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    QVERIFY(activate(1, original_revision));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 1);
    QVERIFY(activate(0, original_revision));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    client_->searchHistory(QStringLiteral("GUI_ROW_PRESENTATION_B_"));
    QVERIFY(activate(1, original_revision));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading(), runtime_wait_ms);
    QCOMPARE(client_->history()->rowCount(), 2);
    QVERIFY(QMetaObject::invokeMethod(results, "forceLayout"));
    const auto current_revision = client_->historyState().value(QStringLiteral("revision")).toString();
    QVERIFY(current_revision != original_revision);
    QVERIFY(activate(1, original_revision));
    QVERIFY(activate(1, current_revision));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    window_->beforeSynchronizing();
    window_->frameSwapped();
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    QVERIFY(activate(1, original_revision));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    QVERIFY(activate(1, current_revision));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 1);
    QCOMPARE(client_->historyCommand(), QStringLiteral("echo GUI_ROW_PRESENTATION_B_FIRST"));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    QCOMPARE(client_->historyState().value(QStringLiteral("error")).toString(), QString{});
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
    const std::array entries{
        telar::ImportHistoryEntry{.started_at_ms = 100, .command = "echo GUI_HISTORY_RESTORE_FIRST"},
        telar::ImportHistoryEntry{.started_at_ms = 101, .command = "echo GUI_HISTORY_RESTORE_SECOND"},
    };
    importHistory(entries, "gui-history-restore");
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
      window_->showNormal();
      QVERIFY(test::showWindow(*window_, runtime_wait_ms));
      if (const auto *pane = firstPane()) {
        client_->input(pane->id, "\x15");
      }
    });
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_RESTORE_FIRST"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 1, runtime_wait_ms);
    QVERIFY(waitForHistoryPresentation());
    const auto original_revision = client_->historyState().value(QStringLiteral("revision")).toString();

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
    client_->searchHistory(QStringLiteral("GUI_HISTORY_RESTORE_SECOND"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 1, runtime_wait_ms);
    QCOMPARE(client_->historyCommand(), QStringLiteral("echo GUI_HISTORY_RESTORE_SECOND"));
    const auto replacement_revision = client_->historyState().value(QStringLiteral("revision")).toString();
    QVERIFY(replacement_revision != original_revision);
    QVERIFY(!test::HistoryPresentation::current(*client_));
    auto *footer = window_->findChild<QQuickItem *>(QStringLiteral("historyFooter"));
    QVERIFY(footer != nullptr);
    QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, QStringLiteral("submit")), Q_ARG(QString, replacement_revision)));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));

    const QSignalSpy frames{window_, &QQuickWindow::frameSwapped};
    window_->showNormal();
    QVERIFY(test::showWindow(*window_, runtime_wait_ms));
    QVERIFY(waitForHistoryPresentation());
    QVERIFY(!frames.empty());
    QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, QStringLiteral("submit")), Q_ARG(QString, original_revision)));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, QStringLiteral("submit")), Q_ARG(QString, replacement_revision)));
    QCOMPARE(client_->dialog(), QString{});
    const auto *pane = firstPane();
    QVERIFY(pane != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(QLatin1StringView("echo GUI_HISTORY_RESTORE_SECOND")), runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void historyFooterPastesInPasteMode() {
    verifyPresentedHistorySubmitMode(false, false, QStringLiteral("paste-primary"));
  }

  Q_SLOT void historyFooterRunsTheAlternateInPasteMode() {
    verifyPresentedHistorySubmitMode(false, true, QStringLiteral("paste-alternate"));
  }

  Q_SLOT void historyFooterRunsInRunMode() {
    verifyPresentedHistorySubmitMode(true, false, QStringLiteral("run-primary"));
  }

  Q_SLOT void historyFooterPastesTheAlternateInRunMode() {
    verifyPresentedHistorySubmitMode(true, true, QStringLiteral("run-alternate"));
  }

  void verifyPresentedHistorySubmitMode(bool enter_runs, bool alternate, const QString &tag) {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto initial_path = directory.filePath(QStringLiteral("initial.lua"));
    const auto final_path = directory.filePath(QStringLiteral("final.lua"));
    const char *paste_configuration = "return {api_version=2,client={history={enter='paste'}}}";
    const char *run_configuration = "return {api_version=2,client={history={enter='run'}}}";
    writeTestFile(initial_path, enter_runs ? paste_configuration : run_configuration);
    writeTestFile(final_path, enter_runs ? run_configuration : paste_configuration);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
      QVERIFY(test::showWindow(*window_, runtime_wait_ms));
      if (const auto *pane = firstPane()) {
        client_->input(pane->id, "\x15");
      }

      client_->loadConfiguration({}, {}, {});
    });
    client_->loadConfiguration(initial_path, {}, {});
    QTRY_COMPARE_WITH_TIMEOUT(client_->configuration().history.enter_runs, !enter_runs, runtime_wait_ms);
    const auto command = QStringLiteral("printf 'GUI_HISTORY_RENDER_%s_%1\\n' DONE").arg(tag);
    const auto encoded = command.toUtf8();
    const std::array entries{telar::ImportHistoryEntry{.started_at_ms = 100, .command = std::string_view{encoded.constData(), static_cast<std::size_t>(encoded.size())}}};
    const auto source = QByteArrayLiteral("gui-history-render-") + tag.toUtf8();
    importHistory(entries, source.constData());
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_RENDER_%s_%1").arg(tag));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 1, runtime_wait_ms);
    window_->hide();
    QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    window_->beforeSynchronizing();
    window_->frameSwapped();
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    const auto previous_revision = client_->historyState().value(QStringLiteral("revision")).toString();
    client_->loadConfiguration(final_path, {}, {});
    QTRY_COMPARE_WITH_TIMEOUT(client_->configuration().history.enter_runs, enter_runs, runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("enterRuns")).toBool(), enter_runs);
    auto *footer = window_->findChild<QQuickItem *>(QStringLiteral("historyFooter"));
    QVERIFY(footer != nullptr);
    const auto action = alternate ? QStringLiteral("alternate") : QStringLiteral("submit");
    const auto revision = client_->historyState().value(QStringLiteral("revision")).toString();
    QCOMPARE(revision, previous_revision);
    QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, action), Q_ARG(QString, revision)));
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    window_->beforeSynchronizing();
    window_->frameSwapped();
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    QVERIFY(QMetaObject::invokeMethod(footer, "actionTriggered", Q_ARG(QString, action), Q_ARG(QString, revision)));
    QCOMPARE(client_->dialog(), QString{});
    QVERIFY(test::showWindow(*window_, runtime_wait_ms));
    const auto *pane = firstPane();
    QVERIFY(pane != nullptr);
    const auto output = QStringLiteral("GUI_HISTORY_RENDER_DONE_%1").arg(tag);
    if (enter_runs != alternate) {
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(output), runtime_wait_ms);
    } else {
      QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen, ScreenTextLayout::logical).contains(command), runtime_wait_ms);
      QVERIFY(!screenText(pane->screen, ScreenTextLayout::logical).contains(output));
    }

    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void historyPagesAndActions() {
    seedHistoryPages();
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_BROWSER_PAGE"));
    constexpr auto page_entries = static_cast<int>(HistoryBrowser<ApplicationAllocator>::page_entries);
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == page_entries, runtime_wait_ms);
    QVERIFY(client_->historyState().value(QStringLiteral("canOlder")).toBool());
    captureHistoryArtifact(QStringLiteral("history-page"));
    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    if (search == nullptr) {
      QFAIL("Required command search fixture is missing");
    }

    QKeyEvent select_older{QEvent::KeyPress, Qt::Key_Up, Qt::NoModifier};
    QCoreApplication::sendEvent(search, &select_older);
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 1);
    QKeyEvent select_newer{QEvent::KeyPress, Qt::Key_Down, Qt::NoModifier};
    QCoreApplication::sendEvent(search, &select_newer);
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);

    QKeyEvent older{QEvent::KeyPress, Qt::Key_PageUp, Qt::NoModifier};
    QCoreApplication::sendEvent(search, &older);
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 1, runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("offset")).toULongLong(), static_cast<qulonglong>(page_entries));
    const auto selected = client_->history()->data(client_->history()->index(0, 0), ListModel::record_role).toMap();

    QKeyEvent inspect{QEvent::KeyPress, Qt::Key_O, NativeKeyAdapter::control_modifier};
    QCoreApplication::sendEvent(search, &inspect);
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("outputPhase")).toString(), QStringLiteral("ready"), runtime_wait_ms);
    QCOMPARE(client_->historyOutput(), QString{});
    captureHistoryArtifact(QStringLiteral("history-inspection"));
    QKeyEvent close_output{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier};
    QCoreApplication::sendEvent(search, &close_output);
    QVERIFY(!client_->historyState().value(QStringLiteral("inspecting")).toBool());
    QCOMPARE(client_->dialog(), QStringLiteral("history"));

    auto *clipboard = QGuiApplication::clipboard();
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
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == page_entries, runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("offset")).toULongLong(), qulonglong{0});
    QVERIFY(!client_->historyState().value(QStringLiteral("canOlder")).toBool());

    client_->setHistoryFilters({{QStringLiteral("author"), QStringLiteral("agent")}});
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 0, runtime_wait_ms);
    client_->setHistoryFilters({{QStringLiteral("author"), QStringLiteral("human")}, {QStringLiteral("failedOnly"), true}});
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 0, runtime_wait_ms);
    client_->setHistoryFilters({{QStringLiteral("scope"), QStringLiteral("pane")}, {QStringLiteral("failedOnly"), false}});
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading(), runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("effectiveScope")).toString(), QStringLiteral("pane"));
    client_->execute(Application::Action::cancel);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void historyScopeLabelsFollowTheFocusedContext() {
    QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && !firstPane()->cwd.empty(), runtime_wait_ms);
    const auto pane_id = firstPane()->id;
    const auto original_directory = QFileInfo{toQString(firstPane()->cwd)}.canonicalFilePath();
    QVERIFY(!original_directory.isEmpty());
    const auto change_directory = [this, pane_id](QString directory) {
      directory.replace(QLatin1Char('\''), QLatin1StringView("'\\''"));
      client_->input(pane_id, QByteArray{"\x15"
                                         "cd '"} +
                                  directory.toUtf8() + "' && pwd\r");
    };
    const auto restore = qScopeGuard([&] {
      change_directory(original_directory);
      client_->execute(Application::Action::cancel);
    });
    client_->execute(Application::Action::history);
    client_->setHistoryFilters({{QStringLiteral("scope"), QStringLiteral("cwd")}});
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading(), runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("effectiveScope")).toString(), QStringLiteral("cwd"));
    QCOMPARE(client_->historyState().value(QStringLiteral("scopeValue")).toString(), toQString(HistoryPath::compact(std::string_view{firstPane()->cwd}).view()));
    const auto revision = client_->historyState().value(QStringLiteral("revision"));
    const QTemporaryDir changed_directory;
    QVERIFY(changed_directory.isValid());
    const auto changed_path = QFileInfo{changed_directory.path()}.canonicalFilePath();
    QVERIFY(!changed_path.isEmpty());
    change_directory(changed_path);
    QTRY_VERIFY2_WITH_TIMEOUT(toQString(firstPane()->cwd) == changed_path, qPrintable(screenText(firstPane()->screen, ScreenTextLayout::logical)), runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("scopeValue")).toString(), toQString(HistoryPath::compact(std::string_view{firstPane()->cwd}).view()), runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("revision")), revision);
    client_->setHistoryFilters({{QStringLiteral("scope"), QStringLiteral("global")}});
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading(), runtime_wait_ms);
    QVERIFY(client_->historyState().value(QStringLiteral("scopeValue")).toString().isEmpty());
    change_directory(original_directory);
    QTRY_COMPARE_WITH_TIMEOUT(toQString(firstPane()->cwd), original_directory, runtime_wait_ms);
  }

  Q_SLOT void historyControllerUpdatesKeepTheVisibleQuerySynchronized() {
    client_->execute(Application::Action::history);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    const auto query = QStringLiteral("!  GUI_HISTORY_FIXTURE");
    client_->searchHistory(query);
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading(), runtime_wait_ms);
    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), query, runtime_wait_ms);
    QVERIFY(QMetaObject::invokeMethod(search, "select", Q_ARG(int, 0), Q_ARG(int, 1)));
    QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};
    QCoreApplication::sendEvent(search, &preedit);
    client_->setHistoryFilters({{QStringLiteral("author"), QStringLiteral("agent")}});
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading(), runtime_wait_ms);
    QCOMPARE(search->property("text").toString(), query);
    QVERIFY(test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
    QVERIFY(search->property("layout").toMap().value(QStringLiteral("composing")).toBool());
    QCOMPARE(search->property("selectionStart").toInt(), 0);
    QCOMPARE(search->property("selectionEnd").toInt(), 1);
    const auto replacement = QStringLiteral("GUI_HISTORY_NEW_QUERY");
    client_->searchHistory(replacement);
    QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), replacement, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
  }

  Q_SLOT void historyQueryOverflowPublishesTheExistingLimitNotice() {
    client_->execute(Application::Action::history);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    const auto maximum = client_->historyState().value(QStringLiteral("maximumQueryBytes")).toInt();
    const QString typed(maximum + 1, QLatin1Char('x'));
    QInputMethodEvent commit;
    commit.setCommitString(typed);
    QCoreApplication::sendEvent(search, &commit);
    QCOMPARE(search->property("text").toString(), typed.first(maximum));
    const auto reached = [this] {
      return std::ranges::any_of(client_->notifications().items(), [](const auto &notice) {
        return notice.title.view() == "Limit reached" && notice.message.view().find("prompt.history_query_bytes") != std::string_view::npos;
      });
    };
    QTRY_VERIFY_WITH_TIMEOUT(reached(), runtime_wait_ms);
    const auto notice = std::ranges::find_if(client_->notifications().items(), [](const auto &item) {
      return item.title.view() == "Limit reached" && item.message.view().find("prompt.history_query_bytes") != std::string_view::npos;
    });
    const auto identity = notice->id;
    captureHistoryArtifact(QStringLiteral("history-query-limit"));
    client_->dismissNotification(client_->notificationIdentity(identity));
    QTRY_VERIFY_WITH_TIMEOUT(client_->notifications().find(identity) == nullptr, runtime_wait_ms);

    const QString retained(maximum - 1, QLatin1Char('x'));
    client_->searchHistory(retained + QStringLiteral("🧵"));
    QTRY_COMPARE_WITH_TIMEOUT(search->property("text").toString(), retained, runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("editorText")).toString(), retained);
  }

  Q_SLOT void historyShiftTabCyclesAuthorsForBothQtKeyForms() {
    client_->execute(Application::Action::history);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    client_->setHistoryFilters({{QStringLiteral("scope"), QStringLiteral("global")}, {QStringLiteral("author"), QStringLiteral("human")}});
    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    if (search == nullptr) {
      QFAIL("History query field must exist");
    }

    search->forceActiveFocus();
    QTest::keyClick(window_, Qt::Key_Tab, Qt::ShiftModifier);
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("author")).toString(), QStringLiteral("agent"), runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("scope")).toString(), QStringLiteral("global"));
    QTest::keyClick(window_, Qt::Key_Backtab, Qt::ShiftModifier);
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("author")).toString(), QStringLiteral("all"), runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("scope")).toString(), QStringLiteral("global"));
    QVERIFY(search->hasActiveFocus());
  }

  Q_SLOT void historyEmptyRecoveryPreservesQueryAndFocus() {
    seedHistoryScroll();
    client_->execute(Application::Action::history);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    const auto query = QStringLiteral("GUI_SCROLL_HISTORY_NO_MATCH");
    client_->setHistoryFilters({{QStringLiteral("scope"), QStringLiteral("workspace")}, {QStringLiteral("author"), QStringLiteral("all")}});
    client_->searchHistory(query);
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 0, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("effectiveScope")).toString(), QStringLiteral("workspace"), runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(window_->findChild<QQuickItem *>(QStringLiteral("historyEmptyTitle")) != nullptr, runtime_wait_ms);
    const auto *title = window_->findChild<QQuickItem *>(QStringLiteral("historyEmptyTitle"));
    const auto *button = window_->findChild<QQuickItem *>(QStringLiteral("historySearchEverywhere"));
    const auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    if (title == nullptr || button == nullptr || search == nullptr) {
      QFAIL("Empty history controls and the query field must exist");
    }

    QCOMPARE(title->property("text").toString(), QStringLiteral("No matches in workspace ") + client_->workspaceContext().value(QStringLiteral("name")).toString());
    QVERIFY(waitForHistoryPresentation());
    QVERIFY(button->isVisible());
    QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, button->mapToScene({button->width() / 2, button->height() / 2}).toPoint());
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->historyState().value(QStringLiteral("effectiveScope")).toString() == QStringLiteral("global"), runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("editorText")).toString(), query);
    QVERIFY(search->hasActiveFocus());
    QTRY_COMPARE_WITH_TIMEOUT(title->property("text").toString(), QStringLiteral("No matching commands"), runtime_wait_ms);
    QVERIFY(!button->isVisible());
    client_->searchHistory(QStringLiteral("GUI_SCROLL_HISTORY_A_"));
    constexpr int count = 4;
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == count, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(window_->findChild<QQuickItem *>(QStringLiteral("historyEmptyTitle")) == nullptr, runtime_wait_ms);
  }

  Q_SLOT void historyWheelMovesSelectionAcrossTheWholeModal() {
    seedHistoryScroll();
    client_->execute(Application::Action::history);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    client_->searchHistory(QStringLiteral("GUI_SCROLL_HISTORY_A_"));
    constexpr int count = 4;
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == count, runtime_wait_ms);
    const auto *panel = window_->findChild<QQuickItem *>(QStringLiteral("historyPanel"));
    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    if (panel == nullptr || search == nullptr) {
      QFAIL("History panel and search field must exist");
    }
    search->forceActiveFocus();
    constexpr int half_notch = 60;
    for (const auto *region : {"header", "results", "search", "footer"}) {
      client_->selectHistoryRow(0);
      QVERIFY(waitForHistoryPresentation());
      const auto area = client_->historyGeometry().value(QString::fromLatin1(region)).toRectF();
      const auto position = panel->mapToScene(area.center());
      QVERIFY(sendHistoryWheel(position, {}, {0, half_notch}, Qt::ScrollBegin));
      QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
      QVERIFY(sendHistoryWheel(position, {}, {0, half_notch}, Qt::ScrollUpdate));
      QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);
      QVERIFY(search->hasActiveFocus());
      QCOMPARE(client_->dialog(), QStringLiteral("history"));
    }

    client_->selectHistoryRow(0);
    QVERIFY(waitForHistoryPresentation());
    auto row_height = std::numeric_limits<qreal>::max();
    for (const auto *row : test::visualItems(*window_->contentItem(), QStringLiteral("historyRow"))) {
      if (row->isVisible()) {
        row_height = std::min(row_height, row->property("layout").toMap().value(QStringLiteral("frame")).toRectF().height());
      }
    }

    if (row_height == std::numeric_limits<qreal>::max()) {
      QFAIL("A delivered history row must exist");
    }

    const auto grid = client_->windowGeometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid")).toMap();
    const auto cell_pixels = static_cast<int>(std::ceil(grid.value(QStringLiteral("cellHeight")).toDouble()));
    const auto row_pixels = static_cast<int>(std::ceil(row_height));
    QVERIFY(cell_pixels > 0 && cell_pixels < row_pixels);
    const auto position = panel->mapToScene(client_->historyGeometry().value(QStringLiteral("header")).toRectF().center());
    QVERIFY(sendHistoryWheel(position, {0, cell_pixels}, {0, cell_pixels * 2}, Qt::ScrollBegin));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    QVERIFY(sendHistoryWheel(position, {0, row_pixels - cell_pixels}, {0, (row_pixels - cell_pixels) * 2}, Qt::ScrollUpdate));
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);

    const auto selected = client_->historyState().value(QStringLiteral("selection")).toInt();
    QVERIFY(sendHistoryWheel(panel->mapToScene({panel->width() + 1, panel->height() / 2}), {}, {0, half_notch * 2}, Qt::ScrollBegin));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), selected);
  }

  Q_SLOT void historyWheelKeepsFractionThroughAnEmptyPresentedPage() {
    seedHistoryScroll();
    client_->execute(Application::Action::history);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    client_->searchHistory(QStringLiteral("GUI_SCROLL_HISTORY_NO_MATCH"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 0, runtime_wait_ms);
    QVERIFY(waitForHistoryPresentation());
    const auto *panel = window_->findChild<QQuickItem *>(QStringLiteral("historyPanel"));
    if (panel == nullptr) {
      QFAIL("History panel must exist");
    }

    const auto position = panel->mapToScene(client_->historyGeometry().value(QStringLiteral("header")).toRectF().center());
    constexpr int half_notch = 60;
    QVERIFY(sendHistoryWheel(position, {}, {0, half_notch}, Qt::ScrollBegin));
    client_->searchHistory(QStringLiteral("GUI_SCROLL_HISTORY_A_"));
    constexpr int count = 4;
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == count, runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    QVERIFY(waitForHistoryPresentation());
    QVERIFY(sendHistoryWheel(position, {}, {0, half_notch}, Qt::ScrollUpdate));
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);
  }

  Q_SLOT void historyWheelScrollsInspectionFromEveryBand() {
    std::string command;
    constexpr int command_lines = 80;
    for (int index = 0; index < command_lines; ++index) {
      command += "printf GUI_SCROLL_INSPECTION_" + std::to_string(index) + "\n";
    }

    const std::array entries{telar::ImportHistoryEntry{.started_at_ms = 100, .command = command}};
    importHistory(entries, "gui-wheel-inspection");
    client_->execute(Application::Action::history);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    client_->searchHistory(QStringLiteral("GUI_SCROLL_INSPECTION_"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 1, runtime_wait_ms);
    client_->executeHistory(Application::HistoryAction::inspect);
    QTRY_VERIFY_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("commandLoaded")).toBool(), runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("outputPhase")).toString(), QStringLiteral("ready"), runtime_wait_ms);
    const auto *panel = window_->findChild<QQuickItem *>(QStringLiteral("historyPanel"));
    if (panel == nullptr) {
      QFAIL("History panel must exist");
    }
    QTRY_VERIFY_WITH_TIMEOUT(window_->findChild<QQuickItem *>(QStringLiteral("historyInspector")) != nullptr, runtime_wait_ms);
    const auto *inspector = window_->findChild<QQuickItem *>(QStringLiteral("historyInspector"));
    if (inspector == nullptr) {
      QFAIL("History inspector must exist");
    }
    QTRY_VERIFY_WITH_TIMEOUT(inspector->property("layout").toMap().value(QStringLiteral("maximumScroll")).toInt() > 0, runtime_wait_ms);
    QVERIFY(waitForHistoryPresentation());
    constexpr int notch = 120;
    int expected_scroll = 0;
    for (const auto *region : {"header", "results", "search", "footer"}) {
      const auto area = client_->historyGeometry().value(QString::fromLatin1(region)).toRectF();
      QVERIFY(sendHistoryWheel(panel->mapToScene(area.center()), {}, {0, -notch}, Qt::ScrollBegin));
      ++expected_scroll;
      QTRY_COMPARE_WITH_TIMEOUT(inspector->property("scroll").toInt(), expected_scroll, runtime_wait_ms);
      QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    }

    const auto grid = client_->windowGeometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid")).toMap();
    const auto whole_cell = static_cast<int>(std::ceil(grid.value(QStringLiteral("cellHeight")).toDouble()));
    QVERIFY(whole_cell > 1);
    const auto half_cell = whole_cell / 2;
    const auto position = panel->mapToScene(client_->historyGeometry().value(QStringLiteral("header")).toRectF().center());
    QVERIFY(sendHistoryWheel(position, {0, -half_cell}, {0, -half_cell * 2}, Qt::ScrollBegin));
    QCOMPARE(inspector->property("scroll").toInt(), expected_scroll);
    QVERIFY(sendHistoryWheel(position, {0, -(whole_cell - half_cell)}, {0, -(whole_cell - half_cell) * 2}, Qt::ScrollUpdate));
    QTRY_COMPARE_WITH_TIMEOUT(inspector->property("scroll").toInt(), expected_scroll + 1, runtime_wait_ms);
  }

  Q_SLOT void historyWheelWaitsForPresentedRowsAndDialogGeneration() {
    seedHistoryScroll();
    client_->execute(Application::Action::history);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
      QVERIFY(test::showWindow(*window_, runtime_wait_ms));
    });
    client_->searchHistory(QStringLiteral("GUI_SCROLL_HISTORY_A_"));
    constexpr int count = 4;
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == count, runtime_wait_ms);
    QVERIFY(waitForHistoryPresentation());
    const auto *panel = window_->findChild<QQuickItem *>(QStringLiteral("historyPanel"));
    if (panel == nullptr) {
      QFAIL("History panel must exist");
    }
    const auto position = panel->mapToScene(client_->historyGeometry().value(QStringLiteral("header")).toRectF().center());
    window_->hide();
    QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    client_->searchHistory(QStringLiteral("GUI_SCROLL_HISTORY_B_"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == count, runtime_wait_ms);
    constexpr int notch = 120;
    QVERIFY(sendHistoryWheel(position, {}, {0, notch}, Qt::ScrollBegin));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    window_->beforeSynchronizing();
    QVERIFY(sendHistoryWheel(position, {}, {0, notch}, Qt::ScrollUpdate));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    QVERIFY(test::showWindow(*window_, runtime_wait_ms));
    QVERIFY(waitForHistoryPresentation());
    QVERIFY(sendHistoryWheel(position, {}, {0, notch}, Qt::ScrollBegin));
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);
    window_->hide();
    QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
    client_->execute(Application::Action::cancel);
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_SCROLL_HISTORY_B_"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == count, runtime_wait_ms);
    QVERIFY(sendHistoryWheel(position, {}, {0, notch}, Qt::ScrollBegin));
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    QVERIFY(test::showWindow(*window_, runtime_wait_ms));
    QVERIFY(waitForHistoryPresentation());
    QVERIFY(sendHistoryWheel(position, {}, {0, notch}, Qt::ScrollBegin));
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("selection")).toInt(), 1, runtime_wait_ms);
  }

  Q_SLOT void historyWheelStopsAtPageAdmission() {
    constexpr auto page_count = HistoryBrowser<ApplicationAllocator>::page_entries;
    constexpr auto entry_count = page_count + 2;
    std::array<std::string, entry_count> commands;
    std::array<telar::ImportHistoryEntry, entry_count> entries{};
    for (std::size_t index = 0; index < entries.size(); ++index) {
      commands[index] = "echo GUI_SCROLL_PAGE_" + std::to_string(index);
      entries[index] = {.started_at_ms = static_cast<std::int64_t>(index), .command = commands[index]};
    }

    importHistory(entries, "gui-wheel-page");
    client_->execute(Application::Action::history);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    client_->searchHistory(QStringLiteral("GUI_SCROLL_PAGE_"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == page_count, runtime_wait_ms);
    client_->selectHistoryRow(page_count - 2);
    QVERIFY(waitForHistoryPresentation());
    const auto *panel = window_->findChild<QQuickItem *>(QStringLiteral("historyPanel"));
    if (panel == nullptr) {
      QFAIL("History panel must exist");
    }
    const auto position = panel->mapToScene(client_->historyGeometry().value(QStringLiteral("header")).toRectF().center());
    constexpr int notch = 120;
    QVERIFY(sendHistoryWheel(position, {}, {0, notch * 2}, Qt::ScrollBegin));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->historyState().value(QStringLiteral("offset")).toInt() == page_count, runtime_wait_ms);
    QCOMPARE(client_->history()->rowCount(), 2);
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), 0);
    QVERIFY(waitForHistoryPresentation());
    QVERIFY(sendHistoryWheel(position, {}, {0, -notch}, Qt::ScrollBegin));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->historyState().value(QStringLiteral("offset")).toInt() == 0, runtime_wait_ms);
    QCOMPARE(client_->historyState().value(QStringLiteral("selection")).toInt(), page_count - 1);
  }

  Q_SLOT void historyCompositionConsumesTheFirstEscape() {
    verifyHistoryCompositionEscape(HistoryView::results);
  }

  Q_SLOT void historyInspectionCompositionConsumesTheFirstEscape() {
    verifyHistoryCompositionEscape(HistoryView::inspector);
  }

  Q_SLOT void historyInspectionTracksTabRenamingAndPaneClosure() {
    const auto original_tabs = client_->tabs()->rowCount();
    const auto *original = firstPane();
    QVERIFY(original != nullptr);
    const auto original_identity = original->id;
    const auto restore = qScopeGuard([this, original_tabs, original_identity] {
      client_->execute(Application::Action::cancel);
      if (client_->tabs()->rowCount() > original_tabs) {
        closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
      }
    });
    client_->execute(Application::Action::new_tab);
    QTRY_VERIFY_WITH_TIMEOUT(client_->tabs()->rowCount() == original_tabs + 1 && terminalReady() && firstPane()->id != original_identity, runtime_wait_ms);
    const auto pane_id = firstPane()->id;
    client_->input(pane_id, "printf 'GUI_HISTORY_LIVE_METADATA\\n'\n");
    const auto printed = [&] {
      const auto lines = screenText(firstPane()->screen, ScreenTextLayout::logical).split(QLatin1Char('\n'));

      return std::ranges::any_of(lines, [](const auto &line) {
        return line.trimmed() == QLatin1StringView("GUI_HISTORY_LIVE_METADATA");
      });
    };
    QTRY_VERIFY_WITH_TIMEOUT(printed(), runtime_wait_ms);
    client_->input(pane_id, "\x15");
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_LIVE_METADATA"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 1, runtime_wait_ms);
    QVERIFY(client_->historyState().value(QStringLiteral("paneOpen")).toBool());
    client_->executeHistory(Application::HistoryAction::inspect);
    QTRY_VERIFY_WITH_TIMEOUT(window_->findChild<QQuickItem *>(QStringLiteral("historyInspector")) != nullptr, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("outputPhase")).toString() != QLatin1StringView("loading") && client_->historyState().value(QStringLiteral("commandPhase")).toString() != QLatin1StringView("loading"), runtime_wait_ms);
    QVERIFY(waitForHistoryPresentation());
    const QPointer<QQuickItem> inspector = window_->findChild<QQuickItem *>(QStringLiteral("historyInspector"));
    const auto pane_fact = [&] {
      if (!inspector) {
        return QString{};
      }

      for (const auto &fact : inspector->property("details").toMap().value(QStringLiteral("facts")).toList()) {
        const auto entry = fact.toMap();
        if (entry.value(QStringLiteral("label")).toString() == QLatin1StringView("Pane")) {
          return entry.value(QStringLiteral("text")).toString();
        }
      }

      return QString{};
    };
    const auto revision = client_->historyState().value(QStringLiteral("revision")).toString();
    const auto query = client_->historyState().value(QStringLiteral("editorText")).toString();
    const auto command = client_->historyCommand();
    const QSignalSpy rows_changed{client_->history(), &QAbstractItemModel::dataChanged};
    test::HistoryPresentation::renameTab(*client_, "Live history tab");
    const auto tab_renamed = [&] {
      for (int index = 0; index < client_->tabs()->rowCount(); ++index) {
        if (client_->tabs()->data(client_->tabs()->index(index, 0), ListModel::record_role).toMap().value(QStringLiteral("label")).toString() == QLatin1StringView("Live history tab")) {
          return true;
        }
      }

      return false;
    };
    QTRY_VERIFY_WITH_TIMEOUT(tab_renamed(), runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(pane_fact(), QString::number(pane_id) + QStringLiteral("  ·  tab Live history tab"), runtime_wait_ms);
    client_->execute(Application::Action::close_tab);
    QTRY_VERIFY_WITH_TIMEOUT(client_->tabs()->rowCount() == original_tabs && client_->pane(pane_id) == nullptr, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(pane_fact(), QString::number(pane_id) + QStringLiteral("  ·  closed"), runtime_wait_ms);
    QVERIFY(!inspector->property("browserState").toMap().value(QStringLiteral("paneOpen")).toBool());
    QVERIFY(!client_->historyState().value(QStringLiteral("paneOpen")).toBool());
    QCOMPARE(client_->historyState().value(QStringLiteral("revision")).toString(), revision);
    QCOMPARE(client_->historyState().value(QStringLiteral("editorText")).toString(), query);
    QCOMPARE(client_->historyCommand(), command);
    QCOMPARE(client_->history()->rowCount(), 1);
    QCOMPARE(rows_changed.size(), 0);
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void historyGeometryAndFocusSurviveInspection() {
    const auto previous_size = window_->size();
    const auto restore = qScopeGuard([this, previous_size] {
      client_->execute(Application::Action::cancel);
      window_->resize(previous_size);
    });
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_FIXTURE"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() > 0, runtime_wait_ms);
    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    const auto *panel = window_->findChild<QQuickItem *>(QStringLiteral("historyPanel"));
    const auto *results = window_->findChild<QQuickItem *>(QStringLiteral("historyResults"));
    QVERIFY(search != nullptr && panel != nullptr && results != nullptr);
    const auto search_bounds = [&] {
      return search->mapRectToScene(QRectF{QPointF{}, search->size()});
    };
    const auto expected_search = [&] {
      const auto geometry = client_->historyGeometry();

      return geometry.value(QStringLiteral("search")).toRectF().translated(geometry.value(QStringLiteral("bounds")).toRectF().topLeft());
    };
    search->forceActiveFocus();
    QTRY_COMPARE(search_bounds().top(), expected_search().top());
    QCOMPARE(search_bounds().height(), expected_search().height());
    QVERIFY(expected_search().contains(search_bounds()));
    QVERIFY(search_bounds().y() > static_cast<qreal>(window_->height()) / 2);
    const auto original_search = search_bounds();
    const auto original_panel_size = panel->size();
    client_->executeHistory(Application::HistoryAction::inspect);
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

    client_->executeHistory(Application::HistoryAction::inspect);
    QTRY_VERIFY_WITH_TIMEOUT(results->isVisible(), runtime_wait_ms);
    QVERIFY2(search_bounds() == narrow_search, qPrintable(search_observation()));
    QVERIFY(search->hasActiveFocus());
    captureHistoryArtifact(QStringLiteral("history-geometry-narrow"));

    client_->searchHistory(QStringLiteral("GUI_HISTORY_GEOMETRY_NO_MATCH"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 0, runtime_wait_ms);
    QVERIFY2(search_bounds() == narrow_search, qPrintable(search_observation()));
    QVERIFY(search->hasActiveFocus());
  }

  Q_SLOT void historyValidationFeedback() {
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_HISTORY_FIXTURE"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() > 0, runtime_wait_ms);
    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    if (search == nullptr) {
      QFAIL("Required history search fixture is missing");
    }

    QKeyEvent scope{QEvent::KeyPress, Qt::Key_Tab, Qt::NoModifier};
    QCoreApplication::sendEvent(search, &scope);
    QCOMPARE(client_->historyState().value(QStringLiteral("scope")).toString(), QStringLiteral("workspace"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading(), runtime_wait_ms);
    QKeyEvent author{QEvent::KeyPress, Qt::Key_Backtab, Qt::ShiftModifier};
    QCoreApplication::sendEvent(search, &author);
    QCOMPARE(client_->historyState().value(QStringLiteral("author")).toString(), QStringLiteral("agent"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == 0, runtime_wait_ms);
    client_->setHistoryFilters({{QStringLiteral("scope"), QStringLiteral("global")}, {QStringLiteral("author"), QStringLiteral("human")}});
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() > 0, runtime_wait_ms);
    const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
    QKeyEvent inspect{QEvent::KeyPress, Qt::Key_O, control};
    QCoreApplication::sendEvent(search, &inspect);
    QVERIFY(client_->historyState().value(QStringLiteral("inspecting")).toBool());
    QKeyEvent close_output{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier};
    QCoreApplication::sendEvent(window_, &close_output);
    QVERIFY(!client_->historyState().value(QStringLiteral("inspecting")).toBool());
    QCOMPARE(client_->dialog(), QStringLiteral("history"));

    client_->useHistory(QStringLiteral("0"));
    QVERIFY(!client_->historyState().value(QStringLiteral("error")).toString().isEmpty());
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    QCOMPARE(client_->error(), QString{});
    const auto entry = client_->history()->data(client_->history()->index(0, 0), ListModel::record_role).toMap();
    client_->useHistory(entry.value(QStringLiteral("key")).toString());
    QCOMPARE(client_->dialog(), QString{});
    const auto *pane = firstPane();
    if (pane == nullptr) {
      QFAIL("Required terminal fixture is missing");
    }

    client_->input(pane->id, "\x15");
  }

  Q_SLOT void historyLongCommands() {
    using Storage = HistoryPageStorage<ApplicationAllocator>;
    constexpr std::size_t command_bytes = std::size_t{48} * 1024;
    constexpr auto cached_entries = Storage::command_cache_bytes / command_bytes;
    constexpr auto entry_count = cached_entries + 1;
    std::array<std::string, entry_count> commands;
    std::array<telar::ImportHistoryEntry, entry_count> entries{};
    for (std::size_t index = 0; index < entries.size(); ++index) {
      commands[index] = "echo GUI_LONG_COMMAND_" + std::to_string(index) + " ";
      commands[index].resize(command_bytes, 'x');
      entries[index] = {.started_at_ms = static_cast<std::int64_t>(index) + 1, .command = commands[index]};
    }

    importHistory(entries, "gui-long-command");
    client_->execute(Application::Action::history);
    client_->searchHistory(QStringLiteral("GUI_LONG_COMMAND"));
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() == static_cast<int>(entry_count), runtime_wait_ms);
    const auto last = client_->history()->data(client_->history()->index(static_cast<int>(cached_entries), 0), ListModel::record_role).toMap();
    QVERIFY(last.value(QStringLiteral("command")).toString().toUtf8().size() <= static_cast<qsizetype>(Storage::command_preview_bytes));
    client_->selectHistoryRow(static_cast<int>(cached_entries));
    QTRY_COMPARE_WITH_TIMEOUT(client_->historyState().value(QStringLiteral("commandPhase")).toString(), QStringLiteral("ready"), runtime_wait_ms);
    QVERIFY(client_->historyState().value(QStringLiteral("canSubmit")).toBool());

    auto *clipboard = QGuiApplication::clipboard();
    auto saved_clipboard = test::copyClipboard();

    const auto restore_clipboard = qScopeGuard([clipboard, saved = std::move(saved_clipboard)] mutable {
      clipboard->setMimeData(saved.release());
    });
    client_->executeHistory(Application::HistoryAction::copy);
    const auto *const expected = std::ranges::find_if(commands, [&](const auto &command) {
      return toQString(command).startsWith(last.value(QStringLiteral("command")).toString());
    });
    QVERIFY(expected != commands.end());
    QCOMPARE(clipboard->text(), toQString(*expected));
    QCOMPARE(client_->historyCommand(), toQString(*expected));
    const auto selected_card = [&] {
      const auto cards = test::visualItems(*window_->contentItem(), QStringLiteral("historyRow"));
      const auto found = std::ranges::find_if(cards, [](const auto *card) {
        return card->property("selected").toBool();
      });

      return found == cards.end() ? nullptr : *found;
    };
    QTRY_VERIFY_WITH_TIMEOUT(selected_card() != nullptr, runtime_wait_ms);
    const auto *card = selected_card();
    if (card == nullptr) {
      QFAIL("Required selected history card is missing");
    }

    QCOMPARE(card->property("commandText").toString(), toQString(*expected));
    QTRY_COMPARE_WITH_TIMEOUT(card->property("layout").toMap().value(QStringLiteral("more")).toInt(), static_cast<int>(HistoryCard::more_bound), runtime_wait_ms);
    const auto *results = window_->findChild<QQuickItem *>(QStringLiteral("historyResults"));
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
    client_->executeHistory(Application::HistoryAction::inspect);
    const auto *command_area = window_->findChild<QQuickItem *>(QStringLiteral("historyCommand"));
    QVERIFY(command_area != nullptr);
    QCOMPARE(command_area->property("text").toString(), toQString(*expected));
    captureHistoryArtifact(QStringLiteral("history-long-command"));
    client_->execute(Application::Action::cancel);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void routedHistory() {
    CommandPeer peer{memory_};
    peer.open(socket_);
    QTRY_VERIFY2_WITH_TIMEOUT(peer.ready(), qPrintable(peer.error()), runtime_wait_ms);
    peer.request(telar::ClientAction::client_open_history, 2);
    QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{2}, runtime_wait_ms);
    QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
    QCOMPARE(peer.result().text, QString{});
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    QTRY_VERIFY_WITH_TIMEOUT(client_->history()->rowCount() > 0, runtime_wait_ms);
    client_->execute(Application::Action::cancel);
    QCOMPARE(peer.error(), QString{});
    QCOMPARE(client_->error(), QString{});
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
    const QSignalSpy unchanged{client_.get(), &Application::configurationChanged};
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

  Q_SLOT void appearanceChangesPreserveInputAndLayout() {
    const telar::gui::test::AppearanceFixture appearance;
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeTestFile(path, "return {api_version=2,theme='terminal',gui={window={background_opacity=0.75}},client={prefix='ctrl+a',appearance={light={colors={text='#010203',accent='#040506',panel_bg='#070809'}}},keybindings={telar.bind({'s'},telar.action.toggle_sidebar())}}}");
    const auto restore = qScopeGuard([this] {
      client_->loadConfiguration({}, {}, {});
    });
    client_->loadConfiguration(path, {}, {});
    QCOMPARE(client_->error(), QString{});
    telar::gui::test::AppearanceFixture::set(Qt::ColorScheme::Unknown);
    auto *terminal = terminalIn(window_->contentItem());
    QVERIFY(terminal != nullptr);
    terminal->forceActiveFocus();
    constexpr qreal retained_width = 317;
    client_->setSidebarWidth(retained_width);
    const auto before_width = client_->sidebarWidth();
    const auto visible = client_->sidebarVisible();
    const auto control = platform::usesCommandKey() ? Qt::MetaModifier : Qt::ControlModifier;
    QTest::keyClick(window_, Qt::Key_A, control);
    telar::gui::test::AppearanceFixture::set(Qt::ColorScheme::Light);
    const QColor light_text{1, 2, 3};
    QCOMPARE(client_->colors().value(QStringLiteral("foreground")).value<QColor>(), light_text);
    constexpr auto panel_rgb = 0x070809;
    QCOMPARE(client_->colors().value(QStringLiteral("panelBackground")).value<QColor>(), QColor::fromRgb(panel_rgb));
    QCOMPARE(client_->sidebarWidth(), before_width);
    QTest::keyClick(window_, Qt::Key_S);
    QCOMPARE(client_->sidebarVisible(), !visible);
    telar::gui::test::AppearanceFixture::set(Qt::ColorScheme::Dark);
    QCOMPARE(client_->sidebarVisible(), !visible);
    QCOMPARE(client_->sidebarWidth(), before_width);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void newTabsRecoverTheFullGridAfterNestedSplits() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    const TabRestorePoint before{.count = client_->tabs()->rowCount(), .pane_id = firstPane()->id};
    const auto restore = qScopeGuard([this, before] {
      closeExtraTabs(before.count);
    });
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), before.count + 1, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != before.pane_id, runtime_wait_ms);
    const auto *terminal = terminalIn(window_->contentItem());
    QVERIFY(terminal != nullptr);
    const auto resolved = client_->resolveFont(window_->devicePixelRatio());
    const TerminalGrid grid{.cell_width_px = resolved.grid.width, .cell_height_px = resolved.grid.height, .scale = window_->devicePixelRatio()};
    const auto full = grid.fit(terminal->width(), terminal->height());
    QVERIFY(full.has_value());
    QTRY_COMPARE_WITH_TIMEOUT(firstPane()->screen.columns(), full->cols, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(firstPane()->screen.rows(), full->rows, runtime_wait_ms);
    const auto source_id = firstPane()->id;
    client_->execute(Application::Action::split_horizontal);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
    const auto gutter = static_cast<std::uint16_t>(client_->configuration().pane_gaps);
    constexpr std::uint16_t border_cells = 2;
    const auto first_outer_columns = (full->cols - gutter) / 2;
    const auto second_outer_columns = full->cols - gutter - first_outer_columns;
    QTRY_COMPARE_WITH_TIMEOUT(client_->pane(source_id)->screen.columns(), first_outer_columns - border_cells, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(client_->pane(source_id)->screen.rows(), full->rows - border_cells, runtime_wait_ms);
    const auto second_record = client_->panes()->data(client_->panes()->index(1, 0), ListModel::record_role).toMap();
    const auto second_id = second_record.value(QStringLiteral("key")).toString().toULongLong();
    QTRY_COMPARE_WITH_TIMEOUT(client_->pane(second_id)->screen.columns(), second_outer_columns - border_cells, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(client_->pane(second_id)->screen.rows(), full->rows - border_cells, runtime_wait_ms);
    client_->execute(Application::Action::split_vertical);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 3, runtime_wait_ms);
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), before.count + 2, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != source_id, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(firstPane()->screen.columns(), full->cols, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(firstPane()->screen.rows(), full->rows, runtime_wait_ms);
    const auto expected = QStringLiteral("GUI_WORKBENCH_SIZE %1 %2").arg(full->rows).arg(full->cols);
    client_->input(firstPane()->id, "printf 'GUI_WORKBENCH_SIZE '; stty size\r");
    QTRY_VERIFY2_WITH_TIMEOUT(screenText(firstPane()->screen).contains(expected), qPrintable(screenText(firstPane()->screen)), runtime_wait_ms);
    QCOMPARE(firstPane()->size.cell_width_px, full->cell_width_px);
    QCOMPARE(firstPane()->size.cell_height_px, full->cell_height_px);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void fullscreenStripSwitchesHiddenPanesAndRestoresTiling() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    const TabRestorePoint before{.count = client_->tabs()->rowCount(), .pane_id = firstPane()->id};
    const auto restore = qScopeGuard([this, before] {
      closeTemporaryTab(before);
    });
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), before.count + 1, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    const auto source_id = firstPane()->id;
    client_->execute(Application::Action::split_horizontal);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
    client_->execute(Application::Action::fullscreen);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 1, runtime_wait_ms);
    const auto strips = [&] {
      return telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("paneFullscreenStrip"));
    };
    QTRY_VERIFY_WITH_TIMEOUT(strips().size() == 1 && strips().front()->isVisible(), runtime_wait_ms);
    const auto entries = [&] {
      return telar::gui::test::visualItems(*strips().front(), QStringLiteral("fullscreenPaneEntry"));
    };
    QTRY_COMPARE_WITH_TIMEOUT(entries().size(), 2, runtime_wait_ms);
    const QQuickItem *hidden = nullptr;
    for (const auto *entry : entries()) {
      const auto data = entry->property("entry").toMap();
      if (data.value(QStringLiteral("key")).toString() == QString::number(source_id)) {
        QVERIFY(!data.value(QStringLiteral("focused")).toBool());
        hidden = entry;
      }
    }

    QVERIFY(hidden != nullptr);
    QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, hidden->mapToScene({hidden->width() / 2, hidden->height() / 2}).toPoint());
    QTRY_COMPARE_WITH_TIMEOUT(firstPane()->id, source_id, runtime_wait_ms);
    QCOMPARE(client_->panes()->rowCount(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && strips().size() == 1, runtime_wait_ms);
    const auto buttons = telar::gui::test::visualItems(*strips().front(), QStringLiteral("leavePaneFullscreen"));
    QCOMPARE(buttons.size(), 1);
    const auto *button = buttons.front();
    QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, button->mapToScene({button->width() / 2, button->height() / 2}).toPoint());
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(strips().isEmpty(), runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void attentionRingsFollowUnfocusedAttachedPanes() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    const TabRestorePoint before{.count = client_->tabs()->rowCount(), .pane_id = firstPane()->id};
    const auto restore = qScopeGuard([this, before] {
      closeTemporaryTab(before);
    });
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), before.count + 1, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != before.pane_id, runtime_wait_ms);
    const auto source_id = firstPane()->id;
    const telar::gui::PaneAttentionKey attachment{.pane_id = source_id, .attachment_generation = firstPane()->attachment_generation};
    const auto *source_terminal = terminalIn(window_->contentItem());
    QVERIFY(source_terminal != nullptr);
    client_->execute(Application::Action::split_horizontal);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
    const auto *other_terminal = focusedTerminalBeside(*window_, *source_terminal);
    QVERIFY(other_terminal != nullptr);
    const auto other_id = other_terminal->paneIdentity();
    const auto report = QStringLiteral("%1 --report-blocked %2 %3 %4\r").arg(shellLiteral(QCoreApplication::applicationFilePath()), shellLiteral(socket_)).arg(source_id).arg(firstPane()->generation);
    client_->input(source_id, report.toUtf8());
    QTRY_VERIFY2_WITH_TIMEOUT(screenText(client_->pane(source_id)->screen, ScreenTextLayout::logical).contains(QStringLiteral("GUI_ATTENTION_READY")), qPrintable(screenText(client_->pane(source_id)->screen)), runtime_wait_ms);
    const auto rings = [&] {
      return telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("paneAttentionRing"));
    };
    QTRY_VERIFY2_WITH_TIMEOUT(rings().size() == 1, qPrintable(screenText(client_->pane(source_id)->screen)), runtime_wait_ms);
    QCOMPARE(telar::gui::qt::paneAttentionKey(rings().front()->property("attachment")).value_or(telar::gui::PaneAttentionKey{}), attachment);
    QTRY_COMPARE_WITH_TIMEOUT(rings().front()->property("alpha").toDouble(), 1, runtime_wait_ms);
    const QPointer<QQuickItem> retired{rings().front()};

    client_->execute(Application::Action::focus_pane, QString::number(source_id));
    QTRY_VERIFY_WITH_TIMEOUT(source_terminal->hasActiveFocus(), runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(rings().isEmpty() && retired.isNull(), runtime_wait_ms);
    client_->execute(Application::Action::focus_pane, QString::number(other_id));
    QTRY_COMPARE_WITH_TIMEOUT(rings().size(), 1, runtime_wait_ms);
    QCOMPARE(telar::gui::qt::paneAttentionKey(rings().front()->property("attachment")).value_or(telar::gui::PaneAttentionKey{}), attachment);

    client_->execute(Application::Action::fullscreen);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 1, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(rings().isEmpty(), runtime_wait_ms);
    client_->execute(Application::Action::fullscreen);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 2, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(rings().size(), 1, runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void configuredCommandsOpenAndCloseTheirOwnTabs() {
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady(), runtime_wait_ms);
    const TabRestorePoint before{.count = client_->tabs()->rowCount(), .pane_id = firstPane()->id};
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
      client_->configureLaunch(directory_.path(), {QStringLiteral("/bin/sh")}, true);
      closeExtraTabs(before.count);
    });
    client_->loadConfiguration(path, {}, {});
    QCOMPARE(client_->error(), QString{});
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), before.count + 1, runtime_wait_ms);
    QTRY_VERIFY2_WITH_TIMEOUT(terminalReady() && firstPane()->id != before.pane_id,
                              qPrintable(QStringLiteral("pane=%1 before=%2 tabs=%3 error=%4").arg(firstPane() == nullptr ? 0 : firstPane()->id).arg(before.pane_id).arg(client_->tabs()->rowCount()).arg(client_->error())),
                              runtime_wait_ms);
    QTRY_VERIFY2_WITH_TIMEOUT(!firstPane()->cwd.empty(), qPrintable(QStringLiteral("pane=%1 frame=%2 attached=%3 error=%4").arg(firstPane()->id).arg(firstPane()->screen.frameId()).arg(firstPane()->attached).arg(client_->error())), runtime_wait_ms);
    const auto source_id = firstPane()->id;
    const auto source_directory = toQString(firstPane()->cwd);
    const auto count = client_->tabs()->rowCount();
    const QTemporaryDir fallback;
    client_->configureLaunch(fallback.path(), {QStringLiteral("/bin/sh")}, true);

    struct CommandCase {
      Qt::Key key;
      const char *label;
      const char *marker;
      const char *argument;
    };

    constexpr auto cases = std::to_array<CommandCase>({
        {.key = Qt::Key_S, .label = "command-static", .marker = "STATIC", .argument = "quoted \"中\" $HOME $(printf IGNORED)"},
        {.key = Qt::Key_C, .label = "command-callback", .marker = "CALLBACK", .argument = "callback 1"},
        {.key = Qt::Key_C, .label = "command-callback", .marker = "CALLBACK", .argument = "callback 2"},
    });
    for (const auto &command : cases) {
      auto *terminal = terminalIn(window_->contentItem());
      QVERIFY(terminal != nullptr);
      terminal->forceActiveFocus();
      QTest::keyClick(window_, command.key, Qt::AltModifier);
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), count + 1, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != source_id, runtime_wait_ms);
      const auto expected = QStringLiteral("GUI_COMMAND_%1:%2:%3").arg(QString::fromUtf8(command.marker), source_directory, QString::fromUtf8(command.argument));
      QTRY_VERIFY2_WITH_TIMEOUT(screenText(firstPane()->screen).remove(QLatin1Char('\n')).contains(expected), qPrintable(screenText(firstPane()->screen)), runtime_wait_ms);
      const auto tab = client_->tabs()->data(client_->tabs()->index(count, 0), ListModel::record_role).toMap();
      QCOMPARE(tab.value(QStringLiteral("label")).toString(), QString::fromUtf8(command.label));
      client_->input(firstPane()->id, "quit\r");
      QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), count, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id == source_id, runtime_wait_ms);
    }

    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void routedClientConfigurationQuery() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeTestFile(path, "return {api_version=2,client={window_title='work {tab}',sound={enabled=false}},profiles={chosen={client={notifications={delivery='system'}}}}}");
    const auto original_collapsed = client_->workspaceListCollapsed();
    const auto restore = qScopeGuard([this, original_collapsed] {
      client_->loadConfiguration({}, {}, {});
      if (client_->workspaceListCollapsed() != original_collapsed) {
        client_->execute(Application::Action::toggle_workspace_list);
      }
    });
    client_->loadConfiguration(path, QStringLiteral("chosen"), {});
    QCOMPARE(client_->error(), QString{});
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
    client_->execute(Application::Action::toggle_sidebar);
    client_->execute(Application::Action::toggle_workspace_list);
    peer.request(telar::ClientAction::config_show, 4, "client", -1);
    QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{4}, runtime_wait_ms);
    QCOMPARE(peer.result().status, telar::ClientCommandStatus::applied);
    text = peer.result().text.toUtf8();
    parsed = telar::runtime::JsonValue::parse({text.constData(), static_cast<std::size_t>(text.size())});
    QCOMPARE(requiredJsonField(parsed, "generation").encoded(), std::string_view{generation});
    QCOMPARE(requiredJsonField(parsed, "sidebar_width").encoded(), std::string_view{expected_width});
    QCOMPARE(requiredJsonField(parsed, "sidebar_visible").boolean(), client_->sidebarVisible());
    QCOMPARE(requiredJsonField(parsed, "workspace_list_collapsed").boolean(), client_->workspaceListCollapsed());
    QCOMPARE(peer.error(), QString{});
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void routedBindingConfigurationQuery() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeTestFile(path, "return {api_version=2,client={keybindings={telar.bind({'c'},telar.action.command_tab{command={'echo','snapshot'},label='kept'}),telar.bind({'s'},function() error('a query must not execute this callback') end)}}}");
    const auto restore = qScopeGuard([this] {
      client_->loadConfiguration({}, {}, {});
    });
    client_->loadConfiguration(path, {}, {});
    QCOMPARE(client_->error(), QString{});
    const auto tab_count = client_->tabs()->rowCount();
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
    QCOMPARE(client_->tabs()->rowCount(), tab_count);
    QCOMPARE(client_->error(), QString{});
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
    QCOMPARE(client_->error(), QString{});
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
    const QByteArray source{"return {api_version=2,gui={font={size=18.25},window={background_opacity=0.75,padding={x=2.5}}},client={prefix='shift+tab',input={sequence_timeout_ms=500},keybindings={telar.bind_global({'g'},telar.action.toggle_sidebar())}}}"};
    QCOMPARE(file.write(source), source.size());
    file.close();
    client_->loadConfiguration(path, {}, {});
    QCOMPARE(client_->error(), QString{});
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
    QCOMPARE(client_->error(), QString{});
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
    client_->loadConfiguration(configuration_path, {}, {});
    constexpr std::uint64_t capped_interval = 1'000'000'000 / 30;
    QCOMPARE(telar::gui::qt::WindowAnimationClock::forWindow(*window_).frameInterval(), capped_interval);
    constexpr float configured_font_size = 18;
    constexpr std::uint8_t configured_strength = 128;
    QCOMPARE(client_->configuration().font.size, configured_font_size);
    QVERIFY(client_->configuration().font.thicken);
    QCOMPARE(client_->configuration().font.thicken_strength, configured_strength);
    QVERIFY(client_->font().value(QStringLiteral("thicken")).toBool());
    QTRY_COMPARE(window_->title(), client_->title());
    QVERIFY(window_->title().startsWith(QStringLiteral("configured ")));
    QVERIFY(!window_->title().contains(QStringLiteral("{hostname}")));
    const auto *pane = firstPane();
    QVERIFY(pane != nullptr);
    client_->execute(Application::Action::focus_pane, QString::number(pane->id));
    client_->input(pane->id, "printf '\\033]0;cpp-title-fixture\\007'\n");
    QTRY_COMPARE_WITH_TIMEOUT(toQString(pane->title), QStringLiteral("cpp-title-fixture"), runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(window_->title().startsWith(QStringLiteral("configured cpp-title-fixture @ ")), runtime_wait_ms);

    const QSignalSpy reloaded{client_.get(), &Application::configurationChanged};
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
    QCOMPARE(client_->error(), QString{});

    QVERIFY(configuration_file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    const QByteArray invalid_source{"return {api_version = 2, gui = {font = {size = 0}}}"};
    QCOMPARE(configuration_file.write(invalid_source), invalid_source.size());
    configuration_file.close();
    peer.request(telar::ClientAction::config_reload, 4);
    QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, std::uint64_t{4}, runtime_wait_ms);
    QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
    QTRY_VERIFY_WITH_TIMEOUT(!client_->error().isEmpty(), runtime_wait_ms);
    QCOMPARE(telar::gui::qt::WindowAnimationClock::forWindow(*window_).frameInterval(), capped_interval);
    QCOMPARE(client_->configuration().font.size, configured_font_size);

    QVERIFY(configuration_file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    QCOMPARE(configuration_file.write(source), source.size());
    configuration_file.close();
    constexpr std::uint64_t recovery_request = 5;
    peer.request(telar::ClientAction::config_reload, recovery_request);
    QTRY_COMPARE_WITH_TIMEOUT(peer.result().request_id, recovery_request, runtime_wait_ms);
    QCOMPARE(peer.result().status, telar::ClientCommandStatus::admitted);
    QTRY_COMPARE_WITH_TIMEOUT(client_->error(), QString{}, runtime_wait_ms);
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
    const auto *pane = firstPane();
    QVERIFY(pane != nullptr);
    const auto command = QStringLiteral("printf '\\033[2J\\033[HFRAME_PACING_WAIT\\n'; while [ ! -f ") + shellLiteral(release_path) + QStringLiteral(" ]; do sleep 0.01; done; printf 'FRAME_PACING_DONE\\n'\r");
    client_->input(pane->id, command.toUtf8());
    QTRY_VERIFY_WITH_TIMEOUT(screenText(pane->screen).startsWith(QLatin1StringView("FRAME_PACING_WAIT")), runtime_wait_ms);
    QVERIFY(telar::gui::test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
    constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
    constexpr int grace_expiry_ms = static_cast<int>(telar::gui::FramePacer::input_grace_ns / nanoseconds_per_millisecond) + 1;
    QTest::qWait(grace_expiry_ms);
    constexpr auto hold_ns = telar::gui::FramePacer::nanoseconds_per_second * 2;
    telar::gui::test::FramePacing::anchor(*client_, telar::gui::platform::AwakeClock::nowNanoseconds() + hold_ns);
    window_->update();
    QVERIFY(telar::gui::test::waitForGuiCondition([&] {
      return telar::gui::test::FramePacing::pending(*client_);
    },
                                                  runtime_wait_ms));
    telar::gui::test::FramePacing::anchor(*client_, telar::gui::platform::AwakeClock::nowNanoseconds() - telar::gui::FramePacer::maximum_interval_ns);
    const auto previous = pane->screen.frameId();
    writeTestFile(release_path, "");
    constexpr int wakeup_wait_ms = 500;
    QVERIFY2(telar::gui::test::waitForGuiCondition([&] {
               return pane->screen.frameId() > previous && pane->acknowledged_frame == pane->screen.frameId() && screenText(pane->screen).contains(QLatin1StringView("FRAME_PACING_DONE"));
             },
                                                   wakeup_wait_ms),
             qPrintable(QStringLiteral("frame=%1 acknowledged=%2 pending=%3").arg(pane->screen.frameId()).arg(pane->acknowledged_frame).arg(telar::gui::test::FramePacing::pending(*client_))));
    QCOMPARE(client_->error(), QString{});
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
    constexpr auto hold_ns = telar::gui::FramePacer::nanoseconds_per_second * 2;
    telar::gui::test::FramePacing::anchor(*client_, telar::gui::platform::AwakeClock::nowNanoseconds() + hold_ns);
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
    QCOMPARE(client_->error(), QString{});
  }

  Q_SLOT void terminalFramesWaitForSceneSynchronization() {
    verifyTerminalFrameAdmission(TerminalSuppression::no_contents);
  }

  Q_SLOT void queuedFramesCannotSurviveAWindowBindingChange() {
    for (const bool restore_before_delivery : std::array{false, true}) {
      QQuickWindow replacement;
      replacement.setScreen(window_->screen());
      replacement.resize(window_->size());
      const auto restore = qScopeGuard([this] {
        client_->setWindow(*window_);
        window_->show();
      });
      const auto *pane = firstPane();
      QVERIFY(pane != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(pane->acknowledged_frame, pane->screen.frameId(), runtime_wait_ms);
      window_->hide();
      QTRY_VERIFY_WITH_TIMEOUT(!window_->isExposed(), runtime_wait_ms);
      QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
      const auto previous_frame = pane->screen.frameId();
      const auto acknowledged = pane->acknowledged_frame;
      client_->input(pane->id, QByteArrayLiteral("printf 'WINDOW_FRAME_OWNER\\n'\r"));
      QTRY_VERIFY_WITH_TIMEOUT(pane->screen.frameId() > previous_frame, runtime_wait_ms);
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

      QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
      QCOMPARE(pane->acknowledged_frame, acknowledged);
      client_->setWindow(*window_);
      window_->show();
      QTRY_VERIFY_WITH_TIMEOUT(pane->acknowledged_frame >= pending_frame, runtime_wait_ms);
      QCOMPARE(client_->error(), QString{});
    }
  }

  Q_SLOT void reopeningRestoresLayout() {
    const auto previous_tabs = client_->tabs()->rowCount();
    const auto previous_pane = firstPane()->id;
    client_->execute(Application::Action::toggle_workspace_list);
    QVERIFY(client_->workspaceListCollapsed());
    QTest::qWait(frame_settle_ms);
    engine_.reset();
    client_.reset();
    window_ = nullptr;
    QCOMPARE(runtime_.state(), QProcess::Running);
    openWindow();
    QVERIFY2(window_ != nullptr, qPrintable(errors_));
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), previous_tabs, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(firstPane() != nullptr && firstPane()->id == previous_pane && firstPane()->screen.frameId() > 0, runtime_wait_ms);
    QTRY_VERIFY(client_->workspaceListCollapsed());
    QCOMPARE(client_->error(), QString{});
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

  void openWindow() {
    client_ = std::make_unique<Application>(memory_);
    client_->configureLaunch(directory_.path(), {QStringLiteral("/bin/sh")}, true);
    client_->loadConfiguration({}, {}, {});
    engine_ = std::make_unique<QQmlApplicationEngine>();
    connect(engine_.get(), &QQmlEngine::warnings, this, [this](const QList<QQmlError> &errors) {
      for (const auto &error : errors) {
        errors_ += error.toString() + QLatin1Char('\n');
      }
    });

    engine_->rootContext()->setContextProperty(QStringLiteral("telar"), client_.get());
    test::activateApplication();
    if (const auto *screen = QGuiApplication::primaryScreen()) {
      const auto position = screen->availableGeometry().topLeft();
      engine_->setInitialProperties({{QStringLiteral("x"), position.x()}, {QStringLiteral("y"), position.y()}});
    }

    engine_->loadFromModule(QStringLiteral("Telar.Gui"), QStringLiteral("Main"));
    if (engine_->rootObjects().isEmpty()) {
      return;
    }

    window_ = qobject_cast<QQuickWindow *>(engine_->rootObjects().first());
    if (window_ != nullptr) {
      client_->setWindow(*window_);
      client_->open(socket_);
    }
  }

  enum class HistoryView : std::uint8_t {
    results,
    inspector,
  };

  void verifyHistoryCompositionEscape(HistoryView view) {
    const auto inspecting = view == HistoryView::inspector;
    client_->execute(Application::Action::history);
    const auto restore = qScopeGuard([this] {
      client_->execute(Application::Action::cancel);
    });
    const auto query = QStringLiteral("GUI_HISTORY_FIXTURE");
    client_->searchHistory(query);
    QTRY_VERIFY_WITH_TIMEOUT(!client_->historyLoading() && client_->history()->rowCount() > 0, runtime_wait_ms);
    if (inspecting) {
      client_->executeHistory(Application::HistoryAction::inspect);
    }

    auto *search = window_->findChild<QQuickItem *>(QStringLiteral("commandSearch"));
    QVERIFY(search != nullptr);
    QVERIFY(QMetaObject::invokeMethod(search, "select", Q_ARG(int, 0), Q_ARG(int, 3)));
    search->forceActiveFocus();
    QInputMethodEvent preedit{QStringLiteral("中"), {{QInputMethodEvent::Cursor, 1, 1, {}}}};
    QCoreApplication::sendEvent(search, &preedit);
    QTRY_VERIFY_WITH_TIMEOUT(search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
    QTest::keyClick(window_, Qt::Key_Escape);
    QCOMPARE(client_->dialog(), QStringLiteral("history"));
    QCOMPARE(client_->historyState().value(QStringLiteral("inspecting")).toBool(), inspecting);
    QTRY_VERIFY_WITH_TIMEOUT(!search->property("layout").toMap().value(QStringLiteral("composing")).toBool(), runtime_wait_ms);
    QCOMPARE(search->property("text").toString(), query);
    QCOMPARE(search->property("selectedText").toString(), query.first(3));
    QTest::keyClick(window_, Qt::Key_Escape);
    if (inspecting) {
      QCOMPARE(client_->dialog(), QStringLiteral("history"));
      QVERIFY(!client_->historyState().value(QStringLiteral("inspecting")).toBool());
      QTest::keyClick(window_, Qt::Key_Escape);
    }

    QTRY_VERIFY_WITH_TIMEOUT(client_->dialog().isEmpty(), runtime_wait_ms);
  }

  void captureHistoryArtifact(const QString &name) {
    const auto directory_path = qEnvironmentVariable("TELAR_GUI_TEST_ARTIFACT_DIRECTORY");
    if (directory_path.isEmpty()) {
      return;
    }

    const QDir directory{directory_path};
    QVERIFY(directory.mkpath(QStringLiteral(".")));
    const auto *panel = window_->findChild<QQuickItem *>(QStringLiteral("historyPanel"));
    if (panel == nullptr) {
      QFAIL("Required history panel fixture is missing");
    }

    const auto *content = panel->parentItem();
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

    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);

    const auto current = QTest::qWaitFor([this] {
      window_->update();
      QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);

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
    const std::array entries{
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
    const std::array<telar::ImportHistoryEntry, 1> entries{{{.started_at_ms = 100, .command = "echo GUI_HISTORY_FIXTURE"}}};
    importHistory(entries, "gui-quick-test");
  }

  void seedHistoryPages() {
    constexpr auto entry_count = HistoryBrowser<ApplicationAllocator>::page_entries + 1;
    std::array<std::string, entry_count> commands;
    std::array<telar::ImportHistoryEntry, entry_count> entries{};
    for (std::size_t index = 0; index < entries.size(); ++index) {
      commands[index] = "echo GUI_BROWSER_PAGE_" + std::to_string(index);
      entries[index] = {.started_at_ms = static_cast<std::int64_t>(index) + 1, .command = commands[index]};
    }

    importHistory(entries, "gui-browser-page");
  }

  void importHistory(std::span<const telar::ImportHistoryEntry> entries, std::string_view source) {
    const auto path = socket_.toUtf8();
    auto peer = telar::Client::init(path.constData());
    try {
      peer.handshake();
      std::array<telar::Byte, response_capacity> bytes{};
      constexpr std::size_t maximum_import_entries = 64;
      std::size_t offset = 0;
      std::uint64_t request_id = 0;
      while (offset < entries.size()) {
        const auto count = std::min(entries.size() - offset, maximum_import_entries);
        const telar::ImportHistory request{.request_id = ++request_id, .source = source, .base_sequence = offset, .entries = entries.subspan(offset, count)};
        std::vector<telar::Byte> encoded(telar::frame_prefix_size + telar::Codec::encodedSize(request));
        peer.send(request, encoded);
        const auto reply = peer.receiveFrame(bytes);
        QCOMPARE(telar::Codec::decode<telar::RequestCompleted>(reply).request_id, request_id);
        offset += count;
      }
      peer.deinit();
    } catch (...) {
      peer.deinit();
      throw;
    }
  }

  void verifyTerminalFrameAdmission(TerminalSuppression suppression) {
    auto *terminal = terminalIn(window_->contentItem());
    const auto *pane = firstPane();
    QVERIFY(terminal != nullptr && pane != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(pane->acknowledged_frame, pane->screen.frameId(), runtime_wait_ms);
    const auto restore = qScopeGuard([terminal] {
      terminal->setVisible(true);
      terminal->setFlag(QQuickItem::ItemHasContents, true);
      terminal->update();
    });

    terminal->setVisible(suppression != TerminalSuppression::hidden);
    terminal->setFlag(QQuickItem::ItemHasContents, suppression != TerminalSuppression::no_contents);
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    const auto acknowledged = pane->acknowledged_frame;
    const auto previous_frame = pane->screen.frameId();
    client_->input(pane->id, QByteArrayLiteral("printf 'DEFERRED_TERMINAL_FRAME\\n'\r"));
    QTRY_VERIFY_WITH_TIMEOUT(pane->screen.frameId() > previous_frame, runtime_wait_ms);
    const auto pending_frame = pane->screen.frameId();
    QVERIFY(telar::gui::test::waitForSynchronizedFrame(*window_, runtime_wait_ms));
    QCoreApplication::sendPostedEvents(client_.get(), QEvent::MetaCall);
    QCOMPARE(pane->acknowledged_frame, acknowledged);

    terminal->setVisible(true);
    terminal->setFlag(QQuickItem::ItemHasContents, true);
    terminal->update();
    QTRY_VERIFY_WITH_TIMEOUT(pane->acknowledged_frame >= pending_frame, runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  template <typename Gesture>
  void verifyChildMouse(std::string_view expected, Gesture &&gesture, ChildMouseEncoding encoding = ChildMouseEncoding::sgr) {
    const auto original_tabs = client_->tabs()->rowCount();
    const auto *original = firstPane();
    QVERIFY(original != nullptr);
    const auto original_identity = original->id;
    client_->execute(Application::Action::new_tab);
    QTRY_COMPARE_WITH_TIMEOUT(client_->tabs()->rowCount(), original_tabs + 1, runtime_wait_ms);
    const auto restore = qScopeGuard([this, original_tabs, original_identity] {
      closeTemporaryTab({.count = original_tabs, .pane_id = original_identity});
    });
    QTRY_VERIFY_WITH_TIMEOUT(terminalReady() && firstPane()->id != original_identity, runtime_wait_ms);
    auto *terminal = terminalIn(window_->contentItem());
    const auto *pane = firstPane();
    QVERIFY(terminal != nullptr && pane != nullptr);
    terminal->forceActiveFocus();
    beginChildMouseCapture(*terminal, expected.size(), encoding);
    std::forward<Gesture>(gesture)(*window_, *terminal);
    finishChildMouseCapture(pane->id, expected);
  }

  void beginChildMouseCapture(TerminalItem &terminal, std::size_t expected_bytes, ChildMouseEncoding encoding = ChildMouseEncoding::sgr) {
    const auto *pane = client_->pane(terminal.paneIdentity());
    QVERIFY(pane != nullptr);
    const auto capture_bytes = static_cast<qsizetype>(expected_bytes) + 1;
    const auto sgr = encoding == ChildMouseEncoding::sgr;
    const auto sgr_control = sgr ? QStringLiteral("\\033[?1006h") : QStringLiteral("\\033[?1006l");
    const auto capture = QStringLiteral("stty raw -echo; printf '\\033[2J\\033[H\\033[?1002h%1MOUSE_%s:' BEGIN; dd bs=1 count=%2 2>/dev/null | tee %3 | od -v -An -tx1 | tr -d ' \\n'; printf ':MOUSE_%s\\n\\033[?1002l\\033[?1006l' END; stty sane\r").arg(sgr_control).arg(capture_bytes).arg(shellLiteral(childMouseCapturePath(pane->id)));
    client_->input(pane->id, capture.toUtf8());
    QTRY_VERIFY_WITH_TIMEOUT(pane->screen.mouse().sgr == sgr && pane->screen.mouse().tracking == telar::MouseTracking::button, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(pane->acknowledged_frame, pane->screen.frameId(), runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!terminal.prepareLinkPresentation(), runtime_wait_ms);
  }

  void finishChildMouseCapture(std::uint64_t pane_id, std::string_view expected) {
    const auto *pane = client_->pane(pane_id);
    QVERIFY(pane != nullptr);
    constexpr char padding_byte = ' ';
    client_->input(pane->id, QByteArray{static_cast<qsizetype>(expected.size()) + 1, padding_byte});
    const auto expected_bytes = QByteArray{expected.data(), static_cast<qsizetype>(expected.size())} + padding_byte;
    const auto path = childMouseCapturePath(pane_id);
    QTRY_COMPARE_WITH_TIMEOUT(QFileInfo{path}.size(), expected_bytes.size(), runtime_wait_ms);
    QFile captured{path};
    QVERIFY2(captured.open(QIODevice::ReadOnly), qPrintable(captured.errorString()));
    QCOMPARE(captured.readAll(), expected_bytes);
    QTRY_VERIFY_WITH_TIMEOUT(!pane->screen.mouse().sgr && pane->screen.mouse().tracking == telar::MouseTracking::none, runtime_wait_ms);
    QCOMPARE(client_->error(), QString{});
  }

  [[nodiscard]] QString childMouseCapturePath(std::uint64_t pane_id) const {
    return directory_.filePath(QStringLiteral("mouse-%1.bin").arg(pane_id));
  }

  void dismissNotification() {
    const auto controls = [&] {
      return telar::gui::test::visualItems(*window_->contentItem(), QStringLiteral("notificationClose"));
    };
    QTRY_VERIFY(!controls().empty());
    const auto *close = controls().front();
    QTest::mouseClick(window_, Qt::LeftButton, Qt::NoModifier, close->mapToScene({close->width() / 2, close->height() / 2}).toPoint());
    QTRY_VERIFY(controls().empty());
  }

  [[nodiscard]] bool terminalReady() const {
    const auto *pane = firstPane();
    const auto *terminal = window_ == nullptr ? nullptr : terminalIn(window_->contentItem());

    return pane != nullptr && pane->attached && pane->screen.frameId() != 0 && terminal != nullptr && terminal->paneIdentity() == pane->id;
  }

  void closeExtraTabs(int kept_count) {
    while (client_->tabs()->rowCount() > kept_count) {
      const auto count = client_->tabs()->rowCount();
      client_->execute(Application::Action::close_tab);
      const auto closed = QTest::qWaitFor([this, count] {
        return client_->tabs()->rowCount() < count;
      },
                                          runtime_wait_ms);
      QVERIFY2(closed, "Temporary tabs must close during test cleanup");
    }
  }

  void closeTemporaryTab(TabRestorePoint destination) {
    client_->execute(Application::Action::close_tab);
    const auto restored = QTest::qWaitFor([this, destination] {
      return client_->tabs()->rowCount() == destination.count && terminalReady() && firstPane()->id == destination.pane_id;
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

  [[nodiscard]] Pane<ApplicationAllocator> *firstPane() const {
    if (client_->panes()->rowCount() == 0) {
      return nullptr;
    }

    const auto record = client_->panes()->data(client_->panes()->index(0, 0), ListModel::record_role).toMap();

    return client_->pane(record.value(QStringLiteral("key")).toString().toULongLong());
  }

  ApplicationAllocator memory_;
  QTemporaryDir directory_;
  QProcess runtime_;
  QString socket_;
  QString errors_;
  std::unique_ptr<Application> client_;
  std::unique_ptr<QQmlApplicationEngine> engine_;
  QQuickWindow *window_ = nullptr;
  std::uint64_t history_wheel_timestamp_ = 0;
};

}

int main(int argc, char **argv) {
  if (argc > 1 && std::string_view{argv[1]} == "--report-blocked") {
    return telar::gui::test::runAgentReportFixture(argc, argv);
  }

  QGuiApplication const application{argc, argv};
  QQuickStyle::setStyle(QStringLiteral("Basic"));
  QuickTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "quick_test.moc"
