#pragma once

#include "action_description_reader.hpp"
#include "action_descriptions.hpp"
#include "action_reader.hpp"
#include "binding_reader.hpp"
#include "callback.hpp"
#include "callback_invocation.hpp"
#include "command_tab_action.hpp"
#include "components/configuration.hpp"
#include "components/invocation.hpp"
#include "components/pick_items.hpp"
#include "components/pick_items_reader.hpp"
#include "components/source.hpp"
#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "gui_config_bootstrap.hpp"
#include "input/action.hpp"
#include "input/binding.hpp"
#include "input/configuration.hpp"
#include "plugin_overrides.hpp"
#include "reader.hpp"
#include "recording_action_reader.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_config/action_validator.hpp"
#include "telar_config/client_definitions.hpp"
#include "telar_config/client_validation_state.hpp"
#include "telar_config/command_tab_registry.hpp"
#include "telar_config/command_tab_view.hpp"
#include "telar_config/key_chord_validator.hpp"
#include "telar_config/limit_notices.hpp"
#include "telar_config/local_modules.hpp"
#include "telar_config/runtime_values.hpp"
#include "telar_config/snapshot_reader.hpp"
#include "telar_lua/json.hpp"
#include "telar_lua/value.hpp"
#include "telar_lua/vm.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <lauxlib.h>
#include <lua.h>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <variant>

namespace telar::gui {

struct ConfigurationSourceText {
  std::string_view source;
  std::string_view directory;
  std::string_view profile;
  std::uint64_t generation = 1;
  const PluginOverrides *plugin_overrides = nullptr;
};

template <Allocator Memory>
class ConfigurationGeneration {
public:
  explicit ConfigurationGeneration(Memory &memory, ConfigurationSourceText source)
      : machine_(memory),
        runtime_(makeOwned<runtime::config::RuntimeValues<Memory>>(memory, memory)),
        components_(makeOwned<components::Configuration>(memory, *machine_.state())),
        descriptions_(memory),
        number_(source.generation) {
    profile_.assign(source.profile);
    machine_.execute(config_bootstrap, "@telar/bootstrap.lua", 0);
    lua_getglobal(machine_.state(), "telar");
    runtime::lua::JsonDecoder<Memory>::install(machine_.state(), memory);
    lua_pop(machine_.state(), 1);
    modules_.emplace(machine_.state(), source.directory);
    machine_.execute(source.source, "@config.lua");
    readConfiguration(memory, source.plugin_overrides);
    lua_settop(machine_.state(), 0);
  }

  [[nodiscard]] const Configuration &configuration() const noexcept {
    return configuration_;
  }

  [[nodiscard]] std::uint64_t number() const noexcept {
    return number_;
  }

  [[nodiscard]] const components::Configuration &components() const noexcept {
    return *components_;
  }

  void renderBar(components::Position position, const components::Context &context) {
    const auto &source = components_->definitions().source(position);
    renderComponents(source, context, [&](const auto &value, const auto &actions) {
      components_->readBar(position, value, actions, notices_);
    });
  }

  void renderPanel(std::size_t index, const components::Context &context) {
    const auto panels = components_->definitions().panels();
    if (index >= panels.size()) {
      throw std::invalid_argument{"Panel is no longer configured"};
    }

    renderComponents(panels[index].source, context, [&](const auto &value, const auto &actions) {
      components_->readPanel(value, actions, notices_);
    });
  }

  void closePanel() noexcept {
    components_->closePanel();
  }

  void renderPick(std::size_t index, const components::Context &context, components::PickItems &items) {
    const auto picks = components_->definitions().picks();
    if (index >= picks.size()) {
      throw std::invalid_argument{"Pick is no longer configured"};
    }

    const auto &pick = picks[index];
    if (pick.command && !pick.render) {
      components::PickItemsReader::lines(context.output.value_or(std::string_view{}), items, notices_);

      return;
    }

    lua_settop(machine_.state(), 0);
    try {
      if (pick.render) {
        constexpr std::uint64_t pick_instructions = 1'000'000;
        constexpr std::chrono::milliseconds pick_deadline{100};
        machine_.resetBudget(pick_instructions, pick_deadline);
        components::Invocation invocation{pick.reference, context, "items"};
        machine_.invoke(&components::Invocation::invoke, &invocation, 1);
        const runtime::lua::Value result{machine_.state(), -1, "pick items"};
        components::PickItemsReader::read(result, items, notices_);
      } else {
        const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "pick registry"};
        components::PickItemsReader::read(registry.element(pick.reference).field("items"), items, notices_);
      }
    } catch (...) {
      lua_settop(machine_.state(), 0);

      throw;
    }

    lua_settop(machine_.state(), 0);
  }

  template <typename Visitor>
  void visitArguments(int reference, const char *field, const Visitor &visit) const {
    const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "source registry"};
    const auto source = registry.element(reference);
    const auto command = source.field(field);
    const auto count = command.listLength();
    for (std::size_t index = 0; index < count; ++index) {
      visit(command.element(static_cast<lua_Integer>(index) + 1).string());
    }
  }

  [[nodiscard]] const runtime::config::RuntimeValues<Memory> &runtimeValues() const noexcept {
    return *runtime_;
  }

  [[nodiscard]] const ActionDescriptions<Memory> &actionDescriptions() const noexcept {
    return descriptions_;
  }

  [[nodiscard]] const runtime::config::RetainedCommandTabRegistry &commandTabs() const noexcept {
    return client_state_.commands;
  }

  [[nodiscard]] std::optional<runtime::config::CommandTabView> commandTab(BindingAction action) const {
    if (action.generation != number_ || action.kind != BindingActionKind::command_tab) {
      throw std::invalid_argument{"Command belongs to an obsolete configuration or a different binding kind"};
    }

    const auto reference = commandTabReference(action);

    return reference ? client_state_.commands.load(*reference) : std::nullopt;
  }

  [[nodiscard]] std::optional<NotificationActionDescription> notificationAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto *notification = description ? std::get_if<NotificationActionDescription>(&*description) : nullptr;

    return notification == nullptr ? std::nullopt : std::optional{*notification};
  }

  [[nodiscard]] const InputConfiguration &input() const noexcept {
    return input_;
  }

  [[nodiscard]] std::optional<PluginActionDescription> pluginAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto *plugin = description ? std::get_if<PluginActionDescription>(&*description) : nullptr;

    return plugin == nullptr ? std::nullopt : std::optional{*plugin};
  }

  [[nodiscard]] std::optional<DefinitionActionDescription> definitionAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto *definition = description ? std::get_if<DefinitionActionDescription>(&*description) : nullptr;

    return definition == nullptr ? std::nullopt : std::optional{*definition};
  }

  [[nodiscard]] std::optional<NamedActionDescription> namedAction(BindingAction action) const {
    const auto description = extendedAction(action);
    if (!description) {
      return std::nullopt;
    }

    if (const auto *definition = std::get_if<DefinitionActionDescription>(&*description)) {
      return *definition;
    }

    if (const auto *plugin = std::get_if<PluginActionDescription>(&*description)) {
      return *plugin;
    }

    return std::nullopt;
  }

  template <typename Visitor>
  void visitPluginActions(const Visitor &visitor) const {
    const auto visit = [&](BindingAction action) {
      if (const auto plugin = pluginAction(action)) {
        visitor(*plugin);
      }
    };
    for (const auto &binding : std::span{input_.configured}.first(input_.length)) {
      visit(binding.action);
    }

    components_->visitActions(visit);
  }

  [[nodiscard]] const BindingMap<BindingAction> &keymap() const noexcept {
    return keymap_;
  }

  template <typename Visitor>
  void visitLocalModules(Visitor &&visit) const {
    if (modules_) {
      modules_->visitLoadedNames(machine_.state(), std::forward<Visitor>(visit));
    }
  }

  [[nodiscard]] std::size_t localModuleCount() const noexcept {
    return modules_ ? modules_->configurationModuleCount() : 0;
  }

  BindingEffects invoke(BindingAction action, BindingContext context) {
    static_cast<void>(callbackBinding(action, BindingActionKind::callback));
    invokeFunction(action.reference, context);
    const runtime::lua::Value result{machine_.state(), -1, "callback result"};

    return withActions([&](const auto &reader) {
      return effects(result, reader);
    });
  }

  InputExpression expression(BindingAction action, BindingContext context) {
    const auto &binding = callbackBinding(action, BindingActionKind::expression);
    invokeFunction(action.reference, context);
    const runtime::lua::Value result{machine_.state(), -1, "expression result"};
    const auto kind_value = result.field("input_kind");
    const auto kind = kind_value.string();
    InputExpression decision;
    if (kind == "consume" || kind == "forward") {
      result.onlyFields({"input_kind"});
      decision.kind = kind == "consume" ? InputExpression::Kind::consume : InputExpression::Kind::forward;
      if (kind == "forward") {
        std::ranges::copy(binding.sequence(), decision.keys.begin());
        decision.length = binding.length;
      }
    } else if (kind == "keys") {
      result.onlyFields({"input_kind", "keys"});
      decision.kind = InputExpression::Kind::keys;
      readKeys(result.field("keys"), decision);
    } else if (kind == "paste") {
      result.onlyFields({"input_kind", "text"});
      decision.kind = InputExpression::Kind::paste;
      decision.paste.assign(result.field("text").string());
    } else {
      kind_value.fail("names an unknown input decision");
    }

    return decision;
  }

private:
  static constexpr std::size_t maximum_profile_bytes = 64;

  template <typename Consumer>
  void renderComponents(const components::Source &source, const components::Context &context, const Consumer &consume) {
    if (source.kind != components::SourceKind::dynamic && source.kind != components::SourceKind::command) {
      throw std::invalid_argument{"Source has no render callback or command"};
    }

    client_state_.commands.beginRender();
    const auto checkpoint = client_state_.commands.checkpoint();
    try {
      lua_settop(machine_.state(), 0);
      if (source.has_render) {
        constexpr std::uint64_t render_instructions = 100'000;
        constexpr std::chrono::milliseconds render_deadline{100};
        machine_.resetBudget(render_instructions, render_deadline);
        components::Invocation invocation{source.reference, context};
        machine_.invoke(&components::Invocation::invoke, &invocation, 1);
      } else {
        const auto output = context.output.value_or(std::string_view{});
        lua_pushlstring(machine_.state(), output.data(), output.size());
      }

      const runtime::lua::Value result{machine_.state(), -1, "component render result"};
      withActions([&](const auto &actions) {
        consume(result, actions);
      });
    } catch (...) {
      client_state_.commands.restore(checkpoint);
      client_state_.commands.endRender();
      lua_settop(machine_.state(), 0);

      throw;
    }

    client_state_.commands.endRender();
    lua_settop(machine_.state(), 0);
  }

  [[nodiscard]] std::optional<ExtendedActionDescription> extendedAction(BindingAction action) const {
    if (action.kind != BindingActionKind::extended) {
      return std::nullopt;
    }

    if (action.generation != number_) {
      throw std::invalid_argument{"Action belongs to an obsolete configuration"};
    }

    const auto configured = std::span{input_.configured}.first(input_.length);
    if (std::ranges::find(configured, action, &KeyBinding<BindingAction>::action) != configured.end()) {
      return descriptions_.at(action.parameter);
    }

    const auto transient = std::span{transient_references_}.first(transient_count_);
    if (!components_->contains(action) && (action.parameter != 0 || !std::ranges::contains(transient, action.reference))) {
      throw std::invalid_argument{"Action is no longer retained"};
    }

    const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "action registry"};
    const auto value = registry.element(action.reference);

    return withDefinitions([&](const auto &definitions) {
      return ActionDescriptionReader::read(value, definitions);
    });
  }

  template <typename Consumer>
  auto withDefinitions(Consumer &&consume) const {
    const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "configuration registry"};
    const auto root = registry.element(root_reference_);
    const auto client = root.field("client");
    if (profile_.view().empty()) {
      const runtime::config::ClientDefinitions definitions{client};

      return std::forward<Consumer>(consume)(definitions);
    }

    const auto profiles = root.field("profiles");
    const auto selected = profiles.entry(profile_.view());
    const auto overlay = selected.field("client");
    const runtime::config::ClientDefinitions definitions{overlay, &client};

    return std::forward<Consumer>(consume)(definitions);
  }

  void readConfiguration(Memory &memory, const PluginOverrides *overrides) {
    const runtime::lua::Value root{machine_.state(), -1, "config"};
    runtime::config::SnapshotReader{memory, *runtime_}.read(root, profile_.view(), client_state_);
    validateUtf8(runtime_->history_path);
    validateUtf8(runtime_->session_path);
    validateUtf8(runtime_->proxy.authority_directory);
    configuration_ = ConfigurationReader::read(root, profile_.view());
    root.pushCopy();
    root_reference_ = luaL_ref(machine_.state(), LUA_REGISTRYINDEX);
    const auto client = root.field("client");
    readClient(client);
    if (!profile_.view().empty()) {
      const auto profiles = root.field("profiles");
      const auto selected = profiles.entry(profile_.view());
      const auto overlay = selected.field("client");
      readClient(overlay, &client);
    }

    if (overrides != nullptr) {
      overrides->apply(runtime_->plugins);
      removeDisabledPluginBindings(*overrides);
    }

    rebindDefinitions();
    keymap_ = input_.compile();
    withActions([&](const auto &reader) {
      components_->readFixed(reader, notices_);
    });
    client_state_.commands.seal();
  }

  void removeDisabledPluginBindings(const PluginOverrides &overrides) {
    std::size_t retained = 0;
    for (const auto &binding : std::span{input_.configured}.first(input_.length)) {
      if (binding.action.kind == BindingActionKind::extended) {
        const auto *plugin = std::get_if<PluginActionDescription>(&descriptions_.at(binding.action.parameter));
        if (plugin != nullptr && overrides.disabled(plugin->plugin, runtime_->plugins.configured())) {
          continue;
        }
      }

      input_.configured[retained] = binding;
      ++retained;
    }

    input_.length = retained;
  }

  // A profile can replace named definitions while inheriting its keybindings.
  void rebindDefinitions() {
    const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "binding registry"};
    for (const auto &binding : std::span{input_.configured}.first(input_.length)) {
      const auto action = binding.action;
      if (action.kind != BindingActionKind::extended || !std::holds_alternative<DefinitionActionDescription>(descriptions_.at(action.parameter))) {
        continue;
      }

      const auto value = registry.element(action.reference);
      const auto description = withDefinitions([&](const auto &definitions) {
        return ActionDescriptionReader::read(value, definitions);
      });
      descriptions_.replaceDefinition(action.parameter, std::get<DefinitionActionDescription>(description));
    }
  }

  void readClient(const runtime::lua::Value &client, const runtime::lua::Value *inherited = nullptr) {
    components_->definitions().apply(*machine_.state(), client);
    const runtime::config::ClientDefinitions definitions{client, inherited};
    const runtime::config::RetainedActionValidator validator{definitions, notices_, client_state_.commands};
    const BindingActionReader reader{*machine_.state(), validator, client_state_.commands, number_};
    if (client.present() && client.field("keybindings").present()) {
      descriptions_.replaceBindings();
    }

    const RecordingActionReader actions{reader, descriptions_, definitions};
    BindingReader::apply(client, input_, actions);
  }

  template <typename Consumer>
  auto withActions(Consumer &&consume) {
    lua_rawgeti(machine_.state(), LUA_REGISTRYINDEX, root_reference_);
    const runtime::lua::Value root{machine_.state(), -1, "config"};
    const auto client = root.field("client");
    if (profile_.view().empty()) {
      const runtime::config::ClientDefinitions definitions{client};
      const runtime::config::RetainedActionValidator validator{definitions, notices_, client_state_.commands};
      const BindingActionReader reader{*machine_.state(), validator, client_state_.commands, number_};

      return std::forward<Consumer>(consume)(reader);
    }

    const auto profiles = root.field("profiles");
    const auto selected = profiles.entry(profile_.view());
    const auto overlay = selected.field("client");
    const runtime::config::ClientDefinitions definitions{overlay, &client};
    const runtime::config::RetainedActionValidator validator{definitions, notices_, client_state_.commands};
    const BindingActionReader reader{*machine_.state(), validator, client_state_.commands, number_};

    return std::forward<Consumer>(consume)(reader);
  }

  [[nodiscard]] const KeyBinding<BindingAction> &callbackBinding(BindingAction action, BindingActionKind kind) const {
    if (action.generation != number_ || action.kind != kind) {
      throw std::invalid_argument{"Callback belongs to an obsolete configuration or a different binding kind"};
    }

    const auto active = std::span{input_.configured}.first(input_.length);
    const auto found = std::ranges::find(active, action, &KeyBinding<BindingAction>::action);
    if (found == active.end()) {
      throw std::invalid_argument{"Callback is no longer bound"};
    }

    return *found;
  }

  void invokeFunction(int reference, BindingContext context) {
    constexpr std::uint64_t callback_instructions = 100'000;
    constexpr std::chrono::milliseconds callback_deadline{100};
    for (const auto reference : std::span{transient_references_}.first(transient_count_)) {
      luaL_unref(machine_.state(), LUA_REGISTRYINDEX, reference);
    }

    transient_count_ = 0;
    lua_settop(machine_.state(), 0);
    machine_.resetBudget(callback_instructions, callback_deadline);
    CallbackInvocation invocation{reference, context};
    machine_.invoke(&CallbackInvocation::invoke, &invocation, 1);
  }

  static void readKeys(const runtime::lua::Value &keys, InputExpression &decision) {
    const auto count = keys.listLength();
    if (count == 0 || count > InputExpression::maximum_keys) {
      keys.fail("must contain one to sixteen keys");
    }

    for (std::size_t index = 0; index < count; ++index) {
      decision.keys[index] = runtime::config::KeyChordValidator::parse(keys.element(static_cast<lua_Integer>(index) + 1));
    }

    decision.length = count;
  }

  BindingEffects effects(const runtime::lua::Value &result, const BindingActionReader &reader) {
    if (!result.is(LUA_TTABLE)) {
      result.fail("must be an action or an array of actions");
    }

    BindingEffects batch;
    const auto kind = result.field("kind");
    if (kind.present()) {
      appendEffect(result, reader, batch);

      return batch;
    }

    const auto count = result.listLength();
    batch.dropped = count - std::min(count, BindingEffects::maximum_effects);
    for (std::size_t index = 0; index < std::min(count, BindingEffects::maximum_effects); ++index) {
      appendEffect(result.element(static_cast<lua_Integer>(index) + 1), reader, batch);
    }

    return batch;
  }

  void appendEffect(const runtime::lua::Value &value, const BindingActionReader &reader, BindingEffects &batch) {
    if (value.is(LUA_TFUNCTION)) {
      value.fail("cannot return a recursive callback");
    }

    if (auto action = reader.read(value)) {
      if (action->kind == BindingActionKind::extended) {
        transient_references_[transient_count_++] = action->reference;
      }

      batch.actions[batch.length++] = *action;
    } else {
      ++batch.dropped;
    }
  }

  runtime::lua::Vm<Memory> machine_;
  Owned<runtime::config::RuntimeValues<Memory>, Memory> runtime_;
  Owned<components::Configuration, Memory> components_;
  std::optional<runtime::config::LocalModules> modules_;
  runtime::config::LimitNotices notices_;
  runtime::config::RetainedClientValidationState client_state_;
  ActionDescriptions<Memory> descriptions_;
  runtime::FixedText<maximum_profile_bytes> profile_;
  Configuration configuration_;
  InputConfiguration input_;
  BindingMap<BindingAction> keymap_;
  std::uint64_t number_;
  int root_reference_ = LUA_NOREF;
  std::array<int, BindingEffects::maximum_effects> transient_references_{};
  std::size_t transient_count_ = 0;
};

}
