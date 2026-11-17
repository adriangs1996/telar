// What a mod draws: the tree of layout boxes, text, marks, native pieces and canvases, and the
// built-in icons it names.
export module telar.gui.features.components:elements;

import std;

import :content;
import telar.tbc;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

// Interface: components/elements.cppm
export {
  namespace telar::gui::features::components {

    // What a mod draws: a tree of layout boxes, text, marks, native pieces and canvases.
    enum class ElementKind : std::uint8_t {
      row,
      column,
      stack,
      spacer,
      label,
      icon,
      mark,
      badge,
      tile,
      canvas,
      builtin,
      elapsed,
      clock,
    };

    inline constexpr std::array element_kind_names{"row", "column", "stack", "spacer", "label", "icon", "mark", "badge", "tile", "canvas", "builtin", "elapsed", "clock"};

    struct ElementText {
      std::uint32_t offset = 0;
      std::uint32_t length = 0;
    };

    struct ElementColor {
      std::optional<ColorName::Value> value = std::nullopt;
      std::uint8_t alpha = std::numeric_limits<std::uint8_t>::max();
    };

    struct Element {
      static constexpr std::uint32_t none = std::numeric_limits<std::uint32_t>::max();
      static constexpr std::size_t maximum_elements = 4096;
      static constexpr std::size_t maximum_text_bytes = std::size_t{256} * 1024;
      static constexpr std::size_t maximum_steps = 4096;
      static constexpr std::size_t maximum_actions = 1024;
      static constexpr unsigned maximum_depth = 32;

      ElementKind kind = ElementKind::row;
      std::uint32_t parent = none;
      ElementText text;
      ElementText key;
      ElementText tooltip;
      ElementText url;
      // Left, top, right and bottom, in logical pixels like every length below.
      std::array<float, 4> padding{};
      float gap = 0;
      float width = -1;
      float height = -1;
      float min_width = 0;
      float max_width = -1;
      float min_height = 0;
      float max_height = -1;
      float grow = 0;
      float x = 0;
      float y = 0;
      float rotation = 0;
      float scale = 1;
      float opacity = 1;
      float radius = 0;
      float border_width = 0;
      float size = 0;
      std::uint16_t transition_ms = 0;
      std::int16_t z = 0;
      ElementColor background;
      ElementColor border;
      ElementColor color;
      ElementColor hover;
      Tone tone = Tone::neutral;
      std::uint8_t align = 0;
      std::uint8_t justify = 0;
      std::optional<std::uint8_t> align_self = std::nullopt;
      std::uint8_t easing = 0;
      std::uint8_t size_role = 1;
      std::uint8_t max_lines = 1;
      bool bold = false;
      bool italic = false;
      bool clip = false;
      bool shadow = false;
      // An icon given by name rather than by glyph.
      bool named = false;
      std::uint32_t action = none;
      std::uint32_t callback = none;
      std::uint32_t steps_offset = 0;
      std::uint32_t steps_count = 0;
      std::int64_t since = 0;
    };

    struct CanvasStep {
      std::uint8_t op = 0;
      std::uint8_t count = 0;
      std::array<float, 6> values{};
      ElementColor color;
      ElementText text;
    };

  }
}

// Interface: components/icon.cppm
export {
  namespace telar::gui::features::components {

    // The built-in icons, whose names and glyphs are literals.
    struct Icon {
      tbc::view<std::string_view, tbc::lt::static_storage> name;
      tbc::view<std::string_view, tbc::lt::static_storage> glyph;
      AgentProvider provider = AgentProvider::unknown;
      bool telar = false;

      [[nodiscard]] static tbc::view<Icon, tbc::lt::static_storage> find(std::string_view name) noexcept;

    private:
      static const std::array<Icon, 32> values;
    };

    inline constexpr std::array<Icon, 32> Icon::values = std::to_array<Icon>({
        {.name = "sidebar_collapse", .glyph = ""},
        {.name = "sidebar_expand", .glyph = ""},
        {.name = "workspace_menu", .glyph = ""},
        {.name = "proxy_active", .glyph = ""},
        {.name = "cpu", .glyph = ""},
        {.name = "memory", .glyph = ""},
        {.name = "battery_empty", .glyph = ""},
        {.name = "battery_quarter", .glyph = ""},
        {.name = "battery_half", .glyph = ""},
        {.name = "battery_three_quarters", .glyph = ""},
        {.name = "battery_full", .glyph = ""},
        {.name = "provider_unknown", .glyph = ""},
        {.name = "provider_claude", .glyph = "", .provider = AgentProvider::claude},
        {.name = "provider_codex", .glyph = "", .provider = AgentProvider::codex},
        {.name = "provider_pi", .glyph = "󰏿", .provider = AgentProvider::pi},
        {.name = "provider_cursor", .glyph = "󰋘", .provider = AgentProvider::cursor},
        {.name = "provider_opencode", .glyph = "󰝣", .provider = AgentProvider::opencode},
        {.name = "app_terminal", .glyph = ""},
        {.name = "app_editor", .glyph = ""},
        {.name = "app_git", .glyph = ""},
        {.name = "agent_unknown", .glyph = ""},
        {.name = "agent_working_0", .glyph = ""},
        {.name = "agent_working_1", .glyph = ""},
        {.name = "agent_working_2", .glyph = ""},
        {.name = "agent_working_3", .glyph = ""},
        {.name = "agent_blocked", .glyph = ""},
        {.name = "agent_ready", .glyph = ""},
        {.name = "agent_done", .glyph = ""},
        {.name = "agent_failed", .glyph = ""},
        {.name = "close", .glyph = ""},
        {.name = "pane_fullscreen", .glyph = ""},
        {.name = "telar_mark", .glyph = "▣", .telar = true},
    });

  }
}
