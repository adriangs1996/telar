module;
#include "tbc/annotations.hpp"

// What the configuration's interpreter gives the GUI, read into the features' values: the
// actions a binding names and what an extended action describes. Reading them takes the
// interpreter's state and keeps references in its registry, so they live here, beside the
// generation that runs it, and not in a feature.
export module telar.gui.application:configuration_readers;

import std;

import telar.lua;
import telar.config.client;
import telar.gui.foundation.actions;
import telar.gui.foundation.keys;

namespace telar::gui::application {

  // Maps what runtime::config::ExtendedActionReader read onto the GUI's descriptions.
  class ActionDescriptionReader {
  public:
    static ExtendedActionDescription read(const runtime::lua::Value& value, const runtime::config::ClientDefinitions& definitions);

  private:
    static ExtendedActionDescription description(const runtime::config::NotificationActionSetting& setting);
    static ExtendedActionDescription description(const runtime::config::PluginActionSetting& setting);
    static ExtendedActionDescription description(const runtime::config::DefinitionActionSetting& setting);
  };

  class BindingActionReader {
  public:
    explicit BindingActionReader(lua_State& state, const runtime::config::RetainedActionValidator& validator, runtime::config::RetainedCommandTabRegistry& commands, std::uint64_t generation);

    [[nodiscard]] std::optional<BindingAction> read(const runtime::lua::Value& value, bool expression = false) const;

  private:
    [[nodiscard]] BindingAction command(const runtime::config::CommandTabView& command) const;

    // The configuration admits only the names the GUI binds.
    static BindingAction builtin(const runtime::lua::Value& value, std::string_view name);

    [[nodiscard]] BindingAction referenced(const runtime::lua::Value& value, BindingActionKind kind) const;

    lua_State& state_;
    const runtime::config::RetainedActionValidator& validator_;
    runtime::config::RetainedCommandTabRegistry& commands_;
    std::uint64_t generation_;
  };

  template <typename Reader>
  concept BindingActionSource = requires(const Reader& reader, const runtime::lua::Value& value) {
    { reader.read(value, false) } -> std::same_as<std::optional<BindingAction>>;
  };

  class BindingReader {
    using Reader = runtime::config::ClientReader;

  public:
    static_assert(BindingLimits::bindings == runtime::config::BindingReader::maximum_bindings);
    static_assert(BindingLimits::keys == runtime::config::BindingSetting::maximum_keys);

    template <BindingActionSource Actions>
    TBC_GENERIC static void apply(const runtime::lua::Value& client, InputConfiguration& input, const Actions& actions) {
      const auto settings = Reader::input(client);
      if (settings.prefix) {
        input.setPrefix(*settings.prefix);
      }

      constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;

      if (settings.sequence_timeout_ms) {
        input.sequence_timeout_ns = *settings.sequence_timeout_ms * nanoseconds_per_millisecond;
      }

      if (Reader::listsBindings(client)) {
        input.length = 0;
      }

      const auto listed = Reader::bindings(client, input.prefix, [&](const runtime::config::BindingSetting& setting, const runtime::lua::Value& value) {
        KeyBinding<BindingAction> binding{.prefixed = setting.prefixed};

        std::ranges::copy(std::span{setting.keys}.first(setting.length), binding.keys.begin());
        binding.length = setting.length;
        if (const auto action = actions.read(value, setting.expression)) {
          binding.action = *action;
          input.configured[input.length++] = binding;
        }
      });
      if (listed) {
        input.dropped = *listed - std::min(*listed, BindingLimits::bindings);
      }
    }
  };

}
