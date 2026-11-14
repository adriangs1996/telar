module;
#include <cstdint>
#include <lua.h>

export module telar.config.client;

import std;
import telar.tbc;
export import telar.config.core;
import telar.base.diagnostics;
import telar.base.text;
import telar.base.text.utf8;
import telar.wire.clients;
import telar.wire.vocabulary;

// Interface: telar_config/named_definitions_validator.cppm
namespace telar::runtime::config {

  class NamedDefinitionsValidator {
  public:
    // Hands the definitions to `validate_definition` in name order, each with its index, and
    // returns how many it kept, if the table is present.
    template <typename Validator>
    inline static std::optional<std::size_t> validate(const lua::Value& table, tbc::view<LimitReach, tbc::lt::b> reach, tbc::view<LimitNotices&, tbc::lt::b> limits, Validator&& validate_definition) {
      if (!table.present()) {
        return std::nullopt;
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

      for (std::size_t index = 0; index < kept; ++index) {
        const auto definition = table.entry(names[index]);

        validate_definition(names[index], definition, index);
      }

      return kept;
    }

    // The definition's title, or its name, cut to the title limit.
    inline static std::string_view heading(std::string_view name, const lua::Value& definition, LimitNotices& limits) {
      if (name.empty() || name.size() > maximum_name_bytes || !std::ranges::all_of(name, [](unsigned char byte) {
            return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
          })) {
        definition.fail("has an invalid name");
      }

      const auto title = definition.field("title");
      const auto text = fittedUiText(title.present() ? title.string() : name, {"panels.title_bytes", "title bytes", maximum_title_bytes, {}, {}}, limits);

      printableUiText(title, text);
      return text;
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
      [[nodiscard]] inline static ExtendedActionSetting read(const lua::Value& action, const ClientDefinitions& definitions) {
        const auto kind = action.field("kind").string();
        if (kind == "notification") {
          return notification(action);
        }

        if (kind == "plugin") {
          return PluginActionSetting{.plugin = action.field("plugin").string(), .action = action.field("action").string()};
        }

        const bool panel = kind == "open-panel";
        const auto selected = action.field(panel ? "panel" : "pick");
        const auto index = definitions.index(panel ? "panels" : "picks", selected.string());
        if (!index) {
          selected.fail("names an unknown client definition");
        }

        return DefinitionActionSetting{.panel = panel, .index = *index};
      }

    private:
      inline static NotificationActionSetting notification(const lua::Value& action) {
        NotificationActionSetting result;

        result.title = utf8Prefix(action.field("title").string(), max_notification_title_bytes);
        const auto body = action.field("body");
        if (body.present()) {
          result.body = utf8Prefix(body.string(), max_notification_message_bytes);
        }

        result.level = optionalChoice<NotificationLevel>(action.field("level"), notification_level_names).value_or(NotificationLevel::info);
        result.duration_ms = static_cast<std::uint32_t>(action.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms));
        constexpr std::array targets{"pane_id", "tab_id", "workspace_id"};

        for (std::size_t index = 0; index < targets.size(); ++index) {
          const auto target = action.field(targets[index]);
          if (target.present()) {
            result.target = {.kind = static_cast<NotificationTarget::Kind>(index + 1), .id = static_cast<std::uint64_t>(target.integer())};
          }
        }

        return result;
      }

      static constexpr std::array<std::string_view, 4> notification_level_names{"info", "success", "warning", "failure"};
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

      // Validates the action and reads it; nothing when a limit drops it.
      [[nodiscard]] inline std::optional<ActionSetting> read(const lua::Value& action, bool expression = false) const {
        if (!validate(action, expression)) {
          return std::nullopt;
        }

        ActionSetting setting;

        if (action.is(LUA_TFUNCTION)) {
          setting.kind = ActionKind::function;
          return setting;
        }

        if (action.is(LUA_TSTRING)) {
          setting.name = action.string();
          return setting;
        }

        const auto kind = action.field("kind").string();
        if (kind == "select-tab" || kind == "select-workspace") {
          setting.kind = kind == "select-tab" ? ActionKind::select_tab : ActionKind::select_workspace;
          setting.number = static_cast<std::int32_t>(action.field("index").integer());
        } else if (kind == "select-tab-offset") {
          setting.kind = ActionKind::select_tab_offset;
          setting.number = static_cast<std::int32_t>(action.field("offset").integer());
        } else if (kind == "command-tab") {
          setting.kind = ActionKind::command_tab;
          command(action, setting.command);
        } else if (kind == "notification") {
          setting.kind = ActionKind::notification;
        } else if (kind == "open-panel") {
          setting.kind = ActionKind::panel;
        } else if (kind == "pick") {
          setting.kind = ActionKind::pick;
        } else if (kind == "plugin") {
          setting.kind = ActionKind::plugin;
        } else {
          setting.name = builtinName(action, kind);
        }

        return setting;
      }

    private:
      inline static void command(const lua::Value& action, CommandTabView& command) {
        const auto arguments = action.field("command");

        command.count = arguments.listLength();
        for (std::size_t index = 0; index < command.count; ++index) {
          command.arguments[index] = arguments.element(static_cast<lua_Integer>(index) + 1).string();
        }

        const auto label = action.field("label");

        command.configured_label = label.is(LUA_TSTRING) ? label.string() : std::string_view{};
      }

      // A directional action names its stem and its direction: {kind = "split-pane", direction =
      // "horizontal"} is "split-horizontal".
      inline static std::string_view builtinName(const lua::Value& action, std::string_view kind) {
        constexpr auto stems = std::to_array<std::pair<std::string_view, std::string_view>>({
            {"scroll-pane", "scroll-pane-"},
            {"split-pane", "split-"},
            {"focus-pane", "focus-"},
            {"navigate-pane", "navigate-"},
            {"resize-pane", "resize-"},
            {"resize-sidebar", "resize-sidebar-"},
            {"move-tab", "move-tab-"},
        });

        const auto* const found = std::ranges::find(stems, kind, &decltype(stems)::value_type::first);
        if (found == stems.end()) {
          return kind;
        }

        const auto direction = action.field("direction").string();
        const auto* const joined = std::ranges::find_if(builtin_names, [&](std::string_view name) {
          return name.size() == found->second.size() + direction.size() && name.starts_with(found->second) && name.ends_with(direction);
        });
        if (joined == builtin_names.end()) {
          action.fail("names an unknown action");
        }

        return *joined;
      }

      static constexpr std::array<std::string_view, 45> builtin_names{"next-machine", "previous-machine", "machine-picker", "add-machine", "scroll-pane-up", "scroll-pane-down", "split-horizontal", "split-vertical", "focus-left", "focus-right", "focus-up", "focus-down", "navigate-left", "navigate-right", "navigate-up", "navigate-down", "resize-left", "resize-right", "resize-up", "resize-down", "toggle-pane-fullscreen", "toggle-sidebar", "resize-sidebar-left", "resize-sidebar-right", "toggle-workspace-list", "leave-worktree", "forget-gone-worktrees", "new-workspace", "rename-workspace", "close-pane", "new-tab", "next-tab", "previous-tab", "rename-tab", "close-tab", "move-tab-previous", "move-tab-next", "detach", "copy-mode", "goto-picker", "history-palette", "path-picker", "suggest-command", "close-panel", "refresh-panel"};

      inline static void builtin(const lua::Value& value) {
        const auto name = value.string();
        if (std::ranges::find(builtin_names, name) != builtin_names.end()) {
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
        return unsignedNumber<unsigned>(number, std::numeric_limits<std::uint8_t>::max()).value_or(0) != 0;
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

    enum class UiMark : std::uint8_t {
      claude,
      codex,
      pi,
      telar,
    };

    inline constexpr std::array<std::string_view, 4> ui_mark_names{"claude", "codex", "pi", "telar"};

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
        shape.form = ComponentForm::component;
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

        shape.form = ComponentForm::segment;
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

    inline constexpr std::array<std::string_view, 6> component_tone_names{"neutral", "muted", "accent", "success", "warning", "danger"};
    inline constexpr std::array<std::string_view, 3> component_metric_names{"cpu", "memory", "battery"};

    // Turns the colors a configuration names into a client's: `index` takes a 256-color index
    // and `name` a name or "#RRGGBB", or nothing for one it does not know.
    template <typename Colors>
    concept UiColors = requires(const Colors& colors, std::uint8_t index, std::string_view name) {
      { colors.index(index) } -> std::same_as<typename Colors::Color>;
      { colors.name(name) } -> std::same_as<std::optional<typename Colors::Color>>;
    };

    // What a component shows beyond its shape. The views are the component's strings.
    template <typename Color>
    struct ComponentValues {
      static constexpr std::size_t maximum_samples = 120;
      static constexpr double sample_percent = 100;
      ComponentTone tone = ComponentTone::neutral;
      std::optional<Color> foreground;
      std::optional<Color> background;
      bool bold = false;
      bool italic = false;
      bool faint = false;
      bool underline = false;
      bool strikethrough = false;
      std::optional<std::string_view> icon;
      std::optional<UiMark> mark;
      ComponentMetric metric = ComponentMetric::cpu;
      std::optional<double> value;
      std::optional<double> marker;
      bool primary = false;
      // A sparkline's last samples, as percentages of its scale.
      std::array<std::uint8_t, maximum_samples> samples{};
      std::size_t sample_count = 0;
    };

    class ComponentValuesReader {
    public:
      template <UiColors Colors>
      [[nodiscard]] inline static ComponentValues<typename Colors::Color> read(const lua::Value& value, const ComponentShape& shape, const Colors& colors) {
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
        default:
          break;
        }

        return result;
      }

      [[nodiscard]] inline static ComponentTone tone(const lua::Value& value) {
        if (!value.present()) {
          return ComponentTone::neutral;
        }

        const auto* const found = std::ranges::find(component_tone_names, value.string());
        if (found == component_tone_names.end()) {
          value.fail("names an unknown component tone");
        }

        return static_cast<ComponentTone>(found - component_tone_names.begin());
      }

      // Hands a component's action, which cannot be a function, to `consume` and returns what it
      // returns.
      template <typename Consume>
      inline static decltype(auto) action(const lua::Value& value, const ComponentShape& shape, Consume&& consume) {
        const auto action = value.field(shape.action_field);
        if (action.is(LUA_TFUNCTION)) {
          action.fail("cannot be a callback in a component");
        }

        return std::forward<Consume>(consume)(action);
      }

    private:
      template <typename Colors, typename Values>
      inline static void style(const lua::Value& value, const Colors& colors, Values& result) {
        result.foreground = color(value.field("fg"), colors);
        result.background = color(value.field("bg"), colors);
        result.bold = value.field("bold").boolean(false);
        result.italic = value.field("italic").boolean(false);
        result.faint = value.field("faint").boolean(false);
        result.underline = value.field("underline").boolean(false);
        result.strikethrough = value.field("strikethrough").boolean(false);
      }

      template <typename Colors>
      inline static std::optional<typename Colors::Color> color(const lua::Value& value, const Colors& colors) {
        if (!value.present()) {
          return std::nullopt;
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

      inline static std::optional<std::string_view> icon(const lua::Value& value) {
        if (!value.present()) {
          return std::nullopt;
        }

        uiIcon(value);
        return value.string();
      }

      inline static std::optional<UiMark> mark(const lua::Value& value) {
        if (!value.present()) {
          return std::nullopt;
        }

        uiMark(value);
        return static_cast<UiMark>(std::ranges::find(ui_mark_names, value.string()) - ui_mark_names.begin());
      }

      inline static ComponentMetric metric(const lua::Value& value) {
        const auto* const found = std::ranges::find(component_metric_names, value.string());
        if (found == component_metric_names.end()) {
          value.fail("names an unknown component metric");
        }

        return static_cast<ComponentMetric>(found - component_metric_names.begin());
      }

      inline static std::optional<double> number(const lua::Value& value) {
        if (!value.present()) {
          return std::nullopt;
        }

        return value.boundedNumber(0, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());
      }

      template <typename Values>
      inline static void samples(const lua::Value& value, Values& result) {
        const auto maximum = value.field("max");
        const auto values = value.field("values");
        const auto total = values.listLength();

        result.sample_count = std::min(total, result.samples.size());
        std::array<double, Values::maximum_samples> kept{};
        double largest = 0;

        for (std::size_t index = 0; index < result.sample_count; ++index) {
          const auto sample = values.element(static_cast<lua_Integer>(total - result.sample_count + index) + 1);
          if (!sample.present()) {
            sample.fail("must be a number");
          }

          kept[index] = sample.boundedNumber(0, 0, std::numeric_limits<double>::max());
          largest = std::max(largest, kept[index]);
        }

        const auto scale = maximum.boundedNumber(largest, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());

        for (std::size_t index = 0; index < result.sample_count; ++index) {
          const auto fraction = scale > 0 ? std::clamp(kept[index] / scale, 0.0, 1.0) : 0;

          result.samples[index] = static_cast<std::uint8_t>(std::round(fraction * Values::sample_percent));
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

    inline bool componentAllowed(ComponentKind kind, ComponentPlace place) noexcept {
      switch (place) {
      case ComponentPlace::bar:
        return kind <= ComponentKind::group;
      case ComponentPlace::panel:
        return true;
      case ComponentPlace::group:
        return kind < ComponentKind::group;
      case ComponentPlace::tooltip:
        return kind != ComponentKind::group && kind != ComponentKind::callout && kind != ComponentKind::actions && kind != ComponentKind::button;
      case ComponentPlace::buttons:
        return kind == ComponentKind::button;
      }

      return false;
    }

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

    // Walks a component tree: text, a component, a segment, or a list of them. It hands each one
    // a builder may place to `builder.node(value, shape, position)`, which returns the parent its
    // children name, or nothing to leave them out. An explicit stack bounds both the nested lists
    // and the Lua stack the walk holds.
    template <typename Builder>
    class ComponentWalker {
    public:
      inline ComponentWalker(lua_State& state, Builder& builder, LimitNotices& limits) noexcept
          : state_(state),
            builder_(builder),
            limits_(limits) {}

      inline void walk(const lua::Value& value, ComponentPosition position) {
        const auto original_top = lua_gettop(&state_);

        value.pushCopy();
        try {
          push(position);
          while (frame_count_ != 0) {
            advance();
          }
        } catch (...) {
          while (frame_count_ != 0) {
            pop();
          }

          lua_settop(&state_, original_top);

          throw;
        }

        lua_settop(&state_, original_top);
      }

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
        std::optional<lua::Value> value = std::nullopt;
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

      inline void push(ComponentPosition position) {
        if (frame_count_ == frames_.size()) {
          throw std::length_error{"Component traversal stack exceeded"};
        }

        auto& frame = frames_[frame_count_++];

        frame.index = lua_gettop(&state_);
        frame.value.emplace(&state_, frame.index, "component");
        frame.position = position;
        frame.phase = Phase::visit;
        frame.tooltip = false;
        frame.next = 0;
        frame.count = 0;
      }

      inline void pop() noexcept {
        auto& frame = frames_[--frame_count_];

        frame.value.reset();
        lua_settop(&state_, frame.index - 1);
      }

      inline void advance() {
        auto& frame = frames_[frame_count_ - 1];

        switch (frame.phase) {
        case Phase::visit:
          visit(frame);
          break;
        case Phase::list:
        case Phase::children:
          if (frame.next == frame.count) {
            frame.phase = frame.tooltip ? Phase::tooltip : Phase::done;
          } else {
            lua_rawgeti(&state_, frame.index, static_cast<lua_Integer>(++frame.next));
            push(frame.child);
          }

          break;
        case Phase::tooltip:
        case Phase::button: {
          const bool tooltip = frame.phase == Phase::tooltip;

          frame.phase = Phase::done;
          lua_getfield(&state_, frame.index, tooltip ? "tooltip" : "button");
          auto child = frame.child;

          child.place = tooltip ? ComponentPlace::tooltip : ComponentPlace::buttons;
          child.priority = ComponentPosition::default_priority;
          push(child);
        } break;
        case Phase::done:
          pop();
          break;
        }
      }

      inline static const lua::Value& frameValue(const Frame& frame) {
        if (!frame.value) {
          throw std::logic_error{"Component traversal frame has no value"};
        }

        return *frame.value;
      }

      inline void visit(Frame& frame) {
        const auto& value = frameValue(frame);
        const auto position = frame.position;

        frame.phase = Phase::done;
        if (!value.present()) {
          return;
        }

        if (value.is(LUA_TSTRING)) {
          static_cast<void>(node(value, {.text = value.string(), .priority = position.priority}, position));
          return;
        }

        if (!value.is(LUA_TTABLE)) {
          value.fail("components must be text, a component or a list");
        }

        if (value.field("ui").present()) {
          component(frame);
          return;
        }

        if (value.field("text").present() || value.field("icon").present()) {
          static_cast<void>(node(value, ComponentShapeReader::segment(value, position.priority), position));
          return;
        }

        if (position.depth == maximum_list_depth) {
          value.fail("exceeds the component nesting limit");
        }

        frame.child = position;
        ++frame.child.depth;
        frame.count = value.arraySize();
        frame.phase = Phase::list;
      }

      inline void component(Frame& frame) {
        const auto& value = frameValue(frame);
        const auto shape = ComponentShapeReader::read(value, frame.position.priority, limits_);
        const auto parent = node(value, shape, frame.position);
        if (!parent) {
          return;
        }

        frame.child = {.parent = parent->index, .rank = parent->rank};
        switch (shape.kind) {
        case ComponentKind::group:
          frame.child.place = ComponentPlace::group;
          frame.child.priority = shape.priority;
          frame.tooltip = true;
          frame.count = value.listLength();
          frame.phase = Phase::children;
          break;
        case ComponentKind::actions:
          frame.child.place = ComponentPlace::buttons;
          frame.count = value.listLength();
          frame.phase = Phase::children;
          break;
        case ComponentKind::callout:
          frame.phase = Phase::button;
          break;
        default:
          break;
        }
      }

      inline std::optional<ComponentParent> node(const lua::Value& value, const ComponentShape& shape, const ComponentPosition& position) {
        if (!componentAllowed(shape.kind, position.place)) {
          value.fail("contains a component unsupported in this position");
        }

        return builder_.node(value, shape, position);
      }

      lua_State& state_;
      Builder& builder_;
      LimitNotices& limits_;
      std::array<Frame, maximum_frames> frames_{};
      std::size_t frame_count_ = 0;
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

    inline constexpr std::array<std::string_view, 13> element_kind_names{"row", "column", "stack", "spacer", "label", "icon", "mark", "badge", "tile", "canvas", "builtin", "elapsed", "clock"};

    // Native pieces `ui.builtin` can place: every slot plus parts of the two bars.
    inline constexpr std::array<std::string_view, 27> ui_builtin_names{
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
      std::optional<Color> value = std::nullopt;
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
      ElementColorSetting<Color> background;
      ElementColorSetting<Color> border;
      ElementColorSetting<Color> color;
      ElementColorSetting<Color> hover;
      ComponentTone tone = ComponentTone::neutral;
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

    template <typename Color>
    struct CanvasStepSetting {
      std::uint8_t op = 0;
      std::uint8_t count = 0;
      std::array<float, 6> values{};
      ElementColorSetting<Color> color;
      std::string_view text;
    };

    // Turns what a slot function returned into elements, handing each one to `sink`:
    // `element(setting)` keeps an element and returns its index, `step(setting)` keeps a canvas
    // operation, `resolve(action)` reads an `on_click` action, or drops it, `bind(resolved)`
    // keeps the action it read and `callback(function)` keeps an `on_click` function and returns
    // its index. Each view the sink gets is one of the result's strings.
    template <UiColors Colors, typename Sink>
    class ElementReader {
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
      inline void element(const Value& value, std::uint32_t parent, unsigned depth) {
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

      inline void children(const Value& value, std::uint32_t parent, unsigned depth) {
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

      static constexpr std::array<std::string_view, 27> layout_fields{"ui", "id", "width", "height", "min_width", "max_width", "min_height", "max_height", "grow", "align_self", "x", "y", "rotation", "scale", "opacity", "z", "background", "border", "radius", "padding", "shadow", "clip", "on_click", "url", "tooltip", "hover", "transition"};

      inline void fields(const Value& value, Element& element) {
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
          element.max_lines = static_cast<std::uint8_t>(value.field("max_lines").boundedInteger(1, 1, 64));
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

      inline void box(const Value& value, Element& element) {
        if (const auto id = value.field("id"); id.present()) {
          element.key = text(id);
        }

        element.width = length(value.field("width"), -1);
        element.height = length(value.field("height"), -1);
        element.min_width = length(value.field("min_width"), 0);
        element.max_width = length(value.field("max_width"), -1);
        element.min_height = length(value.field("min_height"), 0);
        element.max_height = length(value.field("max_height"), -1);
        element.grow = static_cast<float>(value.field("grow").boundedNumber(element.grow, 0, 1000));
        if (const auto align = value.field("align_self"); align.present()) {
          element.align_self = choice(align, {"start", "center", "end", "stretch"}, 0);
        }

        element.x = offset(value.field("x"));
        element.y = offset(value.field("y"));
        element.rotation = static_cast<float>(value.field("rotation").boundedNumber(0, -3600, 3600));
        element.scale = static_cast<float>(value.field("scale").boundedNumber(1, 0, 16));
        element.opacity = static_cast<float>(value.field("opacity").boundedNumber(1, 0, 1));
        element.z = static_cast<std::int16_t>(std::lround(value.field("z").boundedNumber(0, -1000, 1000)));
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

        if (const auto transition = value.field("transition"); transition.present()) {
          if (transition.is(LUA_TTABLE)) {
            transition.onlyFields({"duration", "easing"});
            element.transition_ms = static_cast<std::uint16_t>(transition.field("duration").boundedInteger(220, 0, 10000));
            element.easing = choice(transition.field("easing"), {"ease_out", "linear", "ease_in_out"}, 0);
          } else {
            element.transition_ms = static_cast<std::uint16_t>(transition.boundedInteger(220, 0, 10000));
          }
        }

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

        if (const auto click = value.field("on_click"); click.present()) {
          if (click.is(LUA_TFUNCTION)) {
            if (callbacks_ == Element::maximum_actions) {
              click.fail("exceeds 1024 click functions");
            }

            element.callback = sink_.callback(click);
            ++callbacks_;
          } else if (auto resolved = sink_.resolve(click)) {
            if (actions_ == Element::maximum_actions) {
              click.fail("exceeds 1024 click actions");
            }

            element.action = actions_++;
            sink_.bind(std::move(*resolved));
          }
        }
      }

      inline void typography(const Value& value, Element& element) {
        if (const auto size = value.field("size"); size.present()) {
          if (size.is(LUA_TSTRING)) {
            element.size_role = choice(size, {"title", "body", "small"}, 1);
          } else {
            element.size = static_cast<float>(size.boundedNumber(0, 1, 256));
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
        std::array<float, 4> sides{};

        for (std::size_t index = 0; index < std::min<std::size_t>(count, 4); ++index) {
          sides[index] = length(value.element(static_cast<lua_Integer>(index) + 1), 0);
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
          std::uint8_t numbers;
          bool text;
          bool color;
        };

        // Matches ElementCanvas::Operation, in order.
        constexpr std::array<Shape, 21> shapes{{
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
        }};

        element.steps_offset = steps_;
        const auto count = ops.present() ? ops.listLength() : 0;

        for (std::size_t index = 0; index < count; ++index) {
          if (steps_ == Element::maximum_steps) {
            ops.fail("exceeds 4096 canvas operations");
          }

          const auto op = ops.element(static_cast<lua_Integer>(index) + 1);
          const auto name = op.element(1).string();
          const auto* const shape = std::ranges::find(shapes, name, &Shape::name);
          if (shape == shapes.end()) {
            op.fail("names an unknown canvas operation");
          }

          CanvasStepSetting<typename Colors::Color> step;

          step.op = static_cast<std::uint8_t>(shape - shapes.begin());
          lua_Integer next = 2;

          if (shape->text) {
            step.text = text(op.element(next++));
          }

          if (shape->color) {
            step.color = color(op.element(next++));
          }

          const auto available = op.listLength() - static_cast<std::size_t>(next - 1);

          step.count = static_cast<std::uint8_t>(std::min<std::size_t>(available, shape->numbers));
          if ((step.count < shape->numbers && shape->name != "stroke" && shape->name != "scale") || available > shape->numbers) {
            op.fail("has the wrong number of values");
          }

          for (std::uint8_t number = 0; number < step.count; ++number) {
            step.values[number] = static_cast<float>(op.element(next++).boundedNumber(0, -1e6, 1e6));
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
          if (*index < 0 || *index > std::numeric_limits<std::uint8_t>::max()) {
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
          if (parsed.ec != std::errc{} || parsed.ptr != name.data() + rgba_length) {
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
        return static_cast<float>(value.boundedNumber(fallback, 0, 100000));
      }

      inline static float offset(const Value& value) {
        return static_cast<float>(value.boundedNumber(0, -100000, 100000));
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
        std::array<std::string_view, 40> names{};
        std::size_t count = 0;

        // NOLINTNEXTLINE(google-explicit-constructor): reads like the field lists it joins.
        operator std::span<const std::string_view>() const noexcept {
          return std::span{names}.first(count);
        }
      };

      // The fields name what the base and the extra names view, region `a`.
      inline static tbc::view<Fields, tbc::lt::a> combined(tbc::view<std::span<const std::string_view>, tbc::lt::a> base, tbc::view<std::initializer_list<std::string_view>, tbc::lt::a> extra) {
        Fields result;

        for (const auto name : base) {
          result.names[result.count++] = name;
        }

        for (const auto name : extra) {
          result.names[result.count++] = name;
        }

        return result;
      }

      inline std::string_view text(const Value& value) {
        if (!value.present()) {
          return {};
        }

        return store(value.string(), value);
      }

      inline std::string_view store(std::string_view text, const Value& value) {
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
    using Place = ComponentPlace;

    struct Position {
      Place place = Place::bar;
      unsigned priority = 50;
      unsigned rank = std::numeric_limits<std::uint8_t>::max();
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
      if (!componentAllowed(shape.kind, position.place)) {
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

// Interface: telar_config/command_arguments_reader.cppm
export {
  namespace telar::runtime::config {

    class CommandArgumentsReader {
    public:
      // Hands each argument of the definition's `field` list to `visit`, in order.
      template <typename Visit>
      inline static void read(const lua::Value& definition, const char* field, Visit&& visit) {
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

    inline constexpr std::array<std::string_view, 6> source_kind_names{"tabs", "metrics", "machines", "static", "dynamic", "command"};

    struct SourceSetting {
      static constexpr Bounds<double> every_ms_bounds{100, 3'600'000};
      static constexpr Bounds<double> timeout_ms_bounds{100, 10'000};
      static constexpr std::uint32_t default_every_ms = 1000;
      static constexpr std::uint32_t default_timeout_ms = 2000;
      SourceKind kind = SourceKind::tabs;
      // How often a dynamic or command source renders. A panel's renders when it opens, unless
      // it sets an interval.
      std::optional<std::uint32_t> every_ms;
      std::uint32_t timeout_ms = default_timeout_ms;
      // Whether it has a render function; a command source without one shows the output.
      bool render = false;
    };

    class SourceReader {
    public:
      [[nodiscard]] inline static SourceSetting read(const lua::Value& source, bool panel = false) {
        const auto kind = source.field("bar_kind");
        const auto* const found = std::ranges::find(source_kind_names, kind.string());
        if (found == source_kind_names.end()) {
          source.fail("names an unsupported bar source");
        }

        SourceSetting setting;

        setting.kind = static_cast<SourceKind>(found - source_kind_names.begin());
        if (setting.kind != SourceKind::dynamic && setting.kind != SourceKind::command) {
          return setting;
        }

        const auto every = source.field("every_ms");
        if (!panel || every.present()) {
          setting.every_ms = static_cast<std::uint32_t>(every.boundedInteger(SourceSetting::default_every_ms, SourceSetting::every_ms_bounds.minimum, SourceSetting::every_ms_bounds.maximum));
        }

        setting.render = source.field("render").present();
        setting.timeout_ms = static_cast<std::uint32_t>(source.field("timeout_ms").boundedInteger(SourceSetting::default_timeout_ms, SourceSetting::timeout_ms_bounds.minimum, SourceSetting::timeout_ms_bounds.maximum));
        return setting;
      }

      // Validates a source that renders, a dynamic or a command one, and reads it.
      [[nodiscard]] inline static SourceSetting dynamic(const lua::Value& source, bool panel = false) {
        const auto kind = source.field("bar_kind");
        const bool command = kind.string() == "command";
        if (command) {
          source.onlyFields({"bar_kind", "command", "every_ms", "timeout_ms", "render"});
          CommandArgumentsValidator::validate(source.field("command"));
        } else {
          if (kind.string() != "dynamic") {
            kind.fail("requires a render function or a command");
          }

          source.onlyFields({"bar_kind", "every_ms", "render"});
        }

        const auto setting = read(source, panel);
        const auto render = source.field("render");
        if ((!command || render.present()) && !render.is(LUA_TFUNCTION)) {
          render.fail("must be a function");
        }

        return setting;
      }
    };

  }
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
        static_cast<void>(SourceReader::dynamic(value));
      }

      return Source::content;
    }

    static constexpr std::size_t maximum_footer_slots = 3;
    const BasicActionValidator<Commands>& actions_;
    LimitNotices& limits_;
  };

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
      [[nodiscard]] inline static lua::Value content(const lua::Value& source) {
        return source.field("value");
      }

      // Hands `visit` each position `client.bars` sets with its source. A footer hands its three
      // slots, an empty one with a nil source.
      template <typename Visit>
      inline static void sources(const lua::Value& client, Visit&& visit) {
        const auto bars = client.field("bars");
        if (!bars.present()) {
          return;
        }

        const auto bottom = bars.field("bottom");
        if (bottom.present()) {
          constexpr std::array names{"left", "center", "right"};

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

// Interface: telar_config/binding_reader.cppm
export {
  namespace telar::runtime::config {

    // One `client.keybindings` entry as read; a prefixed binding starts with the prefix.
    struct BindingSetting {
      static constexpr std::size_t maximum_keys = 5;
      std::array<KeyChord, maximum_keys> keys{};
      std::size_t length = 0;
      bool prefixed = false;
      bool expression = false;
    };

    class BindingReader {
    public:
      static constexpr std::size_t maximum_bindings = BindingKeymap::maximum_bindings;

      // Hands the first maximum_bindings entries of `bindings` to `visit`, each with its action,
      // and returns how many it lists.
      template <typename Visit>
      inline static std::size_t read(const lua::Value& bindings, KeyChord prefix, Visit&& visit) {
        if (!bindings.present()) {
          return 0;
        }

        const auto listed = bindings.listLength();
        const auto count = std::min(listed, maximum_bindings);

        for (std::size_t index = 1; index <= count; ++index) {
          const auto binding = bindings.element(static_cast<lua_Integer>(index));

          binding.onlyFields({"keys", "action", "expression", "prefixed"});
          const auto prefixed = binding.field("prefixed");
          if (!prefixed.present()) {
            prefixed.fail("must be a boolean");
          }

          BindingSetting setting{.prefixed = prefixed.boolean(false)};
          const auto offset = static_cast<std::size_t>(setting.prefixed);
          const auto keys = binding.field("keys");
          const auto key_count = keys.listLength();
          if (key_count == 0 || key_count > BindingSetting::maximum_keys - offset) {
            keys.fail("has an invalid number of keys");
          }

          if (setting.prefixed) {
            setting.keys[0] = prefix;
          }

          setting.length = key_count + offset;
          for (std::size_t key = 0; key < key_count; ++key) {
            setting.keys[key + offset] = KeyChordValidator::parse(keys.element(static_cast<lua_Integer>(key) + 1));
          }

          setting.expression = binding.field("expression").boolean(false);
          visit(std::as_const(setting), binding.field("action"));
        }

        return listed;
      }
    };

    class BindingValidator {
    public:
      template <CommandTabStore Commands>
      inline static void validate(const lua::Value& bindings, const BasicActionValidator<Commands>& actions, BindingKeymap& keymap, LimitNotices& limits) {
        if (!bindings.present()) {
          return;
        }

        constexpr auto maximum_bindings = BindingReader::maximum_bindings;
        const auto listed = bindings.listLength();

        keymap.clear();
        if (listed > maximum_bindings) {
          limits.add({"config.max_bindings", "key bindings", maximum_bindings, listed, {}});
        }

        BindingReader::read(bindings, keymap.prefix(), [&](const BindingSetting& binding, const lua::Value& action) {
          BindingKeymap::Sequence sequence{.length = binding.length, .prefixed = binding.prefixed};

          std::ranges::copy(std::span{binding.keys}.first(std::min(binding.length, sequence.keys.size())), sequence.keys.begin());
          if (actions.validate(action, binding.expression)) {
            keymap.append(sequence);
          }
        });
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
      std::array<KeyChord, maximum_keys> keys{};
      std::size_t length = 0;
      // A view of the result's string, alive while the result is.
      std::string_view text;
    };

    // Reads what a binding's function returned.
    class CallbackResultReader {
    public:
      // Hands each of the first `maximum` actions of an action or an array of actions to `visit`
      // and returns how many it dropped past them.
      template <typename Visit>
      inline static std::size_t actions(const lua::Value& result, std::size_t maximum, Visit&& visit) {
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

      [[nodiscard]] inline static InputDecisionSetting decision(const lua::Value& result) {
        using Kind = InputDecisionSetting::Kind;

        const auto kind_value = result.field("input_kind");
        const auto kind = kind_value.string();
        InputDecisionSetting decision;

        if (kind == "consume" || kind == "forward") {
          result.onlyFields({"input_kind"});
          decision.kind = kind == "consume" ? Kind::consume : Kind::forward;
        } else if (kind == "keys") {
          result.onlyFields({"input_kind", "keys"});
          decision.kind = Kind::keys;
          keys(result.field("keys"), decision);
        } else if (kind == "paste") {
          result.onlyFields({"input_kind", "text"});
          decision.kind = Kind::paste;
          decision.text = result.field("text").string();
        } else {
          kind_value.fail("names an unknown input decision");
        }

        return decision;
      }

    private:
      template <typename Visit>
      inline static void action(const lua::Value& value, Visit& visit) {
        if (value.is(LUA_TFUNCTION)) {
          value.fail("cannot return a recursive callback");
        }

        visit(value);
      }

      inline static void keys(const lua::Value& keys, InputDecisionSetting& decision) {
        const auto count = keys.listLength();
        if (count == 0 || count > InputDecisionSetting::maximum_keys) {
          keys.fail("must contain one to sixteen keys");
        }

        for (std::size_t index = 0; index < count; ++index) {
          decision.keys[index] = KeyChordValidator::parse(keys.element(static_cast<lua_Integer>(index) + 1));
        }

        decision.length = count;
      }
    };

  }
}

// Interface: telar_config/pick_items_reader.cppm
export {
  namespace telar::runtime::config {

    // One pick option as listed: a label alone, or a table. The views are the list's strings.
    struct PickItemSetting {
      using Swatch = std::array<std::uint32_t, 3>;
      std::string_view label;
      std::optional<std::string_view> value;
      std::optional<std::string_view> detail;
      std::optional<Swatch> swatch;
      bool selected = false;
    };

    class PickItemsReader {
    public:
      // Hands each option of `items` to `visit` with its value, in order.
      template <typename Visit>
      inline static void read(const lua::Value& items, Visit&& visit) {
        const auto count = items.arraySize();

        for (std::size_t index = 1; index <= count; ++index) {
          const auto item = items.element(static_cast<lua_Integer>(index));
          const auto setting = option(item);

          visit(setting, item);
        }
      }

      // The options a pick definition lists.
      template <typename Visit>
      inline static void definition(const lua::Value& pick, Visit&& visit) {
        read(pick.field("items"), std::forward<Visit>(visit));
      }

    private:
      inline static PickItemSetting option(const lua::Value& item) {
        PickItemSetting setting;

        if (item.is(LUA_TSTRING)) {
          setting.label = item.string();
          return setting;
        }

        item.onlyFields({"label", "value", "detail", "selected", "swatch"});
        setting.label = item.field("label").string();
        if (const auto value = item.field("value"); value.present()) {
          setting.value = value.string();
        }

        if (const auto detail = item.field("detail"); detail.present()) {
          setting.detail = detail.string();
        }

        setting.selected = item.field("selected").boolean(false);
        setting.swatch = swatch(item.field("swatch"));
        return setting;
      }

      inline static std::optional<PickItemSetting::Swatch> swatch(const lua::Value& value) {
        if (!value.present()) {
          return std::nullopt;
        }

        PickItemSetting::Swatch result{};
        if (value.arraySize() != result.size()) {
          value.fail("must contain three RGB colors");
        }

        constexpr int hexadecimal_base = 16;

        for (std::size_t index = 0; index < result.size(); ++index) {
          const auto color = value.element(static_cast<lua_Integer>(index) + 1);

          hexadecimalColor(color);
          const auto text = color.string();
          const auto parsed = std::from_chars(text.data() + 1, text.data() + text.size(), result[index], hexadecimal_base);
          if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
            color.fail("must be an RGB color");
          }
        }

        return result;
      }
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
      std::size_t count = 0;

      PickItemsReader::read(items, [&](const PickItemSetting& option, const lua::Value& item) {
        keep(item, option.label, option.value.value_or(option.label), option.detail.value_or(std::string_view{}));
        ++count;
      });

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
      static constexpr Bounds<double> width_bounds{240, 720};
      static constexpr std::uint16_t default_width = 420;
      DefinitionHeading heading;
      std::uint16_t width = default_width;
      std::optional<UiMark> mark;
      // An icon name, as uiIcon admits it.
      std::optional<std::string_view> icon;
      SourceSetting source;
    };

    struct PickSetting {
      static constexpr Bounds<double> timeout_ms_bounds{100, 60'000};
      DefinitionHeading heading;
      std::uint32_t timeout_ms = SourceSetting::default_timeout_ms;
      // Whether a command lists the options, and whether a function renders them.
      bool command = false;
      bool render = false;
      bool refresh = true;
    };

    // How many panels and picks a client table defines, for each list it has.
    struct DefinitionCounts {
      std::optional<std::size_t> panels;
      std::optional<std::size_t> picks;
    };

    class ClientDefinitionsReader {
    public:
      // Validates and reads `client.panels` and `client.picks`, in name order, handing each
      // panel to `panel` with its source and each pick to `pick` with its definition.
      template <typename Panel, typename Pick>
      inline static DefinitionCounts read(const lua::Value& client, LimitNotices& limits, Panel&& panel, Pick&& pick) {
        DefinitionCounts counts;

        counts.panels = NamedDefinitionsValidator::validate(client.field("panels"), {"panels.max_panels", "panels", NamedDefinitionsValidator::maximum_definitions, {}, {}}, limits, [&](std::string_view name, const lua::Value& definition, std::size_t index) {
          definition.onlyFields({"panel_kind", "title", "mark", "icon", "width", "source", "refresh"});
          PanelSetting setting;

          setting.heading = {.name = name, .title = NamedDefinitionsValidator::heading(name, definition, limits)};
          const auto mark = definition.field("mark");
          if (mark.present()) {
            uiMark(mark);
            setting.mark = static_cast<UiMark>(std::ranges::find(ui_mark_names, mark.string()) - ui_mark_names.begin());
          }

          const auto icon = definition.field("icon");
          if (icon.present()) {
            uiIcon(icon);
            setting.icon = icon.string();
          }

          setting.width = static_cast<std::uint16_t>(definition.field("width").boundedInteger(PanelSetting::default_width, PanelSetting::width_bounds.minimum, PanelSetting::width_bounds.maximum));
          const auto source = definition.field("source");

          setting.source = SourceReader::dynamic(source, true);
          panel(index, std::as_const(setting), source);
        });

        counts.picks = NamedDefinitionsValidator::validate(client.field("picks"), {"picks.max_picks", "picks", NamedDefinitionsValidator::maximum_definitions, {}, {}}, limits, [&](std::string_view name, const lua::Value& definition, std::size_t index) {
          definition.onlyFields({"pick_kind", "title", "command", "items", "on_select", "timeout_ms", "refresh"});
          PickSetting setting;

          setting.heading = {.name = name, .title = NamedDefinitionsValidator::heading(name, definition, limits)};
          setting.timeout_ms = static_cast<std::uint32_t>(definition.field("timeout_ms").boundedInteger(SourceSetting::default_timeout_ms, PickSetting::timeout_ms_bounds.minimum, PickSetting::timeout_ms_bounds.maximum));
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

          setting.command = command.present();
          setting.render = items.is(LUA_TFUNCTION);
          setting.refresh = definition.field("refresh").boolean(true);
          pick(index, std::as_const(setting), definition);
        });

        return counts;
      }
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

    // `client.prefix` and `client.input`.
    struct ClientInputSettings {
      static constexpr Bounds<double> sequence_timeout_bounds{10, 10'000};
      std::optional<KeyChord> prefix;
      std::optional<std::uint16_t> sequence_timeout_ms;
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
        std::optional<bool> show_agent_commands;
        std::optional<HistoryEnter> enter;
        std::optional<HistoryMatch> match;
      };

      struct Sound {
        std::optional<bool> enabled;
        std::optional<bool> ready;
        std::optional<bool> needs_input;
      };

      std::optional<bool> sidebar_visible;
      std::optional<bool> pane_gaps;
      // Views of the configuration's strings, alive while its table is.
      std::optional<std::string_view> editor;
      std::optional<std::string_view> window_title;
      History history;
      Sound sound;
      std::optional<Delivery> delivery;
      ClientInputSettings input;
      PromptSettings prompt;
    };

    class ClientReader {
    public:
      static constexpr std::size_t maximum_editor_bytes = 4096;
      static constexpr std::size_t maximum_window_title_bytes = 128;

      // Hands each `client.prompt` binding to `binding` in order.
      template <typename Binding>
      [[nodiscard]] inline static ClientSettings read(const lua::Value& client, Binding&& binding) {
        ClientSettings settings;

        if (!client.present()) {
          return settings;
        }

        client.onlyFields({"prefix", "theme", "icons", "sidebar", "pane_gaps", "editor", "window_title", "sound", "notifications", "appearance", "input", "keybindings", "bars", "panels", "picks", "history", "components", "prompt"});
        settings.input = input(client);
        settings.pane_gaps = optionalBoolean(client.field("pane_gaps"));
        settings.editor = printableText(client.field("editor"), maximum_editor_bytes, false);
        settings.window_title = printableText(client.field("window_title"), maximum_window_title_bytes, true);
        sidebar(client.field("sidebar"), settings);
        sound(client.field("sound"), settings.sound);
        notifications(client.field("notifications"), settings);
        history(client.field("history"), settings.history);
        settings.prompt = PromptReader::read(client.field("prompt"), std::forward<Binding>(binding));
        return settings;
      }

      // Hands each `client.keybindings` entry to `visit` with its action, `prefix` in front of the
      // prefixed ones, and returns how many it lists, if it lists them.
      template <typename Visit>
      [[nodiscard]] inline static std::optional<std::size_t> bindings(const lua::Value& client, KeyChord prefix, Visit&& visit) {
        if (!listsBindings(client)) {
          return std::nullopt;
        }

        return BindingReader::read(client.field("keybindings"), prefix, std::forward<Visit>(visit));
      }

      // Hands each `client.components` function to `visit` with its index in component_slots.
      template <typename Visit>
      inline static void slots(const lua::Value& client, Visit&& visit) {
        const auto components = client.field("components");
        if (!components.present()) {
          return;
        }

        components.eachField([&](std::string_view name, const lua::Value& entry) {
          const auto* const found = std::ranges::find(component_slots, name);
          if (found == component_slots.end()) {
            const auto message = std::string{"names an unknown component slot \""} + std::string{name} + "\"";

            entry.fail(message.c_str());
          }

          if (!entry.is(LUA_TFUNCTION)) {
            entry.fail("must be a function from the context and the item to an element");
          }

          visit(static_cast<std::size_t>(found - component_slots.begin()), entry);
        });
      }

      // Whether the table lists keybindings, before `bindings` reads them.
      [[nodiscard]] inline static bool listsBindings(const lua::Value& client) {
        return client.present() && client.field("keybindings").present();
      }

      [[nodiscard]] inline static ClientInputSettings input(const lua::Value& client) {
        ClientInputSettings settings;

        if (!client.present()) {
          return settings;
        }

        const auto prefix = client.field("prefix");
        if (prefix.present()) {
          settings.prefix = KeyChordValidator::parse(prefix);
        }

        const auto table = client.field("input");
        if (table.present()) {
          table.onlyFields({"escape_timeout_ms", "sequence_timeout_ms"});
          const auto timeout = table.field("sequence_timeout_ms");
          if (timeout.present()) {
            constexpr auto bounds = ClientInputSettings::sequence_timeout_bounds;

            settings.sequence_timeout_ms = static_cast<std::uint16_t>(timeout.boundedInteger(bounds.minimum, bounds.minimum, bounds.maximum));
          }
        }

        return settings;
      }

    private:
      inline static std::optional<std::string_view> printableText(const lua::Value& value, std::size_t maximum, bool allow_empty) {
        if (!value.present()) {
          return std::nullopt;
        }

        optionalUtf8Text(value, maximum);
        const auto text = value.string();
        if ((!allow_empty && text.empty()) || std::ranges::any_of(text, [](unsigned char byte) {
              return byte < 0x20 || byte == 0x7f;
            })) {
          value.fail("must contain printable text");
        }

        return text;
      }

      inline static void sidebar(const lua::Value& table, ClientSettings& settings) {
        if (table.present()) {
          table.onlyFields({"visible", "renderer"});
          settings.sidebar_visible = optionalBoolean(table.field("visible"));
        }
      }

      inline static void sound(const lua::Value& table, ClientSettings::Sound& sound) {
        if (table.present()) {
          table.onlyFields({"enabled", "ready", "needs_input"});
          sound.enabled = optionalBoolean(table.field("enabled"));
          sound.ready = optionalBoolean(table.field("ready"));
          sound.needs_input = optionalBoolean(table.field("needs_input"));
        }
      }

      inline static void notifications(const lua::Value& table, ClientSettings& settings) {
        if (table.present()) {
          table.onlyFields({"delivery"});
          settings.delivery = optionalChoice<ClientSettings::Delivery>(table.field("delivery"), std::array<std::string_view, 3>{"telar", "system", "terminal"});
        }
      }

      inline static void history(const lua::Value& table, ClientSettings::History& history) {
        if (table.present()) {
          table.onlyFields({"show_agent_commands", "enter", "match"});
          history.show_agent_commands = optionalBoolean(table.field("show_agent_commands"));
          history.enter = optionalChoice<ClientSettings::HistoryEnter>(table.field("enter"), std::array<std::string_view, 2>{"paste", "run"});
          history.match = optionalChoice<ClientSettings::HistoryMatch>(table.field("match"), std::array<std::string_view, 2>{"fuzzy", "fts"});
        }
      }
    };

    class ClientValidator {
    public:
      template <CommandTabStore Commands>
      inline static void validate(const lua::Value& client, LimitNotices& limits, BasicClientValidationState<Commands>& state, const lua::Value* inherited = nullptr) {
        if (!client.present()) {
          return;
        }

        const auto settings = ClientReader::read(client, [](const PromptBindingSetting&) {});
        if (settings.input.prefix) {
          state.keymap.setPrefix(*settings.input.prefix);
        }

        static_cast<void>(ClientDefinitionsReader::read(client, limits, [](std::size_t, const PanelSetting&, const lua::Value&) {}, [](std::size_t, const PickSetting&, const lua::Value&) {}));
        const ClientDefinitions definitions{client, inherited};
        const BasicActionValidator actions{definitions, limits, state.commands};

        BindingValidator::validate(client.field("keybindings"), actions, state.keymap, limits);
        BarsValidator{actions, limits}.validate(client.field("bars"));
        ClientReader::slots(client, [](std::size_t, const lua::Value&) {});
      }
    };

  }
}
