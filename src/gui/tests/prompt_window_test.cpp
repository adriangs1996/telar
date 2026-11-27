#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "frame_fixture.hpp"
#include "gui_wait.hpp"
#include "qml_fixture.hpp"
#include "screen_fixture.hpp"
#include "shots_fixture.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/kit/input/key_adapter.hpp"
#include <QByteArray>
#include <QClipboard>
#include <QColor>
#include <QInputMethodEvent>
#include <QInputMethodQueryEvent>
#include <QWheelEvent>
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
#endif
#ifdef __APPLE__
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
#include "ui/app/chrome/components/machine_chrome/machine_chrome_layout.hpp"
#include "ui/app/panes/terminal/prompt/prompt_editor_item.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include "ui/kit/fonts/bundled_fonts.hpp"
#include "ui/kit/links/external_link_opener.hpp"
#include "ui/kit/machines/machine_client.hpp"
#include "ui/kit/models/list_model.hpp"
#include "wire_runtime.hpp"
#include <QAbstractItemModel>
#include <QCoreApplication>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIODevice>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QLocalServer>
#include <QLocalSocket>
#include <QObject>
#include <QPoint>
#include <QPointF>
#include <QProcess>
#include <QProcessEnvironment>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QSize>
#include <QStandardPaths>
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

import telar.gui.application;
import telar.wire.content;
import telar.wire.editor;
import telar.wire.history;
import telar.wire.layout;
import telar.gui.features.machines;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.wire.pane_io;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::machines;
  using namespace telar::gui::qt;
  using namespace telar::gui::test;

  constexpr int wait_ms = 5000;
  constexpr std::uint64_t pane_id = 1;
  constexpr TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
  constexpr std::uint16_t columns = 60;
  constexpr std::uint16_t rows = 6;
  // The room the run encoder gets for each cell of the screen.
  constexpr std::size_t encoded_cell_bytes = 16;

  // The windows the line is shown in: on its own, with search rows under it, wide enough for its
  // whole context, and too narrow for it.
  constexpr QSize screen_size{720, 300};
  // Long enough for the runtime to answer the spec of a command typed at a real shell.
  constexpr int spec_wait_ms = 1000;
  constexpr QSize search_screen_size{820, 420};
  constexpr QSize wide_screen_size{820, 300};
  constexpr QSize narrow_screen_size{300, 300};

  // How long the line's motion gets to settle before a frame is grabbed or checked.
  constexpr int settle_ms = 900;
  constexpr int running_settle_ms = 1200;
  constexpr int view_settle_ms = 600;

  // A real runtime starts a real shell, which takes longer than a fake one answers.
  constexpr int runtime_wait_ms = 20000;
  constexpr int stop_wait_ms = 5000;

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

  // A prompt line bound as PaneArea binds it, with the application in the pane area's place:
  // the controllers the line hosts, the line search it follows and the cancel it asks for.
  std::unique_ptr<QQuickItem> createPromptLine(QQmlEngine& engine, ApplicationController& application, TerminalItem& terminal, std::uint64_t pane) {
    QQmlComponent component{&engine};

    component.setData(R"(
      import Telar.Gui
      PromptLine {
        required property ApplicationController application
        colors: application.colors
        typography: application.display.geometry.typography
        grid: application.display.geometry.typography.grid
        history: application.history
        pathPicker: application.paths
        copy: application.copy
        prompt: application.prompt
        lineSearch: ({kind: application.dialogs.lineSearch, pane: application.dialogs.lineSearchPane})
        controlModifier: application.controlModifier
        superModifier: application.superModifier
        onCancelled: application.commands.execute(WindowActions.Action.cancel)
      }
    )",
        QUrl{});
    auto object = std::unique_ptr<QObject>{component.createWithInitialProperties({
        {QStringLiteral("application"), QVariant::fromValue(&application)},
        {QStringLiteral("paneId"), QString::number(pane)},
        {QStringLiteral("terminal"), QVariant::fromValue(static_cast<QObject*>(&terminal))},
    })};
    if (qobject_cast<QQuickItem*>(object.get()) == nullptr) {
      throw std::runtime_error{component.errorString().toStdString()};
    }

    return std::unique_ptr<QQuickItem>{qobject_cast<QQuickItem*>(object.release())};
  }

  // A screen with some output and the shell's prompt on the last row, flagged as the runtime
  // flags a row its integrated shell marked; or `last` there, the cursor after it.
  void sendPromptScreen(WireRuntime& runtime, std::uint64_t frame_id, std::string_view last = "adrian@host ~/src/telar % ") {
    const ds::Array<std::string_view, rows> lines{"$ make", "[1/2] Building runtime", "[2/2] Linking telar", "", "", last};
    std::vector<Cell> cells;

    for (const auto line : lines) {
      for (std::size_t column = 0; column < columns; ++column) {
        cells.push_back(Cell{.text = byteView(column < line.size() ? line.substr(column, 1) : std::string_view{" "})});
      }
    }

    std::vector<Byte> encoded(cells.size() * encoded_cell_bytes);
    const ds::Array spans{FrameSpan{.start = 0, .count = static_cast<std::uint32_t>(cells.size()), .cells = CellRunCodec::encode(cells, encoded)}};
    ds::Array<Byte, rows> flags{};

    flags.atMut(rows - 1) = static_cast<Byte>(RowFlag::prompt);
    FrameBody frame{.pane_id = pane_id, .frame_id = frame_id, .cols = columns, .rows = rows, .cursor = {.visible = true, .x = static_cast<std::uint16_t>(lines.back().size()), .y = rows - 1}, .scroll = {.total_rows = rows}, .text_metadata = TextMetadata{.row_flags = flags}, .spans = spans};

    frame.input_modes.bracketed_paste = true;
    runtime.send(PaneFrame{frame});
  }

  void type(TerminalItem& terminal, std::string_view text) {
    for (const auto character : text) {
      const auto key = character >= 'a' && character <= 'z' ? Qt::Key_A + (character - 'a') : static_cast<int>(character);
      QKeyEvent press{QEvent::KeyPress, key, Qt::NoModifier, QString{QChar{character}}};

      QCoreApplication::sendEvent(&terminal, &press);
    }
  }

  // A paste shows on the line at once; typed keys stay on it until Enter sends the command whole,
  // and once the command runs the keys go to it.
  void runsTypedCommand(ApplicationController& application, WireRuntime& runtime, QQuickWindow& window, TerminalItem& terminal, QQuickItem& line) {
    // A paste shows on the line at once, without a key after it.
    const auto* editor = line.findChild<PromptEditorItem*>();

    QVERIFY(editor != nullptr && editor->empty());
    application.terminals()->paste(pane_id, QStringLiteral("echo pasted"));
    QVERIFY2(!editor->empty(), "the paste shows without another key");
    QKeyEvent wipe{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};

    QCoreApplication::sendEvent(&terminal, &wipe);
    QVERIFY(editor->empty());

    const auto before = runtime.count(ClientTag::pane_input);
    const auto commands_before = runtime.count(ClientTag::run_pane_command);

    type(terminal, "git log --oneline -n 3 | grep fix");
    QCOMPARE(runtime.count(ClientTag::pane_input), before);
    QTRY_VERIFY_WITH_TIMEOUT(line.property("inputShown").toBool(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminal.promptRow() >= 0, wait_ms);
    // A one-row prompt on the screen's last row: the context takes the prompt's row and the
    // editor the one past the screen, which the terminal rises by.
    QCOMPARE(terminal.promptTop(), rows - 1);
    QCOMPARE(terminal.promptRow(), rows - 1);
    QCOMPARE(line.property("anchor").toInt(), rows - 1);
    QCOMPARE(line.property("liftRows").toInt(), 1);
    QVERIFY(!line.property("docked").toBool());
    // Without focus the line stays, dimmed, and the shell's own prompt stays hidden.
    line.setProperty("focused", false);
    QVERIFY(line.property("inputShown").toBool());
    QVERIFY(terminal.promptRow() >= 0);
    line.setProperty("focused", true);
    QTest::qWait(settle_ms);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_SCREENSHOT");
    if (!screenshot.isEmpty()) {
      QVERIFY(window.grabWindow().save(screenshot, "PNG"));
    }

    QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(runtime.count(ClientTag::run_pane_command) > commands_before, wait_ms);
    QCOMPARE(runtime.count(ClientTag::pane_input), before);
    // The runtime receives the command whole and types it at the prompt itself.
    QCOMPARE(textView(runtime.last<RunPaneCommand>().text), std::string_view{"git log --oneline -n 3 | grep fix"});

    runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::running, .canonical = true, .echo = true, .signal_keys = true, .interrupt = 3});
    QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->surface(pane_id), application::prompt::Surface::running, wait_ms);
    // Running, the line leaves and the terminal settles back under it.
    QCOMPARE(line.property("liftRows").toInt(), 0);
    // The program printed a question and waits after it: the keys go to the program, and the
    // separators show the key that interrupts it.
    sendPromptScreen(runtime, 2, "Overwrite the build? [y/N] ");
    QTest::qWait(settle_ms);
    type(terminal, "make test");
    QVERIFY(!line.property("queueing").toBool());
    QVERIFY(!line.property("interruptKey").toString().isEmpty());
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    const auto running = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_RUNNING_SCREENSHOT");
    if (!running.isEmpty()) {
      QTest::qWait(running_settle_ms);
      QVERIFY(window.grabWindow().save(running, "PNG"));
    }
  }

  // Back at the prompt, the line learns which commands exist, completes from the runtime's specs,
  // and follows the command blocks to the shell's prompt row.
  void completesAtThePrompt(ApplicationController& application, WireRuntime& runtime, QQuickWindow& window, TerminalItem& terminal, const QQuickItem& line) {
    const auto* editor = line.findChild<PromptEditorItem*>();

    QVERIFY(editor != nullptr);
    // Tab opens the spec's choices above the command.
    runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true, .commands = 1, .status = 2});
    QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->surface(pane_id), application::prompt::Surface::editor, wait_ms);
    QKeyEvent clear{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};

    QCoreApplication::sendEvent(&terminal, &clear);
    // The command's block arrives: its prompt row turns into a separator, which offers the
    // way to its error while the editor waits, and the rail beside the pane gets its dot.
    const ds::Array blocks{CommandBlock{.row = 0, .rows = 1, .lines = 0, .state = CommandBlockState::failed, .status = 2, .duration_ms = 1500, .command = "git log --oneline -n 3 | grep fix"}};

    runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = blocks});
    QTRY_COMPARE_WITH_TIMEOUT(terminal.separators().size(), 1, wait_ms);
    QVERIFY(line.property("offerFailure").toBool());
    QCOMPARE(terminal.separators().front().toMap().value(QStringLiteral("command")).toString(), QStringLiteral("git log --oneline -n 3 | grep fix"));
    QCOMPARE(terminal.separators().front().toMap().value(QStringLiteral("state")).toString(), QStringLiteral("failed"));
    QCOMPARE(terminal.rail().size(), 1);

    // The block ran git, so git exists. Any other command word, once typed, is asked of the
    // runtime; one it does not find is missing.
    QCOMPARE(application.prompt()->commandPresence(pane_id, "git"), application::prompt::CommandPresence::found);
    const auto asked = runtime.count(ClientTag::complete_words);

    type(terminal, "gti s");
    QTRY_VERIFY_WITH_TIMEOUT(runtime.count(ClientTag::complete_words) > asked, wait_ms);
    const auto presence = runtime.last<CompleteWords>();

    QCOMPARE(presence.prefix, std::string_view{"gti"});
    QCOMPARE(application.prompt()->commandPresence(pane_id, "gti"), application::prompt::CommandPresence::pending);
    const QSignalSpy relaid{editor, &PromptEditorItem::layoutChanged};

    runtime.send(CompletionWords{.request_id = presence.request_id, .truncated = false, .words = {}});
    QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->commandPresence(pane_id, "gti"), application::prompt::CommandPresence::missing, wait_ms);
    // The answer reaches the line as its pane's change and marks the word: it is laid out again.
    QTRY_VERIFY_WITH_TIMEOUT(relaid.count() > 0, wait_ms);
    // Output that changes nothing the line draws keeps its layout.
    const auto relayouts = relaid.count();

    emit application.terminals()->terminalChanged(pane_id);
    QCOMPARE(relaid.count(), relayouts);
    QCoreApplication::sendEvent(&terminal, &clear);
    type(terminal, "git s");
    QKeyEvent tab{QEvent::KeyPress, Qt::Key_Tab, Qt::NoModifier, QStringLiteral("\t")};
    const auto specs_asked = runtime.count(ClientTag::request_command_spec);

    QCoreApplication::sendEvent(&terminal, &tab);
    // git's spec comes from the runtime: the menu opens once it arrives.
    QTRY_VERIFY_WITH_TIMEOUT(runtime.count(ClientTag::request_command_spec) > specs_asked, wait_ms);
    const auto spec = runtime.last<RequestCommandSpec>();

    QCOMPARE(spec.command, std::string_view{"git"});
    constexpr std::string_view git_spec = R"(git = [ command ] ;
command = "switch" : "Switch branches" | "status" : "Show the working tree status" | "stash" : "Stash the changes" ;)";

    runtime.send(CommandSpec{.request_id = spec.request_id, .command = "git", .state = CommandSpecState::available, .digest = 3, .source = git_spec});
    QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->line(pane_id)->menu().hasValue(), wait_ms);
    // The menu's heading says where its choices come from.
    QCOMPARE(application.prompt()->line(pane_id)->menu()->label, std::string{"git"});
    // A choice taken sweeps in, glowing in the accent colour as it settles.
    QKeyEvent take{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

    QCoreApplication::sendEvent(&terminal, &take);
    QVERIFY(!application.prompt()->line(pane_id)->menu().hasValue());
    QVERIFY(!editor->glows().isEmpty());
    QTRY_VERIFY_WITH_TIMEOUT(editor->glows().isEmpty(), wait_ms);

    // A command that ran without the shell missing it exists, whatever it reported before.
    const ds::Array ran{blocks[0], CommandBlock{.row = 2, .rows = 1, .lines = 0, .state = CommandBlockState::succeeded, .status = 0, .duration_ms = 20, .command = "gti status"}};

    runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = ran});
    QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->commandPresence(pane_id, "gti"), application::prompt::CommandPresence::found, wait_ms);

    // Back at the prompt before the frame that draws it, the last prompt on screen is the
    // command's own: its output is not prompt, and the line waits under the cursor.
    const ds::Array pending{ran[0], ran[1], CommandBlock{.row = rows - 1, .rows = 1, .lines = 0, .state = CommandBlockState::succeeded, .status = 0, .duration_ms = 5, .command = "ls"}};

    runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = pending});
    QTRY_COMPARE_WITH_TIMEOUT(terminal.promptRow(), -1, wait_ms);
    QCOMPARE(line.property("anchor").toInt(), terminal.cursorRow() + 1);
    QVERIFY(!line.property("docked").toBool());
    runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = ran});
    QTRY_COMPARE_WITH_TIMEOUT(terminal.promptRow(), rows - 1, wait_ms);
    QTest::qWait(settle_ms);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    const auto menu = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_MENU_SCREENSHOT");
    if (!menu.isEmpty()) {
      QVERIFY(window.grabWindow().save(menu, "PNG"));
    }
  }

  // Ctrl-R searches the history for the line, each command once, and Esc leaves the line as it was.
  void searchesHistory(ApplicationController& application, WireRuntime& runtime, QQuickWindow& window, TerminalItem& terminal, const QQuickItem& line) {
    type(terminal, "git s");
    const auto queries = runtime.count(ClientTag::query_history);
    QKeyEvent search{QEvent::KeyPress, Qt::Key_R, NativeKeyAdapter::control_modifier};

    QCoreApplication::sendEvent(&terminal, &search);
    QCOMPARE(application.dialogs()->lineSearch(), telar::gui::qt::ApplicationController::Dialog::history);
    // The line also loads its suggestions from the history; the search's query is the line.
    QTRY_VERIFY_WITH_TIMEOUT(runtime.count(ClientTag::query_history) > queries && runtime.last<QueryHistory>().query == "git s", wait_ms);
    const auto query = runtime.last<QueryHistory>();

    QVERIFY(query.distinct);
    const ds::Array entries{
        HistoryEntry{.id = 3, .pane_id = pane_id, .started_at_ms = 1'700'000'300'000, .exit_code = 0, .command = "git status --short", .cwd = "/work"},
        HistoryEntry{.id = 2, .pane_id = pane_id, .started_at_ms = 1'700'000'200'000, .exit_code = 1, .command = "git stash pop", .cwd = "/work"},
        HistoryEntry{.id = 1, .pane_id = pane_id, .started_at_ms = 1'700'000'100'000, .exit_code = 0, .command = "git switch main", .cwd = "/work"},
    };

    runtime.send(HistoryResults{.request_id = query.request_id, .snapshot_id = 3, .entries = entries});
    QTRY_COMPARE_WITH_TIMEOUT(application.history()->state().value(QStringLiteral("count")).toInt(), 3, wait_ms);
    auto* field = line.findChild<QQuickItem*>(QStringLiteral("promptSearch"));

    QVERIFY(field != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(field->hasActiveFocus(), wait_ms);
    QCOMPARE(field->property("text").toString(), QStringLiteral("git s"));
    // The rows run down from the query: down goes to an older command. The line needs the
    // query's row and the rows found past the screen, which the terminal rises by.
    QTRY_COMPARE_WITH_TIMEOUT(line.property("rowCount").toInt(), 2 + 3, wait_ms);
    QCOMPARE(line.property("liftRows").toInt(), line.property("anchor").toInt() + 5 - rows);
    QKeyEvent down{QEvent::KeyPress, Qt::Key_Down, Qt::NoModifier};

    QCoreApplication::sendEvent(field, &down);
    QTRY_COMPARE_WITH_TIMEOUT(application.history()->state().value(QStringLiteral("selection")).toInt(), 1, wait_ms);
    QTest::qWait(settle_ms);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    if (const auto picture = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_HISTORY_SCREENSHOT"); !picture.isEmpty()) {
      QVERIFY(window.grabWindow().save(picture, "PNG"));
    }

    // Esc closes it and leaves the line as it was.
    QKeyEvent escape{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier};

    QCoreApplication::sendEvent(field, &escape);
    QVERIFY((application.dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::none));
    QVERIFY(application.prompt()->line(pane_id)->text() == "git s");
  }

  // The path search starts from the word before the caret and writes the path over it.
  void searchesPaths(ApplicationController& application, WireRuntime& runtime, QQuickWindow& window, const QQuickItem& line) {
    application.commands()->execute(window_actions::Action::path_picker);
    QCOMPARE(application.dialogs()->lineSearch(), telar::gui::qt::ApplicationController::Dialog::paths);
    QTRY_VERIFY_WITH_TIMEOUT(runtime.count(ClientTag::find_paths) != 0, wait_ms);
    const auto find = runtime.last<FindPaths>();

    QCOMPARE(find.query, std::string_view{"s"});
    const ds::Array paths{PathMatch{.path = "src/main.cpp", .kind = PathKind::file}, PathMatch{.path = "src/", .kind = PathKind::directory}, PathMatch{.path = "scripts/setup.sh", .kind = PathKind::file}};

    runtime.send(PathResults{.request_id = find.request_id, .root = find.root, .complete = true, .matches = paths});
    QTRY_COMPARE_WITH_TIMEOUT(application.paths()->state().value(QStringLiteral("count")).toInt(), 3, wait_ms);
    auto* field = line.findChild<QQuickItem*>(QStringLiteral("promptSearch"));

    QVERIFY(field != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(field->hasActiveFocus(), wait_ms);
    QTest::qWait(settle_ms);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    if (const auto picture = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_PATHS_SCREENSHOT"); !picture.isEmpty()) {
      QVERIFY(window.grabWindow().save(picture, "PNG"));
    }

    QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

    QCoreApplication::sendEvent(field, &enter);
    QVERIFY((application.dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::none));
    const std::string written{application.prompt()->line(pane_id)->text()};

    QVERIFY2(written == "git src/main.cpp", written.c_str());
  }

  // A shell ssh reached works on its host: the line names it, with the link's round trip, and
  // never shows this host's directory, only the one the remote shell reports.
  void namesTheRemoteHost(WireRuntime& runtime, const QQuickItem& line) {
    constexpr std::uint32_t round_trip_ms = 38;
    const auto* editor = line.findChild<PromptEditorItem*>();

    QVERIFY(editor != nullptr);
    runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true, .remote = true, .host = "box", .link_ms = round_trip_ms});
    QTRY_VERIFY_WITH_TIMEOUT(editor->remote(), wait_ms);
    QCOMPARE(editor->directory(), QString{});
    QCOMPARE(line.property("hostLabel").toString(), QStringLiteral("box · 38 ms"));
    runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true, .remote = true, .host = "box", .link_ms = round_trip_ms, .directory = "/srv/app"});
    QTRY_COMPARE_WITH_TIMEOUT(editor->directory(), QStringLiteral("/srv/app"), wait_ms);
    QCOMPARE(line.property("contextText").toMap().value(QStringLiteral("host")).toString(), QStringLiteral("⇄ box · 38 ms"));
  }

  // The ssh that reached a host stays open over the commands run there, which name the host, and
  // an edge runs from it down to the live end until the pane's own shell is back.
  void nestsRemoteCommands(ApplicationController& application, WireRuntime& runtime, QQmlEngine& engine, QQuickWindow& window, TerminalItem& terminal) {
    QKeyEvent close{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier};

    QCoreApplication::sendEvent(&terminal, &close);
    const ds::Array session{CommandBlock{.row = 0, .rows = 1, .state = CommandBlockState::session, .command = "ssh box", .nest = CommandBlockNest::opens}, CommandBlock{.row = 3, .rows = 1, .state = CommandBlockState::succeeded, .duration_ms = 40, .command = "ls", .nest = CommandBlockNest::inside}};

    runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = session});
    QTRY_COMPARE_WITH_TIMEOUT(terminal.separators().size(), 2, wait_ms);
    const auto opened = terminal.separators()[0].toMap();
    const auto ran = terminal.separators()[1].toMap();

    QCOMPARE(opened.value(QStringLiteral("state")).toString(), QStringLiteral("session"));
    QCOMPARE(opened.value(QStringLiteral("host")).toString(), QStringLiteral("box"));
    QVERIFY(ran.value(QStringLiteral("remote")).toBool() && ran.value(QStringLiteral("host")).toString() == QStringLiteral("box"));
    QCOMPARE(terminal.remoteRows().size(), 1);
    QCOMPARE(terminal.remoteRows()[0].toMap().value(QStringLiteral("row")).toInt(), 0);
    QCOMPARE(terminal.remoteRows()[0].toMap().value(QStringLiteral("rows")).toInt(), rows);
    if (const auto picture = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_REMOTE_SCREENSHOT"); !picture.isEmpty()) {
      const QVariantMap separator_properties{
          {QStringLiteral("view"), QVariant::fromValue(static_cast<QObject*>(&terminal))},
          {QStringLiteral("colors"), application.colors()},
          {QStringLiteral("grid"), application.display()->geometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid"))},
      };

      const auto separators = createChrome(engine, QStringLiteral("CommandSeparators"), separator_properties);

      QVERIFY(separators);
      separators->setParentItem(&terminal);
      QTest::qWait(settle_ms);
      QVERIFY(waitForSynchronizedFrame(window, wait_ms));
      QVERIFY(window.grabWindow().save(picture, "PNG"));
    }

    // The pane's own shell is back: ssh's block ends, and the edge stops at its last command.
    runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true});
    const ds::Array closed{CommandBlock{.row = 0, .rows = 1, .state = CommandBlockState::failed, .status = 255, .duration_ms = 9000, .command = "ssh box", .nest = CommandBlockNest::opens}, session[1]};

    runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = closed});
    QTRY_COMPARE_WITH_TIMEOUT(terminal.separators()[0].toMap().value(QStringLiteral("state")).toString(), QStringLiteral("failed"), wait_ms);
    QVERIFY(terminal.separators()[1].toMap().value(QStringLiteral("host")).toString().isEmpty());
    QCOMPARE(terminal.remoteRows().size(), 1);
    QVERIFY(terminal.remoteRows()[0].toMap().value(QStringLiteral("rows")).toInt() < rows);
  }

  // The environment of a runtime that sees nothing of the user's: zsh in a fresh home, with its
  // history and data in the test's directory.
  QProcessEnvironment isolatedEnvironment(const QTemporaryDir& directory, const QString& home) {
    auto environment = QProcessEnvironment::systemEnvironment();

    for (const auto& name : environment.keys()) {
      if (name.startsWith(QLatin1StringView("TELAR_")) || name == QLatin1StringView("ZDOTDIR")) {
        environment.remove(name);
      }
    }

    environment.insert(QStringLiteral("HOME"), home);
    environment.insert(QStringLiteral("SHELL"), QStringLiteral("/bin/zsh"));
    environment.insert(QStringLiteral("TELAR_HISTORY"), directory.filePath(QStringLiteral("history.db")));
    environment.insert(QStringLiteral("XDG_DATA_HOME"), directory.filePath(QStringLiteral("data")));
    return environment;
  }

  bool atBottom(const ApplicationController& application, std::uint64_t pane) {
    const auto& screen = application.pane(pane)->screen;

    return screen.scroll().offset + screen.rows() >= screen.scroll().total_rows;
  }

  // Where the view stands, for a failure's message.
  QString viewPosition(const ApplicationController& application, const TerminalItem& terminal, std::uint64_t pane) {
    return QStringLiteral("offset %1 of %2 rows, prompt row %3").arg(application.pane(pane)->screen.scroll().offset).arg(application.pane(pane)->screen.scroll().total_rows).arg(terminal.promptRow());
  }

  // Runs a command from the line and waits for the shell to be back at its prompt.
  void runCommand(ApplicationController& application, TerminalItem& terminal, std::uint64_t pane, std::string_view command) {
    const auto ran = application.pane(pane)->shell.commands;
    QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

    type(terminal, command);
    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->shell.commands == ran + 1 && application.prompt()->surface(pane) == application::prompt::Surface::editor, runtime_wait_ms);
  }

  // The shell runs the command the line sends, the runtime anchors its block where its prompt was,
  // and a command sent before is suggested as its start is typed.
  void runsAndSuggests(ApplicationController& application, TerminalItem& terminal, const QQuickItem& line, std::uint64_t pane, const QString& marker) {
    type(terminal, ("touch " + marker).toStdString());
    QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(marker), runtime_wait_ms);
    QTRY_VERIFY2_WITH_TIMEOUT(application.pane(pane)->shell.commands == 1 && application.prompt()->surface(pane) == application::prompt::Surface::editor, qPrintable(QStringLiteral("commands=%1 phase=%2 surface=%3 foreground=%4").arg(application.pane(pane)->shell.commands).arg(static_cast<int>(application.pane(pane)->shell.phase)).arg(static_cast<int>(application.prompt()->surface(pane))).arg(application.pane(pane)->shell.shell_foreground)), 8000);
    QCOMPARE(application.pane(pane)->shell.status, 0);
    // The runtime anchored the command's block where its prompt was, and the terminal draws
    // its separator there.
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 1 && application.pane(pane)->blocks.front().state == CommandBlockState::succeeded, runtime_wait_ms);
    QVERIFY(application.pane(pane)->blocks.front().command.ends_with(("touch " + marker).toStdString()));
    QTRY_COMPARE_WITH_TIMEOUT(terminal.separators().size(), 1, runtime_wait_ms);
    // A command sent before is suggested as its start is typed, for a key to take it.
    type(terminal, "tou");
    const auto* editor = line.findChild<PromptEditorItem*>();

    QTRY_VERIFY_WITH_TIMEOUT(editor != nullptr && editor->suggesting(), runtime_wait_ms);
    QCOMPARE(editor->mode(), QStringLiteral("emacs"));
    QKeyEvent erase{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};

    QCoreApplication::sendEvent(&terminal, &erase);
    QTRY_VERIFY_WITH_TIMEOUT(!editor->suggesting(), runtime_wait_ms);
  }

  // The process card of the pane reads what its shell ran last through the runtime: the command,
  // how it ended and where the pane works.
  void cardReadsTheLastCommand(ApplicationController& application, const QString& marker) {
    const auto card = [&] {
      const auto* rows = application.activity()->rows();

      for (int row = 0; row < rows->rowCount(); ++row) {
        const auto record = rows->data(rows->index(row, 0), ListModel::record_role).toMap();
        if (record.value(QStringLiteral("process")).toBool()) {
          return record;
        }
      }

      return QVariantMap{};
    };

    QTRY_VERIFY2_WITH_TIMEOUT(card().value(QStringLiteral("commandLine")).toString().endsWith(QStringLiteral("touch ") + marker), qPrintable(card().value(QStringLiteral("commandLine")).toString() + QStringLiteral(" / ") + card().value(QStringLiteral("commandState")).toString()), runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(card().value(QStringLiteral("commandState")).toString(), QStringLiteral("finished"), runtime_wait_ms);
    QCOMPARE(card().value(QStringLiteral("exitCode")), QVariant{0});
    QVERIFY(!card().value(QStringLiteral("commandDuration")).toString().isEmpty());
    QVERIFY(!card().value(QStringLiteral("cwd")).toString().isEmpty());
  }

  // A command that fails: its block says so, and its separator offers the way to its error. The
  // runtime finds the commands the shell runs, and only those.
  void marksFailuresAndPresence(ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, const QQuickItem& line, std::uint64_t pane) {
    QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

    type(terminal, "ls /nonexistent-telar");
    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 2 && application.pane(pane)->blocks.back().state == CommandBlockState::failed, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(line.property("offerFailure").toBool() && terminal.separators().back().toMap().value(QStringLiteral("state")).toString() == QStringLiteral("failed"), runtime_wait_ms);
    QCOMPARE(terminal.rail().size(), 2);
    // The runtime finds the commands the shell runs, and only those.
    type(terminal, "gti x && ls ./");
    QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->commandPresence(pane, "gti"), application::prompt::CommandPresence::missing, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->commandPresence(pane, "ls"), application::prompt::CommandPresence::found, runtime_wait_ms);
    const auto blocks = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_BLOCKS_SCREENSHOT");
    if (!blocks.isEmpty()) {
      QTest::qWait(settle_ms);
      QVERIFY(waitForSynchronizedFrame(window, wait_ms));
      QVERIFY(window.grabWindow().save(blocks, "PNG"));
    }
  }

  // A full-screen program comes and goes: the commands before it keep their blocks, and the line
  // takes the keys again once the shell is back at its prompt.
  void returnsFromFullScreen(ApplicationController& application, TerminalItem& terminal, std::uint64_t pane) {
    QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};
    QKeyEvent erase{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};

    QCoreApplication::sendEvent(&terminal, &erase);
    const auto before_vim = application.pane(pane)->blocks.size();

    type(terminal, "vim -u NONE");
    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->screen.modes().alternate_screen, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->surface(pane), application::prompt::Surface::none, runtime_wait_ms);
    QKeyEvent escape{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier, QStringLiteral("\x1b")};

    QCoreApplication::sendEvent(&terminal, &escape);
    type(terminal, ":q");
    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(!application.pane(pane)->screen.modes().alternate_screen && application.prompt()->surface(pane) == application::prompt::Surface::editor, runtime_wait_ms);
    QTRY_VERIFY2_WITH_TIMEOUT(application.pane(pane)->blocks.size() == before_vim + 1, qPrintable(QStringLiteral("blocks %1, before %2").arg(application.pane(pane)->blocks.size()).arg(before_vim)), runtime_wait_ms);
    const auto inputs = application.pane(pane)->shell.commands;

    type(terminal, "echo after-vim");
    QVERIFY2(application.prompt()->line(pane)->text() == "echo after-vim", "the line takes the keys again");
    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->shell.commands == inputs + 1 && application.pane(pane)->blocks.size() == before_vim + 2, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminal.promptRow() >= 0, runtime_wait_ms);
  }

  // Scrolled back to the bottom, the view follows the output, and the shell's prompt stays hidden
  // under the line: after more output, and after `clear`. Scrolled up, the line docks.
  void followsOutput(ApplicationController& application, TerminalItem& terminal, const QQuickItem& line, std::uint64_t pane) {
    runCommand(application, terminal, pane, "seq 60");
    QTRY_VERIFY_WITH_TIMEOUT(atBottom(application, pane), runtime_wait_ms);
    application.terminals()->scroll(application::PaneScrollDelta{.pane_id = pane, .rows = 3});
    QTRY_VERIFY_WITH_TIMEOUT(!atBottom(application, pane), runtime_wait_ms);
    QTRY_VERIFY2_WITH_TIMEOUT(line.property("docked").toBool() && terminal.rowsBelow() == 3, qPrintable(QStringLiteral("docked %1 below %2 offset %3 total %4 rows %5").arg(line.property("docked").toBool()).arg(terminal.rowsBelow()).arg(application.pane(pane)->screen.scroll().offset).arg(application.pane(pane)->screen.scroll().total_rows).arg(application.pane(pane)->screen.rows())), runtime_wait_ms);
    application.terminals()->scroll(application::PaneScrollDelta{.pane_id = pane, .rows = -3});
    QTRY_VERIFY_WITH_TIMEOUT(atBottom(application, pane), runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!line.property("docked").toBool(), runtime_wait_ms);
    runCommand(application, terminal, pane, "seq 30");
    QTRY_VERIFY2_WITH_TIMEOUT(atBottom(application, pane) && terminal.promptRow() >= 0, qPrintable(viewPosition(application, terminal, pane)), runtime_wait_ms);
    runCommand(application, terminal, pane, "clear");
    QTRY_VERIFY2_WITH_TIMEOUT(atBottom(application, pane) && terminal.promptRow() >= 0, qPrintable(viewPosition(application, terminal, pane)), runtime_wait_ms);
  }

  // With a scrollback of commands, gg goes to its top and G back to the live end.
  void jumpsAcrossScrollback(ApplicationController& application, TerminalItem& terminal, std::uint64_t pane) {
    // Printed for a pane that shows no top row.
    constexpr std::uint64_t no_top = 9999;

    runCommand(application, terminal, pane, "seq 40");
    runCommand(application, terminal, pane, "seq 40");
    runCommand(application, terminal, pane, "seq 40");
    QTRY_VERIFY_WITH_TIMEOUT(atBottom(application, pane), runtime_wait_ms);
    // The last command selected, as prefix+[ selects it with any keymap.
    application.terminals()->selectBlock(pane, application.pane(pane)->blocks.size() - 1);
    QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->selectedBlock(pane).hasValue(), runtime_wait_ms);
    // gg goes to the scrollback's top and G back to the live end.
    const auto top_where = [&] {
      return viewPosition(application, terminal, pane) + QStringLiteral(", shown top %1").arg(application.pane(pane)->shown_top.valueOr(no_top));
    };

    type(terminal, "gg");
    QTRY_VERIFY2_WITH_TIMEOUT(application.pane(pane)->screen.scroll().offset == 0 && application.pane(pane)->shown_top == ds::Option<std::uint64_t>{0}, qPrintable(top_where()), runtime_wait_ms);
    QKeyEvent end{QEvent::KeyPress, Qt::Key_G, Qt::ShiftModifier, QStringLiteral("G")};

    QCoreApplication::sendEvent(&terminal, &end);
    QTRY_VERIFY2_WITH_TIMEOUT(atBottom(application, pane) && terminal.rowsBelow() == 0 && !application.prompt()->selectedBlock(pane), qPrintable(top_where()), runtime_wait_ms);
  }

  // A fold in view moves: right after zc the output is shrinking under its separator, and when it
  // settles the fold is done and nothing is offset; zo grows it back.
  void foldsInView(ApplicationController& application, TerminalItem& terminal, QQuickItem& line, std::uint64_t pane) {
    application.terminals()->selectBlock(pane, application.pane(pane)->blocks.size() - 1);
    QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->selectedBlock(pane).hasValue(), runtime_wait_ms);
    QKeyEvent scroll_up{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};

    // The view settles on the command first, as a reader's would.
    QTest::qWait(view_settle_ms);
    type(terminal, "zc");
    QVERIFY2(terminal.foldFrom() >= 0, "folding a command in view starts its motion");
    QTRY_VERIFY_WITH_TIMEOUT(terminal.foldFrom() < 0 && terminal.foldOffset() == 0 && !application.pane(pane)->folds.empty(), runtime_wait_ms);
    const auto folded_top = application.pane(pane)->shown_top;

    type(terminal, "zo");
    QVERIFY2(terminal.foldFrom() >= 0, "unfolding a command in view starts its motion");
    QTRY_VERIFY_WITH_TIMEOUT(terminal.foldFrom() < 0 && application.pane(pane)->folds.empty(), runtime_wait_ms);
    QVERIFY2(application.pane(pane)->shown_top == folded_top, "unfolding keeps the row at the top where it was");
    // Folded commands bring the live prompt into view whichever command is selected: the
    // runtime's view settles at the bottom, the shell's prompt stays hidden and the line stands
    // where it is, not docked.
    type(terminal, "zM");
    QTRY_VERIFY_WITH_TIMEOUT(!application.pane(pane)->folds.empty(), runtime_wait_ms);
    QCoreApplication::sendEvent(&terminal, &scroll_up);
    const auto folded_where = [&] {
      return viewPosition(application, terminal, pane) + QStringLiteral(", rows below %1, docked %2").arg(terminal.rowsBelow()).arg(line.property("docked").toBool());
    };

    QTRY_VERIFY2_WITH_TIMEOUT(atBottom(application, pane) && terminal.rowsBelow() == 0 && terminal.promptRow() >= 0 && !line.property("docked").toBool(), qPrintable(folded_where()), runtime_wait_ms);
    type(terminal, "zR");
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->folds.empty(), runtime_wait_ms);
  }

  // / searches the command's output from the line under the pane, no dialog over it: the matches
  // arrive as the query is typed, and Enter leaves them for n and N.
  void searchesScrollback(ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem& line, std::uint64_t pane) {
    type(terminal, "/");
    QTRY_VERIFY_WITH_TIMEOUT(application.dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::copy_search && application.dialogs()->lineSearch() == telar::gui::qt::ApplicationController::Dialog::copy_search && line.property("searching").toBool(), runtime_wait_ms);
    const QQuickItem* query = nullptr;
    const auto find_query = [&] {
      query = line.findChild<QQuickItem*>(QStringLiteral("scrollbackSearch"));
      return query != nullptr;
    };

    QTRY_VERIFY_WITH_TIMEOUT(find_query(), runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(query->hasActiveFocus(), runtime_wait_ms);
    QTest::keyClick(&window, Qt::Key_3);
    QTRY_VERIFY2_WITH_TIMEOUT(application.copy()->searchState().value(QStringLiteral("count")).toInt() > 0, qPrintable(QStringLiteral("search %1").arg(QString::fromUtf8(QJsonDocument::fromVariant(application.copy()->searchState()).toJson(QJsonDocument::Compact)))), runtime_wait_ms);
    QTest::keyClick(&window, Qt::Key_Return);
    QTRY_VERIFY_WITH_TIMEOUT((application.dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::none) && application.copy()->active() && application.copy()->searchState().value(QStringLiteral("count")).toInt() > 0, runtime_wait_ms);
    type(terminal, "q");
    QTRY_VERIFY_WITH_TIMEOUT(!application.copy()->active(), runtime_wait_ms);
    QKeyEvent back{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier};

    QCoreApplication::sendEvent(&terminal, &back);
    QTRY_VERIFY_WITH_TIMEOUT(!application.prompt()->selectedBlock(pane).hasValue() && atBottom(application, pane), runtime_wait_ms);
  }

  // The view over a real shell's scrollback: following, jumping, folding and searching it.
  void exercisesScrollback(ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem& line, std::uint64_t pane) {
    followsOutput(application, terminal, line, pane);
    QVERIFY(!QTest::currentTestFailed());
    jumpsAcrossScrollback(application, terminal, pane);
    QVERIFY(!QTest::currentTestFailed());
    foldsInView(application, terminal, line, pane);
    QVERIFY(!QTest::currentTestFailed());
    searchesScrollback(application, window, terminal, line, pane);
  }

  // The runtime serves the spec of a command the shell runs: Tab completes git's subcommand, and
  // an alias the shell defines completes as the command it stands for.
  void completesFromSpecs(ApplicationController& application, TerminalItem& terminal, std::uint64_t pane) {
    if (QStandardPaths::findExecutable(QStringLiteral("git")).isEmpty()) {
      return;
    }

    QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};
    QKeyEvent erase{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};

    QCoreApplication::sendEvent(&terminal, &erase);
    type(terminal, "git sw");
    QKeyEvent complete{QEvent::KeyPress, Qt::Key_Tab, Qt::NoModifier, QStringLiteral("\t")};

    QCoreApplication::sendEvent(&terminal, &complete);
    QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->line(pane)->text(), std::string_view{"git switch "}, runtime_wait_ms);
    // An alias the shell defines completes as the command it stands for.
    QCoreApplication::sendEvent(&terminal, &erase);
    const auto ran = application.pane(pane)->shell.commands;

    type(terminal, "alias gsw='git switch'");
    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->shell.commands == ran + 1 && application.prompt()->surface(pane) == application::prompt::Surface::editor, runtime_wait_ms);
    type(terminal, "gsw --det");
    QCoreApplication::sendEvent(&terminal, &complete);
    QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->line(pane)->text(), std::string_view{"gsw --detach "}, runtime_wait_ms);
  }

  // A quick command: it flies to its separator while its output waits, then the output enters
  // line by line. TELAR_GUI_TEST_PROMPT_LAUNCH_FRAMES names where frames go.
  void recordsLaunchFrames(QQuickWindow& window, TerminalItem& terminal) {
    const auto frames = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_LAUNCH_FRAMES");
    if (frames.isEmpty()) {
      return;
    }

    constexpr int frame_count = 12;
    constexpr int frame_interval_ms = 30;
    QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};
    QKeyEvent erase{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};

    QCoreApplication::sendEvent(&terminal, &erase);
    type(terminal, "ls /");
    QCoreApplication::sendEvent(&terminal, &enter);
    for (int frame = 0; frame < frame_count; ++frame) {
      QVERIFY(window.grabWindow().save(frames + QString::number(frame) + QStringLiteral(".png"), "PNG"));
      QTest::qWait(frame_interval_ms);
    }
  }

  // The native prompt's view, blocks and clipboard, each against a real zsh.

  constexpr auto telar_config = "return {api_version=2,client={prompt={mode='telar'}}}";
  constexpr auto telar_vim_config = "return {api_version=2,client={prompt={mode='telar',keymap='vim'}}}";

  // The highest `tick<N>` the pane's screen holds, 0 for none.
  int lastTick(const ApplicationController& application, std::uint64_t pane) {
    static const QRegularExpression tick{QStringLiteral("tick(\\d+)")};
    int last = 0;

    for (auto match = tick.globalMatch(screenText(application.pane(pane)->screen)); match.hasNext();) {
      last = std::max(last, match.next().captured(1).toInt());
    }

    return last;
  }

  // A notch of a mouse wheel over the terminal, `notches` up when positive.
  void wheel(QQuickWindow& window, TerminalItem& terminal, int notches) {
    constexpr int notch = 120;
    const QPointF position{terminal.width() / 2, terminal.height() / 2};
    QWheelEvent event{position, window.mapToGlobal(position), QPoint{}, QPoint{0, notches * notch}, Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false};

    QCoreApplication::sendEvent(&terminal, &event);
  }

  QString clipboardText() {
    return QGuiApplication::clipboard()->text();
  }

  // Where the view stands and what it shows, for a failure's message.
  QString viewState(const ApplicationController& application, const TerminalItem& terminal, std::uint64_t pane) {
    return viewPosition(application, terminal, pane) + QStringLiteral(", rows below %1, arrived %2, at bottom %3, last tick %4").arg(terminal.rowsBelow()).arg(terminal.rowsArrived()).arg(atBottom(application, pane)).arg(lastTick(application, pane));
  }

  // Drags the pointer over row `row` of the view, from column `first` to `last`, and lets go.
  void dragRow(QQuickWindow& window, const TerminalItem& terminal, int row, int first, int last) {
    const auto cell = terminal.cellSize();
    const auto at = [&](int column) {
      return terminal.mapToScene(QPointF{(column + 0.5) * cell.width(), (row + 0.5) * cell.height()}).toPoint();
    };

    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, at(first));
    QTest::mouseMove(&window, at((first + last) / 2));
    QTest::mouseMove(&window, at(last));
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, at(last));
  }

  // The platform's copy key over the terminal: Cmd+C, or Ctrl+Shift+C.
  void pressCopy(TerminalItem& terminal, Qt::Key key = Qt::Key_C) {
#ifdef __APPLE__
    constexpr Qt::KeyboardModifiers copy_modifiers = Qt::ControlModifier;
#else
    constexpr Qt::KeyboardModifiers copy_modifiers = Qt::ControlModifier | Qt::ShiftModifier;
#endif
    QKeyEvent copy{QEvent::KeyPress, key, copy_modifiers, key == Qt::Key_C ? QStringLiteral("c") : QString{}};

    QCoreApplication::sendEvent(&terminal, &copy);
  }

  // The view row of block `index`'s separator, -1 while it is not in view.
  int separatorRow(const TerminalItem& terminal, int index) {
    for (const auto& separator : terminal.separators()) {
      const auto map = separator.toMap();
      if (map.value(QStringLiteral("index")).toInt() == index) {
        return map.value(QStringLiteral("row")).toInt();
      }
    }

    return -1;
  }

  // A runtime that integrates a real zsh in a fresh home, a window with a pane of it, the
  // separators, the rail and the line over its terminal, and `config` as the client's file; `body`
  // runs with them. The runtime reads `runtime_config` when one is given, and no configuration
  // otherwise. Needs TELAR_GUI_TEST_RUNTIME and /bin/zsh.
  template <typename Body>
  void withRealShell(const QByteArray& config, Body body, const QByteArray& runtime_config = {}) {
    const auto executable = qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME");
    if (executable.isEmpty() || !QFileInfo::exists(QStringLiteral("/bin/zsh"))) {
      QSKIP("Set TELAR_GUI_TEST_RUNTIME to a runtime executable; needs /bin/zsh");
    }

    const QTemporaryDir directory;

    QVERIFY(directory.isValid());
    const auto home = directory.filePath(QStringLiteral("home"));

    QVERIFY(QDir{}.mkpath(home));
    const auto socket = directory.filePath(QStringLiteral("runtime.sock"));
    QProcess runtime;

    runtime.setProgram(executable);
    if (runtime_config.isEmpty()) {
      runtime.setArguments({QStringLiteral("server"), QStringLiteral("--no-config"), QStringLiteral("--fresh"), QStringLiteral("--socket"), socket});
    } else {
      const auto runtime_path = directory.filePath(QStringLiteral("runtime-config.lua"));
      QFile runtime_file{runtime_path};

      QVERIFY(runtime_file.open(QIODevice::WriteOnly));
      runtime_file.write(runtime_config);
      runtime_file.close();
      runtime.setArguments({QStringLiteral("server"), QStringLiteral("--config"), runtime_path, QStringLiteral("--fresh"), QStringLiteral("--socket"), socket});
    }

    runtime.setProcessEnvironment(isolatedEnvironment(directory, home));
    runtime.start();
    QVERIFY(runtime.waitForStarted());
    const auto stop = qScopeGuard([&] {
      runtime.terminate();
      runtime.waitForFinished(stop_wait_ms);
    });

    QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(socket), runtime_wait_ms);
    qputenv("SHELL", "/bin/zsh");

    ApplicationMemory application_memory;
    ApplicationAllocator& memory = application_memory.memory();
    ApplicationController application{memory};
    const auto config_path = directory.filePath(QStringLiteral("config.lua"));
    QFile file{config_path};

    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(config);
    file.close();
    application.loadConfiguration(config_path, {}, {});
    QQuickWindow window;

    window.resize(screen_size);
    application.setWindow(window);
    application.machines()->open(socket);
    QTRY_COMPARE_WITH_TIMEOUT(application.panes()->rows()->rowCount(), 1, runtime_wait_ms);
    const auto record = application.panes()->rows()->data(application.panes()->rows()->index(0, 0), ListModel::record_role).toMap();
    const auto pane = record.value(QStringLiteral("key")).toString().toULongLong();

    QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->surface(pane), application::prompt::Surface::editor, runtime_wait_ms);

    TerminalItem terminal{window.contentItem()};

    terminal.setController(application.terminals());
    terminal.setPaneId(QString::number(pane));
    terminal.setSize(QSizeF{screen_size});
    // The pieces a pane stacks over its terminal: the separators, the rail and the line.
    constexpr QPointF rail_position{700, 12};
    constexpr qreal rail_height = 180;
    QQmlEngine engine;
    const auto grid = application.display()->geometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid"));
    const auto separators = createChrome(engine, QStringLiteral("CommandSeparators"), {{QStringLiteral("view"), QVariant::fromValue(static_cast<QObject*>(&terminal))}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("grid"), grid}});

    separators->setParentItem(&terminal);
    const auto rail = createChrome(engine, QStringLiteral("CommandRail"), {{QStringLiteral("view"), QVariant::fromValue(static_cast<QObject*>(&terminal))}, {QStringLiteral("colors"), application.colors()}});

    rail->setParentItem(&terminal);
    rail->setPosition(rail_position);
    rail->setHeight(rail_height);
    const auto line = createPromptLine(engine, application, terminal, pane);

    line->setParentItem(&terminal);
    window.show();
    QVERIFY(QTest::qWaitForWindowExposed(&window, wait_ms));
    terminal.forceActiveFocus();

    body(application, window, terminal, *line, pane, directory);
  }

  class PromptWindowTest : public QObject {
    Q_OBJECT

    // The prompt line takes the keys of a shell at its prompt, sends the finished command as one
    // paste and Enter, and stands in for the shell's prompt rows.
    Q_SLOT static void lineEditsAndRunsCommands() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController application{memory};
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto config = directory.filePath(QStringLiteral("config.lua"));
      QFile file{config};

      QVERIFY(file.open(QIODevice::WriteOnly));
      file.write("return {api_version=2,client={prompt={mode='telar'}}}");
      file.close();
      application.loadConfiguration(config, {}, {});
      QVERIFY2(application.status()->error().isEmpty(), qPrintable(application.status()->error()));

      QLocalServer listener;

      QVERIFY(listener.listen(directory.filePath(QStringLiteral("runtime.sock"))));
      QQuickWindow window;

      window.resize(screen_size);
      application.setWindow(window);
      application.machines()->open(listener.fullServerName());
      QVERIFY(waitForGuiCondition([&] {
        return listener.hasPendingConnections();
      },
          wait_ms));
      std::unique_ptr<QLocalSocket> socket{listener.nextPendingConnection()};
      WireRuntime runtime{*socket};

      QVERIFY(waitForGuiCondition([&] {
        return application.status()->connected();
      },
          wait_ms));
      runtime.send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(runtime));
      sendPromptScreen(runtime, 1);
      runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true});
      QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->surface(pane_id), application::prompt::Surface::editor, wait_ms);

      TerminalItem terminal{window.contentItem()};

      terminal.setController(application.terminals());
      terminal.setPaneId(QString::number(pane_id));
      terminal.setSize(QSizeF{screen_size});
      QQmlEngine engine;
      const auto line = createPromptLine(engine, application, terminal, pane_id);

      QVERIFY(line);
      line->setParentItem(&terminal);
      window.show();
      QVERIFY(QTest::qWaitForWindowExposed(&window, wait_ms));
      terminal.forceActiveFocus();
      QVERIFY(waitForSynchronizedFrame(window, wait_ms));

      runsTypedCommand(application, runtime, window, terminal, *line);
      QVERIFY(!QTest::currentTestFailed());
      completesAtThePrompt(application, runtime, window, terminal, *line);
    }

    // At the shell's prompt, the history and path searches open on the prompt line instead of a
    // dialog: they start from the line, take the keyboard, and give it back as they close.
    // A separator stays as its command's rows move and updates in place, so a command that ends
    // under it is settled as one built afresh would be: its clock forgotten, its end recorded.
    Q_SLOT static void separatorSettlesACommandThatEnds() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController application{memory};
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto config = directory.filePath(QStringLiteral("config.lua"));
      QFile file{config};

      QVERIFY(file.open(QIODevice::WriteOnly));
      file.write("return {api_version=2,client={prompt={mode='telar'}}}");
      file.close();
      application.loadConfiguration(config, {}, {});
      QLocalServer listener;

      QVERIFY(listener.listen(directory.filePath(QStringLiteral("runtime.sock"))));
      QQuickWindow window;

      window.resize(screen_size);
      application.setWindow(window);
      application.machines()->open(listener.fullServerName());
      QVERIFY(waitForGuiCondition([&] {
        return listener.hasPendingConnections();
      },
          wait_ms));
      std::unique_ptr<QLocalSocket> socket{listener.nextPendingConnection()};
      WireRuntime runtime{*socket};

      QVERIFY(waitForGuiCondition([&] {
        return application.status()->connected();
      },
          wait_ms));
      runtime.send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(runtime));
      sendPromptScreen(runtime, 1);
      runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true});
      TerminalItem terminal{window.contentItem()};

      terminal.setController(application.terminals());
      terminal.setPaneId(QString::number(pane_id));
      terminal.setSize(QSizeF{screen_size});
      QQmlEngine engine;
      const auto grid = application.display()->geometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid"));
      const auto separators = createChrome(engine, QStringLiteral("CommandSeparators"), {{QStringLiteral("view"), QVariant::fromValue(static_cast<QObject*>(&terminal))}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("grid"), grid}});

      separators->setParentItem(&terminal);
      window.show();

      const ds::Array running{CommandBlock{.row = 0, .rows = 1, .state = CommandBlockState::running, .command = "make"}};

      runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = running});
      QTRY_VERIFY_WITH_TIMEOUT(separators->property("started").toMap().contains(QStringLiteral("0")), wait_ms);
      const ds::Array failed{CommandBlock{.row = 0, .rows = 1, .state = CommandBlockState::failed, .status = 2, .duration_ms = 40, .command = "make"}};

      runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = failed});
      QTRY_COMPARE_WITH_TIMEOUT(separators->property("drawn").toMap().value(QStringLiteral("0")).toString(), QStringLiteral("failed"), wait_ms);
      QVERIFY(!separators->property("started").toMap().contains(QStringLiteral("0")));
    }

    Q_SLOT static void lineHostsSearches() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController application{memory};
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto config = directory.filePath(QStringLiteral("config.lua"));
      QFile file{config};

      QVERIFY(file.open(QIODevice::WriteOnly));
      file.write("return {api_version=2,client={prompt={mode='telar'}}}");
      file.close();
      application.loadConfiguration(config, {}, {});
      QVERIFY2(application.status()->error().isEmpty(), qPrintable(application.status()->error()));

      QLocalServer listener;

      QVERIFY(listener.listen(directory.filePath(QStringLiteral("runtime.sock"))));
      QQuickWindow window;

      window.resize(search_screen_size);
      application.setWindow(window);
      application.machines()->open(listener.fullServerName());
      QVERIFY(waitForGuiCondition([&] {
        return listener.hasPendingConnections();
      },
          wait_ms));
      std::unique_ptr<QLocalSocket> socket{listener.nextPendingConnection()};
      WireRuntime runtime{*socket};

      QVERIFY(waitForGuiCondition([&] {
        return application.status()->connected();
      },
          wait_ms));
      runtime.send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(runtime));
      sendPromptScreen(runtime, 1);
      runtime.send(PaneCwd{.pane_id = pane_id, .cwd = "/work"});
      runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true});
      QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->surface(pane_id), application::prompt::Surface::editor, wait_ms);

      TerminalItem terminal{window.contentItem()};

      terminal.setController(application.terminals());
      terminal.setPaneId(QString::number(pane_id));
      terminal.setSize(QSizeF{search_screen_size});
      QQmlEngine engine;
      const auto line = createPromptLine(engine, application, terminal, pane_id);

      QVERIFY(line);
      line->setParentItem(&terminal);
      window.show();
      QVERIFY(QTest::qWaitForWindowExposed(&window, wait_ms));
      terminal.forceActiveFocus();
      QVERIFY(waitForSynchronizedFrame(window, wait_ms));

      searchesHistory(application, runtime, window, terminal, *line);
      QVERIFY(!QTest::currentTestFailed());
      searchesPaths(application, runtime, window, *line);
      QVERIFY(!QTest::currentTestFailed());
      namesTheRemoteHost(runtime, *line);
      QVERIFY(!QTest::currentTestFailed());
      nestsRemoteCommands(application, runtime, engine, window, terminal);
    }

    // In a narrow pane the line turns compact: the mode's chip gives its columns to the context,
    // which never runs past them.
    Q_SLOT static void lineTurnsCompactWhenNarrow() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController application{memory};
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto config = directory.filePath(QStringLiteral("config.lua"));
      QFile file{config};

      QVERIFY(file.open(QIODevice::WriteOnly));
      file.write("return {api_version=2,client={prompt={mode='telar',keymap='vim'}}}");
      file.close();
      application.loadConfiguration(config, {}, {});
      QVERIFY2(application.status()->error().isEmpty(), qPrintable(application.status()->error()));

      QLocalServer listener;

      QVERIFY(listener.listen(directory.filePath(QStringLiteral("runtime.sock"))));
      QQuickWindow window;

      window.resize(wide_screen_size);
      application.setWindow(window);
      application.machines()->open(listener.fullServerName());
      QVERIFY(waitForGuiCondition([&] {
        return listener.hasPendingConnections();
      },
          wait_ms));
      std::unique_ptr<QLocalSocket> socket{listener.nextPendingConnection()};
      WireRuntime runtime{*socket};

      QVERIFY(waitForGuiCondition([&] {
        return application.status()->connected();
      },
          wait_ms));
      runtime.send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(runtime));
      sendPromptScreen(runtime, 1);
      constexpr std::string_view cwd = "/home/user/projects/telar";

      runtime.send(PaneCwd{.pane_id = pane_id, .cwd = cwd});
      runtime.send(PaneGit{.pane_id = pane_id, .repository = true, .branch = "feat/shell-integration"});
      runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true});
      QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->surface(pane_id), application::prompt::Surface::editor, wait_ms);

      TerminalItem terminal{window.contentItem()};

      terminal.setController(application.terminals());
      terminal.setPaneId(QString::number(pane_id));
      terminal.setSize(QSizeF{wide_screen_size});
      QQmlEngine engine;
      const auto line = createPromptLine(engine, application, terminal, pane_id);

      QVERIFY(line);
      line->setParentItem(&terminal);
      window.show();
      QVERIFY(QTest::qWaitForWindowExposed(&window, wait_ms));
      terminal.forceActiveFocus();
      QVERIFY(waitForSynchronizedFrame(window, wait_ms));
      // The editor takes its keymap with its first key.
      type(terminal, "ls");

      const auto context = [&] {
        return line->property("contextText").toMap();
      };

      QTRY_COMPARE_WITH_TIMEOUT(context().value(QStringLiteral("branch")).toString(), QStringLiteral("⎇ feat/shell-integration"), wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(line->property("modeShown").toBool(), wait_ms);
      QVERIFY(!line->property("compact").toBool());
      QCOMPARE(context().value(QStringLiteral("directory")).toString(), QString::fromUtf8(cwd.data(), static_cast<qsizetype>(cwd.size())));

      terminal.setSize(QSizeF{narrow_screen_size});
      QTRY_VERIFY_WITH_TIMEOUT(line->property("compact").toBool(), wait_ms);
      const auto narrow = context();
      const auto directory_text = narrow.value(QStringLiteral("directory")).toString();
      const auto branch_text = narrow.value(QStringLiteral("branch")).toString();

      QVERIFY2(directory_text.startsWith(QStringLiteral("…/")), qPrintable(directory_text));
      const auto span = directory_text.size() + (branch_text.isEmpty() ? 0 : branch_text.size() + 2);

      QVERIFY2(span <= line->property("contextColumns").toInt(), qPrintable(directory_text + QStringLiteral(" ") + branch_text));

      terminal.setSize(QSizeF{wide_screen_size});
      QTRY_VERIFY_WITH_TIMEOUT(!line->property("compact").toBool(), wait_ms);
    }

    // What the line offers a person typing at a real zsh, each step in a picture when
    // TELAR_SHOTS_DIR is set: Up by the typed prefix, the suggestion for this directory, the fuzzy
    // menu, an option its command refuses, an alias expanded, the command meant after a typo, the
    // notice of a paste too large, and keys typed ahead given back to the line.
    Q_SLOT static void showsWhatThePromptOffers() {
      withRealShell("return {api_version=2,client={prompt={mode='telar',expand_aliases=true}}}", [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem& line, std::uint64_t pane, const QTemporaryDir& directory) {
        const auto* editor = line.findChild<PromptEditorItem*>();
        const auto text = [&] {
          return std::string{application.prompt()->line(pane)->text()};
        };
        const auto clear = [&] {
          QKeyEvent escape{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier};
          QKeyEvent erase{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};

          QCoreApplication::sendEvent(&terminal, &escape);
          QCoreApplication::sendEvent(&terminal, &erase);
          QTRY_VERIFY_WITH_TIMEOUT(text().empty(), wait_ms);
        };
        const auto picture = [&](const QString& name) {
          QTest::qWait(settle_ms);
          QVERIFY(waitForSynchronizedFrame(window, wait_ms));
          shoot(window, name);
        };

        QVERIFY(editor != nullptr);
        // Up walks the commands that start with what is typed.
        runCommand(application, terminal, pane, "git --exec-path");
        runCommand(application, terminal, pane, "ls");
        runCommand(application, terminal, pane, "echo done");
        type(terminal, "git");
        QKeyEvent up{QEvent::KeyPress, Qt::Key_Up, Qt::NoModifier};

        QCoreApplication::sendEvent(&terminal, &up);
        QTRY_COMPARE_WITH_TIMEOUT(text(), std::string{"git --exec-path"}, wait_ms);
        picture(QStringLiteral("01-prompt-up-by-prefix"));
        clear();

        // The suggestion prefers what ran in this directory over what ran last.
        QVERIFY(QDir{directory.path()}.mkpath(QStringLiteral("api")) && QDir{directory.path()}.mkpath(QStringLiteral("web")));
        runCommand(application, terminal, pane, "cd " + directory.filePath(QStringLiteral("api")).toStdString());
        runCommand(application, terminal, pane, "echo building the api");
        runCommand(application, terminal, pane, "cd ../web");
        runCommand(application, terminal, pane, "echo building the web");
        runCommand(application, terminal, pane, "cd ../api");
        type(terminal, "echo b");
        QTRY_VERIFY_WITH_TIMEOUT(editor->suggesting(), runtime_wait_ms);
        picture(QStringLiteral("02-prompt-contextual-suggestion"));
        clear();

        // Tab narrows the choices fuzzily, in a menu under the line: the screen is cleared so the
        // line is at its top.
        runCommand(application, terminal, pane, "clear");
        type(terminal, "ls --s");
        QTest::qWait(spec_wait_ms);
        QKeyEvent tab{QEvent::KeyPress, Qt::Key_Tab, Qt::NoModifier, QStringLiteral("\t")};

        QCoreApplication::sendEvent(&terminal, &tab);
        QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->line(pane)->menu().hasValue(), runtime_wait_ms);
        // Typing on narrows the menu as a fuzzy finder does: `sz` keeps --size.
        type(terminal, "z");
        QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->line(pane)->menu().hasValue() && std::ranges::any_of(application.prompt()->line(pane)->menu()->choices, [](const auto& choice) {
          return choice.text.view() == "--size";
        }),
            runtime_wait_ms);
        picture(QStringLiteral("03-prompt-fuzzy-menu"));
        clear();

        // An option the command refuses is marked as it is typed past.
        type(terminal, "ls --colour -la");
        QTest::qWait(spec_wait_ms);
        picture(QStringLiteral("04-prompt-invalid-option"));
        clear();

        // A space after an alias writes what it stands for.
        runCommand(application, terminal, pane, "alias gst='git status'");
        // The shell tells its aliases at its prompt, and the runtime the alias's words with the
        // command's spec, which the line asks for as the command is typed.
        type(terminal, "gst");
        QTest::qWait(spec_wait_ms);
        type(terminal, " ");
        QTRY_COMPARE_WITH_TIMEOUT(text(), std::string{"git status "}, runtime_wait_ms);
        picture(QStringLiteral("05-prompt-alias-expansion"));
        clear();

        // A command the shell did not find: the empty line suggests the one meant.
        runCommand(application, terminal, pane, "gti --version");
        QTRY_VERIFY_WITH_TIMEOUT(editor->suggesting(), runtime_wait_ms);
        picture(QStringLiteral("06-prompt-did-you-mean"));
        clear();

        // A paste larger than a command may be is refused whole, and a notice says why.
        QQmlEngine engine;
        const auto overlay = createChrome(engine, QStringLiteral("NotificationOverlay"), {{QStringLiteral("width"), screen_size.width()}, {QStringLiteral("height"), screen_size.height()}, {QStringLiteral("controller"), QVariant::fromValue(application.notifications())}, {QStringLiteral("colors"), application.colors()}});

        overlay->setParentItem(window.contentItem());
        application.terminals()->paste(pane, QStringLiteral("echo ") + QString(70 * 1024, QLatin1Char('x')));
        QTRY_VERIFY_WITH_TIMEOUT(!application.notifications()->center().items().empty(), wait_ms);
        QVERIFY(text().empty());
        picture(QStringLiteral("07-prompt-paste-too-large-notice"));
        overlay->setParentItem(nullptr);

        // Keys that reach the shell's own line, past the editor, ahead of a command come back to
        // the editor after it.
        application.terminals()->input(pane, QByteArrayLiteral("git sta"), telar::gui::application::PaneInputSource::terminal_report);
        QTest::qWait(settle_ms);
        runCommand(application, terminal, pane, "echo ran");
        QTRY_COMPARE_WITH_TIMEOUT(text(), std::string{"git sta"}, runtime_wait_ms);
        picture(QStringLiteral("08-prompt-typeahead-back-in-the-line"));
        clear();
      });
    }

    // With the output kept, a word a command printed and never typed is found with `in:output` in
    // the line's history search: its row shows the excerpt of the output, lit where the runtime
    // matched.
    Q_SLOT static void historyFindsWhatACommandPrinted() {
      withRealShell(
          telar_config,
          [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem& line, std::uint64_t pane, const QTemporaryDir&) {
            // The command holds the word in two halves; only its output holds it whole.
            runCommand(application, terminal, pane, "printf 'built W9OUT_%s in 3s\\n' NEEDLE");
            QKeyEvent search{QEvent::KeyPress, Qt::Key_R, NativeKeyAdapter::control_modifier};

            QCoreApplication::sendEvent(&terminal, &search);
            QTRY_COMPARE_WITH_TIMEOUT(application.dialogs()->lineSearch(), telar::gui::qt::ApplicationController::Dialog::history, wait_ms);
            application.history()->search(QStringLiteral("in:output W9OUT_NEEDLE"));
            QTRY_VERIFY_WITH_TIMEOUT(!application.history()->loading() && application.history()->rows()->rowCount() == 1, runtime_wait_ms);
            const auto record = application.history()->rows()->data(application.history()->rows()->index(0, 0), ListModel::record_role).toMap();
            const auto excerpt = record.value(QStringLiteral("excerpt")).toString();
            const auto ranges = record.value(QStringLiteral("excerptRanges")).toList();

            QVERIFY2(record.value(QStringLiteral("command")).toString().contains(QStringLiteral("W9OUT_%s")), qPrintable(record.value(QStringLiteral("command")).toString()));
            QVERIFY2(excerpt.contains(QStringLiteral("built W9OUT_NEEDLE in 3s")), qPrintable(excerpt));
            QVERIFY(ranges.size() >= 2);
            const auto bytes = excerpt.toUtf8();
            const auto lit = bytes.mid(ranges[0].toInt(), ranges[1].toInt() - ranges[0].toInt());

            QCOMPARE(QString::fromUtf8(lit).toLower(), QStringLiteral("w9out_needle"));
            // The line shows the excerpt in its row, in place of where and when it ran.
            QTRY_VERIFY_WITH_TIMEOUT(line.property("rowCount").toInt() >= 2, wait_ms);
            QTest::qWait(settle_ms);
            QVERIFY(waitForSynchronizedFrame(window, wait_ms));
            shoot(window, QStringLiteral("output-search-excerpt"));
          },
          "return {api_version=2,runtime={history={output='bounded'}}}"
      );
    }

    // A command prints for a while; a wheel notch up stops following it, and wheel notches back
    // down to the live end follow it again.
    Q_SLOT static void followsOutputAfterTheWheelComesBack() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

        runCommand(application, terminal, pane, "seq 80");
        type(terminal, "for i in {1..600}; do echo tick$i; sleep 0.02; done");
        QCoreApplication::sendEvent(&terminal, &enter);
        QTRY_VERIFY_WITH_TIMEOUT(lastTick(application, pane) >= 40, runtime_wait_ms);
        wheel(window, terminal, 1);
        QTest::qWait(view_settle_ms);
        const auto scrolled = lastTick(application, pane);

        QTest::qWait(view_settle_ms);
        QVERIFY2(lastTick(application, pane) == scrolled && terminal.rowsBelow() > 0, qPrintable(QStringLiteral("scrolled up, the rows stay: ") + viewState(application, terminal, pane)));
        wheel(window, terminal, -3);
        QTest::qWait(view_settle_ms);
        const auto back = lastTick(application, pane);

        QTest::qWait(view_settle_ms);
        QVERIFY2(lastTick(application, pane) > back && terminal.rowsBelow() == 0, qPrintable(QStringLiteral("back at the end the view follows the output again: ") + viewState(application, terminal, pane)));
      });
    }

    // The same with JumpToEnd's click while the command still prints.
    Q_SLOT static void followsOutputAfterJumpingToTheEnd() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

        runCommand(application, terminal, pane, "seq 80");
        type(terminal, "for i in {1..600}; do echo tick$i; sleep 0.02; done");
        QCoreApplication::sendEvent(&terminal, &enter);
        QTRY_VERIFY_WITH_TIMEOUT(lastTick(application, pane) >= 40, runtime_wait_ms);
        wheel(window, terminal, 2);
        QTest::qWait(view_settle_ms);
        terminal.scrollToEnd();
        QTest::qWait(view_settle_ms);
        const auto back = lastTick(application, pane);

        QTest::qWait(view_settle_ms);
        QVERIFY2(lastTick(application, pane) > back && terminal.rowsBelow() == 0, qPrintable(viewState(application, terminal, pane)));
      });
    }

    // With the vim keymap: Escape, [[ selects the last command, yc copies its command and Y its
    // output.
    Q_SLOT static void copiesABlockWithVimKeys() {
      withRealShell(telar_vim_config, [](ApplicationController& application, QQuickWindow&, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        QKeyEvent escape{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier, QStringLiteral("\x1b")};

        runCommand(application, terminal, pane, "printf 'alpha\\nbeta\\ngamma\\n'");
        QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 1, runtime_wait_ms);
        QGuiApplication::clipboard()->setText(QStringLiteral("untouched"));
        QCoreApplication::sendEvent(&terminal, &escape);
        type(terminal, "[[");
        QTRY_VERIFY2_WITH_TIMEOUT(application.prompt()->selectedBlock(pane).hasValue(), "Escape then [[ selects the last command", runtime_wait_ms);
        type(terminal, "yc");
        QTRY_COMPARE_WITH_TIMEOUT(clipboardText(), QStringLiteral("printf 'alpha\\nbeta\\ngamma\\n'"), runtime_wait_ms);
        QKeyEvent output{QEvent::KeyPress, Qt::Key_Y, Qt::ShiftModifier, QStringLiteral("Y")};

        QCoreApplication::sendEvent(&terminal, &output);
        QTRY_COMPARE_WITH_TIMEOUT(clipboardText(), QStringLiteral("alpha\nbeta\ngamma"), runtime_wait_ms);
      });
    }

    // With the default keymap, prefix+[ selects the last command (selectBlock here), then yc and Y.
    Q_SLOT static void copiesABlockFromPrefixBracket() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow&, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        runCommand(application, terminal, pane, "printf 'alpha\\nbeta\\ngamma\\n'");
        QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 1, runtime_wait_ms);
        QGuiApplication::clipboard()->setText(QStringLiteral("untouched"));
        application.terminals()->selectBlock(pane, 0);
        QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->selectedBlock(pane).hasValue(), runtime_wait_ms);
        type(terminal, "yc");
        QTRY_COMPARE_WITH_TIMEOUT(clipboardText(), QStringLiteral("printf 'alpha\\nbeta\\ngamma\\n'"), runtime_wait_ms);
        QKeyEvent output{QEvent::KeyPress, Qt::Key_Y, Qt::ShiftModifier, QStringLiteral("Y")};

        QCoreApplication::sendEvent(&terminal, &output);
        QTRY_COMPARE_WITH_TIMEOUT(clipboardText(), QStringLiteral("alpha\nbeta\ngamma"), runtime_wait_ms);
      });
    }

    // Y on a command whose output ends right before the live prompt copies all of it, its last
    // line too, and nothing of the prompt.
    Q_SLOT static void copiesWholeOutputs() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow&, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        runCommand(application, terminal, pane, "echo one");
        runCommand(application, terminal, pane, "seq 3");
        QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 2, runtime_wait_ms);
        QGuiApplication::clipboard()->setText(QStringLiteral("untouched"));
        application.terminals()->selectBlock(pane, 1);
        QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->selectedBlock(pane).hasValue(), runtime_wait_ms);
        QKeyEvent output{QEvent::KeyPress, Qt::Key_Y, Qt::ShiftModifier, QStringLiteral("Y")};

        QCoreApplication::sendEvent(&terminal, &output);
        QTRY_VERIFY_WITH_TIMEOUT(clipboardText() != QStringLiteral("untouched"), runtime_wait_ms);
        QCOMPARE(clipboardText(), QStringLiteral("1\n2\n3"));
        // The first command's output too, between two separators.
        application.terminals()->selectBlock(pane, 0);
        QGuiApplication::clipboard()->setText(QStringLiteral("untouched"));
        QCoreApplication::sendEvent(&terminal, &output);
        QTRY_VERIFY_WITH_TIMEOUT(clipboardText() != QStringLiteral("untouched"), runtime_wait_ms);
        QCOMPARE(clipboardText(), QStringLiteral("one"));
      });
    }

    // A drag over a row scrolled into view copies the row it is drawn on.
    Q_SLOT static void selectsTheRowsDrawnWhenScrolled() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        runCommand(application, terminal, pane, "seq 1000 1120");
        wheel(window, terminal, 5);
        QTest::qWait(view_settle_ms);
        const auto lines = screenText(application.pane(pane)->screen).split(QLatin1Char('\n'));
        constexpr int row = 3;

        QGuiApplication::clipboard()->setText(QStringLiteral("untouched"));
        dragRow(window, terminal, row, 0, 3);
        pressCopy(terminal);
        QTRY_VERIFY2_WITH_TIMEOUT(clipboardText() != QStringLiteral("untouched"), "a drag copies on release", runtime_wait_ms);
        QCOMPARE(clipboardText(), lines[row].trimmed());
      });
    }

    // A drag while a command still prints, scrolled up, copies the row it is drawn on.
    Q_SLOT static void selectsWhileOutputRuns() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

        runCommand(application, terminal, pane, "seq 80");
        type(terminal, "for i in {1..600}; do echo tick$i; sleep 0.02; done");
        QCoreApplication::sendEvent(&terminal, &enter);
        QTRY_VERIFY_WITH_TIMEOUT(lastTick(application, pane) >= 60, runtime_wait_ms);
        wheel(window, terminal, 4);
        QTest::qWait(view_settle_ms);
        const auto lines = screenText(application.pane(pane)->screen).split(QLatin1Char('\n'));
        constexpr int row = 4;

        QGuiApplication::clipboard()->setText(QStringLiteral("untouched"));
        dragRow(window, terminal, row, 0, 6);
        pressCopy(terminal);
        QTRY_VERIFY2_WITH_TIMEOUT(clipboardText() != QStringLiteral("untouched"), qPrintable(QStringLiteral("a drag copies on release: ") + viewState(application, terminal, pane)), runtime_wait_ms);
        QCOMPARE(clipboardText(), lines[row].trimmed());
        // The view still moves with the wheel after the selection.
        const auto before = application.pane(pane)->screen.scroll().offset;

        wheel(window, terminal, 2);
        QTest::qWait(view_settle_ms);
        QVERIFY2(application.pane(pane)->screen.scroll().offset < before, qPrintable(viewState(application, terminal, pane)));
      });
    }

    // With an earlier command folded, a drag over the first output row of the next command copies
    // that row, not the folded command's.
    Q_SLOT static void selectsUnderAFold() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        runCommand(application, terminal, pane, "seq 1 60");
        runCommand(application, terminal, pane, "seq 1000 1060");
        QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 2, runtime_wait_ms);
        terminal.toggleFold(0);
        QTRY_VERIFY_WITH_TIMEOUT(!application.pane(pane)->folds.empty(), runtime_wait_ms);
        terminal.scrollToFraction(0, false);
        QTest::qWait(view_settle_ms);
        const auto separator = separatorRow(terminal, 1);

        QVERIFY2(separator >= 0, "the second command's separator is in view");
        QGuiApplication::clipboard()->setText(QStringLiteral("untouched"));
        dragRow(window, terminal, separator + 1, 0, 4);
        pressCopy(terminal);
        QTRY_VERIFY_WITH_TIMEOUT(clipboardText() != QStringLiteral("untouched"), runtime_wait_ms);
        QCOMPARE(clipboardText(), QStringLiteral("1000"));
      });
    }

    // A notch up and at once a notch back, or far more notches down than up, while a command
    // prints: the view should be following the output again either way.
    Q_SLOT static void followsOutputAfterAShortWheel() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};
        constexpr int jiggle_ms = 150;

        runCommand(application, terminal, pane, "seq 80");
        type(terminal, "for i in {1..900}; do echo tick$i; sleep 0.02; done");
        QCoreApplication::sendEvent(&terminal, &enter);
        QTRY_VERIFY_WITH_TIMEOUT(lastTick(application, pane) >= 40, runtime_wait_ms);
        wheel(window, terminal, 1);
        QTest::qWait(jiggle_ms);
        wheel(window, terminal, -1);
        QTest::qWait(view_settle_ms);
        const auto jiggled = terminal.rowsBelow();

        terminal.scrollToEnd();
        QTest::qWait(view_settle_ms);
        wheel(window, terminal, 1);
        QTest::qWait(jiggle_ms);
        wheel(window, terminal, -40);
        QTest::qWait(view_settle_ms);
        QTest::qWait(view_settle_ms);
        QVERIFY2(jiggled == 0 && terminal.rowsBelow() == 0, qPrintable(QStringLiteral("rows below after the jiggle %1; ").arg(jiggled) + viewState(application, terminal, pane)));
      });
    }

    // A block selected as a click on its separator selects it, then a command typed in the
    // default keymap reaches the editor whole.
    Q_SLOT static void typesAfterAClickedBlock() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow&, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        runCommand(application, terminal, pane, "echo one");
        terminal.selectBlock(0);
        QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->selectedBlock(pane).hasValue(), runtime_wait_ms);
        type(terminal, "git status");
        const auto text = application.prompt()->line(pane)->text();

        QCOMPARE(QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size())), QStringLiteral("git status"));
      });
    }

    // Y on a command with no output copies nothing of the next command.
    Q_SLOT static void copiesNothingOfAnEmptyOutput() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow&, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        runCommand(application, terminal, pane, "true");
        runCommand(application, terminal, pane, "echo after");
        QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 2, runtime_wait_ms);
        QGuiApplication::clipboard()->setText(QStringLiteral("untouched"));
        application.terminals()->selectBlock(pane, 0);
        QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->selectedBlock(pane).hasValue(), runtime_wait_ms);
        QKeyEvent output{QEvent::KeyPress, Qt::Key_Y, Qt::ShiftModifier, QStringLiteral("Y")};

        QCoreApplication::sendEvent(&terminal, &output);
        QTest::qWait(view_settle_ms);
        QVERIFY2(!clipboardText().contains(QStringLiteral("echo after")), qPrintable(QStringLiteral("copied: ") + clipboardText()));
      });
    }

    // yc copies the whole command that ran, past 160 bytes.
    Q_SLOT static void copiesALongCommandWhole() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow&, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        const std::string command = "echo " + std::string(200, 'a');

        runCommand(application, terminal, pane, command);
        QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 1, runtime_wait_ms);
        application.terminals()->selectBlock(pane, 0);
        QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->selectedBlock(pane).hasValue(), runtime_wait_ms);
        type(terminal, "yc");
        QTRY_VERIFY_WITH_TIMEOUT(clipboardText().startsWith(QStringLiteral("echo")), runtime_wait_ms);
        QCOMPARE(clipboardText().size(), static_cast<qsizetype>(command.size()));
      });
    }

    // Cmd+Up selects the last command from the default keymap, Cmd+C copies its output, the
    // separator's button its command, and typing goes on to the editor.
    Q_SLOT static void copiesWithTheWindowKeys() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow&, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        runCommand(application, terminal, pane, "printf 'alpha\\nbeta\\n'");
        QGuiApplication::clipboard()->setText(QStringLiteral("untouched"));
        pressCopy(terminal, Qt::Key_Up);
        QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->selectedBlock(pane) == ds::Option<std::size_t>{0}, runtime_wait_ms);
        pressCopy(terminal);
        QTRY_COMPARE_WITH_TIMEOUT(clipboardText(), QStringLiteral("alpha\nbeta"), runtime_wait_ms);
        QSignalSpy copied{&terminal, &TerminalItem::blockCopied};

        terminal.copyBlock(0, true);
        QTRY_COMPARE_WITH_TIMEOUT(clipboardText(), QStringLiteral("printf 'alpha\\nbeta\\n'"), runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(!copied.isEmpty(), runtime_wait_ms);
        type(terminal, "git");
        const auto text = application.prompt()->line(pane)->text();

        QCOMPARE(QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size())), QStringLiteral("git"));
        QVERIFY(!application.prompt()->selectedBlock(pane).hasValue());
      });
    }

    // The filter of a block's output: & opens it on the selected block and the bar it shows
    // filters as its query is typed, by text, by regular expression, with context and inverted;
    // Y copies the lines shown and Escape shows them all again.
    Q_SLOT static void filtersABlockOutput() {
      withRealShell(telar_vim_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        QQmlEngine engine;
        const auto bar = createChrome(engine, QStringLiteral("BlockFilter"), {{QStringLiteral("view"), QVariant::fromValue(static_cast<QObject*>(&terminal))}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("typography"), application.display()->geometry().value(QStringLiteral("typography"))}});
        QKeyEvent escape{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier, QStringLiteral("\x1b")};
        const auto hides = [&](int line) {
          const auto& block = application.pane(pane)->blocks[0];

          return application.pane(pane)->folds.hides(static_cast<std::uint64_t>(block.row) + block.rows + line);
        };

        bar->setParentItem(&terminal);
        bar->setPosition({200, 4});
        bar->setWidth(500);
        runCommand(application, terminal, pane, "printf 'ok 1\\nfail 2\\nok 3\\nFAIL 4\\nok 5\\n'");
        QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 1, runtime_wait_ms);
        QCoreApplication::sendEvent(&terminal, &escape);
        type(terminal, "[[&");
        QTRY_VERIFY2_WITH_TIMEOUT(terminal.blockFilter().value(QStringLiteral("open")).toBool(), "& opens the filter on the selected block", runtime_wait_ms);
        QTRY_VERIFY2_WITH_TIMEOUT(bar->isVisible(), "the bar shows while the filter is open", runtime_wait_ms);

        auto* field = bar->findChild<QObject*>(QStringLiteral("blockFilterField"));

        QVERIFY(field != nullptr);
        const auto filter = [&](const QString& text, bool regex, bool match_case, bool invert, int context) {
          bar->setProperty("regex", regex);
          bar->setProperty("matchCase", match_case);
          bar->setProperty("invert", invert);
          bar->setProperty("context", context);
          field->setProperty("text", text);
          QMetaObject::invokeMethod(bar.get(), "apply");
        };

        filter(QStringLiteral("fail"), false, false, false, 0);
        QTRY_VERIFY2_WITH_TIMEOUT(hides(0) && !hides(1) && hides(2) && !hides(3) && hides(4), "only the lines with the text show, in either case", runtime_wait_ms);
        QTRY_COMPARE_WITH_TIMEOUT(terminal.blockFilter().value(QStringLiteral("matches")).toInt(), 2, runtime_wait_ms);
        QTest::qWait(settle_ms);
        shoot(window, QStringLiteral("01-filter-literal"));

        filter(QStringLiteral("^ok [13]$"), true, false, false, 0);
        QTRY_VERIFY2_WITH_TIMEOUT(!hides(0) && hides(1) && !hides(2) && hides(3) && hides(4), "a regular expression", runtime_wait_ms);
        QTest::qWait(settle_ms);
        shoot(window, QStringLiteral("02-filter-regex"));

        filter(QStringLiteral("FAIL"), false, true, false, 1);
        QTRY_VERIFY2_WITH_TIMEOUT(hides(0) && hides(1) && !hides(2) && !hides(3) && !hides(4), "its case matched, with a line of context", runtime_wait_ms);
        QTest::qWait(settle_ms);
        shoot(window, QStringLiteral("03-filter-context"));

        filter(QStringLiteral("ok"), false, false, true, 0);
        QTRY_VERIFY2_WITH_TIMEOUT(hides(0) && !hides(1) && hides(2) && !hides(3) && hides(4), "inverted, the lines without it", runtime_wait_ms);
        QTest::qWait(settle_ms);
        shoot(window, QStringLiteral("04-filter-inverted"));

        QGuiApplication::clipboard()->setText(QStringLiteral("untouched"));
        terminal.forceActiveFocus();
        QKeyEvent output{QEvent::KeyPress, Qt::Key_Y, Qt::ShiftModifier, QStringLiteral("Y")};

        QCoreApplication::sendEvent(&terminal, &output);
        QTRY_COMPARE_WITH_TIMEOUT(clipboardText(), QStringLiteral("fail 2\nFAIL 4"), runtime_wait_ms);
        terminal.closeBlockFilter();
        QTRY_VERIFY2_WITH_TIMEOUT(!hides(0) && !hides(2) && !hides(4) && !bar->isVisible(), "closing shows every line", runtime_wait_ms);
      });
    }

    // m marks blocks, which the rail and their separators show, ' goes back to one, and its
    // command goes back to the editor with sudo, or runs again from its separator's "rerun".
    Q_SLOT static void marksAndReusesBlocks() {
      withRealShell(telar_vim_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        QKeyEvent escape{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier, QStringLiteral("\x1b")};

        // Longer than a view, for the rail to show.
        runCommand(application, terminal, pane, "echo one; seq 1 12");
        runCommand(application, terminal, pane, "echo two; seq 1 12");
        QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 2, runtime_wait_ms);
        QCoreApplication::sendEvent(&terminal, &escape);
        type(terminal, "[[ma[[mb");
        QTRY_VERIFY_WITH_TIMEOUT(TerminalItem::markLetters(*application.pane(pane), 1) == QStringLiteral("a") && TerminalItem::markLetters(*application.pane(pane), 0) == QStringLiteral("b"), runtime_wait_ms);
        type(terminal, "G'a");
        QTRY_VERIFY2_WITH_TIMEOUT(application.prompt()->selectedBlock(pane) == ds::Option<std::size_t>{1}, "'a selects the block a marks, from the live end", runtime_wait_ms);
        QTest::qWait(settle_ms);
        shoot(window, QStringLiteral("05-marks-and-reuse-buttons"));

        QKeyEvent root{QEvent::KeyPress, Qt::Key_E, Qt::ShiftModifier, QStringLiteral("E")};

        QCoreApplication::sendEvent(&terminal, &root);
        QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->line(pane).hasValue(), runtime_wait_ms);
        const auto text = application.prompt()->line(pane)->text();

        QCOMPARE(QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size())), QStringLiteral("sudo echo two; seq 1 12"));
        QTest::qWait(settle_ms);
        shoot(window, QStringLiteral("06-reuse-with-sudo-in-the-editor"));

        terminal.reuseBlock(0, QStringLiteral("run"));
        QTRY_VERIFY2_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 3 && application.pane(pane)->blocks[2].command == "echo one; seq 1 12", "rerun runs the block's command", runtime_wait_ms);
      });
    }

    // Each separator says where its command ran: the directory and the branch, and pinned over
    // its output when it started; the rail says it all under the pointer. Output no command
    // printed, as a background job's, is marked down its rows instead of standing a separator.
    Q_SLOT static void blocksSayWhereTheyRan() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir& directory) {
        const auto repository = directory.filePath(QStringLiteral("blocks-repo")).toStdString();

        runCommand(application, terminal, pane, "git init -q " + repository + " && cd " + repository + " && git symbolic-ref HEAD refs/heads/feature/blocks");
        QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->git_branch == "feature/blocks", runtime_wait_ms);
        runCommand(application, terminal, pane, "seq 1 30");
        const auto separator = [&]() -> QVariantMap {
          for (const auto& record : terminal.separators()) {
            if (record.toMap().value(QStringLiteral("command")).toString() == QStringLiteral("seq 1 30")) {
              return record.toMap();
            }
          }

          return {};
        };

        // The pointer away from the separators, which show their actions under it.
        QTest::mouseMove(&window, {screen_size.width() / 2, screen_size.height() / 2});
        QTRY_VERIFY2_WITH_TIMEOUT(terminal.stickyBlock().value(QStringLiteral("command")).toString() == QStringLiteral("seq 1 30"), "the command whose output fills the view is pinned", runtime_wait_ms);
        const auto pinned = terminal.stickyBlock();

        QVERIFY2(pinned.value(QStringLiteral("place")).toString().endsWith(QStringLiteral("blocks-repo  ⎇ feature/blocks")), qPrintable(pinned.value(QStringLiteral("place")).toString()));
        QVERIFY2(QRegularExpression{QStringLiteral("^\\d\\d:\\d\\d:\\d\\d$")}.match(pinned.value(QStringLiteral("started")).toString()).hasMatch(), "the pinned separator says when it started");
        QVERIFY(pinned.value(QStringLiteral("tip")).toString().startsWith(QStringLiteral("seq 1 30\n")));
        QTest::qWait(settle_ms);
        shoot(window, QStringLiteral("08-sticky-header-with-place-and-start"));

        // Back up to the separator itself, drawn with its place.
        wheel(window, terminal, 10);
        QTRY_VERIFY_WITH_TIMEOUT(separator().value(QStringLiteral("place")).toString().contains(QStringLiteral("⎇ feature/blocks")), runtime_wait_ms);
        QTest::qWait(settle_ms);
        shoot(window, QStringLiteral("09-separator-with-place"));
        terminal.scrollToEnd();

        runCommand(application, terminal, pane, "(sleep 0.3; echo late from the background) &");
        QTRY_VERIFY2_WITH_TIMEOUT(std::ranges::any_of(application.pane(pane)->blocks, [](const CommandBlock& block) {
          return block.state == CommandBlockState::background;
        }),
            "output no command printed is a block of its own",
            runtime_wait_ms);
        QTRY_VERIFY2_WITH_TIMEOUT(!terminal.backgroundRows().isEmpty(), "its rows are marked", runtime_wait_ms);
        QTest::qWait(settle_ms);
        shoot(window, QStringLiteral("10-background-output"));

        // The rail says it all under the pointer.
        wheel(window, terminal, 10);
        QTest::mouseMove(&window, {704, 120});
        QTest::qWait(settle_ms);
        shoot(window, QStringLiteral("12-rail-tooltip"));
      });
    }

    // The commands an earlier runtime kept have no rows: a chip counts them, and opens their
    // list, from which a command goes back to the editor.
    Q_SLOT static void showsRestoredCommands() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController application{memory};
      const QTemporaryDir directory;

      QVERIFY(directory.isValid());
      const auto config = directory.filePath(QStringLiteral("config.lua"));
      QFile file{config};

      QVERIFY(file.open(QIODevice::WriteOnly));
      file.write("return {api_version=2,client={prompt={mode='telar'}}}");
      file.close();
      application.loadConfiguration(config, {}, {});
      QLocalServer listener;

      QVERIFY(listener.listen(directory.filePath(QStringLiteral("runtime.sock"))));
      QQuickWindow window;

      window.resize(screen_size);
      application.setWindow(window);
      application.machines()->open(listener.fullServerName());
      QVERIFY(waitForGuiCondition([&] {
        return listener.hasPendingConnections();
      },
          wait_ms));
      std::unique_ptr<QLocalSocket> socket{listener.nextPendingConnection()};
      WireRuntime runtime{*socket};

      QVERIFY(waitForGuiCondition([&] {
        return application.status()->connected();
      },
          wait_ms));
      runtime.send(ClientLayoutSnapshot{});
      QVERIFY(finishOpening(runtime));
      sendPromptScreen(runtime, 1);
      runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true});
      TerminalItem terminal{window.contentItem()};

      terminal.setController(application.terminals());
      terminal.setPaneId(QString::number(pane_id));
      terminal.setSize(QSizeF{screen_size});
      QQmlEngine engine;
      const auto grid = application.display()->geometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid"));
      const auto separators = createChrome(engine, QStringLiteral("CommandSeparators"), {{QStringLiteral("view"), QVariant::fromValue(static_cast<QObject*>(&terminal))}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("grid"), grid}});
      const auto restored = createChrome(engine, QStringLiteral("RestoredBlocks"), {{QStringLiteral("view"), QVariant::fromValue(static_cast<QObject*>(&terminal))}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("typography"), application.display()->geometry().value(QStringLiteral("typography"))}});

      separators->setParentItem(&terminal);
      restored->setParentItem(&terminal);
      restored->setPosition({140, 4});
      window.show();
      QVERIFY(QTest::qWaitForWindowExposed(&window, wait_ms));

      const ds::Array blocks{
          CommandBlock{.state = CommandBlockState::succeeded, .duration_ms = 1200, .command = "cargo build --release", .started_ms = 1'700'000'000'000, .directory = "/home/ada/src/telar", .host = "laptop", .user = "ada", .branch = "main", .restored = true},
          CommandBlock{.state = CommandBlockState::failed, .status = 2, .duration_ms = 31'000, .command = "make test", .started_ms = 1'700'000'060'000, .directory = "/home/ada/src/telar", .host = "laptop", .user = "ada", .branch = "main", .restored = true},
          CommandBlock{.state = CommandBlockState::succeeded, .command = "[REDACTED]", .restored = true},
          CommandBlock{.row = 0, .rows = 1, .state = CommandBlockState::succeeded, .command = "make", .directory = "/home/ada/src/telar", .user = "ada", .branch = "main"},
      };

      runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = blocks});
      QTRY_COMPARE_WITH_TIMEOUT(terminal.restoredBlocks().size(), 3, wait_ms);
      QCOMPARE(terminal.rail().size(), 1);
      QTRY_VERIFY(restored->isVisible());
      restored->setProperty("expanded", true);
      QTest::qWait(settle_ms);
      shoot(window, QStringLiteral("11-restored-commands"));

      terminal.reuseRestored(1, QStringLiteral("edit"));
      QTRY_VERIFY_WITH_TIMEOUT(application.prompt()->line(pane_id).hasValue(), wait_ms);
      const auto text = application.prompt()->line(pane_id)->text();

      QCOMPARE(QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size())), QStringLiteral("make test"));
    }

    // zsh's spelling correction asks before the command starts: the answer reaches zsh.
    Q_SLOT static void answersZshCorrection() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow&, TerminalItem& terminal, QQuickItem&, std::uint64_t pane, const QTemporaryDir&) {
        QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};

        runCommand(application, terminal, pane, "setopt correct");
        const auto ran = application.pane(pane)->shell.commands;

        type(terminal, "gti --version");
        QCoreApplication::sendEvent(&terminal, &enter);
        QTRY_VERIFY_WITH_TIMEOUT(screenText(application.pane(pane)->screen).contains(QStringLiteral("correct")), runtime_wait_ms);
        QTest::qWait(view_settle_ms);
        type(terminal, "y");
        QTRY_VERIFY2_WITH_TIMEOUT(application.pane(pane)->shell.commands > ran && screenText(application.pane(pane)->screen).contains(QStringLiteral("git version")), qPrintable(screenText(application.pane(pane)->screen)), runtime_wait_ms);
      });
    }

    // A click in the editor places the cursor; on macOS, Command+A selects the command,
    // Command+X cuts it and Command+Z brings it back.
    Q_SLOT static void editsWithThePointerAndCommandKeys() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem& line, std::uint64_t pane, const QTemporaryDir&) {
        auto* editor = line.findChild<PromptEditorItem*>();

        QVERIFY(editor != nullptr);
        type(terminal, "git status");
        QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->line(pane)->cursor(), std::size_t{10}, runtime_wait_ms);
        const auto cell = editor->cellWidth();

        QTRY_VERIFY_WITH_TIMEOUT(editor->isVisible(), runtime_wait_ms);
        QTest::qWait(view_settle_ms);
        // The editor lays its text out after a two-column indent: the fifth character is in its
        // seventh column.
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, editor->mapToScene(QPointF{cell * 6.5, editor->cellHeight() / 2}).toPoint());
        QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->line(pane)->cursor(), std::size_t{4}, runtime_wait_ms);
#ifdef __APPLE__
        const auto command = [&](Qt::Key key, Qt::KeyboardModifiers more = Qt::NoModifier) {
          QKeyEvent press{QEvent::KeyPress, key, Qt::ControlModifier | more, QString {}};

          QCoreApplication::sendEvent(&terminal, &press);
        };

        command(Qt::Key_A);
        command(Qt::Key_X);
        QCOMPARE(clipboardText(), QStringLiteral("git status"));
        QVERIFY(application.prompt()->line(pane)->text().empty());
        command(Qt::Key_Z);
        QCOMPARE(QString::fromUtf8(application.prompt()->line(pane)->text().data(), static_cast<qsizetype>(application.prompt()->line(pane)->text().size())), QStringLiteral("git status"));
        command(Qt::Key_Left);
        QCOMPARE(application.prompt()->line(pane)->cursor(), std::size_t{0});
#endif
      });
    }

    // Wide text an input method wrote: a click lands on the character under the cell, whatever
    // its width, and the input method reads the line around the caret to reconvert it.
    Q_SLOT static void clicksAndReconvertsWideText() {
      withRealShell(telar_config, [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem& line, std::uint64_t pane, const QTemporaryDir&) {
        auto* editor = line.findChild<PromptEditorItem*>();

        QVERIFY(editor != nullptr);
        type(terminal, "echo ");
        QInputMethodEvent committed;

        committed.setCommitString(QStringLiteral("日本語"));
        QCoreApplication::sendEvent(&terminal, &committed);
        // "echo " and three characters of three bytes each.
        QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->line(pane)->cursor(), std::size_t{14}, runtime_wait_ms);
        QTRY_VERIFY_WITH_TIMEOUT(editor->isVisible(), runtime_wait_ms);
        QTest::qWait(view_settle_ms);

        // After the two-column indent and "echo ", 日 takes columns 7 and 8 and 本 9 and 10: a
        // click on 本's second cell puts the caret before it.
        const auto cell = editor->cellWidth();

        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, editor->mapToScene(QPointF{cell * 10.5, editor->cellHeight() / 2}).toPoint());
        QTRY_COMPARE_WITH_TIMEOUT(application.prompt()->line(pane)->cursor(), std::size_t{8}, runtime_wait_ms);

        QInputMethodQueryEvent query{Qt::ImSurroundingText | Qt::ImCursorPosition | Qt::ImAnchorPosition | Qt::ImCurrentSelection};

        QCoreApplication::sendEvent(&terminal, &query);
        QCOMPARE(query.value(Qt::ImSurroundingText).toString(), QStringLiteral("echo 日本語"));
        QCOMPARE(query.value(Qt::ImCursorPosition).toInt(), 6);
        QCOMPARE(query.value(Qt::ImAnchorPosition).toInt(), 6);
        QVERIFY(query.value(Qt::ImCurrentSelection).toString().isEmpty());

        // Reconverting the character before the caret replaces it, as the input method asks.
        QInputMethodEvent reconverted;

        reconverted.setCommitString(QStringLiteral("に"), -1, 1);
        QCoreApplication::sendEvent(&terminal, &reconverted);
        QTRY_COMPARE_WITH_TIMEOUT(QString::fromUtf8(application.prompt()->line(pane)->text().data(), static_cast<qsizetype>(application.prompt()->line(pane)->text().size())), QStringLiteral("echo に本語"), runtime_wait_ms);
      });
    }

    // The whole chain with nothing faked: the runtime integrates a real zsh, the line takes the
    // keys, and the shell runs the command it receives. Needs TELAR_GUI_TEST_RUNTIME.
    Q_SLOT static void lineRunsInARealShell() {
      withRealShell("return {api_version=2,client={prompt={mode='telar'}}}", [](ApplicationController& application, QQuickWindow& window, TerminalItem& terminal, QQuickItem& line_item, std::uint64_t pane, const QTemporaryDir& directory) {
        auto* line = &line_item;

        runsAndSuggests(application, terminal, *line, pane, directory.filePath(QStringLiteral("ran-by-line")));
        QVERIFY(!QTest::currentTestFailed());
        cardReadsTheLastCommand(application, directory.filePath(QStringLiteral("ran-by-line")));
        QVERIFY(!QTest::currentTestFailed());
        marksFailuresAndPresence(application, window, terminal, *line, pane);
        QVERIFY(!QTest::currentTestFailed());
        returnsFromFullScreen(application, terminal, pane);
        QVERIFY(!QTest::currentTestFailed());
        exercisesScrollback(application, window, terminal, *line, pane);
        QVERIFY(!QTest::currentTestFailed());
        completesFromSpecs(application, terminal, pane);
        QVERIFY(!QTest::currentTestFailed());
        recordsLaunchFrames(window, terminal);
      });
    }
  };

}

QTEST_MAIN(PromptWindowTest)
#include "prompt_window_test.moc"
