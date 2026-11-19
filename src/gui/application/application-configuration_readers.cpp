module telar.gui.application;

import std;

import telar.lua;
import telar.base.diagnostics;
import telar.base.text.utf8;
import telar.gui.foundation.core;
import telar.gui.features.components;
import telar.plugins;
import telar.config.client;
import telar.config.core;
import telar.gui.foundation.actions;
import telar.gui.features.configuration;
import telar.base.ds;

namespace telar::gui::application {

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

  BindingActionReader::BindingActionReader(lua_State& state, runtime::config::RetainedActionValidator& validator, runtime::config::RetainedCommandTabRegistry& commands, std::uint64_t generation)
      : state_(state),
        validator_(validator),
        commands_(commands),
        generation_(generation) {}

  ds::Option<BindingAction> BindingActionReader::read(const runtime::lua::Value& value, bool expression) {
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

  BindingAction BindingActionReader::command(const runtime::config::CommandTabView& command) {
    runtime::config::LimitNotices limits;
    const auto reference = commands_.keepReference(command.argv(), command.configured_label, limits);
    if (!reference) {
      throw std::runtime_error{"BindingNotFound"};
    }

    return features::configuration::commandTabAction(*reference, generation_);
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

  template <std::size_t MaximumReferences>
  ActionReferences<MaximumReferences>::ActionReferences(lua_State& state) noexcept
      : state_(&state) {}

  template <std::size_t MaximumReferences>
  ActionReferences<MaximumReferences>::~ActionReferences() {
    clear();
  }

  template <std::size_t MaximumReferences>
  void ActionReferences<MaximumReferences>::keep(BindingAction action) {
    if (action.kind != BindingActionKind::extended) {
      return;
    }

    if (count_ == MaximumReferences) {
      luaL_unref(state_, LUA_REGISTRYINDEX, action.reference);

      throw std::length_error{"Too many component action references"};
    }

    references_.atMut(count_++) = action;
  }

  template <std::size_t MaximumReferences>
  bool ActionReferences<MaximumReferences>::contains(BindingAction action) const noexcept {
    return std::ranges::contains(std::span{references_}.first(count_), action);
  }

  template <std::size_t MaximumReferences>
  template <features::components::Capacity Bounds>
  void ActionReferences<MaximumReferences>::keepOnly(const features::components::Content<Bounds>& content) {
    std::size_t kept = 0;

    // By index, as a reference kept moves down over one released.
    for (std::size_t index = 0; index < count_; ++index) {
      const auto retained = references_[index];
      const bool used = std::ranges::any_of(content.nodes(), [&](const features::components::Node& node) {
        const auto action = content.action(node);

        return action == retained;
      });
      if (used) {
        references_.atMut(kept++) = retained;
      } else {
        luaL_unref(state_, LUA_REGISTRYINDEX, retained.reference);
      }
    }

    count_ = kept;
  }

  template <std::size_t MaximumReferences>
  void ActionReferences<MaximumReferences>::swap(ActionReferences& other) noexcept {
    std::swap(state_, other.state_);
    std::swap(references_, other.references_);
    std::swap(count_, other.count_);
  }

  template <std::size_t MaximumReferences>
  void ActionReferences<MaximumReferences>::clear() noexcept {
    for (const auto retained : std::span{references_}.first(count_)) {
      luaL_unref(state_, LUA_REGISTRYINDEX, retained.reference);
    }

    count_ = 0;
  }

  ComponentActionReader::ComponentActionReader(ComponentActions& reader, StagedActionReferences& references, std::uint32_t& next_reference) noexcept
      : reader_(reader),
        references_(references),
        next_reference_(next_reference) {}

  ds::Option<BindingAction> ComponentActionReader::read(const runtime::lua::Value& value) {
    auto action = reader_.read(value);
    if (action && action->kind == BindingActionKind::extended) {
      if (next_reference_ == static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())) {
        references_.keep(*action);

        throw std::length_error{"Component action identity exhausted"};
      }

      action.getMut().parameter = -static_cast<std::int32_t>(++next_reference_);
      references_.keep(*action);
    }

    return action;
  }

  ContentReader::ContentReader(lua_State& state, ComponentActions& actions, runtime::config::LimitNotices& limits, features::components::StagedContent& staged, ComponentSurface surface)
      : state_(state),
        builder_{.actions_ = actions, .limits_ = limits, .staged_ = staged, .surface_ = surface} {}

  template <features::components::Capacity Bounds>
  void ContentReader::read(const runtime::lua::Value& value, features::components::Content<Bounds>& output) {
    builder_.budget_ = {};
    builder_.demand_ = {};
    builder_.had_children_.fill(false);
    builder_.counting_ = true;
    builder_.staged_.clear();
    const Position root{.place = builder_.surface_ == ComponentSurface::bar ? Place::bar : Place::panel};

    // A walk borrows the builder, so the budget is prepared between two walks.
    {
      runtime::config::ComponentWalker walker{state_, builder_, builder_.limits_};

      walker.walk(value, root);
    }

    builder_.budget_.prepare();
    builder_.counting_ = false;
    {
      runtime::config::ComponentWalker walker{state_, builder_, builder_.limits_};

      walker.walk(value, root);
    }

    output.keepFitting(builder_.staged_, &builder_.had_children_);
    builder_.report(Bounds);
  }

  ds::Option<ContentReader::Parent> ContentReader::Builder::node(const runtime::lua::Value& value, const Shape& shape, const Position& position) {
    const auto values = runtime::config::ComponentValuesReader::read(value, shape, features::components::ComponentColors{});
    features::components::Input input;

    input.node.kind = shape.kind;
    input.node.priority = static_cast<std::uint8_t>(shape.priority);
    input.node.tone = features::components::ValueMapper::tone(values.tone);
    input.node.style = {.foreground = values.foreground, .background = values.background, .bold = values.bold, .italic = values.italic, .faint = values.faint, .underline = values.underline, .strikethrough = values.strikethrough};
    input.node.icon = features::components::ValueMapper::icon(values.icon);
    input.node.mark = features::components::ValueMapper::mark(values.mark);
    input.node.metric = static_cast<BarMetric>(std::to_underlying(values.metric));
    input.node.value = features::components::ValueMapper::fraction(values.value.valueOr(0));
    input.node.marker = values.marker ? ds::Option{features::components::ValueMapper::fraction(*values.marker)} : ds::none;
    input.node.primary = values.primary;
    input.text = shape.text;
    input.detail = shape.detail;
    input.url = shape.url;
    input.samples = std::span{values.samples}.first(values.sample_count);

    return append(value, shape, input, position);
  }

  ds::Option<ContentReader::Parent> ContentReader::Builder::append(const runtime::lua::Value& value, const Shape& shape, features::components::Input& input, const Position& position) {
    const auto rank = std::min(shape.priority + shape.tone_bonus, position.rank);

    if (counting_) {
      budget_.count(shape, rank);
      demand_ = demand_ + usage(shape);

      return Parent{.index = 0, .rank = rank};
    }

    if (position.parent != features::components::Node::no_parent) {
      had_children_.atMut(position.parent) = true;
    }

    if (!budget_.admit(shape, rank)) {
      return ds::none;
    }

    if (shape.action_field != nullptr) {
      input.action = runtime::config::ComponentValuesReader::action(value, shape, [&](const runtime::lua::Value& action) {
        return actions_.read(action);
      });

      if (!input.action) {
        budget_.release(shape, rank);

        return ds::none;
      }
    }

    if (!budget_.stage(shape)) {
      return ds::none;
    }

    input.node.parent = position.parent;
    input.node.tooltip = position.place == Place::tooltip;

    return Parent{.index = staged_.append(input), .rank = rank};
  }

  runtime::config::ComponentBudget::Usage ContentReader::Builder::usage(const Shape& shape) noexcept {
    return {.nodes = 1, .text = shape.text.size() + shape.detail.size() + shape.url.size(), .actions = shape.action_field == nullptr ? 0U : 1U, .samples = shape.samples};
  }

  void ContentReader::Builder::report(features::components::Capacity bounds) {
    const bool panel = surface_ == ComponentSurface::panel;
    const auto reaches = ds::Array<LimitReach, 4>{{
        {.name = panel ? "panels.max_panel_nodes" : "bars.max_bar_nodes", .noun = "components", .value = bounds.nodes, .requested = demand_.nodes, .route = {}},
        {.name = panel ? "panels.max_panel_text_bytes" : "bars.max_bar_text_bytes", .noun = "text bytes", .value = bounds.text, .requested = demand_.text, .route = {}},
        {.name = panel ? "panels.max_panel_actions" : "bars.max_bar_actions", .noun = "click actions", .value = bounds.actions, .requested = demand_.actions, .route = {}},
        {.name = panel ? "panels.max_samples" : "bars.max_samples", .noun = "sparkline samples", .value = bounds.samples, .requested = demand_.samples, .route = {}},
    }};

    for (const auto& reach : reaches) {
      if (reach.requested.valueOr(0) > reach.value) {
        limits_.add(reach);
      }
    }
  }

  template <features::components::Capacity Bounds>
  ComponentSnapshot<Bounds>::ComponentSnapshot(lua_State& state) noexcept
      : state_(state),
        references_(state) {}

  template <features::components::Capacity Bounds>
  void ComponentSnapshot<Bounds>::read(const runtime::lua::Value& value, ComponentActions& actions, runtime::config::LimitNotices& limits, features::components::StagedContent& staged, std::uint32_t& next_reference) {
    StagedActionReferences pending{state_};
    ComponentActionReader reader{actions, pending, next_reference};
    features::components::Content<Bounds> next;
    constexpr auto surface = Bounds.nodes == features::components::PanelContent::capacity.nodes ? ComponentSurface::panel : ComponentSurface::bar;

    ContentReader{state_, reader, limits, staged, surface}.read(value, next);
    pending.keepOnly(next);
    references_.swap(pending);
    content_ = std::move(next);
  }

  template <features::components::Capacity Bounds>
  const features::components::Content<Bounds>& ComponentSnapshot<Bounds>::content() const noexcept {
    return content_;
  }

  template <features::components::Capacity Bounds>
  bool ComponentSnapshot<Bounds>::contains(BindingAction action) const noexcept {
    return references_.contains(action);
  }

  template <features::components::Capacity Bounds>
  void ComponentSnapshot<Bounds>::clear() noexcept {
    references_.clear();
    content_.clear();
  }

  ComponentConfiguration::ComponentConfiguration(lua_State& state)
      : state_(state),
        bars_{BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}},
        panel_(state) {}

  const features::components::Definitions& ComponentConfiguration::definitions() const noexcept {
    return definitions_;
  }

  void ComponentConfiguration::readDefinitions(const runtime::lua::Value& client) {
    if (!client.present()) {
      return;
    }

    runtime::config::BarsReader::sources(client, [&](runtime::config::BarPosition position, const runtime::lua::Value& source) {
      definitions_.defineSource(static_cast<features::components::Position>(std::to_underlying(position)), readSource(source));
    });

    runtime::config::ClientReader::slots(client, [&](std::size_t slot, const runtime::lua::Value& function) {
      const auto held = definitions_.slot(static_cast<features::components::Slot>(slot));
      if (held != LUA_NOREF) {
        luaL_unref(&state_, LUA_REGISTRYINDEX, held);
      }

      function.pushCopy();
      definitions_.defineSlot(static_cast<features::components::Slot>(slot), luaL_ref(&state_, LUA_REGISTRYINDEX));
    });

    // SnapshotReader reported the definitions' limits.
    runtime::config::LimitNotices limits;
    const auto counts = runtime::config::ClientDefinitionsReader::read(
        client,
        limits,
        [&](std::size_t index, const runtime::config::PanelSetting& setting, const runtime::lua::Value& source) {
          features::components::Panel panel;

          panel.heading.assign(setting.heading);
          panel.width = setting.width;
          panel.mark = features::components::ValueMapper::mark(setting.mark);
          panel.icon = features::components::ValueMapper::icon(setting.icon);
          panel.source = readSource(source, setting.source);
          definitions_.definePanel(index, panel);
        },
        [&](std::size_t index, const runtime::config::PickSetting& setting, const runtime::lua::Value& definition) {
          features::components::Pick pick;

          pick.heading.assign(setting.heading);
          pick.timeout = std::chrono::milliseconds{setting.timeout_ms};
          pick.command = setting.command;
          pick.render = setting.render;
          pick.refresh = setting.refresh;
          definition.pushCopy();
          pick.reference = luaL_ref(&state_, LUA_REGISTRYINDEX);
          definitions_.definePick(index, pick);
        }
    );

    definitions_.count(counts.panels, counts.picks);
  }

  features::components::Source ComponentConfiguration::readSource(const runtime::lua::Value& value, bool panel) {
    if (!value.present()) {
      return {};
    }

    return readSource(value, runtime::config::SourceReader::read(value, panel));
  }

  features::components::Source ComponentConfiguration::readSource(const runtime::lua::Value& value, const runtime::config::SourceSetting& setting) {
    features::components::Source result;

    result.kind = static_cast<features::components::SourceKind>(std::to_underlying(setting.kind) + 1);
    if (setting.every_ms) {
      result.interval = std::chrono::milliseconds{*setting.every_ms};
    }

    result.has_render = setting.render;
    result.timeout = std::chrono::milliseconds{setting.timeout_ms};
    value.pushCopy();
    result.reference = luaL_ref(&state_, LUA_REGISTRYINDEX);

    return result;
  }

  void ComponentConfiguration::readFixedSources(ComponentActions& actions, runtime::config::LimitNotices& limits) {
    const runtime::lua::Value registry{&state_, LUA_REGISTRYINDEX, "bar registry"};

    for (std::size_t index = 0; index < bars_.size(); ++index) {
      const auto& source = definitions_.source(static_cast<features::components::Position>(index));
      if (source.kind == features::components::SourceKind::fixed) {
        const auto value = registry.element(source.reference);

        bars_.atMut(index).read(runtime::config::BarsReader::content(value), actions, limits, staged_, next_reference_);
      }
    }
  }

  void ComponentConfiguration::readBarContent(features::components::Position position, const runtime::lua::Value& value, ComponentActions& actions, runtime::config::LimitNotices& limits) {
    bars_.atCheckedMut(static_cast<std::size_t>(position)).read(value, actions, limits, staged_, next_reference_);
  }

  void ComponentConfiguration::readPanelContent(const runtime::lua::Value& value, ComponentActions& actions, runtime::config::LimitNotices& limits) {
    panel_.read(value, actions, limits, staged_, next_reference_);
  }

  const features::components::BarContent& ComponentConfiguration::bar(features::components::Position position) const {
    return bars_.at(static_cast<std::size_t>(position)).content();
  }

  const features::components::PanelContent& ComponentConfiguration::panel() const noexcept {
    return panel_.content();
  }

  void ComponentConfiguration::closePanel() noexcept {
    panel_.clear();
  }

  bool ComponentConfiguration::contains(BindingAction action) const noexcept {
    return panel_.contains(action) || std::ranges::any_of(bars_, [action](const auto& bar) {
      return bar.contains(action);
    });
  }

  ComponentInvocation::ComponentInvocation(int reference, const features::components::Context& context, const char* field, ds::Option<std::string_view> item) noexcept
      : reference_(reference),
        context_(context),
        field_(field),
        item_(item) {}

  int ComponentInvocation::invoke(lua_State* state) {
    const auto& invocation = *static_cast<const ComponentInvocation*>(lua_touserdata(state, 1));

    lua_rawgeti(state, LUA_REGISTRYINDEX, invocation.reference_);
    if (invocation.field_ != nullptr) {
      lua_getfield(state, -1, invocation.field_);
      lua_remove(state, -2);
    }

    invocation.pushContext(state);
    if (invocation.item_) {
      lua_getglobal(state, "telar");
      lua_getfield(state, -1, "json");
      lua_getfield(state, -1, "decode");
      lua_pushlstring(state, invocation.item_->data(), invocation.item_->size());
      lua_call(state, 1, 1);
      lua_replace(state, -3);
      lua_pop(state, 1);
    }

    lua_call(state, invocation.item_ ? 2 : 1, 1);

    return 1;
  }

  void ComponentInvocation::pushContext(lua_State* state) const {
    lua_newtable(state);
    runtime::lua::setField(state, "sidebar_visible", static_cast<bool>(context_.client.sidebar_visible));
    runtime::lua::setField(state, "tab_count", static_cast<lua_Integer>(context_.client.tab_count));
    runtime::lua::setField(state, "active_tab_index", static_cast<lua_Integer>(static_cast<std::int64_t>(context_.client.active_tab_index) + 1));
    runtime::lua::setField(state, "pane_count", static_cast<lua_Integer>(context_.client.pane_count));
    runtime::lua::setField(state, "focused_pane_id", static_cast<lua_Integer>(static_cast<std::int64_t>(context_.client.focused_pane_id)));

    lua_newtable(state);
    runtime::lua::setField(state, "unix_seconds", static_cast<lua_Integer>(context_.time.unix_seconds));
    runtime::lua::setField(state, "year", static_cast<lua_Integer>(context_.time.year));
    runtime::lua::setField(state, "month", static_cast<lua_Integer>(context_.time.month));
    runtime::lua::setField(state, "day", static_cast<lua_Integer>(context_.time.day));
    runtime::lua::setField(state, "hour", static_cast<lua_Integer>(context_.time.hour));
    runtime::lua::setField(state, "minute", static_cast<lua_Integer>(context_.time.minute));
    runtime::lua::setField(state, "second", static_cast<lua_Integer>(context_.time.second));
    runtime::lua::setField(state, "weekday", static_cast<lua_Integer>(context_.time.weekday));
    runtime::lua::pushReadOnly(state, "callback context is immutable");
    lua_setfield(state, -2, "time");

    lua_newtable(state);
    runtime::lua::setField(state, "available", static_cast<bool>(context_.metrics.hasValue()));
    if (context_.metrics) {
      runtime::lua::setField(state, "cpu_percent", static_cast<lua_Integer>(context_.metrics->cpu_percent));
      runtime::lua::setField(state, "memory_used_decigib", static_cast<lua_Integer>(context_.metrics->memory_used_decigib));
      if (context_.metrics->has_battery) {
        runtime::lua::setField(state, "battery_percent", static_cast<lua_Integer>(context_.metrics->battery_percent));
      }
    }

    runtime::lua::pushReadOnly(state, "callback context is immutable");
    lua_setfield(state, -2, "metrics");
    if (context_.output) {
      runtime::lua::setField(state, "output", *context_.output);
    }

    runtime::lua::setField(state, "pane_title", context_.pane_title);
    runtime::lua::pushReadOnly(state, "callback context is immutable");
  }

  void PickItemsReader::read(const runtime::lua::Value& value, features::components::PickItems& output, runtime::config::LimitNotices& limits) {
    keep(
        [&](const auto& collect) {
          runtime::config::PickItemsReader::read(value, collect);
        },
        output,
        limits
    );
  }

  void PickItemsReader::definition(const runtime::lua::Value& pick, features::components::PickItems& output, runtime::config::LimitNotices& limits) {
    keep(
        [&](const auto& collect) {
          runtime::config::PickItemsReader::definition(pick, collect);
        },
        output,
        limits
    );
  }

  void PickItemsReader::lines(std::string_view text, features::components::PickItems& output, runtime::config::LimitNotices& limits) {
    ds::Array<char, features::components::PickItems::maximum_label_bytes> label{};

    output.clear();
    while (!text.empty()) {
      const auto newline = text.find('\n');
      const auto line = text.substr(0, newline);

      text = newline == std::string_view::npos ? std::string_view{} : text.substr(newline + 1);
      constexpr std::string_view blanks = " \t\r";
      const auto first = line.find_first_not_of(blanks);
      if (first == std::string_view::npos) {
        continue;
      }

      const auto option = line.substr(first, line.find_last_not_of(blanks) - first + 1);
      const auto shown = runtime::utf8Prefix(option, label.size());

      std::ranges::transform(shown, label.viewMut().begin(), [](char byte) {
        return byte == '\t' ? ' ' : byte;
      });

      features::components::PickInput input;

      input.label = {label.data(), shown.size()};
      input.value = option;
      output.keep(input);
    }

    output.report(limits);
  }

  template <typename Read>
  void PickItemsReader::keep(const Read& read, features::components::PickItems& output, runtime::config::LimitNotices& limits) {
    output.clear();
    read([&](const runtime::config::PickItemSetting& option, const runtime::lua::Value&) {
      output.keep({.label = option.label, .detail = option.detail.valueOr(std::string_view{}), .value = option.value, .swatch = option.swatch, .selected = option.selected});
    });

    output.report(limits);
  }

  static_assert(features::components::no_reference == LUA_NOREF);

  template class ActionReferences<features::components::StagedContent::capacity.actions>;
  template void StagedActionReferences::keepOnly<features::components::bar_capacity>(const features::components::Content<features::components::bar_capacity>& content);
  template void StagedActionReferences::keepOnly<features::components::panel_capacity>(const features::components::Content<features::components::panel_capacity>& content);
  template void ContentReader::read<features::components::bar_capacity>(const runtime::lua::Value& value, features::components::BarContent& output);
  template void ContentReader::read<features::components::panel_capacity>(const runtime::lua::Value& value, features::components::PanelContent& output);
  template class ComponentSnapshot<features::components::bar_capacity>;
  template class ComponentSnapshot<features::components::panel_capacity>;

}
