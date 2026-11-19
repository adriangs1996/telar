module telar.config.snapshot;

import std;
import telar.lua;
import telar.config.core;
import telar.plugins;
import telar.base.ds;

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

        auto& plugin = destination.entries.atMut(destination.count);

        plugin.path.assign(path);
        plugin.enabled = specification.field("enabled").boolean(true);
        ++destination.count;
      }
    }
  };

  bool validProfileName(std::string_view name) noexcept {
    return !name.empty() && name.size() <= 64 && std::ranges::all_of(name, [](char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
    });
  }

  template <Allocator Memory>
  SnapshotReader<Memory>::SnapshotReader(Memory& memory, RuntimeValues<Memory>& values)
      : memory_(memory),
        values_(values) {}

  template <Allocator Memory>
  void SnapshotReader<Memory>::read(const lua::Value& root, std::string_view selected_profile) {
    auto state = ds::makeBox<ClientValidationState>(memory_);

    read(root, selected_profile, state.getMut());
  }

  template <Allocator Memory>
  template <CommandTabStore Commands>
  void SnapshotReader<Memory>::read(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<Commands>& client_state) {
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
        auto checked = ds::makeBox<RuntimeValues<Memory>>(memory_, values_.clone());
        const auto saved_commands = client_state.commands.checkpoint();
        const auto saved_keymap = client_state.keymap;

        readProfile(profile.as("config"), checked.getMut(), base_client, client_state);
        client_state.commands.restore(saved_commands);
        client_state.keymap = saved_keymap;
      }
    });

    if (selected_profile.empty()) {
      client_state.keymap.report(values_.limits);
      return;
    }

    ds::Array<char, 65> name{};

    if (!validProfileName(selected_profile)) {
      profiles.fail("has an invalid selected profile name");
    }

    std::copy(selected_profile.begin(), selected_profile.end(), name.dataMut());
    const auto selected = profiles.field(name.data());
    if (!selected.present()) {
      selected.fail("is not defined");
    }

    readProfile(selected.as("config"), values_, base_client, client_state);
    client_state.keymap.report(values_.limits);
  }

  template <Allocator Memory>
  template <CommandTabStore Commands>
  void SnapshotReader<Memory>::readProfile(const lua::Value& profile, RuntimeValues<Memory>& values, const lua::Value& base_client, BasicClientValidationState<Commands>& client_state) {
    profile.onlyFields({"theme", "client", "gui", "runtime", "plugins"});
    static_cast<void>(ThemeReader::selection(profile));
    ClientValidator::validate(profile.field("client"), values.limits, client_state, &base_client);
    static_cast<void>(GuiReader::read(profile.field("gui")));
    RuntimeReader{values}.read(profile.field("runtime"));
    PluginReader::read(profile.field("plugins"), values.plugins, values.limits);
  }

  template class SnapshotReader<Memory>;
  template void SnapshotReader<Memory>::read<CommandTabRegistry>(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<CommandTabRegistry>& client_state);
  template void SnapshotReader<Memory>::read<RetainedCommandTabRegistry>(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<RetainedCommandTabRegistry>& client_state);
  template class SnapshotReader<ConcurrentMemory>;
  template void SnapshotReader<ConcurrentMemory>::read<CommandTabRegistry>(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<CommandTabRegistry>& client_state);
  template void SnapshotReader<ConcurrentMemory>::read<RetainedCommandTabRegistry>(const lua::Value& root, std::string_view selected_profile, BasicClientValidationState<RetainedCommandTabRegistry>& client_state);

}
