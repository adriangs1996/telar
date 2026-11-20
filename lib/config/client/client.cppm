module;
#include "tbc/annotations.hpp"

export module telar.config.client;

import std;
import telar.lua;
import telar.tbc;
import telar.config.core;
import telar.base.diagnostics;
import telar.base.text;
import telar.base.text.utf8;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: telar_config/named_definitions_validator.cppm
namespace telar::runtime::config {

  class NamedDefinitionsValidator {
  public:
    static constexpr std::size_t maximum_definitions = 16;

    // Hands the definitions to `validate_definition` in name order, each with its index, and
    // returns how many it kept, if the table is present. Stays in the interface because it is a
    // template over the caller's callable.
    template <typename Validator>
    TBC_GENERIC static ds::Option<std::size_t> validate(const lua::Value& table, tbc::val_b<LimitReach> reach, tbc::mut_b<LimitNotices> limits, const Validator& validate_definition) {
      if (!table.present()) {
        return ds::none;
      }

      ds::Array<std::string_view, maximum_definitions> names;
      const auto kept = sortedNames(table, reach, limits, names.viewMut());

      for (std::size_t index = 0; index < kept; ++index) {
        const auto definition = table.entry(names[index]);

        validate_definition(names[index], definition, index);
      }

      return kept;
    }

    // The definition's title, or its name, cut to the title limit.
    static tbc::val_a<std::string_view> heading(tbc::val_a<std::string_view> name, const lua::Value& definition, LimitNotices& limits);

  private:
    // Keeps the first names of the table in name order and returns how many it kept, telling the
    // notices about the ones it leaves out.
    static std::size_t sortedNames(const lua::Value& table, tbc::val_b<LimitReach> reach, tbc::mut_b<LimitNotices> limits, std::span<std::string_view, maximum_definitions> names);

    static constexpr std::size_t maximum_name_bytes = 32;
    static constexpr std::size_t maximum_title_bytes = 128;
  };

}

// Interface: telar_config/client_definitions.cppm
export {
  namespace telar::runtime::config {

    class ClientDefinitions {
    public:
      explicit ClientDefinitions(const lua::Value& client, const lua::Value* inherited = nullptr);
      bool contains(const char* section, std::string_view name) const;
      ds::Option<std::uint8_t> index(const char* section, std::string_view name) const;

    private:
      static ds::Option<std::uint8_t> indexOf(const lua::Value& definitions, std::string_view name);

      const lua::Value& client_;
      const lua::Value* inherited_;
    };

  }
}

// Interface: telar_config/command_tab_reference.cppm
export {
  namespace telar::runtime::config {

    struct CommandTabReference {
      std::uint32_t epoch = 0;
      std::uint16_t id = 0;

      bool operator==(const CommandTabReference&) const = default;
    };

  }
}

// Interface: telar_config/command_tab_view.cppm
export {
  namespace telar::runtime::config {

    struct CommandTabView {
      static constexpr std::size_t maximum_arguments = 32;
      static constexpr std::size_t maximum_argument_bytes = 4096;
      static constexpr std::size_t maximum_label_bytes = 32;

      ds::Array<std::string_view, maximum_arguments> arguments{};
      std::size_t count = 0;
      std::string_view configured_label;

      [[nodiscard]] std::span<const std::string_view> argv() const noexcept;
      [[nodiscard]] std::string_view label() const noexcept;
    };

  }
}

// Interface: telar_config/command_tab_registry.cppm
export {
  namespace telar::runtime::config {

    enum class CommandTabLifetime : std::uint8_t {
      configuration,
      retained,
    };

    template <CommandTabLifetime Lifetime>
    class CommandTabStorage {
    public:
      CommandTabStorage() noexcept = default;

      struct Checkpoint {
        std::size_t rows;
        std::size_t bytes;
      };

      bool keep(std::span<const std::string_view> arguments, std::string_view label, LimitNotices& limits);
      ds::Option<CommandTabReference> keepReference(std::span<const std::string_view> arguments, std::string_view label, LimitNotices& limits);
      [[nodiscard]] ds::Option<CommandTabView> load(CommandTabReference reference) const;

      void seal() noexcept
        requires(Lifetime == CommandTabLifetime::retained);

      void beginRender() noexcept
        requires(Lifetime == CommandTabLifetime::retained);

      void endRender() noexcept
        requires(Lifetime == CommandTabLifetime::retained);
      [[nodiscard]] Checkpoint checkpoint() const noexcept;
      void restore(Checkpoint saved) noexcept;

    private:
      static constexpr std::size_t recent_rows = 256;
      static constexpr std::size_t fixed_row_limit = 768;
      static constexpr std::size_t recent_bytes = std::size_t{64} * 1024;
      static constexpr std::size_t fixed_byte_limit = std::size_t{80} * 1024;
      static constexpr std::size_t maximum_rows = fixed_row_limit + (Lifetime == CommandTabLifetime::retained ? recent_rows : 0);
      static constexpr std::size_t maximum_bytes = fixed_byte_limit + (Lifetime == CommandTabLifetime::retained ? recent_bytes : 0);
      static constexpr std::size_t header_bytes = 2;
      static constexpr std::size_t argument_length_bytes = sizeof(std::uint16_t);
      static constexpr unsigned upper_byte_shift = std::numeric_limits<Byte>::digits;
      static constexpr std::size_t maximum_encoded_bytes = header_bytes + (argument_length_bytes * CommandTabView::maximum_arguments) + CommandTabView::maximum_argument_bytes + CommandTabView::maximum_label_bytes;

      static_assert(maximum_encoded_bytes <= recent_bytes);
      static_assert(maximum_bytes <= std::numeric_limits<std::uint32_t>::max());
      static_assert(maximum_rows - 1 <= std::numeric_limits<std::uint16_t>::max());
      static std::size_t encode(std::span<const std::string_view> arguments, std::string_view label, std::span<Byte> encoded);
      bool admit(std::size_t length, LimitNotices& limits) noexcept;
      [[nodiscard]] CommandTabReference reference(std::size_t index) const noexcept;
      [[nodiscard]] std::span<const Byte> rowBytes(std::size_t index) const noexcept;
      void clearRecent() noexcept;

      ds::Array<Byte, maximum_bytes> bytes_{};
      ds::Array<std::uint32_t, maximum_rows> offsets_{};
      std::size_t rows_ = 0;
      std::size_t used_ = 0;
      std::size_t fixed_rows_ = 0;
      std::size_t fixed_bytes_ = 0;
      std::uint32_t epoch_ = 1;
      bool sealed_ = false;
      bool rendering_ = false;
      bool refused_ = false;
    };

    using CommandTabRegistry = CommandTabStorage<CommandTabLifetime::configuration>;
    using RetainedCommandTabRegistry = CommandTabStorage<CommandTabLifetime::retained>;

    template <typename Store>
    concept CommandTabStore = requires(Store& store, std::span<const std::string_view> arguments, std::string_view label, LimitNotices& limits) {
      { store.keep(arguments, label, limits) } -> std::same_as<bool>;
      { store.restore(store.checkpoint()) } noexcept -> std::same_as<void>;
    };

  }
}

// Interface: telar_config/action_setting.cppm
export {
  namespace telar::runtime::config {

    enum class ActionKind : std::uint8_t {
      function,
      builtin,
      select_tab,
      select_workspace,
      select_tab_offset,
      command_tab,
      notification,
      panel,
      pick,
      plugin,
    };

    // An action as read. A function or a notification, panel, pick or plugin action is read
    // again from its value when it runs; ExtendedActionReader reads the last four.
    struct ActionSetting {
      ActionKind kind = ActionKind::builtin;
      // A built-in action's name, with a direction joined to its stem: "split-horizontal". It views
      // the configuration's string or, for a direction, a name that outlives it.
      std::string_view name;
      // The tab or workspace `index`, from 1, or the tab `offset`.
      std::int32_t number = 0;
      // A command tab's arguments and label, views of the configuration's strings.
      CommandTabView command;
    };

    struct NotificationActionSetting {
      std::string_view title;
      std::string_view body;
      NotificationLevel level = NotificationLevel::info;
      std::uint32_t duration_ms = default_notification_duration_ms;
      NotificationTarget target;
    };

    struct DefinitionActionSetting {
      bool panel = false;
      std::uint8_t index = 0;
    };

    struct PluginActionSetting {
      std::string_view plugin;
      std::string_view action;
    };

    using ExtendedActionSetting = std::variant<NotificationActionSetting, DefinitionActionSetting, PluginActionSetting>;

    // Reads a notification, panel, pick or plugin action a validator already accepted.
    class ExtendedActionReader {
    public:
      // The definition is the one `definitions` holds now: a profile may replace it.
      // The setting views the strings the Lua state holds, region `a`.
      [[nodiscard]] static tbc::val_a<ExtendedActionSetting> read(const lua::Value& action, const ClientDefinitions& definitions);

    private:
      static tbc::val_a<NotificationActionSetting> notification(const lua::Value& action);

      static constexpr ds::Array<std::string_view, 4> notification_level_names{"info", "success", "warning", "failure"};
    };

  }
}

// Interface: telar_config/action_validator.cppm
export {
  namespace telar::runtime::config {

    template <CommandTabStore Commands>
    class BasicActionValidator {
    public:
      explicit BasicActionValidator(tbc::ref_b<ClientDefinitions> definitions, tbc::mut_b<LimitNotices> limits, tbc::mut_b<Commands> commands);
      bool validate(const lua::Value& action, bool expression = false);
      bool component(const lua::Value& action);

      // Validates the action and reads it; nothing when a limit drops it.
      [[nodiscard]] tbc::val_a<ds::Option<ActionSetting>> read(const lua::Value& action, bool expression = false);

    private:
      static void command(const lua::Value& action, tbc::mut_a<CommandTabView> command);

      // A directional action names its stem and its direction: {kind = "split-pane", direction =
      // "horizontal"} is "split-horizontal".
      static tbc::val_a<std::string_view> builtinName(const lua::Value& action, tbc::val_a<std::string_view> kind);

      static constexpr ds::Array<std::string_view, 57> builtin_names{"next-machine", "previous-machine", "machine-picker", "add-machine", "monitor", "process-picker", "process-terminate", "process-kill", "process-stop", "process-continue", "process-lower-priority", "process-copy-command", "process-focus-pane", "process-review-stack", "process-review-files", "process-review-logs", "scroll-pane-up", "scroll-pane-down", "split-horizontal", "split-vertical", "focus-left", "focus-right", "focus-up", "focus-down", "navigate-left", "navigate-right", "navigate-up", "navigate-down", "resize-left", "resize-right", "resize-up", "resize-down", "toggle-pane-fullscreen", "toggle-sidebar", "resize-sidebar-left", "resize-sidebar-right", "toggle-workspace-list", "leave-worktree", "forget-gone-worktrees", "new-workspace", "rename-workspace", "close-pane", "new-tab", "next-tab", "previous-tab", "rename-tab", "close-tab", "move-tab-previous", "move-tab-next", "detach", "copy-mode", "goto-picker", "history-palette", "path-picker", "suggest-command", "close-panel", "refresh-panel"};

      static void builtin(const lua::Value& value);
      static bool validIndex(std::string_view number) noexcept;
      static void requiredInteger(const lua::Value& value, lua_Integer minimum, lua_Integer maximum);
      static void direction(const lua::Value& action, std::initializer_list<std::string_view> choices);

      // An action's field that names a client definition, and the section that defines it.
      struct DefinitionField {
        const char* field = nullptr;
        const char* section = nullptr;
      };

      void reference(const lua::Value& action, DefinitionField definition) const;
      bool commandTab(const lua::Value& action);
      void notification(const lua::Value& action);
      tbc::val_a<std::string_view> fitted(tbc::val_a<std::string_view> text, tbc::val_b<LimitReach> limit);

      tbc::ref_b<ClientDefinitions> definitions_;
      tbc::mut_b<LimitNotices> limits_;
      tbc::mut_b<Commands> commands_;
    };

    using RetainedActionValidator = BasicActionValidator<RetainedCommandTabRegistry>;

  }
}

// Interface: telar_config/component_shape.cppm
export {
  namespace telar::runtime::config {

    enum class UiMark : std::uint8_t {
      claude,
      codex,
      pi,
      telar,
    };

    inline constexpr ds::Array<std::string_view, 4> ui_mark_names{"claude", "codex", "pi", "telar"};

    enum class ComponentKind : std::uint8_t {
      label,
      icon,
      mark,
      meter,
      sparkline,
      badge,
      clock,
      metric,
      machines,
      group,
      heading,
      text,
      meter_row,
      key_value,
      callout,
      actions,
      button,
      divider,
    };

    // How a component is written: as text, as a `text` or `icon` segment, or as a `ui` table.
    enum class ComponentForm : std::uint8_t {
      text,
      segment,
      component,
    };

    struct ComponentShape {
      ComponentKind kind = ComponentKind::label;
      ComponentForm form = ComponentForm::text;
      std::string_view text;
      std::string_view detail;
      std::string_view url;
      static constexpr unsigned default_priority = 50;

      const char* action_field = nullptr;
      std::size_t samples = 0;
      unsigned priority = default_priority;
      unsigned tone_bonus = 0;
    };

  }
}

// Interface: telar_config/component_budget.cppm
export {
  namespace telar::runtime::config {

    class ComponentBudget {
    public:
      struct Usage {
        std::size_t nodes = 0;
        std::size_t text = 0;
        std::size_t actions = 0;
        std::size_t samples = 0;

        Usage operator+(Usage other) const noexcept;
        Usage operator-(Usage other) const noexcept;
        [[nodiscard]] bool fits(Usage room) const noexcept;
      };

      void count(const ComponentShape& shape, unsigned rank) noexcept;
      void prepare() noexcept;
      bool admit(const ComponentShape& shape, unsigned rank) noexcept;
      void release(const ComponentShape& shape, unsigned rank) noexcept;
      bool stage(const ComponentShape& shape) noexcept;
      [[nodiscard]] bool nodesFull() const noexcept;
      void report(LimitNotices& limits) const noexcept;

    private:
      static Usage usage(const ComponentShape& shape) noexcept;

      static constexpr unsigned rank_count = 256;
      static constexpr Usage staging_capacity{.nodes = 254, .text = std::size_t{32} * 1024, .actions = 64, .samples = 2048};
      ds::Array<Usage, rank_count> ranked_{};
      Usage offered_;
      Usage taken_;
      Usage staged_;
      Usage room_;
      unsigned cutoff_ = 0;
    };

  }
}

// Interface: telar_config/component_shape_reader.cppm
export {
  namespace telar::runtime::config {

    class ComponentShapeReader {
    public:
      // A shape views the value's strings, which belong to the state in the value's region `a`.
      static tbc::val_a<ComponentShape> read(const lua::Value& value, unsigned inherited_priority, LimitNotices& limits);
      static ComponentShape segment(const lua::Value& value, unsigned priority);

    private:
      static ComponentKind kind(const lua::Value& value);
      static void fields(const lua::Value& value, ComponentKind kind);
      static tbc::val_a<std::string_view> text(const lua::Value& value, const char* name, tbc::val_a<std::string_view> fallback = {});
      static void optionalIcon(const lua::Value& value);
      static void finiteNumber(const lua::Value& value);
      static std::size_t samples(const lua::Value& value, LimitNotices& limits);

      static constexpr std::size_t maximum_glyph_bytes = 16;
      static constexpr std::size_t maximum_clock_bytes = 32;
      static constexpr std::size_t maximum_samples = 120;
    };

  }
}

// Interface: telar_config/component_values.cppm
export {
  namespace telar::runtime::config {

    enum class ComponentTone : std::uint8_t {
      neutral,
      muted,
      accent,
      success,
      warning,
      danger,
    };

    enum class ComponentMetric : std::uint8_t {
      cpu,
      memory,
      battery,
    };

    inline constexpr ds::Array<std::string_view, 6> component_tone_names{"neutral", "muted", "accent", "success", "warning", "danger"};
    inline constexpr ds::Array<std::string_view, 3> component_metric_names{"cpu", "memory", "battery"};

    // Turns the colors a configuration names into a client's: `index` takes a 256-color index
    // and `name` a name or "#RRGGBB", or nothing for one it does not know.
    template <typename Colors>
    concept UiColors = requires(const Colors& colors, std::uint8_t index, std::string_view name) {
      { colors.index(index) } -> std::same_as<typename Colors::Color>;
      { colors.name(name) } -> std::same_as<ds::Option<typename Colors::Color>>;
    };

    // What a component shows beyond its shape. The views are the component's strings.
    template <typename Color>
    struct ComponentValues {
      static constexpr std::size_t maximum_samples = 120;
      static constexpr double sample_percent = 100;
      ComponentTone tone = ComponentTone::neutral;
      ds::Option<Color> foreground;
      ds::Option<Color> background;
      bool bold = false;
      bool italic = false;
      bool faint = false;
      bool underline = false;
      bool strikethrough = false;
      ds::Option<std::string_view> icon;
      ds::Option<UiMark> mark;
      ComponentMetric metric = ComponentMetric::cpu;
      ds::Option<double> value;
      ds::Option<double> marker;
      bool primary = false;
      // A sparkline's last samples, as percentages of its scale.
      ds::Array<std::uint8_t, maximum_samples> samples{};
      std::size_t sample_count = 0;
    };

    class ComponentValuesReader {
    public:
      // Stays in the interface, as do the other templates of this class, because it is a template
      // over the client's colors.
      template <UiColors Colors>
      [[nodiscard]] TBC_GENERIC static tbc::val_a<ComponentValues<typename Colors::Color>> read(const lua::Value& value, const ComponentShape& shape, const Colors& colors) {
        ComponentValues<typename Colors::Color> result;

        if (shape.form == ComponentForm::text) {
          return result;
        }

        if (shape.form == ComponentForm::segment) {
          result.icon = icon(value.field("icon"));
          style(value, colors, result);
          return result;
        }

        result.tone = tone(value.field("tone"));
        switch (shape.kind) {
        case ComponentKind::label:
          style(value, colors, result);
          break;
        case ComponentKind::icon:
          result.icon = icon(value.field("name"));
          break;
        case ComponentKind::mark:
          result.mark = mark(value.field("name"));
          break;
        case ComponentKind::meter:
        case ComponentKind::meter_row:
          result.value = number(value.field("value"));
          result.marker = number(value.field("marker"));
          break;
        case ComponentKind::sparkline:
          samples(value, result);
          break;
        case ComponentKind::metric:
          result.metric = metric(value.field("name"));
          break;
        case ComponentKind::group:
          result.mark = mark(value.field("mark"));
          result.icon = icon(value.field("icon"));
          break;
        case ComponentKind::callout:
          result.icon = icon(value.field("icon"));
          break;
        case ComponentKind::button:
          result.primary = value.field("primary").boolean(false);
          break;
        case ComponentKind::badge:
        case ComponentKind::clock:
        case ComponentKind::machines:
        case ComponentKind::heading:
        case ComponentKind::text:
        case ComponentKind::key_value:
        case ComponentKind::actions:
        case ComponentKind::divider:
          break;
        }

        return result;
      }

      [[nodiscard]] static ComponentTone tone(const lua::Value& value);

      // Hands a component's action, which cannot be a function, to `consume` and returns what it
      // returns.
      template <typename Consume>
      TBC_GENERIC static decltype(auto) action(const lua::Value& value, const ComponentShape& shape, Consume&& consume) {
        const auto action = value.field(shape.action_field);
        if (action.is(LUA_TFUNCTION)) {
          action.fail("cannot be a callback in a component");
        }

        return std::forward<Consume>(consume)(action);
      }

    private:
      template <typename Colors, typename Values>
      TBC_GENERIC static void style(const lua::Value& value, const Colors& colors, Values& result) {
        result.foreground = color(value.field("fg"), colors);
        result.background = color(value.field("bg"), colors);
        result.bold = value.field("bold").boolean(false);
        result.italic = value.field("italic").boolean(false);
        result.faint = value.field("faint").boolean(false);
        result.underline = value.field("underline").boolean(false);
        result.strikethrough = value.field("strikethrough").boolean(false);
      }

      template <typename Colors>
      TBC_GENERIC static ds::Option<typename Colors::Color> color(const lua::Value& value, const Colors& colors) {
        if (!value.present()) {
          return ds::none;
        }

        if (const auto index = value.asInteger()) {
          if (*index < 0 || std::cmp_greater(*index, std::numeric_limits<std::uint8_t>::max())) {
            value.fail("is outside the component color index range");
          }

          return colors.index(static_cast<std::uint8_t>(*index));
        }

        auto parsed = colors.name(value.string());
        if (!parsed) {
          value.fail("is not a supported component color");
        }

        return parsed;
      }

      static tbc::val_a<ds::Option<std::string_view>> icon(const lua::Value& value);
      static ds::Option<UiMark> mark(const lua::Value& value);
      static ComponentMetric metric(const lua::Value& value);
      static ds::Option<double> number(const lua::Value& value);

      template <typename Values>
      TBC_GENERIC static void samples(const lua::Value& value, Values& result) {
        const auto maximum = value.field("max");
        const auto values = value.field("values");
        const auto total = values.listLength();

        result.sample_count = std::min(total, result.samples.size());
        ds::Array<double, Values::maximum_samples> kept{};
        double largest = 0;

        for (std::size_t index = 0; index < result.sample_count; ++index) {
          const auto sample = values.element(static_cast<lua_Integer>(total - result.sample_count + index) + 1);
          if (!sample.present()) {
            sample.fail("must be a number");
          }

          kept.atMut(index) = sample.boundedNumber(0, 0, std::numeric_limits<double>::max());
          largest = std::max(largest, kept[index]);
        }

        const auto scale = maximum.boundedNumber(largest, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());

        for (std::size_t index = 0; index < result.sample_count; ++index) {
          const auto fraction = scale > 0 ? std::clamp(kept[index] / scale, 0.0, 1.0) : 0;

          result.samples.atMut(index) = static_cast<std::uint8_t>(std::round(fraction * Values::sample_percent));
        }
      }
    };

  }
}

// Interface: telar_config/component_walker.cppm
export {
  namespace telar::runtime::config {

    enum class ComponentPlace : std::uint8_t {
      bar,
      panel,
      group,
      tooltip,
      buttons,
    };

    bool componentAllowed(ComponentKind kind, ComponentPlace place) noexcept;

    struct ComponentPosition {
      static constexpr std::uint8_t no_parent = std::numeric_limits<std::uint8_t>::max();
      static constexpr unsigned default_priority = 50;
      ComponentPlace place = ComponentPlace::bar;
      std::uint8_t parent = no_parent;
      unsigned priority = default_priority;
      unsigned rank = std::numeric_limits<std::uint8_t>::max();
      unsigned depth = 0;
    };

    // The node a builder kept for a container, which its children name as their parent.
    struct ComponentParent {
      std::uint8_t index = ComponentPosition::no_parent;
      unsigned rank = 0;
    };

    // What a walk hands each node a builder may place: `place(value, shape, position)` returns the
    // parent its children name, or nothing to leave them out.
    class ComponentPlacer {
    public:
      virtual ds::Option<ComponentParent> place(const lua::Value& value, const ComponentShape& shape, const ComponentPosition& position) = 0;

    protected:
      ComponentPlacer() = default;
      ComponentPlacer(const ComponentPlacer&) = default;
      ComponentPlacer(ComponentPlacer&&) = default;
      ComponentPlacer& operator=(const ComponentPlacer&) = default;
      ComponentPlacer& operator=(ComponentPlacer&&) = default;
      ~ComponentPlacer() = default;
    };

    // Walks a component tree: text, a component, a segment, or a list of them, handing each node to
    // a placer apart from the walk, so a frame's value stays borrowed while it is placed. An
    // explicit stack bounds both the nested lists and the Lua stack the walk holds.
    class ComponentTreeWalker {
    public:
      ComponentTreeWalker(lua_State& state, LimitNotices& limits) noexcept;

      void walk(const lua::Value& value, ComponentPosition position, ComponentPlacer& placer);

    private:
      enum class Phase : std::uint8_t {
        visit,
        list,
        children,
        tooltip,
        button,
        done,
      };

      struct Frame {
        ds::Option<lua::Value> value = ds::none;
        ComponentPosition position;
        ComponentPosition child;
        Phase phase = Phase::visit;
        bool tooltip = false;
        int index = 0;
        std::size_t next = 0;
        std::size_t count = 0;
      };

      static constexpr unsigned maximum_list_depth = 4;
      static constexpr std::size_t maximum_frames = (std::size_t{maximum_list_depth} + 2) * 2;

      void push(ComponentPosition position);
      void pop() noexcept;
      void advance(ComponentPlacer& placer);
      static const lua::Value& frameValue(const Frame& frame);
      // Each reads the frame on top of the stack, which stays there while they run.
      void visit(ComponentPlacer& placer);
      void component(ComponentPlacer& placer);
      static ds::Option<ComponentParent> node(ComponentPlacer& placer, const lua::Value& value, const ComponentShape& shape, const ComponentPosition& position);

      lua_State& state_;
      LimitNotices& limits_;
      ds::Array<Frame, maximum_frames> frames_{};
      std::size_t frame_count_ = 0;
    };

    // A walk that hands each node to `builder.node(value, shape, position)`. Stays in the interface
    // because it is a template over the caller's builder; it only forwards to it.
    template <typename Builder>
    class TBC_GENERIC ComponentWalker final {
    public:
      inline ComponentWalker(lua_State& state, Builder& builder, LimitNotices& limits) noexcept
          : walker_(state, limits),
            placer_(builder) {}

      inline void walk(const lua::Value& value, ComponentPosition position) {
        walker_.walk(value, position, placer_);
      }

    private:
      class Placer final : public ComponentPlacer {
      public:
        inline explicit Placer(Builder& builder) noexcept
            : builder_(builder) {}

        inline ds::Option<ComponentParent> place(const lua::Value& value, const ComponentShape& shape, const ComponentPosition& position) override {
          return builder_.node(value, shape, position);
        }

      private:
        Builder& builder_;
      };

      ComponentTreeWalker walker_;
      Placer placer_;
    };

  }
}

// Interface: telar_config/element_reader.cppm
export {
  namespace telar::runtime::config {

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

    inline constexpr ds::Array<std::string_view, 13> element_kind_names{"row", "column", "stack", "spacer", "label", "icon", "mark", "badge", "tile", "canvas", "builtin", "elapsed", "clock"};

    // Native pieces `ui.builtin` can place: every slot plus parts of the two bars.
    inline constexpr ds::Array<std::string_view, 27> ui_builtin_names{
        "tab",
        "pane_header",
        "agent_card",
        "tab_cards",
        "tab_title",
        "tab_path",
        "tab_activity",
        "pane_mark",
        "pane_program",
        "pane_context",
        "pane_status",
        "pane_progress",
        "pane_actions",
        "agent_mark",
        "agent_title",
        "agent_project",
        "agent_status",
        "sidebar_toggle",
        "workspace_identity",
        "project_switcher",
        "tabs",
        "palette_button",
        "new_tab",
        "metrics",
        "bar_left",
        "bar_center",
        "bar_right",
    };

    template <typename Color>
    struct ElementColorSetting {
      ds::Option<Color> value = ds::none;
      std::uint8_t alpha = std::numeric_limits<std::uint8_t>::max();
    };

    // One element as read. Its texts view the result's strings.
    template <typename Color>
    struct ElementSetting {
      static constexpr std::uint32_t none = std::numeric_limits<std::uint32_t>::max();
      static constexpr std::size_t maximum_elements = 4096;
      static constexpr std::size_t maximum_text_bytes = std::size_t{256} * 1024;
      static constexpr std::size_t maximum_steps = 4096;
      static constexpr std::size_t maximum_actions = 1024;
      static constexpr unsigned maximum_depth = 32;

      ElementKind kind = ElementKind::row;
      std::uint32_t parent = none;
      std::string_view text;
      std::string_view key;
      std::string_view tooltip;
      std::string_view url;
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
      ElementColorSetting<Color> background;
      ElementColorSetting<Color> border;
      ElementColorSetting<Color> color;
      ElementColorSetting<Color> hover;
      ComponentTone tone = ComponentTone::neutral;
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

    template <typename Color>
    struct CanvasStepSetting {
      static constexpr std::size_t maximum_values = 6;

      std::uint8_t op = 0;
      std::uint8_t count = 0;
      ds::Array<float, maximum_values> values{};
      ElementColorSetting<Color> color;
      std::string_view text;
    };

    // Turns what a slot function returned into elements, handing each one to `sink`:
    // `element(setting)` keeps an element and returns its index, `step(setting)` keeps a canvas
    // operation, `resolve(action)` reads an `on_click` action, or drops it, `bind(resolved)`
    // keeps the action it read and `callback(function)` keeps an `on_click` function and returns
    // its index. Each view the sink gets is one of the result's strings. Stays in the interface
    // because it is a template over the client's colors and sink.
    template <UiColors Colors, typename Sink>
    class TBC_GENERIC ElementReader {
    public:
      using Element = ElementSetting<typename Colors::Color>;
      using Kind = ElementKind;
      using Value = lua::Value;

      inline ElementReader(Sink& sink, const Colors& colors) noexcept
          : sink_(sink),
            colors_(colors) {}

      inline void read(const Value& root) {
        if (root.is(LUA_TTABLE) && !root.field("ui").present()) {
          Element row;
          const auto index = append(root, row);

          children(root, index, 1);

          return;
        }

        element(root, Element::none, 0);
      }

    private:
      // The bounds of what an element may set.
      static constexpr std::uint64_t maximum_lines = 64;
      static constexpr double maximum_grow = 1000;
      static constexpr double maximum_rotation = 3600;
      static constexpr double maximum_scale = 16;
      static constexpr double maximum_z = 1000;
      static constexpr double maximum_text_size = 256;
      static constexpr double maximum_length = 100'000;
      static constexpr double maximum_canvas_value = 1e6;

      inline void element(const Value& value, std::uint32_t parent, unsigned depth) { // NOLINT(misc-no-recursion): bounded by Element::maximum_depth; an explicit stack of Lua slots, as ComponentTreeWalker keeps, needs the lua_State this reader does not get.
        if (!value.present()) {
          return;
        }

        if (depth > Element::maximum_depth) {
          value.fail("nests elements deeper than 32 levels");
        }

        if (value.is(LUA_TSTRING)) {
          Element label;

          label.kind = Kind::label;
          label.parent = parent;
          label.text = text(value);
          static_cast<void>(append(value, label));

          return;
        }

        if (!value.is(LUA_TTABLE)) {
          value.fail("must be text, an element or a list of elements");
        }

        if (!value.field("ui").present()) {
          // A list inside a container flattens into it.
          children(value, parent, depth + 1);

          return;
        }

        const auto name = value.field("ui").string();
        const auto* const found = std::ranges::find(element_kind_names, name);
        if (found == element_kind_names.end()) {
          value.field("ui").fail("names an unknown element");
        }

        Element result;

        result.kind = static_cast<Kind>(found - element_kind_names.begin());
        result.parent = parent;
        fields(value, result);
        const auto index = append(value, result);

        if (result.kind == Kind::row || result.kind == Kind::column || result.kind == Kind::stack) {
          children(value, index, depth + 1);
        }
      }

      inline void children(const Value& value, std::uint32_t parent, unsigned depth) { // NOLINT(misc-no-recursion): bounded by Element::maximum_depth.
        const auto count = value.listLength();

        for (std::size_t index = 0; index < count; ++index) {
          element(value.element(static_cast<lua_Integer>(index) + 1), parent, depth);
        }
      }

      inline std::uint32_t append(const Value& value, const Element& element) {
        if (elements_ == Element::maximum_elements) {
          value.fail("exceeds 4096 elements");
        }

        ++elements_;

        return sink_.element(element);
      }

      static constexpr ds::Array<std::string_view, 27> layout_fields{"ui", "id", "width", "height", "min_width", "max_width", "min_height", "max_height", "grow", "align_self", "x", "y", "rotation", "scale", "opacity", "z", "background", "border", "radius", "padding", "shadow", "clip", "on_click", "url", "tooltip", "hover", "transition"};

      inline void fields(tbc::ref_a<Value> value, tbc::mut_a<Element> element) {
        switch (element.kind) {
        case Kind::row:
        case Kind::column:
        case Kind::stack:
          value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"gap", "align", "justify"})}, true);
          element.gap = length(value.field("gap"), 0);
          element.align = choice(value.field("align"), {"start", "center", "end", "stretch"}, 0);
          element.justify = choice(value.field("justify"), {"start", "center", "end", "between"}, 0);
          break;
        case Kind::spacer:
          value.onlyFields(std::span<const std::string_view>{layout_fields});
          element.grow = 1;
          break;
        case Kind::label:
          value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"text", "size", "bold", "italic", "color", "tone", "max_lines"})});
          element.text = text(value.field("text"));
          typography(value, element);
          element.max_lines = static_cast<std::uint8_t>(value.field("max_lines").boundedInteger(1, 1, maximum_lines));
          break;
        case Kind::icon:
          value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"name", "glyph", "size", "color", "tone"})});
          element.named = value.field("name").present();
          element.text = text(element.named ? value.field("name") : value.field("glyph"));
          if (element.text.empty()) {
            value.fail("requires an icon name or a glyph");
          }

          typography(value, element);
          break;
        case Kind::mark:
          value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"name"})});
          uiMark(value.field("name"));
          element.text = text(value.field("name"));
          break;
        case Kind::badge:
          value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"text", "tone", "color", "size"})});
          element.text = text(value.field("text"));
          typography(value, element);
          break;
        case Kind::tile:
          value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"program", "size"})});
          element.text = text(value.field("program"));
          element.size = length(value.field("size"), 0);
          break;
        case Kind::canvas:
          value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"ops", "label"})});
          element.text = text(value.field("label"));
          canvas(value.field("ops"), element);
          break;
        case Kind::builtin: {
          value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"name"})});
          const auto name = value.field("name").string();
          if (std::ranges::find(ui_builtin_names, name) == ui_builtin_names.end()) {
            value.field("name").fail("names an unknown built-in piece");
          }

          element.text = text(value.field("name"));
        } break;
        case Kind::elapsed:
          value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"since", "size", "bold", "color", "tone"})});
          element.since = value.field("since").integer();
          typography(value, element);
          break;
        case Kind::clock:
          value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"format", "size", "bold", "color", "tone"})});
          element.text = value.field("format").present() ? text(value.field("format")) : store("%H:%M", value);
          typography(value, element);
          break;
        }

        box(value, element);
      }

      inline void box(tbc::ref_a<Value> value, tbc::mut_a<Element> element) {
        if (const auto id = value.field("id"); id.present()) {
          element.key = text(id);
        }

        element.width = length(value.field("width"), -1);
        element.height = length(value.field("height"), -1);
        element.min_width = length(value.field("min_width"), 0);
        element.max_width = length(value.field("max_width"), -1);
        element.min_height = length(value.field("min_height"), 0);
        element.max_height = length(value.field("max_height"), -1);
        element.grow = static_cast<float>(value.field("grow").boundedNumber(element.grow, 0, maximum_grow));
        if (const auto align = value.field("align_self"); align.present()) {
          element.align_self = choice(align, {"start", "center", "end", "stretch"}, 0);
        }

        element.x = offset(value.field("x"));
        element.y = offset(value.field("y"));
        element.rotation = static_cast<float>(value.field("rotation").boundedNumber(0, -maximum_rotation, maximum_rotation));
        element.scale = static_cast<float>(value.field("scale").boundedNumber(1, 0, maximum_scale));
        element.opacity = static_cast<float>(value.field("opacity").boundedNumber(1, 0, 1));
        element.z = static_cast<std::int16_t>(std::lround(value.field("z").boundedNumber(0, -maximum_z, maximum_z)));
        element.background = color(value.field("background"));
        element.radius = length(value.field("radius"), 0);
        element.shadow = value.field("shadow").boolean(false);
        element.clip = value.field("clip").boolean(false);
        padding(value.field("padding"), element);
        if (const auto border = value.field("border"); border.present()) {
          if (border.is(LUA_TTABLE)) {
            border.onlyFields({"color", "width"});
            element.border = color(border.field("color"));
            element.border_width = length(border.field("width"), 1);
          } else {
            element.border = color(border);
            element.border_width = 1;
          }
        }

        if (const auto hover = value.field("hover"); hover.present()) {
          hover.onlyFields({"background"});
          element.hover = color(hover.field("background"));
        }

        transition(value.field("transition"), element);
        if (const auto tooltip = value.field("tooltip"); tooltip.present()) {
          element.tooltip = text(tooltip);
        }

        if (const auto url = value.field("url"); url.present()) {
          const auto link = url.string();
          constexpr std::size_t maximum_url_bytes = 1024;
          if (link.size() > maximum_url_bytes || link.contains(' ') || (!link.starts_with("https://") && !link.starts_with("http://"))) {
            url.fail("must be an http or https address");
          }

          element.url = text(url);
        }

        click(value.field("on_click"), element);
      }

      inline void transition(const Value& value, Element& element) {
        constexpr std::uint64_t default_transition_ms = 220;
        constexpr std::uint64_t maximum_transition_ms = 10'000;

        if (!value.present()) {
          return;
        }

        if (!value.is(LUA_TTABLE)) {
          element.transition_ms = static_cast<std::uint16_t>(value.boundedInteger(default_transition_ms, 0, maximum_transition_ms));
          return;
        }

        value.onlyFields({"duration", "easing"});
        element.transition_ms = static_cast<std::uint16_t>(value.field("duration").boundedInteger(default_transition_ms, 0, maximum_transition_ms));
        element.easing = choice(value.field("easing"), {"ease_out", "linear", "ease_in_out"}, 0);
      }

      inline void click(const Value& value, Element& element) {
        if (!value.present()) {
          return;
        }

        if (value.is(LUA_TFUNCTION)) {
          if (callbacks_ == Element::maximum_actions) {
            value.fail("exceeds 1024 click functions");
          }

          element.callback = sink_.callback(value);
          ++callbacks_;
        } else if (auto resolved = sink_.resolve(value)) {
          if (actions_ == Element::maximum_actions) {
            value.fail("exceeds 1024 click actions");
          }

          element.action = actions_++;
          sink_.bind(std::move(resolved.getMut()));
        }
      }

      inline void typography(const Value& value, Element& element) {
        if (const auto size = value.field("size"); size.present()) {
          if (size.is(LUA_TSTRING)) {
            element.size_role = choice(size, {"title", "body", "small"}, 1);
          } else {
            element.size = static_cast<float>(size.boundedNumber(0, 1, maximum_text_size));
          }
        }

        element.bold = value.field("bold").boolean(false);
        element.italic = value.field("italic").boolean(false);
        element.color = color(value.field("color"));
        element.tone = ComponentValuesReader::tone(value.field("tone"));
      }

      inline void padding(const Value& value, Element& element) {
        if (!value.present()) {
          return;
        }

        if (!value.is(LUA_TTABLE)) {
          element.padding.fill(length(value, 0));

          return;
        }

        // CSS order: {all}, {vertical, horizontal} or {top, right, bottom, left}.
        const auto count = value.listLength();
        ds::Array<float, 4> sides{};

        for (std::size_t index = 0; index < std::min<std::size_t>(count, 4); ++index) {
          sides.atMut(index) = length(value.element(static_cast<lua_Integer>(index) + 1), 0);
        }

        if (count == 1) {
          element.padding.fill(sides[0]);
        } else if (count == 2) {
          element.padding = {sides[1], sides[0], sides[1], sides[0]};
        } else if (count == 4) {
          element.padding = {sides[3], sides[0], sides[1], sides[2]};
        } else {
          value.fail("must hold one, two or four lengths");
        }
      }

      inline void canvas(const Value& ops, Element& element) {
        struct Shape {
          std::string_view name;
          std::uint8_t numbers = 0;
          bool text = false;
          bool color = false;
        };

        // Matches ElementCanvas::Operation, in order.
        constexpr ds::Array<Shape, 21> shapes{
            {
                {"move", 2, false, false},
                {"line", 2, false, false},
                {"curve", 6, false, false},
                {"quad", 4, false, false},
                {"arc", 5, false, false},
                {"rect", 4, false, false},
                {"round_rect", 5, false, false},
                {"circle", 3, false, false},
                {"path", 0, true, false},
                {"close", 0, false, false},
                {"fill", 0, false, true},
                {"stroke", 1, false, true},
                {"width", 1, false, false},
                {"cap", 0, true, false},
                {"join", 0, true, false},
                {"alpha", 1, false, false},
                {"translate", 2, false, false},
                {"rotate", 1, false, false},
                {"scale", 2, false, false},
                {"save", 0, false, false},
                {"restore", 0, false, false},
            },
        };

        element.steps_offset = steps_;
        const auto count = ops.present() ? ops.listLength() : 0;

        for (std::size_t index = 0; index < count; ++index) {
          if (steps_ == Element::maximum_steps) {
            ops.fail("exceeds 4096 canvas operations");
          }

          const auto operation = ops.element(static_cast<lua_Integer>(index) + 1);
          const auto name = operation.element(1).string();
          const auto* const shape = std::ranges::find(shapes, name, &Shape::name);
          if (shape == shapes.end()) {
            operation.fail("names an unknown canvas operation");
          }

          CanvasStepSetting<typename Colors::Color> step;

          step.op = static_cast<std::uint8_t>(shape - shapes.begin());
          lua_Integer next = 2;

          if (shape->text) {
            step.text = text(operation.element(next++));
          }

          if (shape->color) {
            step.color = color(operation.element(next++));
          }

          const auto available = operation.listLength() - static_cast<std::size_t>(next - 1);

          step.count = static_cast<std::uint8_t>(std::min<std::size_t>(available, shape->numbers));
          if ((step.count < shape->numbers && shape->name != "stroke" && shape->name != "scale") || available > shape->numbers) {
            operation.fail("has the wrong number of values");
          }

          for (std::uint8_t number = 0; number < step.count; ++number) {
            step.values.atMut(number) = static_cast<float>(operation.element(next++).boundedNumber(0, -maximum_canvas_value, maximum_canvas_value));
          }

          sink_.step(step);
          ++steps_;
        }

        element.steps_count = steps_ - element.steps_offset;
      }

      inline ElementColorSetting<typename Colors::Color> color(const Value& value) const {
        ElementColorSetting<typename Colors::Color> result;

        if (!value.present()) {
          return result;
        }

        if (const auto index = value.asInteger()) {
          if (!std::in_range<std::uint8_t>(*index)) {
            value.fail("is outside the color index range");
          }

          result.value = colors_.index(static_cast<std::uint8_t>(*index));

          return result;
        }

        auto name = value.string();
        constexpr std::size_t rgba_length = std::string_view{"#RRGGBBAA"}.size();
        if (name.size() == rgba_length && name.front() == '#') {
          unsigned alpha = 0;
          const auto parsed = std::from_chars(name.data() + rgba_length - 2, name.data() + rgba_length, alpha, 16);
          if (std::make_error_code(parsed.ec) || parsed.ptr != name.data() + rgba_length) {
            value.fail("is not a supported color");
          }

          result.alpha = static_cast<std::uint8_t>(alpha);
          name.remove_suffix(2);
        }

        result.value = colors_.name(name);
        if (!result.value) {
          value.fail("is not a supported color");
        }

        return result;
      }

      inline static float length(const Value& value, float fallback) {
        return static_cast<float>(value.boundedNumber(static_cast<double>(fallback), 0, maximum_length));
      }

      inline static float offset(const Value& value) {
        return static_cast<float>(value.boundedNumber(0, -maximum_length, maximum_length));
      }

      inline static std::uint8_t choice(const Value& value, std::initializer_list<std::string_view> names, std::uint8_t fallback) {
        if (!value.present()) {
          return fallback;
        }

        const auto name = value.string();
        const auto* const found = std::ranges::find(names, name);
        if (found == names.end()) {
          value.fail("names an unknown option");
        }

        return static_cast<std::uint8_t>(found - names.begin());
      }

      struct Fields {
        static constexpr std::size_t capacity = 40;

        ds::Array<std::string_view, capacity> names{};
        std::size_t count = 0;

        explicit operator std::span<const std::string_view>() const noexcept {
          return std::span{names}.first(count);
        }
      };

      // The fields name what the base and the extra names view, region `a`.
      inline static tbc::val_a<Fields> combined(tbc::val_a<std::span<const std::string_view>> base, tbc::val_a<std::initializer_list<std::string_view>> extra) {
        Fields result;

        for (const auto name : base) {
          result.names.atMut(result.count++) = name;
        }

        for (const auto name : extra) {
          result.names.atMut(result.count++) = name;
        }

        return result;
      }

      // The texts view the strings the Lua state holds, region `a`, as Value::string does.
      inline tbc::val_a<std::string_view> text(const Value& value) {
        if (!value.present()) {
          return {};
        }

        return store(value.string(), value);
      }

      inline tbc::val_a<std::string_view> store(tbc::val_a<std::string_view> text, const Value& value) {
        validateUtf8(text);
        constexpr unsigned char first_printable = 0x20;
        constexpr unsigned char delete_control = 0x7f;
        if (std::ranges::any_of(text, [](unsigned char byte) {
              return (byte < first_printable && byte != '\n') || byte == delete_control;
            })) {
          value.fail("holds control characters");
        }

        if (text.size() > Element::maximum_text_bytes - text_bytes_) {
          value.fail("exceeds 256 KiB of element text");
        }

        text_bytes_ += text.size();

        return text;
      }

      Sink& sink_;
      const Colors& colors_;
      std::uint32_t elements_ = 0;
      std::uint32_t steps_ = 0;
      std::uint32_t actions_ = 0;
      std::uint32_t callbacks_ = 0;
      std::size_t text_bytes_ = 0;
    };

  }
}

// Interface: telar_config/command_arguments_reader.cppm
export {
  namespace telar::runtime::config {

    class CommandArgumentsReader {
    public:
      // Hands each argument of the definition's `field` list to `visit`, in order. Stays in the
      // interface because it is a template over the caller's callable.
      template <typename Visit>
      TBC_GENERIC static void read(const lua::Value& definition, const char* field, const Visit& visit) {
        const auto command = definition.field(field);
        const auto count = command.listLength();

        for (std::size_t index = 0; index < count; ++index) {
          visit(command.element(static_cast<lua_Integer>(index) + 1).string());
        }
      }
    };

  }
}

// Interface: telar_config/source_reader.cppm
export {
  namespace telar::runtime::config {

    // What fills a bar position or a panel, as `bar_kind` names it.
    enum class SourceKind : std::uint8_t {
      tabs,
      metrics,
      machines,
      fixed,
      dynamic,
      command,
    };

    inline constexpr ds::Array<std::string_view, 6> source_kind_names{"tabs", "metrics", "machines", "static", "dynamic", "command"};

    struct SourceSetting {
      static constexpr Bounds<std::uint64_t> every_ms_bounds{.minimum = 100, .maximum = 3'600'000};
      static constexpr Bounds<std::uint64_t> timeout_ms_bounds{.minimum = 100, .maximum = 10'000};
      static constexpr std::uint32_t default_every_ms = 1000;
      static constexpr std::uint32_t default_timeout_ms = 2000;
      SourceKind kind = SourceKind::tabs;
      // How often a dynamic or command source renders. A panel's renders when it opens, unless
      // it sets an interval.
      ds::Option<std::uint32_t> every_ms;
      std::uint32_t timeout_ms = default_timeout_ms;
      // Whether it has a render function; a command source without one shows the output.
      bool render = false;
    };

    class SourceReader {
    public:
      [[nodiscard]] static SourceSetting read(const lua::Value& source, bool panel = false);

      // Validates a source that renders, a dynamic or a command one, and reads it.
      [[nodiscard]] static SourceSetting dynamic(const lua::Value& source, bool panel = false);
    };

  }
}

// Interface: telar_config/bars_reader.cppm
export {
  namespace telar::runtime::config {

    enum class BarPosition : std::uint8_t {
      bottom_left,
      bottom_center,
      bottom_right,
      top_right,
      footer_left,
      footer_center,
      footer_right,
    };

    class BarsReader {
    public:
      static constexpr std::size_t footer_slots = 3;

      // The content of a static source.
      [[nodiscard]] static lua::Value content(const lua::Value& source);

      // Hands `visit` each position `client.bars` sets with its source. A footer hands its three
      // slots, an empty one with a nil source. Stays in the interface because it is a template
      // over the caller's callable.
      template <typename Visit>
      TBC_GENERIC static void sources(const lua::Value& client, const Visit& visit) {
        const auto bars = client.field("bars");
        if (!bars.present()) {
          return;
        }

        const auto bottom = bars.field("bottom");
        if (bottom.present()) {
          constexpr ds::Array names{"left", "center", "right"};

          for (std::size_t index = 0; index < names.size(); ++index) {
            visit(static_cast<BarPosition>(index), bottom.field(names[index]));
          }
        }

        const auto top = bars.field("top");
        if (top.present()) {
          visit(BarPosition::top_right, top.field("right"));
        }

        const auto footer = bars.field("sidebar_footer");
        if (footer.present()) {
          // An array has nothing past its size, so a slot it leaves empty reads nil.
          static_cast<void>(footer.arraySize());

          for (std::size_t index = 0; index < footer_slots; ++index) {
            const auto position = static_cast<BarPosition>(std::to_underlying(BarPosition::footer_left) + index);

            visit(position, footer.element(static_cast<lua_Integer>(index) + 1));
          }
        }
      }
    };

  }
}

// Interface: telar_config/key_chord.cppm
export {
  namespace telar::runtime::config {

    struct KeyChord {
      enum class Key : std::uint8_t {
        character,
        up,
        down,
        left,
        right,
        home,
        end,
        erase,
        page_up,
        page_down,
        enter,
        escape,
        backspace,
        tab,
        back_tab,
      };

      enum class Modifier : std::uint8_t {
        none = 0,
        control = 1,
        alt = 2,
        shift = 4,
        super = 8,
      };

      Key key = Key::character;
      std::uint32_t character = 0;
      unsigned modifiers = 0;

      [[nodiscard]] bool has(Modifier modifier) const noexcept;

      bool operator==(const KeyChord&) const = default;
    };

  }
}

// Interface: telar_config/binding_keymap.cppm
export {
  namespace telar::runtime::config {

    class BindingKeymap {
    public:
      struct Sequence {
        ds::Array<KeyChord, 2> keys{};
        std::size_t length = 0;
        bool prefixed = false;
      };

      void setPrefix(KeyChord prefix) noexcept;
      [[nodiscard]] KeyChord prefix() const noexcept;
      void clear() noexcept;
      void append(Sequence sequence) noexcept;
      void report(LimitNotices& limits) const noexcept;

      static constexpr std::size_t maximum_bindings = 256;

    private:
      static constexpr std::size_t default_suffix_count = 43;

      static constexpr ds::Array<KeyChord, default_suffix_count> defaultSuffixes() noexcept {
        using Key = KeyChord::Key;
        constexpr auto shift = static_cast<unsigned>(KeyChord::Modifier::shift);
        constexpr auto alt = static_cast<unsigned>(KeyChord::Modifier::alt);

        return ds::Array<KeyChord, default_suffix_count>{
            {
                {.key = Key::character, .character = '-'},
                {.key = Key::character, .character = '='},
                {.key = Key::character, .character = '%'},
                {.key = Key::character, .character = '"'},
                {.key = Key::left},
                {.key = Key::right},
                {.key = Key::up},
                {.key = Key::down},
                {.key = Key::left, .character = 0, .modifiers = shift},
                {.key = Key::right, .character = 0, .modifiers = shift},
                {.key = Key::up, .character = 0, .modifiers = shift},
                {.key = Key::down, .character = 0, .modifiers = shift},
                {.key = Key::character, .character = 'z'},
                {.key = Key::character, .character = 's'},
                {.key = Key::left, .character = 0, .modifiers = alt},
                {.key = Key::right, .character = 0, .modifiers = alt},
                {.key = Key::character, .character = 'w'},
                {.key = Key::character, .character = 'u'},
                {.key = Key::character, .character = 'N'},
                {.key = Key::character, .character = 'W'},
                {.key = Key::character, .character = 'x'},
                {.key = Key::character, .character = 'd'},
                {.key = Key::character, .character = '['},
                {.key = Key::character, .character = 'g'},
                {.key = Key::character, .character = '/'},
                {.key = Key::character, .character = 'f'},
                {.key = Key::character, .character = '?'},
                {.key = Key::character, .character = 'c'},
                {.key = Key::character, .character = 'n'},
                {.key = Key::character, .character = 'p'},
                {.key = Key::character, .character = '1'},
                {.key = Key::character, .character = '2'},
                {.key = Key::character, .character = '3'},
                {.key = Key::character, .character = '4'},
                {.key = Key::character, .character = '5'},
                {.key = Key::character, .character = '6'},
                {.key = Key::character, .character = '7'},
                {.key = Key::character, .character = '8'},
                {.key = Key::character, .character = '9'},
                {.key = Key::character, .character = 'T'},
                {.key = Key::character, .character = 'X'},
                {.key = Key::character, .character = ','},
                {.key = Key::character, .character = '.'},
            },
        };
      }

      KeyChord prefix_{.key = KeyChord::Key::character, .character = 'b', .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};
      ds::Array<Sequence, maximum_bindings> bindings_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: telar_config/key_chord_validator.cppm
export {
  namespace telar::runtime::config {

    class KeyChordValidator {
      using Modifier = KeyChord::Modifier;
      using Key = KeyChord::Key;

    public:
      static void validate(const lua::Value& value);
      static KeyChord parse(const lua::Value& value);

    private:
      static bool matches(std::string_view text, std::string_view name) noexcept;
      static Modifier identifyModifier(std::string_view name) noexcept;
      static void parseKey(const lua::Value& value, std::string_view name, KeyChord& chord);
    };

  }
}

// Interface: telar_config/binding_reader.cppm
export {
  namespace telar::runtime::config {

    // One `client.keybindings` entry as read; a prefixed binding starts with the prefix.
    struct BindingSetting {
      static constexpr std::size_t maximum_keys = 5;
      ds::Array<KeyChord, maximum_keys> keys{};
      std::size_t length = 0;
      bool prefixed = false;
      bool expression = false;
    };

    class BindingReader {
    public:
      static constexpr std::size_t maximum_bindings = BindingKeymap::maximum_bindings;

      // Hands the first maximum_bindings entries of `bindings` to `visit`, each with its action,
      // and returns how many it lists. Stays in the interface because it is a template over the
      // caller's callable; each entry is read out of line.
      template <typename Visit>
      TBC_GENERIC static std::size_t read(const lua::Value& bindings, KeyChord prefix, const Visit& visit) {
        if (!bindings.present()) {
          return 0;
        }

        const auto listed = bindings.listLength();
        const auto count = std::min(listed, maximum_bindings);

        for (std::size_t index = 1; index <= count; ++index) {
          const auto binding = bindings.element(static_cast<lua_Integer>(index));
          const auto parsed = setting(binding, prefix);

          visit(parsed, binding.field("action"));
        }

        return listed;
      }

    private:
      static BindingSetting setting(const lua::Value& binding, KeyChord prefix);
    };

    class BindingValidator {
    public:
      template <CommandTabStore Commands>
      static void validate(const lua::Value& bindings, BasicActionValidator<Commands>& actions, BindingKeymap& keymap, LimitNotices& limits);
    };

  }
}

// Interface: telar_config/callback_context.cppm
export {
  namespace telar::runtime::config {

    struct BindingContext {
      bool sidebar_visible = true;
      std::uint16_t tab_count = 0;
      std::uint16_t active_tab_index = 0;
      std::uint16_t pane_count = 0;
      std::uint64_t focused_pane_id = 0;
    };

    // The arguments of `telar plugin-worker`, which the GUI writes and the CLI reads.
    struct PluginWorkerOptions {
      static constexpr std::string_view command = "plugin-worker";
      static constexpr std::size_t argument_count = 7;

      const char* entry = nullptr;
      const char* action = nullptr;
      BindingContext context;

      static PluginWorkerOptions parse(std::span<char* const> arguments);

      // Hands `consume` each word after the command, in the order parse reads them. Stays in the
      // interface because it is a template over the caller's callable.
      template <typename Consume>
      TBC_GENERIC void eachArgument(const Consume& consume) const {
        consume(std::string_view{entry});
        consume(std::string_view{action});
        consume(std::string_view{context.sidebar_visible ? "1" : "0"});
        for (const std::uint64_t value : {std::uint64_t{context.tab_count}, std::uint64_t{context.active_tab_index}, std::uint64_t{context.pane_count}, context.focused_pane_id}) {
          // The digits of the largest std::uint64_t.
          constexpr std::size_t maximum_digits = 20;

          ds::Array<char, maximum_digits> digits{};
          const auto written = std::to_chars(digits.dataMut(), digits.dataMut() + digits.size(), value);

          consume(std::string_view{digits.data(), static_cast<std::size_t>(written.ptr - digits.data())});
        }
      }

    private:
      template <std::unsigned_integral Integer>
      static Integer number(std::string_view text);
    };

  }
}

// Interface: telar_config/callback_invocation.cppm
export {
  namespace telar::runtime::config {

    class CallbackInvocation {
    public:
      explicit CallbackInvocation(int reference, BindingContext context);
      static int invoke(lua_State* state);

    private:
      void pushContext(lua_State* state) const;

      int reference_;
      BindingContext context_;
    };

  }
}

// Interface: telar_config/callback_result_reader.cppm
export {
  namespace telar::runtime::config {

    // What an expression binding's function decided for the keys that triggered it.
    struct InputDecisionSetting {
      enum class Kind : std::uint8_t {
        consume,
        forward,
        keys,
        paste,
      };

      static constexpr std::size_t maximum_keys = 16;
      Kind kind = Kind::consume;
      ds::Array<KeyChord, maximum_keys> keys{};
      std::size_t length = 0;
      // A view of the result's string, alive while the result is.
      std::string_view text;
    };

    // Reads what a binding's function returned.
    class CallbackResultReader {
    public:
      // Hands each of the first `maximum` actions of an action or an array of actions to `visit`
      // and returns how many it dropped past them. Stays in the interface, as does `action`,
      // because it is a template over the caller's callable.
      template <typename Visit>
      TBC_GENERIC static std::size_t actions(const lua::Value& result, std::size_t maximum, const Visit& visit) {
        if (!result.is(LUA_TTABLE)) {
          result.fail("must be an action or an array of actions");
        }

        if (result.field("kind").present()) {
          action(result, visit);
          return 0;
        }

        const auto count = result.listLength();

        for (std::size_t index = 0; index < std::min(count, maximum); ++index) {
          action(result.element(static_cast<lua_Integer>(index) + 1), visit);
        }

        return count - std::min(count, maximum);
      }

      [[nodiscard]] static InputDecisionSetting decision(const lua::Value& result);

    private:
      template <typename Visit>
      TBC_GENERIC static void action(const lua::Value& value, Visit& visit) {
        if (value.is(LUA_TFUNCTION)) {
          value.fail("cannot return a recursive callback");
        }

        visit(value);
      }

      static void keys(const lua::Value& keys, InputDecisionSetting& decision);
    };

  }
}

// Interface: telar_config/pick_items_reader.cppm
export {
  namespace telar::runtime::config {

    // One pick option as listed: a label alone, or a table. The views are the list's strings.
    struct PickItemSetting {
      using Swatch = ds::Array<std::uint32_t, 3>;
      std::string_view label;
      ds::Option<std::string_view> value;
      ds::Option<std::string_view> detail;
      ds::Option<Swatch> swatch;
      bool selected = false;
    };

    class PickItemsReader {
    public:
      // Hands each option of `items` to `visit` with its value, in order. Stays in the interface,
      // as does `definition`, because it is a template over the caller's callable.
      template <typename Visit>
      TBC_GENERIC static void read(const lua::Value& items, const Visit& visit) {
        const auto count = items.arraySize();

        for (std::size_t index = 1; index <= count; ++index) {
          const auto item = items.element(static_cast<lua_Integer>(index));
          const auto setting = option(item);

          visit(setting, item);
        }
      }

      // The options a pick definition lists.
      template <typename Visit>
      TBC_GENERIC static void definition(const lua::Value& pick, const Visit& visit) {
        read(pick.field("items"), visit);
      }

    private:
      static PickItemSetting option(const lua::Value& item);
      static ds::Option<PickItemSetting::Swatch> swatch(const lua::Value& value);
    };

  }
}

// Interface: telar_config/client_definitions_reader.cppm
export {
  namespace telar::runtime::config {

    // A named `client.panels` or `client.picks` definition's name and title; the views are the
    // configuration's strings.
    struct DefinitionHeading {
      std::string_view name;
      std::string_view title;
    };

    struct PanelSetting {
      static constexpr Bounds<std::uint64_t> width_bounds{.minimum = 240, .maximum = 720};
      static constexpr std::uint16_t default_width = 420;
      DefinitionHeading heading;
      std::uint16_t width = default_width;
      ds::Option<UiMark> mark;
      // An icon name, as uiIcon admits it.
      ds::Option<std::string_view> icon;
      SourceSetting source;
    };

    struct PickSetting {
      static constexpr Bounds<std::uint64_t> timeout_ms_bounds{.minimum = 100, .maximum = 60'000};
      DefinitionHeading heading;
      std::uint32_t timeout_ms = SourceSetting::default_timeout_ms;
      // Whether a command lists the options, and whether a function renders them.
      bool command = false;
      bool render = false;
      bool refresh = true;
    };

    // How many panels and picks a client table defines, for each list it has.
    struct DefinitionCounts {
      ds::Option<std::size_t> panels;
      ds::Option<std::size_t> picks;
    };

    class ClientDefinitionsReader {
    public:
      // Validates and reads `client.panels` and `client.picks`, in name order, handing each
      // panel to `panel` with its source and each pick to `pick` with its definition. Stays in the
      // interface because it is a template over the caller's callables; each definition is read
      // out of line.
      template <typename Panel, typename Pick>
      TBC_GENERIC static DefinitionCounts read(const lua::Value& client, LimitNotices& limits, const Panel& panel, const Pick& pick) {
        DefinitionCounts counts;

        counts.panels = NamedDefinitionsValidator::validate(client.field("panels"), {"panels.max_panels", "panels", NamedDefinitionsValidator::maximum_definitions, {}, {}}, limits, [&](std::string_view name, const lua::Value& definition, std::size_t index) {
          const auto setting = panelSetting(name, definition, limits);

          panel(index, setting, definition.field("source"));
        });

        counts.picks = NamedDefinitionsValidator::validate(client.field("picks"), {"picks.max_picks", "picks", NamedDefinitionsValidator::maximum_definitions, {}, {}}, limits, [&](std::string_view name, const lua::Value& definition, std::size_t index) {
          const auto setting = pickSetting(name, definition, limits);

          pick(index, setting, definition);
        });

        return counts;
      }

    private:
      // A setting views the name and the definition's strings, region `a`.
      static tbc::val_a<PanelSetting> panelSetting(tbc::val_a<std::string_view> name, const lua::Value& definition, LimitNotices& limits);
      static tbc::val_a<PickSetting> pickSetting(tbc::val_a<std::string_view> name, const lua::Value& definition, LimitNotices& limits);
    };

  }
}

// Interface: telar_config/client_validation_state.cppm
export {
  namespace telar::runtime::config {

    template <CommandTabStore Commands>
    struct BasicClientValidationState {
      Commands commands;
      BindingKeymap keymap;
    };

    using ClientValidationState = BasicClientValidationState<CommandTabRegistry>;
    using RetainedClientValidationState = BasicClientValidationState<RetainedCommandTabRegistry>;

  }
}

// Interface: telar_config/prompt_reader.cppm
export {
  namespace telar::runtime::config {

    // The actions `client.prompt.bindings` may name, in the order of the GUI editor's Action.
    inline constexpr ds::Array<std::string_view, 27> prompt_action_names{
        "submit",
        "newline",
        "cancel",
        "complete",
        "accept_suggestion",
        "history_previous",
        "history_next",
        "history_search",
        "line_start",
        "line_end",
        "char_left",
        "char_right",
        "word_left",
        "word_right",
        "delete_char",
        "backspace",
        "kill_line",
        "kill_to_start",
        "kill_word",
        "kill_word_back",
        "yank",
        "undo",
        "redo",
        "transpose",
        "clear_screen",
        "normal_mode",
        "insert_mode",
    };

    enum class PromptMode : std::uint8_t {
      classic,
      telar,
    };

    enum class PromptSkin : std::uint8_t {
      halo,
      glass,
      ink,
    };

    enum class PromptMotion : std::uint8_t {
      spring,
      ease,
      none,
    };

    enum class PromptKeymap : std::uint8_t {
      emacs,
      vim,
    };

    inline constexpr ds::Array<std::string_view, 2> prompt_mode_names{"classic", "telar"};
    inline constexpr ds::Array<std::string_view, 3> prompt_skin_names{"halo", "glass", "ink"};
    inline constexpr ds::Array<std::string_view, 3> prompt_motion_names{"spring", "ease", "none"};
    inline constexpr ds::Array<std::string_view, 2> prompt_keymap_names{"emacs", "vim"};
    inline constexpr ds::Array<std::string_view, 2> prompt_binding_mode_names{"insert", "normal"};

    struct PromptBounds {
      static constexpr Bounds<std::uint64_t> max_lines{.minimum = 1, .maximum = 64};
      static constexpr std::size_t bindings = 256;
    };

    // A key `client.prompt.bindings` binds to one of prompt_action_names; `normal` binds it in
    // vim's normal mode instead of typing.
    struct PromptBindingSetting {
      KeyChord chord;
      std::uint8_t action = 0;
      bool normal = false;
    };

    // The `client.prompt` table as read: each field the configuration sets, within its bounds.
    struct PromptSettings {
      ds::Option<PromptMode> mode;
      ds::Option<PromptSkin> skin;
      ds::Option<PromptMotion> motion;
      ds::Option<PromptKeymap> keymap;
      ds::Option<bool> ghost;
      ds::Option<std::uint8_t> max_lines;
      // Whether it lists bindings, which replace the defaults even when empty.
      bool bindings = false;
    };

    class PromptReader {
    public:
      // Hands each binding to `binding` in order. Stays in the interface because it is a template
      // over the caller's callable.
      template <typename Binding>
      [[nodiscard]] TBC_GENERIC static tbc::val_a<PromptSettings> read(const lua::Value& table, const Binding& binding) {
        PromptSettings settings;

        if (!table.present()) {
          return settings;
        }

        const auto bindings = begin(table, settings);
        const auto count = countBindings(bindings, settings);

        for (std::size_t index = 0; index < count; ++index) {
          binding(readBinding(bindings.element(static_cast<lua_Integer>(index) + 1)));
        }

        finish(table, settings);
        return settings;
      }

    private:
      // Checks the table's fields and reads its mode; returns its bindings.
      static tbc::val_a<lua::Value> begin(const lua::Value& table, PromptSettings& settings);
      static std::size_t countBindings(const lua::Value& bindings, PromptSettings& settings);
      static PromptBindingSetting readBinding(const lua::Value& entry);
      static void finish(const lua::Value& table, PromptSettings& settings);
    };

  }
}

// Interface: telar_config/client_validator.cppm
export {
  namespace telar::runtime::config {

    // Interface pieces a configuration may draw with Lua, under `client.components`.
    inline constexpr ds::Array<std::string_view, 19> component_slots{
        "top_bar",
        "bottom_bar",
        "tab",
        "pane_header",
        "agent_card",
        "tab_cards",
        "tab_title",
        "tab_path",
        "tab_activity",
        "pane_mark",
        "pane_program",
        "pane_context",
        "pane_status",
        "pane_progress",
        "pane_actions",
        "agent_mark",
        "agent_title",
        "agent_project",
        "agent_status",
    };

    // `client.prefix` and `client.input`.
    struct ClientInputSettings {
      static constexpr Bounds<std::uint64_t> sequence_timeout_bounds{.minimum = 10, .maximum = 10'000};
      ds::Option<KeyChord> prefix;
      ds::Option<std::uint16_t> sequence_timeout_ms;
    };

    // The settings of a `client` table, each one as the configuration sets it.
    struct ClientSettings {
      enum class Delivery : std::uint8_t {
        telar,
        system,
        terminal,
      };

      enum class HistoryEnter : std::uint8_t {
        paste,
        run,
      };

      enum class HistoryMatch : std::uint8_t {
        fuzzy,
        fts,
      };

      struct History {
        ds::Option<bool> show_agent_commands;
        ds::Option<HistoryEnter> enter;
        ds::Option<HistoryMatch> match;
      };

      struct Sound {
        ds::Option<bool> enabled;
        ds::Option<bool> ready;
        ds::Option<bool> needs_input;
      };

      ds::Option<bool> sidebar_visible;
      ds::Option<bool> pane_gaps;
      // Views of the configuration's strings, alive while its table is.
      ds::Option<std::string_view> editor;
      ds::Option<std::string_view> window_title;
      History history;
      Sound sound;
      ds::Option<Delivery> delivery;
      ClientInputSettings input;
      PromptSettings prompt;
    };

    class ClientReader {
    public:
      static constexpr std::size_t maximum_editor_bytes = 4096;
      static constexpr std::size_t maximum_window_title_bytes = 128;

      // Hands each `client.prompt` binding to `binding` in order. Stays in the interface, as do
      // the other templates of this class, because it is a template over the caller's callable; the
      // rest of the table is read out of line.
      template <typename Binding>
      [[nodiscard]] TBC_GENERIC static tbc::val_a<ClientSettings> read(const lua::Value& client, Binding&& binding) {
        auto settings = readSettings(client);

        if (client.present()) {
          settings.prompt = PromptReader::read(client.field("prompt"), std::forward<Binding>(binding));
        }

        return settings;
      }

      // Hands each `client.keybindings` entry to `visit` with its action, `prefix` in front of the
      // prefixed ones, and returns how many it lists, if it lists them.
      template <typename Visit>
      [[nodiscard]] TBC_GENERIC static ds::Option<std::size_t> bindings(const lua::Value& client, KeyChord prefix, Visit&& visit) {
        if (!listsBindings(client)) {
          return ds::none;
        }

        return BindingReader::read(client.field("keybindings"), prefix, std::forward<Visit>(visit));
      }

      // Hands each `client.components` function to `visit` with its index in component_slots.
      template <typename Visit>
      TBC_GENERIC static void slots(const lua::Value& client, const Visit& visit) {
        const auto components = client.field("components");
        if (!components.present()) {
          return;
        }

        components.eachField([&](std::string_view name, const lua::Value& entry) {
          visit(slot(name, entry), entry);
        });
      }

      // Whether the table lists keybindings, before `bindings` reads them.
      [[nodiscard]] static bool listsBindings(const lua::Value& client);
      [[nodiscard]] static ClientInputSettings input(const lua::Value& client);

    private:
      // The settings of the table but its prompt.
      static tbc::val_a<ClientSettings> readSettings(const lua::Value& client);
      // The index of the slot `name` names in component_slots.
      static std::size_t slot(std::string_view name, const lua::Value& entry);
      static tbc::val_a<ds::Option<std::string_view>> printableText(const lua::Value& value, std::size_t maximum, bool allow_empty);
      static void sidebar(const lua::Value& table, ClientSettings& settings);
      static void sound(const lua::Value& table, ClientSettings::Sound& sound);
      static void notifications(const lua::Value& table, ClientSettings& settings);
      static void history(const lua::Value& table, ClientSettings::History& history);
    };

    class ClientValidator {
    public:
      template <CommandTabStore Commands>
      static void validate(const lua::Value& client, LimitNotices& limits, BasicClientValidationState<Commands>& state, const lua::Value* inherited = nullptr);
    };

  }
}

// The templates over a command tab store are built in client.cpp for both registries.
namespace telar::runtime::config {

  extern template class CommandTabStorage<CommandTabLifetime::configuration>;
  extern template class CommandTabStorage<CommandTabLifetime::retained>;
  extern template class BasicActionValidator<CommandTabRegistry>;
  extern template class BasicActionValidator<RetainedCommandTabRegistry>;
  extern template void BindingValidator::validate<CommandTabRegistry>(const lua::Value& bindings, BasicActionValidator<CommandTabRegistry>& actions, BindingKeymap& keymap, LimitNotices& limits);
  extern template void BindingValidator::validate<RetainedCommandTabRegistry>(const lua::Value& bindings, BasicActionValidator<RetainedCommandTabRegistry>& actions, BindingKeymap& keymap, LimitNotices& limits);
  extern template void ClientValidator::validate<CommandTabRegistry>(const lua::Value& client, LimitNotices& limits, BasicClientValidationState<CommandTabRegistry>& state, const lua::Value* inherited);
  extern template void ClientValidator::validate<RetainedCommandTabRegistry>(const lua::Value& client, LimitNotices& limits, BasicClientValidationState<RetainedCommandTabRegistry>& state, const lua::Value* inherited);

}
