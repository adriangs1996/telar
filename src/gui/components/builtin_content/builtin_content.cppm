export module telar.gui.components.builtin_content;

import std;
import telar.tbc;

import telar.gui.components.configuration;

import telar.gui.foundation.actions;

import telar.gui.foundation.text;

import telar.config.client;

import telar.lua;

import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.config.core;

// Interface: components/builtin_content.cppm
export {
  namespace telar::gui::components {

    inline constexpr std::uint8_t builtin_priority = 40;

    bool builtinSource(SourceKind kind) noexcept;

    BarContent builtinContent(SourceKind kind);

  }
}

// Interface: components/invocation.cppm
export {
  namespace telar::gui::components {

    struct Time {
      std::int64_t unix_seconds = 0;
      std::uint16_t year = 0;
      std::uint8_t month = 0;
      std::uint8_t day = 0;
      std::uint8_t hour = 0;
      std::uint8_t minute = 0;
      std::uint8_t second = 0;
      std::uint8_t weekday = 0;
    };

    struct Context {
      BindingContext client;
      Time time;
      std::optional<SystemMetrics> metrics = std::nullopt;
      std::optional<std::string_view> output = std::nullopt;
      std::string_view pane_title;
    };

    class Invocation {
    public:
      // `field` names the function inside the referenced table; without it the reference is the
      // function. `item`, a JSON document, becomes the call's second argument.
      explicit Invocation(int reference, const Context& context, const char* field = "render", std::optional<std::string_view> item = std::nullopt) noexcept;

      static int invoke(lua_State* state);

    private:
      void pushContext(lua_State* state) const;

      int reference_;
      const Context& context_;
      const char* field_;
      std::optional<std::string_view> item_;
    };

  }
}

// Interface: components/clock.cppm
export {
  namespace telar::gui::components {

    class Clock {
    public:
      static constexpr std::size_t maximum_format_bytes = 32;
      static constexpr std::size_t maximum_output_bytes = maximum_format_bytes / 2 * std::string_view{"September"}.size();
      using Text = BoundedText<maximum_output_bytes>;

      [[nodiscard]] static Text format(std::string_view pattern, const Time& time);

      [[nodiscard]] static bool showsSeconds(std::string_view pattern) noexcept;

    private:
      static constexpr unsigned noon = 12;
      static constexpr unsigned century = 100;
      static constexpr unsigned decimal_base = 10;
      static constexpr std::array<std::string_view, 7> weekdays{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
      static constexpr std::array<std::string_view, 7> weekday_names{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
      static constexpr std::array<std::string_view, 12> months{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
      static constexpr std::array<std::string_view, 12> month_names{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"};

      static void decimal(Text& text, unsigned number, bool padded = true);

      template <std::size_t Count>
      static std::string_view named(const std::array<std::string_view, Count>& names, unsigned index) noexcept;

      static void directive(Text& text, char code, const Time& time);
    };

  }
}

// Interface: components/icon.cppm
export {
  namespace telar::gui::components {

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

// Interface: components/pick_items.cppm
export {
  namespace telar::gui::components {

    using PickSwatch = std::array<std::uint32_t, 3>;

    struct PickInput {
      std::string_view label;
      std::string_view detail;
      std::optional<std::string_view> value = std::nullopt;
      std::optional<PickSwatch> swatch = std::nullopt;
      bool selected = false;
    };

    struct PickOption {
      std::string_view label;
      std::string_view value;
      std::string_view detail;
      std::optional<PickSwatch> swatch;
      bool selected;
    };

    class PickItems {
    public:
      static constexpr std::size_t maximum_items = 4096;
      static constexpr std::size_t maximum_text_bytes = std::size_t{256} * 1024;
      static constexpr std::size_t maximum_label_bytes = 128;
      static constexpr std::size_t maximum_value_bytes = 512;
      static constexpr std::size_t maximum_detail_bytes = 128;

      void clear() noexcept;

      // A value remains one argv element; only labels and details may be shortened.
      void keep(const PickInput& input);

      [[nodiscard]] std::size_t size() const noexcept;

      [[nodiscard]] PickOption at(std::size_t index) const;

      void report(runtime::config::LimitNotices& limits) const noexcept;

    private:
      struct Range {
        std::uint32_t offset = 0;
        std::uint16_t length = 0;
      };

      struct Row {
        Range label;
        Range value;
        Range detail;
        std::optional<PickSwatch> swatch = std::nullopt;
        bool selected = false;
      };

      struct Offered {
        std::uint32_t items = 0;
        std::uint32_t text = 0;
        std::uint32_t label = 0;
        std::uint32_t value = 0;
        std::uint32_t detail = 0;
        bool text_full = false;
      };

      static std::uint32_t saturated(std::size_t value) noexcept;

      static void offer(std::uint32_t& total, std::size_t value) noexcept;

      static void validate(std::string_view text, bool tabs);

      Range store(std::string_view value) noexcept;

      [[nodiscard]] std::string_view text(Range range) const noexcept;

      std::array<char, maximum_text_bytes> bytes_{};
      std::array<Row, maximum_items> rows_{};
      std::size_t count_ = 0;
      std::size_t used_ = 0;
      Offered offered_;
    };

  }
}

// Interface: components/pick_items_reader.cppm
export {
  namespace telar::gui::components {

    // Each read replaces output in place: a PickItems takes 432 KiB, too large to stage on
    // the Lua thread's stack. After a failure output holds the options read before it, so a
    // caller that must keep its last complete list reads into a fresh PickItems.
    class PickItemsReader {
    public:
      static void read(const runtime::lua::Value& value, PickItems& output, runtime::config::LimitNotices& limits);

      // The options a pick definition lists.
      static void definition(const runtime::lua::Value& pick, PickItems& output, runtime::config::LimitNotices& limits);

      static void lines(std::string_view text, PickItems& output, runtime::config::LimitNotices& limits);

    private:
      template <typename Read>
      static void keep(const Read& read, PickItems& output, runtime::config::LimitNotices& limits);
    };

  }
}

// Interface: components/pick_matches.cppm
export {
  namespace telar::gui::components {

    class PickMatches {
    public:
      struct Match {
        std::uint32_t score = 0;
        std::uint16_t index = 0;
      };

      void collect(const PickItems& items, std::string_view query);

      [[nodiscard]] std::span<const Match> rows() const noexcept;

    private:
      std::array<Match, PickItems::maximum_items> matches_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: components/rendered_content.cppm
export {
  namespace telar::gui {

    // A command tab that outlives the Lua thread's registry row it was read from.
    class CommandTabCopy {
    public:
      using View = runtime::config::CommandTabView;

      explicit CommandTabCopy(const View& view);

      [[nodiscard]] View view() const noexcept;

    private:
      std::array<char, View::maximum_argument_bytes + View::maximum_label_bytes> bytes_{};
      std::array<std::uint16_t, View::maximum_arguments> lengths_{};
      std::size_t count_ = 0;
      std::uint16_t label_ = 0;
    };

    // What an action produced by Lua means, read on the Lua thread so the window never reads the VM.
    struct ResolvedAction {
      BindingAction action;
      std::optional<ExtendedActionDescription> description = std::nullopt;
      std::optional<CommandTabCopy> command = std::nullopt;
    };

    template <Allocator Memory>
    class ResolvedActions {
    public:
      explicit ResolvedActions(Memory& memory);

      void add(ResolvedAction entry);

      [[nodiscard]] const ResolvedAction* find(BindingAction action) const noexcept;

      [[nodiscard]] bool contains(BindingAction action) const noexcept;

    private:
      Vector<ResolvedAction, Memory> entries_;
    };

    template <components::Capacity Bounds, Allocator Memory>
    struct RenderedContent {
      explicit RenderedContent(Memory& memory);

      components::Content<Bounds> content;
      ResolvedActions<Memory> actions;
    };

    template <Allocator Memory>
    struct ResolvedEffects {
      explicit ResolvedEffects(Memory& memory);

      BindingEffects effects;
      ResolvedActions<Memory> actions;
    };

    extern template class ResolvedActions<telar::Memory>;
    extern template class ResolvedActions<telar::ConcurrentMemory>;
    extern template struct RenderedContent<components::bar_capacity, telar::Memory>;
    extern template struct RenderedContent<components::panel_capacity, telar::Memory>;
    extern template struct RenderedContent<components::bar_capacity, telar::ConcurrentMemory>;
    extern template struct RenderedContent<components::panel_capacity, telar::ConcurrentMemory>;
    extern template struct ResolvedEffects<telar::Memory>;
    extern template struct ResolvedEffects<telar::ConcurrentMemory>;

  }
}

// Interface: components/elements.cppm
export {
  namespace telar::gui::components {

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

// Interface: components/rendered_elements.cppm
export {
  namespace telar::gui {

    template <Allocator Memory>
    struct RenderedElements {
      explicit RenderedElements(Memory& memory);

      [[nodiscard]] std::string_view view(components::ElementText range) const noexcept;

      Vector<components::Element, Memory> elements;
      String<Memory> text;
      Vector<components::CanvasStep, Memory> steps;
      // Element `action` indices name these; `actions` holds what each one means.
      Vector<BindingAction, Memory> bindings;
      ResolvedActions<Memory> actions;
      // Lua handlers this render registered for `on_click` functions, by element `callback`.
      std::uint32_t callbacks = 0;
    };

    extern template struct RenderedElements<telar::Memory>;
    extern template struct RenderedElements<telar::ConcurrentMemory>;

  }
}
