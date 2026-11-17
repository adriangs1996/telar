module telar.gui.components.configuration;

import std;

import telar.base.diagnostics;
import telar.base.text;
import telar.base.text.utf8;
import telar.wire.vocabulary;
import telar.gui.foundation.core;

namespace telar::gui::components {

  unsigned Node::effectivePriority() const noexcept {
    unsigned bonus = 0;

    if (tone == Tone::warning) {
      bonus = warning_bonus;
    } else if (tone == Tone::danger) {
      bonus = danger_bonus;
    }

    return std::min<unsigned>(priority + bonus, std::numeric_limits<std::uint8_t>::max());
  }

  bool Node::container() const noexcept {
    return kind == Kind::group || kind == Kind::callout || kind == Kind::actions;
  }

  template <Capacity Bounds>
  std::uint8_t Content<Bounds>::append(const Input& input) {
    if (node_count_ == Bounds.nodes) {
      throw std::length_error{"TooManyBarComponents"};
    }

    validateParent(input.node);
    if (input.node.value > Node::full_scale || input.node.marker.value_or(0) > Node::full_scale) {
      throw std::invalid_argument{"InvalidBarValue"};
    }

    if (input.samples.size() > Node::maximum_samples || input.samples.size() > Bounds.samples - sample_length_) {
      throw std::length_error{"TooManyBarSamples"};
    }

    if (input.action && action_count_ == Bounds.actions) {
      throw std::length_error{"TooManyBarActions"};
    }

    auto remaining = Bounds.text - text_length_;

    for (const auto value : {input.text, input.detail, input.url}) {
      if (value.size() > remaining) {
        throw std::length_error{"BarTextTooLong"};
      }

      remaining -= value.size();
      validateText(value);
    }

    validateUrl(input.url);
    auto node = input.node;

    node.priority = std::min(node.priority, Node::maximum_priority);
    node.text = copyText(input.text);
    node.detail = copyText(input.detail);
    node.url = copyText(input.url);
    node.samples = {.offset = static_cast<std::uint16_t>(sample_length_), .length = static_cast<std::uint16_t>(input.samples.size())};
    std::ranges::copy(input.samples, samples_.begin() + static_cast<std::ptrdiff_t>(sample_length_));
    sample_length_ += input.samples.size();
    node.action = Node::no_action;
    if (input.action) {
      node.action = static_cast<std::uint8_t>(action_count_);
      actions_[action_count_++] = *input.action;
    }

    const auto index = node_count_++;

    nodes_[index] = node;

    return static_cast<std::uint8_t>(index);
  }

  template <Capacity Bounds>
  void Content<Bounds>::clear() noexcept {
    node_count_ = 0;
    text_length_ = 0;
    sample_length_ = 0;
    action_count_ = 0;
  }

  template <Capacity Bounds>
  std::span<const Node> Content<Bounds>::nodes() const noexcept {
    return std::span{nodes_}.first(node_count_);
  }

  template <Capacity Bounds>
  bool Content<Bounds>::empty() const noexcept {
    return node_count_ == 0;
  }

  template <Capacity Bounds>
  std::string_view Content<Bounds>::text(Range range) const {
    validateRange(range, text_length_);
    if (range.length == 0) {
      return {};
    }

    return {text_.data() + range.offset, range.length};
  }

  template <Capacity Bounds>
  std::span<const std::uint8_t> Content<Bounds>::samples(const Node& node) const {
    validateRange(node.samples, sample_length_);

    return std::span{samples_}.subspan(node.samples.offset, node.samples.length);
  }

  template <Capacity Bounds>
  std::optional<BindingAction> Content<Bounds>::action(const Node& node) const {
    if (node.action == Node::no_action) {
      return std::nullopt;
    }

    if (node.action >= action_count_) {
      throw std::out_of_range{"InvalidBarAction"};
    }

    return actions_[node.action];
  }

  template <Capacity Bounds>
  Input Content<Bounds>::inputAt(std::size_t index) const {
    if (index >= node_count_) {
      throw std::out_of_range{"InvalidBarComponent"};
    }

    const auto& node = nodes_[index];

    return {.node = node, .text = text(node.text), .detail = text(node.detail), .url = text(node.url), .samples = samples(node), .action = action(node)};
  }

  template <Capacity Bounds>
  template <Capacity SourceBounds>
  void Content<Bounds>::keepFitting(const Content<SourceBounds>& source, const Parents* known_children) {
    if (static_cast<const void*>(this) == static_cast<const void*>(&source)) {
      throw std::invalid_argument{"Component fitting requires a distinct source"};
    }

    const auto count = source.nodes().size();
    std::array<unsigned, Node::maximum_nodes> ranks{};
    std::array<std::uint8_t, Node::maximum_nodes> order{};
    auto empty_containers = known_children == nullptr ? Parents{} : *known_children;

    for (std::size_t index = 0; index < count; ++index) {
      const auto& node = source.nodes()[index];

      ranks[index] = node.effectivePriority();
      order[index] = static_cast<std::uint8_t>(index);
      if (node.parent != Node::no_parent) {
        ranks[index] = std::min(ranks[index], ranks[node.parent]);
        empty_containers[node.parent] = false;
      }
    }

    const auto sorted = std::span{order}.first(count);

    std::ranges::sort(sorted, [&](auto left, auto right) {
      return ranks[left] == ranks[right] ? left < right : ranks[left] > ranks[right];
    });

    Parents kept{};
    Usage used;

    for (const auto index : sorted) {
      const auto& node = source.nodes()[index];
      if (empty_containers[index] || (node.parent != Node::no_parent && !kept[node.parent])) {
        continue;
      }

      const auto next = used.with(node);
      if (next.fits(Bounds)) {
        kept[index] = true;
        used = next;
      }
    }

    dropEmpty(source.nodes(), kept, known_children);
    clear();
    std::array<std::uint8_t, Node::maximum_nodes> copied{};

    for (std::size_t index = 0; index < count; ++index) {
      if (!kept[index]) {
        continue;
      }

      auto input = source.inputAt(index);
      if (input.node.parent != Node::no_parent) {
        input.node.parent = copied[input.node.parent];
      }

      copied[index] = append(input);
    }
  }

  template <Capacity Bounds>
  void Content<Bounds>::dropEmpty(std::span<const Node> source, Parents& kept, const Parents* known_children) noexcept {
    auto had_children = known_children == nullptr ? Parents{} : *known_children;
    std::array<std::uint8_t, Node::maximum_nodes> children{};

    for (std::size_t index = 0; index < source.size(); ++index) {
      const auto& node = source[index];
      if (node.parent != Node::no_parent) {
        had_children[node.parent] = true;
        if (kept[index]) {
          ++children[node.parent];
        }
      }
    }

    for (auto index = source.size(); index-- > 0;) {
      if (kept[index] && had_children[index] && children[index] == 0) {
        kept[index] = false;
        const auto& node = source[index];
        if (node.parent != Node::no_parent) {
          --children[node.parent];
        }
      }
    }
  }

  template <Capacity Bounds>
  void Content<Bounds>::validateParent(const Node& node) const {
    if (node.parent == Node::no_parent) {
      if (node.tooltip) {
        throw std::invalid_argument{"InvalidBarParent"};
      }

      return;
    }

    if (node.parent >= node_count_ || !nodes_[node.parent].container() || (node.tooltip && nodes_[node.parent].kind != Kind::group)) {
      throw std::invalid_argument{"InvalidBarParent"};
    }
  }

  template <Capacity Bounds>
  void Content<Bounds>::validateText(std::string_view value) {
    validateUtf8(value);
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_control = 0x7f;
    if (std::ranges::any_of(value, [](unsigned char byte) {
          return byte < first_printable || byte == delete_control;
        })) {
      throw std::invalid_argument{"InvalidBarText"};
    }
  }

  template <Capacity Bounds>
  void Content<Bounds>::validateUrl(std::string_view value) {
    constexpr std::size_t maximum_url_bytes = 1024;
    if (!value.empty() && (value.size() > maximum_url_bytes || value.contains(' ') || (!value.starts_with("https://") && !value.starts_with("http://")))) {
      throw std::invalid_argument{"InvalidBarUrl"};
    }
  }

  template <Capacity Bounds>
  void Content<Bounds>::validateRange(Range range, std::size_t length) {
    if (range.offset > length || range.length > length - range.offset) {
      throw std::out_of_range{"InvalidBarContentRange"};
    }
  }

  template <Capacity Bounds>
  Range Content<Bounds>::copyText(std::string_view value) noexcept {
    const Range range{.offset = static_cast<std::uint16_t>(text_length_), .length = static_cast<std::uint16_t>(value.size())};

    std::ranges::copy(value, text_.begin() + static_cast<std::ptrdiff_t>(text_length_));
    text_length_ += value.size();

    return range;
  }

  template <Capacity Bounds>
  typename Content<Bounds>::Usage Content<Bounds>::Usage::with(const Node& node) const noexcept {
    return {.nodes = nodes + 1, .text = text + node.text.length + node.detail.length + node.url.length, .samples = samples + node.samples.length, .actions = actions + (node.action != Node::no_action ? 1 : 0)};
  }

  template <Capacity Bounds>
  bool Content<Bounds>::Usage::fits(Capacity room) const noexcept {
    return nodes <= room.nodes && text <= room.text && samples <= room.samples && actions <= room.actions;
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

    references_[count_++] = action;
  }

  template <std::size_t MaximumReferences>
  bool ActionReferences<MaximumReferences>::contains(BindingAction action) const noexcept {
    return std::ranges::contains(std::span{references_}.first(count_), action);
  }

  template <std::size_t MaximumReferences>
  template <Capacity Bounds>
  void ActionReferences<MaximumReferences>::keepOnly(const Content<Bounds>& content) {
    std::size_t kept = 0;

    for (const auto retained : std::span{references_}.first(count_)) {
      const bool used = std::ranges::any_of(content.nodes(), [&](const Node& node) {
        const auto action = content.action(node);

        return action == retained;
      });
      if (used) {
        references_[kept++] = retained;
      } else {
        luaL_unref(state_, LUA_REGISTRYINDEX, retained.reference);
      }
    }

    count_ = kept;
  }

  template <std::size_t MaximumReferences>
  void ActionReferences<MaximumReferences>::swap(ActionReferences& other) noexcept {
    std::swap(state_, other.state_);
    references_.swap(other.references_);
    std::swap(count_, other.count_);
  }

  template <std::size_t MaximumReferences>
  void ActionReferences<MaximumReferences>::clear() noexcept {
    for (const auto retained : std::span{references_}.first(count_)) {
      luaL_unref(state_, LUA_REGISTRYINDEX, retained.reference);
    }

    count_ = 0;
  }

  ActionReader::ActionReader(const ComponentActions& reader, StagedActionReferences& references, std::uint32_t& next_reference) noexcept
      : reader_(reader),
        references_(references),
        next_reference_(next_reference) {}

  std::optional<BindingAction> ActionReader::read(const runtime::lua::Value& value) const {
    auto action = reader_.read(value);
    if (action && action->kind == BindingActionKind::extended) {
      if (next_reference_ == static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())) {
        references_.keep(*action);

        throw std::length_error{"Component action identity exhausted"};
      }

      action->parameter = -static_cast<std::int32_t>(++next_reference_);
      references_.keep(*action);
    }

    return action;
  }

  ComponentColors::Color ComponentColors::index(std::uint8_t index) const noexcept {
    return CellColor{.kind = CellColor::Kind::indexed, .channels = {index, 0, 0}};
  }

  std::optional<ComponentColors::Color> ComponentColors::name(std::string_view name) const noexcept {
    return ColorName::parse(name);
  }

  runtime::FixedText<Node::maximum_icon_bytes> ValueMapper::iconName(std::string_view name) {
    std::array<char, Node::maximum_icon_bytes> normalized{};
    if (name.size() > normalized.size()) {
      throw std::invalid_argument{"Component icon name exceeds its limit"};
    }

    std::ranges::transform(name, normalized.begin(), [](char byte) {
      return byte == '-' ? '_' : runtime::asciiLower(byte);
    });

    runtime::FixedText<Node::maximum_icon_bytes> result;

    result.assign({normalized.data(), name.size()});

    return result;
  }

  std::optional<runtime::FixedText<Node::maximum_icon_bytes>> ValueMapper::icon(const std::optional<std::string_view>& name) {
    return name ? std::optional{iconName(*name)} : std::nullopt;
  }

  std::optional<Mark> ValueMapper::mark(std::optional<runtime::config::UiMark> mark) noexcept {
    return mark ? std::optional{static_cast<Mark>(std::to_underlying(*mark))} : std::nullopt;
  }

  Tone ValueMapper::tone(runtime::config::ComponentTone tone) noexcept {
    return static_cast<Tone>(std::to_underlying(tone));
  }

  std::uint16_t ValueMapper::fraction(double number) noexcept {
    return static_cast<std::uint16_t>(std::round(std::clamp(number, 0.0, 1.0) * Node::full_scale));
  }

  ContentReader::ContentReader(lua_State& state, const ComponentActions& actions, runtime::config::LimitNotices& limits, StagedContent& staged, Surface surface)
      : state_(state),
        builder_{.actions_ = actions, .limits_ = limits, .staged_ = staged, .surface_ = surface} {}

  template <Capacity Bounds>
  void ContentReader::read(const runtime::lua::Value& value, Content<Bounds>& output) {
    builder_.budget_ = {};
    builder_.demand_ = {};
    builder_.had_children_.fill(false);
    builder_.counting_ = true;
    builder_.staged_.clear();
    const Position root{.place = builder_.surface_ == Surface::bar ? Place::bar : Place::panel};
    runtime::config::ComponentWalker walker{state_, builder_, builder_.limits_};

    walker.walk(value, root);
    builder_.budget_.prepare();
    builder_.counting_ = false;
    walker.walk(value, root);
    output.keepFitting(builder_.staged_, &builder_.had_children_);
    builder_.report(Bounds);
  }

  std::optional<ContentReader::Parent> ContentReader::Builder::node(const runtime::lua::Value& value, const Shape& shape, const Position& position) {
    const auto values = runtime::config::ComponentValuesReader::read(value, shape, ComponentColors{});
    Input input;

    input.node.kind = shape.kind;
    input.node.priority = static_cast<std::uint8_t>(shape.priority);
    input.node.tone = ValueMapper::tone(values.tone);
    input.node.style = {.foreground = values.foreground, .background = values.background, .bold = values.bold, .italic = values.italic, .faint = values.faint, .underline = values.underline, .strikethrough = values.strikethrough};
    input.node.icon = ValueMapper::icon(values.icon);
    input.node.mark = ValueMapper::mark(values.mark);
    input.node.metric = static_cast<BarMetric>(std::to_underlying(values.metric));
    input.node.value = ValueMapper::fraction(values.value.value_or(0));
    input.node.marker = values.marker ? std::optional{ValueMapper::fraction(*values.marker)} : std::nullopt;
    input.node.primary = values.primary;
    input.text = shape.text;
    input.detail = shape.detail;
    input.url = shape.url;
    input.samples = std::span{values.samples}.first(values.sample_count);

    return append(value, shape, input, position);
  }

  std::optional<ContentReader::Parent> ContentReader::Builder::append(const runtime::lua::Value& value, const Shape& shape, Input& input, const Position& position) {
    const auto rank = std::min(shape.priority + shape.tone_bonus, position.rank);

    if (counting_) {
      budget_.count(shape, rank);
      demand_ = demand_ + usage(shape);

      return Parent{.index = 0, .rank = rank};
    }

    if (position.parent != Node::no_parent) {
      had_children_[position.parent] = true;
    }

    if (!budget_.admit(shape, rank)) {
      return std::nullopt;
    }

    if (shape.action_field != nullptr) {
      input.action = runtime::config::ComponentValuesReader::action(value, shape, [&](const runtime::lua::Value& action) {
        return actions_.read(action);
      });

      if (!input.action) {
        budget_.release(shape, rank);

        return std::nullopt;
      }
    }

    if (!budget_.stage(shape)) {
      return std::nullopt;
    }

    input.node.parent = position.parent;
    input.node.tooltip = position.place == Place::tooltip;

    return Parent{.index = staged_.append(input), .rank = rank};
  }

  runtime::config::ComponentBudget::Usage ContentReader::Builder::usage(const Shape& shape) noexcept {
    return {.nodes = 1, .text = shape.text.size() + shape.detail.size() + shape.url.size(), .actions = shape.action_field == nullptr ? 0U : 1U, .samples = shape.samples};
  }

  void ContentReader::Builder::report(Capacity bounds) {
    const bool panel = surface_ == Surface::panel;
    const auto reaches = std::to_array<LimitReach>({
        {.name = panel ? "panels.max_panel_nodes" : "bars.max_bar_nodes", .noun = "components", .value = bounds.nodes, .requested = demand_.nodes, .route = {}},
        {.name = panel ? "panels.max_panel_text_bytes" : "bars.max_bar_text_bytes", .noun = "text bytes", .value = bounds.text, .requested = demand_.text, .route = {}},
        {.name = panel ? "panels.max_panel_actions" : "bars.max_bar_actions", .noun = "click actions", .value = bounds.actions, .requested = demand_.actions, .route = {}},
        {.name = panel ? "panels.max_samples" : "bars.max_samples", .noun = "sparkline samples", .value = bounds.samples, .requested = demand_.samples, .route = {}},
    });

    for (const auto& reach : reaches) {
      if (reach.requested.value_or(0) > reach.value) {
        limits_.add(reach);
      }
    }
  }

  template <Capacity Bounds>
  Snapshot<Bounds>::Snapshot(lua_State& state) noexcept
      : state_(state),
        references_(state) {}

  template <Capacity Bounds>
  void Snapshot<Bounds>::read(const runtime::lua::Value& value, const ComponentActions& actions, runtime::config::LimitNotices& limits, StagedContent& staged, std::uint32_t& next_reference) {
    StagedActionReferences pending{state_};
    const ActionReader reader{actions, pending, next_reference};
    Content<Bounds> next;
    constexpr auto surface = Bounds.nodes == PanelContent::capacity.nodes ? Surface::panel : Surface::bar;

    ContentReader{state_, reader, limits, staged, surface}.read(value, next);
    pending.keepOnly(next);
    references_.swap(pending);
    content_ = std::move(next);
  }

  template <Capacity Bounds>
  const Content<Bounds>& Snapshot<Bounds>::content() const noexcept {
    return content_;
  }

  template <Capacity Bounds>
  bool Snapshot<Bounds>::contains(BindingAction action) const noexcept {
    return references_.contains(action);
  }

  template <Capacity Bounds>
  void Snapshot<Bounds>::clear() noexcept {
    references_.clear();
    content_.clear();
  }

  Source Source::read(lua_State& state, const runtime::lua::Value& value, bool panel) {
    if (!value.present()) {
      return {};
    }

    return read(state, value, runtime::config::SourceReader::read(value, panel));
  }

  Source Source::read(lua_State& state, const runtime::lua::Value& value, const runtime::config::SourceSetting& setting) {
    Source result;

    result.kind = static_cast<SourceKind>(std::to_underlying(setting.kind) + 1);
    if (setting.every_ms) {
      result.interval = std::chrono::milliseconds{*setting.every_ms};
    }

    result.has_render = setting.render;
    result.timeout = std::chrono::milliseconds{setting.timeout_ms};
    value.pushCopy();
    result.reference = luaL_ref(&state, LUA_REGISTRYINDEX);

    return result;
  }

  void Heading::assign(const runtime::config::DefinitionHeading& heading) {
    name.assign(heading.name);
    title.assign(heading.title);
  }

  Definitions::Definitions() noexcept {
    slots_.fill(LUA_NOREF);
    sources_[static_cast<std::size_t>(Position::bottom_left)].kind = SourceKind::metrics;
    sources_[static_cast<std::size_t>(Position::bottom_right)].kind = SourceKind::tabs;
    sources_[static_cast<std::size_t>(Position::footer_left)].kind = SourceKind::metrics;
  }

  void Definitions::apply(lua_State& state, const runtime::lua::Value& client) {
    if (!client.present()) {
      return;
    }

    runtime::config::BarsReader::sources(client, [&](runtime::config::BarPosition position, const runtime::lua::Value& source) {
      sources_[std::to_underlying(position)] = Source::read(state, source);
    });

    runtime::config::ClientReader::slots(client, [&](std::size_t slot, const runtime::lua::Value& function) {
      auto& reference = slots_[slot];
      if (reference != LUA_NOREF) {
        luaL_unref(&state, LUA_REGISTRYINDEX, reference);
      }

      function.pushCopy();
      reference = luaL_ref(&state, LUA_REGISTRYINDEX);
    });

    // SnapshotReader reported the definitions' limits.
    runtime::config::LimitNotices limits;
    const auto counts = runtime::config::ClientDefinitionsReader::read(
        client,
        limits,
        [&](std::size_t index, const runtime::config::PanelSetting& setting, const runtime::lua::Value& source) {
          auto& panel = panels_[index];

          panel.heading.assign(setting.heading);
          panel.width = setting.width;
          panel.mark = ValueMapper::mark(setting.mark);
          panel.icon = ValueMapper::icon(setting.icon);
          panel.source = Source::read(state, source, setting.source);
        },
        [&](std::size_t index, const runtime::config::PickSetting& setting, const runtime::lua::Value& definition) {
          auto& pick = picks_[index];

          pick.heading.assign(setting.heading);
          pick.timeout = std::chrono::milliseconds{setting.timeout_ms};
          pick.command = setting.command;
          pick.render = setting.render;
          pick.refresh = setting.refresh;
          definition.pushCopy();
          pick.reference = luaL_ref(&state, LUA_REGISTRYINDEX);
        }
    );

    panel_count_ = counts.panels.value_or(panel_count_);
    pick_count_ = counts.picks.value_or(pick_count_);
  }

  const Source& Definitions::source(Position position) const {
    return sources_.at(static_cast<std::size_t>(position));
  }

  int Definitions::slot(Slot slot) const noexcept {
    return slots_[static_cast<std::size_t>(slot)];
  }

  bool Definitions::drawsAny() const noexcept {
    return std::ranges::any_of(slots_, [](int reference) {
      return reference != LUA_NOREF;
    });
  }

  std::span<const Panel> Definitions::panels() const noexcept {
    return std::span{panels_}.first(panel_count_);
  }

  std::span<const Pick> Definitions::picks() const noexcept {
    return std::span{picks_}.first(pick_count_);
  }

  Configuration::Configuration(lua_State& state)
      : state_(state),
        bars_{BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}},
        panel_(state) {}

  Definitions& Configuration::definitions() noexcept {
    return definitions_;
  }

  const Definitions& Configuration::definitions() const noexcept {
    return definitions_;
  }

  void Configuration::readFixedSources(const ComponentActions& actions, runtime::config::LimitNotices& limits) {
    const runtime::lua::Value registry{&state_, LUA_REGISTRYINDEX, "bar registry"};

    for (std::size_t index = 0; index < bars_.size(); ++index) {
      const auto& source = definitions_.source(static_cast<Position>(index));
      if (source.kind == SourceKind::fixed) {
        const auto value = registry.element(source.reference);

        bars_[index].read(runtime::config::BarsReader::content(value), actions, limits, staged_, next_reference_);
      }
    }
  }

  void Configuration::readBarContent(Position position, const runtime::lua::Value& value, const ComponentActions& actions, runtime::config::LimitNotices& limits) {
    bars_.at(static_cast<std::size_t>(position)).read(value, actions, limits, staged_, next_reference_);
  }

  void Configuration::readPanelContent(const runtime::lua::Value& value, const ComponentActions& actions, runtime::config::LimitNotices& limits) {
    panel_.read(value, actions, limits, staged_, next_reference_);
  }

  const BarContent& Configuration::bar(Position position) const {
    return bars_.at(static_cast<std::size_t>(position)).content();
  }

  const PanelContent& Configuration::panel() const noexcept {
    return panel_.content();
  }

  void Configuration::closePanel() noexcept {
    panel_.clear();
  }

  bool Configuration::contains(BindingAction action) const noexcept {
    return panel_.contains(action) || std::ranges::any_of(bars_, [action](const auto& bar) {
      return bar.contains(action);
    });
  }

  template class Content<bar_capacity>;
  template class Content<panel_capacity>;
  template class Content<staging_capacity>;
  template void BarContent::keepFitting<staging_capacity>(const StagedContent& source, const Parents* known_children);
  template void PanelContent::keepFitting<staging_capacity>(const StagedContent& source, const Parents* known_children);
  template class ActionReferences<StagedContent::capacity.actions>;
  template void StagedActionReferences::keepOnly<bar_capacity>(const Content<bar_capacity>& content);
  template void StagedActionReferences::keepOnly<panel_capacity>(const Content<panel_capacity>& content);
  template void ContentReader::read<bar_capacity>(const runtime::lua::Value& value, BarContent& output);
  template void ContentReader::read<panel_capacity>(const runtime::lua::Value& value, PanelContent& output);
  template class Snapshot<bar_capacity>;
  template class Snapshot<panel_capacity>;

}
