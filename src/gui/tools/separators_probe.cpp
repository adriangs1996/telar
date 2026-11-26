#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

// Measures what a pane's command separators cost when output moves every command a row, as
// a shell printing under a screen of finished commands does: the client's block refresh and
// the QML separators it drives, on the GUI thread's CPU clock. The separators' records and the
// final rendered window are the oracle a candidate must reproduce.

#include "../tests/gui_wait.hpp"
#include "../tests/qml_fixture.hpp"
#include "../tests/wire_runtime.hpp"
#include "telar_wire/codecs/telar_cells.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include <QCommandLineParser>
#include <QCryptographicHash>
#include <QFile>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <array>
#include <chrono>
#include <cstdint>
#include <ctime>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

import telar.wire.content;
import telar.wire.layout;
import telar.base.ds;
import telar.gui.foundation.core;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::qt;
  using namespace telar::gui::test;

  constexpr int wait_ms = 10000;
  constexpr std::uint64_t pane_id = 1;
  constexpr TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
  constexpr std::uint16_t columns = 100;
  constexpr std::uint16_t rows = 48;
  constexpr QSize window_size{960, 820};

  std::int64_t threadCpuNanoseconds() {
    constexpr std::int64_t nanoseconds_per_second = 1'000'000'000;
    timespec now{};

    ::clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now);
    return (static_cast<std::int64_t>(now.tv_sec) * nanoseconds_per_second) + now.tv_nsec;
  }

  void require(bool condition, const char* failure) {
    if (!condition) {
      throw std::runtime_error{failure};
    }
  }

  void open(WireRuntime& runtime) {
    require(waitForGuiCondition([&] {
      return runtime.count(ClientTag::open_pane) != 0;
    },
                wait_ms),
        "The client did not open a pane");
    runtime.send(PaneOpened{.request_id = runtime.last<OpenPane>().request_id, .pane_id = pane_id, .location = location, .created = true, .pane_generation = 1});
    require(waitForGuiCondition([&] {
      return runtime.count(ClientTag::request_tab_snapshot) != 0 && runtime.count(ClientTag::request_workspace_snapshot) != 0;
    },
                wait_ms),
        "The client did not ask for its tab");
    const ds::Array descriptors{PaneDescriptor{.pane_id = pane_id, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

    runtime.send(TabSnapshot{.request_id = runtime.last<RequestTabSnapshot>().request_id, .location = location, .panes = descriptors});
    const ds::Array tabs{TabDescriptor{.tab_id = location.tab_id, .pane_count = 1}};

    runtime.send(WorkspaceSnapshot{.request_id = runtime.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});
  }

  void sendScreen(WireRuntime& runtime) {
    // A bound on the encoded size of a blank cell.
    constexpr std::size_t encoded_cell_bytes = 16;
    std::vector<Cell> cells(static_cast<std::size_t>(columns) * rows, Cell{.text = byteView(" ")});
    std::vector<Byte> encoded(cells.size() * encoded_cell_bytes);
    const ds::Array spans{FrameSpan{.start = 0, .count = static_cast<std::uint32_t>(cells.size()), .cells = CellRunCodec::encode(cells, encoded)}};
    const ds::Array<Byte, rows> flags{};

    runtime.send(PaneFrame{FrameBody{.pane_id = pane_id, .frame_id = 1, .cols = columns, .rows = rows, .cursor = {.visible = true, .x = 0, .y = rows - 1}, .scroll = {.total_rows = rows}, .text_metadata = TextMetadata{.row_flags = flags}, .spans = spans}});
  }

  constexpr unsigned default_iterations = 60;
  constexpr unsigned default_warmup = 10;
  constexpr unsigned default_blocks = 20;
  constexpr unsigned maximum_refreshes = 10000;

  struct Options {
    unsigned iterations = default_iterations;
    unsigned warmup = default_warmup;
    unsigned blocks = default_blocks;
    QString output;
  };

  struct Timing {
    std::int64_t cpu = 0;
    std::int64_t wall = 0;
  };

  Options parse(const QGuiApplication& application) {
    QCommandLineParser parser;

    parser.addHelpOption();
    parser.addOption({"iterations", "Measured block refreshes", "count", "60"});
    parser.addOption({"warmup", "Untimed block refreshes", "count", "10"});
    parser.addOption({"blocks", "Finished commands on screen, 1 to 23", "count", "20"});
    parser.addOption({"output", "Final rendered window", "path"});
    parser.process(application);
    Options options{.iterations = parser.value("iterations").toUInt(), .warmup = parser.value("warmup").toUInt(), .blocks = parser.value("blocks").toUInt(), .output = parser.value("output")};

    require(options.iterations != 0 && options.iterations <= maximum_refreshes && options.warmup <= maximum_refreshes, "Expected 1..10000 iterations and up to 10000 warmup refreshes");
    require(options.blocks != 0 && options.blocks <= (rows / 2) - 1, "Expected 1 to 23 blocks");
    return options;
  }

  // Separators belong to Telar's prompt over an integrated shell.
  void configurePrompt(ApplicationController& client, const QTemporaryDir& directory) {
    const auto configuration = directory.filePath(QStringLiteral("config.lua"));
    QFile file{configuration};

    require(file.open(QIODevice::WriteOnly) && file.write("return {api_version=2,client={prompt={mode='telar'}}}") > 0, "Cannot write the configuration");
    file.close();
    client.loadConfiguration(configuration, {}, {});
    require(client.status()->error().isEmpty(), "The configuration did not load");
  }

  // Two screens of the same finished commands, the second a row lower: each refresh moves
  // every separator. The blocks view the names in commands.
  ds::Array<std::vector<CommandBlock>, 2> commandScreens(const std::vector<std::string>& commands) {
    constexpr std::uint32_t base_duration_ms = 100;
    ds::Array<std::vector<CommandBlock>, 2> screens;

    for (unsigned shift = 0; shift < 2; ++shift) {
      for (unsigned index = 0; index < commands.size(); ++index) {
        screens.atMut(shift).push_back(CommandBlock{.row = (index * 2) + shift, .rows = 1, .lines = 0, .state = index % 3 == 0 ? CommandBlockState::failed : CommandBlockState::succeeded, .status = index % 3 == 0 ? 2 : 0, .duration_ms = base_duration_ms + index, .command = commands[index]});
      }
    }

    return screens;
  }

  int firstRow(const TerminalItem& terminal, unsigned blocks) {
    const auto listed = terminal.separators();

    return listed.size() == static_cast<qsizetype>(blocks) ? listed.front().toMap().value(QStringLiteral("row")).toInt() : -1;
  }

  Timing measure(WireRuntime& runtime, const TerminalItem& terminal, const Options& options, const ds::Array<std::vector<CommandBlock>, 2>& screens) {
    Timing timing;

    for (unsigned step = 1; step <= options.warmup + options.iterations; ++step) {
      const auto shift = step % 2;
      const auto started_cpu = threadCpuNanoseconds();
      const auto started_wall = std::chrono::steady_clock::now();

      runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = screens[shift]});
      require(waitForGuiCondition([&] {
        return firstRow(terminal, options.blocks) == static_cast<int>(shift);
      },
                  wait_ms),
          "A refresh did not reach the separators");
      if (step > options.warmup) {
        timing.cpu += threadCpuNanoseconds() - started_cpu;
        timing.wall += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started_wall).count();
      }
    }

    return timing;
  }

  int run(const QGuiApplication& application) {
    const auto options = parse(application);
    const QTemporaryDir directory;

    require(directory.isValid(), "No temporary directory");

    ApplicationMemory application_memory;
    ApplicationAllocator& memory = application_memory.memory();
    ApplicationController client{memory};

    configurePrompt(client, directory);
    QLocalServer listener;

    require(listener.listen(directory.filePath(QStringLiteral("runtime.sock"))), "Cannot listen");
    QQuickWindow window;

    window.resize(window_size);
    client.setWindow(window);
    client.machines()->open(listener.fullServerName());
    require(waitForGuiCondition([&] {
      return listener.hasPendingConnections();
    },
                wait_ms),
        "The client did not connect");
    std::unique_ptr<QLocalSocket> socket{listener.nextPendingConnection()};
    WireRuntime runtime{*socket};

    require(waitForGuiCondition([&] {
      return client.status()->connected();
    },
                wait_ms),
        "The handshake did not finish");
    runtime.send(ClientLayoutSnapshot{});
    open(runtime);
    sendScreen(runtime);
    runtime.send(PaneShell{.pane_id = pane_id, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true});

    TerminalItem terminal{window.contentItem()};
    // Read before the terminal takes the controller, which lends the client mutably.
    const auto grid = client.display()->geometry().value(QStringLiteral("typography")).toMap().value(QStringLiteral("grid"));
    const auto colors = client.colors();

    terminal.setController(client.terminals());
    terminal.setPaneId(QString::number(pane_id));
    terminal.setSize(QSizeF{window_size});
    QQmlEngine engine;
    auto separators = createChrome(engine, QStringLiteral("CommandSeparators"), {{QStringLiteral("view"), QVariant::fromValue(static_cast<QObject*>(&terminal))}, {QStringLiteral("colors"), colors}, {QStringLiteral("grid"), grid}});

    separators->setParentItem(&terminal);
    window.show();

    // Every command is named before any block views its name.
    std::vector<std::string> commands;

    commands.reserve(options.blocks);
    for (unsigned index = 0; index < options.blocks; ++index) {
      commands.push_back("make target-" + std::to_string(index));
    }

    const auto screens = commandScreens(commands);

    runtime.send(PaneBlocks{.pane_id = pane_id, .blocks = screens[0]});
    require(waitForGuiCondition([&] {
      return firstRow(terminal, options.blocks) == 0;
    },
                wait_ms),
        "The separators did not appear");

    const auto timing = measure(runtime, terminal, options, screens);

    // Entrances and colour changes finish before the oracle reads the window.
    constexpr int settle_ms = 1500;

    waitForGuiCondition([] {
      return false;
    },
        settle_ms);
    const auto listed = QJsonDocument{QJsonArray::fromVariantList(terminal.separators())}.toJson(QJsonDocument::Compact);

    if (!options.output.isEmpty()) {
      require(window.grabWindow().save(options.output, "PNG"), "Cannot save the final window");
    }

    const QJsonObject result{{"iterations", static_cast<int>(options.iterations)}, {"warmup", static_cast<int>(options.warmup)}, {"blocks", static_cast<int>(options.blocks)}, {"cpu_ns", qint64{timing.cpu}}, {"wall_ns", qint64{timing.wall}}, {"separators_sha256", QString::fromLatin1(QCryptographicHash::hash(listed, QCryptographicHash::Sha256).toHex())}};

    std::cout << QJsonDocument{result}.toJson(QJsonDocument::Compact).constData() << '\n';
    return 0;
  }

}

int main(int argc, char** argv) {
  const QGuiApplication application{argc, argv};

  try {
    return run(application);
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
