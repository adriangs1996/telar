module;
#include <lauxlib.h>
#include <lua.h>

#include "gui_config_bootstrap.hpp"

module telar.gui.config.generation;

namespace telar::gui {

  ExtendedActionDescription ActionDescriptionReader::read(const runtime::lua::Value& value, const runtime::config::ClientDefinitions& definitions) {
    return std::visit(
        [](const auto& setting) {
          return description(setting);
        },
        runtime::config::ExtendedActionReader::read(value, definitions)
    );
  }

  ExtendedActionDescription ActionDescriptionReader::description(const runtime::config::NotificationActionSetting& setting) {
    NotificationActionDescription result;

    result.title.assign(setting.title);
    result.message.assign(setting.body);
    result.level = setting.level;
    result.duration_ms = setting.duration_ms;
    result.target = setting.target;

    return result;
  }

  ExtendedActionDescription ActionDescriptionReader::description(const runtime::config::PluginActionSetting& setting) {
    return PluginActionDescription{.plugin = runtime::plugins::stableId(setting.plugin), .action = runtime::plugins::stableId(setting.action)};
  }

  ExtendedActionDescription ActionDescriptionReader::description(const runtime::config::DefinitionActionSetting& setting) {
    return DefinitionActionDescription{.kind = setting.panel ? DefinitionActionDescription::Kind::panel : DefinitionActionDescription::Kind::pick, .index = setting.index};
  }

  BindingActionReader::BindingActionReader(lua_State& state, const runtime::config::RetainedActionValidator& validator, runtime::config::RetainedCommandTabRegistry& commands, std::uint64_t generation)
      : state_(state),
        validator_(validator),
        commands_(commands),
        generation_(generation) {}

  std::optional<BindingAction> BindingActionReader::read(const runtime::lua::Value& value, bool expression) const {
    using Kind = runtime::config::ActionKind;

    const auto setting = validator_.read(value, expression);
    if (!setting) {
      return {};
    }

    switch (setting->kind) {
    case Kind::function:
      return referenced(value, expression ? BindingActionKind::expression : BindingActionKind::callback);
    case Kind::builtin:
      return builtin(value, setting->name);
    case Kind::select_tab:
    case Kind::select_workspace:
      return BindingAction{.kind = setting->kind == Kind::select_tab ? BindingActionKind::select_tab : BindingActionKind::select_workspace, .parameter = setting->number - 1};
    case Kind::select_tab_offset:
      return BindingAction{.kind = BindingActionKind::select_tab_offset, .parameter = setting->number};
    case Kind::command_tab:
      return command(setting->command);
    case Kind::notification:
    case Kind::panel:
    case Kind::pick:
    case Kind::plugin:
      return referenced(value, BindingActionKind::extended);
    }

    return {};
  }

  BindingAction BindingActionReader::command(const runtime::config::CommandTabView& command) const {
    runtime::config::LimitNotices limits;
    const auto reference = commands_.keepReference(command.argv(), command.configured_label, limits);
    if (!reference) {
      throw std::runtime_error{"BindingNotFound"};
    }

    return commandTabAction(*reference, generation_);
  }

  BindingAction BindingActionReader::builtin(const runtime::lua::Value& value, std::string_view name) {
    if (const auto action = builtinBindingAction(name)) {
      return *action;
    }

    value.fail("names an unknown binding action");
  }

  BindingAction BindingActionReader::referenced(const runtime::lua::Value& value, BindingActionKind kind) const {
    value.pushCopy();

    return {.kind = kind, .reference = luaL_ref(&state_, LUA_REGISTRYINDEX), .generation = generation_};
  }

  template <BindingActionSource Actions>
  void BindingReader::apply(const runtime::lua::Value& client, InputConfiguration& input, const Actions& actions) {
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

  std::string_view canonicalThemeName(std::string_view name) noexcept {
    if (name == "catppuccin-mocha" || name == "mocha") {
      return "catppuccin";
    }

    if (name == "tokyonight" || name == "tokyo_night") {
      return "tokyo-night";
    }

    if (name == "kanagawa-wave" || name == "kanagawa_wave") {
      return "kanagawa";
    }

    if (name == "kanagawa_dragon") {
      return "kanagawa-dragon";
    }

    if (name == "default") {
      return "terminal";
    }

    return name;
  }

  ThemeValues themeValuesByName(std::string_view name) {
    constexpr std::size_t maximum_name_bytes = 64;
    if (name.size() > maximum_name_bytes) {
      throw std::invalid_argument{"GUI theme name exceeds capacity"};
    }

    std::array<char, maximum_name_bytes> lowercase{};

    std::ranges::transform(name, lowercase.begin(), [](char character) {
      return character >= 'A' && character <= 'Z' ? static_cast<char>(character + 'a' - 'A') : character;
    });

    const auto canonical = canonicalThemeName({lowercase.data(), name.size()});
    const auto* const found = std::ranges::find_if(theme_presets, [&](const auto& preset) {
      return preset.name == canonical;
    });
    if (found == theme_presets.end()) {
      throw std::invalid_argument{"Unknown GUI theme"};
    }

    return found->values;
  }

  Theme themeByName(std::string_view name) {
    return projectTheme(themeValuesByName(name));
  }

  void ThemeReader::apply(const runtime::config::ThemeSelectionSettings& settings, ThemeSelection& selection) {
    applyTheme(settings.base, selection.base);
    applyVariant(settings.light, selection.light, selection.base);
    applyVariant(settings.dark, selection.dark, selection.base);
  }

  CellColor ThemeReader::color(const runtime::config::ThemeColor& color) noexcept {
    if (!color.rgb) {
      return {};
    }

    return {.kind = CellColor::Kind::rgb, .channels = *color.rgb};
  }

  void ThemeReader::applyVariant(const std::optional<Settings>& settings, std::optional<ThemeValues>& variant, const ThemeValues& base) {
    if (!settings) {
      return;
    }

    auto result = variant.value_or(base);

    applyTheme(settings, result);
    variant = result;
  }

  void ThemeReader::applyTheme(const std::optional<Settings>& settings, ThemeValues& theme) {
    if (!settings) {
      return;
    }

    if (settings->preset) {
      theme = themeValuesByName(*settings->preset);
    }

    for (std::size_t index = 0; index < settings->colors.size(); ++index) {
      if (settings->colors[index]) {
        theme.palette[index] = color(*settings->colors[index]);
      }
    }

    applyTerminal(settings->terminal, theme.terminal);
    applySyntax(*settings, theme);
  }

  void ThemeReader::applyTerminal(const Settings::Terminal& settings, TerminalThemeValues& terminal) noexcept {
    terminal.foreground = settings.foreground.value_or(terminal.foreground);
    terminal.background = settings.background.value_or(terminal.background);
    if (settings.cursor_color) {
      terminal.cursor_color = settings.cursor_color;
    }

    if (settings.cursor_text_color) {
      terminal.cursor_text_color = settings.cursor_text_color;
    }

    terminal.palette = settings.palette.value_or(terminal.palette);
  }

  void ThemeReader::applySyntax(const Settings& settings, ThemeValues& theme) {
    for (std::size_t index = 0; index < settings.syntax.size(); ++index) {
      const auto& entry = settings.syntax[index];
      if (!entry) {
        continue;
      }

      auto style = theme.syntaxStyle(static_cast<SyntaxRole>(index));

      if (entry->color) {
        style.color = color(*entry->color);
      }

      style.italic = entry->italic.value_or(style.italic);
      style.bold = entry->bold.value_or(style.bold);
      theme.syntax_styles[index] = style;
    }
  }

  template <typename To, typename From>
  To ConfigurationReader::mapped(From value) noexcept {
    return static_cast<To>(std::to_underlying(value));
  }

  Configuration ConfigurationReader::read(const runtime::lua::Value& root, std::string_view profile) {
    Configuration result;

    result.themes.base = default_theme_values;
    runtime::config::ConfigurationLayers::each(root, profile, [&](const runtime::lua::Value& configuration) {
      std::vector<PromptBinding> bindings;
      const auto settings = runtime::config::ConfigurationLayers::read(configuration, [&](const runtime::config::PromptBindingSetting& binding) {
        bindings.push_back({.key = static_cast<std::uint8_t>(binding.chord.key), .character = binding.chord.character, .modifiers = binding.chord.modifiers, .action = binding.action, .normal = binding.normal});
      });

      ThemeReader::apply(settings.themes, result.themes);
      client(settings.client, result);
      prompt(settings.client.prompt, std::move(bindings), result.prompt);
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

    configuration.cursor_blink = cursor.blink.value_or(configuration.cursor_blink);
    if (cursor.blink_interval_ms) {
      configuration.blink_interval = std::chrono::milliseconds{*cursor.blink_interval_ms};
    }

    auto& scroll = configuration.scroll;

    scroll.smooth = gui.scroll.smooth.value_or(scroll.smooth);
    scroll.wheel_ms = gui.scroll.wheel_ms.value_or(scroll.wheel_ms);
    scroll.overscan = static_cast<float>(gui.scroll.overscan.value_or(scroll.overscan));
    scroll.sticky_headers = gui.scroll.sticky_headers.value_or(scroll.sticky_headers);

    window(gui.window, configuration);
    for (std::size_t index = 0; index < gui.opacity.size(); ++index) {
      if (gui.opacity[index]) {
        configuration.opacity.overrides[index] = static_cast<float>(*gui.opacity[index]);
      }
    }

    configuration.chrome_scale = static_cast<float>(gui.chrome_scale.value_or(configuration.chrome_scale));
    if (gui.sidebar.automatic) {
      configuration.sidebar_width_auto = true;
    } else if (gui.sidebar.width) {
      configuration.sidebar_width = static_cast<float>(*gui.sidebar.width);
      configuration.sidebar_width_auto = false;
    }

    configuration.max_fps = gui.max_fps.value_or(configuration.max_fps);
  }

  void ConfigurationReader::client(const ClientSettings& settings, Configuration& configuration) {
    configuration.sidebar_visible = settings.sidebar_visible.value_or(configuration.sidebar_visible);
    configuration.pane_gaps = settings.pane_gaps.value_or(configuration.pane_gaps);
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
    policy.enabled = settings.enabled.value_or(policy.enabled);
    policy.ready = settings.ready.value_or(policy.ready);
    policy.needs_input = settings.needs_input.value_or(policy.needs_input);
  }

  void ConfigurationReader::prompt(const runtime::config::PromptSettings& settings, std::vector<PromptBinding> bindings, PromptConfiguration& prompt) {
    if (settings.bindings) {
      prompt.bindings = std::move(bindings);
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

    prompt.ghost = settings.ghost.value_or(prompt.ghost);
    prompt.max_lines = settings.max_lines.value_or(prompt.max_lines);
  }

  void ConfigurationReader::history(const ClientSettings::History& settings, HistoryConfiguration& history) noexcept {
    history.show_agent_commands = settings.show_agent_commands.value_or(history.show_agent_commands);
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

    font.size = static_cast<float>(settings.size.value_or(font.size));
    font.line_height = static_cast<float>(settings.line_height.value_or(font.line_height));
    font.letter_spacing = static_cast<float>(settings.letter_spacing.value_or(font.letter_spacing));
    font.thicken = settings.thicken.value_or(font.thicken);
    font.thicken_strength = settings.thicken_strength.value_or(font.thicken_strength);
    if (settings.hinting) {
      font.hinting = mapped<FontHinting>(*settings.hinting);
    }
  }

  void ConfigurationReader::window(const runtime::config::GuiSettings::Window& settings, Configuration& configuration) {
    configuration.background_opacity = static_cast<float>(settings.background_opacity.value_or(configuration.background_opacity));
    if (settings.titlebar) {
      configuration.titlebar = settings.titlebar;
    }

    if (settings.blur) {
      configuration.background_blur = *settings.blur ? Configuration::default_background_blur : 0;
    } else if (settings.blur_radius) {
      configuration.background_blur = *settings.blur_radius;
    }

    configuration.padding_x = static_cast<float>(settings.padding_x.value_or(configuration.padding_x));
    configuration.padding_y = static_cast<float>(settings.padding_y.value_or(configuration.padding_y));
  }

  CursorShape ConfigurationReader::cursorShape(runtime::config::CursorStyle style) noexcept {
    return static_cast<CursorShape>(std::to_underlying(style) + 1);
  }

  // Records the descriptions and callbacks of the actions BindingActionReader reads, so that a
  // configured binding keeps only an index into them.
  template <Allocator Memory>
  class RecordingActionReader {
  public:
    explicit RecordingActionReader(const BindingActionReader& reader, ActionDescriptions<Memory>& descriptions, const runtime::config::ClientDefinitions& definitions)
        : reader_(reader),
          descriptions_(descriptions),
          definitions_(definitions) {}

    [[nodiscard]] std::optional<BindingAction> read(const runtime::lua::Value& value, bool expression = false) const {
      auto action = reader_.read(value, expression);
      if (!action) {
        return {};
      }

      if (action->kind == BindingActionKind::callback || action->kind == BindingActionKind::expression) {
        action->parameter = descriptions_.registerCallback();
      } else if (action->kind == BindingActionKind::extended) {
        action->parameter = descriptions_.retain(ActionDescriptionReader::read(value, definitions_));
      }

      return action;
    }

  private:
    const BindingActionReader& reader_;
    ActionDescriptions<Memory>& descriptions_;
    const runtime::config::ClientDefinitions& definitions_;
  };

  // Keeps the elements runtime::config::ElementReader reads from what a slot function returned.
  // It runs on the Lua thread; actions are resolved as they are read and functions are handed to
  // `callback`, so the result needs no VM.
  template <Allocator Memory, typename Resolve, typename Callback>
  class ElementSink {
  public:
    using Color = components::ComponentColors::Color;
    using Setting = runtime::config::ElementSetting<Color>;

    static_assert(components::Element::maximum_elements == Setting::maximum_elements && components::Element::maximum_text_bytes == Setting::maximum_text_bytes);
    static_assert(components::Element::maximum_steps == Setting::maximum_steps && components::Element::maximum_actions == Setting::maximum_actions);
    static_assert(std::ranges::equal(components::element_kind_names, runtime::config::element_kind_names));

    ElementSink(RenderedElements<Memory>& output, const Resolve& resolve, const Callback& callback) noexcept
        : output_(output),
          resolve_(resolve),
          callback_(callback) {}

    std::uint32_t element(const Setting& setting) {
      components::Element element;

      element.kind = static_cast<components::ElementKind>(std::to_underlying(setting.kind));
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
      element.tone = components::ValueMapper::tone(setting.tone);
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
      output_.elements.push_back(element);

      return static_cast<std::uint32_t>(output_.elements.size() - 1);
    }

    void step(const runtime::config::CanvasStepSetting<Color>& setting) {
      output_.steps.push_back({.op = setting.op, .count = setting.count, .values = setting.values, .color = color(setting.color), .text = store(setting.text)});
    }

    [[nodiscard]] std::optional<ResolvedAction> resolve(const runtime::lua::Value& action) const {
      return resolve_(action);
    }

    void bind(ResolvedAction resolved) {
      output_.bindings.push_back(resolved.action);
      output_.actions.add(std::move(resolved));
    }

    std::uint32_t callback(const runtime::lua::Value& function) {
      return callback_(function);
    }

  private:
    static components::ElementColor color(const runtime::config::ElementColorSetting<Color>& setting) noexcept {
      return {.value = setting.value, .alpha = setting.alpha};
    }

    components::ElementText store(std::string_view text) {
      const components::ElementText range{.offset = static_cast<std::uint32_t>(output_.text.size()), .length = static_cast<std::uint32_t>(text.size())};

      output_.text.append(text);

      return range;
    }

    RenderedElements<Memory>& output_;
    const Resolve& resolve_;
    const Callback& callback_;
  };

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
      const runtime::config::RetainedActionValidator validator{definitions, notices_, client_state_.commands};
      const BindingActionReader reader{*machine_.state(), validator, client_state_.commands, number_};

      return std::forward<Consumer>(consume)(reader);
    });
  }

  template <Allocator Memory>
  template <typename Consumer>
  void ConfigurationGeneration<Memory>::renderComponents(const components::Source& source, const components::Context& context, const Consumer& consume) {
    if (source.kind != components::SourceKind::dynamic && source.kind != components::SourceKind::command) {
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
        components::Invocation invocation{source.reference, context};

        machine_.invoke(&components::Invocation::invoke, &invocation, 1);
      } else {
        const auto output = context.output.value_or(std::string_view{});

        lua_pushlstring(machine_.state(), output.data(), output.size());
      }

      const runtime::lua::Value result{machine_.state(), -1, "component render result"};

      withActions([&](const auto& actions) {
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
  ConfigurationGeneration<Memory>::ConfigurationGeneration(tbc::view<Memory&, tbc::lt::a> memory, ConfigurationSourceText source)
      : memory_(memory),
        machine_(memory),
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

  template <Allocator Memory>
  const Configuration& ConfigurationGeneration<Memory>::configuration() const noexcept {
    return configuration_;
  }

  template <Allocator Memory>
  std::uint64_t ConfigurationGeneration<Memory>::number() const noexcept {
    return number_;
  }

  template <Allocator Memory>
  const components::Configuration& ConfigurationGeneration<Memory>::components() const noexcept {
    return *components_;
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::renderBar(components::Position position, const components::Context& context) {
    const auto source = components_->definitions().source(position);

    renderComponents(source, context, [&](const auto& value, const auto& actions) {
      components_->readBar(position, value, actions, notices_);
    });
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::renderPanel(std::size_t index, const components::Context& context) {
    const auto panels = components_->definitions().panels();
    if (index >= panels.size()) {
      throw std::invalid_argument{"Panel is no longer configured"};
    }

    const auto source = panels[index].source;

    renderComponents(source, context, [&](const auto& value, const auto& actions) {
      components_->readPanel(value, actions, notices_);
    });
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::closePanel() noexcept {
    components_->closePanel();
  }

  template <Allocator Memory>
  template <components::Capacity Bounds>
  tbc::view<Owned<RenderedContent<Bounds, Memory>, Memory>, tbc::lt::b> ConfigurationGeneration<Memory>::copied(tbc::view<Memory&, tbc::lt::b> memory, const components::Content<Bounds>& content) const {
    auto result = makeOwned<RenderedContent<Bounds, Memory>>(memory, memory);

    result->content = content;
    for (const auto& node : content.nodes()) {
      if (const auto action = content.action(node)) {
        result->actions.add(resolve(*action));
      }
    }

    return result;
  }

  template <Allocator Memory>
  Owned<RenderedContent<components::BarContent::capacity, Memory>, Memory> ConfigurationGeneration<Memory>::renderedBar(components::Position position, const components::Context& context) {
    renderBar(position, context);

    return copied(memory_, components_->bar(position));
  }

  template <Allocator Memory>
  Owned<RenderedContent<components::PanelContent::capacity, Memory>, Memory> ConfigurationGeneration<Memory>::renderedPanel(std::size_t index, const components::Context& context) {
    renderPanel(index, context);

    return copied(memory_, components_->panel());
  }

  template <Allocator Memory>
  ResolvedAction ConfigurationGeneration<Memory>::resolve(BindingAction action) const {
    ResolvedAction result{.action = action};

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
  Owned<ResolvedEffects<Memory>, Memory> ConfigurationGeneration<Memory>::invokeResolved(BindingAction action, BindingContext context) {
    auto result = makeOwned<ResolvedEffects<Memory>>(memory_, memory_);

    result->effects = invoke(action, context);
    for (const auto effect : std::span{result->effects.actions}.first(result->effects.length)) {
      if (effect.kind == BindingActionKind::extended || effect.kind == BindingActionKind::command_tab) {
        result->actions.add(resolve(effect));
      }
    }

    return result;
  }

  template <Allocator Memory>
  Owned<RenderedElements<Memory>, Memory> ConfigurationGeneration<Memory>::renderElements(components::Slot slot, std::uint64_t instance, const components::Context& context, std::string_view item) {
    const auto reference = components_->definitions().slot(slot);
    if (reference == LUA_NOREF) {
      throw std::invalid_argument{"Slot has no render function"};
    }

    auto result = makeOwned<RenderedElements<Memory>>(memory_, memory_);
    Vector<int, Memory> handlers{AllocatorRef<int, Memory>{memory_}};
    const auto release = [&] {
      for (const auto handler : handlers) {
        luaL_unref(machine_.state(), LUA_REGISTRYINDEX, handler);
      }
    };

    client_state_.commands.beginRender();
    try {
      lua_settop(machine_.state(), 0);
      machine_.resetBudget(lua_call_instructions, lua_call_deadline);
      components::Invocation invocation{reference, context, nullptr, item};

      machine_.invoke(&components::Invocation::invoke, &invocation, 1);
      const runtime::lua::Value root{machine_.state(), -1, "element"};
      const auto action = [&](const runtime::lua::Value& value) {
        return elementAction(value, static_cast<std::uint32_t>(result->bindings.size()));
      };

      const auto callback = [&](const runtime::lua::Value& value) {
        value.pushCopy();
        handlers.push_back(luaL_ref(machine_.state(), LUA_REGISTRYINDEX));

        return static_cast<std::uint32_t>(handlers.size() - 1);
      };

      ElementSink<Memory, decltype(action), decltype(callback)> sink{*result, action, callback};
      const components::ComponentColors colors;

      runtime::config::ElementReader{sink, colors}.read(root);
    } catch (...) {
      release();
      client_state_.commands.endRender();
      lua_settop(machine_.state(), 0);

      throw;
    }

    client_state_.commands.endRender();
    lua_settop(machine_.state(), 0);
    result->callbacks = static_cast<std::uint32_t>(handlers.size());
    auto& kept = handlersOf(instance);

    std::swap(kept.references, handlers);
    release();

    return result;
  }

  template <Allocator Memory>
  Owned<ResolvedEffects<Memory>, Memory> ConfigurationGeneration<Memory>::invokeElement(std::uint64_t instance, std::uint32_t callback, const components::Context& context, std::string_view item) {
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
    components::Invocation invocation{found->references[callback], context, nullptr, item};

    machine_.invoke(&components::Invocation::invoke, &invocation, 1);
    auto result = makeOwned<ResolvedEffects<Memory>>(memory_, memory_);
    const runtime::lua::Value value{machine_.state(), -1, "click result"};
    if (value.present()) {
      result->effects = withActions([&](const auto& reader) {
        return effects(value, reader);
      });
    }

    lua_settop(machine_.state(), 0);
    for (const auto effect : std::span{result->effects.actions}.first(result->effects.length)) {
      if (effect.kind == BindingActionKind::extended || effect.kind == BindingActionKind::command_tab) {
        result->actions.add(resolve(effect));
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

    element_handlers_.erase(found);
  }

  template <Allocator Memory>
  std::optional<ExtendedActionDescription> ConfigurationGeneration<Memory>::configuredAction(BindingAction action) const {
    if (action.kind != BindingActionKind::extended || action.generation != number_) {
      return std::nullopt;
    }

    const auto configured = std::span{input_.configured}.first(input_.length);
    if (std::ranges::find(configured, action, &KeyBinding<BindingAction>::action) == configured.end()) {
      return std::nullopt;
    }

    return descriptions_.at(action.parameter);
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::renderPick(std::size_t index, const components::Context& context, components::PickItems& items) {
    const auto picks = components_->definitions().picks();
    if (index >= picks.size()) {
      throw std::invalid_argument{"Pick is no longer configured"};
    }

    const auto& pick = picks[index];
    if (pick.command && !pick.render) {
      components::PickItemsReader::lines(context.output.value_or(std::string_view{}), items, notices_);

      return;
    }

    lua_settop(machine_.state(), 0);
    try {
      if (pick.render) {
        constexpr std::uint64_t pick_instructions = lua_call_instructions;
        constexpr auto pick_deadline = lua_call_deadline;

        machine_.resetBudget(pick_instructions, pick_deadline);
        components::Invocation invocation{pick.reference, context, "items"};

        machine_.invoke(&components::Invocation::invoke, &invocation, 1);
        const runtime::lua::Value result{machine_.state(), -1, "pick items"};

        components::PickItemsReader::read(result, items, notices_);
      } else {
        const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "pick registry"};

        components::PickItemsReader::definition(registry.element(pick.reference), items, notices_);
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
  std::optional<runtime::config::CommandTabView> ConfigurationGeneration<Memory>::commandTab(BindingAction action) const {
    if (action.generation != number_ || action.kind != BindingActionKind::command_tab) {
      throw std::invalid_argument{"Command belongs to an obsolete configuration or a different binding kind"};
    }

    const auto reference = commandTabReference(action);

    return reference ? client_state_.commands.load(*reference) : std::nullopt;
  }

  template <Allocator Memory>
  std::optional<NotificationActionDescription> ConfigurationGeneration<Memory>::notificationAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto* notification = description ? std::get_if<NotificationActionDescription>(&*description) : nullptr;

    return notification == nullptr ? std::nullopt : std::optional{*notification};
  }

  template <Allocator Memory>
  const InputConfiguration& ConfigurationGeneration<Memory>::input() const noexcept {
    return input_;
  }

  template <Allocator Memory>
  std::optional<PluginActionDescription> ConfigurationGeneration<Memory>::pluginAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto* plugin = description ? std::get_if<PluginActionDescription>(&*description) : nullptr;

    return plugin == nullptr ? std::nullopt : std::optional{*plugin};
  }

  template <Allocator Memory>
  std::optional<DefinitionActionDescription> ConfigurationGeneration<Memory>::definitionAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto* definition = description ? std::get_if<DefinitionActionDescription>(&*description) : nullptr;

    return definition == nullptr ? std::nullopt : std::optional{*definition};
  }

  template <Allocator Memory>
  std::optional<NamedActionDescription> ConfigurationGeneration<Memory>::namedAction(BindingAction action) const {
    const auto description = extendedAction(action);
    if (!description) {
      return std::nullopt;
    }

    if (const auto* definition = std::get_if<DefinitionActionDescription>(&*description)) {
      return *definition;
    }

    if (const auto* plugin = std::get_if<PluginActionDescription>(&*description)) {
      return *plugin;
    }

    return std::nullopt;
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

    return withActions([&](const auto& reader) {
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
      std::ranges::copy(binding.sequence(), decision.keys.begin());
      decision.length = binding.length;
    } else if (decision.kind == InputExpression::Kind::keys) {
      std::ranges::copy(std::span{setting.keys}.first(setting.length), decision.keys.begin());
      decision.length = setting.length;
    } else if (decision.kind == InputExpression::Kind::paste) {
      decision.paste.assign(setting.text);
    }

    return decision;
  }

  template <Allocator Memory>
  typename ConfigurationGeneration<Memory>::ElementHandlers& ConfigurationGeneration<Memory>::handlersOf(std::uint64_t instance) {
    const auto found = std::ranges::find(element_handlers_, instance, &ElementHandlers::instance);
    if (found != element_handlers_.end()) {
      return *found;
    }

    element_handlers_.push_back({.instance = instance, .references = Vector<int, Memory>{AllocatorRef<int, Memory>{memory_}}});

    return element_handlers_.back();
  }

  template <Allocator Memory>
  std::optional<ResolvedAction> ConfigurationGeneration<Memory>::elementAction(const runtime::lua::Value& value, std::uint32_t index) {
    const auto action = withActions([&](const auto& reader) {
      return reader.read(value);
    });

    lua_pop(machine_.state(), 1);
    if (!action) {
      return std::nullopt;
    }

    ResolvedAction resolved;

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
  std::optional<ExtendedActionDescription> ConfigurationGeneration<Memory>::extendedAction(BindingAction action) const {
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

    return withDefinitions([&](const auto& definitions) {
      return ActionDescriptionReader::read(value, definitions);
    });
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::readConfiguration(tbc::view<Memory&, tbc::lt::a> memory, const PluginOverrides* overrides) {
    const runtime::lua::Value root{machine_.state(), -1, "config"};

    runtime::config::SnapshotReader{memory, *runtime_}.read(root, profile_.view(), client_state_);
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
      overrides->apply(runtime_->plugins);
      removeDisabledPluginBindings(*overrides);
    }

    rebindDefinitions();
    keymap_ = input_.compile();
    withActions([&](const auto& reader) {
      components_->readFixed(reader, notices_);
    });

    client_state_.commands.seal();
  }

  template <Allocator Memory>
  void ConfigurationGeneration<Memory>::removeDisabledPluginBindings(const PluginOverrides& overrides) {
    std::size_t retained = 0;

    for (const auto& binding : std::span{input_.configured}.first(input_.length)) {
      if (binding.action.kind == BindingActionKind::extended) {
        const auto* plugin = std::get_if<PluginActionDescription>(&descriptions_.at(binding.action.parameter));
        if (plugin != nullptr && overrides.disabled(plugin->plugin, runtime_->plugins.configured())) {
          continue;
        }
      }

      input_.configured[retained] = binding;
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
    components_->definitions().apply(*machine_.state(), client);
    const runtime::config::ClientDefinitions definitions{client, inherited};
    const runtime::config::RetainedActionValidator validator{definitions, notices_, client_state_.commands};
    const BindingActionReader reader{*machine_.state(), validator, client_state_.commands, number_};

    if (runtime::config::ClientReader::listsBindings(client)) {
      descriptions_.replaceBindings();
    }

    const RecordingActionReader actions{reader, descriptions_, definitions};

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

    for (const auto reference : std::span{transient_references_}.first(transient_count_)) {
      luaL_unref(machine_.state(), LUA_REGISTRYINDEX, reference);
    }

    transient_count_ = 0;
    lua_settop(machine_.state(), 0);
    machine_.resetBudget(callback_instructions, callback_deadline);
    CallbackInvocation invocation{reference, context};

    machine_.invoke(&CallbackInvocation::invoke, &invocation, 1);
  }

  template <Allocator Memory>
  BindingEffects ConfigurationGeneration<Memory>::effects(const runtime::lua::Value& result, const BindingActionReader& reader) {
    BindingEffects batch;
    const auto past = runtime::config::CallbackResultReader::actions(result, BindingEffects::maximum_effects, [&](const runtime::lua::Value& value) {
      if (auto action = reader.read(value)) {
        if (action->kind == BindingActionKind::extended) {
          transient_references_[transient_count_++] = action->reference;
        }

        batch.actions[batch.length++] = *action;
      } else {
        ++batch.dropped;
      }
    });

    batch.dropped += past;

    return batch;
  }

  template class ConfigurationGeneration<telar::Memory>;
  template class ConfigurationGeneration<telar::ConcurrentMemory>;

  template tbc::view<Owned<RenderedContent<components::BarContent::capacity, telar::Memory>, telar::Memory>, tbc::lt::b> ConfigurationGeneration<telar::Memory>::copied<components::BarContent::capacity>(tbc::view<telar::Memory&, tbc::lt::b> memory, const components::Content<components::BarContent::capacity>& content) const;
  template tbc::view<Owned<RenderedContent<components::PanelContent::capacity, telar::Memory>, telar::Memory>, tbc::lt::b> ConfigurationGeneration<telar::Memory>::copied<components::PanelContent::capacity>(tbc::view<telar::Memory&, tbc::lt::b> memory, const components::Content<components::PanelContent::capacity>& content) const;
  template tbc::view<Owned<RenderedContent<components::BarContent::capacity, telar::ConcurrentMemory>, telar::ConcurrentMemory>, tbc::lt::b> ConfigurationGeneration<telar::ConcurrentMemory>::copied<components::BarContent::capacity>(tbc::view<telar::ConcurrentMemory&, tbc::lt::b> memory, const components::Content<components::BarContent::capacity>& content) const;
  template tbc::view<Owned<RenderedContent<components::PanelContent::capacity, telar::ConcurrentMemory>, telar::ConcurrentMemory>, tbc::lt::b> ConfigurationGeneration<telar::ConcurrentMemory>::copied<components::PanelContent::capacity>(tbc::view<telar::ConcurrentMemory&, tbc::lt::b> memory, const components::Content<components::PanelContent::capacity>& content) const;

}
