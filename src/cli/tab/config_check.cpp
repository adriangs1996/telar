module telar.cli.tab;

import std;

import telar.config.snapshot;
import telar.lua;
import telar.platform.fs;
import telar.platform.paths;
import telar.plugins;
import telar.sys.posix;
import telar.config.client;
import telar.config.core;
import telar.config.runtime;
import telar.base.ds;

namespace telar::runtime::cli {

  namespace {

#include "window_config_bootstrap.inc"

    struct ConfigurationFailure : std::runtime_error {
      using std::runtime_error::runtime_error;
    };

    // Prints the formatted message, cut to one line's buffer, and fails with `code`.
    template <typename... Arguments>
    [[noreturn]] void diagnostic(const char* code, std::format_string<Arguments...> format, Arguments&&... arguments) {
      ds::Array<char, 1024> line;
      const auto written = std::format_to_n(line.dataMut(), line.size(), format, std::forward<Arguments>(arguments)...);
      const auto size = std::min(static_cast<std::size_t>(written.size), line.size());

      std::fprintf(stderr, "telar config: %.*s\n", static_cast<int>(size), line.data());
      throw ConfigurationFailure{code};
    }

    void executeSource(lua_State* state, std::string_view source) {
      const auto loaded = luaL_loadbufferx(state, source.data(), source.size(), "@config.lua", "t");
      if (loaded != LUA_OK) {
        diagnostic("LuaLoadFailed", "{}", lua_tostring(state, -1) == nullptr ? "unknown Lua error" : lua_tostring(state, -1));
      }

      if (lua_pcall(state, 0, 1, 0) != LUA_OK) {
        diagnostic("LuaRuntimeFailed", "{}", lua_tostring(state, -1) == nullptr ? "unknown Lua error" : lua_tostring(state, -1));
      }
    }

    void validateRoot(const lua::Value& root) {
      if (!root.is(LUA_TTABLE)) {
        diagnostic("InvalidConfig", "config.lua must return a table");
      }

      constexpr ds::Array allowed{"api_version", "theme", "client", "gui", "runtime", "plugins", "profiles"};

      root.eachField([&](std::string_view name, const lua::Value&) {
        if (std::ranges::find(allowed, name) == allowed.end()) {
          diagnostic("InvalidConfig", "unknown field config.{}", name);
        }
      });

      const auto version = root.field("api_version").asInteger();
      if (!version) {
        diagnostic("InvalidConfig", "config.api_version must be an integer");
      }

      if (*version != 2) {
        diagnostic("IncompatibleConfigApi", "config.api_version is {}; this Telar accepts 2", *version);
      }
    }

    void retiredWarnings(const lua::Value& root) {
      const auto client = root.field("client");
      if (!client.present()) {
        return;
      }

      ds::Array<std::string_view, 4> paths{};
      std::size_t count = 0;
      const auto sidebar = client.field("sidebar");
      if (sidebar.present() && sidebar.field("renderer").present()) {
        paths.atMut(count++) = "client.sidebar.renderer";
      }

      const auto notifications = client.field("notifications");
      if (notifications.present() && notifications.field("delivery").present() && notifications.field("delivery").string() == "terminal") {
        paths.atMut(count++) = "client.notifications.delivery = \"terminal\"";
      }

      const auto input = client.field("input");
      if (input.present() && input.field("escape_timeout_ms").present()) {
        paths.atMut(count++) = "client.input.escape_timeout_ms";
      }

      if (client.field("icons").present()) {
        paths.atMut(count++) = "client.icons";
      }

      if (count == 0) {
        return;
      }

      std::fputs("telar config: warning: Ignored ", stderr);
      for (std::size_t index = 0; index < count; ++index) {
        if (index != 0) {
          std::fputs(", ", stderr);
        }

        std::fprintf(stderr, "%.*s", static_cast<int>(paths[index].size()), paths[index].data());
      }

      std::fputs(": only the retired terminal client used them; remove them\n", stderr);
    }

    void validatePluginAction(const lua::Value& action, std::span<const plugins::Package> packages) {
      if (!action.is(LUA_TTABLE)) {
        return;
      }

      const auto kind = action.field("kind");
      if (!kind.present() || kind.string() != "plugin") {
        return;
      }

      const auto id = action.field("plugin").string();
      const auto name = action.field("action").string();

      for (const auto& package : packages) {
        if (package.manifest.id.view() != id) {
          continue;
        }

        for (const auto& candidate : std::span{package.manifest.actions}.first(package.manifest.action_count)) {
          if (candidate.view() == name) {
            return;
          }
        }

        throw ConfigurationFailure{"UnknownPluginAction"};
      }

      throw ConfigurationFailure{"PluginNotConfigured"};
    }

    void validateBindings(const lua::Value& client, config::KeyChord prefix, std::span<const plugins::Package> packages) {
      if (!client.present()) {
        return;
      }

      const auto bindings = client.field("keybindings");
      if (!bindings.present()) {
        return;
      }

      constexpr std::size_t maximum_keys = 5;

      struct Sequence {
        ds::Array<config::KeyChord, maximum_keys> keys;
        std::size_t count = 0;
      };

      ds::Array<Sequence, config::BindingKeymap::maximum_bindings> sequences{};
      const auto count = std::min(bindings.listLength(), sequences.size());

      for (std::size_t index = 0; index < count; ++index) {
        const auto binding = bindings.element(index + 1);

        validatePluginAction(binding.field("action"), packages);
        auto& sequence = sequences.atMut(index);

        if (binding.field("prefixed").boolean(false)) {
          sequence.keys.atMut(sequence.count++) = prefix;
        }

        const auto keys = binding.field("keys");

        for (std::size_t key = 1; key <= keys.listLength(); ++key) {
          sequence.keys.atMut(sequence.count++) = config::KeyChordValidator::parse(keys.element(key));
        }

        for (std::size_t previous = 0; previous < index; ++previous) {
          const auto& other = sequences[previous];
          const auto shared = std::min(other.count, sequence.count);
          if (std::equal(sequence.keys.begin(), sequence.keys.begin() + shared, other.keys.begin())) {
            const auto* const error = other.count == sequence.count ? "DuplicateBinding" : "AmbiguousBindingPrefix";

            std::fprintf(stderr, "telar config: keybindings do not compile: %s\n", error);
            throw ConfigurationFailure{error};
          }
        }
      }
    }

    void validateSelectedBindings(const lua::Value& root, std::string_view profile, std::span<const plugins::Package> packages) {
      config::KeyChord prefix{.key = config::KeyChord::Key::character, .character = 'b', .modifiers = static_cast<unsigned>(config::KeyChord::Modifier::control)};
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

  int checkConfiguration(const window::ConfigCheckOptions& options) {
    try {
      SystemAllocator system;
      constexpr std::size_t memory_budget = 64 * 1024 * 1024;
      BudgetAllocator budget{system, memory_budget};
      MemoryAdapter budget_memory{budget};
      Memory& memory = budget_memory;
      ds::String<Memory> path{memory};
      const ProcessEnvironment environment;

      if (options.path != nullptr) {
        path.assign(options.path);
      } else {
        path = RuntimePaths<Memory>::configFile(memory, environment);
        if (path.empty()) {
          diagnostic("HomeUnavailable", "cannot resolve config: Home directory unavailable for configuration");
        }
      }

      ds::Array<char, PATH_MAX> canonical;
      if (::realpath(path.data(), canonical.dataMut()) == nullptr) {
        const auto* const error = sys::errorName(sys::lastError());

        diagnostic(error, "cannot resolve config '{}': {}", std::string_view{path}, error);
      }

      // The configuration's directory: the canonical path up to its last separator.
      const std::string_view canonical_path{canonical.data()};
      const auto directory = canonical_path.substr(0, std::max<std::size_t>(canonical_path.rfind('/'), 1));
      constexpr std::size_t maximum_source_bytes = 1024 * 1024;
      const auto source = readFile(memory, canonical.data(), maximum_source_bytes);
      lua::Vm vm{memory};

      vm.execute(configuration_bootstrap, "@telar/bootstrap.lua", 0);
      lua_getglobal(vm.state(), "telar");
      lua::JsonDecoder<Memory>::install(vm.state(), memory);
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
    } catch (const ConfigurationFailure& error) {
      std::fprintf(stderr, "error: %s\n", error.what());
      return 1;
    } catch (const std::exception& error) {
      std::fprintf(stderr, "telar config: %s\nerror: InvalidConfig\n", error.what());
      return 1;
    }
  }

}
