module;
#include <lua.h>

export module telar.config.snapshot;

import std;
export import telar.config.client;
export import telar.config.gui;
export import telar.config.runtime;

// Interface: telar_config/plugin_reader.cppm
namespace telar::runtime::config {

  class PluginReader {
  public:
    inline static void read(const lua::Value& value, plugins::Specifications& destination, LimitNotices& limits) {
      if (!value.present()) {
        return;
      }

      const auto listed = value.listLength();
      const auto count = std::min(listed, plugins::PackageLimits::configured);
      if (count < listed) {
        limits.add({.name = "plugins.max_plugins", .noun = "plugins", .value = plugins::PackageLimits::configured, .requested = listed});
      }

      destination.count = 0;
      for (std::size_t index = 0; index < count; ++index) {
        const auto specification = value.element(static_cast<lua_Integer>(index + 1));

        specification.onlyFields({"path", "enabled"});
        const auto path_value = specification.field("path");
        const auto path = path_value.string();
        if (path.empty() || path.size() > plugins::PackageLimits::configured_path_bytes) {
          path_value.fail("is outside its bounds");
        }

        auto& plugin = destination.entries[destination.count];

        plugin.path.assign(path);
        plugin.enabled = specification.field("enabled").boolean(true);
        ++destination.count;
      }
    }
  };

}

// Interface: telar_config/snapshot_reader.cppm
export {
  namespace telar::runtime::config {

    inline bool validProfileName(std::string_view name) noexcept {
      return !name.empty() && name.size() <= 64 && std::ranges::all_of(name, [](char byte) {
        return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
      });
    }

    template <Allocator Memory>
    class SnapshotReader {
    public:
      inline explicit SnapshotReader(Memory& memory, RuntimeValues<Memory>& values)
          : memory_(memory),
            values_(values) {}

      inline void read(const lua::Value& root, std::string_view selected_profile) {
        auto state = makeOwned<ClientValidationState>(memory_);

        read(root, selected_profile, *state);
      }

      template <CommandTabStore Commands>
      inline void read(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<Commands>& client_state) {
        root.onlyFields({"api_version", "theme", "client", "gui", "runtime", "plugins", "profiles"});
        if (root.field("api_version").integer() != 2) {
          root.fail("requires api_version = 2");
        }

        const auto base_client = root.field("client");

        static_cast<void>(ThemeReader::selection(root));
        ClientValidator::validate(base_client, values_.limits, client_state);
        static_cast<void>(GuiReader::read(root.field("gui")));
        RuntimeReader{values_}.read(root.field("runtime"));
        PluginReader::read(root.field("plugins"), values_.plugins, values_.limits);
        const auto profiles = root.field("profiles");
        if (!profiles.present()) {
          if (!selected_profile.empty()) {
            profiles.fail("does not define the selected profile");
          }

          client_state.keymap.report(values_.limits);
          return;
        }

        profiles.eachField([&](std::string_view name, const lua::Value& profile) {
          if (!validProfileName(name)) {
            profile.fail("has an invalid name");
          }

          if (name != selected_profile) {
            auto checked = makeOwned<RuntimeValues<Memory>>(memory_, values_);
            const auto saved_commands = client_state.commands.checkpoint();
            const auto saved_keymap = client_state.keymap;

            readProfile(profile.as("config"), *checked, base_client, client_state);
            client_state.commands.restore(saved_commands);
            client_state.keymap = saved_keymap;
          }
        });

        if (selected_profile.empty()) {
          client_state.keymap.report(values_.limits);
          return;
        }

        std::array<char, 65> name{};

        if (!validProfileName(selected_profile)) {
          profiles.fail("has an invalid selected profile name");
        }

        std::copy(selected_profile.begin(), selected_profile.end(), name.begin());
        const auto selected = profiles.field(name.data());
        if (!selected.present()) {
          selected.fail("is not defined");
        }

        readProfile(selected.as("config"), values_, base_client, client_state);
        client_state.keymap.report(values_.limits);
      }

    private:
      template <CommandTabStore Commands>
      inline static void readProfile(const lua::Value& profile, RuntimeValues<Memory>& values, const lua::Value& base_client, BasicClientValidationState<Commands>& client_state) {
        profile.onlyFields({"theme", "client", "gui", "runtime", "plugins"});
        static_cast<void>(ThemeReader::selection(profile));
        ClientValidator::validate(profile.field("client"), values.limits, client_state, &base_client);
        static_cast<void>(GuiReader::read(profile.field("gui")));
        RuntimeReader{values}.read(profile.field("runtime"));
        PluginReader::read(profile.field("plugins"), values.plugins, values.limits);
      }

      Memory& memory_;
      RuntimeValues<Memory>& values_;
    };

    template <Allocator Memory>
    SnapshotReader(Memory& memory, RuntimeValues<Memory>& values) -> SnapshotReader<Memory>;

  }
}

// Interface: telar_config/configuration_layers.cppm
export {
  namespace telar::runtime::config {

    // What a client applies from one configuration table: the root's, or a profile's.
    struct ClientLayerSettings {
      ThemeSelectionSettings themes;
      ClientSettings client;
      GuiSettings gui;
    };

    // The tables a configuration layers for a client: the root and then the selected profile's,
    // which overlays it. Each one is read after SnapshotReader validated the whole configuration.
    class ConfigurationLayers {
    public:
      // Hands `consume` the root and then the selected profile's configuration.
      template <typename Consume>
      inline static void each(const lua::Value& root, std::string_view profile, Consume&& consume) {
        consume(root);
        if (!profile.empty()) {
          const auto profiles = root.field("profiles");
          const auto selected = profiles.entry(profile);

          consume(selected.as("config"));
        }
      }

      // Hands `consume` the root's client table and then the selected profile's, with the root's
      // as the one it inherits from.
      template <typename Consume>
      inline static void clients(const lua::Value& root, std::string_view profile, Consume&& consume) {
        const auto client = root.field("client");

        consume(client, static_cast<const lua::Value*>(nullptr));
        if (!profile.empty()) {
          overlay(root, profile, client, consume);
        }
      }

      // Hands `consume` the client table in effect and the one it inherits from, if any, and
      // returns what `consume` returns.
      template <typename Consume>
      inline static decltype(auto) client(const lua::Value& root, std::string_view profile, Consume&& consume) {
        const auto client = root.field("client");

        if (profile.empty()) {
          return consume(client, static_cast<const lua::Value*>(nullptr));
        }

        return overlay(root, profile, client, consume);
      }

      // Hands each `client.prompt` binding to `binding` in order.
      template <typename Binding>
      [[nodiscard]] inline static ClientLayerSettings read(const lua::Value& configuration, Binding&& binding) {
        return {
            .themes = ThemeReader::selection(configuration),
            .client = ClientReader::read(configuration.field("client"), std::forward<Binding>(binding)),
            .gui = GuiReader::read(configuration.field("gui")),
        };
      }

    private:
      template <typename Consume>
      inline static decltype(auto) overlay(const lua::Value& root, std::string_view profile, const lua::Value& client, Consume& consume) {
        const auto profiles = root.field("profiles");
        const auto selected = profiles.entry(profile);
        const auto configuration = selected.as("config");
        const auto overlay = configuration.field("client");

        return consume(overlay, &client);
      }
    };

  }
}
