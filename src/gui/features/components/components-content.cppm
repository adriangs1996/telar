// What a component shows: the nodes of a bar or a panel, the content that holds them within its
// capacity and keeps the ones that fit by priority, and how the configuration's values map onto
// them.
export module telar.gui.features.components:content;

import std;

import telar.base.memory.containers;
import telar.base.text;
import telar.config.client;
import telar.config.core;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.base.ds;

// Interface: components/node.cppm
export {
  namespace telar::gui::features::components {

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
      ds::Option<ColorName::Value> foreground = ds::none;
      ds::Option<ColorName::Value> background = ds::none;
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
      ds::Option<runtime::FixedText<maximum_icon_bytes>> icon = ds::none;
      ds::Option<Mark> mark = ds::none;
      BarMetric metric = BarMetric::cpu;
      Tone tone = Tone::neutral;
      Style style{};
      std::uint16_t value = 0;
      ds::Option<std::uint16_t> marker = ds::none;
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
      ds::Option<BindingAction> action = ds::none;
    };

  }
}

// Interface: components/content.cppm
export {
  namespace telar::gui::features::components {

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
      using Parents = ds::Array<bool, Node::maximum_nodes>;

      // Validate and reserve the complete node before changing any owned storage.
      std::uint8_t append(const Input& input);

      void clear() noexcept;

      [[nodiscard]] std::span<const Node> nodes() const noexcept;

      [[nodiscard]] bool empty() const noexcept;

      [[nodiscard]] std::string_view text(Range range) const;

      [[nodiscard]] std::span<const std::uint8_t> samples(const Node& node) const;

      [[nodiscard]] ds::Option<BindingAction> action(const Node& node) const;

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

      ds::Array<Node, Bounds.nodes> nodes_{};
      ds::Array<char, Bounds.text> text_{};
      ds::Array<std::uint8_t, Bounds.samples> samples_{};
      ds::Array<BindingAction, Bounds.actions> actions_{};
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

// Interface: components/value_reader.cppm
export {
  namespace telar::gui::features::components {

    // The colors a configuration names, as the GUI draws them.
    struct ComponentColors {
      using Color = ColorName::Value;

      [[nodiscard]] Color index(std::uint8_t index) const noexcept;

      [[nodiscard]] ds::Option<Color> name(std::string_view name) const noexcept;
    };

    // Maps what the configuration's readers read onto the GUI's nodes.
    class ValueMapper {
    public:
      // An icon name as the GUI keys it: lowercase, with underscores for hyphens.
      static runtime::FixedText<Node::maximum_icon_bytes> iconName(std::string_view name);

      static ds::Option<runtime::FixedText<Node::maximum_icon_bytes>> icon(const ds::Option<std::string_view>& name);

      static ds::Option<Mark> mark(ds::Option<runtime::config::UiMark> mark) noexcept;

      static Tone tone(runtime::config::ComponentTone tone) noexcept;

      static std::uint16_t fraction(double number) noexcept;

      static_assert(std::to_underlying(Tone::danger) == std::to_underlying(runtime::config::ComponentTone::danger));
      static_assert(std::to_underlying(BarMetric::battery) == std::to_underlying(runtime::config::ComponentMetric::battery));
      static_assert(Node::maximum_samples == runtime::config::ComponentValues<ComponentColors::Color>::maximum_samples);
    };

  }
}
