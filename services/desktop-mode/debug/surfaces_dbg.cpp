// Renders the chrome surfaces (top bar, sidebar, pane headers) against a made-up runtime with
// agents in every status, and saves each frame as a PNG, so the Lua UI can be compared with its
// design without taking over the macOS Spaces. Run it with QT_QPA_PLATFORM=offscreen and
// TELAR_DESKTOP_UI_DIR pointing at ui/ to see unbuilt Lua changes.

#include "desktop_session.hpp"
#include "lua_vm.hpp"
#include "runtime_session.hpp"
#include "shortcuts.hpp"
#include "telar_client/telar.hpp"
#include "ui/desktop_ui.hpp"
#include "ui/lua_surface.hpp"
#include "ui/services.hpp"
#include <QCommandLineParser>
#include <QDir>
#include <QEventLoop>
#include <QGuiApplication>
#include <QImage>
#include <QTimer>
#include <chrono>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {
  constexpr std::uint32_t display = 1;
  constexpr int settle_ms = 400;

  struct Listener {
    int fd = -1;
    std::string path;

    explicit Listener(std::string socket_path)
        : path(std::move(socket_path)) {
      ::unlink(path.c_str());
      fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
      sockaddr_un address{};
      address.sun_family = AF_UNIX;
      std::snprintf(address.sun_path, sizeof(address.sun_path), "%s", path.c_str());

      if (fd < 0 || ::bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 ||
          ::listen(fd, 1) != 0) {
        throw std::runtime_error("Unable to listen on the stand-in runtime socket");
      }
    }

    ~Listener() {
      ::close(fd);
      ::unlink(path.c_str());
    }
  };

  void settle() {
    QEventLoop loop;
    QTimer::singleShot(settle_ms, &loop, &QEventLoop::quit);
    loop.exec();
  }

  RuntimeAgent agent(std::uint64_t pane, std::string status, std::string name, int age_s) {
    RuntimeAgent result;
    result.pane = pane;
    result.generation = 1;
    result.workspace = RuntimeWorkspace{1};
    result.tab = 101;
    result.pane_index = 1;
    result.workspace_label = "telar";
    result.tab_label = "desktop";
    result.provider = name == "Codex" ? "codex" : name == "Pi" ? "pi" : "claude";
    result.name = std::move(name);
    result.status = std::move(status);
    result.status_changed = std::chrono::steady_clock::now() - std::chrono::seconds(age_s);
    return result;
  }

  RuntimeState runtimeState(bool with_agents) {
    RuntimeState state;
    state.connected = true;
    state.workspaces_ready = true;
    state.workspace = RuntimeWorkspace{1};
    state.workspaces = {{1, "telar", 3}, {2, "guruwalk-api", 2}, {3, "dotfiles", 1}};
    state.checkouts = {{1, "feat/desktop-lua-ui", true}, {2, "main", false}, {3, "main", false}};
    state.worktrees = {{
        .id = 7,
        .workspace = 2,
        .branch = "refunds-retry",
        .title = "Booking refunds",
        .diff_added = 48,
        .diff_removed = 12,
        .diff_files = 5,
        .commits_ahead = 2,
        .command_label = "rspec",
        .command_state = "exited",
    }};
    state.views = {RuntimeView{
        .workspace = RuntimeWorkspace{1},
        .name = "telar",
        .active_tab = 101,
        .tabs = {{101, "desktop", {{11, "claude"}, {12, "codex"}, {13, "zsh"}}},
                 {102, "proxy", {{14, "nvim"}}},
                 {103, "", {{15, "zsh"}}}},
    }};

    if (!with_agents) {
      state.agents = std::make_shared<const std::vector<RuntimeAgent>>();
      return state;
    }

    auto blocked = agent(12, "blocked", "Codex", 64);
    blocked.blocked_reason = "permission";
    blocked.title = "proxy TLS tests";
    blocked.pane_index = 2;
    blocked.last_event = "zig build test -Dproxy --summary failures";

    auto working = agent(11, "working", "Claude Code", 134);
    working.title = "✳ Login shell for runtime endpoint";
    working.cwd_label = "~/telar";
    working.last_event = "Edit services/desktop-mode/runtime_endpoint.cpp";
    working.plan_step = "Wire login shell into runtime endpoint";
    working.plan_done = 3;
    working.status_changed = std::chrono::steady_clock::now() - std::chrono::seconds(14);
    working.plan_total = 7;

    auto refunds = agent(21, "working", "Claude Code", 720);
    refunds.workspace = RuntimeWorkspace{2};
    refunds.workspace_label = "guruwalk-api";
    refunds.tab_label = "";
    refunds.title = "Booking refunds";
    refunds.last_event = "Bash bundle exec rspec spec/bookings";
    refunds.work_tree = 7;

    auto done = agent(31, "done", "Pi", 240);
    done.workspace = RuntimeWorkspace{3};
    done.workspace_label = "dotfiles";
    done.tab_label = "main";
    done.title = "vt reflow";
    done.last_event = "Bash zig build test";
    done.final_message = "Wide chars keep their column on resize; the reflow test covers it.";

    auto idle = agent(32, "ready", "Codex", 3900);
    idle.workspace = RuntimeWorkspace{3};
    idle.workspace_label = "adriangonzalez";
    idle.tab_label = "";
    idle.title = "adriangonzalez";

    auto plain = agent(33, "ready", "Claude Code", 5);
    plain.title = "✳ Claude Code";

    state.agents = std::make_shared<const std::vector<RuntimeAgent>>(
        std::vector{blocked, working, refunds, done, idle, plain});
    return state;
  }

  DesktopState desktopState() {
    DesktopState state;
    state.available = true;
    state.accessibility = true;
    state.focused_space = 1;
    state.displays = {{display, "display", 0, 0, 1512, 982}};

    for (std::uint64_t index = 1; index <= 3; ++index) {
      state.spaces.push_back({.id = index,
                              .uuid = "space-" + std::to_string(index),
                              .display = display,
                              .index = static_cast<std::uint32_t>(index),
                              .visible = index == 1,
                              .focused = index == 1,
                              .managed = true,
                              .workspace = index});
    }

    return state;
  }

  QVariantMap rectangle(double x, double y, double width, double height) {
    return {{"x", x}, {"y", y}, {"width", width}, {"height", height}};
  }

  QVariantMap panelState(QSize size) {
    return {{"screen",
             QVariantMap{{"id", display},
                         {"name", "display"},
                         {"geometry", rectangle(0, 0, 1512, 982)},
                         {"available_geometry", rectangle(0, 0, 1512, 982)}}},
            {"geometry", rectangle(0, 0, size.width(), size.height())},
            {"visible", true}};
  }

  QVariantMap paneState(QSize size, std::uint64_t pane, bool focused) {
    return {{"element", QString::number(pane)},
            {"pane", QString::number(pane)},
            {"workspace", "1"},
            {"tab", "101"},
            {"focused", focused},
            {"floating", false},
            {"visible", true},
            {"area", rectangle(0, 0, 1512, 982)},
            {"geometry", rectangle(0, 0, size.width(), size.height())},
            {"content", rectangle(8, 34, size.width() - 16, size.height() - 42)}};
  }

  void save(LuaSurface &surface, const QDir &directory, const QString &name) {
    settle();
    const auto image = surface.window().grabWindow();
    const auto path = directory.filePath(name + ".png");

    if (image.isNull() || !image.save(path)) {
      std::fprintf(stderr, "FAIL: could not save %s\n", qPrintable(path));
      return;
    }

    std::printf("%s\n", qPrintable(path));
  }
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  QCommandLineParser parser;
  parser.addHelpOption();
  const QCommandLineOption images_option("images",
                                         "Save the frames as PNG files in this existing directory.",
                                         "directory");
  parser.addOption(images_option);
  parser.process(application);
  const QDir images(parser.value(images_option));

  if (!parser.isSet(images_option) || !images.exists()) {
    std::fprintf(stderr, "--images must name an existing directory\n");
    return 1;
  }

  // Relative, since a socket path must fit in sockaddr_un: it lands in the working directory.
  const Listener listener("surfaces_dbg.sock");
  lua::Vm vm;
  auto client = telar::Client::init(listener.path.c_str());
  RuntimeSession runtime{client, listener.path};
  // Spaces bind to workspaces only through the registry, which then must not touch the user's.
  qputenv("TELAR_DESKTOP_STATE_DIR", images.absoluteFilePath("desktop-state").toUtf8());
  DesktopSession desktop{listener.path};
  Shortcuts shortcuts;
  ui::Services services{vm, runtime, desktop, shortcuts, listener.path};
  const auto state = runtimeState(true);
  desktop.apply(desktopState());
  desktop.reconcile(state.workspaces);

  for (const auto &workspace : state.workspaces) {
    desktop.execute(
        {.kind = DesktopCommand::Kind::bind, .space = workspace.id, .workspace = workspace.id});
  }

  runtime.apply(state);

  {
    ui::DesktopUi desktop_ui(services);
    const QSize topbar_size(1512, 44), sidebar_size(300, 900), pane_size(720, 300);
    LuaSurface topbar(desktop_ui, topbar_size, ui::SurfaceKind::topbar);
    topbar.setNativeState(panelState(topbar_size));
    LuaSurface sidebar(desktop_ui, sidebar_size, ui::SurfaceKind::sidebar);
    sidebar.setNativeState(panelState(sidebar_size));
    LuaSurface working(desktop_ui, pane_size, ui::SurfaceKind::workbench);
    working.setNativeState(paneState(pane_size, 11, true));
    LuaSurface blocked(desktop_ui, pane_size, ui::SurfaceKind::workbench);
    blocked.setNativeState(paneState(pane_size, 12, false));
    LuaSurface shell(desktop_ui, pane_size, ui::SurfaceKind::workbench);
    shell.setNativeState(paneState(pane_size, 13, false));

    save(topbar, images, "topbar");
    save(sidebar, images, "sidebar");
    save(working, images, "pane-working");
    save(blocked, images, "pane-blocked");
    save(shell, images, "pane-shell");

    const QSize rail_size(52, 900);
    LuaSurface rail(desktop_ui, rail_size, ui::SurfaceKind::sidebar);
    rail.setNativeState(panelState(rail_size));
    save(rail, images, "sidebar-collapsed");

    // Statuses change under the open surfaces: the waiting agent starts working and the working
    // one finishes, so both cards move to their new groups.
    auto changed = runtimeState(true);
    auto agents = *changed.agents;
    agents[0].status = "working";
    agents[0].blocked_reason.clear();
    agents[1].status = "done";
    // In attention order, as the runtime session sorts it: working, then done.
    std::swap(agents[1], agents[2]);
    changed.agents = std::make_shared<const std::vector<RuntimeAgent>>(std::move(agents));
    runtime.apply(changed);
    save(sidebar, images, "sidebar-changed");
    save(blocked, images, "pane-changed");

    runtime.apply(runtimeState(false));
    save(sidebar, images, "sidebar-empty");
  }

  client.deinit();
  return 0;
}
