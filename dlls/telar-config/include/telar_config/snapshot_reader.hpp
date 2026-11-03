#pragma once

#include "telar_config/client_validator.hpp"
#include "telar_config/gui_validator.hpp"
#include "telar_config/plugin_reader.hpp"
#include "telar_config/runtime_reader.hpp"
#include "telar_config/theme_validator.hpp"

namespace telar::runtime::config {

inline bool validProfileName(std::string_view name) noexcept {
  return !name.empty() && name.size() <= 64 && std::ranges::all_of(name, [](char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-'; });
}

template <Allocator Memory>
class SnapshotReader {
public:
  explicit SnapshotReader(Memory &memory, RuntimeValues<Memory> &values)
      : memory_(memory),
        values_(values) {}

  void read(const lua::Value &root, std::string_view selected_profile) {
    auto state = makeOwned<ClientValidationState>(memory_);
    read(root, selected_profile, *state);
  }

  template <CommandTabStore Commands>
  void read(const lua::Value &root, std::string_view selected_profile, BasicClientValidationState<Commands> &client_state) {
    root.onlyFields({"api_version", "theme", "client", "gui", "runtime", "plugins", "profiles"});
    if (root.field("api_version").integer() != 2) {
      root.fail("requires api_version = 2");
    }

    const auto base_client = root.field("client");
    ThemeValidator::selection(root);
    ClientValidator::validate(base_client, values_.limits, client_state);
    GuiValidator::validate(root.field("gui"));
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

    profiles.eachField([&](std::string_view name, const lua::Value &profile) {
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
  static void readProfile(const lua::Value &profile, RuntimeValues<Memory> &values, const lua::Value &base_client, BasicClientValidationState<Commands> &client_state) {
    profile.onlyFields({"theme", "client", "gui", "runtime", "plugins"});
    ThemeValidator::selection(profile);
    ClientValidator::validate(profile.field("client"), values.limits, client_state, &base_client);
    GuiValidator::validate(profile.field("gui"));
    RuntimeReader{values}.read(profile.field("runtime"));
    PluginReader::read(profile.field("plugins"), values.plugins, values.limits);
  }

  Memory &memory_;
  RuntimeValues<Memory> &values_;
};

template <Allocator Memory>
SnapshotReader(Memory &memory, RuntimeValues<Memory> &values) -> SnapshotReader<Memory>;

}
