#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../application/dependencies.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>
#include <array>
#include <optional>
#include <utility>
#include <span>
#include <stdexcept>
#include <tuple>
#include "telar_base/memory/allocator.hpp"
#include <exception>
#include <charconv>
#include <limits.h>
#include "frame_fixture.hpp"
#include "gui_wait.hpp"
#include <concepts>
#include <cstring>
#include <system_error>
#include "qml_fixture.hpp"
#include "../qt/application.hpp"
#include <QByteArray>
#include <QColor>
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include "../qt/key_adapter.hpp"
#endif
#if (defined(__APPLE__))
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
#include "../qt/external_link_opener.hpp"
#include "../qt/list_model.hpp"
#include "../qt/machine_chrome_layout.hpp"
#include "../qt/machine_client.hpp"
#include "../qt/machine_client_key.hpp"
#include "../qt/terminal_item.hpp"
#include "../qt/prompt_island.hpp"
#include "telar_client/codecs/telar_cells.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <chrono>
#include "../qt/bundled_fonts.hpp"
#include "wire_runtime.hpp"
#include <QAbstractItemModel>
#include <QCoreApplication>
#include <QEvent>
#include <QFile>
#include <QProcess>
#include <QDir>
#include <QProcessEnvironment>
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
#include <QStandardPaths>
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
#include <memory>

#include "application/dependencies.hpp"
#include "qt/application.hpp"
#ifdef __APPLE__
#include "qt/key_adapter.hpp"
#include <QBuffer>
#include <QRectF>
#include <QImage>
#include <QDebug>
#include <QtCore/qlogging.h>
#include <QSGRendererInterface>
#include <QFont>
#include <QScopeGuard>
#include <QtGui/qtestsupport_gui.h>
#endif
#include "qt/external_link_opener.hpp"
#include "qt/list_model.hpp"
#include "qt/machine_chrome_layout.hpp"
#include "qt/machine_client.hpp"
#include "qt/machine_client_key.hpp"
#include "qt/terminal_item.hpp"
#include "qt/bundled_fonts.hpp"

import telar.gui.transport.runtime_link;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr std::uint64_t pane_id = 1;
constexpr TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
constexpr std::uint16_t columns = 60;
constexpr std::uint16_t rows = 6;

bool finishOpening(WireRuntime &runtime) {
  if (!waitForGuiCondition([&] { return runtime.count(ClientTag::open_pane) != 0; }, wait_ms)) {
    return false;
  }
  const auto opening = runtime.last<OpenPane>();
  runtime.send(PaneOpened{.request_id = opening.request_id, .pane_id = pane_id, .location = location, .created = true, .pane_generation = 1});
  if (!waitForGuiCondition([&] { return runtime.count(ClientTag::request_tab_snapshot) != 0 && runtime.count(ClientTag::request_workspace_snapshot) != 0; }, wait_ms)) {
    return false;
  }
  const std::array descriptors{PaneDescriptor{.pane_id = pane_id, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  runtime.send(TabSnapshot{.request_id = runtime.last<RequestTabSnapshot>().request_id, .location = location, .panes = descriptors});
  const std::array tabs{TabDescriptor{.tab_id = location.tab_id, .pane_count = 1}};
  runtime.send(WorkspaceSnapshot{.request_id = runtime.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});
  return true;
}

// A screen with some output and the shell's prompt on the last row, flagged as the runtime
// flags a row its integrated shell marked.
void sendPromptScreen(WireRuntime &runtime, std::uint64_t frame_id) {
  constexpr std::array<std::string_view, rows> lines{"$ make", "[1/2] Building runtime", "[2/2] Linking telar", "", "", "adrian@host ~/src/telar % "};
  std::vector<Cell> cells;
  for (const auto line : lines) {
    for (std::size_t column = 0; column < columns; ++column) {
      cells.push_back(Cell{.text = byteView(column < line.size() ? line.substr(column, 1) : std::string_view{" "})});
    }
  }
  std::vector<Byte> encoded(cells.size() * 16);
  const std::array spans{FrameSpan{.start = 0, .count = static_cast<std::uint32_t>(cells.size()), .cells = CellRunCodec::encode(cells, encoded)}};
  std::array<Byte, rows> flags{};
  flags[rows - 1] = static_cast<Byte>(RowFlag::prompt);
  FrameBody frame{.pane_id = pane_id, .frame_id = frame_id, .cols = columns, .rows = rows, .cursor = {.visible = true, .x = static_cast<std::uint16_t>(lines.back().size()), .y = rows - 1}, .scroll = {.total_rows = rows}, .text_metadata = TextMetadata{.row_flags = flags}, .spans = spans};
  frame.input_modes.bracketed_paste = true;
  runtime.send(PaneFrame{frame});
}

void type(TerminalItem &terminal, std::string_view text) {
  for (const auto character : text) {
    const auto key = character >= 'a' && character <= 'z' ? Qt::Key_A + (character - 'a') : static_cast<int>(character);
    QKeyEvent press{QEvent::KeyPress, key, Qt::NoModifier, QString{QChar{character}}};
    QCoreApplication::sendEvent(&terminal, &press);
  }
}

class PromptWindowTest : public QObject {
  Q_OBJECT

  // The island takes the keys of a shell at its prompt, sends the finished command as one
  // paste and Enter, and stands in for the shell's prompt row.
  Q_SLOT static void islandEditsAndRunsCommands() {
    ApplicationAllocator memory;
    Application application{memory};
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto config = directory.filePath(QStringLiteral("config.lua"));
    QFile file{config};
    QVERIFY(file.open(QIODevice::WriteOnly));
    const auto skin = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_SKIN", QStringLiteral("halo"));
    file.write(QStringLiteral("return {api_version=2,client={prompt={mode='telar',skin='%1'}}}").arg(skin).toUtf8());
    file.close();
    application.loadConfiguration(config, {}, {});
    QVERIFY2(application.error().isEmpty(), qPrintable(application.error()));

    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("runtime.sock"))));
    QQuickWindow window;
    window.resize(QSize{720, 300});
    application.setWindow(window);
    application.open(listener.fullServerName());
    QVERIFY(waitForGuiCondition([&] { return listener.hasPendingConnections(); }, wait_ms));
    std::unique_ptr<QLocalSocket> socket{listener.nextPendingConnection()};
    WireRuntime runtime{*socket};
    QVERIFY(waitForGuiCondition([&] { return application.connected(); }, wait_ms));
    runtime.send(ClientLayoutSnapshot{});
    QVERIFY(finishOpening(runtime));
    sendPromptScreen(runtime, 1);
    runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true});
    QTRY_COMPARE_WITH_TIMEOUT(application.promptSurface(pane_id), prompt::Surface::editor, wait_ms);

    TerminalItem terminal{window.contentItem()};
    terminal.setApplication(&application);
    terminal.setPaneId(QString::number(pane_id));
    terminal.setSize(QSizeF{720, 300});
    QQmlEngine engine;
    const QVariantMap properties{
        {QStringLiteral("application"), QVariant::fromValue(&application)},
        {QStringLiteral("paneId"), QString::number(pane_id)},
        {QStringLiteral("colors"), application.colors()},
        {QStringLiteral("grid"), application.windowGeometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid"))},
        {QStringLiteral("terminal"), QVariant::fromValue(static_cast<QObject *>(&terminal))},
    };
    const auto island = createChrome(engine, QStringLiteral("PromptIsland"), properties);
    QVERIFY(island);
    island->setParentItem(&terminal);
    window.show();
    QVERIFY(QTest::qWaitForWindowExposed(&window, wait_ms));
    terminal.forceActiveFocus();
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));

    // A paste shows in the island at once, without a key after it.
    const auto *editor = island->findChild<PromptIsland *>();
    QVERIFY(editor != nullptr && editor->empty());
    application.paste(pane_id, QStringLiteral("echo pasted"));
    QVERIFY2(!editor->empty(), "the paste shows without another key");
    QKeyEvent wipe{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};
    QCoreApplication::sendEvent(&terminal, &wipe);
    QVERIFY(editor->empty());

    const auto before = runtime.count(ClientTag::pane_input);
    type(terminal, "git log --oneline -n 3 | grep fix");
    QCOMPARE(runtime.count(ClientTag::pane_input), before);
    QTRY_VERIFY_WITH_TIMEOUT(island->isVisible(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(terminal.promptRow() >= 0, wait_ms);
    // Without focus the island steps aside, and the shell's own prompt stays hidden.
    island->setProperty("focused", false);
    QVERIFY(!island->isVisible());
    QVERIFY(terminal.promptRow() >= 0);
    island->setProperty("focused", true);
    QVERIFY(island->isVisible());
    QTest::qWait(900);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    const auto screenshot = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_SCREENSHOT");
    if (!screenshot.isEmpty()) {
      QVERIFY(window.grabWindow().save(screenshot, "PNG"));
    }

    QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};
    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(runtime.count(ClientTag::pane_input) > before, wait_ms);
    // The command left at once; its output waits for the flight to its separator to land.
    QVERIFY(island->property("flying").toBool() && terminal.outputHeld());
    QTRY_VERIFY_WITH_TIMEOUT(!island->property("flying").toBool() && !terminal.outputHeld(), 1000);
    const auto sent = runtime.inputText();
    QVERIFY2(sent.ends_with("\x1b[200~git log --oneline -n 3 | grep fix\x1b[201~\r"), sent.c_str());

    runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::running, .canonical = true, .echo = true, .signal_keys = true, .interrupt = 3});
    QTRY_COMPARE_WITH_TIMEOUT(application.promptSurface(pane_id), prompt::Surface::running, wait_ms);
    type(terminal, "make test");
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    const auto running = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_RUNNING_SCREENSHOT");
    if (!running.isEmpty()) {
      // Past the spring that reshapes the island, so the picture shows where it settles.
      QTest::qWait(1200);
      QVERIFY(window.grabWindow().save(running, "PNG"));
    }

    // Tab opens the spec's choices above the command.
    runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true, .commands = 1, .status = 2});
    QTRY_COMPARE_WITH_TIMEOUT(application.promptSurface(pane_id), prompt::Surface::editor, wait_ms);
    // A command that failed shakes the island.
    QTRY_COMPARE_WITH_TIMEOUT(island->property("outcome").toString(), QStringLiteral("failure"), wait_ms);
    QKeyEvent clear{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};
    QCoreApplication::sendEvent(&terminal, &clear);
    // The command's block arrives: its outcome stands in for the empty editor for a moment,
    // its prompt row turns into a separator and the rail beside the pane gets its dot.
    const std::array blocks{CommandBlock{.row = 0, .rows = 1, .lines = 0, .state = CommandBlockState::failed, .status = 2, .duration_ms = 1500, .command = "git log --oneline -n 3 | grep fix"}};
    runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = blocks});
    QTRY_VERIFY_WITH_TIMEOUT(island->property("concluded").toBool() && island->property("concludedFailed").toBool(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(terminal.separators().size(), 1, wait_ms);
    QCOMPARE(terminal.separators().front().toMap().value(QStringLiteral("command")).toString(), QStringLiteral("git log --oneline -n 3 | grep fix"));
    QCOMPARE(terminal.separators().front().toMap().value(QStringLiteral("state")).toString(), QStringLiteral("failed"));
    QCOMPARE(terminal.rail().size(), 1);

    // The block ran git, so git exists. Any other command word, once typed, is asked of the
    // runtime; one it does not find is missing.
    QCOMPARE(application.commandPresence(pane_id, "git"), CommandPresence::found);
    const auto asked = runtime.count(ClientTag::complete_words);
    type(terminal, "gti s");
    QVERIFY(!island->property("concluded").toBool());
    QTRY_VERIFY_WITH_TIMEOUT(runtime.count(ClientTag::complete_words) > asked, wait_ms);
    const auto presence = runtime.last<CompleteWords>();
    QCOMPARE(presence.prefix, std::string_view{"gti"});
    QCOMPARE(application.commandPresence(pane_id, "gti"), CommandPresence::pending);
    runtime.send(CompletionWords{.request_id = presence.request_id, .truncated = false, .words = {}});
    QTRY_COMPARE_WITH_TIMEOUT(application.commandPresence(pane_id, "gti"), CommandPresence::missing, wait_ms);
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
    QTRY_VERIFY_WITH_TIMEOUT(application.promptIsland(pane_id)->menu().has_value(), wait_ms);
    // The menu's heading says where its choices come from.
    QCOMPARE(application.promptIsland(pane_id)->menu()->label, std::string{"git"});
    // A choice taken sweeps in, glowing in the accent colour as it settles.
    QKeyEvent take{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};
    QCoreApplication::sendEvent(&terminal, &take);
    QVERIFY(!application.promptIsland(pane_id)->menu().has_value());
    QVERIFY(!editor->glows().isEmpty());
    QTRY_VERIFY_WITH_TIMEOUT(editor->glows().isEmpty(), wait_ms);

    // A command that ran without the shell missing it exists, whatever it reported before.
    const std::array ran{blocks[0], CommandBlock{.row = 2, .rows = 1, .lines = 0, .state = CommandBlockState::succeeded, .status = 0, .duration_ms = 20, .command = "gti status"}};
    runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = ran});
    QTRY_COMPARE_WITH_TIMEOUT(application.commandPresence(pane_id, "gti"), CommandPresence::found, wait_ms);
    QTest::qWait(900);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    const auto menu = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_MENU_SCREENSHOT");
    if (!menu.isEmpty()) {
      QVERIFY(window.grabWindow().save(menu, "PNG"));
    }
  }

  // The whole chain with nothing faked: the runtime integrates a real zsh, the island takes the
  // keys, and the shell runs the command it receives. Needs TELAR_GUI_TEST_RUNTIME.
  Q_SLOT static void islandRunsInARealShell() {
    const auto executable = qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME");
    if (executable.isEmpty() || !QFileInfo::exists(QStringLiteral("/bin/zsh"))) {
      QSKIP("Set TELAR_GUI_TEST_RUNTIME to a runtime executable; needs /bin/zsh");
    }
    constexpr int runtime_wait_ms = 20000;
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto home = directory.filePath(QStringLiteral("home"));
    QVERIFY(QDir{}.mkpath(home));
    const auto socket = directory.filePath(QStringLiteral("runtime.sock"));
    QProcess runtime;
    runtime.setProgram(executable);
    runtime.setArguments({QStringLiteral("server"), QStringLiteral("--no-config"), QStringLiteral("--fresh"), QStringLiteral("--socket"), socket});
    auto environment = QProcessEnvironment::systemEnvironment();
    for (const auto &name : environment.keys()) {
      if (name.startsWith(QLatin1StringView("TELAR_")) || name == QLatin1StringView("ZDOTDIR")) {
        environment.remove(name);
      }
    }
    environment.insert(QStringLiteral("HOME"), home);
    environment.insert(QStringLiteral("SHELL"), QStringLiteral("/bin/zsh"));
    environment.insert(QStringLiteral("TELAR_HISTORY"), directory.filePath(QStringLiteral("history.db")));
    environment.insert(QStringLiteral("XDG_DATA_HOME"), directory.filePath(QStringLiteral("data")));
    runtime.setProcessEnvironment(environment);
    runtime.start();
    QVERIFY(runtime.waitForStarted());
    const auto stop = qScopeGuard([&] {
      runtime.terminate();
      runtime.waitForFinished(5000);
    });
    QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(socket), runtime_wait_ms);
    qputenv("SHELL", "/bin/zsh");

    ApplicationAllocator memory;
    Application application{memory};
    const auto config = directory.filePath(QStringLiteral("config.lua"));
    QFile file{config};
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("return {api_version=2,client={prompt={mode='telar'}}}");
    file.close();
    application.loadConfiguration(config, {}, {});
    QQuickWindow window;
    window.resize(QSize{720, 300});
    application.setWindow(window);
    application.open(socket);
    QTRY_COMPARE_WITH_TIMEOUT(application.panes()->rowCount(), 1, runtime_wait_ms);
    const auto record = application.panes()->data(application.panes()->index(0, 0), ListModel::record_role).toMap();
    const auto pane = record.value(QStringLiteral("key")).toString().toULongLong();
    QTRY_COMPARE_WITH_TIMEOUT(application.promptSurface(pane), prompt::Surface::editor, runtime_wait_ms);

    TerminalItem terminal{window.contentItem()};
    terminal.setApplication(&application);
    terminal.setPaneId(QString::number(pane));
    terminal.setSize(QSizeF{720, 300});
    // The pieces a pane stacks over its terminal: the separators, the rail and the island.
    QQmlEngine engine;
    const auto grid = application.windowGeometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid"));
    const auto separators = createChrome(engine, QStringLiteral("CommandSeparators"), {{QStringLiteral("view"), QVariant::fromValue(static_cast<QObject *>(&terminal))}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("grid"), grid}});
    separators->setParentItem(&terminal);
    const auto rail = createChrome(engine, QStringLiteral("CommandRail"), {{QStringLiteral("view"), QVariant::fromValue(static_cast<QObject *>(&terminal))}, {QStringLiteral("colors"), application.colors()}});
    rail->setParentItem(&terminal);
    rail->setPosition({700, 12});
    rail->setHeight(180);
    const auto island = createChrome(engine, QStringLiteral("PromptIsland"), {{QStringLiteral("application"), QVariant::fromValue(&application)}, {QStringLiteral("paneId"), QString::number(pane)}, {QStringLiteral("colors"), application.colors()}, {QStringLiteral("grid"), grid}, {QStringLiteral("terminal"), QVariant::fromValue(static_cast<QObject *>(&terminal))}});
    island->setParentItem(&terminal);
    window.show();
    QVERIFY(QTest::qWaitForWindowExposed(&window, wait_ms));
    terminal.forceActiveFocus();
    const auto marker = directory.filePath(QStringLiteral("ran-by-island"));
    type(terminal, ("touch " + marker).toStdString());
    QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r")};
    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(marker), runtime_wait_ms);
    QTRY_VERIFY2_WITH_TIMEOUT(application.pane(pane)->shell.commands == 1 && application.promptSurface(pane) == prompt::Surface::editor, qPrintable(QStringLiteral("commands=%1 phase=%2 surface=%3 foreground=%4").arg(application.pane(pane)->shell.commands).arg(static_cast<int>(application.pane(pane)->shell.phase)).arg(static_cast<int>(application.promptSurface(pane))).arg(application.pane(pane)->shell.shell_foreground)), 8000);
    QCOMPARE(application.pane(pane)->shell.status, 0);
    // The runtime anchored the command's block where its prompt was, and the terminal draws
    // its separator there.
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 1 && application.pane(pane)->blocks.front().state == CommandBlockState::succeeded, runtime_wait_ms);
    QVERIFY(application.pane(pane)->blocks.front().command.ends_with(("touch " + marker).toStdString()));
    QTRY_COMPARE_WITH_TIMEOUT(terminal.separators().size(), 1, runtime_wait_ms);
    // A command sent before is suggested as its start is typed, for a key to take it.
    {
      type(terminal, "tou");
      const auto *editor = island->findChild<PromptIsland *>();
      QTRY_VERIFY_WITH_TIMEOUT(editor != nullptr && editor->suggesting(), runtime_wait_ms);
      QCOMPARE(editor->mode(), QStringLiteral("emacs"));
      QKeyEvent erase{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};
      QCoreApplication::sendEvent(&terminal, &erase);
      QTRY_VERIFY_WITH_TIMEOUT(!editor->suggesting(), runtime_wait_ms);
    }
    // A command that fails: its block says so, and the island offers the way to its error.
    type(terminal, "ls /nonexistent-telar");
    QCoreApplication::sendEvent(&terminal, &enter);
    QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->blocks.size() == 2 && application.pane(pane)->blocks.back().state == CommandBlockState::failed, runtime_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(island->property("concluded").toBool() && island->property("concludedFailed").toBool(), runtime_wait_ms);
    QCOMPARE(terminal.rail().size(), 2);
    // The runtime finds the commands the shell runs, and only those.
    type(terminal, "gti x && ls ./");
    QTRY_COMPARE_WITH_TIMEOUT(application.commandPresence(pane, "gti"), CommandPresence::missing, runtime_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(application.commandPresence(pane, "ls"), CommandPresence::found, runtime_wait_ms);
    const auto blocks = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_BLOCKS_SCREENSHOT");
    if (!blocks.isEmpty()) {
      QTest::qWait(900);
      QVERIFY(waitForSynchronizedFrame(window, wait_ms));
      QVERIFY(window.grabWindow().save(blocks, "PNG"));
    }
    // A full-screen program comes and goes: the commands before it keep their blocks, and the
    // island takes the keys again once the shell is back at its prompt.
    {
      QKeyEvent erase{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};
      QCoreApplication::sendEvent(&terminal, &erase);
      const auto before_vim = application.pane(pane)->blocks.size();
      type(terminal, "vim -u NONE");
      QCoreApplication::sendEvent(&terminal, &enter);
      QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->screen.modes().alternate_screen, runtime_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(application.promptSurface(pane), prompt::Surface::none, runtime_wait_ms);
      QKeyEvent escape{QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier, QStringLiteral("\x1b")};
      QCoreApplication::sendEvent(&terminal, &escape);
      type(terminal, ":q");
      QCoreApplication::sendEvent(&terminal, &enter);
      QTRY_VERIFY_WITH_TIMEOUT(!application.pane(pane)->screen.modes().alternate_screen && application.promptSurface(pane) == prompt::Surface::editor, runtime_wait_ms);
      QTRY_VERIFY2_WITH_TIMEOUT(application.pane(pane)->blocks.size() == before_vim + 1, qPrintable(QStringLiteral("blocks %1, before %2").arg(application.pane(pane)->blocks.size()).arg(before_vim)), runtime_wait_ms);
      const auto inputs = application.pane(pane)->shell.commands;
      type(terminal, "echo after-vim");
      QVERIFY2(application.promptIsland(pane)->editor().text().view() == "echo after-vim", "the island takes the keys again");
      QCoreApplication::sendEvent(&terminal, &enter);
      QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->shell.commands == inputs + 1 && application.pane(pane)->blocks.size() == before_vim + 2, runtime_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(terminal.promptRow() >= 0, runtime_wait_ms);
    }
    // Scrolled back to the bottom, the view follows the output, and the shell's prompt stays
    // hidden under the island: after more output, and after `clear`.
    {
      const auto at_bottom = [&] {
        const auto &screen = application.pane(pane)->screen;
        return screen.scroll().offset + screen.rows() >= screen.scroll().total_rows;
      };
      const auto run = [&](std::string_view command) {
        const auto ran = application.pane(pane)->shell.commands;
        type(terminal, command);
        QCoreApplication::sendEvent(&terminal, &enter);
        QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->shell.commands == ran + 1 && application.promptSurface(pane) == prompt::Surface::editor, runtime_wait_ms);
      };
      run("seq 60");
      QTRY_VERIFY_WITH_TIMEOUT(at_bottom(), runtime_wait_ms);
      application.scroll(PaneScrollDelta{.pane_id = pane, .rows = 3});
      QTRY_VERIFY_WITH_TIMEOUT(!at_bottom(), runtime_wait_ms);
      application.scroll(PaneScrollDelta{.pane_id = pane, .rows = -3});
      QTRY_VERIFY_WITH_TIMEOUT(at_bottom(), runtime_wait_ms);
      const auto where = [&] { return QStringLiteral("offset %1 of %2 rows, prompt row %3").arg(application.pane(pane)->screen.scroll().offset).arg(application.pane(pane)->screen.scroll().total_rows).arg(terminal.promptRow()); };
      run("seq 30");
      QTRY_VERIFY2_WITH_TIMEOUT(at_bottom() && terminal.promptRow() >= 0, qPrintable(where()), runtime_wait_ms);
      run("clear");
      QTRY_VERIFY2_WITH_TIMEOUT(at_bottom() && terminal.promptRow() >= 0, qPrintable(where()), runtime_wait_ms);
    }

    // The runtime serves the spec of a command the shell runs: Tab completes git's subcommand.
    if (!QStandardPaths::findExecutable(QStringLiteral("git")).isEmpty()) {
      QKeyEvent erase{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};
      QCoreApplication::sendEvent(&terminal, &erase);
      type(terminal, "git sw");
      QKeyEvent complete{QEvent::KeyPress, Qt::Key_Tab, Qt::NoModifier, QStringLiteral("\t")};
      QCoreApplication::sendEvent(&terminal, &complete);
      QTRY_COMPARE_WITH_TIMEOUT(application.promptIsland(pane)->editor().text().view(), std::string_view{"git switch "}, runtime_wait_ms);
      // An alias the shell defines completes as the command it stands for.
      QCoreApplication::sendEvent(&terminal, &erase);
      const auto ran = application.pane(pane)->shell.commands;
      type(terminal, "alias gsw='git switch'");
      QCoreApplication::sendEvent(&terminal, &enter);
      QTRY_VERIFY_WITH_TIMEOUT(application.pane(pane)->shell.commands == ran + 1 && application.promptSurface(pane) == prompt::Surface::editor, runtime_wait_ms);
      type(terminal, "gsw --det");
      QCoreApplication::sendEvent(&terminal, &complete);
      QTRY_COMPARE_WITH_TIMEOUT(application.promptIsland(pane)->editor().text().view(), std::string_view{"gsw --detach "}, runtime_wait_ms);
    }

    // A quick command: it flies to its separator while its output waits, then the output
    // enters line by line. TELAR_GUI_TEST_PROMPT_LAUNCH_FRAMES names where frames go.
    const auto frames = qEnvironmentVariable("TELAR_GUI_TEST_PROMPT_LAUNCH_FRAMES");
    if (!frames.isEmpty()) {
      QKeyEvent erase{QEvent::KeyPress, Qt::Key_U, NativeKeyAdapter::control_modifier};
      QCoreApplication::sendEvent(&terminal, &erase);
      type(terminal, "ls /");
      QCoreApplication::sendEvent(&terminal, &enter);
      for (int frame = 0; frame < 12; ++frame) {
        QVERIFY(window.grabWindow().save(frames + QString::number(frame) + QStringLiteral(".png"), "PNG"));
        QTest::qWait(30);
      }
    }
  }
};

}

QTEST_MAIN(PromptWindowTest)
#include "prompt_window_test.moc"
