module telar.gui.application;

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
import telar.config.snapshot;
import telar.gui.features.configuration;
import telar.gui.features.notifications;
import telar.base.ds;

namespace telar::gui::application {

  namespace {

    constexpr std::string_view config_bootstrap{
#include "gui_config_bootstrap.inc"
    };

  }

  template <typename To, typename From>
  To ConfigurationReader::mapped(From value) noexcept {
    return static_cast<To>(std::to_underlying(value));
  }

  Configuration ConfigurationReader::read(const runtime::lua::Value& root, std::string_view profile) {
    Configuration result;

    result.themes.base = features::configuration::default_theme_values;
    runtime::config::ConfigurationLayers::each(root, profile, [&](const runtime::lua::Value& configuration) {
      PromptBindings bindings;
      const auto settings = runtime::config::ConfigurationLayers::read(configuration, [&](const runtime::config::PromptBindingSetting& binding) {
        bindings.push({.key = static_cast<std::uint8_t>(binding.chord.key), .character = binding.chord.character, .modifiers = binding.chord.modifiers, .action = binding.action, .normal = binding.normal});
      });

      features::configuration::ThemeReader::apply(settings.themes, result.themes);
      client(settings.client, result);
      prompt(settings.client.prompt, bindings, result.prompt);
      gui(settings.gui, result);
    });

    result.theme = projectTheme(result.themes.base);

    return result;
  }

  void ConfigurationReader::gui(const runtime::config::GuiSettings& gui, Configuration& configuration) {
    using Settings = runtime::config::GuiSettings;

    font(gui.font, configuration.font);
    const Settings::Cursor& cursor = gui.cursor;
    if (cursor.style) {
      configuration.cursor = cursorShape(*cursor.style);
    }

    configuration.cursor_blink = cursor.blink.valueOr(configuration.cursor_blink);
    if (cursor.blink_interval_ms) {
      configuration.blink_interval = std::chrono::milliseconds{*cursor.blink_interval_ms};
    }

    auto& scroll = configuration.scroll;

    scroll.smooth = gui.scroll.smooth.valueOr(scroll.smooth);
    scroll.wheel_ms = gui.scroll.wheel_ms.valueOr(scroll.wheel_ms);
    scroll.overscan = static_cast<float>(gui.scroll.overscan.valueOr(static_cast<double>(scroll.overscan)));
    scroll.sticky_headers = gui.scroll.sticky_headers.valueOr(scroll.sticky_headers);

    window(gui.window, configuration);
    for (std::size_t index = 0; index < gui.opacity.size(); ++index) {
      if (gui.opacity[index]) {
        configuration.opacity.overrides.atMut(index) = static_cast<float>(*gui.opacity[index]);
      }
    }

    configuration.chrome_scale = static_cast<float>(gui.chrome_scale.valueOr(static_cast<double>(configuration.chrome_scale)));
    if (gui.sidebar.automatic) {
      configuration.sidebar_width_auto = true;
    } else if (gui.sidebar.width) {
      configuration.sidebar_width = static_cast<float>(*gui.sidebar.width);
      configuration.sidebar_width_auto = false;
    }

    configuration.max_fps = gui.max_fps.valueOr(configuration.max_fps);
  }

  void ConfigurationReader::client(const ClientSettings& settings, Configuration& configuration) {
    configuration.sidebar_visible = settings.sidebar_visible.valueOr(configuration.sidebar_visible);
    configuration.pane_gaps = settings.pane_gaps.valueOr(configuration.pane_gaps);
    if (settings.editor) {
      DisplayText16<Configuration::maximum_editor_bytes, false>::validate(*settings.editor);
      configuration.editor.assign(*settings.editor);
    }

    if (settings.window_title) {
      DisplayText16<Configuration::maximum_window_title_bytes, true>::validate(*settings.window_title);
      configuration.window_title.assign(*settings.window_title);
    }

    history(settings.history, configuration.history);
    sound(settings.sound, configuration.sound);
    // Terminal delivery keeps the default the GUI chose.
    if (settings.delivery && *settings.delivery != ClientSettings::Delivery::terminal) {
      configuration.notification_delivery = *settings.delivery == ClientSettings::Delivery::system ? NotificationDelivery::system : NotificationDelivery::telar;
    }
  }

  void ConfigurationReader::sound(const ClientSettings::Sound& settings, SoundPolicy& policy) noexcept {
    policy.enabled = settings.enabled.valueOr(policy.enabled);
    policy.ready = settings.ready.valueOr(policy.ready);
    policy.needs_input = settings.needs_input.valueOr(policy.needs_input);
  }

  void ConfigurationReader::prompt(const runtime::config::PromptSettings& settings, const PromptBindings& bindings, PromptConfiguration& prompt) {
    if (settings.bindings) {
      prompt.bindings = bindings;
    }

    if (settings.mode) {
      prompt.mode = mapped<PromptMode>(*settings.mode);
    }

    if (settings.motion) {
      prompt.motion = mapped<PromptMotion>(*settings.motion);
    }

    if (settings.keymap) {
      prompt.keymap = mapped<PromptKeymap>(*settings.keymap);
    }

    prompt.ghost = settings.ghost.valueOr(prompt.ghost);
    prompt.max_lines = settings.max_lines.valueOr(prompt.max_lines);
  }

  void ConfigurationReader::history(const ClientSettings::History& settings, HistoryConfiguration& history) noexcept {
    history.show_agent_commands = settings.show_agent_commands.valueOr(history.show_agent_commands);
    if (settings.enter) {
      history.enter_runs = *settings.enter == ClientSettings::HistoryEnter::run;
    }

    if (settings.match) {
      history.match_fts = *settings.match == ClientSettings::HistoryMatch::fts;
    }
  }

  void ConfigurationReader::font(const runtime::config::GuiSettings::Font& settings, FontConfiguration& font) {
    if (settings.family) {
      font.family.assign(settings.family->view());
    }

    if (settings.style) {
      font.style.assign(settings.style->view());
    }

    font.size = static_cast<float>(settings.size.valueOr(static_cast<double>(font.size)));
    font.line_height = static_cast<float>(settings.line_height.valueOr(static_cast<double>(font.line_height)));
    font.letter_spacing = static_cast<float>(settings.letter_spacing.valueOr(static_cast<double>(font.letter_spacing)));
    font.thicken = settings.thicken.valueOr(font.thicken);
    font.thicken_strength = settings.thicken_strength.valueOr(font.thicken_strength);
    if (settings.hinting) {
      font.hinting = mapped<FontHinting>(*settings.hinting);
    }
  }

  void ConfigurationReader::window(const runtime::config::GuiSettings::Window& settings, Configuration& configuration) {
    configuration.background_opacity = static_cast<float>(settings.background_opacity.valueOr(static_cast<double>(configuration.background_opacity)));
    if (settings.titlebar) {
      configuration.titlebar = settings.titlebar;
    }

    if (settings.blur) {
      configuration.background_blur = *settings.blur ? Configuration::default_background_blur : 0;
    } else if (settings.blur_radius) {
      configuration.background_blur = *settings.blur_radius;
    }

    configuration.padding_x = static_cast<float>(settings.padding_x.valueOr(static_cast<double>(configuration.padding_x)));
    configuration.padding_y = static_cast<float>(settings.padding_y.valueOr(static_cast<double>(configuration.padding_y)));
  }

  CursorShape ConfigurationReader::cursorShape(runtime::config::CursorStyle style) noexcept {
    return static_cast<CursorShape>(std::to_underlying(style) + 1);
  }

  namespace {

    // Records the descriptions and callbacks of the actions BindingActionReader reads, so that a
    // configured binding keeps only an index into them.
    template <Allocator Memory>
    class RecordingActionReader {
    public:
      explicit RecordingActionReader(BindingActionReader& reader, ActionDescriptions<Memory>& descriptions, const runtime::config::ClientDefinitions& definitions)
          : reader_(reader),
            descriptions_(descriptions),
            definitions_(definitions) {}

      [[nodiscard]] ds::Option<BindingAction> read(const runtime::lua::Value& value, bool expression = false) {
        auto action = reader_.read(value, expression);
        if (action && (action->kind == BindingActionKind::callback || action->kind == BindingActionKind::expression)) {
          action.getMut().parameter = descriptions_.registerCallback();
        } else if (action && action->kind == BindingActionKind::extended) {
          action.getMut().parameter = descriptions_.retain(ActionDescriptionReader::read(value, definitions_));
        }

        return action;
      }

    private:
      BindingActionReader& reader_;
      ActionDescriptions<Memory>& descriptions_;
      const runtime::config::ClientDefinitions& definitions_;
    };

    // Keeps the elements runtime::config::ElementReader reads from what a slot function returned.
    // It runs on the Lua thread; actions are resolved as they are read and functions are handed to
    // `callback`, so the result needs no VM.
    template <Allocator Memory, typename Resolve, typename Callback>
    class ElementSink {
    public:
      using Color = features::components::ComponentColors::Color;
      using Setting = runtime::config::ElementSetting<Color>;

      static_assert(features::components::Element::maximum_elements == Setting::maximum_elements && features::components::Element::maximum_text_bytes == Setting::maximum_text_bytes);
      static_assert(features::components::Element::maximum_steps == Setting::maximum_steps && features::components::Element::maximum_actions == Setting::maximum_actions);
      static_assert(std::ranges::equal(features::components::element_kind_names, runtime::config::element_kind_names));

      ElementSink(features::components::RenderedElements<Memory>& output, const Resolve& resolve, const Callback& callback) noexcept
          : output_(output),
            resolve_(resolve),
            callback_(callback) {}

      std::uint32_t element(const Setting& setting) {
        features::components::Element element;

        element.kind = static_cast<features::components::ElementKind>(std::to_underlying(setting.kind));
        element.parent = setting.parent;
        element.text = store(setting.text);
        element.key = store(setting.key);
        element.tooltip = store(setting.tooltip);
        element.url = store(setting.url);
        element.padding = setting.padding;
        element.gap = setting.gap;
        element.width = setting.width;
        element.height = setting.height;
        element.min_width = setting.min_width;
        element.max_width = setting.max_width;
        element.min_height = setting.min_height;
        element.max_height = setting.max_height;
        element.grow = setting.grow;
        element.x = setting.x;
        element.y = setting.y;
        element.rotation = setting.rotation;
        element.scale = setting.scale;
        element.opacity = setting.opacity;
        element.radius = setting.radius;
        element.border_width = setting.border_width;
        element.size = setting.size;
        element.transition_ms = setting.transition_ms;
        element.z = setting.z;
        element.background = color(setting.background);
        element.border = color(setting.border);
        element.color = color(setting.color);
        element.hover = color(setting.hover);
        element.tone = features::components::ValueMapper::tone(setting.tone);
        element.align = setting.align;
        element.justify = setting.justify;
        element.align_self = setting.align_self;
        element.easing = setting.easing;
        element.size_role = setting.size_role;
        element.max_lines = setting.max_lines;
        element.bold = setting.bold;
        element.italic = setting.italic;
        element.clip = setting.clip;
        element.shadow = setting.shadow;
        element.named = setting.named;
        element.action = setting.action;
        element.callback = setting.callback;
        element.steps_offset = setting.steps_offset;
        element.steps_count = setting.steps_count;
        element.since = setting.since;
        output_.elements.push(element);

        return static_cast<std::uint32_t>(output_.elements.size() - 1);
      }

      void step(const runtime::config::CanvasStepSetting<Color>& setting) {
        output_.steps.push({.op = setting.op, .count = setting.count, .values = setting.values, .color = color(setting.color), .text = store(setting.text)});
      }

      [[nodiscard]] ds::Option<features::components::ResolvedAction> resolve(const runtime::lua::Value& action) const {
        return resolve_(action);
      }

      void bind(features::components::ResolvedAction resolved) {
        output_.bindings.push(resolved.action);
        output_.actions.add(std::move(resolved));
      }

      std::uint32_t callback(const runtime::lua::Value& function) {
        return callback_(function);
      }

    private:
      static features::components::ElementColor color(const runtime::config::ElementColorSetting<Color>& setting) noexcept {
        return {.value = setting.value, .alpha = setting.alpha};
      }

      features::components::ElementText store(std::string_view text) {
        const features::components::ElementText range{.offset = static_cast<std::uint32_t>(output_.text.size()), .length = static_cast<std::uint32_t>(text.size())};

        output_.text.append(text);

        return range;
      }

      features::components::RenderedElements<Memory>& output_;
      const Resolve& resolve_;
      const Callback& callback_;
    };

  }

  template <Allocator Memory>
  template <typename Consumer>
  auto ConfigurationGeneration<Memory>::withDefinitions(Consumer&& consume) const {
    const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "configuration registry"};
    const auto root = registry.element(root_reference_);

    return runtime::config::ConfigurationLayers::client(root, profile_.view(), [&](const runtime::lua::Value& client, const runtime::lua::Value* inherited) {
      const runtime::config::ClientDefinitions definitions{client, inherited};

      return std::forward<Consumer>(consume)(definitions);
    });
  }

  template <Allocator Memory>
  template <typename Consumer>
  auto ConfigurationGeneration<Memory>::withActions(Consumer&& consume) {
    lua_rawgeti(machine_.state(), LUA_REGISTRYINDEX, root_reference_);
    const runtime::lua::Value root{machine_.state(), -1, "config"};

    return runtime::config::ConfigurationLayers::client(root, profile_.view(), [&](const runtime::lua::Value& client, const runtime::lua::Value* inherited) {
      const runtime::config::ClientDefinitions definitions{client, inherited};
      runtime::config::RetainedActionValidator validator{definitions, notices_, client_state_.commands};
      BindingActionReader reader{*machine_.state(), validator, client_state_.commands, number_};

      return std::forward<Consumer>(consume)(reader);
    });
  }

  template <Allocator Memory>
  template <typename Consumer>
  void ConfigurationGeneration<Memory>::renderComponents(const features::components::Source& source, const features::components::Context& context, const Consumer& consume) {
    if (source.kind != features::components::SourceKind::dynamic && source.kind != features::components::SourceKind::command) {
      throw std::invalid_argument{"Source has no render callback or command"};
    }

    client_state_.commands.beginRender();
    const auto checkpoint = client_state_.commands.checkpoint();

    try {
      lua_settop(machine_.state(), 0);
      if (source.has_render) {
        constexpr std::uint64_t render_instructions = lua_call_instructions;
        constexpr auto render_deadline = lua_call_deadline;

        machine_.resetBudget(render_instructions, render_deadline);
        ComponentInvocation invocation{source.reference, context};

        machine_.invoke(&ComponentInvocation::invoke, &invocation, 1);
      } else {
        const auto output = context.output.valueOr(std::string_view{});

        lua_pushlstring(machine_.state(), output.data(), output.size());
      }

      const runtime::lua::Value result{machine_.state(), -1, "component render result"};

      withActions([&](auto& actions) {
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

  template <Allocator Memory>
  ConfigurationGeneration<Memory>::ConfigurationGeneration(tbc::mut_a<Memory> memory, ConfigurationSourceText source)
      : memory_(memory),
        machine_(memory),
        runtime_(ds::makeBox<runtime::config::RuntimeValues<Memory>>(memory, memory)),
        components_(ds::makeBox<ComponentConfiguration>(memory, *machine_.state())),
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

  template <Allocator Memory>
  const Configuration& ConfigurationGeneration<Memory>::configuration() const noexcept {
    return configuration_;
  }

  template <Allocator Memory>
  std::uint64_t ConfigurationGeneration<Memory>::number() const noexcept {
    return number_;
  }

  template <Allocator Memory>
  const ComponentConfiguration& ConfigurationGeneration<Memory>::components() const noexcept {
    return *components_;
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::renderBar(features::components::Position position, const features::components::Context& context) {
    const auto source = components_->definitions().source(position);

    renderComponents(source, context, [&](const auto& value, auto& actions) {
      components_.getMut().readBar(position, value, actions, notices_);
    });
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::renderPanel(std::size_t index, const features::components::Context& context) {
    const auto panels = components_->definitions().panels();
    if (index >= panels.size()) {
      throw std::invalid_argument{"Panel is no longer configured"};
    }

    const auto source = panels[index].source;

    renderComponents(source, context, [&](const auto& value, auto& actions) {
      components_.getMut().readPanel(value, actions, notices_);
    });
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::closePanel() noexcept {
    components_.getMut().closePanel();
  }

  template <Allocator Memory>
  template <features::components::Capacity Bounds>
  tbc::val_b<ds::Box<features::components::RenderedContent<Bounds, Memory>, Memory>> ConfigurationGeneration<Memory>::copied(tbc::mut_b<Memory> memory, const features::components::Content<Bounds>& content) const {
    auto result = ds::makeBox<features::components::RenderedContent<Bounds, Memory>>(memory, memory);

    result.getMut().content = content;
    for (const auto& node : content.nodes()) {
      if (const auto action = content.action(node)) {
        result.getMut().actions.add(resolve(*action));
      }
    }

    return result;
  }

  template <Allocator Memory>
  ds::Box<features::components::RenderedContent<features::components::BarContent::capacity, Memory>, Memory> ConfigurationGeneration<Memory>::renderedBar(features::components::Position position, const features::components::Context& context) {
    renderBar(position, context);

    return copied(memory_, components_->bar(position));
  }

  template <Allocator Memory>
  ds::Box<features::components::RenderedContent<features::components::PanelContent::capacity, Memory>, Memory> ConfigurationGeneration<Memory>::renderedPanel(std::size_t index, const features::components::Context& context) {
    renderPanel(index, context);

    return copied(memory_, components_->panel());
  }

  template <Allocator Memory>
  features::components::ResolvedAction ConfigurationGeneration<Memory>::resolve(BindingAction action) const {
    features::components::ResolvedAction result{.action = action};

    if (action.kind == BindingActionKind::extended) {
      result.description = extendedAction(action);
    } else if (action.kind == BindingActionKind::command_tab) {
      if (const auto command = commandTab(action)) {
        result.command.emplace(*command);
      }
    }

    return result;
  }

  template <Allocator Memory>
  ds::Box<features::components::ResolvedEffects<Memory>, Memory> ConfigurationGeneration<Memory>::invokeResolved(BindingAction action, BindingContext context) {
    auto result = ds::makeBox<features::components::ResolvedEffects<Memory>>(memory_, memory_);

    result.getMut().effects = invoke(action, context);
    for (const auto effect : std::span{result->effects.actions}.first(result->effects.length)) {
      if (effect.kind == BindingActionKind::extended || effect.kind == BindingActionKind::command_tab) {
        result.getMut().actions.add(resolve(effect));
      }
    }

    return result;
  }

  template <Allocator Memory>
  ds::Box<features::components::RenderedElements<Memory>, Memory> ConfigurationGeneration<Memory>::renderElements(features::components::Slot slot, std::uint64_t instance, const features::components::Context& context, std::string_view item) {
    const auto reference = components_->definitions().slot(slot);
    if (reference == LUA_NOREF) {
      throw std::invalid_argument{"Slot has no render function"};
    }

    auto result = ds::makeBox<features::components::RenderedElements<Memory>>(memory_, memory_);
    ds::Vec<int, Memory> handlers{memory_};
    const auto release = [&] {
      for (const auto handler : handlers) {
        luaL_unref(machine_.state(), LUA_REGISTRYINDEX, handler);
      }
    };

    client_state_.commands.beginRender();
    try {
      lua_settop(machine_.state(), 0);
      machine_.resetBudget(lua_call_instructions, lua_call_deadline);
      ComponentInvocation invocation{reference, context, nullptr, item};

      machine_.invoke(&ComponentInvocation::invoke, &invocation, 1);
      const runtime::lua::Value root{machine_.state(), -1, "element"};
      const auto action = [&](const runtime::lua::Value& value) {
        return elementAction(value, static_cast<std::uint32_t>(result->bindings.size()));
      };

      const auto callback = [&](const runtime::lua::Value& value) {
        value.pushCopy();
        handlers.push(luaL_ref(machine_.state(), LUA_REGISTRYINDEX));

        return static_cast<std::uint32_t>(handlers.size() - 1);
      };

      ElementSink<Memory, decltype(action), decltype(callback)> sink{result.getMut(), action, callback};
      const features::components::ComponentColors colors;

      runtime::config::ElementReader<features::components::ComponentColors, decltype(sink)>{sink, colors}.read(root);
    } catch (...) {
      release();
      client_state_.commands.endRender();
      lua_settop(machine_.state(), 0);

      throw;
    }

    client_state_.commands.endRender();
    lua_settop(machine_.state(), 0);
    result.getMut().callbacks = static_cast<std::uint32_t>(handlers.size());
    auto& kept = handlersOf(instance);

    std::swap(kept.references, handlers);
    release();

    return result;
  }

  template <Allocator Memory>
  ds::Box<features::components::ResolvedEffects<Memory>, Memory> ConfigurationGeneration<Memory>::invokeElement(ElementCallback target, const features::components::Context& context, std::string_view item) {
    const auto [instance, callback] = target;
    const auto found = std::ranges::find(element_handlers_, instance, &ElementHandlers::instance);
    if (found == element_handlers_.end() || callback >= found->references.size()) {
      throw std::invalid_argument{"That element changed before its click arrived"};
    }

    lua_settop(machine_.state(), 0);
    machine_.resetBudget(lua_call_instructions, lua_call_deadline);
    for (const auto reference : std::span{transient_references_}.first(transient_count_)) {
      luaL_unref(machine_.state(), LUA_REGISTRYINDEX, reference);
    }

    transient_count_ = 0;
    ComponentInvocation invocation{found->references[callback], context, nullptr, item};

    machine_.invoke(&ComponentInvocation::invoke, &invocation, 1);
    auto result = ds::makeBox<features::components::ResolvedEffects<Memory>>(memory_, memory_);
    const runtime::lua::Value value{machine_.state(), -1, "click result"};
    if (value.present()) {
      result.getMut().effects = withActions([&](auto& reader) {
        return effects(value, reader);
      });
    }

    lua_settop(machine_.state(), 0);
    for (const auto effect : std::span{result->effects.actions}.first(result->effects.length)) {
      if (effect.kind == BindingActionKind::extended || effect.kind == BindingActionKind::command_tab) {
        result.getMut().actions.add(resolve(effect));
      }
    }

    return result;
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::forgetElements(std::uint64_t instance) noexcept {
    const auto found = std::ranges::find(element_handlers_, instance, &ElementHandlers::instance);
    if (found == element_handlers_.end()) {
      return;
    }

    for (const auto reference : found->references) {
      luaL_unref(machine_.state(), LUA_REGISTRYINDEX, reference);
    }

    static_cast<void>(element_handlers_.remove(static_cast<std::size_t>(found - element_handlers_.begin())));
  }

  template <Allocator Memory>
  ds::Option<ExtendedActionDescription> ConfigurationGeneration<Memory>::configuredAction(BindingAction action) const {
    if (action.kind != BindingActionKind::extended || action.generation != number_) {
      return ds::none;
    }

    const auto configured = std::span{input_.configured}.first(input_.length);
    if (std::ranges::find(configured, action, &KeyBinding<BindingAction>::action) == configured.end()) {
      return ds::none;
    }

    return descriptions_.at(action.parameter);
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::renderPick(std::size_t index, const features::components::Context& context, features::components::PickItems& items) {
    const auto picks = components_->definitions().picks();
    if (index >= picks.size()) {
      throw std::invalid_argument{"Pick is no longer configured"};
    }

    const auto& pick = picks[index];
    if (pick.command && !pick.render) {
      PickItemsReader::lines(context.output.valueOr(std::string_view{}), items, notices_);

      return;
    }

    lua_settop(machine_.state(), 0);
    try {
      if (pick.render) {
        constexpr std::uint64_t pick_instructions = lua_call_instructions;
        constexpr auto pick_deadline = lua_call_deadline;

        machine_.resetBudget(pick_instructions, pick_deadline);
        ComponentInvocation invocation{pick.reference, context, "items"};

        machine_.invoke(&ComponentInvocation::invoke, &invocation, 1);
        const runtime::lua::Value result{machine_.state(), -1, "pick items"};

        PickItemsReader::read(result, items, notices_);
      } else {
        const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "pick registry"};

        PickItemsReader::definition(registry.element(pick.reference), items, notices_);
      }
    } catch (...) {
      lua_settop(machine_.state(), 0);

      throw;
    }

    lua_settop(machine_.state(), 0);
  }

  template <Allocator Memory>
  const runtime::config::RuntimeValues<Memory>& ConfigurationGeneration<Memory>::runtimeValues() const noexcept {
    return *runtime_;
  }

  template <Allocator Memory>
  const ActionDescriptions<Memory>& ConfigurationGeneration<Memory>::actionDescriptions() const noexcept {
    return descriptions_;
  }

  template <Allocator Memory>
  const runtime::config::RetainedCommandTabRegistry& ConfigurationGeneration<Memory>::commandTabs() const noexcept {
    return client_state_.commands;
  }

  template <Allocator Memory>
  ds::Option<runtime::config::CommandTabView> ConfigurationGeneration<Memory>::commandTab(BindingAction action) const {
    if (action.generation != number_ || action.kind != BindingActionKind::command_tab) {
      throw std::invalid_argument{"Command belongs to an obsolete configuration or a different binding kind"};
    }

    const auto reference = features::configuration::commandTabReference(action);

    return reference ? client_state_.commands.load(*reference) : ds::none;
  }

  template <Allocator Memory>
  ds::Option<NotificationActionDescription> ConfigurationGeneration<Memory>::notificationAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto* notification = description ? std::get_if<NotificationActionDescription>(&*description) : nullptr;

    return notification == nullptr ? ds::none : ds::Option{*notification};
  }

  template <Allocator Memory>
  const InputConfiguration& ConfigurationGeneration<Memory>::input() const noexcept {
    return input_;
  }

  template <Allocator Memory>
  ds::Option<PluginActionDescription> ConfigurationGeneration<Memory>::pluginAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto* plugin = description ? std::get_if<PluginActionDescription>(&*description) : nullptr;

    return plugin == nullptr ? ds::none : ds::Option{*plugin};
  }

  template <Allocator Memory>
  ds::Option<DefinitionActionDescription> ConfigurationGeneration<Memory>::definitionAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto* definition = description ? std::get_if<DefinitionActionDescription>(&*description) : nullptr;

    return definition == nullptr ? ds::none : ds::Option{*definition};
  }

  template <Allocator Memory>
  ds::Option<NamedActionDescription> ConfigurationGeneration<Memory>::namedAction(BindingAction action) const {
    const auto description = extendedAction(action);
    if (!description) {
      return ds::none;
    }

    if (const auto* definition = std::get_if<DefinitionActionDescription>(&*description)) {
      return *definition;
    }

    if (const auto* plugin = std::get_if<PluginActionDescription>(&*description)) {
      return *plugin;
    }

    return ds::none;
  }

  template <Allocator Memory>
  const BindingMap<BindingAction>& ConfigurationGeneration<Memory>::keymap() const noexcept {
    return keymap_;
  }

  template <Allocator Memory>
  std::size_t ConfigurationGeneration<Memory>::localModuleCount() const noexcept {
    return modules_ ? modules_->configurationModuleCount() : 0;
  }

  template <Allocator Memory>
  BindingEffects ConfigurationGeneration<Memory>::invoke(BindingAction action, BindingContext context) {
    static_cast<void>(callbackBinding(action, BindingActionKind::callback));
    invokeFunction(action.reference, context);
    const runtime::lua::Value result{machine_.state(), -1, "callback result"};

    return withActions([&](auto& reader) {
      return effects(result, reader);
    });
  }

  template <Allocator Memory>
  InputExpression ConfigurationGeneration<Memory>::expression(BindingAction action, BindingContext context) {
    static_assert(std::to_underlying(InputExpression::Kind::paste) == std::to_underlying(runtime::config::InputDecisionSetting::Kind::paste));
    static_assert(InputExpression::maximum_keys == runtime::config::InputDecisionSetting::maximum_keys);
    const auto& binding = callbackBinding(action, BindingActionKind::expression);

    invokeFunction(action.reference, context);
    const runtime::lua::Value result{machine_.state(), -1, "expression result"};
    const auto setting = runtime::config::CallbackResultReader::decision(result);
    InputExpression decision;

    decision.kind = static_cast<InputExpression::Kind>(std::to_underlying(setting.kind));
    if (decision.kind == InputExpression::Kind::forward) {
      std::ranges::copy(binding.sequence(), decision.keys.viewMut().begin());
      decision.length = binding.length;
    } else if (decision.kind == InputExpression::Kind::keys) {
      std::ranges::copy(std::span{setting.keys}.first(setting.length), decision.keys.viewMut().begin());
      decision.length = setting.length;
    } else if (decision.kind == InputExpression::Kind::paste) {
      decision.paste.assign(setting.text);
    }

    return decision;
  }

  template <Allocator Memory>
  ConfigurationGeneration<Memory>::ElementHandlers& ConfigurationGeneration<Memory>::handlersOf(std::uint64_t instance) {
    const auto handlers = element_handlers_.viewMut();
    const auto found = std::ranges::find(handlers, instance, &ElementHandlers::instance);
    if (found != handlers.end()) {
      return *found;
    }

    element_handlers_.push({.instance = instance, .references = ds::Vec<int, Memory>{memory_}});

    return element_handlers_.atMut(element_handlers_.size() - 1);
  }

  template <Allocator Memory>
  ds::Option<features::components::ResolvedAction> ConfigurationGeneration<Memory>::elementAction(const runtime::lua::Value& value, std::uint32_t index) {
    const auto action = withActions([&](auto& reader) {
      return reader.read(value);
    });

    lua_pop(machine_.state(), 1);
    if (!action) {
      return ds::none;
    }

    features::components::ResolvedAction resolved;

    resolved.action = *action;
    if (action->kind == BindingActionKind::extended) {
      resolved.description = withDefinitions([&](const auto& definitions) {
        return ActionDescriptionReader::read(value, definitions);
      });

      luaL_unref(machine_.state(), LUA_REGISTRYINDEX, action->reference);
      constexpr int first_element_reference = -16;

      resolved.action.reference = first_element_reference - static_cast<int>(index);
    } else if (action->kind == BindingActionKind::command_tab) {
      if (const auto command = commandTab(*action)) {
        resolved.command.emplace(*command);
      }
    } else if (action->kind == BindingActionKind::callback || action->kind == BindingActionKind::expression) {
      value.fail("must be an action; a function is called directly");
    }

    return resolved;
  }

  template <Allocator Memory>
  ds::Option<ExtendedActionDescription> ConfigurationGeneration<Memory>::extendedAction(BindingAction action) const {
    if (action.kind != BindingActionKind::extended) {
      return ds::none;
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

    return withDefinitions([&](const auto& definitions) {
      return ActionDescriptionReader::read(value, definitions);
    });
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::readConfiguration(tbc::mut_a<Memory> memory, const features::plugins::PluginOverrides* overrides) {
    const runtime::lua::Value root{machine_.state(), -1, "config"};

    runtime::config::SnapshotReader{memory, runtime_.getMut()}.read(root, profile_.view(), client_state_);
    validateUtf8(runtime_->history_path);
    validateUtf8(runtime_->session_path);
    validateUtf8(runtime_->proxy.authority_directory);
    configuration_ = ConfigurationReader::read(root, profile_.view());
    root.pushCopy();
    root_reference_ = luaL_ref(machine_.state(), LUA_REGISTRYINDEX);
    runtime::config::ConfigurationLayers::clients(root, profile_.view(), [&](const runtime::lua::Value& client, const runtime::lua::Value* inherited) {
      readClient(client, inherited);
    });

    if (overrides != nullptr) {
      overrides->apply(runtime_.getMut().plugins);
      removeDisabledPluginBindings(*overrides);
    }

    rebindDefinitions();
    keymap_ = input_.compile();
    withActions([&](auto& reader) {
      components_.getMut().readFixed(reader, notices_);
    });

    client_state_.commands.seal();
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::removeDisabledPluginBindings(const features::plugins::PluginOverrides& overrides) {
    std::size_t retained = 0;

    // By index, as a binding kept moves down over one dropped.
    for (std::size_t index = 0; index < input_.length; ++index) {
      const auto binding = input_.configured[index];
      if (binding.action.kind == BindingActionKind::extended) {
        const auto* plugin = std::get_if<PluginActionDescription>(&descriptions_.at(binding.action.parameter));
        if (plugin != nullptr && overrides.disabled(plugin->plugin, runtime_->plugins.configured())) {
          continue;
        }
      }

      input_.configured.atMut(retained) = binding;
      ++retained;
    }

    input_.length = retained;
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::rebindDefinitions() {
    const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "binding registry"};

    for (const auto& binding : std::span{input_.configured}.first(input_.length)) {
      const auto action = binding.action;
      if (action.kind != BindingActionKind::extended || !std::holds_alternative<DefinitionActionDescription>(descriptions_.at(action.parameter))) {
        continue;
      }

      const auto value = registry.element(action.reference);
      const auto description = withDefinitions([&](const auto& definitions) {
        return ActionDescriptionReader::read(value, definitions);
      });

      descriptions_.replaceDefinition(action.parameter, std::get<DefinitionActionDescription>(description));
    }
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::readClient(const runtime::lua::Value& client, const runtime::lua::Value* inherited) {
    components_.getMut().readDefinitions(client);
    const runtime::config::ClientDefinitions definitions{client, inherited};
    runtime::config::RetainedActionValidator validator{definitions, notices_, client_state_.commands};
    BindingActionReader reader{*machine_.state(), validator, client_state_.commands, number_};

    if (runtime::config::ClientReader::listsBindings(client)) {
      descriptions_.replaceBindings();
    }

    RecordingActionReader<Memory> actions{reader, descriptions_, definitions};

    BindingReader::apply(client, input_, actions);
  }

  template <Allocator Memory>
  const KeyBinding<BindingAction>& ConfigurationGeneration<Memory>::callbackBinding(BindingAction action, BindingActionKind kind) const {
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

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::invokeFunction(int reference, BindingContext context) {
    constexpr std::uint64_t callback_instructions = lua_call_instructions;
    constexpr auto callback_deadline = lua_call_deadline;

    for (const auto transient : std::span{transient_references_}.first(transient_count_)) {
      luaL_unref(machine_.state(), LUA_REGISTRYINDEX, transient);
    }

    transient_count_ = 0;
    lua_settop(machine_.state(), 0);
    machine_.resetBudget(callback_instructions, callback_deadline);
    runtime::config::CallbackInvocation invocation{reference, context};

    machine_.invoke(&runtime::config::CallbackInvocation::invoke, &invocation, 1);
  }

  template <Allocator Memory>
  BindingEffects ConfigurationGeneration<Memory>::effects(const runtime::lua::Value& result, BindingActionReader& reader) {
    BindingEffects batch;
    const auto past = runtime::config::CallbackResultReader::actions(result, BindingEffects::maximum_effects, [&](const runtime::lua::Value& value) {
      if (const auto action = reader.read(value)) {
        if (action->kind == BindingActionKind::extended) {
          transient_references_.atMut(transient_count_++) = action->reference;
        }

        batch.actions.atMut(batch.length++) = *action;
      } else {
        ++batch.dropped;
      }
    });

    batch.dropped += past;

    return batch;
  }

  template class ConfigurationGeneration<telar::Memory>;
  template class ConfigurationGeneration<telar::ConcurrentMemory>;

  template tbc::val_b<ds::Box<features::components::RenderedContent<features::components::BarContent::capacity, telar::Memory>, telar::Memory>> ConfigurationGeneration<telar::Memory>::copied<features::components::BarContent::capacity>(tbc::mut_b<telar::Memory> memory, const features::components::Content<features::components::BarContent::capacity>& content) const;
  template tbc::val_b<ds::Box<features::components::RenderedContent<features::components::PanelContent::capacity, telar::Memory>, telar::Memory>> ConfigurationGeneration<telar::Memory>::copied<features::components::PanelContent::capacity>(tbc::mut_b<telar::Memory> memory, const features::components::Content<features::components::PanelContent::capacity>& content) const;
  template tbc::val_b<ds::Box<features::components::RenderedContent<features::components::BarContent::capacity, telar::ConcurrentMemory>, telar::ConcurrentMemory>> ConfigurationGeneration<telar::ConcurrentMemory>::copied<features::components::BarContent::capacity>(tbc::mut_b<telar::ConcurrentMemory> memory, const features::components::Content<features::components::BarContent::capacity>& content) const;
  template tbc::val_b<ds::Box<features::components::RenderedContent<features::components::PanelContent::capacity, telar::ConcurrentMemory>, telar::ConcurrentMemory>> ConfigurationGeneration<telar::ConcurrentMemory>::copied<features::components::PanelContent::capacity>(tbc::mut_b<telar::ConcurrentMemory> memory, const features::components::Content<features::components::PanelContent::capacity>& content) const;

  tbc::val_a<std::string_view> ClientQuery::write(const Configuration& configuration, const ClientQueryContext& context, tbc::val_a<std::span<char>> output) {
    JsonWriter writer{output};

    writer.object([&](JsonWriter& object) {
      object.member("source", [&](JsonWriter& value) {
        writeOptionalBytes(value, context.source);
      });

      object.member("profile", [&](JsonWriter& value) {
        writeOptionalBytes(value, context.profile);
      });

      object.member("generation", context.generation);
      object.member("sidebar_visible", context.view.sidebar_visible);
      object.member("sidebar_width", context.view.sidebar_width);
      object.member("workspace_list_collapsed", context.view.workspace_list_collapsed);
      object.member("pane_gaps", context.view.pane_gaps);
      object.member("window_title", context.view.window_title);
      object.member("sound", [&](JsonWriter& value) {
        writeSound(value, configuration.sound);
      });

      object.member("notification_delivery", configuration.notification_delivery == NotificationDelivery::system ? "system" : "telar");
      object.member("history_show_agent_commands", configuration.history.show_agent_commands);
      object.member("history_enter_runs", configuration.history.enter_runs);
      object.member("history_match_fts", configuration.history.match_fts);
      object.member("sections", writeSections);
    });

    return writer.view();
  }

  void ClientQuery::writeOptionalBytes(JsonWriter& writer, ds::Option<std::string_view> text) {
    if (text) {
      writer.bytes(byteView(*text));
    } else {
      writer.value(nullptr);
    }
  }

  void ClientQuery::writeSound(JsonWriter& writer, SoundPolicy policy) {
    writer.object([&](JsonWriter& object) {
      object.member("enabled", policy.enabled);
      object.member("ready", policy.ready);
      object.member("needs_input", policy.needs_input);
    });
  }

  void ClientQuery::writeSections(JsonWriter& writer) {
    writer.array([](JsonWriter& sections) {
      for (const auto& [name, section] : features::configuration::ConfigurationQuery::sections) {
        sections.element(name);
      }
    });
  }

}

namespace telar::gui::application::configuration {

  void configure(Session& session, const Configuration& configuration) {
    auto& shown = session.configuration;
    const bool prompt_changed = shown.prompt.mode != configuration.prompt.mode;
    const bool theme_changed = shown.theme != configuration.theme;

    shown = configuration;
    features::notifications::configure(session.notifications, configuration.sound);
    ++session.view_version.configuration;
    if (prompt_changed) {
      prompt::configureShell(session);
    }

    if (theme_changed) {
      configureTerminal(session);
    }
  }

  void setTheme(Session& session, const Theme& theme) {
    auto& shown = session.configuration;
    if (shown.theme == theme) {
      return;
    }

    shown.theme = theme;
    ++session.view_version.configuration;
    configureTerminal(session);
  }

  ConfigureTerminalColors terminalColors(const Theme& theme) noexcept {
    constexpr auto same = [](const auto& names, const auto& wire) {
      return names.size() == wire.size() && std::ranges::equal(names, wire, [](std::string_view name, std::string_view wire_name) {
        return name == wire_name;
      });
    };

    static_assert(same(syntax_names, TerminalTheme::syntax_names) && same(palette_names, TerminalTheme::chrome_names), "the theme's roles travel in the wire's order");
    constexpr float channel_max = 255;
    const auto bytes = [](Color color) {
      const auto channel = [](float value) {
        return static_cast<Byte>(std::lround(std::clamp(value, 0.0F, 1.0F) * channel_max));
      };

      return ds::Array<Byte, 3>{channel(color.r), channel(color.g), channel(color.b)};
    };

    const auto write = [&](auto& target, std::size_t index, Color color) {
      const auto rgb = bytes(color);

      std::ranges::copy(rgb, target.viewMut().begin() + static_cast<std::ptrdiff_t>(index * 3));
    };

    ConfigureTerminalColors colors;
    ds::Array<Byte, DefaultTheme::palette_size * 3> palette{};
    ds::Array<Byte, TerminalTheme::syntax_roles * 3> syntax{};
    ds::Array<Byte, TerminalTheme::chrome_roles * 3> chrome{};

    for (std::size_t index = 0; index < theme.palette.size(); ++index) {
      write(palette, index, theme.palette[index]);
    }

    for (std::size_t index = 0; index < theme.syntax.size(); ++index) {
      write(syntax, index, theme.resolve(theme.syntax[index], theme.foreground));
    }

    // A surface the theme leaves unset is the terminal's background; any other color its text.
    for (std::size_t index = 0; index < theme.chrome.size(); ++index) {
      const auto role = static_cast<PaletteRole>(index);
      const bool surface = role == PaletteRole::panel_bg || role == PaletteRole::surface0 || role == PaletteRole::surface1 || role == PaletteRole::surface_dim;

      write(chrome, index, theme.resolve(theme.chrome[index], surface ? theme.background : theme.foreground));
    }

    colors.foreground = bytes(theme.foreground);
    colors.background = bytes(theme.background);
    colors.palette = palette;
    colors.cursor = bytes(theme.cursor);
    colors.syntax = syntax;
    colors.syntax_italic = theme.syntax_italic;
    colors.syntax_bold = theme.syntax_bold;
    colors.chrome = chrome;
    return colors;
  }

  void configureTerminal(Session& session) {
    if (session.readsTheme()) {
      session.link.send(terminalColors(session.configuration.theme));
    }
  }

  template <Allocator Memory>
  tbc::val_a<std::string_view> query(
      const ConfigurationGeneration<Memory>& generation,
      const runtime::config::RetainedCommandTabRegistry& commands,
      ConfigurationQuery query,
      const ClientQueryContext& context,
      tbc::val_a<std::span<char>> output
  ) {
    using Section = ConfigurationQuery::Section;

    if (query.section != Section::client && query.index < 0) {
      throw std::invalid_argument{"InvalidIndex"};
    }

    switch (query.section) {
    case Section::client:
      return ClientQuery::write(generation.configuration(), context, output);
    case Section::binding:
      if (!std::in_range<std::size_t>(query.index)) {
        throw std::runtime_error{"BindingNotFound"};
      }

      return features::configuration::BindingQuery::write(generation.input(), static_cast<std::size_t>(query.index), generation.actionDescriptions(), commands, output);
    case Section::runtime:
      return features::configuration::RuntimeQuery::write(generation.runtimeValues(), output);
    case Section::gui:
      return features::configuration::GuiQuery::write(generation.configuration(), output, context.default_titlebar);
    case Section::input:
      return features::configuration::InputQuery::write(generation.input(), output);
    case Section::theme:
      return features::configuration::ThemeQuery::write(generation.configuration().themes, output);
    }

    throw std::runtime_error{"ConfigurationSectionUnavailable"};
  }

  template tbc::val_a<std::string_view> query<telar::Memory>(const ConfigurationGeneration<telar::Memory>& generation, const runtime::config::RetainedCommandTabRegistry& commands, ConfigurationQuery query, const ClientQueryContext& context, tbc::val_a<std::span<char>> output);
  template tbc::val_a<std::string_view> query<telar::ConcurrentMemory>(const ConfigurationGeneration<telar::ConcurrentMemory>& generation, const runtime::config::RetainedCommandTabRegistry& commands, ConfigurationQuery query, const ClientQueryContext& context, tbc::val_a<std::span<char>> output);

}
