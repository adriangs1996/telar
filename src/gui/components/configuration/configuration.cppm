module;
#include "tbc/annotations.hpp"

export module telar.gui.components.configuration;

import std;

import telar.gui.core.metrics;
import telar.gui.input.copy_pointer;
import telar.config.client;

import telar.lua;

import telar.base.memory.containers;
import telar.base.diagnostics;
import telar.base.text;
import telar.base.text.utf8;
import telar.gui.presentation.history_filter_geometry;
import telar.wire.vocabulary;
import telar.config.core;
import telar.gui.core.json_writer;

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

      [[nodiscard]] unsigned effectivePriority() const noexcept;

      [[nodiscard]] bool container() const noexcept;
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
      std::uint8_t append(const Input& input);

      void clear() noexcept;

      [[nodiscard]] std::span<const Node> nodes() const noexcept;

      [[nodiscard]] bool empty() const noexcept;

      [[nodiscard]] std::string_view text(Range range) const;

      [[nodiscard]] std::span<const std::uint8_t> samples(const Node& node) const;

      [[nodiscard]] std::optional<BindingAction> action(const Node& node) const;

      [[nodiscard]] Input inputAt(std::size_t index) const;

      // Rank children with their container, reserve by priority, then copy in document order.
      template <Capacity SourceBounds>
      void keepFitting(const Content<SourceBounds>& source, const Parents* known_children = nullptr);

    private:
      struct Usage {
        std::size_t nodes = 0;
        std::size_t text = 0;
        std::size_t samples = 0;
        std::size_t actions = 0;

        [[nodiscard]] Usage with(const Node& node) const noexcept;

        [[nodiscard]] bool fits(Capacity room) const noexcept;
      };

      static void dropEmpty(std::span<const Node> source, Parents& kept, const Parents* known_children) noexcept;

      void validateParent(const Node& node) const;

      static void validateText(std::string_view value);

      static void validateUrl(std::string_view value);

      static void validateRange(Range range, std::size_t length);

      Range copyText(std::string_view value) noexcept;

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

    extern template class Content<bar_capacity>;
    extern template class Content<panel_capacity>;
    extern template class Content<staging_capacity>;
    extern template void BarContent::keepFitting<staging_capacity>(const StagedContent& source, const Parents* known_children);
    extern template void PanelContent::keepFitting<staging_capacity>(const StagedContent& source, const Parents* known_children);

  }
}

// Interface: components/action_references.cppm
export {
  namespace telar::gui::components {

    template <std::size_t MaximumReferences>
    class ActionReferences {
    public:
      explicit ActionReferences(lua_State& state) noexcept;

      ~ActionReferences();

      ActionReferences(const ActionReferences&) = delete;
      ActionReferences& operator=(const ActionReferences&) = delete;
      ActionReferences(ActionReferences&&) = delete;
      ActionReferences& operator=(ActionReferences&&) = delete;

      void keep(BindingAction action);

      [[nodiscard]] bool contains(BindingAction action) const noexcept;

      // Release actions omitted by the final fit, including empty containers.
      template <Capacity Bounds>
      void keepOnly(const Content<Bounds>& content);

      void swap(ActionReferences& other) noexcept;

      void clear() noexcept;

    private:
      lua_State* state_;
      std::array<BindingAction, MaximumReferences> references_{};
      std::size_t count_ = 0;
    };

    // What reads a component's click action from its configuration value.
    class ComponentActions {
    public:
      [[nodiscard]] virtual std::optional<BindingAction> read(const runtime::lua::Value& value) const = 0;

    protected:
      ComponentActions() noexcept = default;
      ComponentActions(const ComponentActions&) noexcept = default;
      ComponentActions& operator=(const ComponentActions&) noexcept = default;
      ~ComponentActions() = default;
    };

    // A caller's action reader as ComponentActions. Generic over the caller's reader.
    template <typename Reader>
    class TBC_GENERIC ComponentActionsOf final : public ComponentActions {
    public:
      explicit ComponentActionsOf(const Reader& reader) noexcept
          : reader_(reader) {}

      [[nodiscard]] std::optional<BindingAction> read(const runtime::lua::Value& value) const override {
        return reader_.read(value);
      }

    private:
      const Reader& reader_;
    };

    using StagedActionReferences = ActionReferences<StagedContent::capacity.actions>;

    extern template class ActionReferences<StagedContent::capacity.actions>;
    extern template void StagedActionReferences::keepOnly<bar_capacity>(const Content<bar_capacity>& content);
    extern template void StagedActionReferences::keepOnly<panel_capacity>(const Content<panel_capacity>& content);

    // Numbers each extended action the reader reads and keeps it in `references` until the fit
    // decides which ones stay.
    class ActionReader final : public ComponentActions {
    public:
      explicit ActionReader(const ComponentActions& reader, StagedActionReferences& references, std::uint32_t& next_reference) noexcept;

      [[nodiscard]] std::optional<BindingAction> read(const runtime::lua::Value& value) const override;

    private:
      const ComponentActions& reader_;
      StagedActionReferences& references_;
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

      [[nodiscard]] Color index(std::uint8_t index) const noexcept;

      [[nodiscard]] std::optional<Color> name(std::string_view name) const noexcept;
    };

    // Maps what the configuration's readers read onto the GUI's nodes.
    class ValueMapper {
    public:
      // An icon name as the GUI keys it: lowercase, with underscores for hyphens.
      static runtime::FixedText<Node::maximum_icon_bytes> iconName(std::string_view name);

      static std::optional<runtime::FixedText<Node::maximum_icon_bytes>> icon(const std::optional<std::string_view>& name);

      static std::optional<Mark> mark(std::optional<runtime::config::UiMark> mark) noexcept;

      static Tone tone(runtime::config::ComponentTone tone) noexcept;

      static std::uint16_t fraction(double number) noexcept;

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

    class ContentReader {
      using Place = runtime::config::ComponentPlace;
      using Position = runtime::config::ComponentPosition;
      using Parent = runtime::config::ComponentParent;
      using Shape = runtime::config::ComponentShape;

    public:
      static_assert(Node::no_parent == Position::no_parent && Node::default_priority == Position::default_priority);

      explicit ContentReader(lua_State& state, const ComponentActions& actions, runtime::config::LimitNotices& limits, StagedContent& staged, Surface surface = Surface::bar);

      // Count before retaining actions so omitted components cannot retain commands.
      template <Capacity Bounds>
      void read(const runtime::lua::Value& value, Content<Bounds>& output);

    private:
      // What the walk builds from each component it places.
      struct Builder {
        std::optional<Parent> node(const runtime::lua::Value& value, const Shape& shape, const Position& position);

        std::optional<Parent> append(const runtime::lua::Value& value, const Shape& shape, Input& input, const Position& position);

        static runtime::config::ComponentBudget::Usage usage(const Shape& shape) noexcept;

        void report(Capacity bounds);

        const ComponentActions& actions_;
        runtime::config::LimitNotices& limits_;
        StagedContent& staged_;
        Surface surface_;
        runtime::config::ComponentBudget budget_{};
        runtime::config::ComponentBudget::Usage demand_{};
        StagedContent::Parents had_children_{};
        bool counting_ = true;
      };

      lua_State& state_;
      Builder builder_;
    };

    extern template void ContentReader::read<bar_capacity>(const runtime::lua::Value& value, BarContent& output);
    extern template void ContentReader::read<panel_capacity>(const runtime::lua::Value& value, PanelContent& output);

  }
}

// Interface: components/snapshot.cppm
export {
  namespace telar::gui::components {

    template <Capacity Bounds>
    class Snapshot {
    public:
      explicit Snapshot(lua_State& state) noexcept;

      void read(const runtime::lua::Value& value, const ComponentActions& actions, runtime::config::LimitNotices& limits, StagedContent& staged, std::uint32_t& next_reference);

      [[nodiscard]] const Content<Bounds>& content() const noexcept;

      [[nodiscard]] bool contains(BindingAction action) const noexcept;

      void clear() noexcept;

    private:
      lua_State& state_;
      StagedActionReferences references_;
      Content<Bounds> content_;
    };

    using BarSnapshot = Snapshot<BarContent::capacity>;
    using PanelSnapshot = Snapshot<PanelContent::capacity>;

    extern template class Snapshot<bar_capacity>;
    extern template class Snapshot<panel_capacity>;

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

      static Source read(lua_State& state, const runtime::lua::Value& value, bool panel = false);

      // Keeps the source's table in the registry, where its render function and command are.
      static Source read(lua_State& state, const runtime::lua::Value& value, const runtime::config::SourceSetting& setting);
    };

    struct Heading {
      static constexpr std::size_t maximum_name_bytes = 32;
      static constexpr std::size_t maximum_title_bytes = 128;
      runtime::FixedText<maximum_name_bytes> name;
      runtime::FixedText<maximum_title_bytes> title;

      void assign(const runtime::config::DefinitionHeading& heading);
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

      Definitions() noexcept;

      void apply(lua_State& state, const runtime::lua::Value& client);

      [[nodiscard]] const Source& source(Position position) const;

      // A registry reference to the slot's render function, or LUA_NOREF when QML draws it.
      [[nodiscard]] int slot(Slot slot) const noexcept;

      [[nodiscard]] bool drawsAny() const noexcept;

      [[nodiscard]] std::span<const Panel> panels() const noexcept;

      [[nodiscard]] std::span<const Pick> picks() const noexcept;

    private:
      std::array<Source, positions> sources_{};
      std::array<Panel, maximum_definitions> panels_{};
      std::array<Pick, maximum_definitions> picks_{};
      std::size_t panel_count_ = 0;
      std::size_t pick_count_ = 0;
      std::array<int, static_cast<std::size_t>(Slot::count)> slots_{};
    };

  }
}

// Interface: components/configuration.cppm
export {
  namespace telar::gui::components {

    class Configuration {
    public:
      explicit Configuration(lua_State& state);

      [[nodiscard]] Definitions& definitions() noexcept;

      [[nodiscard]] const Definitions& definitions() const noexcept;

      template <typename Actions>
      TBC_GENERIC void readFixed(const Actions& actions, runtime::config::LimitNotices& limits) {
        readFixedSources(ComponentActionsOf<Actions>{actions}, limits);
      }

      template <typename Actions>
      TBC_GENERIC void readBar(Position position, const runtime::lua::Value& value, const Actions& actions, runtime::config::LimitNotices& limits) {
        readBarContent(position, value, ComponentActionsOf<Actions>{actions}, limits);
      }

      template <typename Actions>
      TBC_GENERIC void readPanel(const runtime::lua::Value& value, const Actions& actions, runtime::config::LimitNotices& limits) {
        readPanelContent(value, ComponentActionsOf<Actions>{actions}, limits);
      }

      [[nodiscard]] const BarContent& bar(Position position) const;

      [[nodiscard]] const PanelContent& panel() const noexcept;

      void closePanel() noexcept;

      [[nodiscard]] bool contains(BindingAction action) const noexcept;

      template <typename Visitor>
      TBC_GENERIC void visitActions(const Visitor& visitor) const {
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
      void readFixedSources(const ComponentActions& actions, runtime::config::LimitNotices& limits);

      void readBarContent(Position position, const runtime::lua::Value& value, const ComponentActions& actions, runtime::config::LimitNotices& limits);

      void readPanelContent(const runtime::lua::Value& value, const ComponentActions& actions, runtime::config::LimitNotices& limits);

      lua_State& state_;
      Definitions definitions_;
      std::array<BarSnapshot, Definitions::positions> bars_;
      PanelSnapshot panel_;
      StagedContent staged_;
      std::uint32_t next_reference_ = 0;
    };

  }
}
