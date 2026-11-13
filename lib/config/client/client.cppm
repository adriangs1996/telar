module;
#include "tbc/view.hpp"
#include <cstdint>
#include <lua.h>

export module telar.config.client;

import std;
export import telar.config.core;
import telar.base.diagnostics;
import telar.wire.clients;
import telar.wire.vocabulary;

// Interface: telar_config/named_definitions_validator.cppm
namespace telar::runtime::config {

  class NamedDefinitionsValidator {
  public:
    template <typename Validator>
    inline static void validate(const lua::Value& table, tbc::view<LimitReach, tbc::lt::b> reach, tbc::view<LimitNotices&, tbc::lt::b> limits, Validator&& validate_definition) {
      if (!table.present()) {
        return;
      }

      std::array<std::string_view, maximum_definitions> names;
      std::size_t kept = 0;
      std::size_t total = 0;

      table.eachField([&](std::string_view name, const lua::Value&) {
        ++total;
        const auto end = names.begin() + kept;
        const auto insertion = std::lower_bound(names.begin(), end, name);
        if (kept == names.size() && insertion == end) {
          return;
        }

        const auto last = kept < names.size() ? end : end - 1;

        std::move_backward(insertion, last, last + 1);
        *insertion = name;
        kept = std::min(kept + 1, names.size());
      });

      if (total > kept) {
        reach.requested = total;
        limits.add(reach);
      }

      for (const auto name : std::span{names}.first(kept)) {
        const auto definition = table.entry(name);

        validate_definition(name, definition);
      }
    }

    inline static void heading(std::string_view name, const lua::Value& definition, LimitNotices& limits) {
      if (name.empty() || name.size() > maximum_name_bytes || !std::ranges::all_of(name, [](unsigned char byte) {
            return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
          })) {
        definition.fail("has an invalid name");
      }

      const auto title = definition.field("title");
      const auto text = title.present() ? title.string() : name;

      printableUiText(title, fittedUiText(text, {"panels.title_bytes", "title bytes", maximum_title_bytes, {}, {}}, limits));
    }

    static constexpr std::size_t maximum_definitions = 16;

  private:
    static constexpr std::size_t maximum_name_bytes = 32;
    static constexpr std::size_t maximum_title_bytes = 128;
  };

}

// Interface: telar_config/client_definitions.cppm
export {
  namespace telar::runtime::config {

    class ClientDefinitions {
    public:
      inline explicit ClientDefinitions(const lua::Value& client, const lua::Value* inherited = nullptr)
          : client_(client),
            inherited_(inherited) {}

      inline bool contains(const char* section, std::string_view name) const {
        return index(section, name).has_value();
      }

      inline std::optional<std::uint8_t> index(const char* section, std::string_view name) const {
        if (client_.present()) {
          const auto definitions = client_.field(section);
          if (definitions.present()) {
            return indexOf(definitions, name);
          }
        }

        if (inherited_ != nullptr && inherited_->present()) {
          return indexOf(inherited_->field(section), name);
        }

        return std::nullopt;
      }

    private:
      inline static std::optional<std::uint8_t> indexOf(const lua::Value& definitions, std::string_view name) {
        if (!definitions.present()) {
          return std::nullopt;
        }

        bool found = false;
        std::size_t preceding = 0;

        definitions.eachField([&](std::string_view candidate, const lua::Value&) {
          found |= candidate == name;
          preceding += candidate < name;
        });

        if (!found) {
          return std::nullopt;
        }

        return preceding < NamedDefinitionsValidator::maximum_definitions ? static_cast<std::uint8_t>(preceding) : std::numeric_limits<std::uint8_t>::max();
      }

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

      std::array<std::string_view, maximum_arguments> arguments{};
      std::size_t count = 0;
      std::string_view configured_label;

      [[nodiscard]] inline std::span<const std::string_view> argv() const noexcept {
        return std::span{arguments}.first(count);
      }

      [[nodiscard]] inline std::string_view label() const noexcept {
        if (!configured_label.empty() || count == 0) {
          return configured_label;
        }

        auto executable = arguments.front();
        const auto last = executable.find_last_not_of('/');
        if (last == std::string_view::npos) {
          return {};
        }

        executable.remove_suffix(executable.size() - last - 1);
        const auto separator = executable.find_last_of('/');
        if (separator != std::string_view::npos) {
          executable.remove_prefix(separator + 1);
        }

        return executable;
      }
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

      inline bool keep(std::span<const std::string_view> arguments, std::string_view label, LimitNotices& limits) {
        return keepReference(arguments, label, limits).has_value();
      }

      inline std::optional<CommandTabReference> keepReference(std::span<const std::string_view> arguments, std::string_view label, LimitNotices& limits) {
        std::array<Byte, maximum_encoded_bytes> encoded{};
        const auto length = encode(arguments, label, encoded);
        const auto row = std::span{encoded}.first(length);

        for (std::size_t index = 0; index < rows_; ++index) {
          const auto stored = rowBytes(index);
          if (stored.size() == row.size() && std::ranges::equal(stored, row)) {
            return reference(index);
          }
        }

        if (!admit(row.size(), limits)) {
          return std::nullopt;
        }

        const auto index = rows_++;

        offsets_[index] = static_cast<std::uint32_t>(used_);
        std::ranges::copy(row, bytes_.begin() + used_);
        used_ += row.size();

        return reference(index);
      }

      [[nodiscard]] inline std::optional<CommandTabView> load(CommandTabReference reference) const {
        if (reference.id >= rows_ || reference != this->reference(reference.id)) {
          return std::nullopt;
        }

        const auto row = rowBytes(reference.id);
        CommandTabView result;

        result.count = row[0];
        const auto label_length = row[1];
        auto offset = header_bytes + (result.count * argument_length_bytes);

        for (std::size_t argument = 0; argument < result.count; ++argument) {
          const auto entry = header_bytes + (argument * argument_length_bytes);
          const auto length = static_cast<std::size_t>(row[entry]) | (static_cast<std::size_t>(row[entry + 1]) << upper_byte_shift);

          result.arguments[argument] = textView(row.subspan(offset, length));
          offset += length;
        }

        result.configured_label = textView(row.subspan(offset, label_length));

        return result;
      }

      inline void seal() noexcept
        requires(Lifetime == CommandTabLifetime::retained)
      {
        sealed_ = true;
        fixed_rows_ = rows_;
        fixed_bytes_ = used_;
      }

      inline void beginRender() noexcept
        requires(Lifetime == CommandTabLifetime::retained)
      {
        if (!sealed_) {
          return;
        }

        const bool crowded = maximum_bytes - used_ < recent_bytes / 2 || maximum_rows - rows_ < recent_rows / 2;
        if (refused_ || crowded) {
          clearRecent();
        }

        refused_ = false;
        rendering_ = true;
      }

      inline void endRender() noexcept
        requires(Lifetime == CommandTabLifetime::retained)
      {
        rendering_ = false;
      }

      [[nodiscard]] inline Checkpoint checkpoint() const noexcept {
        return {.rows = rows_, .bytes = used_};
      }

      inline void restore(Checkpoint saved) noexcept {
        rows_ = saved.rows;
        used_ = saved.bytes;
      }

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

      inline static std::size_t encode(std::span<const std::string_view> arguments, std::string_view label, std::span<Byte> encoded) {
        if (arguments.empty() || arguments.size() > CommandTabView::maximum_arguments || label.size() > CommandTabView::maximum_label_bytes) {
          throw EncodingError{"Invalid command tab bounds"};
        }

        std::size_t argument_bytes = 0;

        for (const auto argument : arguments) {
          if (argument.empty() || argument.size() > CommandTabView::maximum_argument_bytes - argument_bytes || argument.contains('\0')) {
            throw EncodingError{"Invalid command tab argument"};
          }

          argument_bytes += argument.size();
        }

        std::size_t length = 0;

        encoded[length++] = static_cast<Byte>(arguments.size());
        encoded[length++] = static_cast<Byte>(label.size());
        for (const auto argument : arguments) {
          encoded[length++] = static_cast<Byte>(argument.size());
          encoded[length++] = static_cast<Byte>(argument.size() >> upper_byte_shift);
        }

        for (const auto argument : arguments) {
          std::memcpy(encoded.data() + length, argument.data(), argument.size());
          length += argument.size();
        }

        if (!label.empty()) {
          std::memcpy(encoded.data() + length, label.data(), label.size());
        }

        return length + label.size();
      }

      inline bool admit(std::size_t length, LimitNotices& limits) noexcept {
        if (Lifetime == CommandTabLifetime::configuration || !sealed_) {
          if (rows_ >= fixed_row_limit) {
            limits.add({.name = "config.command_tab_rows", .noun = "command tabs", .value = fixed_row_limit});

            return false;
          }

          if (used_ + length > fixed_byte_limit) {
            limits.add({.name = "config.command_tab_bytes", .noun = "command tab bytes", .value = fixed_byte_limit});

            return false;
          }
        } else if (used_ + length > maximum_bytes || rows_ == maximum_rows) {
          if (rendering_) {
            refused_ = true;
            limits.add({.name = "config.recent_command_tab_bytes", .noun = "command tab bytes", .value = recent_bytes});

            return false;
          }

          clearRecent();
        }

        return true;
      }

      [[nodiscard]] inline CommandTabReference reference(std::size_t index) const noexcept {
        return {.epoch = Lifetime == CommandTabLifetime::retained && sealed_ && index >= fixed_rows_ ? epoch_ : 0, .id = static_cast<std::uint16_t>(index)};
      }

      [[nodiscard]] inline std::span<const Byte> rowBytes(std::size_t index) const noexcept {
        const auto start = offsets_[index];
        const auto end = index + 1 == rows_ ? used_ : offsets_[index + 1];

        return std::span{bytes_}.subspan(start, end - start);
      }

      inline void clearRecent() noexcept {
        rows_ = fixed_rows_;
        used_ = fixed_bytes_;
        if (++epoch_ == 0) {
          ++epoch_;
        }
      }

      std::array<Byte, maximum_bytes> bytes_{};
      std::array<std::uint32_t, maximum_rows> offsets_{};
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

// Interface: telar_config/action_validator.cppm
export {
  namespace telar::runtime::config {

    template <CommandTabStore Commands>
    class BasicActionValidator {
    public:
      inline explicit BasicActionValidator(tbc::view<const ClientDefinitions&, tbc::lt::b> definitions, tbc::view<LimitNotices&, tbc::lt::b> limits, tbc::view<Commands&, tbc::lt::b> commands)
          : definitions_(definitions),
            limits_(limits),
            commands_(commands) {}

      inline bool validate(const lua::Value& action, bool expression = false) const {
        if (action.is(LUA_TFUNCTION)) {
          return true;
        }

        if (expression) {
          action.fail("requires a function for an expression binding");
        }

        if (action.is(LUA_TSTRING)) {
          builtin(action);
          return true;
        }

        const auto kind_value = action.field("kind");
        const auto kind = kind_value.string();
        if (kind == "scroll-pane") {
          direction(action, {"up", "down"});
        } else if (kind == "split-pane") {
          direction(action, {"horizontal", "vertical"});
        } else if (kind == "focus-pane" || kind == "navigate-pane" || kind == "resize-pane") {
          direction(action, {"left", "right", "up", "down"});
        } else if (kind == "resize-sidebar") {
          direction(action, {"left", "right"});
        } else if (kind == "move-tab") {
          direction(action, {"previous", "next"});
        } else if (kind == "select-tab" || kind == "select-workspace") {
          action.onlyFields({"kind", "index"});
          requiredInteger(action.field("index"), 1, 256);
        } else if (kind == "select-tab-offset") {
          action.onlyFields({"kind", "offset"});
          requiredInteger(action.field("offset"), INT8_MIN, INT8_MAX);
        } else if (kind == "command-tab") {
          return commandTab(action);
        } else if (kind == "notification") {
          notification(action);
        } else if (kind == "open-panel") {
          reference(action, "panel", "panels");
        } else if (kind == "pick") {
          reference(action, "pick", "picks");
        } else if (kind == "plugin") {
          action.onlyFields({"kind", "plugin", "action"});
          action.field("plugin").string();
          action.field("action").string();
        } else {
          builtin(kind_value);
          action.onlyFields({"kind"});
        }

        return true;
      }

      inline bool component(const lua::Value& action) const {
        if (action.is(LUA_TFUNCTION)) {
          action.fail("cannot be a callback in a static component");
        }

        return validate(action);
      }

    private:
      inline static void builtin(const lua::Value& value) {
        constexpr std::string_view names[]{"next-machine", "previous-machine", "machine-picker", "add-machine", "scroll-pane-up", "scroll-pane-down", "split-horizontal", "split-vertical", "focus-left", "focus-right", "focus-up", "focus-down", "navigate-left", "navigate-right", "navigate-up", "navigate-down", "resize-left", "resize-right", "resize-up", "resize-down", "toggle-pane-fullscreen", "toggle-sidebar", "resize-sidebar-left", "resize-sidebar-right", "toggle-workspace-list", "leave-worktree", "forget-gone-worktrees", "new-workspace", "rename-workspace", "close-pane", "new-tab", "next-tab", "previous-tab", "rename-tab", "close-tab", "move-tab-previous", "move-tab-next", "detach", "copy-mode", "goto-picker", "history-palette", "path-picker", "suggest-command", "close-panel", "refresh-panel"};
        const auto name = value.string();
        if (std::ranges::find(names, name) != std::end(names)) {
          return;
        }

        for (const std::string_view prefix : {"select-tab-", "select-workspace-"}) {
          if (name.starts_with(prefix)) {
            const auto number = name.substr(prefix.size());
            if (validIndex(number)) {
              return;
            }
          }
        }

        value.fail("names an unknown action");
      }

      inline static bool validIndex(std::string_view number) noexcept {
        return unsignedNumber<unsigned>(number, UINT8_MAX).value_or(0) != 0;
      }

      inline static void requiredInteger(const lua::Value& value, lua_Integer minimum, lua_Integer maximum) {
        const auto integer = value.integer();
        if (integer < minimum || integer > maximum) {
          value.fail("is outside its bounds");
        }
      }

      inline static void direction(const lua::Value& action, std::initializer_list<std::string_view> choices) {
        action.onlyFields({"kind", "direction"});
        const auto direction = action.field("direction");

        direction.string();
        optionalChoice(direction, choices);
      }

      inline void reference(const lua::Value& action, const char* field, const char* section) const {
        action.onlyFields({"kind", field});
        const auto value = action.field(field);
        if (!definitions_.contains(section, value.string())) {
          value.fail("names an unknown client definition");
        }
      }

      inline bool commandTab(const lua::Value& action) const {
        action.onlyFields({"kind", "command", "label"});
        const auto command = action.field("command");
        const auto count = command.listLength();
        constexpr std::size_t maximum_arguments = 32;
        constexpr std::size_t maximum_bytes = 4096;

        if (count == 0) {
          command.fail("requires a command");
        }

        if (count > maximum_arguments) {
          limits_.add({"command_tab.max_arguments", "arguments", maximum_arguments, count, {}});
          return false;
        }

        command.arraySize();
        std::array<std::string_view, maximum_arguments> arguments;
        std::size_t total_bytes = 0;

        for (std::size_t index = 0; index < count; ++index) {
          const auto argument = command.element(index + 1);

          arguments[index] = argument.string();
          if (arguments[index].empty()) {
            argument.fail("must be nonempty");
          }

          total_bytes += arguments[index].size();
        }

        const auto label = action.field("label");
        if (label.is(LUA_TSTRING) && label.string().size() > 32) {
          label.fail("exceeds the label limit");
        }

        std::size_t kept_bytes = 0;

        for (const auto argument : std::span{arguments}.first(count)) {
          if (argument.contains('\0')) {
            command.fail("contains NUL");
          }

          kept_bytes += argument.size();
          if (kept_bytes > maximum_bytes) {
            limits_.add({"command_tab.max_command_bytes", "argv bytes", maximum_bytes, total_bytes, {}});
            return false;
          }
        }

        return commands_.keep(std::span{arguments}.first(count), label.is(LUA_TSTRING) ? label.string() : std::string_view{}, limits_);
      }

      inline void notification(const lua::Value& action) const {
        action.onlyFields({"kind", "title", "body", "level", "duration_ms", "pane_id", "tab_id", "workspace_id"});
        optionalChoice(action.field("level"), {"info", "success", "warning", "failure"});
        NotificationBody body{.duration_ms = static_cast<std::uint32_t>(action.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms))};
        const auto title = action.field("title");
        const auto message = action.field("body");

        body.title = fitted(title.string(), {"notifications.max_title_bytes", "bytes", max_notification_title_bytes, {}, {}});
        body.message = message.present() ? fitted(message.string(), {"notifications.max_message_bytes", "bytes", max_notification_message_bytes, {}, {}}) : std::string_view{};
        unsigned target_count = 0;

        for (const auto* name : {"pane_id", "tab_id", "workspace_id"}) {
          const auto target = action.field(name);
          if (target.present()) {
            requiredInteger(target, 1, INT64_MAX);
            ++target_count;
          }
        }

        if (target_count > 1) {
          action.fail("accepts only one notification target");
        }

        std::array<Byte, 1024> storage;

        Codec::encode(ShowNotification{.request_id = 1, .notification = body}, storage);
      }

      inline tbc::view<std::string_view, tbc::lt::a> fitted(tbc::view<std::string_view, tbc::lt::a> text, tbc::view<LimitReach, tbc::lt::b> limit) const {
        if (text.size() > limit.value) {
          limit.requested = text.size();
          limits_.add(limit);
        }

        return utf8Prefix(text, limit.value);
      }

      tbc::view<const ClientDefinitions&, tbc::lt::b> definitions_;
      tbc::view<LimitNotices&, tbc::lt::b> limits_;
      tbc::view<Commands&, tbc::lt::b> commands_;
    };

    using RetainedActionValidator = BasicActionValidator<RetainedCommandTabRegistry>;

  }
}

// Interface: telar_config/component_shape.cppm
export {
  namespace telar::runtime::config {

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

    struct ComponentShape {
      ComponentKind kind = ComponentKind::label;
      std::string_view text{};
      std::string_view detail{};
      std::string_view url{};
      const char* action_field = nullptr;
      std::size_t samples = 0;
      unsigned priority = 50;
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

        inline Usage operator+(Usage other) const noexcept {
          return {nodes + other.nodes, text + other.text, actions + other.actions, samples + other.samples};
        }

        inline Usage operator-(Usage other) const noexcept {
          return {nodes - other.nodes, text - other.text, actions - other.actions, samples - other.samples};
        }

        inline bool fits(Usage room) const noexcept {
          return nodes <= room.nodes && text <= room.text && actions <= room.actions && samples <= room.samples;
        }
      };

      inline void count(const ComponentShape& shape, unsigned rank) noexcept {
        const auto needed = usage(shape);

        offered_ = offered_ + needed;
        ranked_[rank] = ranked_[rank] + needed;
      }

      inline void prepare() noexcept {
        Usage above;

        for (unsigned rank = rank_count; rank-- > 0;) {
          const auto next = above + ranked_[rank];
          if (!next.fits(staging_capacity)) {
            cutoff_ = rank;
            room_ = staging_capacity - above;
            return;
          }

          above = next;
        }

        room_ = staging_capacity;
      }

      inline bool admit(const ComponentShape& shape, unsigned rank) noexcept {
        if (rank < cutoff_) {
          return false;
        }

        if (rank > cutoff_) {
          return true;
        }

        const auto next = taken_ + usage(shape);
        if (!next.fits(room_)) {
          return false;
        }

        taken_ = next;
        return true;
      }

      inline void release(const ComponentShape& shape, unsigned rank) noexcept {
        if (rank == cutoff_) {
          taken_ = taken_ - usage(shape);
        }
      }

      inline bool stage(const ComponentShape& shape) noexcept {
        const auto next = staged_ + usage(shape);
        if (!next.fits(staging_capacity)) {
          return false;
        }

        staged_ = next;
        return true;
      }

      inline bool nodesFull() const noexcept {
        return staged_.nodes == staging_capacity.nodes;
      }

      inline void report(LimitNotices& limits) const noexcept {
        const std::array<LimitReach, 4> reaches{{
            {"bars.max_bar_nodes", "components", 64, offered_.nodes, {}},
            {"bars.max_bar_text_bytes", "text bytes", 4096, offered_.text, {}},
            {"bars.max_bar_actions", "click actions", 32, offered_.actions, {}},
            {"bars.max_samples", "sparkline samples", 256, offered_.samples, {}},
        }};

        for (const auto& reach : reaches) {
          if (reach.requested > reach.value) {
            limits.add(reach);
          }
        }
      }

    private:
      inline static Usage usage(const ComponentShape& shape) noexcept {
        return {1, shape.text.size() + shape.detail.size() + shape.url.size(), shape.action_field != nullptr ? 1u : 0u, shape.samples};
      }

      static constexpr unsigned rank_count = 256;
      static constexpr Usage staging_capacity{254, 32 * 1024, 64, 2048};
      std::array<Usage, rank_count> ranked_{};
      Usage offered_;
      Usage taken_;
      Usage staged_;
      Usage room_;
      unsigned cutoff_ = 0;
    };

  }
}

// Interface: telar_config/component_style_validator.cppm
namespace telar::runtime::config {

  class ComponentStyleValidator {
  public:
    inline static void validate(const lua::Value& component) {
      for (const auto* name : {"fg", "bg"}) {
        const auto value = component.field(name);
        if (value.present()) {
          color(value);
        }
      }

      for (const auto* name : {"bold", "italic", "faint", "underline", "strikethrough"}) {
        component.field(name).boolean(false);
      }
    }

  private:
    inline static void color(const lua::Value& value) {
      if (const auto index = value.asInteger()) {
        if (*index < 0 || *index > 255) {
          value.fail("is outside the color index range");
        }

        return;
      }

      constexpr std::string_view names[]{"default", "accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"};
      const auto text = value.string();
      if (std::ranges::any_of(names, [text](std::string_view name) {
            return equalUiName(text, name);
          })) {
        return;
      }

      if (text.size() == 7 && text.front() == '#' && hexadecimal(text.substr(1))) {
        return;
      }

      value.fail("is not a supported color");
    }

    inline static bool hexadecimal(std::string_view digits) noexcept {
      const bool negative = digits.front() == '-';
      if (negative || digits.front() == '+') {
        digits.remove_prefix(1);
      }

      // At most six digits follow '#', so the value never reaches the limit.
      const auto value = unsignedNumber<unsigned>(digits, std::numeric_limits<unsigned>::max(), 16);

      return value && (!negative || *value == 0);
    }
  };

}

// Interface: telar_config/component_shape_reader.cppm
export {
  namespace telar::runtime::config {

    class ComponentShapeReader {
    public:
      // A shape views the value's strings, which belong to the state in the value's region `a`.
      inline static tbc::view<ComponentShape, tbc::lt::a> read(const lua::Value& value, unsigned inherited_priority, LimitNotices& limits) {
        ComponentShape shape;

        shape.kind = kind(value.field("ui"));
        fields(value, shape.kind);
        shape.priority = static_cast<unsigned>(std::round(value.field("priority").boundedNumber(inherited_priority, 0, 100)));
        const auto tone = value.field("tone");

        optionalChoice(tone, {"neutral", "muted", "accent", "success", "warning", "danger"});
        if (tone.present()) {
          shape.tone_bonus = tone.string() == "danger" ? 40 : tone.string() == "warning" ? 20
                                                                                         : 0;
        }

        switch (shape.kind) {
        case ComponentKind::label:
          shape.text = text(value, "text");
          ComponentStyleValidator::validate(value);
          break;
        case ComponentKind::icon:
          optionalIcon(value.field("name"));
          shape.text = text(value, "glyph");
          if (shape.text.size() > maximum_glyph_bytes || (shape.text.empty() && !value.field("name").present())) {
            value.fail("requires an icon name or a glyph of at most 16 bytes");
          }

          break;
        case ComponentKind::mark:
          uiMark(value.field("name"));
          break;
        case ComponentKind::meter:
        case ComponentKind::meter_row:
          finiteNumber(value.field("value"));
          finiteNumber(value.field("marker"));
          shape.text = text(value, "label");
          shape.detail = text(value, shape.kind == ComponentKind::meter ? "text" : "detail");
          break;
        case ComponentKind::sparkline:
          shape.samples = samples(value, limits);
          break;
        case ComponentKind::badge:
        case ComponentKind::heading:
        case ComponentKind::text:
          shape.text = text(value, "text");
          break;
        case ComponentKind::clock:
          shape.text = text(value, "format", "%H:%M");
          if (shape.text.size() > maximum_clock_bytes) {
            value.fail("exceeds the clock format limit");
          }

          break;
        case ComponentKind::metric:
          value.field("name").string();
          optionalChoice(value.field("name"), {"cpu", "memory", "battery"});
          break;
        case ComponentKind::group:
          optionalIcon(value.field("icon"));
          if (const auto mark = value.field("mark"); mark.present()) {
            uiMark(mark);
          }

          shape.action_field = value.field("on_click").present() ? "on_click" : nullptr;
          shape.url = text(value, "url");
          // A summary group shows one indicator for its metrics and meters, named by this text.
          shape.text = text(value, "summary");
          break;
        case ComponentKind::key_value:
          shape.text = text(value, "key");
          shape.detail = text(value, "value");
          break;
        case ComponentKind::callout:
          optionalIcon(value.field("icon"));
          shape.text = text(value, "text");
          shape.detail = text(value, "detail");
          break;
        case ComponentKind::button:
          shape.text = text(value, "text");
          shape.action_field = value.field("action").present() ? "action" : nullptr;
          shape.url = text(value, "url");
          value.field("primary").boolean(false);
          if (shape.action_field == nullptr && shape.url.empty()) {
            value.fail("requires an action or URL");
          }

          break;
        case ComponentKind::machines:
        case ComponentKind::actions:
        case ComponentKind::divider:
          break;
        }

        return shape;
      }

      inline static ComponentShape segment(const lua::Value& value, unsigned priority) {
        value.onlyFields({"text", "icon", "fg", "bg", "bold", "italic", "faint", "underline", "strikethrough"});
        ComponentShape shape;

        shape.text = text(value, "text");
        shape.kind = shape.text.empty() ? ComponentKind::icon : ComponentKind::label;
        shape.priority = priority;
        optionalIcon(value.field("icon"));
        ComponentStyleValidator::validate(value);
        return shape;
      }

    private:
      inline static ComponentKind kind(const lua::Value& value) {
        constexpr std::string_view names[]{"label", "icon", "mark", "meter", "sparkline", "badge", "clock", "metric", "machines", "group", "heading", "text", "meter_row", "kv", "callout", "actions", "button", "divider"};
        const auto found = std::ranges::find(names, value.string());
        if (found == std::end(names)) {
          value.fail("names an unknown component");
        }

        return static_cast<ComponentKind>(found - std::begin(names));
      }

      inline static void fields(const lua::Value& value, ComponentKind kind) {
        switch (kind) {
        case ComponentKind::label:
          value.onlyFields({"ui", "text", "tone", "priority", "fg", "bg", "bold", "italic", "faint", "underline", "strikethrough"});
          break;
        case ComponentKind::icon:
          value.onlyFields({"ui", "name", "glyph", "tone", "priority"});
          break;
        case ComponentKind::mark:
        case ComponentKind::metric:
          value.onlyFields({"ui", "name", "priority"});
          break;
        case ComponentKind::meter:
          value.onlyFields({"ui", "value", "label", "text", "marker", "tone", "priority"});
          break;
        case ComponentKind::meter_row:
          value.onlyFields({"ui", "value", "label", "detail", "marker", "tone", "priority"});
          break;
        case ComponentKind::sparkline:
          value.onlyFields({"ui", "values", "max", "tone", "priority"});
          break;
        case ComponentKind::badge:
        case ComponentKind::heading:
        case ComponentKind::text:
          value.onlyFields({"ui", "text", "tone", "priority"});
          break;
        case ComponentKind::clock:
          value.onlyFields({"ui", "format", "tone", "priority"});
          break;
        case ComponentKind::machines:
        case ComponentKind::divider:
          value.onlyFields({"ui", "priority"});
          break;
        case ComponentKind::group:
          value.onlyFields({"ui", "mark", "icon", "tooltip", "on_click", "url", "priority", "tone", "summary"}, true);
          break;
        case ComponentKind::key_value:
          value.onlyFields({"ui", "key", "value", "tone", "priority"});
          break;
        case ComponentKind::callout:
          value.onlyFields({"ui", "icon", "text", "detail", "button", "tone", "priority"});
          break;
        case ComponentKind::button:
          value.onlyFields({"ui", "text", "action", "url", "primary", "tone", "priority"});
          break;
        case ComponentKind::actions:
          value.onlyFields({"ui", "priority"}, true);
          break;
        }
      }

      inline static tbc::view<std::string_view, tbc::lt::a> text(const lua::Value& value, const char* name, tbc::view<std::string_view, tbc::lt::a> fallback = {}) {
        const auto field = value.field(name);

        return field.present() ? field.string() : fallback;
      }

      inline static void optionalIcon(const lua::Value& value) {
        if (value.present()) {
          uiIcon(value);
        }
      }

      inline static void finiteNumber(const lua::Value& value) {
        value.boundedNumber(0, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());
      }

      inline static std::size_t samples(const lua::Value& value, LimitNotices& limits) {
        finiteNumber(value.field("max"));
        const auto values = value.field("values");
        const auto total = values.listLength();
        const auto kept = std::min(total, maximum_samples);
        if (total > kept) {
          limits.add({"bars.max_node_samples", "sparkline values", maximum_samples, total, {}});
        }

        for (std::size_t index = total - kept + 1; index <= total; ++index) {
          const auto sample = values.element(index);
          if (!sample.present()) {
            sample.fail("must be a number");
          }

          sample.boundedNumber(0, 0, std::numeric_limits<double>::max());
        }

        return kept;
      }

      static constexpr std::size_t maximum_glyph_bytes = 16;
      static constexpr std::size_t maximum_clock_bytes = 32;
      static constexpr std::size_t maximum_samples = 120;
    };

  }
}

// Interface: telar_config/component_validator.cppm
namespace telar::runtime::config {

  template <CommandTabStore Commands>
  class ComponentValidator {
  public:
    inline explicit ComponentValidator(const BasicActionValidator<Commands>& actions, LimitNotices& limits)
        : actions_(actions),
          limits_(limits) {}

    inline void validate(const lua::Value& value) {
      // Rank the whole result before validating actions: components excluded
      // from staging must not retain commands or reject the configuration.
      walk(value, {});
      budget_.prepare();
      counting_ = false;
      walk(value, {});
      budget_.report(limits_);
    }

  private:
    enum class Place {
      bar,
      group,
      tooltip,
      buttons,
    };

    struct Position {
      Place place = Place::bar;
      unsigned priority = 50;
      unsigned rank = UINT8_MAX;
      unsigned depth = 0;
    };

    inline void walk(const lua::Value& value, Position position) {
      if (!value.present()) {
        return;
      }

      if (value.is(LUA_TSTRING)) {
        append(value, {.text = value.string(), .priority = position.priority}, position);
        return;
      }

      if (value.field("ui").present()) {
        component(value, position);
        return;
      }

      if (value.field("text").present() || value.field("icon").present()) {
        append(value, ComponentShapeReader::segment(value, position.priority), position);
        return;
      }

      if (position.depth == maximum_list_depth) {
        value.fail("exceeds the component nesting limit");
      }

      ++position.depth;
      const auto count = value.arraySize();

      for (std::size_t index = 1; index <= count; ++index) {
        walk(value.element(index), position);
      }
    }

    inline void component(const lua::Value& value, Position position) {
      const auto shape = ComponentShapeReader::read(value, position.priority, limits_);
      if (!append(value, shape, position)) {
        return;
      }

      const auto rank = std::min(shape.priority + shape.tone_bonus, position.rank);

      if (shape.kind == ComponentKind::group) {
        children(value, {Place::group, shape.priority, rank});
        walk(value.field("tooltip"), {Place::tooltip, default_priority, rank});
      } else if (shape.kind == ComponentKind::callout) {
        walk(value.field("button"), {Place::buttons, default_priority, rank});
      } else if (shape.kind == ComponentKind::actions) {
        children(value, {Place::buttons, default_priority, rank});
      }
    }

    inline void children(const lua::Value& value, Position position) {
      const auto count = value.listLength();

      for (std::size_t index = 1; index <= count; ++index) {
        walk(value.element(index), position);
      }
    }

    inline bool append(const lua::Value& value, const ComponentShape& shape, Position position) {
      if (!allowed(shape.kind, position.place)) {
        value.fail("contains a component unsupported in this position");
      }

      const auto rank = std::min(shape.priority + shape.tone_bonus, position.rank);

      if (counting_) {
        budget_.count(shape, rank);
        return true;
      }

      if (!budget_.admit(shape, rank)) {
        return false;
      }

      if (shape.action_field != nullptr && !actions_.component(value.field(shape.action_field))) {
        budget_.release(shape, rank);
        return false;
      }

      if (budget_.nodesFull()) {
        return false;
      }

      validateUrl(value, shape.url);
      if (!budget_.stage(shape)) {
        return false;
      }

      printableUiText(value, shape.text);
      printableUiText(value, shape.detail);
      return true;
    }

    inline static bool allowed(ComponentKind kind, Place place) noexcept {
      switch (place) {
      case Place::bar:
        return kind <= ComponentKind::group;
      case Place::group:
        return kind < ComponentKind::group;
      case Place::tooltip:
        return kind != ComponentKind::group && kind != ComponentKind::callout && kind != ComponentKind::actions && kind != ComponentKind::button;
      case Place::buttons:
        return kind == ComponentKind::button;
      }

      return false;
    }

    inline static void validateUrl(const lua::Value& value, std::string_view url) {
      if (url.empty()) {
        return;
      }

      if (url.size() > maximum_url_bytes || url.contains(' ') || (!url.starts_with("https://") && !url.starts_with("http://"))) {
        value.fail("requires an HTTP or HTTPS URL without spaces");
      }

      printableUiText(value, url);
    }

    static constexpr unsigned maximum_list_depth = 4;
    static constexpr unsigned default_priority = 50;
    static constexpr std::size_t maximum_url_bytes = 1024;
    const BasicActionValidator<Commands>& actions_;
    LimitNotices& limits_;
    ComponentBudget budget_;
    bool counting_ = true;
  };

}

// Interface: telar_config/command_arguments_validator.cppm
namespace telar::runtime::config {

  class CommandArgumentsValidator {
  public:
    inline static bool validate(const lua::Value& command) {
      const auto count = command.arraySize();
      if (count == 0 || count > maximum_arguments) {
        command.fail("must contain 1..32 arguments");
      }

      std::size_t bytes = 0;
      bool receives_choice = false;

      for (std::size_t index = 0; index < count; ++index) {
        const auto value = command.element(index + 1);
        const auto argument = value.string();

        bytes += argument.size();
        if ((index == 0 && argument.empty()) || argument.contains('\0') || bytes > maximum_bytes) {
          value.fail("is not a valid bounded command argument");
        }

        receives_choice |= index > 0 && argument == "{}";
      }

      return receives_choice;
    }

  private:
    static constexpr std::size_t maximum_arguments = 32;
    static constexpr std::size_t maximum_bytes = 4096;
  };

}

// Interface: telar_config/dynamic_source_validator.cppm
namespace telar::runtime::config {

  class DynamicSourceValidator {
  public:
    inline static void validate(const lua::Value& source) {
      const auto kind = source.field("bar_kind");
      const bool command = kind.string() == "command";
      if (command) {
        source.onlyFields({"bar_kind", "command", "every_ms", "timeout_ms", "render"});
        source.field("timeout_ms").boundedInteger(2000, 100, 10000);
        CommandArgumentsValidator::validate(source.field("command"));
      } else {
        if (kind.string() != "dynamic") {
          kind.fail("requires a render function or a command");
        }

        source.onlyFields({"bar_kind", "every_ms", "render"});
      }

      source.field("every_ms").boundedInteger(1000, 100, 3600000);
      const auto render = source.field("render");
      if ((!command || render.present()) && !render.is(LUA_TFUNCTION)) {
        render.fail("must be a function");
      }
    }
  };

}

// Interface: telar_config/bars_validator.cppm
namespace telar::runtime::config {

  template <CommandTabStore Commands>
  class BarsValidator {
  public:
    inline explicit BarsValidator(const BasicActionValidator<Commands>& actions, LimitNotices& limits)
        : actions_(actions),
          limits_(limits) {}

    inline void validate(const lua::Value& bars) const {
      if (!bars.present()) {
        return;
      }

      bars.onlyFields({"bottom", "top", "sidebar_footer"});
      bottom(bars.field("bottom"));
      const auto top = bars.field("top");
      if (top.present()) {
        top.onlyFields({"right"});
        const auto right = top.field("right");
        if (right.present() && source(right) == Source::tabs) {
          right.fail("cannot contain tabs");
        }
      }

      const auto footer = bars.field("sidebar_footer");
      if (footer.present()) {
        const auto count = footer.arraySize();
        if (count > maximum_footer_slots) {
          footer.fail(std::format("accepts at most {} slots", maximum_footer_slots).c_str());
        }

        for (std::size_t index = 1; index <= count; ++index) {
          if (source(footer.element(index)) == Source::tabs) {
            footer.fail("cannot contain tabs");
          }
        }
      }
    }

  private:
    enum class Source {
      content,
      tabs,
    };

    inline void bottom(const lua::Value& bar) const {
      if (!bar.present()) {
        return;
      }

      bar.onlyFields({"left", "center", "right"});
      unsigned tabs = 0;

      for (const auto* name : {"left", "center", "right"}) {
        const auto value = bar.field(name);
        if (value.present() && source(value) == Source::tabs) {
          ++tabs;
        }
      }

      if (tabs != 1) {
        bar.fail("must contain exactly one tabs source");
      }
    }

    inline Source source(const lua::Value& value) const {
      const auto kind_value = value.field("bar_kind");
      const auto kind = kind_value.string();
      if (kind == "tabs" || kind == "metrics" || kind == "machines") {
        value.onlyFields({"bar_kind"});
        return kind == "tabs" ? Source::tabs : Source::content;
      }

      if (kind == "static") {
        value.onlyFields({"bar_kind", "value"});
        ComponentValidator{actions_, limits_}.validate(value.field("value"));
      } else {
        DynamicSourceValidator::validate(value);
      }

      return Source::content;
    }

    static constexpr std::size_t maximum_footer_slots = 3;
    const BasicActionValidator<Commands>& actions_;
    LimitNotices& limits_;
  };

}

// Interface: telar_config/key_chord.cppm
export {
  namespace telar::runtime::config {

    struct KeyChord {
      enum class Key {
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

      enum class Modifier : unsigned {
        none = 0,
        control = 1,
        alt = 2,
        shift = 4,
        super = 8,
      };

      Key key = Key::character;
      std::uint32_t character = 0;
      unsigned modifiers = 0;

      inline bool has(Modifier modifier) const noexcept {
        return (modifiers & static_cast<unsigned>(modifier)) != 0;
      }

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
        std::array<KeyChord, 2> keys{};
        std::size_t length = 0;
        bool prefixed = false;
      };

      inline void setPrefix(KeyChord prefix) noexcept {
        prefix_ = prefix;
        for (auto& binding : std::span{bindings_}.first(count_)) {
          if (binding.prefixed) {
            binding.keys[0] = prefix;
          }
        }
      }

      inline KeyChord prefix() const noexcept {
        return prefix_;
      }

      inline void clear() noexcept {
        count_ = 0;
      }

      inline void append(Sequence sequence) noexcept {
        bindings_[count_++] = sequence;
      }

      inline void report(LimitNotices& limits) const noexcept {
        std::size_t wanted = count_;

        for (const auto suffix : defaultSuffixes()) {
          const bool overridden = std::ranges::any_of(std::span{bindings_}.first(count_), [&](const Sequence& binding) {
            return binding.keys[0] == prefix_ && (binding.length == 1 || binding.keys[1] == suffix);
          });

          wanted += !overridden;
        }

        if (wanted > maximum_bindings) {
          limits.add({"config.max_bindings", "key bindings", maximum_bindings, wanted, {}});
        }
      }

      static constexpr std::size_t maximum_bindings = 256;

    private:
      static constexpr std::array<KeyChord, 43> defaultSuffixes() noexcept {
        using Key = KeyChord::Key;
        constexpr auto shift = static_cast<unsigned>(KeyChord::Modifier::shift);
        constexpr auto alt = static_cast<unsigned>(KeyChord::Modifier::alt);

        return std::array<KeyChord, 43>{{
            {Key::character, '-'},
            {Key::character, '='},
            {Key::character, '%'},
            {Key::character, '"'},
            {Key::left},
            {Key::right},
            {Key::up},
            {Key::down},
            {Key::left, 0, shift},
            {Key::right, 0, shift},
            {Key::up, 0, shift},
            {Key::down, 0, shift},
            {Key::character, 'z'},
            {Key::character, 's'},
            {Key::left, 0, alt},
            {Key::right, 0, alt},
            {Key::character, 'w'},
            {Key::character, 'u'},
            {Key::character, 'N'},
            {Key::character, 'W'},
            {Key::character, 'x'},
            {Key::character, 'd'},
            {Key::character, '['},
            {Key::character, 'g'},
            {Key::character, '/'},
            {Key::character, 'f'},
            {Key::character, '?'},
            {Key::character, 'c'},
            {Key::character, 'n'},
            {Key::character, 'p'},
            {Key::character, '1'},
            {Key::character, '2'},
            {Key::character, '3'},
            {Key::character, '4'},
            {Key::character, '5'},
            {Key::character, '6'},
            {Key::character, '7'},
            {Key::character, '8'},
            {Key::character, '9'},
            {Key::character, 'T'},
            {Key::character, 'X'},
            {Key::character, ','},
            {Key::character, '.'},
        }};
      }

      KeyChord prefix_{KeyChord::Key::character, 'b', static_cast<unsigned>(KeyChord::Modifier::control)};
      std::array<Sequence, maximum_bindings> bindings_{};
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
      inline static void validate(const lua::Value& value) {
        parse(value);
      }

      inline static KeyChord parse(const lua::Value& value) {
        auto remaining = value.string();
        KeyChord chord;
        bool has_key = false;

        for (;;) {
          const auto separator = remaining.find('+');
          const auto part = remaining.substr(0, separator);
          if (part.empty() || has_key) {
            value.fail("contains an empty key or a modifier after its key");
          }

          const auto modifier = identifyModifier(part);
          if (modifier != Modifier::none) {
            const auto bit = static_cast<unsigned>(modifier);
            if ((chord.modifiers & bit) != 0) {
              value.fail("repeats a modifier");
            }

            chord.modifiers |= bit;
          } else {
            parseKey(value, part, chord);
            has_key = true;
          }

          if (separator == std::string_view::npos) {
            break;
          }

          remaining.remove_prefix(separator + 1);
        }

        if (!has_key) {
          value.fail("has no key");
        }

        return chord;
      }

    private:
      inline static bool matches(std::string_view text, std::string_view name) noexcept {
        return text.size() == name.size() && std::equal(text.begin(), text.end(), name.begin(), [](char left, char right) {
          return asciiLower(left) == right;
        });
      }

      inline static Modifier identifyModifier(std::string_view name) noexcept {
        if (matches(name, "ctrl") || matches(name, "control")) {
          return Modifier::control;
        }

        if (matches(name, "alt")) {
          return Modifier::alt;
        }

        if (matches(name, "shift")) {
          return Modifier::shift;
        }

        if (matches(name, "super") || matches(name, "cmd") || matches(name, "command")) {
          return Modifier::super;
        }

        return Modifier::none;
      }

      inline static void parseKey(const lua::Value& value, std::string_view name, KeyChord& chord) {
        constexpr std::pair<std::string_view, Key> named_keys[]{{"up", Key::up}, {"down", Key::down}, {"left", Key::left}, {"right", Key::right}, {"home", Key::home}, {"end", Key::end}, {"delete", Key::erase}, {"del", Key::erase}, {"pageup", Key::page_up}, {"page-up", Key::page_up}, {"pagedown", Key::page_down}, {"page-down", Key::page_down}, {"enter", Key::enter}, {"return", Key::enter}, {"escape", Key::escape}, {"esc", Key::escape}, {"backspace", Key::backspace}, {"tab", Key::tab}, {"backtab", Key::back_tab}};

        for (const auto& [known, key] : named_keys) {
          if (matches(name, known)) {
            chord.key = key;
            if (key == Key::tab && chord.modifiers == static_cast<unsigned>(Modifier::shift)) {
              chord.key = Key::back_tab;
              chord.modifiers = 0;
            }

            return;
          }
        }

        if (matches(name, "space")) {
          name = " ";
        } else if (matches(name, "plus")) {
          name = "+";
        }

        validateUtf8(name);
        const auto codepoints = std::ranges::count_if(name, [](unsigned char byte) {
          return (byte & 0xc0) != 0x80;
        });
        if (codepoints != 1) {
          value.fail("must name one key");
        }

        std::memcpy(&chord.character, name.data(), name.size());
        if (name.size() == 1 && (chord.has(Modifier::control) || chord.has(Modifier::super))) {
          chord.character = static_cast<unsigned char>(asciiLower(name.front()));
        }

        if (chord.has(Modifier::shift) && !chord.has(Modifier::super)) {
          const bool letter = name.size() == 1 && asciiLower(name.front()) >= 'a' && asciiLower(name.front()) <= 'z';
          if (chord.has(Modifier::control) || (!letter && name != " ")) {
            value.fail("cannot represent this shifted character");
          }

          chord.character = letter ? static_cast<unsigned char>(asciiLower(name.front()) - ('a' - 'A')) : ' ';
          chord.modifiers &= ~static_cast<unsigned>(Modifier::shift);
        }
      }
    };

  }
}

// Interface: telar_config/binding_validator.cppm
export {
  namespace telar::runtime::config {

    class BindingValidator {
    public:
      template <CommandTabStore Commands>
      inline static void validate(const lua::Value& bindings, const BasicActionValidator<Commands>& actions, BindingKeymap& keymap, LimitNotices& limits) {
        if (!bindings.present()) {
          return;
        }

        constexpr auto maximum_bindings = BindingKeymap::maximum_bindings;

        keymap.clear();
        const auto listed = bindings.listLength();
        const auto count = std::min(listed, maximum_bindings);

        if (listed > maximum_bindings) {
          limits.add({"config.max_bindings", "key bindings", maximum_bindings, listed, {}});
        }

        for (std::size_t index = 1; index <= count; ++index) {
          const auto binding = bindings.element(index);

          binding.onlyFields({"keys", "action", "expression", "prefixed"});
          const auto prefix = binding.field("prefixed");
          if (!prefix.present()) {
            prefix.fail("must be a boolean");
          }

          const bool prefixed = prefix.boolean(false);
          const auto keys = binding.field("keys");
          const auto key_count = keys.listLength();
          constexpr std::size_t maximum_keys = 5;
          if (key_count == 0 || key_count > maximum_keys - prefixed) {
            keys.fail("has an invalid number of keys");
          }

          BindingKeymap::Sequence sequence{.length = key_count + prefixed, .prefixed = prefixed};

          if (prefixed) {
            sequence.keys[0] = keymap.prefix();
          }

          for (std::size_t key = 1; key <= key_count; ++key) {
            const auto parsed = KeyChordValidator::parse(keys.element(key));
            const auto position = key - 1 + prefixed;
            if (position < sequence.keys.size()) {
              sequence.keys[position] = parsed;
            }
          }

          if (actions.validate(binding.field("action"), binding.field("expression").boolean(false))) {
            keymap.append(sequence);
          }
        }
      }
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

      static PluginWorkerOptions parse(std::span<char* const> arguments) {
        if (arguments.size() != argument_count) {
          throw std::invalid_argument{"Expected plugin-worker ENTRY ACTION SIDEBAR TAB_COUNT ACTIVE_TAB_INDEX PANE_COUNT FOCUSED_PANE_ID"};
        }

        std::array<char*, argument_count> fields = {};

        std::ranges::copy(arguments, fields.begin());
        const auto [entry_arg, action_arg, sidebar_arg, tab_count_arg, active_tab_index_arg, pane_count_arg, focused_pane_id_arg] = fields;

        const std::string_view sidebar = {sidebar_arg};
        if (sidebar != "0" && sidebar != "1") {
          throw std::invalid_argument{"Invalid plugin worker sidebar flag"};
        }

        const std::string_view action = {action_arg};
        if (action.empty()) {
          throw std::invalid_argument{"Empty plugin action"};
        }

        for (const char byte : action) {
          if ((byte < 'a' || byte > 'z') && (byte < 'A' || byte > 'Z') && (byte < '0' || byte > '9') && byte != '_' && byte != '-' && byte != '.') {
            throw std::invalid_argument{"Invalid plugin action name"};
          }
        }

        const BindingContext context = {
            .sidebar_visible = sidebar == "1",
            .tab_count = number<std::uint16_t>(tab_count_arg),
            .active_tab_index = number<std::uint16_t>(active_tab_index_arg),
            .pane_count = number<std::uint16_t>(pane_count_arg),
            .focused_pane_id = number<std::uint64_t>(focused_pane_id_arg),
        };

        return {
            .entry = entry_arg,
            .action = action_arg,
            .context = context,
        };
      }

      // Hands `consume` each word after the command, in the order parse reads them.
      template <typename Consume>
      void eachArgument(Consume&& consume) const {
        consume(std::string_view{entry});
        consume(std::string_view{action});
        consume(std::string_view{context.sidebar_visible ? "1" : "0"});
        for (const std::uint64_t value : {std::uint64_t{context.tab_count}, std::uint64_t{context.active_tab_index}, std::uint64_t{context.pane_count}, context.focused_pane_id}) {
          std::array<char, 20> digits;
          const auto written = std::to_chars(digits.data(), digits.data() + digits.size(), value);

          consume(std::string_view{digits.data(), static_cast<std::size_t>(written.ptr - digits.data())});
        }
      }

    private:
      template <std::unsigned_integral Integer>
      static Integer number(std::string_view text) {
        const auto value = unsignedNumber<Integer>(text);
        if (!value) {
          throw std::invalid_argument{value.error() == NumberError::overflow ? "Plugin worker integer exceeds its bounds" : "Invalid plugin worker integer"};
        }

        return *value;
      }
    };

  }
}

// Interface: telar_config/callback_invocation.cppm
export {
  namespace telar::runtime::config {

    class CallbackInvocation {
    public:
      inline explicit CallbackInvocation(int reference, BindingContext context)
          : reference_(reference),
            context_(context) {}

      inline static int invoke(lua_State* state) {
        const auto& invocation = *static_cast<CallbackInvocation*>(lua_touserdata(state, 1));

        lua_rawgeti(state, LUA_REGISTRYINDEX, invocation.reference_);
        invocation.pushContext(state);
        lua_call(state, 1, 1);

        return 1;
      }

    private:
      inline void pushContext(lua_State* state) const {
        lua_newtable(state);
        lua::setField(state, "sidebar_visible", static_cast<bool>(context_.sidebar_visible));
        lua::setField(state, "tab_count", static_cast<lua_Integer>(context_.tab_count));
        lua::setField(state, "active_tab_index", static_cast<lua_Integer>(static_cast<std::uint32_t>(context_.active_tab_index) + 1));
        lua::setField(state, "pane_count", static_cast<lua_Integer>(context_.pane_count));
        lua::setField(state, "focused_pane_id", static_cast<lua_Integer>(context_.focused_pane_id));
        lua::pushReadOnly(state, "callback context is immutable");
      }

      int reference_;
      BindingContext context_;
    };

  }
}

// Interface: telar_config/pick_items_validator.cppm
namespace telar::runtime::config {

  class PickItemsValidator {
  public:
    inline explicit PickItemsValidator(LimitNotices& limits)
        : limits_(limits) {}

    inline void validate(const lua::Value& items) {
      const auto count = items.arraySize();

      for (std::size_t index = 1; index <= count; ++index) {
        const auto item = items.element(index);
        if (item.is(LUA_TSTRING)) {
          const auto label = item.string();

          keep(item, label, label, {});
          continue;
        }

        item.onlyFields({"label", "value", "detail", "selected", "swatch"});
        const auto label = item.field("label");
        const auto value = item.field("value");
        const auto detail = item.field("detail");

        item.field("selected").boolean(false);
        swatch(item.field("swatch"));
        keep(item, label.string(), value.present() ? value.string() : label.string(), detail.present() ? detail.string() : std::string_view{});
      }

      if (count > maximum_items) {
        limits_.add({"picks.max_items", "options", maximum_items, count, {}});
      }

      if (text_full_) {
        limits_.add({"picks.max_text_bytes", "option text bytes", maximum_text_bytes, offered_text_bytes_, {}});
      }

      const std::array<LimitReach, 3> text_limits{{
          {"picks.max_label_bytes", "label bytes", maximum_label_bytes, longest_label_, {}},
          {"picks.max_value_bytes", "value bytes", maximum_value_bytes, longest_value_, {}},
          {"picks.max_detail_bytes", "detail bytes", maximum_detail_bytes, longest_detail_, {}},
      }};

      for (const auto& reach : text_limits) {
        if (reach.requested > reach.value) {
          limits_.add(reach);
        }
      }
    }

  private:
    inline void keep(const lua::Value& item, std::string_view label, std::string_view value, std::string_view detail) {
      offered_text_bytes_ += label.size() + value.size() + detail.size();
      longest_label_ = std::max(longest_label_, label.size());
      longest_detail_ = std::max(longest_detail_, detail.size());
      longest_value_ = std::max(longest_value_, value.size());
      label = utf8Prefix(label, maximum_label_bytes);
      detail = utf8Prefix(detail, maximum_detail_bytes);
      if (value.size() > maximum_value_bytes) {
        return;
      }

      if (kept_items_ == maximum_items || text_full_) {
        return;
      }

      if (label.empty() || value.empty()) {
        item.fail("needs a nonempty label and value");
      }

      printableUiText(item, label);
      printableUiText(item, detail);
      printableUiText(item, value, true);

      const auto needed = label.size() + detail.size() + (label == value ? 0 : value.size());
      if (text_bytes_ + needed > maximum_text_bytes) {
        text_full_ = true;
        return;
      }

      text_bytes_ += needed;
      ++kept_items_;
    }

    inline static void swatch(const lua::Value& value) {
      if (!value.present()) {
        return;
      }

      if (value.arraySize() != 3) {
        value.fail("must contain three RGB colors");
      }

      for (lua_Integer index = 1; index <= 3; ++index) {
        hexadecimalColor(value.element(index));
      }
    }

    static constexpr std::size_t maximum_items = 4096;
    static constexpr std::size_t maximum_text_bytes = 256 * 1024;
    static constexpr std::size_t maximum_label_bytes = 128;
    static constexpr std::size_t maximum_value_bytes = 512;
    static constexpr std::size_t maximum_detail_bytes = 128;

    LimitNotices& limits_;
    std::size_t kept_items_ = 0;
    std::size_t text_bytes_ = 0;
    std::size_t offered_text_bytes_ = 0;
    std::size_t longest_label_ = 0;
    std::size_t longest_value_ = 0;
    std::size_t longest_detail_ = 0;
    bool text_full_ = false;
  };

}

// Interface: telar_config/client_definitions_validator.cppm
namespace telar::runtime::config {

  class ClientDefinitionsValidator {
  public:
    inline static void validate(const lua::Value& client, LimitNotices& limits) {
      NamedDefinitionsValidator::validate(client.field("panels"), {"panels.max_panels", "panels", NamedDefinitionsValidator::maximum_definitions, {}, {}}, limits, [&](std::string_view name, const lua::Value& definition) {
        definition.onlyFields({"panel_kind", "title", "mark", "icon", "width", "source", "refresh"});
        NamedDefinitionsValidator::heading(name, definition, limits);
        const auto mark = definition.field("mark");
        if (mark.is(LUA_TSTRING)) {
          uiMark(mark);
        }

        const auto icon = definition.field("icon");
        if (icon.is(LUA_TSTRING)) {
          uiIcon(icon);
        }

        definition.field("width").boundedInteger(420, 240, 720);
        DynamicSourceValidator::validate(definition.field("source"));
      });

      NamedDefinitionsValidator::validate(client.field("picks"), {"picks.max_picks", "picks", NamedDefinitionsValidator::maximum_definitions, {}, {}}, limits, [&](std::string_view name, const lua::Value& definition) {
        definition.onlyFields({"pick_kind", "title", "command", "items", "on_select", "timeout_ms", "refresh"});
        NamedDefinitionsValidator::heading(name, definition, limits);
        definition.field("timeout_ms").boundedInteger(2000, 100, 60000);
        const auto command = definition.field("command");
        if (command.present()) {
          CommandArgumentsValidator::validate(command);
        }

        const auto items = definition.field("items");
        if (items.present()) {
          if (command.present()) {
            if (!items.is(LUA_TFUNCTION)) {
              items.fail("must be a function when a command is provided");
            }
          } else {
            PickItemsValidator{limits}.validate(items);
          }
        } else if (!command.present()) {
          definition.fail("requires items or a command");
        }

        if (!CommandArgumentsValidator::validate(definition.field("on_select"))) {
          definition.fail("requires a choice placeholder after the program");
        }

        definition.field("refresh").boolean(false);
      });
    }
  };

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
    inline constexpr std::array<std::string_view, 27> prompt_action_names{
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
        "insert_mode"
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

    inline constexpr std::array<std::string_view, 2> prompt_mode_names{"classic", "telar"};
    inline constexpr std::array<std::string_view, 3> prompt_skin_names{"halo", "glass", "ink"};
    inline constexpr std::array<std::string_view, 3> prompt_motion_names{"spring", "ease", "none"};
    inline constexpr std::array<std::string_view, 2> prompt_keymap_names{"emacs", "vim"};
    inline constexpr std::array<std::string_view, 2> prompt_binding_mode_names{"insert", "normal"};

    struct PromptBounds {
      static constexpr Bounds<double> max_lines{1, 64};
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
      std::optional<PromptMode> mode;
      std::optional<PromptSkin> skin;
      std::optional<PromptMotion> motion;
      std::optional<PromptKeymap> keymap;
      std::optional<bool> ghost;
      std::optional<std::uint8_t> max_lines;
      // Whether it lists bindings, which replace the defaults even when empty.
      bool bindings = false;
    };

    class PromptReader {
    public:
      // Hands each binding to `binding` in order.
      template <typename Binding>
      [[nodiscard]] inline static PromptSettings read(const lua::Value& table, Binding&& binding) {
        PromptSettings settings;

        if (!table.present()) {
          return settings;
        }

        table.onlyFields({"mode", "skin", "motion", "ghost", "keymap", "max_lines", "bindings"});
        settings.mode = optionalChoice<PromptMode>(table.field("mode"), prompt_mode_names);
        const auto bindings = table.field("bindings");
        if (bindings.present()) {
          settings.bindings = true;
          const auto count = bindings.listLength();
          if (count > PromptBounds::bindings) {
            bindings.fail("has more than 256 bindings");
          }

          for (std::size_t index = 0; index < count; ++index) {
            const auto entry = bindings.element(static_cast<lua_Integer>(index) + 1);

            entry.onlyFields({"keys", "action", "mode"});
            const auto chord = KeyChordValidator::parse(entry.field("keys"));
            const auto action = entry.field("action");
            const auto found = std::ranges::find(prompt_action_names, action.string());
            if (found == prompt_action_names.end()) {
              action.fail("names an unknown prompt action");
            }

            const auto mode = optionalChoice<std::uint8_t>(entry.field("mode"), prompt_binding_mode_names);

            binding(PromptBindingSetting{.chord = chord, .action = static_cast<std::uint8_t>(found - prompt_action_names.begin()), .normal = mode == 1});
          }
        }

        settings.skin = optionalChoice<PromptSkin>(table.field("skin"), prompt_skin_names);
        settings.motion = optionalChoice<PromptMotion>(table.field("motion"), prompt_motion_names);
        settings.keymap = optionalChoice<PromptKeymap>(table.field("keymap"), prompt_keymap_names);
        settings.ghost = optionalBoolean(table.field("ghost"));
        if (const auto lines = table.field("max_lines"); lines.present()) {
          settings.max_lines = static_cast<std::uint8_t>(lines.boundedInteger(PromptBounds::max_lines.minimum, PromptBounds::max_lines.minimum, PromptBounds::max_lines.maximum));
        }

        return settings;
      }
    };

  }
}

// Interface: telar_config/client_validator.cppm
export {
  namespace telar::runtime::config {

    // Interface pieces a configuration may draw with Lua, under `client.components`.
    inline constexpr std::array<std::string_view, 19> component_slots{
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

    class ClientValidator {
    public:
      template <CommandTabStore Commands>
      inline static void validate(const lua::Value& client, LimitNotices& limits, BasicClientValidationState<Commands>& state, const lua::Value* inherited = nullptr) {
        if (!client.present()) {
          return;
        }

        client.onlyFields({"prefix", "theme", "icons", "sidebar", "pane_gaps", "editor", "window_title", "sound", "notifications", "appearance", "input", "keybindings", "bars", "panels", "picks", "history", "components", "prompt"});
        const auto prefix = client.field("prefix");
        if (prefix.present()) {
          state.keymap.setPrefix(KeyChordValidator::parse(prefix));
        }

        client.field("pane_gaps").boolean(false);
        printableText(client.field("editor"), 4096, false);
        printableText(client.field("window_title"), 128, true);
        sidebar(client.field("sidebar"));
        sound(client.field("sound"));
        notifications(client.field("notifications"));
        input(client.field("input"));
        history(client.field("history"));
        prompt(client.field("prompt"));
        ClientDefinitionsValidator::validate(client, limits);
        const ClientDefinitions definitions{client, inherited};
        const BasicActionValidator actions{definitions, limits, state.commands};

        BindingValidator::validate(client.field("keybindings"), actions, state.keymap, limits);
        BarsValidator{actions, limits}.validate(client.field("bars"));
        components(client.field("components"));
      }

    private:
      inline static void components(const lua::Value& value) {
        if (!value.present()) {
          return;
        }

        value.eachField([](std::string_view name, const lua::Value& entry) {
          if (std::ranges::find(component_slots, name) == component_slots.end()) {
            const auto message = std::string{"names an unknown component slot \""} + std::string{name} + "\"";

            entry.fail(message.c_str());
          }

          if (!entry.is(LUA_TFUNCTION)) {
            entry.fail("must be a function from the context and the item to an element");
          }
        });
      }

      inline static void printableText(const lua::Value& value, std::size_t maximum, bool allow_empty) {
        if (!value.present()) {
          return;
        }

        optionalUtf8Text(value, maximum);
        const auto text = value.string();
        if ((!allow_empty && text.empty()) || std::ranges::any_of(text, [](unsigned char byte) {
              return byte < 0x20 || byte == 0x7f;
            })) {
          value.fail("must contain printable text");
        }
      }

      inline static void sidebar(const lua::Value& table) {
        if (table.present()) {
          table.onlyFields({"visible", "renderer"});
          table.field("visible").boolean(true);
        }
      }

      inline static void sound(const lua::Value& table) {
        if (table.present()) {
          table.onlyFields({"enabled", "ready", "needs_input"});
          for (const auto* name : {"enabled", "ready", "needs_input"}) {
            table.field(name).boolean(false);
          }
        }
      }

      inline static void notifications(const lua::Value& table) {
        if (table.present()) {
          table.onlyFields({"delivery"});
          optionalChoice(table.field("delivery"), {"telar", "system", "terminal"});
        }
      }

      inline static void input(const lua::Value& table) {
        if (table.present()) {
          table.onlyFields({"escape_timeout_ms", "sequence_timeout_ms"});
          table.field("sequence_timeout_ms").boundedInteger(1000, 10, 10000);
        }
      }

      inline static void prompt(const lua::Value& table) {
        static_cast<void>(PromptReader::read(table, [](const PromptBindingSetting&) {}));
      }

      inline static void history(const lua::Value& table) {
        if (table.present()) {
          table.onlyFields({"show_agent_commands", "enter", "match"});
          table.field("show_agent_commands").boolean(false);
          optionalChoice(table.field("enter"), {"paste", "run"});
          optionalChoice(table.field("match"), {"fuzzy", "fts"});
        }
      }
    };

  }
}
