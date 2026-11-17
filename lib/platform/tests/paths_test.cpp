#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.platform.paths;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::cli;

  struct TestEnvironment final : EnvironmentSource {
    using Values = std::array<std::pair<std::string_view, std::string_view>, 8>;

    explicit TestEnvironment(const Values& entries) noexcept
        : values(entries) {}

    Values values{};

    std::string_view lookup(const char* name) const noexcept override {
      for (const auto& [key, value] : values) {
        if (key == name) {
          return value;
        }
      }

      return {};
    }
  };

  void testPaths() {
    SystemAllocator memory;
    TestEnvironment environment{{{{"TELAR_SOCKET", "/override/runtime.sock"}, {"TELAR_SOCKET_PATH", "/pane/runtime.sock"}, {"XDG_RUNTIME_DIR", "/runtime/"}, {"HOME", "/home/user"}, {"XDG_DATA_HOME", "/data"}}}};
    ServerOptions options;

    options.socket = "/explicit/runtime.sock";
    RuntimePaths explicit_paths{memory, options, environment};

    check(explicit_paths.socket == options.socket && !explicit_paths.socket_managed);
    options.socket = {};
    RuntimePaths override_paths{memory, options, environment};

    check(override_paths.socket == "/override/runtime.sock" && !override_paths.socket_managed);
    environment.values[0].second = {};
    RuntimePaths pane_paths{memory, options, environment};

    check(pane_paths.socket == "/pane/runtime.sock" && !pane_paths.socket_managed);
    environment.values[1].second = {};
    RuntimePaths managed_paths{memory, options, environment};

    check(managed_paths.socket == "/runtime/telar/runtime.sock" && managed_paths.socket_managed);

    managed_paths.resolveStorage(options, environment);
    check(managed_paths.history == "/data/telar/history.db" && managed_paths.history_managed);
    check(managed_paths.session == "/data/telar/session.ckpt");
    environment.values[4].second = {};
    RuntimePaths home_paths{memory, options, environment};

    home_paths.resolveStorage(options, environment);
    check(home_paths.history == "/home/user/.local/share/telar/history.db");

    environment.values[4] = {"TELAR_HISTORY", "/private/history.db"};
    options.persist_session = false;
    RuntimePaths custom_paths{memory, options, environment};

    custom_paths.resolveStorage(options, environment);
    check(custom_paths.history == "/private/history.db" && !custom_paths.history_managed && custom_paths.session.empty());
  }

  // Every process finds the configuration directory the same way: an XDG path counts only when
  // absolute, HOME too, and without either there is none.
  void testConfigHome() {
    SystemAllocator memory;
    using Paths = RuntimePaths<SystemAllocator>;
    TestEnvironment environment{{{{"XDG_CONFIG_HOME", "/config"}, {"HOME", "/home/user"}, {"TELAR_DEVELOPMENT_CONFIG", ""}}}};

    check(Paths::configHome(memory, environment) == "/config/telar");
    check(Paths::configFile(memory, environment) == "/config/telar/config.lua");
    environment.values[0].second = "relative";
    check(Paths::configHome(memory, environment) == "/home/user/.config/telar");
    environment.values[0].second = {};
    check(Paths::configHome(memory, environment) == "/home/user/.config/telar");
    environment.values[1].second = {};
    check(Paths::configHome(memory, environment).empty() && Paths::configFile(memory, environment).empty());
    environment.values[1].second = "home";
    check(Paths::configHome(memory, environment).empty());
    environment.values[2].second = "/repository/dev/config.lua";
    check(Paths::configFile(memory, environment) == "/repository/dev/config.lua");

    ServerOptions options;

    options.socket = "/run/user/";
    bool rejected = false;

    try {
      RuntimePaths directory{memory, options, environment};
    } catch (const std::invalid_argument&) {
      rejected = true;
    }

    check(rejected);
  }

  void testArguments() {
    std::array arguments{const_cast<char*>("server"), const_cast<char*>("endpoint"), const_cast<char*>("--socket"), const_cast<char*>("/tmp/runtime.sock"), const_cast<char*>("--no-config")};
    const auto options = ServerOptions::parse(arguments);

    check(options.action == ServerAction::endpoint && options.socket == "/tmp/runtime.sock" && options.no_config);
    arguments.back() = const_cast<char*>("--fresh");
    bool rejected = false;

    try {
      ServerOptions::parse(arguments);
    } catch (const std::invalid_argument&) {
      rejected = true;
    }

    check(rejected);
  }

  const telar::testing::Case case_paths{"paths.runtime_paths", testPaths};
  const telar::testing::Case case_config_home{"paths.config_home", testConfigHome};
  const telar::testing::Case case_arguments{"paths.server_arguments", testArguments};

}
