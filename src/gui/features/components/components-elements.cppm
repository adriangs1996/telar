// What a mod draws: the tree of layout boxes, text, marks, native pieces and canvases, and the
// built-in icons it names.
export module telar.gui.features.components:elements;

import std;

import :content;
import telar.tbc;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

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

    inline constexpr ds::Array element_kind_names{"row", "column", "stack", "spacer", "label", "icon", "mark", "badge", "tile", "canvas", "builtin", "elapsed", "clock"};

    struct ElementText {
      std::uint32_t offset = 0;
      std::uint32_t length = 0;
    };

    struct ElementColor {
      ds::Option<ColorName::Value> value = ds::none;
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
      ds::Array<float, 4> padding{};
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
      ds::Option<std::uint8_t> align_self = ds::none;
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
      // The most values an operation takes, a curve's.
      static constexpr std::size_t maximum_values = 6;

      std::uint8_t op = 0;
      std::uint8_t count = 0;
      ds::Array<float, maximum_values> values{};
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
      tbc::val_static<std::string_view> name;
      tbc::val_static<std::string_view> glyph;
      AgentProvider provider = AgentProvider::unknown;
      bool telar = false;

      [[nodiscard]] static tbc::val_static<Icon> find(std::string_view name) noexcept;

    private:
      static const ds::Array<Icon, 32> values;
    };

    inline constexpr ds::Array<Icon, 32> Icon::values = ds::Array<Icon, 32>{
        Icon{.name = "sidebar_collapse", .glyph = ""},
        Icon{.name = "sidebar_expand", .glyph = ""},
        Icon{.name = "workspace_menu", .glyph = ""},
        Icon{.name = "proxy_active", .glyph = ""},
        Icon{.name = "cpu", .glyph = ""},
        Icon{.name = "memory", .glyph = ""},
        Icon{.name = "battery_empty", .glyph = ""},
        Icon{.name = "battery_quarter", .glyph = ""},
        Icon{.name = "battery_half", .glyph = ""},
        Icon{.name = "battery_three_quarters", .glyph = ""},
        Icon{.name = "battery_full", .glyph = ""},
        Icon{.name = "provider_unknown", .glyph = ""},
        Icon{.name = "provider_claude", .glyph = "", .provider = AgentProvider::claude},
        Icon{.name = "provider_codex", .glyph = "", .provider = AgentProvider::codex},
        Icon{.name = "provider_pi", .glyph = "󰏿", .provider = AgentProvider::pi},
        Icon{.name = "provider_cursor", .glyph = "󰋘", .provider = AgentProvider::cursor},
        Icon{.name = "provider_opencode", .glyph = "󰝣", .provider = AgentProvider::opencode},
        Icon{.name = "app_terminal", .glyph = ""},
        Icon{.name = "app_editor", .glyph = ""},
        Icon{.name = "app_git", .glyph = ""},
        Icon{.name = "agent_unknown", .glyph = ""},
        Icon{.name = "agent_working_0", .glyph = ""},
        Icon{.name = "agent_working_1", .glyph = ""},
        Icon{.name = "agent_working_2", .glyph = ""},
        Icon{.name = "agent_working_3", .glyph = ""},
        Icon{.name = "agent_blocked", .glyph = ""},
        Icon{.name = "agent_ready", .glyph = ""},
        Icon{.name = "agent_done", .glyph = ""},
        Icon{.name = "agent_failed", .glyph = ""},
        Icon{.name = "close", .glyph = ""},
        Icon{.name = "pane_fullscreen", .glyph = ""},
        Icon{.name = "telar_mark", .glyph = "▣", .telar = true},
    };

  }
}
