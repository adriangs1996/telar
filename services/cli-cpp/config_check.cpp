#include "config_check.hpp"
#include "telar_config/local_modules.hpp"
#include "telar_config/snapshot_reader.hpp"
#include "telar_lua/json.hpp"
#include "telar_platform/process_environment.hpp"
#include "telar_platform/read_file.hpp"
#include "telar_plugins/package_registry.hpp"
#include "window_config_bootstrap.hpp"
#include <filesystem>

namespace telar::runtime::cli {

namespace {

struct ConfigurationFailure : std::runtime_error {
  using std::runtime_error::runtime_error;
};

[[noreturn]] void diagnostic(std::string_view message, const char *code) {
  std::fprintf(stderr, "telar config: %.*s\n", static_cast<int>(message.size()), message.data());
  throw ConfigurationFailure{code};
}

void executeSource(lua_State *state, std::string_view source) {
  const auto loaded = luaL_loadbufferx(state, source.data(), source.size(), "@config.lua", "t");
  if (loaded != LUA_OK) {
    diagnostic(lua_tostring(state, -1) == nullptr ? "unknown Lua error" : lua_tostring(state, -1), "LuaLoadFailed");
  }

  if (lua_pcall(state, 0, 1, 0) != LUA_OK) {
    diagnostic(lua_tostring(state, -1) == nullptr ? "unknown Lua error" : lua_tostring(state, -1), "LuaRuntimeFailed");
  }
}

void validateRoot(const lua::Value &root) {
  if (!root.is(LUA_TTABLE)) {
    diagnostic("config.lua must return a table", "InvalidConfig");
  }

  constexpr std::array allowed{"api_version", "theme", "client", "gui", "runtime", "plugins", "profiles"};
  root.eachField([&](std::string_view name, const lua::Value &) {
    if (std::ranges::find(allowed, name) == allowed.end()) {
      diagnostic(std::string{"unknown field config."} + std::string{name}, "InvalidConfig");
    }
  });
  const auto version = root.field("api_version").asInteger();
  if (!version) {
    diagnostic("config.api_version must be an integer", "InvalidConfig");
  }
  if (*version != 2) {
    diagnostic("config.api_version is " + std::to_string(*version) + "; this Telar accepts 2", "IncompatibleConfigApi");
  }
}

void retiredWarnings(const lua::Value &root) {
  const auto client = root.field("client");
  if (!client.present()) {
    return;
  }

  std::vector<std::string_view> paths;
  const auto sidebar = client.field("sidebar");
  if (sidebar.present() && sidebar.field("renderer").present()) {
    paths.push_back("client.sidebar.renderer");
  }

  const auto notifications = client.field("notifications");
  if (notifications.present() && notifications.field("delivery").present() && notifications.field("delivery").string() == "terminal") {
    paths.push_back("client.notifications.delivery = \"terminal\"");
  }

  const auto input = client.field("input");
  if (input.present() && input.field("escape_timeout_ms").present()) {
    paths.push_back("client.input.escape_timeout_ms");
  }
  if (client.field("icons").present()) {
    paths.push_back("client.icons");
  }
  if (paths.empty()) {
    return;
  }

  std::fputs("telar config: warning: Ignored ", stderr);
  for (std::size_t index = 0; index < paths.size(); ++index) {
    if (index != 0) {
      std::fputs(", ", stderr);
    }

    std::fprintf(stderr, "%.*s", static_cast<int>(paths[index].size()), paths[index].data());
  }

  std::fputs(": only the retired terminal client used them; remove them\n", stderr);
}

void validatePluginAction(const lua::Value &action, std::span<const plugins::Package> packages) {
  if (!action.is(LUA_TTABLE)) {
    return;
  }

  const auto kind = action.field("kind");
  if (!kind.present() || kind.string() != "plugin") {
    return;
  }

  const auto id = action.field("plugin").string();
  const auto name = action.field("action").string();
  for (const auto &package : packages) {
    if (package.manifest.id.view() != id) {
      continue;
    }

    for (const auto &candidate : std::span{package.manifest.actions}.first(package.manifest.action_count)) {
      if (candidate.view() == name) {
        return;
      }
    }

    throw ConfigurationFailure{"UnknownPluginAction"};
  }

  throw ConfigurationFailure{"PluginNotConfigured"};
}

void validateBindings(const lua::Value &client, config::KeyChord prefix, std::span<const plugins::Package> packages) {
  if (!client.present()) {
    return;
  }

  const auto bindings = client.field("keybindings");
  if (!bindings.present()) {
    return;
  }

  constexpr std::size_t maximum_keys = 5;

  struct Sequence {
    std::array<config::KeyChord, maximum_keys> keys;
    std::size_t count = 0;
  };

  std::array<Sequence, config::BindingKeymap::maximum_bindings> sequences{};
  const auto count = std::min(bindings.listLength(), sequences.size());
  for (std::size_t index = 0; index < count; ++index) {
    const auto binding = bindings.element(index + 1);
    validatePluginAction(binding.field("action"), packages);
    auto &sequence = sequences[index];
    if (binding.field("prefixed").boolean(false)) {
      sequence.keys[sequence.count++] = prefix;
    }

    const auto keys = binding.field("keys");
    for (std::size_t key = 1; key <= keys.listLength(); ++key) {
      sequence.keys[sequence.count++] = config::KeyChordValidator::parse(keys.element(key));
    }

    for (std::size_t previous = 0; previous < index; ++previous) {
      const auto &other = sequences[previous];
      const auto shared = std::min(other.count, sequence.count);
      if (std::equal(sequence.keys.begin(), sequence.keys.begin() + shared, other.keys.begin())) {
        const auto error = other.count == sequence.count ? "DuplicateBinding" : "AmbiguousBindingPrefix";
        std::fprintf(stderr, "telar config: keybindings do not compile: %s\n", error);
        throw ConfigurationFailure{error};
      }
    }
  }
}

void validateSelectedBindings(const lua::Value &root, std::string_view profile, std::span<const plugins::Package> packages) {
  config::KeyChord prefix{config::KeyChord::Key::character, 'b', static_cast<unsigned>(config::KeyChord::Modifier::control)};
  const auto client = root.field("client");
  if (client.present() && client.field("prefix").present()) {
    prefix = config::KeyChordValidator::parse(client.field("prefix"));
  }

  if (!profile.empty()) {
    const auto profiles = root.field("profiles");
    const auto selected = profiles.entry(profile);
    const auto profile_config = selected.as("config");
    const auto overlay = profile_config.field("client");
    if (overlay.present()) {
      if (overlay.field("prefix").present()) {
        prefix = config::KeyChordValidator::parse(overlay.field("prefix"));
      }
      if (overlay.field("keybindings").present()) {
        validateBindings(overlay, prefix, packages);
        return;
      }
    }
  }

  validateBindings(client, prefix, packages);
}

}

int checkConfiguration(const window::ConfigCheckOptions &options) {
  try {
    SystemAllocator system;
    constexpr std::size_t memory_budget = 64 * 1024 * 1024;
    BudgetAllocator memory{system, memory_budget};
    String<decltype(memory)> path{AllocatorRef<char, decltype(memory)>{memory}};
    const ProcessEnvironment environment;
    if (options.path != nullptr) {
      path = options.path;
    } else if (const auto development = environment.lookup("TELAR_DEVELOPMENT_CONFIG"); !development.empty()) {
      path = development;
    } else if (const auto base = environment.lookup("XDG_CONFIG_HOME"); !base.empty()) {
      path = base;
      path += "/telar/config.lua";
    } else {
      path = environment.lookup("HOME");
      path += "/.config/telar/config.lua";
    }

    std::array<char, PATH_MAX> canonical;
    if (::realpath(path.c_str(), canonical.data()) == nullptr) {
      const auto error = errno == ENOENT ? "FileNotFound" : errno == EACCES ? "AccessDenied"
                                                                            : "Unexpected";
      diagnostic("cannot resolve config '" + std::string{path} + "': " + error, error);
    }

    const auto directory = std::filesystem::path{canonical.data()}.parent_path().string();
    constexpr std::size_t maximum_source_bytes = 1024 * 1024;
    const auto source = readFile(memory, canonical.data(), maximum_source_bytes);
    lua::Vm vm{memory};
    vm.execute(configuration_bootstrap, "@telar/bootstrap.lua", 0);
    lua_getglobal(vm.state(), "telar");
    lua::JsonDecoder<decltype(memory)>::install(vm.state(), memory);
    lua_pop(vm.state(), 1);
    config::LocalModules modules{vm.state(), directory};
    executeSource(vm.state(), source);
    config::RuntimeValues values{memory};
    const lua::Value root{vm.state(), -1, "config"};
    validateRoot(root);
    config::SnapshotReader{memory, values}.read(root, options.profile);
    plugins::PackageRegistry registry{memory, directory, values.plugins.configured()};
    validateSelectedBindings(root, options.profile, registry.packages());
    retiredWarnings(root);
    values.limits.print();
    if (!values.limits.entries().empty()) {
      std::fputs("error: ConfigLimitReached\n", stderr);
      return 1;
    }

    std::fputs("telar config: OK\n", stdout);
    return 0;
  } catch (const ConfigurationFailure &error) {
    std::fprintf(stderr, "error: %s\n", error.what());
    return 1;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar config: %s\nerror: InvalidConfig\n", error.what());
    return 1;
  }
}

}
