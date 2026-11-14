module;
#include "tbc/view.hpp"
#include <cstdlib>
#include <new>

#include <cstddef>
#include <cstdint>
#include <cstring>

#include <cmath>
#include <cstdio>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

#include <cinttypes>

export module telar.gui.components.configuration;

import std;

export import telar.gui.core.metrics;
export import telar.gui.input.copy_pointer;
export import telar.config.client;

export import telar.lua;

export import telar.base.memory.containers;
import telar.base.diagnostics;
import telar.base.text;
import telar.base.text.utf8;
import telar.gui.presentation.history_filter_geometry;
import telar.wire.vocabulary;

// Interface: components/node.cppm
export {
  namespace telar::gui::components {

    using Kind = runtime::config::ComponentKind;

    enum class Tone : std::uint8_t {
      neutral,
      muted,
      accent,
      success,
      warning,
      danger,
    };

    enum class Mark : std::uint8_t {
      claude,
      codex,
      pi,
      telar,
    };

    struct Style {
      std::optional<ColorName::Value> foreground = std::nullopt;
      std::optional<ColorName::Value> background = std::nullopt;
      bool bold = false;
      bool italic = false;
      bool faint = false;
      bool underline = false;
      bool strikethrough = false;
    };

    struct Range {
      std::uint16_t offset = 0;
      std::uint16_t length = 0;
    };

    struct Node {
      static constexpr std::uint8_t no_parent = std::numeric_limits<std::uint8_t>::max();
      static constexpr std::uint8_t no_action = no_parent;
      static constexpr std::size_t maximum_nodes = no_parent - 1;
      static constexpr std::size_t maximum_samples = 120;
      static constexpr std::size_t maximum_icon_bytes = 32;
      static constexpr std::uint8_t default_priority = 50;
      static constexpr std::uint8_t maximum_priority = 100;
      static constexpr std::uint16_t full_scale = 1000;
      static constexpr std::uint8_t warning_bonus = 20;
      static constexpr std::uint8_t danger_bonus = 40;

      Kind kind = Kind::label;
      std::uint8_t parent = no_parent;
      bool tooltip = false;
      Range text{};
      Range detail{};
      Range url{};
      Range samples{};
      std::optional<runtime::FixedText<maximum_icon_bytes>> icon = std::nullopt;
      std::optional<Mark> mark = std::nullopt;
      BarMetric metric = BarMetric::cpu;
      Tone tone = Tone::neutral;
      Style style{};
      std::uint16_t value = 0;
      std::optional<std::uint16_t> marker = std::nullopt;
      std::uint8_t priority = default_priority;
      bool primary = false;
      std::uint8_t action = no_action;

      [[nodiscard]] inline unsigned effectivePriority() const noexcept {
        unsigned bonus = 0;

        if (tone == Tone::warning) {
          bonus = warning_bonus;
        } else if (tone == Tone::danger) {
          bonus = danger_bonus;
        }

        return std::min<unsigned>(priority + bonus, std::numeric_limits<std::uint8_t>::max());
      }

      [[nodiscard]] inline bool container() const noexcept {
        return kind == Kind::group || kind == Kind::callout || kind == Kind::actions;
      }
    };

    struct Input {
      Node node{};
      std::string_view text;
      std::string_view detail;
      std::string_view url;
      std::span<const std::uint8_t> samples;
      std::optional<BindingAction> action = std::nullopt;
    };

  }
}

// Interface: components/content.cppm
export {
  namespace telar::gui::components {

    struct Capacity {
      std::size_t nodes;
      std::size_t text;
      std::size_t samples;
      std::size_t actions;
    };

    template <Capacity Bounds>
    class Content {
      static_assert(Bounds.nodes <= Node::maximum_nodes && Bounds.actions <= Node::maximum_nodes);
      static_assert(Bounds.text <= std::numeric_limits<std::uint16_t>::max() && Bounds.samples <= std::numeric_limits<std::uint16_t>::max());

    public:
      static constexpr auto capacity = Bounds;
      using Parents = std::array<bool, Node::maximum_nodes>;

      // Validate and reserve the complete node before changing any owned storage.
      inline std::uint8_t append(const Input& input) {
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

      inline void clear() noexcept {
        node_count_ = 0;
        text_length_ = 0;
        sample_length_ = 0;
        action_count_ = 0;
      }

      [[nodiscard]] inline std::span<const Node> nodes() const noexcept {
        return std::span{nodes_}.first(node_count_);
      }

      [[nodiscard]] inline bool empty() const noexcept {
        return node_count_ == 0;
      }

      [[nodiscard]] inline std::string_view text(Range range) const {
        validateRange(range, text_length_);
        if (range.length == 0) {
          return {};
        }

        return {text_.data() + range.offset, range.length};
      }

      [[nodiscard]] inline std::span<const std::uint8_t> samples(const Node& node) const {
        validateRange(node.samples, sample_length_);

        return std::span{samples_}.subspan(node.samples.offset, node.samples.length);
      }

      [[nodiscard]] inline std::optional<BindingAction> action(const Node& node) const {
        if (node.action == Node::no_action) {
          return std::nullopt;
        }

        if (node.action >= action_count_) {
          throw std::out_of_range{"InvalidBarAction"};
        }

        return actions_[node.action];
      }

      [[nodiscard]] inline Input inputAt(std::size_t index) const {
        if (index >= node_count_) {
          throw std::out_of_range{"InvalidBarComponent"};
        }

        const auto& node = nodes_[index];

        return {.node = node, .text = text(node.text), .detail = text(node.detail), .url = text(node.url), .samples = samples(node), .action = action(node)};
      }

      // Rank children with their container, reserve by priority, then copy in document order.
      template <Capacity SourceBounds>
      inline void keepFitting(const Content<SourceBounds>& source, const Parents* known_children = nullptr) {
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

    private:
      struct Usage {
        std::size_t nodes = 0;
        std::size_t text = 0;
        std::size_t samples = 0;
        std::size_t actions = 0;

        [[nodiscard]] inline Usage with(const Node& node) const noexcept {
          return {.nodes = nodes + 1, .text = text + node.text.length + node.detail.length + node.url.length, .samples = samples + node.samples.length, .actions = actions + (node.action != Node::no_action ? 1 : 0)};
        }

        [[nodiscard]] inline bool fits(Capacity room) const noexcept {
          return nodes <= room.nodes && text <= room.text && samples <= room.samples && actions <= room.actions;
        }
      };

      inline static void dropEmpty(std::span<const Node> source, Parents& kept, const Parents* known_children) noexcept {
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

      inline void validateParent(const Node& node) const {
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

      inline static void validateText(std::string_view value) {
        validateUtf8(value);
        constexpr unsigned char first_printable = 0x20;
        constexpr unsigned char delete_control = 0x7f;
        if (std::ranges::any_of(value, [](unsigned char byte) {
              return byte < first_printable || byte == delete_control;
            })) {
          throw std::invalid_argument{"InvalidBarText"};
        }
      }

      inline static void validateUrl(std::string_view value) {
        constexpr std::size_t maximum_url_bytes = 1024;
        if (!value.empty() && (value.size() > maximum_url_bytes || value.contains(' ') || (!value.starts_with("https://") && !value.starts_with("http://")))) {
          throw std::invalid_argument{"InvalidBarUrl"};
        }
      }

      inline static void validateRange(Range range, std::size_t length) {
        if (range.offset > length || range.length > length - range.offset) {
          throw std::out_of_range{"InvalidBarContentRange"};
        }
      }

      inline Range copyText(std::string_view value) noexcept {
        const Range range{.offset = static_cast<std::uint16_t>(text_length_), .length = static_cast<std::uint16_t>(value.size())};

        std::ranges::copy(value, text_.begin() + static_cast<std::ptrdiff_t>(text_length_));
        text_length_ += value.size();

        return range;
      }

      std::array<Node, Bounds.nodes> nodes_{};
      std::array<char, Bounds.text> text_{};
      std::array<std::uint8_t, Bounds.samples> samples_{};
      std::array<BindingAction, Bounds.actions> actions_{};
      std::size_t node_count_ = 0;
      std::size_t text_length_ = 0;
      std::size_t sample_length_ = 0;
      std::size_t action_count_ = 0;
    };

    inline constexpr Capacity bar_capacity{.nodes = 64, .text = 4096, .samples = 256, .actions = 32};
    inline constexpr Capacity panel_capacity{.nodes = 128, .text = std::size_t{16} * std::size_t{1024}, .samples = 1024, .actions = 32};
    inline constexpr Capacity staging_capacity{.nodes = Node::maximum_nodes, .text = std::size_t{32} * std::size_t{1024}, .samples = 2048, .actions = 64};
    using BarContent = Content<bar_capacity>;
    using PanelContent = Content<panel_capacity>;
    using StagedContent = Content<staging_capacity>;

  }
}

// Interface: components/action_references.cppm
export {
  namespace telar::gui::components {

    template <std::size_t MaximumReferences>
    class ActionReferences {
    public:
      inline explicit ActionReferences(lua_State& state) noexcept
          : state_(&state) {}

      inline ~ActionReferences() {
        clear();
      }

      ActionReferences(const ActionReferences&) = delete;
      ActionReferences& operator=(const ActionReferences&) = delete;
      ActionReferences(ActionReferences&&) = delete;
      ActionReferences& operator=(ActionReferences&&) = delete;

      inline void keep(BindingAction action) {
        if (action.kind != BindingActionKind::extended) {
          return;
        }

        if (count_ == MaximumReferences) {
          luaL_unref(state_, LUA_REGISTRYINDEX, action.reference);

          throw std::length_error{"Too many component action references"};
        }

        references_[count_++] = action;
      }

      [[nodiscard]] inline bool contains(BindingAction action) const noexcept {
        return std::ranges::contains(std::span{references_}.first(count_), action);
      }

      // Release actions omitted by the final fit, including empty containers.
      template <Capacity Bounds>
      inline void keepOnly(const Content<Bounds>& content) {
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

      inline void swap(ActionReferences& other) noexcept {
        std::swap(state_, other.state_);
        references_.swap(other.references_);
        std::swap(count_, other.count_);
      }

      inline void clear() noexcept {
        for (const auto retained : std::span{references_}.first(count_)) {
          luaL_unref(state_, LUA_REGISTRYINDEX, retained.reference);
        }

        count_ = 0;
      }

    private:
      lua_State* state_;
      std::array<BindingAction, MaximumReferences> references_{};
      std::size_t count_ = 0;
    };

    template <typename Reader, std::size_t Capacity>
    class ActionReader {
    public:
      inline explicit ActionReader(const Reader& reader, ActionReferences<Capacity>& references, std::uint32_t& next_reference) noexcept
          : reader_(reader),
            references_(references),
            next_reference_(next_reference) {}

      [[nodiscard]] inline std::optional<BindingAction> read(const runtime::lua::Value& value) const {
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

    private:
      const Reader& reader_;
      ActionReferences<Capacity>& references_;
      std::uint32_t& next_reference_;
    };

  }
}

// Interface: components/value_reader.cppm
export {
  namespace telar::gui::components {

    // The colors a configuration names, as the GUI draws them.
    struct ComponentColors {
      using Color = ColorName::Value;

      [[nodiscard]] inline Color index(std::uint8_t index) const noexcept {
        return CellColor{.kind = CellColor::Kind::indexed, .channels = {index, 0, 0}};
      }

      [[nodiscard]] inline std::optional<Color> name(std::string_view name) const noexcept {
        return ColorName::parse(name);
      }
    };

    // Maps what the configuration's readers read onto the GUI's nodes.
    class ValueMapper {
    public:
      // An icon name as the GUI keys it: lowercase, with underscores for hyphens.
      inline static runtime::FixedText<Node::maximum_icon_bytes> iconName(std::string_view name) {
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

      inline static std::optional<runtime::FixedText<Node::maximum_icon_bytes>> icon(const std::optional<std::string_view>& name) {
        return name ? std::optional{iconName(*name)} : std::nullopt;
      }

      inline static std::optional<Mark> mark(std::optional<runtime::config::UiMark> mark) noexcept {
        return mark ? std::optional{static_cast<Mark>(std::to_underlying(*mark))} : std::nullopt;
      }

      inline static Tone tone(runtime::config::ComponentTone tone) noexcept {
        return static_cast<Tone>(std::to_underlying(tone));
      }

      inline static std::uint16_t fraction(double number) noexcept {
        return static_cast<std::uint16_t>(std::round(std::clamp(number, 0.0, 1.0) * Node::full_scale));
      }

      static_assert(std::to_underlying(Tone::danger) == std::to_underlying(runtime::config::ComponentTone::danger));
      static_assert(std::to_underlying(BarMetric::battery) == std::to_underlying(runtime::config::ComponentMetric::battery));
      static_assert(Node::maximum_samples == runtime::config::ComponentValues<ComponentColors::Color>::maximum_samples);
    };

  }
}

// Interface: components/content_reader.cppm
export {
  namespace telar::gui::components {

    enum class Surface : std::uint8_t {
      bar,
      panel,
    };

    template <typename Actions>
    class ContentReader {
      using Place = runtime::config::ComponentPlace;
      using Position = runtime::config::ComponentPosition;
      using Parent = runtime::config::ComponentParent;
      using Shape = runtime::config::ComponentShape;

    public:
      static_assert(Node::no_parent == Position::no_parent && Node::default_priority == Position::default_priority);

      inline explicit ContentReader(lua_State& state, const Actions& actions, runtime::config::LimitNotices& limits, StagedContent& staged, Surface surface = Surface::bar)
          : state_(state),
            builder_{.actions_ = actions, .limits_ = limits, .staged_ = staged, .surface_ = surface} {}

      // Count before retaining actions so omitted components cannot retain commands.
      template <Capacity Bounds>
      inline void read(const runtime::lua::Value& value, Content<Bounds>& output) {
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

    private:
      // What the walk builds from each component it places.
      struct Builder {
        inline std::optional<Parent> node(const runtime::lua::Value& value, const Shape& shape, const Position& position) {
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

        inline std::optional<Parent> append(const runtime::lua::Value& value, const Shape& shape, Input& input, const Position& position) {
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

        inline static runtime::config::ComponentBudget::Usage usage(const Shape& shape) noexcept {
          return {.nodes = 1, .text = shape.text.size() + shape.detail.size() + shape.url.size(), .actions = shape.action_field == nullptr ? 0U : 1U, .samples = shape.samples};
        }

        inline void report(Capacity bounds) {
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

        const Actions& actions_;
        runtime::config::LimitNotices& limits_;
        StagedContent& staged_;
        Surface surface_;
        runtime::config::ComponentBudget budget_;
        runtime::config::ComponentBudget::Usage demand_;
        StagedContent::Parents had_children_{};
        bool counting_ = true;
      };

      lua_State& state_;
      Builder builder_;
    };

  }
}

// Interface: components/snapshot.cppm
export {
  namespace telar::gui::components {

    template <Capacity Bounds>
    class Snapshot {
    public:
      inline explicit Snapshot(lua_State& state) noexcept
          : state_(state),
            references_(state) {}

      template <typename Actions>
      inline void read(const runtime::lua::Value& value, const Actions& actions, runtime::config::LimitNotices& limits, StagedContent& staged, std::uint32_t& next_reference) {
        ActionReferences<StagedContent::capacity.actions> pending{state_};
        const ActionReader reader{actions, pending, next_reference};
        Content<Bounds> next;
        constexpr auto surface = Bounds.nodes == PanelContent::capacity.nodes ? Surface::panel : Surface::bar;

        ContentReader{state_, reader, limits, staged, surface}.read(value, next);
        pending.keepOnly(next);
        references_.swap(pending);
        content_ = std::move(next);
      }

      [[nodiscard]] inline const Content<Bounds>& content() const noexcept {
        return content_;
      }

      [[nodiscard]] inline bool contains(BindingAction action) const noexcept {
        return references_.contains(action);
      }

      inline void clear() noexcept {
        references_.clear();
        content_.clear();
      }

    private:
      lua_State& state_;
      ActionReferences<StagedContent::capacity.actions> references_;
      Content<Bounds> content_;
    };

    using BarSnapshot = Snapshot<BarContent::capacity>;
    using PanelSnapshot = Snapshot<PanelContent::capacity>;

  }
}

// Interface: components/source.cppm
export {
  namespace telar::gui::components {

    enum class Position : std::uint8_t {
      bottom_left,
      bottom_center,
      bottom_right,
      top_right,
      footer_left,
      footer_center,
      footer_right,
      count,
    };

    enum class SourceKind : std::uint8_t {
      empty,
      tabs,
      metrics,
      machines,
      fixed,
      dynamic,
      command,
    };

    // The interface pieces a mod may draw, under `client.components`.
    enum class Slot : std::uint8_t {
      top_bar,
      bottom_bar,
      tab,
      pane_header,
      agent_card,
      tab_cards,
      tab_title,
      tab_path,
      tab_activity,
      pane_mark,
      pane_program,
      pane_context,
      pane_status,
      pane_progress,
      pane_actions,
      agent_mark,
      agent_title,
      agent_project,
      agent_status,
      count,
    };

    inline constexpr const auto& slot_names = runtime::config::component_slots;
    static_assert(slot_names.size() == static_cast<std::size_t>(Slot::count) && slot_names[static_cast<std::size_t>(Slot::agent_status)] == "agent_status");
    // The positions, the source kinds after `empty` and the marks follow the configuration's.
    static_assert(std::to_underlying(Position::footer_right) == std::to_underlying(runtime::config::BarPosition::footer_right));
    static_assert(std::to_underlying(SourceKind::command) == std::to_underlying(runtime::config::SourceKind::command) + 1);
    static_assert(std::to_underlying(Mark::telar) == std::to_underlying(runtime::config::UiMark::telar));

    struct Source {
      static constexpr std::chrono::milliseconds default_interval{1000};
      static constexpr std::chrono::milliseconds default_timeout{2000};
      static constexpr std::uint64_t minimum_interval_ms = 100;
      static constexpr std::uint64_t maximum_interval_ms = 3600000;
      static constexpr std::uint64_t minimum_timeout_ms = 100;
      static constexpr std::uint64_t maximum_timeout_ms = 10000;
      SourceKind kind = SourceKind::empty;
      std::optional<std::chrono::milliseconds> interval = std::nullopt;
      std::chrono::milliseconds timeout = default_timeout;
      int reference = LUA_NOREF;
      bool has_render = false;

      inline static Source read(lua_State& state, const runtime::lua::Value& value, bool panel = false) {
        if (!value.present()) {
          return {};
        }

        return read(state, value, runtime::config::SourceReader::read(value, panel));
      }

      // Keeps the source's table in the registry, where its render function and command are.
      inline static Source read(lua_State& state, const runtime::lua::Value& value, const runtime::config::SourceSetting& setting) {
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
    };

    struct Heading {
      static constexpr std::size_t maximum_name_bytes = 32;
      static constexpr std::size_t maximum_title_bytes = 128;
      runtime::FixedText<maximum_name_bytes> name;
      runtime::FixedText<maximum_title_bytes> title;

      inline void assign(const runtime::config::DefinitionHeading& heading) {
        name.assign(heading.name);
        title.assign(heading.title);
      }
    };

    struct Panel {
      static constexpr std::uint16_t default_width = 420;
      static constexpr std::uint16_t minimum_width = 240;
      static constexpr std::uint16_t maximum_width = 720;
      Heading heading;
      Source source;
      std::optional<Mark> mark = std::nullopt;
      std::optional<runtime::FixedText<Node::maximum_icon_bytes>> icon = std::nullopt;
      std::uint16_t width = default_width;
    };

    struct Pick {
      static constexpr std::uint64_t maximum_timeout_ms = 60000;
      Heading heading;
      std::chrono::milliseconds timeout = Source::default_timeout;
      int reference = LUA_NOREF;
      bool command = false;
      bool render = false;
      bool refresh = true;
    };

    class Definitions {
    public:
      static constexpr std::size_t positions = static_cast<std::size_t>(Position::count);
      static constexpr std::size_t maximum_definitions = 16;

      inline Definitions() noexcept {
        sources_[static_cast<std::size_t>(Position::bottom_left)].kind = SourceKind::metrics;
        sources_[static_cast<std::size_t>(Position::bottom_right)].kind = SourceKind::tabs;
        sources_[static_cast<std::size_t>(Position::footer_left)].kind = SourceKind::metrics;
      }

      inline void apply(lua_State& state, const runtime::lua::Value& client) {
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

      [[nodiscard]] inline const Source& source(Position position) const {
        return sources_.at(static_cast<std::size_t>(position));
      }

      // A registry reference to the slot's render function, or LUA_NOREF when QML draws it.
      [[nodiscard]] inline int slot(Slot slot) const noexcept {
        return slots_[static_cast<std::size_t>(slot)];
      }

      [[nodiscard]] inline bool drawsAny() const noexcept {
        return std::ranges::any_of(slots_, [](int reference) {
          return reference != LUA_NOREF;
        });
      }

      [[nodiscard]] inline std::span<const Panel> panels() const noexcept {
        return std::span{panels_}.first(panel_count_);
      }

      [[nodiscard]] inline std::span<const Pick> picks() const noexcept {
        return std::span{picks_}.first(pick_count_);
      }

    private:
      std::array<Source, positions> sources_{};
      std::array<Panel, maximum_definitions> panels_{};
      std::array<Pick, maximum_definitions> picks_{};
      std::size_t panel_count_ = 0;
      std::size_t pick_count_ = 0;
      std::array<int, static_cast<std::size_t>(Slot::count)> slots_ = [] {
        std::array<int, static_cast<std::size_t>(Slot::count)> result{};

        result.fill(LUA_NOREF);

        return result;
      }();
    };

  }
}

// Interface: components/configuration.cppm
export {
  namespace telar::gui::components {

    class Configuration {
    public:
      inline explicit Configuration(lua_State& state)
          : state_(state),
            bars_{BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}},
            panel_(state) {}

      [[nodiscard]] inline Definitions& definitions() noexcept {
        return definitions_;
      }

      [[nodiscard]] inline const Definitions& definitions() const noexcept {
        return definitions_;
      }

      template <typename Actions>
      inline void readFixed(const Actions& actions, runtime::config::LimitNotices& limits) {
        const runtime::lua::Value registry{&state_, LUA_REGISTRYINDEX, "bar registry"};

        for (std::size_t index = 0; index < bars_.size(); ++index) {
          const auto& source = definitions_.source(static_cast<Position>(index));
          if (source.kind == SourceKind::fixed) {
            const auto value = registry.element(source.reference);

            bars_[index].read(runtime::config::BarsReader::content(value), actions, limits, staged_, next_reference_);
          }
        }
      }

      template <typename Actions>
      inline void readBar(Position position, const runtime::lua::Value& value, const Actions& actions, runtime::config::LimitNotices& limits) {
        bars_.at(static_cast<std::size_t>(position)).read(value, actions, limits, staged_, next_reference_);
      }

      template <typename Actions>
      inline void readPanel(const runtime::lua::Value& value, const Actions& actions, runtime::config::LimitNotices& limits) {
        panel_.read(value, actions, limits, staged_, next_reference_);
      }

      [[nodiscard]] inline const BarContent& bar(Position position) const {
        return bars_.at(static_cast<std::size_t>(position)).content();
      }

      [[nodiscard]] inline const PanelContent& panel() const noexcept {
        return panel_.content();
      }

      inline void closePanel() noexcept {
        panel_.clear();
      }

      [[nodiscard]] inline bool contains(BindingAction action) const noexcept {
        return panel_.contains(action) || std::ranges::any_of(bars_, [action](const auto& bar) {
          return bar.contains(action);
        });
      }

      template <typename Visitor>
      inline void visitActions(const Visitor& visitor) const {
        const auto visit = [&](const auto& content) {
          for (const auto& node : content.nodes()) {
            if (const auto action = content.action(node)) {
              visitor(*action);
            }
          }
        };

        for (const auto& bar : bars_) {
          visit(bar.content());
        }

        visit(panel_.content());
      }

    private:
      lua_State& state_;
      Definitions definitions_;
      std::array<BarSnapshot, Definitions::positions> bars_;
      PanelSnapshot panel_;
      StagedContent staged_;
      std::uint32_t next_reference_ = 0;
    };

  }
}
