// What a configuration defines for the components: the source of each bar position, the slots a
// mod draws, the panels and the picks, and the content telar draws itself for the built-in
// sources.
export module telar.gui.features.components:definitions;

import std;

import :content;
import telar.base.text;
import telar.config.client;
import telar.base.ds;

// Interface: components/source.cppm
export {
  namespace telar::gui::features::components {

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

    // A reference into the registry of the configuration's interpreter, which application holds
    // and releases; no_reference, LUA_NOREF, when there is none.
    inline constexpr int no_reference = -2;

    struct Source {
      static constexpr std::chrono::milliseconds default_interval{1000};
      static constexpr std::chrono::milliseconds default_timeout{2000};
      static constexpr std::uint64_t minimum_interval_ms = 100;
      static constexpr std::uint64_t maximum_interval_ms = 3600000;
      static constexpr std::uint64_t minimum_timeout_ms = 100;
      static constexpr std::uint64_t maximum_timeout_ms = 10000;
      SourceKind kind = SourceKind::empty;
      ds::Option<std::chrono::milliseconds> interval = ds::none;
      std::chrono::milliseconds timeout = default_timeout;
      int reference = no_reference;
      bool has_render = false;
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
      ds::Option<Mark> mark = ds::none;
      ds::Option<runtime::FixedText<Node::maximum_icon_bytes>> icon = ds::none;
      std::uint16_t width = default_width;
    };

    struct Pick {
      static constexpr std::uint64_t maximum_timeout_ms = 60000;
      Heading heading;
      std::chrono::milliseconds timeout = Source::default_timeout;
      int reference = no_reference;
      bool command = false;
      bool render = false;
      bool refresh = true;
    };

    class Definitions {
    public:
      static constexpr std::size_t positions = static_cast<std::size_t>(Position::count);
      static constexpr std::size_t maximum_definitions = 16;

      Definitions() noexcept;

      [[nodiscard]] const Source& source(Position position) const;

      // A registry reference to the slot's render function, or no_reference when QML draws it.
      [[nodiscard]] int slot(Slot slot) const noexcept;

      [[nodiscard]] bool drawsAny() const noexcept;

      [[nodiscard]] std::span<const Panel> panels() const noexcept;

      [[nodiscard]] std::span<const Pick> picks() const noexcept;

      // What application reads from a configuration's client table, one layer over another: each
      // replaces what the layer before defined in the same place.
      void defineSource(Position position, const Source& source);

      void defineSlot(Slot slot, int reference) noexcept;

      void definePanel(std::size_t index, const Panel& panel);

      void definePick(std::size_t index, const Pick& pick);

      // A layer that lists no panels or picks keeps the ones before it.
      void count(ds::Option<std::size_t> panels, ds::Option<std::size_t> picks) noexcept;

    private:
      ds::Array<Source, positions> sources_{};
      ds::Array<Panel, maximum_definitions> panels_{};
      ds::Array<Pick, maximum_definitions> picks_{};
      std::size_t panel_count_ = 0;
      std::size_t pick_count_ = 0;
      ds::Array<int, static_cast<std::size_t>(Slot::count)> slots_{};
    };

  }
}

// Interface: components/builtin_content.cppm
export {
  namespace telar::gui::features::components {

    inline constexpr std::uint8_t builtin_priority = 40;

    bool builtinSource(SourceKind kind) noexcept;

    BarContent builtinContent(SourceKind kind);

  }
}
