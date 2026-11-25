module;
#include "tbc/annotations.hpp"

export module telar.gui.application:configuration;

import std;
import telar.tbc;
import telar.gui.features.plugins;
import telar.gui.foundation.actions;
import telar.lua;
import telar.gui.foundation.keys;
import telar.gui.foundation.core;
import telar.gui.features.components;
import telar.plugins;
import telar.wire.vocabulary;
import telar.wire.pane_io;
import telar.base.memory.allocators;
import telar.config.core;
import telar.config.gui;
import telar.config.client;
import telar.config.runtime;
import telar.base.memory.containers;
import :client_view_state;
import :session;
import telar.gui.features.configuration;
import :configuration_readers;
import telar.base.ds;

namespace telar::gui::application::configuration_bounds {

  // Whether a GUI limit is exactly the configuration's, which may keep it in another number type.
  consteval bool follows(auto limit, auto bound) {
    return std::equal_to<>{}(limit, bound);
  }

}

// Interface: config/reader.cppm
export {
  namespace telar::gui::application {

    // The GUI keeps its own limits for what it clamps at run time; they follow the configuration's.
    namespace configuration_bounds {
      using runtime::config::GuiBounds;
      static_assert(follows(FontConfiguration::minimum_size, GuiBounds::font_size.minimum) && follows(FontConfiguration::maximum_size, GuiBounds::font_size.maximum));
      static_assert(follows(FontConfiguration::minimum_line_height, GuiBounds::line_height.minimum) && follows(FontConfiguration::maximum_line_height, GuiBounds::line_height.maximum));
      static_assert(follows(FontConfiguration::minimum_letter_spacing, GuiBounds::letter_spacing.minimum) && follows(FontConfiguration::maximum_letter_spacing, GuiBounds::letter_spacing.maximum));
      static_assert(follows(FontConfiguration::maximum_thicken_strength, GuiBounds::thicken_strength.maximum));
      static_assert(follows(Configuration::minimum_blink_interval.count(), GuiBounds::blink_interval_ms.minimum) && follows(Configuration::maximum_blink_interval.count(), GuiBounds::blink_interval_ms.maximum));
      static_assert(follows(ScrollConfiguration::maximum_wheel_ms, GuiBounds::wheel_ms.maximum) && follows(ScrollConfiguration::maximum_overscan, GuiBounds::overscan.maximum));
      static_assert(follows(Configuration::minimum_sidebar_width, GuiBounds::sidebar_width.minimum) && follows(Configuration::maximum_sidebar_width, GuiBounds::sidebar_width.maximum));
      static_assert(follows(Configuration::minimum_chrome_scale, GuiBounds::chrome_scale.minimum) && follows(Configuration::maximum_chrome_scale, GuiBounds::chrome_scale.maximum));
      static_assert(follows(Configuration::maximum_padding, GuiBounds::padding.maximum) && follows(Configuration::maximum_background_blur, GuiBounds::background_blur.maximum));
      static_assert(follows(Configuration::minimum_fps, GuiBounds::max_fps.minimum) && follows(Configuration::maximum_fps, GuiBounds::max_fps.maximum));
      static_assert(follows(PromptConfiguration::maximum_max_lines, runtime::config::PromptBounds::max_lines.maximum));
      static_assert(PromptBindings::capacity == runtime::config::PromptBounds::bindings);
      // The enums follow the configuration's name tables.
      static_assert(std::to_underlying(FontHinting::full) == std::to_underlying(runtime::config::FontHinting::full));
      static_assert(std::to_underlying(PromptMode::telar) == std::to_underlying(runtime::config::PromptMode::telar));
      static_assert(std::to_underlying(PromptMotion::none) == std::to_underlying(runtime::config::PromptMotion::none));
      static_assert(std::to_underlying(PromptKeymap::vim) == std::to_underlying(runtime::config::PromptKeymap::vim));
      static_assert(std::to_underlying(CursorShape::hollow) == std::to_underlying(runtime::config::CursorStyle::hollow) + 1);
      static_assert(BackgroundOpacity::names.size() == runtime::config::surface_names.size());
    }

    class ConfigurationReader {
    public:
      // Maps a configuration runtime::config::SnapshotReader already validated, profile included.
      static Configuration read(const runtime::lua::Value& root, std::string_view profile);

      // The themes the picker lists and the command it runs, from every layer in order.
      static void themePicker(const runtime::lua::Value& root, std::string_view profile, features::configuration::ThemePicker& picker);

    private:
      using ClientSettings = runtime::config::ClientSettings;

      template <typename To, typename From>
      static To mapped(From value) noexcept;

      static void gui(const runtime::config::GuiSettings& gui, Configuration& configuration);
      static void client(const ClientSettings& settings, Configuration& configuration);
      static void sound(const ClientSettings::Sound& settings, SoundPolicy& policy) noexcept;
      static void prompt(const runtime::config::PromptSettings& settings, const PromptBindings& bindings, PromptConfiguration& prompt);
      static void history(const ClientSettings::History& settings, HistoryConfiguration& history) noexcept;
      static void font(const runtime::config::GuiSettings::Font& settings, FontConfiguration& font);
      static void window(const runtime::config::GuiSettings::Window& settings, Configuration& configuration);

      // CursorShape leads with the terminal's default, which a configuration cannot choose.
      static CursorShape cursorShape(runtime::config::CursorStyle style) noexcept;
    };

  }
}

// Interface: config/generation.cppm
export {
  namespace telar::gui::application {

    struct ConfigurationSourceText {
      std::string_view source;
      std::string_view directory;
      std::string_view profile;
      std::uint64_t generation = 1;
      const features::plugins::PluginOverrides* plugin_overrides = nullptr;
    };

    template <Allocator Memory>
    class ConfigurationGeneration {
    public:
      // The generation allocates from memory, region `a`, and copies its source.
      explicit ConfigurationGeneration(tbc::mut_a<Memory> memory, ConfigurationSourceText source);

      [[nodiscard]] const Configuration& configuration() const noexcept;

      // Safe on the window thread: fixed when the generation loads.
      [[nodiscard]] const features::configuration::ThemePicker& themePicker() const noexcept;

      [[nodiscard]] std::uint64_t number() const noexcept;

      [[nodiscard]] const ComponentConfiguration& components() const noexcept;

      void renderBar(features::components::Position position, const features::components::Context& context);

      void renderPanel(std::size_t index, const features::components::Context& context);

      void closePanel() noexcept;

      // The members below until configuredAction run on the Lua thread: they read or run the VM.
      [[nodiscard]] ds::Box<features::components::RenderedContent<features::components::BarContent::capacity, Memory>, Memory> renderedBar(features::components::Position position, const features::components::Context& context);

      [[nodiscard]] ds::Box<features::components::RenderedContent<features::components::PanelContent::capacity, Memory>, Memory> renderedPanel(std::size_t index, const features::components::Context& context);

      // Instantiated for the bar's and the panel's capacities.
      template <features::components::Capacity Bounds>
      // The copy allocates from memory, region `b`.
      [[nodiscard]] tbc::val_b<ds::Box<features::components::RenderedContent<Bounds, Memory>, Memory>> copied(tbc::mut_b<Memory> memory, const features::components::Content<Bounds>& content) const;

      [[nodiscard]] features::components::ResolvedAction resolve(BindingAction action) const;

      [[nodiscard]] ds::Box<features::components::ResolvedEffects<Memory>, Memory> invokeResolved(BindingAction action, BindingContext context);

      // Calls a slot's function with the context and the item, a JSON document, and reads the
      // element tree it returns. The instance keeps the `on_click` functions of its last render.
      [[nodiscard]] ds::Box<features::components::RenderedElements<Memory>, Memory> renderElements(features::components::Slot slot, std::uint64_t instance, const features::components::Context& context, std::string_view item);

      // One `on_click` function of an instance's last render.
      struct ElementCallback {
        std::uint64_t instance = 0;
        std::uint32_t callback = 0;
      };

      // Runs one `on_click` function of the instance's last render and resolves what it returns.
      [[nodiscard]] ds::Box<features::components::ResolvedEffects<Memory>, Memory> invokeElement(ElementCallback target, const features::components::Context& context, std::string_view item);

      void forgetElements(std::uint64_t instance) noexcept;

      // Safe on the window thread: configured bindings are fixed when the generation loads.
      [[nodiscard]] ds::Option<ExtendedActionDescription> configuredAction(BindingAction action) const;

      void renderPick(std::size_t index, const features::components::Context& context, features::components::PickItems& items);

      template <typename Visitor>
      TBC_GENERIC void visitArguments(int reference, const char* field, const Visitor& visit) const {
        const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "source registry"};

        runtime::config::CommandArgumentsReader::read(registry.element(reference), field, visit);
      }

      [[nodiscard]] const runtime::config::RuntimeValues<Memory>& runtimeValues() const noexcept;

      [[nodiscard]] const ActionDescriptions<Memory>& actionDescriptions() const noexcept;

      [[nodiscard]] const runtime::config::RetainedCommandTabRegistry& commandTabs() const noexcept;

      [[nodiscard]] ds::Option<runtime::config::CommandTabView> commandTab(BindingAction action) const;

      [[nodiscard]] ds::Option<NotificationActionDescription> notificationAction(BindingAction action) const;

      [[nodiscard]] const InputConfiguration& input() const noexcept;

      [[nodiscard]] ds::Option<PluginActionDescription> pluginAction(BindingAction action) const;

      [[nodiscard]] ds::Option<DefinitionActionDescription> definitionAction(BindingAction action) const;

      [[nodiscard]] ds::Option<NamedActionDescription> namedAction(BindingAction action) const;

      template <typename Visitor>
      TBC_GENERIC void visitPluginActions(const Visitor& visitor) const {
        const auto visit = [&](BindingAction action) {
          if (const auto plugin = pluginAction(action)) {
            visitor(*plugin);
          }
        };

        for (const auto& binding : std::span{input_.configured}.first(input_.length)) {
          visit(binding.action);
        }

        components_->visitActions(visit);
      }

      [[nodiscard]] const BindingMap<BindingAction>& keymap() const noexcept;

      template <typename Visitor>
      TBC_GENERIC void visitLocalModules(Visitor&& visit) const {
        if (modules_) {
          modules_->visitLoadedNames(machine_.state(), std::forward<Visitor>(visit));
        }
      }

      [[nodiscard]] std::size_t localModuleCount() const noexcept;

      BindingEffects invoke(BindingAction action, BindingContext context);

      InputExpression expression(BindingAction action, BindingContext context);

    private:
      static constexpr std::size_t maximum_profile_bytes = 64;
      // Calls run on the Lua thread, so the bound only keeps a runaway loop from holding the queue.
      static constexpr std::uint64_t lua_call_instructions = 50'000'000;
      static constexpr std::chrono::seconds lua_call_deadline{1};

      template <typename Consumer>
      void renderComponents(const features::components::Source& source, const features::components::Context& context, const Consumer& consume);

      struct ElementHandlers {
        std::uint64_t instance = 0;
        ds::Vec<int, Memory> references;
      };

      ElementHandlers& handlersOf(std::uint64_t instance);

      // Reads an element's `on_click` action table and resolves it at once. Its registry entry is
      // released here, so the action carries a reference private to its element tree.
      ds::Option<features::components::ResolvedAction> elementAction(const runtime::lua::Value& value, std::uint32_t index);

      [[nodiscard]] ds::Option<ExtendedActionDescription> extendedAction(BindingAction action) const;

      template <typename Consumer>
      auto withDefinitions(Consumer&& consume) const;

      void readConfiguration(tbc::mut_a<Memory> memory, const features::plugins::PluginOverrides* overrides);

      void removeDisabledPluginBindings(const features::plugins::PluginOverrides& overrides);

      // A profile can replace named definitions while inheriting its keybindings.
      void rebindDefinitions();

      void readClient(const runtime::lua::Value& client, const runtime::lua::Value* inherited);

      template <typename Consumer>
      auto withActions(Consumer&& consume);

      [[nodiscard]] const KeyBinding<BindingAction>& callbackBinding(BindingAction action, BindingActionKind kind) const;

      void invokeFunction(int reference, BindingContext context);

      BindingEffects effects(const runtime::lua::Value& result, BindingActionReader& reader);

      tbc::mut_a<Memory> memory_;
      tbc::val_a<runtime::lua::Vm<Memory>> machine_;
      tbc::val_a<ds::Box<runtime::config::RuntimeValues<Memory>, Memory>> runtime_;
      tbc::val_a<ds::Box<ComponentConfiguration, Memory>> components_;
      tbc::val_a<ds::Box<features::configuration::ThemePicker, Memory>> theme_picker_;
      ds::Option<runtime::config::LocalModules> modules_;
      runtime::config::LimitNotices notices_;
      runtime::config::RetainedClientValidationState client_state_;
      tbc::val_a<ActionDescriptions<Memory>> descriptions_;
      runtime::FixedText<maximum_profile_bytes> profile_;
      Configuration configuration_;
      InputConfiguration input_;
      BindingMap<BindingAction> keymap_;
      std::uint64_t number_;
      int root_reference_ = LUA_NOREF;
      ds::Array<int, BindingEffects::maximum_effects> transient_references_{};
      std::size_t transient_count_ = 0;
      tbc::val_a<ds::Vec<ElementHandlers, Memory>> element_handlers_{memory_};
    };

    extern template class ConfigurationGeneration<telar::Memory>;
    extern template class ConfigurationGeneration<telar::ConcurrentMemory>;

    extern template tbc::val_b<ds::Box<features::components::RenderedContent<features::components::BarContent::capacity, telar::Memory>, telar::Memory>> ConfigurationGeneration<telar::Memory>::copied<features::components::BarContent::capacity>(tbc::mut_b<telar::Memory> memory, const features::components::Content<features::components::BarContent::capacity>& content) const;
    extern template tbc::val_b<ds::Box<features::components::RenderedContent<features::components::PanelContent::capacity, telar::Memory>, telar::Memory>> ConfigurationGeneration<telar::Memory>::copied<features::components::PanelContent::capacity>(tbc::mut_b<telar::Memory> memory, const features::components::Content<features::components::PanelContent::capacity>& content) const;
    extern template tbc::val_b<ds::Box<features::components::RenderedContent<features::components::BarContent::capacity, telar::ConcurrentMemory>, telar::ConcurrentMemory>> ConfigurationGeneration<telar::ConcurrentMemory>::copied<features::components::BarContent::capacity>(tbc::mut_b<telar::ConcurrentMemory> memory, const features::components::Content<features::components::BarContent::capacity>& content) const;
    extern template tbc::val_b<ds::Box<features::components::RenderedContent<features::components::PanelContent::capacity, telar::ConcurrentMemory>, telar::ConcurrentMemory>> ConfigurationGeneration<telar::ConcurrentMemory>::copied<features::components::PanelContent::capacity>(tbc::mut_b<telar::ConcurrentMemory> memory, const features::components::Content<features::components::PanelContent::capacity>& content) const;

  }
}

// Interface: config/client_query.cppm
export {
  namespace telar::gui::application {

    struct ClientQueryContext {
      ds::Option<std::string_view> source;
      ds::Option<std::string_view> profile;
      std::uint64_t generation = 0;
      ClientViewState view;
      // Whether the platform draws the window's titlebar when the configuration names none.
      bool default_titlebar = false;
    };

    class ClientQuery {
    public:
      // Each query is written into the output, region `a`.
      [[nodiscard]] static tbc::val_a<std::string_view> write(const Configuration& configuration, const ClientQueryContext& context, tbc::val_a<std::span<char>> output);

    private:
      static void writeOptionalBytes(JsonWriter& writer, ds::Option<std::string_view> text);
      static void writeSound(JsonWriter& writer, SoundPolicy policy);
      static void writeSections(JsonWriter& writer);
    };

  }
}

// The configuration as ui drives it: the section of a loaded configuration a client asks for,
// the themes it names, and the configuration and theme the session shows.
export namespace telar::gui::application::configuration {

  using features::configuration::commandTabReference;
  using features::configuration::ConfigurationQuery;
  using features::configuration::default_theme_values;
  using features::configuration::lightTheme;
  using features::configuration::ThemeCatalog;
  using features::configuration::ThemeChoice;
  using features::configuration::ThemeCommand;
  using features::configuration::ThemeEntry;
  using features::configuration::themeFingerprint;
  using features::configuration::ThemePicker;
  using features::configuration::themeValuesByName;

  // The session shows `configuration` from now on; a new prompt mode configures the shells again.
  void configure(Session& session, const Configuration& configuration);

  // The session shows `theme`, picked by the system's appearance, without reading the
  // configuration again.
  void setTheme(Session& session, const Theme& theme);

  // `theme` as a pane's programs read it: the terminal's colors and the editor colors, every
  // color the theme leaves to the terminal resolved against it.
  [[nodiscard]] ConfigureTerminalColors terminalColors(const Theme& theme) noexcept;

  // Gives the runtime the theme the session shows, for the programs in the panes of the
  // workspaces whose geometry it owns. A runtime before schema cqp00005 cannot hear it.
  void configureTerminal(Session& session);

  // Writes the section of the loaded configuration `query` names, the binding at its index or
  // the client's state in `context`, into the output, region `a`. `commands` holds the command
  // tabs the generation's bindings name.
  template <Allocator Memory>
  [[nodiscard]] tbc::val_a<std::string_view> query(
      const ConfigurationGeneration<Memory>& generation,
      const runtime::config::RetainedCommandTabRegistry& commands,
      ConfigurationQuery query,
      const ClientQueryContext& context,
      tbc::val_a<std::span<char>> output
  );

  extern template tbc::val_a<std::string_view> query<telar::Memory>(const ConfigurationGeneration<telar::Memory>& generation, const runtime::config::RetainedCommandTabRegistry& commands, ConfigurationQuery query, const ClientQueryContext& context, tbc::val_a<std::span<char>> output);
  extern template tbc::val_a<std::string_view> query<telar::ConcurrentMemory>(const ConfigurationGeneration<telar::ConcurrentMemory>& generation, const runtime::config::RetainedCommandTabRegistry& commands, ConfigurationQuery query, const ClientQueryContext& context, tbc::val_a<std::span<char>> output);

}
