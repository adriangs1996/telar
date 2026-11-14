module;
#include "tbc/annotations.hpp"

export module telar.config.snapshot;

import std;
export import telar.config.client;
export import telar.config.gui;
export import telar.config.runtime;

// Interface: telar_config/snapshot_reader.cppm
export {
  namespace telar::runtime::config {

    bool validProfileName(std::string_view name) noexcept;

    template <Allocator Memory>
    class SnapshotReader {
    public:
      explicit SnapshotReader(Memory& memory, RuntimeValues<Memory>& values);
      void read(const lua::Value& root, std::string_view selected_profile);

      template <CommandTabStore Commands>
      void read(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<Commands>& client_state);

    private:
      template <CommandTabStore Commands>
      static void readProfile(const lua::Value& profile, RuntimeValues<Memory>& values, const lua::Value& base_client, BasicClientValidationState<Commands>& client_state);

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
    // Stays in the interface: each member is a template over the caller's callable.
    class TBC_HOT_PATH ConfigurationLayers {
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

// SnapshotReader is built in snapshot.cpp for Memory and ConcurrentMemory, with both command tab
// registries.
namespace telar::runtime::config {

  extern template class SnapshotReader<Memory>;
  extern template void SnapshotReader<Memory>::read<CommandTabRegistry>(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<CommandTabRegistry>& client_state);
  extern template void SnapshotReader<Memory>::read<RetainedCommandTabRegistry>(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<RetainedCommandTabRegistry>& client_state);
  extern template class SnapshotReader<ConcurrentMemory>;
  extern template void SnapshotReader<ConcurrentMemory>::read<CommandTabRegistry>(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<CommandTabRegistry>& client_state);
  extern template void SnapshotReader<ConcurrentMemory>::read<RetainedCommandTabRegistry>(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<RetainedCommandTabRegistry>& client_state);

}
