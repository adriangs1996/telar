module;
#include "tbc/view.hpp"
#include <exception>
#include <memory>
#include <type_traits>
#include <variant>
#include <vector>
#include <bit>
#include <cstdlib>
#include <mutex>
#include <new>

#include <algorithm>
#include <array>
#include <cinttypes>
#include <cstdio>

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <cmath>
#include <initializer_list>
#include <optional>
#include <string>

#include <cstddef>
#include <cstdint>
#include <limits>

#include <span>

#include <concepts>

#include <ghostty/vt/unicode.h>

#include <format>

#include <utility>

#include "telar_config/terminal/control/policy.hpp"

#include <limits.h>
#include <sys/stat.h>

#include <arpa/inet.h>

#include "telar_config/graphics/limits.hpp"

export module telar.config;

export import telar.lua;


export import telar.base.text;


export import telar.platform;


export import telar.plugins;
import telar.base.diagnostics;
import telar.client.protocol;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime {
using telar::runtime::GraphicsLimits;
}
export namespace telar::runtime::control {
using telar::runtime::control::Access;
using telar::runtime::control::ColorFormat;
using telar::runtime::control::Policy;
}


// Interface: telar_config/limit_notices.cppm
export {
namespace telar::runtime::config {

// The notices view the names of the limits they are told about, usually literals, in region `a`.
class LimitNotices {
public:
  inline void add(tbc::view<const LimitReach &, tbc::lt::a> reach) noexcept {
    for (auto &entry : std::span{entries_}.first(count_)) {
      if (entry.name == reach.name) {
        if (reach.requested) {
          entry.requested = std::max(entry.requested.value_or(0), *reach.requested);
        }
        return;
      }
    }
    if (count_ == entries_.size()) {
      return;
    }

    entries_[count_++] = reach;
  }

  inline std::span<const LimitReach> entries() const noexcept {
    return std::span{entries_}.first(count_);
  }

  inline void print() const noexcept {
    for (const auto &entry : entries()) {
      std::fprintf(stderr, "telar config: limit reached, the excess was left out: %.*s: ", static_cast<int>(entry.name.size()), entry.name.data());
      const auto *separator = entry.noun.empty() ? "" : " ";
      if (entry.requested) {
        std::fprintf(stderr, "%" PRIu64 "%s%.*s; limit %" PRIu64 "\n", *entry.requested, separator, static_cast<int>(entry.noun.size()), entry.noun.data(), entry.value);
      } else if (entry.value == 0) {
        std::fputs("limit reached\n", stderr);
      } else {
        std::fprintf(stderr, "limit %" PRIu64 "%s%.*s reached\n", entry.value, separator, static_cast<int>(entry.noun.size()), entry.noun.data());
      }
    }
  }

private:
  tbc::view<std::array<LimitReach, 16>, tbc::lt::a> entries_{};
  std::size_t count_ = 0;
};

}
}

// Interface: telar_config/value_constraints.cppm
export {
namespace telar::runtime::config {

inline void optionalChoice(const lua::Value &value, std::initializer_list<std::string_view> choices) {
  if (!value.present()) {
    return;
  }

  const auto text = value.string();
  if (std::find(choices.begin(), choices.end(), text) == choices.end()) {
    value.fail("is not a supported value");
  }
}

inline void optionalWholeNumber(const lua::Value &value, double minimum, double maximum) {
  const auto number = value.boundedNumber(minimum, minimum, maximum);
  if (std::trunc(number) != number) {
    value.fail("must be a whole number");
  }
}

inline void optionalUtf8Text(const lua::Value &value, std::size_t maximum_bytes) {
  if (!value.present()) {
    return;
  }

  const auto text = value.string();
  validateUtf8(text);
  if (text.size() > maximum_bytes || text.contains('\0')) {
    value.fail("exceeds its text bounds or contains NUL");
  }
}

}
}

// Interface: telar_config/ui_value_constraints.cppm
export {
namespace telar::runtime::config {

inline void printableUiText(const lua::Value &source, std::string_view text, bool allow_tab = false) {
  validateUtf8(text);
  if (std::ranges::any_of(text, [allow_tab](unsigned char byte) { return (byte < 0x20 && !(allow_tab && byte == '\t')) || byte == 0x7f; })) {
    source.fail("must contain printable text");
  }
}

inline tbc::view<std::string_view, tbc::lt::a> fittedUiText(tbc::view<std::string_view, tbc::lt::a> text, tbc::view<LimitReach, tbc::lt::b> reach, tbc::view<LimitNotices &, tbc::lt::b> limits) {
  if (text.size() > reach.value) {
    reach.requested = text.size();
    limits.add(reach);
  }
  return utf8Prefix(text, reach.value);
}

inline bool equalUiName(std::string_view left, std::string_view right) noexcept {
  return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin(), [](char byte, char expected) { return (byte == '-' ? '_' : asciiLower(byte)) == expected; });
}

inline void uiIcon(const lua::Value &value) {
  constexpr std::string_view names[]{"sidebar_collapse", "sidebar_expand", "workspace_menu", "proxy_active", "cpu", "memory", "battery_empty", "battery_quarter", "battery_half", "battery_three_quarters", "battery_full", "provider_unknown", "provider_claude", "provider_codex", "provider_pi", "provider_cursor", "provider_opencode", "app_terminal", "app_editor", "app_git", "agent_unknown", "agent_working_0", "agent_working_1", "agent_working_2", "agent_working_3", "agent_blocked", "agent_ready", "agent_done", "agent_failed", "close", "pane_fullscreen", "telar_mark"};
  const auto text = value.string();
  if (!std::ranges::any_of(names, [text](std::string_view name) { return equalUiName(text, name); })) {
    value.fail("names an unknown icon");
  }
}

inline void uiMark(const lua::Value &value) {
  value.string();
  optionalChoice(value, {"claude", "codex", "pi", "telar"});
}

inline void hexadecimalColor(const lua::Value &value) {
  const auto text = value.string();
  if (text.size() != 7 || text.front() != '#' || !std::ranges::all_of(text.substr(1), [](char byte) { return (byte >= '0' && byte <= '9') || (asciiLower(byte) >= 'a' && asciiLower(byte) <= 'f'); })) {
    value.fail("must be an RGB hexadecimal color");
  }
}

}
}

// Interface: telar_config/named_definitions_validator.cppm
export {
namespace telar::runtime::config {

class NamedDefinitionsValidator {
public:
  template <typename Validator>
  inline static void validate(const lua::Value &table, tbc::view<LimitReach, tbc::lt::b> reach, tbc::view<LimitNotices &, tbc::lt::b> limits, Validator &&validate_definition) {
    if (!table.present()) {
      return;
    }

    std::array<std::string_view, maximum_definitions> names;
    std::size_t kept = 0;
    std::size_t total = 0;
    table.eachField([&](std::string_view name, const lua::Value &) {
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

  inline static void heading(std::string_view name, const lua::Value &definition, LimitNotices &limits) {
    if (name.empty() || name.size() > maximum_name_bytes || !std::ranges::all_of(name, [](unsigned char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-'; })) {
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
}

// Interface: telar_config/client_definitions.cppm
export {
namespace telar::runtime::config {

class ClientDefinitions {
public:
  inline explicit ClientDefinitions(const lua::Value &client, const lua::Value *inherited = nullptr)
      : client_(client),
        inherited_(inherited) {}

  inline bool contains(const char *section, std::string_view name) const {
    return index(section, name).has_value();
  }

  inline std::optional<std::uint8_t> index(const char *section, std::string_view name) const {
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
  inline static std::optional<std::uint8_t> indexOf(const lua::Value &definitions, std::string_view name) {
    if (!definitions.present()) {
      return std::nullopt;
    }

    bool found = false;
    std::size_t preceding = 0;
    definitions.eachField([&](std::string_view candidate, const lua::Value &) {
      found |= candidate == name;
      preceding += candidate < name;
    });
    if (!found) {
      return std::nullopt;
    }
    return preceding < NamedDefinitionsValidator::maximum_definitions ? static_cast<std::uint8_t>(preceding) : std::numeric_limits<std::uint8_t>::max();
  }

  const lua::Value &client_;
  const lua::Value *inherited_;
};

}
}

// Interface: telar_config/command_tab_reference.cppm
export {
namespace telar::runtime::config {

struct CommandTabReference {
  std::uint32_t epoch = 0;
  std::uint16_t id = 0;

  bool operator==(const CommandTabReference &) const = default;
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

  inline bool keep(std::span<const std::string_view> arguments, std::string_view label, LimitNotices &limits) {
    return keepReference(arguments, label, limits).has_value();
  }

  inline std::optional<CommandTabReference> keepReference(std::span<const std::string_view> arguments, std::string_view label, LimitNotices &limits) {
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

  inline bool admit(std::size_t length, LimitNotices &limits) noexcept {
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
concept CommandTabStore = requires(Store &store, std::span<const std::string_view> arguments, std::string_view label, LimitNotices &limits) {
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
  inline explicit BasicActionValidator(tbc::view<const ClientDefinitions &, tbc::lt::b> definitions, tbc::view<LimitNotices &, tbc::lt::b> limits, tbc::view<Commands &, tbc::lt::b> commands)
      : definitions_(definitions),
        limits_(limits),
        commands_(commands) {}

  inline bool validate(const lua::Value &action, bool expression = false) const {
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

  inline bool component(const lua::Value &action) const {
    if (action.is(LUA_TFUNCTION)) {
      action.fail("cannot be a callback in a static component");
    }
    return validate(action);
  }

private:
  inline static void builtin(const lua::Value &value) {
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
    if (number.empty() || number.front() == '_' || number.back() == '_') {
      return false;
    }

    unsigned index = 0;
    for (const auto byte : number) {
      if (byte == '_') {
        continue;
      }
      if (byte < '0' || byte > '9') {
        return false;
      }
      index = index * 10 + static_cast<unsigned>(byte - '0');
      if (index > UINT8_MAX) {
        return false;
      }
    }
    return index != 0;
  }

  inline static void requiredInteger(const lua::Value &value, lua_Integer minimum, lua_Integer maximum) {
    const auto integer = value.integer();
    if (integer < minimum || integer > maximum) {
      value.fail("is outside its bounds");
    }
  }

  inline static void direction(const lua::Value &action, std::initializer_list<std::string_view> choices) {
    action.onlyFields({"kind", "direction"});
    const auto direction = action.field("direction");
    direction.string();
    optionalChoice(direction, choices);
  }

  inline void reference(const lua::Value &action, const char *field, const char *section) const {
    action.onlyFields({"kind", field});
    const auto value = action.field(field);
    if (!definitions_.contains(section, value.string())) {
      value.fail("names an unknown client definition");
    }
  }

  inline bool commandTab(const lua::Value &action) const {
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

  inline void notification(const lua::Value &action) const {
    action.onlyFields({"kind", "title", "body", "level", "duration_ms", "pane_id", "tab_id", "workspace_id"});
    optionalChoice(action.field("level"), {"info", "success", "warning", "failure"});
    NotificationBody body{.duration_ms = static_cast<std::uint32_t>(action.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms))};
    const auto title = action.field("title");
    const auto message = action.field("body");
    body.title = fitted(title.string(), {"notifications.max_title_bytes", "bytes", max_notification_title_bytes, {}, {}});
    body.message = message.present() ? fitted(message.string(), {"notifications.max_message_bytes", "bytes", max_notification_message_bytes, {}, {}}) : std::string_view{};
    unsigned target_count = 0;
    for (const auto *name : {"pane_id", "tab_id", "workspace_id"}) {
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

  tbc::view<const ClientDefinitions &, tbc::lt::b> definitions_;
  tbc::view<LimitNotices &, tbc::lt::b> limits_;
  tbc::view<Commands &, tbc::lt::b> commands_;
};

using RetainedActionValidator = BasicActionValidator<RetainedCommandTabRegistry>;

}
}

// Interface: telar_config/agents/evidence.cppm
export {
namespace telar::runtime {

struct AgentSignal {
  AgentProvider provider = AgentProvider::unknown;
  AgentStatus status = AgentStatus::unknown;
  Byte confidence = 0;
  bool identity_confirmed = false;
  bool ready_confirmed = false;

  bool operator==(const AgentSignal &) const = default;
};

struct AgentEvidence {
  AgentProvider provider = AgentProvider::unknown;
  AgentStatus status = AgentStatus::unknown;
  AgentSource source = AgentSource::screen;
  Byte confidence = 0;
  ObservationTime observed;
  std::int64_t expires_at = 0;

  inline bool expired(std::int64_t now) const noexcept {
    return expires_at <= now;
  }

  inline static AgentEvidence process(AgentProvider provider, ObservationTime now) noexcept {
    return {provider, AgentStatus::ready, AgentSource::foreground_process, 100, now, std::numeric_limits<std::int64_t>::max()};
  }

  inline static AgentEvidence screen(AgentProvider provider, AgentSignal signal, ObservationTime now) noexcept {
    return {provider, signal.status, AgentSource::screen, signal.confidence, now, now.milliseconds + (signal.status == AgentStatus::working ? screen_working_expiry : settled_expiry).count()};
  }

  inline static AgentEvidence report(AgentProvider provider, AgentReportState state, ObservationTime now) noexcept {
    const bool working = state == AgentReportState::working || state == AgentReportState::waiting || state == AgentReportState::settling;
    const auto expiry = working ? (state == AgentReportState::settling ? screen_working_expiry : report_working_expiry) : settled_expiry;
    const auto status = working ? AgentStatus::working : state == AgentReportState::blocked ? AgentStatus::blocked
                                                                                            : AgentStatus::ready;
    return {provider, status, AgentSource::lifecycle_report, 100, now, now.milliseconds + expiry.count()};
  }

  static constexpr std::chrono::milliseconds screen_working_expiry{120'000};
  static constexpr std::chrono::milliseconds report_working_expiry{600'000};
  static constexpr std::chrono::milliseconds settled_expiry{1'800'000};
  static constexpr std::chrono::milliseconds renewal_margin{300'000};
};

inline bool completionRequiresSignal(AgentProvider provider) noexcept {
  return provider == AgentProvider::codex || provider == AgentProvider::pi || provider == AgentProvider::cursor || provider == AgentProvider::opencode;
}

}
}

// Interface: telar_config/agents/provider.cppm
export {
namespace telar::runtime {

struct ProviderDescription {
  std::string_view name;
  std::string_view display_name;
  std::string_view placeholder;
  AgentAttachmentMarkers attachments;
  std::array<std::string_view, 2> process_names;
};

inline ProviderDescription describeProvider(AgentProvider provider) noexcept {
  switch (provider) {
  case AgentProvider::claude:
    return {.name = "claude", .display_name = "Claude Code", .placeholder = "New Claude Code session", .attachments = AgentAttachmentMarkers::stable_number, .process_names = {"claude", "claude-code"}};
  case AgentProvider::codex:
    return {.name = "codex", .display_name = "Codex", .placeholder = "New Codex session", .attachments = AgentAttachmentMarkers::ordered, .process_names = {"codex", {}}};
  case AgentProvider::pi:
    return {.name = "pi", .display_name = "Pi", .placeholder = "New Pi session", .attachments = AgentAttachmentMarkers::pasted_path, .process_names = {"pi", {}}};
  case AgentProvider::cursor:
    return {.name = "cursor", .display_name = "Cursor Agent", .placeholder = "New Cursor Agent session", .attachments = AgentAttachmentMarkers::none, .process_names = {"cursor-agent", {}}};
  case AgentProvider::opencode:
    return {.name = "opencode", .display_name = "OpenCode", .placeholder = "New OpenCode session", .attachments = AgentAttachmentMarkers::none, .process_names = {"opencode", {}}};
  default:
    return {.name = "", .display_name = "", .placeholder = "New agent session", .attachments = AgentAttachmentMarkers::none, .process_names = {}};
  }
}

inline AgentProvider builtinProviderFromExecutable(std::string_view name) noexcept {
  const auto stem = withoutExecutableSuffix(name);
  for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
    for (const auto process : describeProvider(provider).process_names) {
      if (!process.empty() && asciiEqualIgnoreCase(stem, process)) {
        return provider;
      }
    }
  }

  return AgentProvider::unknown;
}

inline AgentProvider providerNamed(std::string_view name) noexcept {
  for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
    if (describeProvider(provider).name == name) {
      return provider;
    }
  }

  return AgentProvider::unknown;
}

}
}

// Interface: telar_config/agents/manifest.cppm
export {
namespace telar::runtime {

inline bool containsInsensitive(std::string_view text, std::string_view phrase) noexcept {
  if (phrase.empty() || phrase.size() > text.size()) {
    return false;
  }

  for (std::size_t offset = 0; offset <= text.size() - phrase.size(); ++offset) {
    if (std::equal(phrase.begin(), phrase.end(), text.begin() + offset, [](char left, char right) { return asciiLower(left) == asciiLower(right); })) {
      return true;
    }
  }

  return false;
}

template <std::size_t Capacity, std::size_t TextCapacity>
class ManifestTextList {
public:
  inline void append(std::string_view text) {
    if (text.empty() || text.size() > TextCapacity || count_ == Capacity) {
      throw EncodingError{"Agent manifest list exceeds its bounds"};
    }

    entries_[count_++].assign(text);
  }

  inline bool matches(std::string_view text) const noexcept {
    return std::ranges::any_of(entries(), [&](const auto &phrase) { return containsInsensitive(text, phrase.view()); });
  }

  inline std::span<const FixedText<TextCapacity>> entries() const noexcept {
    return std::span{entries_}.first(count_);
  }

private:
  std::array<FixedText<TextCapacity>, Capacity> entries_;
  std::size_t count_ = 0;
};

enum class AgentInterruptKey {
  none,
  escape,
  escape_twice,
  control_c
};

struct AgentCommandTool {
  FixedText<64> tool;
  FixedText<32> field;
};

struct AgentManifest {
  inline void addCommandTool(std::string_view name, std::string_view field) {
    if (name.empty() || name.size() > 64 || field.empty() || field.size() > 32 || tool_count == command_tools.size()) {
      throw EncodingError{"Invalid agent command tool"};
    }

    command_tools[tool_count].tool.assign(name);
    command_tools[tool_count].field.assign(field);
    ++tool_count;
  }

  inline std::string_view commandField(std::string_view tool) const noexcept {
    for (const auto &mapping : std::span{command_tools}.first(tool_count)) {
      if (mapping.tool.view() == tool) {
        return mapping.field.view();
      }
    }

    return {};
  }

  inline std::string_view displayName() const noexcept {
    return display_name.view().empty() ? name.view() : display_name.view();
  }

  // The manifest's own placeholder, or one built in the caller's storage.
  inline tbc::view<std::string_view, tbc::lt::a> placeholderTitle(tbc::view<FixedText<96> &, tbc::lt::a> storage) const {
    if (!placeholder.view().empty()) {
      return placeholder.view();
    }

    std::array<char, 96> bytes{};
    const auto display = displayName();
    std::memcpy(bytes.data(), "New ", 4);
    std::memcpy(bytes.data() + 4, display.data(), display.size());
    std::memcpy(bytes.data() + 4 + display.size(), " session", 8);
    storage.assign({bytes.data(), display.size() + 12});
    return storage.view();
  }

  AgentProvider provider = AgentProvider::unknown;
  tbc::view<FixedText<32>, tbc::lt::a> name;
  tbc::view<FixedText<32>, tbc::lt::a> display_name;
  tbc::view<FixedText<96>, tbc::lt::a> placeholder;
  FixedText<8> icon;
  AgentAttachmentMarkers attachments = AgentAttachmentMarkers::none;
  AgentInterruptKey interrupt = AgentInterruptKey::none;
  ManifestTextList<8, 128> process_names;
  ManifestTextList<8, 128> process_paths;
  ManifestTextList<16, 64> brand;
  ManifestTextList<16, 64> identity;
  ManifestTextList<16, 64> working;
  ManifestTextList<16, 64> blocked;
  ManifestTextList<16, 64> ready_prompt;
  std::array<AgentCommandTool, 8> command_tools;
  std::size_t tool_count = 0;
};

class AgentManifests {
public:
  inline AgentManifest &add(std::string_view name) {
    auto *manifest = tryAdd(name);
    if (manifest == nullptr) {
      throw EncodingError{"Too many agent manifests"};
    }

    return *manifest;
  }

  inline AgentManifest *tryAdd(std::string_view name) {
    if (name.empty() || name.size() > 32 || !std::ranges::all_of(name, [](char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '.'; })) {
      throw EncodingError{"Invalid agent manifest name"};
    }

    const auto builtin = providerNamed(name);
    for (auto &entry : std::span{entries_}.first(count_)) {
      if (entry.name.view() == name) {
        if (builtin == AgentProvider::unknown) {
          throw EncodingError{"Duplicate agent manifest"};
        }

        return &entry;
      }
    }

    if (count_ >= entries_.size() || (builtin == AgentProvider::unknown && custom_count_ >= maximum_custom_agents)) {
      return nullptr;
    }

    auto &entry = entries_[count_++];
    entry.provider = builtin == AgentProvider::unknown ? static_cast<AgentProvider>(first_custom_provider + custom_count_++) : builtin;
    entry.name.assign(name);
    return &entry;
  }

  inline const AgentManifest *find(AgentProvider provider) const noexcept {
    for (const auto &entry : entries()) {
      if (entry.provider == provider) {
        return &entry;
      }
    }

    return nullptr;
  }

  inline AgentProvider named(std::string_view name) const noexcept {
    for (const auto &entry : entries()) {
      if (entry.name.view() == name) {
        return entry.provider;
      }
    }

    return AgentProvider::unknown;
  }

  inline AgentProvider fromExecutable(std::string_view name) const noexcept {
    const auto stem = withoutExecutableSuffix(name);
    for (const auto &entry : entries()) {
      for (const auto &candidate : entry.process_names.entries()) {
        if (asciiEqualIgnoreCase(stem, candidate.view())) {
          return entry.provider;
        }
      }
    }

    return AgentProvider::unknown;
  }

  inline AgentProvider fromPath(std::string_view path) const noexcept {
    for (const auto &entry : entries()) {
      if (entry.process_paths.matches(path)) {
        return entry.provider;
      }
    }

    return AgentProvider::unknown;
  }

  inline std::optional<AgentSignal> detect(std::string_view text) const noexcept {
    for (const auto &entry : entries()) {
      if (entry.blocked.matches(text)) {
        return AgentSignal{inferProvider(text), AgentStatus::blocked, 88};
      }
    }

    for (const auto &entry : entries()) {
      if (entry.working.matches(text)) {
        return AgentSignal{inferProvider(text), AgentStatus::working, 78};
      }
    }

    for (const auto &entry : entries()) {
      if (entry.ready_prompt.matches(text)) {
        return AgentSignal{entry.provider, AgentStatus::ready, 94, true, true};
      }
    }

    for (const auto &entry : entries()) {
      if (entry.identity.matches(text)) {
        return AgentSignal{entry.provider, AgentStatus::ready, 90, true, false};
      }
    }

    return std::nullopt;
  }

  inline std::span<const AgentManifest> entries() const noexcept {
    return std::span{entries_}.first(count_);
  }

private:
  inline AgentProvider inferProvider(std::string_view text) const noexcept {
    for (const auto &entry : entries()) {
      if (entry.brand.matches(text)) {
        return entry.provider;
      }
    }

    return AgentProvider::unknown;
  }

  static constexpr Byte first_custom_provider = first_custom_agent_provider;
  static constexpr Byte maximum_custom_agents = max_agent_provider_index - first_custom_provider + 1;
  std::array<AgentManifest, 32> entries_;
  std::size_t count_ = 0;
  Byte custom_count_ = 0;
};

}
}

// Interface: telar_config/agent_reader.cppm
export {
namespace telar::runtime::config {

class AgentReader {
public:
  // Fills the manifests and tells the notices about limits it reaches, region `a`.
  inline explicit AgentReader(tbc::view<AgentManifests &, tbc::lt::a> manifests, tbc::view<LimitNotices &, tbc::lt::a> limits)
      : manifests_(manifests),
        limits_(limits) {}

  inline void read(const lua::Value &agents) {
    if (!agents.present()) {
      return;
    }

    const auto count = agents.arraySize();
    std::size_t dropped = 0;
    for (std::size_t position = 1; position <= count; ++position) {
      const auto entry = agents.element(static_cast<lua_Integer>(position));
      entry.onlyFields({"name", "process_names", "process_paths", "brand", "identity", "working", "blocked", "ready_prompt", "display_name", "placeholder", "icon", "attachments", "command_tools"});
      auto *manifest = manifests_.tryAdd(entry.field("name").string());
      if (manifest == nullptr) {
        ++dropped;
        continue;
      }

      paths(entry.field("process_names"), manifest->process_names);
      paths(entry.field("process_paths"), manifest->process_paths);
      phrases(entry.field("brand"), manifest->brand);
      phrases(entry.field("identity"), manifest->identity);
      phrases(entry.field("working"), manifest->working);
      phrases(entry.field("blocked"), manifest->blocked);
      phrases(entry.field("ready_prompt"), manifest->ready_prompt);
      commandTools(entry.field("command_tools"), *manifest);
      presentation(entry, *manifest);
    }
    if (dropped != 0) {
      limits_.add({"agent_manifest.max_custom_agents", "agents", 27, 27 + dropped, {}});
    }
  }

private:
  inline static tbc::view<std::string_view, tbc::lt::a> printable(const lua::Value &value) {
    const auto text = value.string();
    validateUtf8(text);
    if (text.empty() || std::ranges::any_of(text, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; })) {
      value.fail("must be a printable string");
    }

    return text;
  }

  template <std::size_t Capacity, std::size_t TextCapacity>
  inline void list(const lua::Value &value, ManifestTextList<Capacity, TextCapacity> &destination, tbc::view<LimitReach, tbc::lt::a> entries_limit, tbc::view<LimitReach, tbc::lt::a> bytes_limit) {
    if (!value.present()) {
      return;
    }

    const auto count = value.arraySize();
    for (std::size_t position = 1; position <= count; ++position) {
      const auto text = printable(value.element(static_cast<lua_Integer>(position)));
      if (text.size() > TextCapacity) {
        bytes_limit.requested = text.size();
        limits_.add(bytes_limit);
      } else if (destination.entries().size() == Capacity) {
        entries_limit.requested = Capacity + count - position + 1;
        limits_.add(entries_limit);
        return;
      } else {
        destination.append(text);
      }
    }
  }

  inline void paths(const lua::Value &value, ManifestTextList<8, 128> &destination) {
    list(value, destination, {"agent_manifest.max_paths", "entries", 8, {}, {}}, {"agent_manifest.max_path_bytes", "bytes", 128, {}, {}});
  }

  inline void phrases(const lua::Value &value, ManifestTextList<16, 64> &destination) {
    list(value, destination, {"agent_manifest.max_phrases", "phrases", 16, {}, {}}, {"agent_manifest.max_phrase_bytes", "bytes", 64, {}, {}});
  }

  inline void commandTools(const lua::Value &value, AgentManifest &manifest) {
    if (!value.present()) {
      return;
    }

    const auto count = value.arraySize();
    for (std::size_t position = 1; position <= count; ++position) {
      const auto mapping = value.element(static_cast<lua_Integer>(position));
      mapping.onlyFields({"tool", "field"});
      const auto tool = mapping.field("tool").string();
      const auto field = mapping.field("field").string();
      if (tool.empty() || field.empty()) {
        mapping.fail("requires nonempty tool and field strings");
      }
      if (tool.size() > 64 || field.size() > 32) {
        if (tool.size() > 64) {
          limits_.add({"agent_manifest.max_tool_name_bytes", "bytes", 64, tool.size(), {}});
        }
        if (field.size() > 32) {
          limits_.add({"agent_manifest.max_command_field_bytes", "bytes", 32, field.size(), {}});
        }
      } else if (manifest.tool_count == manifest.command_tools.size()) {
        limits_.add({"agent_manifest.max_command_tools", "command tools", 8, 8 + count - position + 1, {}});
        return;
      } else {
        manifest.addCommandTool(tool, field);
      }
    }
  }

  template <std::size_t Capacity>
  inline static void text(const lua::Value &value, FixedText<Capacity> &destination) {
    if (value.present()) {
      destination.assign(printable(value));
    }
  }

  inline static unsigned iconWidth(std::string_view text) noexcept {
    std::array<std::uint32_t, 8> codepoints;
    std::size_t count = 0;
    for (std::size_t offset = 0; offset < text.size();) {
      const auto lead = static_cast<unsigned char>(text[offset++]);
      const unsigned continuation = lead < 0x80 ? 0 : lead < 0xe0 ? 1
                                                  : lead < 0xf0   ? 2
                                                                  : 3;
      std::uint32_t codepoint = continuation == 0 ? lead : lead & (0x7f >> continuation);
      for (unsigned index = 0; index < continuation; ++index) {
        codepoint = (codepoint << 6) | (static_cast<unsigned char>(text[offset++]) & 0x3f);
      }
      codepoints[count++] = codepoint;
    }

    unsigned width = 0;
    for (std::size_t offset = 0; offset < count;) {
      std::uint8_t cluster_width = 0;
      offset += ghostty_unicode_grapheme_width(codepoints.data() + offset, count - offset, &cluster_width);
      width += std::max<unsigned>(1, cluster_width);
    }

    return width;
  }

  inline static void presentation(const lua::Value &entry, AgentManifest &manifest) {
    text(entry.field("display_name"), manifest.display_name);
    text(entry.field("placeholder"), manifest.placeholder);
    const auto icon = entry.field("icon");
    if (icon.present()) {
      const auto value = printable(icon);
      if (value.size() > 8 || iconWidth(value) != 1) {
        icon.fail("must fit in eight bytes and exactly one cell");
      }

      manifest.icon.assign(value);
    }

    const auto attachments = entry.field("attachments");
    if (!attachments.present()) {
      return;
    }

    const auto policy = printable(attachments);
    for (const auto &[name, kind] : std::array<std::pair<std::string_view, AgentAttachmentMarkers>, 4>{{{"none", AgentAttachmentMarkers::none}, {"ordered", AgentAttachmentMarkers::ordered}, {"stable_number", AgentAttachmentMarkers::stable_number}, {"pasted_path", AgentAttachmentMarkers::pasted_path}}}) {
      if (name == policy) {
        manifest.attachments = kind;
        return;
      }
    }

    attachments.fail("must be none, ordered, stable_number or pasted_path");
  }

  tbc::view<AgentManifests &, tbc::lt::a> manifests_;
  tbc::view<LimitNotices &, tbc::lt::a> limits_;
};

}
}

// Interface: telar_config/agents/builtin_manifests.cppm
export {
namespace telar::runtime {

inline AgentManifests makeBuiltinManifests() {
  AgentManifests table;
  for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
    const auto description = describeProvider(provider);
    auto &manifest = table.add(description.name);
    manifest.display_name.assign(description.display_name);
    manifest.attachments = description.attachments;
    manifest.interrupt = AgentInterruptKey::escape;
    for (const auto process : description.process_names) {
      if (!process.empty()) {
        manifest.process_names.append(process);
      }
    }
  }

  auto &claude = table.add("claude");
  claude.process_paths.append("/@anthropic-ai/claude-code/");
  claude.process_paths.append("\\@anthropic-ai\\claude-code\\");
  claude.brand.append("claude");
  claude.identity.append("claude code");
  claude.addCommandTool("Bash", "command");
  claude.interrupt = AgentInterruptKey::control_c;
  for (const auto phrase : {"press enter to confirm", "enter to submit answer", "enter to select", "allow command?", "[y/n]", "do you want to proceed?", "waiting for permission", "yes, and don't ask again"}) {
    claude.blocked.append(phrase);
  }

  for (const auto phrase : {"esc to interrupt", "working (", "waiting for background agents", "tasks still running", "background shells"}) {
    claude.working.append(phrase);
  }

  auto &codex = table.add("codex");
  codex.process_paths.append("/@openai/codex/");
  codex.process_paths.append("\\@openai\\codex\\");
  codex.brand.append("codex");
  codex.ready_prompt.append("ask codex to do anything");
  codex.addCommandTool("Bash", "command");
  codex.addCommandTool("exec_command", "cmd");
  codex.addCommandTool("shell", "command");

  auto &pi = table.add("pi");
  pi.process_paths.append("/@earendil-works/pi-coding-agent/");
  pi.process_paths.append("\\@earendil-works\\pi-coding-agent\\");
  pi.process_paths.append("/@mariozechner/pi-coding-agent/");
  pi.process_paths.append("\\@mariozechner\\pi-coding-agent\\");
  pi.addCommandTool("bash", "command");

  auto &cursor = table.add("cursor");
  cursor.process_paths.append("/cursor-agent/versions/");
  cursor.addCommandTool("Shell", "command");
  for (const auto phrase : {"not in allowlist:", "skip & tell the agent what to do instead", "yes, build locally", "do you trust the contents of this directory?"}) {
    cursor.blocked.append(phrase);
  }

  auto &opencode = table.add("opencode");
  opencode.interrupt = AgentInterruptKey::escape_twice;
  opencode.addCommandTool("bash", "command");
  return table;
}

inline const AgentManifests builtin_manifests = makeBuiltinManifests();

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
  divider
};

struct ComponentShape {
  ComponentKind kind = ComponentKind::label;
  std::string_view text{};
  std::string_view detail{};
  std::string_view url{};
  const char *action_field = nullptr;
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

  inline void count(const ComponentShape &shape, unsigned rank) noexcept {
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

  inline bool admit(const ComponentShape &shape, unsigned rank) noexcept {
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

  inline void release(const ComponentShape &shape, unsigned rank) noexcept {
    if (rank == cutoff_) {
      taken_ = taken_ - usage(shape);
    }
  }

  inline bool stage(const ComponentShape &shape) noexcept {
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

  inline void report(LimitNotices &limits) const noexcept {
    const std::array<LimitReach, 4> reaches{{
        {"bars.max_bar_nodes", "components", 64, offered_.nodes, {}},
        {"bars.max_bar_text_bytes", "text bytes", 4096, offered_.text, {}},
        {"bars.max_bar_actions", "click actions", 32, offered_.actions, {}},
        {"bars.max_samples", "sparkline samples", 256, offered_.samples, {}},
    }};
    for (const auto &reach : reaches) {
      if (reach.requested > reach.value) {
        limits.add(reach);
      }
    }
  }

private:
  inline static Usage usage(const ComponentShape &shape) noexcept {
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
export {
namespace telar::runtime::config {

class ComponentStyleValidator {
public:
  inline static void validate(const lua::Value &component) {
    for (const auto *name : {"fg", "bg"}) {
      const auto value = component.field(name);
      if (value.present()) {
        color(value);
      }
    }
    for (const auto *name : {"bold", "italic", "faint", "underline", "strikethrough"}) {
      component.field(name).boolean(false);
    }
  }

private:
  inline static void color(const lua::Value &value) {
    if (const auto index = value.asInteger()) {
      if (*index < 0 || *index > 255) {
        value.fail("is outside the color index range");
      }
      return;
    }

    constexpr std::string_view names[]{"default", "accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"};
    const auto text = value.string();
    if (std::ranges::any_of(names, [text](std::string_view name) { return equalUiName(text, name); })) {
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
    if (digits.empty() || digits.front() == '_' || digits.back() == '_') {
      return false;
    }

    unsigned value = 0;
    for (const auto byte : digits) {
      if (byte == '_') {
        continue;
      }
      const auto lower = asciiLower(byte);
      if (byte >= '0' && byte <= '9') {
        value = value * 16 + static_cast<unsigned>(byte - '0');
      } else if (lower >= 'a' && lower <= 'f') {
        value = value * 16 + static_cast<unsigned>(lower - 'a' + 10);
      } else {
        return false;
      }
    }
    return !negative || value == 0;
  }
};

}
}

// Interface: telar_config/component_shape_reader.cppm
export {
namespace telar::runtime::config {

class ComponentShapeReader {
public:
  // A shape views the value's strings, which belong to the state in the value's region `a`.
  inline static tbc::view<ComponentShape, tbc::lt::a> read(const lua::Value &value, unsigned inherited_priority, LimitNotices &limits) {
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

  inline static ComponentShape segment(const lua::Value &value, unsigned priority) {
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
  inline static ComponentKind kind(const lua::Value &value) {
    constexpr std::string_view names[]{"label", "icon", "mark", "meter", "sparkline", "badge", "clock", "metric", "machines", "group", "heading", "text", "meter_row", "kv", "callout", "actions", "button", "divider"};
    const auto found = std::ranges::find(names, value.string());
    if (found == std::end(names)) {
      value.fail("names an unknown component");
    }
    return static_cast<ComponentKind>(found - std::begin(names));
  }

  inline static void fields(const lua::Value &value, ComponentKind kind) {
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

  inline static tbc::view<std::string_view, tbc::lt::a> text(const lua::Value &value, const char *name, tbc::view<std::string_view, tbc::lt::a> fallback = {}) {
    const auto field = value.field(name);
    return field.present() ? field.string() : fallback;
  }

  inline static void optionalIcon(const lua::Value &value) {
    if (value.present()) {
      uiIcon(value);
    }
  }

  inline static void finiteNumber(const lua::Value &value) {
    value.boundedNumber(0, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());
  }

  inline static std::size_t samples(const lua::Value &value, LimitNotices &limits) {
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
export {
namespace telar::runtime::config {

template <CommandTabStore Commands>
class ComponentValidator {
public:
  inline explicit ComponentValidator(const BasicActionValidator<Commands> &actions, LimitNotices &limits)
      : actions_(actions),
        limits_(limits) {}

  inline void validate(const lua::Value &value) {
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
    buttons
  };

  struct Position {
    Place place = Place::bar;
    unsigned priority = 50;
    unsigned rank = UINT8_MAX;
    unsigned depth = 0;
  };

  inline void walk(const lua::Value &value, Position position) {
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

  inline void component(const lua::Value &value, Position position) {
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

  inline void children(const lua::Value &value, Position position) {
    const auto count = value.listLength();
    for (std::size_t index = 1; index <= count; ++index) {
      walk(value.element(index), position);
    }
  }

  inline bool append(const lua::Value &value, const ComponentShape &shape, Position position) {
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

  inline static void validateUrl(const lua::Value &value, std::string_view url) {
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
  const BasicActionValidator<Commands> &actions_;
  LimitNotices &limits_;
  ComponentBudget budget_;
  bool counting_ = true;
};

}
}

// Interface: telar_config/command_arguments_validator.cppm
export {
namespace telar::runtime::config {

class CommandArgumentsValidator {
public:
  inline static bool validate(const lua::Value &command) {
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
}

// Interface: telar_config/dynamic_source_validator.cppm
export {
namespace telar::runtime::config {

class DynamicSourceValidator {
public:
  inline static void validate(const lua::Value &source) {
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
}

// Interface: telar_config/bars_validator.cppm
export {
namespace telar::runtime::config {

template <CommandTabStore Commands>
class BarsValidator {
public:
  inline explicit BarsValidator(const BasicActionValidator<Commands> &actions, LimitNotices &limits)
      : actions_(actions),
        limits_(limits) {}

  inline void validate(const lua::Value &bars) const {
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
    tabs
  };

  inline void bottom(const lua::Value &bar) const {
    if (!bar.present()) {
      return;
    }
    bar.onlyFields({"left", "center", "right"});
    unsigned tabs = 0;
    for (const auto *name : {"left", "center", "right"}) {
      const auto value = bar.field(name);
      if (value.present() && source(value) == Source::tabs) {
        ++tabs;
      }
    }
    if (tabs != 1) {
      bar.fail("must contain exactly one tabs source");
    }
  }

  inline Source source(const lua::Value &value) const {
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
  const BasicActionValidator<Commands> &actions_;
  LimitNotices &limits_;
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
    back_tab
  };

  enum class Modifier : unsigned {
    none = 0,
    control = 1,
    alt = 2,
    shift = 4,
    super = 8
  };

  Key key = Key::character;
  std::uint32_t character = 0;
  unsigned modifiers = 0;

  inline bool has(Modifier modifier) const noexcept {
    return (modifiers & static_cast<unsigned>(modifier)) != 0;
  }

  bool operator==(const KeyChord &) const = default;
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
    for (auto &binding : std::span{bindings_}.first(count_)) {
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

  inline void report(LimitNotices &limits) const noexcept {
    std::size_t wanted = count_;
    for (const auto suffix : defaultSuffixes()) {
      const bool overridden = std::ranges::any_of(std::span{bindings_}.first(count_), [&](const Sequence &binding) {
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
  inline static void validate(const lua::Value &value) {
    parse(value);
  }

  inline static KeyChord parse(const lua::Value &value) {
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
    return text.size() == name.size() && std::equal(text.begin(), text.end(), name.begin(), [](char left, char right) { return asciiLower(left) == right; });
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

  inline static void parseKey(const lua::Value &value, std::string_view name, KeyChord &chord) {
    constexpr std::pair<std::string_view, Key> named_keys[]{{"up", Key::up}, {"down", Key::down}, {"left", Key::left}, {"right", Key::right}, {"home", Key::home}, {"end", Key::end}, {"delete", Key::erase}, {"del", Key::erase}, {"pageup", Key::page_up}, {"page-up", Key::page_up}, {"pagedown", Key::page_down}, {"page-down", Key::page_down}, {"enter", Key::enter}, {"return", Key::enter}, {"escape", Key::escape}, {"esc", Key::escape}, {"backspace", Key::backspace}, {"tab", Key::tab}, {"backtab", Key::back_tab}};
    for (const auto &[known, key] : named_keys) {
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
    const auto codepoints = std::ranges::count_if(name, [](unsigned char byte) { return (byte & 0xc0) != 0x80; });
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
  inline static void validate(const lua::Value &bindings, const BasicActionValidator<Commands> &actions, BindingKeymap &keymap, LimitNotices &limits) {
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

  inline static int invoke(lua_State *state) {
    const auto &invocation = *static_cast<CallbackInvocation *>(lua_touserdata(state, 1));
    lua_rawgeti(state, LUA_REGISTRYINDEX, invocation.reference_);
    invocation.pushContext(state);
    lua_call(state, 1, 1);

    return 1;
  }

private:
  inline static void integer(lua_State *state, const char *name, std::uint64_t value) {
    lua_pushinteger(state, static_cast<lua_Integer>(value));
    lua_setfield(state, -2, name);
  }

  inline static int immutable(lua_State *state) {
    lua_pushliteral(state, "callback context is immutable");

    return lua_error(state);
  }

  inline void pushContext(lua_State *state) const {
    lua_newtable(state);
    lua_pushboolean(state, static_cast<int>(context_.sidebar_visible));
    lua_setfield(state, -2, "sidebar_visible");
    integer(state, "tab_count", context_.tab_count);
    integer(state, "active_tab_index", static_cast<std::uint32_t>(context_.active_tab_index) + 1);
    integer(state, "pane_count", context_.pane_count);
    integer(state, "focused_pane_id", context_.focused_pane_id);

    lua_newtable(state);
    lua_newtable(state);
    lua_pushvalue(state, -3);
    lua_setfield(state, -2, "__index");
    lua_pushcfunction(state, &immutable);
    lua_setfield(state, -2, "__newindex");
    lua_pushboolean(state, 0);
    lua_setfield(state, -2, "__metatable");
    lua_setmetatable(state, -2);
    lua_remove(state, -2);
  }

  int reference_;
  BindingContext context_;
};

}
}

// Interface: telar_config/pick_items_validator.cppm
export {
namespace telar::runtime::config {

class PickItemsValidator {
public:
  inline explicit PickItemsValidator(LimitNotices &limits)
      : limits_(limits) {}

  inline void validate(const lua::Value &items) {
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
    for (const auto &reach : text_limits) {
      if (reach.requested > reach.value) {
        limits_.add(reach);
      }
    }
  }

private:
  inline void keep(const lua::Value &item, std::string_view label, std::string_view value, std::string_view detail) {
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

  inline static void swatch(const lua::Value &value) {
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

  LimitNotices &limits_;
  std::size_t kept_items_ = 0;
  std::size_t text_bytes_ = 0;
  std::size_t offered_text_bytes_ = 0;
  std::size_t longest_label_ = 0;
  std::size_t longest_value_ = 0;
  std::size_t longest_detail_ = 0;
  bool text_full_ = false;
};

}
}

// Interface: telar_config/client_definitions_validator.cppm
export {
namespace telar::runtime::config {

class ClientDefinitionsValidator {
public:
  inline static void validate(const lua::Value &client, LimitNotices &limits) {
    NamedDefinitionsValidator::validate(client.field("panels"), {"panels.max_panels", "panels", NamedDefinitionsValidator::maximum_definitions, {}, {}}, limits, [&](std::string_view name, const lua::Value &definition) {
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

    NamedDefinitionsValidator::validate(client.field("picks"), {"picks.max_picks", "picks", NamedDefinitionsValidator::maximum_definitions, {}, {}}, limits, [&](std::string_view name, const lua::Value &definition) {
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

// Interface: telar_config/client_validator.cppm
export {
namespace telar::runtime::config {

// Interface pieces a configuration may draw with Lua, under `client.components`.
// The actions `client.prompt.bindings` may name, in the order of the GUI editor's Action.
inline constexpr std::array<std::string_view, 27> prompt_action_names{
    "submit", "newline", "cancel", "complete", "accept_suggestion", "history_previous", "history_next", "history_search", "line_start", "line_end", "char_left", "char_right", "word_left", "word_right",
    "delete_char", "backspace", "kill_line", "kill_to_start", "kill_word", "kill_word_back", "yank", "undo", "redo", "transpose", "clear_screen", "normal_mode", "insert_mode"};

inline constexpr std::array<std::string_view, 19> component_slots{
    "top_bar", "bottom_bar", "tab", "pane_header", "agent_card",
    "tab_cards", "tab_title", "tab_path", "tab_activity",
    "pane_mark", "pane_program", "pane_context", "pane_status", "pane_progress", "pane_actions",
    "agent_mark", "agent_title", "agent_project", "agent_status",
};

class ClientValidator {
public:
  template <CommandTabStore Commands>
  inline static void validate(const lua::Value &client, LimitNotices &limits, BasicClientValidationState<Commands> &state, const lua::Value *inherited = nullptr) {
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
  inline static void components(const lua::Value &value) {
    if (!value.present()) {
      return;
    }

    value.eachField([](std::string_view name, const lua::Value &entry) {
      if (std::ranges::find(component_slots, name) == component_slots.end()) {
        const auto message = std::string{"names an unknown component slot \""} + std::string{name} + "\"";
        entry.fail(message.c_str());
      }

      if (!entry.is(LUA_TFUNCTION)) {
        entry.fail("must be a function from the context and the item to an element");
      }
    });
  }

  inline static void printableText(const lua::Value &value, std::size_t maximum, bool allow_empty) {
    if (!value.present()) {
      return;
    }

    optionalUtf8Text(value, maximum);
    const auto text = value.string();
    if ((!allow_empty && text.empty()) || std::ranges::any_of(text, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; })) {
      value.fail("must contain printable text");
    }
  }

  inline static void sidebar(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"visible", "renderer"});
      table.field("visible").boolean(true);
    }
  }

  inline static void sound(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"enabled", "ready", "needs_input"});
      for (const auto *name : {"enabled", "ready", "needs_input"}) {
        table.field(name).boolean(false);
      }
    }
  }

  inline static void notifications(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"delivery"});
      optionalChoice(table.field("delivery"), {"telar", "system", "terminal"});
    }
  }

  inline static void input(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"escape_timeout_ms", "sequence_timeout_ms"});
      table.field("sequence_timeout_ms").boundedInteger(1000, 10, 10000);
    }
  }

  inline static void prompt(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"mode", "skin", "motion", "ghost", "keymap", "max_lines", "bindings"});
    optionalChoice(table.field("mode"), {"classic", "telar"});
    const auto bindings = table.field("bindings");
    if (bindings.present()) {
      const auto count = bindings.listLength();
      if (count > 256) {
        bindings.fail("has more than 256 bindings");
      }
      for (std::size_t index = 0; index < count; ++index) {
        const auto binding = bindings.element(static_cast<lua_Integer>(index) + 1);
        binding.onlyFields({"keys", "action", "mode"});
        KeyChordValidator::parse(binding.field("keys"));
        const auto action = binding.field("action");
        if (std::ranges::find(prompt_action_names, action.string()) == prompt_action_names.end()) {
          action.fail("names an unknown prompt action");
        }
        optionalChoice(binding.field("mode"), {"insert", "normal"});
      }
    }
    optionalChoice(table.field("skin"), {"halo", "glass", "ink"});
    optionalChoice(table.field("motion"), {"spring", "ease", "none"});
    optionalChoice(table.field("keymap"), {"emacs", "vim"});
    table.field("ghost").boolean(true);
    table.field("max_lines").boundedInteger(12, 1, 64);
  }

  inline static void history(const lua::Value &table) {
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

// Interface: telar_config/control_reader.cppm
export {
namespace telar::runtime::config {

inline void readControlPolicy(const lua::Value &table, control::Policy &policy) {
  if (!table.present()) {
    return;
  }

  table.onlyFields({"clipboard_read", "clipboard_write", "title_report", "checksum_report", "color_format", "answerback"});
  const auto access = [](const lua::Value &value, control::Access fallback) {
    if (!value.present()) {
      return fallback;
    }
    const auto text = value.string();
    if (text == "deny") {
      return control::Access::deny;
    }
    if (text == "ask") {
      return control::Access::ask;
    }
    if (text == "allow") {
      return control::Access::allow;
    }
    value.fail("must be deny, ask or allow");
  };
  policy.clipboard_read = access(table.field("clipboard_read"), policy.clipboard_read);
  policy.clipboard_write = access(table.field("clipboard_write"), policy.clipboard_write);
  policy.title_report = table.field("title_report").boolean(policy.title_report);
  policy.checksum_report = table.field("checksum_report").boolean(policy.checksum_report);

  const auto format = table.field("color_format");
  if (format.present()) {
    const auto text = format.string();
    if (text == "none") {
      policy.color_format = control::ColorFormat::none;
    } else if (text == "8-bit") {
      policy.color_format = control::ColorFormat::eight_bit;
    } else if (text == "16-bit") {
      policy.color_format = control::ColorFormat::sixteen_bit;
    } else {
      format.fail("must be none, 8-bit or 16-bit");
    }
  }

  const auto answerback = table.field("answerback");
  if (answerback.present()) {
    const auto text = answerback.string();
    if (text.size() > policy.answerback.size()) {
      answerback.fail("exceeds 1024 bytes");
    }
    std::copy(text.begin(), text.end(), policy.answerback.begin());
    policy.answerback_length = static_cast<std::uint16_t>(text.size());
  }
}

}
}

// Interface: telar_config/gui_validator.cppm
export {
namespace telar::runtime::config {

class GuiValidator {
public:
  inline static void validate(const lua::Value &gui) {
    if (!gui.present()) {
      return;
    }

    gui.onlyFields({"font", "cursor", "window", "chrome", "sidebar", "max_fps", "opacity"});
    font(gui.field("font"));
    cursor(gui.field("cursor"));
    window(gui.field("window"));
    chrome(gui.field("chrome"));
    sidebar(gui.field("sidebar"));
    opacity(gui.field("opacity"));
    optionalWholeNumber(gui.field("max_fps"), 30, 240);
  }

private:
  inline static void font(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"family", "style", "size", "line_height", "letter_spacing", "thicken", "thicken_strength"});
    optionalUtf8Text(table.field("family"), 256);
    optionalUtf8Text(table.field("style"), 256);
    table.field("size").boundedNumber(6, 6, 96);
    table.field("line_height").boundedNumber(1, 0.75, 3);
    table.field("letter_spacing").boundedNumber(0, -5, 20);
    table.field("thicken").boolean(false);
    optionalWholeNumber(table.field("thicken_strength"), 0, 255);
  }

  inline static void cursor(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"style", "blink", "blink_interval_ms"});
    optionalChoice(table.field("style"), {"block", "bar", "underline", "hollow"});
    table.field("blink").boolean(false);
    optionalWholeNumber(table.field("blink_interval_ms"), 100, 5000);
  }

  inline static void window(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"background_opacity", "background_blur", "titlebar", "padding"});
    table.field("background_opacity").boundedNumber(1, 0, 1);
    table.field("titlebar").boolean(true);
    const auto blur = table.field("background_blur");
    if (!blur.is(LUA_TBOOLEAN)) {
      optionalWholeNumber(blur, 0, 255);
    }

    const auto padding = table.field("padding");
    if (padding.present()) {
      padding.onlyFields({"x", "y"});
      padding.field("x").boundedNumber(0, 0, 256);
      padding.field("y").boundedNumber(0, 0, 256);
    }
  }

  inline static void chrome(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"scale"});
      table.field("scale").boundedNumber(1, 0.5, 2);
    }
  }

  inline static void opacity(const lua::Value &table) {
    if (!table.present()) {
      return;
    }
    table.onlyFields({"sidebar", "topbar", "bottombar", "workspace", "pane"});
    for (const auto field : {"sidebar", "topbar", "bottombar", "workspace", "pane"}) {
      table.field(field).boundedNumber(1, 0, 1);
    }
  }

  inline static void sidebar(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"width"});
      const auto width = table.field("width");
      if (width.is(LUA_TSTRING)) {
        if (width.string() != "auto") {
          width.fail("must be a number or \"auto\"");
        }
      } else {
        width.boundedNumber(284, 220, 800);
      }
    }
  }
};

}
}

// Interface: telar_config/history/filters.cppm
export {
namespace telar::runtime {

class HistoryPatternList {
public:
  inline void append(std::string_view pattern) {
    if (pattern.empty() || pattern.find('\0') != std::string_view::npos) {
      throw std::invalid_argument{"History filter patterns must not be empty or contain NUL"};
    }
    if (count_ == patterns_.size()) {
      throw std::length_error{"History filter exceeds 64 patterns"};
    }

    patterns_[count_].assign(pattern);
    ++count_;
  }

  inline bool matches(std::string_view text) const noexcept {
    for (const auto &pattern : std::span{patterns_}.first(count_)) {
      if (text.contains(pattern.view())) {
        return true;
      }
    }

    return false;
  }

private:
  std::array<FixedText<256>, 64> patterns_;
  std::size_t count_ = 0;
};

class HistoryFilters {
public:
  inline bool allowsPane(std::string_view command, std::string_view directory) const noexcept {
    return !command.empty() && command.front() != ' ' && allowsAgent(command, directory);
  }

  inline bool allowsAgent(std::string_view command, std::string_view directory, bool redact = true) const noexcept {
    return !command.empty() && !(redact && secrets && looksLikeSecret(command)) && !commands.matches(command) && !directories.matches(directory);
  }

  inline static bool looksLikeSecret(std::string_view command) noexcept {
    constexpr std::array tokens{
        TokenRule{"AKIA", 16},
        TokenRule{"ghp_", 20},
        TokenRule{"gho_", 20},
        TokenRule{"github_pat_", 20},
        TokenRule{"npm_", 30},
        TokenRule{"sk_live_", 12},
        TokenRule{"rk_live_", 12},
        TokenRule{"xoxb-", 10},
        TokenRule{"xoxp-", 10},
    };
    for (const auto &rule : tokens) {
      if (matchesToken(command, rule)) {
        return true;
      }
    }

    if (command.contains("hooks.slack.com/services/") || command.contains("-----BEGIN")) {
      return true;
    }

    constexpr std::array<std::string_view, 5> assignments{"password=", "passwd=", "token=", "secret=", "api_key="};
    for (const auto marker : assignments) {
      if (matchesAssignment(command, marker)) {
        return true;
      }
    }

    return false;
  }

  bool secrets = true;
  HistoryPatternList commands;
  HistoryPatternList directories;

private:
  struct TokenRule {
    std::string_view marker;
    std::size_t minimum_length;
  };

  inline static bool tokenByte(unsigned char byte) noexcept {
    return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
  }

  inline static bool matchesToken(std::string_view command, const TokenRule &rule) noexcept {
    for (std::size_t offset = 0; offset < command.size();) {
      const auto found = command.find(rule.marker, offset);
      if (found == std::string_view::npos) {
        return false;
      }

      const auto suffix = command.substr(found + rule.marker.size());
      std::size_t length = 0;
      while (length < suffix.size() && tokenByte(suffix[length])) {
        ++length;
      }
      if (length >= rule.minimum_length) {
        return true;
      }

      offset = found + 1;
    }

    return false;
  }

  inline static bool matchesAssignment(std::string_view command, std::string_view marker) noexcept {
    for (std::size_t offset = 0; offset + marker.size() < command.size(); ++offset) {
      bool matches = true;
      for (std::size_t index = 0; index < marker.size(); ++index) {
        const unsigned char byte = command[offset + index];
        const auto lower = byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte;
        if (lower != marker[index]) {
          matches = false;
          break;
        }
      }

      const auto value = command[offset + marker.size()];
      if (matches && value != ' ' && value != '"' && value != '\'') {
        return true;
      }
    }

    return false;
  }
};

inline const HistoryFilters default_history_filters{};

}
}

// Interface: telar_config/local_modules.cppm
export {
namespace telar::runtime::config {

using LocalModules = lua::LocalModules<lua::ModuleDomain::configuration>;

}
}

// Interface: telar_config/plugin_reader.cppm
export {
namespace telar::runtime::config {

class PluginReader {
public:
  inline static void read(const lua::Value &value, plugins::Specifications &destination, LimitNotices &limits) {
    if (!value.present()) {
      return;
    }

    const auto listed = value.listLength();
    const auto count = std::min(listed, plugins::PackageLimits::configured);
    if (count < listed) {
      limits.add({.name = "plugins.max_plugins", .noun = "plugins", .value = plugins::PackageLimits::configured, .requested = listed});
    }

    destination.count = 0;
    for (std::size_t index = 0; index < count; ++index) {
      const auto specification = value.element(static_cast<lua_Integer>(index + 1));
      specification.onlyFields({"path", "enabled"});
      const auto path_value = specification.field("path");
      const auto path = path_value.string();
      if (path.empty() || path.size() > plugins::PackageLimits::configured_path_bytes) {
        path_value.fail("is outside its bounds");
      }

      auto &plugin = destination.entries[destination.count];
      plugin.path.assign(path);
      plugin.enabled = specification.field("enabled").boolean(true);
      ++destination.count;
    }
  }
};

}
}

// Interface: telar_config/proxy/capture_limits.cppm
export {
namespace telar::runtime {

struct ProxyCaptureLimits {
  static constexpr std::size_t mebibyte = 1024 * 1024;
  static constexpr std::size_t maximum_exchange_bytes = 64 * mebibyte;
  static constexpr std::size_t maximum_total_bytes = 1024 * mebibyte;
  static constexpr auto maximum_join_timeout = std::chrono::hours{1};

  std::size_t part_bytes = 16 * mebibyte;
  std::size_t exchange_bytes = 32 * mebibyte;
  std::size_t total_bytes = 128 * mebibyte;
  std::chrono::milliseconds join_timeout{std::chrono::minutes{15}};
  bool enabled = false;

  inline bool valid() const noexcept {
    return part_bytes != 0 && exchange_bytes >= 2 && total_bytes != 0 && part_bytes <= exchange_bytes && exchange_bytes <= total_bytes && exchange_bytes <= maximum_exchange_bytes && total_bytes <= maximum_total_bytes && join_timeout.count() > 0 && join_timeout <= maximum_join_timeout;
  }
};

}
}

// Interface: telar_config/proxy/hostname.cppm
export {
namespace telar::runtime {

class ProxyHostname {
public:
  static constexpr std::size_t maximum_bytes = 253;

  inline static bool validPattern(std::string_view pattern) noexcept {
    if (pattern.empty() || pattern.size() > maximum_bytes) {
      return false;
    }
    if (pattern.contains(':')) { return ipv6(pattern).has_value(); }
    if (pattern == "*") {
      return true;
    }
    if (pattern.starts_with("*.")) {
      pattern.remove_prefix(2);
    }
    return validLabels(pattern);
  }

  inline static bool validTarget(std::string_view hostname) noexcept {
    if (hostname.empty() || hostname.size() > maximum_bytes) {
      return false;
    }
    if (hostname.contains(':')) { return ipv6(hostname).has_value(); }
    if (hostname.ends_with('.')) {
      hostname.remove_suffix(1);
    }
    return validLabels(hostname);
  }

  inline static std::optional<in6_addr> ipv6(std::string_view host) noexcept {
    if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) { return {}; }
    std::array<char, INET6_ADDRSTRLEN> text{};
    std::ranges::copy(host, text.begin());
    in6_addr address{};
    return ::inet_pton(AF_INET6, text.data(), &address) == 1 ? std::optional{address} : std::nullopt;
  }

private:
  inline static bool validLabels(std::string_view pattern) noexcept {
    std::size_t label_length = 0;
    char previous = '\0';
    for (const char byte : pattern) {
      if (byte == '.') {
        if (label_length == 0 || label_length > maximum_label_bytes || previous == '-') {
          return false;
        }
        label_length = 0;
      } else if (byte == '-') {
        if (label_length == 0) {
          return false;
        }
        ++label_length;
      } else {
        const char lower = asciiLower(byte);
        if ((lower < 'a' || lower > 'z') && (byte < '0' || byte > '9')) {
          return false;
        }
        ++label_length;
      }
      previous = byte;
    }
    return label_length != 0 && label_length <= maximum_label_bytes && previous != '-';
  }

  static constexpr std::size_t maximum_label_bytes = 63;
};

}
}

// Interface: telar_config/proxy/host_policy.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class ProxyHostPolicy {
public:
  static constexpr std::size_t maximum_hosts = 256;
  static constexpr std::size_t maximum_hostname_bytes = ProxyHostname::maximum_bytes;

  inline explicit ProxyHostPolicy(Memory &memory)
      : patterns_(AllocatorRef<String<Memory>, Memory>{memory}) {}

  inline static bool validPattern(std::string_view pattern) noexcept {
    return ProxyHostname::validPattern(pattern);
  }

  inline bool append(std::string_view pattern) {
    if (patterns_.size() == maximum_hosts || !validPattern(pattern)) {
      return false;
    }

    std::array<char, INET6_ADDRSTRLEN> numeric{};
    if (const auto address = ProxyHostname::ipv6(pattern)) {
      ::inet_ntop(AF_INET6, &*address, numeric.data(), numeric.size());
      pattern = numeric.data();
    }
    patterns_.emplace_back(pattern, AllocatorRef<char, Memory>{patterns_.get_allocator().memory()});
    std::ranges::transform(patterns_.back(), patterns_.back().begin(), asciiLower);
    return true;
  }

  inline void finish() {
    std::ranges::sort(patterns_);
    const auto duplicates = std::ranges::unique(patterns_);
    patterns_.erase(duplicates.begin(), duplicates.end());
  }

  inline void clear() noexcept {
    patterns_.clear();
  }

  inline bool contains(std::string_view hostname) const noexcept {
    if (hostname.empty() || patterns_.empty()) {
      return false;
    }
    if (patterns_.front() == "*") {
      return true;
    }
    if (hostname.size() > maximum_hostname_bytes) {
      return false;
    }

    if (const auto address = ProxyHostname::ipv6(hostname)) {
      std::array<char, INET6_ADDRSTRLEN> numeric{};
      ::inet_ntop(AF_INET6, &*address, numeric.data(), numeric.size());
      return find(numeric.data());
    }

    std::array<char, maximum_hostname_bytes + wildcard_prefix.size()> canonical;
    std::ranges::transform(hostname, canonical.begin() + wildcard_prefix.size(), asciiLower);
    const std::string_view exact{canonical.data() + wildcard_prefix.size(), hostname.size()};
    if (find(exact)) {
      return true;
    }

    for (auto dot = hostname.find('.'); dot != std::string_view::npos; dot = hostname.find('.', dot + 1)) {
      const auto start = dot + 1;
      std::ranges::copy(wildcard_prefix, canonical.data() + start);
      if (find({canonical.data() + start, hostname.size() - start + wildcard_prefix.size()})) {
        return true;
      }
    }
    return false;
  }

  inline std::span<const String<Memory>> patterns() const noexcept {
    return patterns_;
  }

private:
  inline bool find(std::string_view pattern) const noexcept {
    const auto found = std::lower_bound(patterns_.begin(), patterns_.end(), pattern, [](const auto &entry, std::string_view value) { return std::string_view{entry} < value; });
    return found != patterns_.end() && *found == pattern;
  }

  static constexpr std::string_view wildcard_prefix = "*.";
  Vector<String<Memory>, Memory> patterns_;
};

}
}

// Interface: telar_config/proxy/options.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
struct ProxyOptions {
  inline explicit ProxyOptions(Memory &memory)
      : authority_directory(AllocatorRef<char, Memory>{memory}),
        intercept_hosts(memory) {}

  String<Memory> authority_directory;
  ProxyHostPolicy<Memory> intercept_hosts;
  ProxyCaptureLimits capture;
  bool enabled = false;
  bool anonymous_tunnels = false;
  bool network_capture = false;
  bool network_control = false;
  bool transparent_redirect = false;
  bool transparent_tls = false;
  bool stream_interception = false;
};

}
}

// Interface: telar_config/proxy_reader.cppm
export {
namespace telar::runtime::config {

template <Allocator Memory>
class ProxyReader {
public:
  inline static void read(const lua::Value &table, ProxyOptions<Memory> &values) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"enabled", "anonymous_tunnels", "ca_dir", "intercept_hosts", "capture", "network_capture", "network_control", "transparent_redirect", "transparent_tls", "stream_interception"});
    values.enabled = table.field("enabled").boolean(values.enabled);
    values.anonymous_tunnels = table.field("anonymous_tunnels").boolean(values.anonymous_tunnels);
    values.network_capture = table.field("network_capture").boolean(values.network_capture);
    values.network_control = table.field("network_control").boolean(values.network_control);
    if (values.network_control && !values.network_capture) { table.fail("network_control requires network_capture"); }
    values.transparent_redirect = table.field("transparent_redirect").boolean(values.transparent_redirect);
    values.transparent_tls = table.field("transparent_tls").boolean(values.transparent_tls);
    values.stream_interception = table.field("stream_interception").boolean(values.stream_interception);
    if (values.transparent_tls && !values.transparent_redirect) { table.fail("transparent_tls requires transparent_redirect"); }
    if (values.stream_interception && (!values.enabled || !values.network_capture)) { table.fail("stream_interception requires enabled and network_capture"); }
    if (values.transparent_redirect && !values.enabled) {
      table.fail("transparent_redirect requires the proxy to be enabled");
    }
    capture(table.field("capture"), values.capture);
    const auto directory = table.field("ca_dir");
    if (directory.present()) {
      const auto text = directory.string();
      if (text.empty() || text.size() > maximum_path_bytes || text.contains('\0')) {
        directory.fail("is invalid");
      }
      values.authority_directory = text;
    }

    const auto hosts = table.field("intercept_hosts");
    if (!hosts.present()) {
      return;
    }
    const auto count = hosts.arraySize();
    if (count > ProxyHostPolicy<Memory>::maximum_hosts) {
      hosts.fail("exceeds 256 entries");
    }

    values.intercept_hosts.clear();
    for (std::size_t index = 1; index <= count; ++index) {
      const auto host = hosts.element(static_cast<lua_Integer>(index));
      if (!values.intercept_hosts.append(host.string())) {
        host.fail("is not a valid hostname");
      }
    }
    values.intercept_hosts.finish();
  }

private:
  inline static std::size_t positive(const lua::Value &field, std::size_t fallback) {
    return field.boundedInteger(fallback, 1, SIZE_MAX);
  }

  inline static void capture(const lua::Value &table, ProxyCaptureLimits &limits) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"enabled", "max_part_bytes", "max_exchange_bytes", "max_total_bytes", "join_timeout_ms"});
    limits.enabled = table.field("enabled").boolean(limits.enabled);
    limits.part_bytes = positive(table.field("max_part_bytes"), limits.part_bytes);
    limits.exchange_bytes = positive(table.field("max_exchange_bytes"), limits.exchange_bytes);
    limits.total_bytes = positive(table.field("max_total_bytes"), limits.total_bytes);
    const auto timeout = positive(table.field("join_timeout_ms"), static_cast<std::size_t>(limits.join_timeout.count()));
    if (timeout > static_cast<std::size_t>(std::chrono::duration_cast<std::chrono::milliseconds>(ProxyCaptureLimits::maximum_join_timeout).count())) {
      table.field("join_timeout_ms").fail("exceeds its 3600000 ms ceiling");
    }
    limits.join_timeout = std::chrono::milliseconds{timeout};

    if (limits.exchange_bytes < 2 || limits.part_bytes > limits.exchange_bytes || limits.exchange_bytes > limits.total_bytes) {
      table.fail("byte limits must satisfy part <= exchange <= total");
    }
    if (limits.exchange_bytes > ProxyCaptureLimits::maximum_exchange_bytes) {
      table.field("max_exchange_bytes").fail("exceeds its 67108864-byte ceiling");
    }
    if (limits.total_bytes > ProxyCaptureLimits::maximum_total_bytes) {
      table.field("max_total_bytes").fail("exceeds its 1073741824-byte ceiling");
    }
  }

  static constexpr std::size_t maximum_path_bytes = 1024;
};

}
}

// Interface: telar_config/runtime_values.cppm
export {
namespace telar::runtime::config {

template <Allocator Memory>
struct CommandValues {
  inline explicit CommandValues(Memory &memory)
      : arguments(AllocatorRef<String<Memory>, Memory>{memory}) {}

  Vector<String<Memory>, Memory> arguments;
  std::chrono::milliseconds timeout{15'000};
  std::chrono::milliseconds idle_timeout{300'000};
};

template <Allocator Memory>
struct RuntimeValues {
  inline explicit RuntimeValues(Memory &memory)
      : history_path(AllocatorRef<char, Memory>{memory}),
        session_path(AllocatorRef<char, Memory>{memory}),
        engine(memory),
        descriptions(memory),
        proxy(memory) {}

  String<Memory> history_path;
  String<Memory> session_path;
  HistoryFilters history_filters;
  CommandValues<Memory> engine;
  CommandValues<Memory> descriptions;
  ProxyOptions<Memory> proxy;
  plugins::Specifications plugins;
  FixedText<PATH_MAX> configuration_directory;
  AgentManifests manifests = builtin_manifests;
  LimitNotices limits;
  GraphicsLimits graphics;
  control::Policy control_policy{};
  bool capture_output = false;
  bool persist_session = true;
  bool resume_agents = true;
  bool shell_integration = true;
  bool ssh_integration = true;
};

template <Allocator Memory>
RuntimeValues(Memory &memory) -> RuntimeValues<Memory>;

}
}

// Interface: telar_config/runtime_reader.cppm
export {
namespace telar::runtime::config {

template <Allocator Memory>
class RuntimeReader {
public:
  inline explicit RuntimeReader(RuntimeValues<Memory> &values)
      : values_(values) {}

  inline void read(const lua::Value &runtime) {
    if (!runtime.present()) {
      return;
    }

    runtime.onlyFields({"history", "session", "engine", "agent_descriptions", "graphics", "proxy", "agents", "control_queries", "shell_integration", "ssh_integration"});
    values_.shell_integration = runtime.field("shell_integration").boolean(values_.shell_integration);
    values_.ssh_integration = runtime.field("ssh_integration").boolean(values_.ssh_integration);
    history(runtime.field("history"));
    session(runtime.field("session"));
    helper(runtime.field("engine"), values_.engine, true);
    helper(runtime.field("agent_descriptions"), values_.descriptions, false);
    AgentReader{values_.manifests, values_.limits}.read(runtime.field("agents"));
    graphics(runtime.field("graphics"));
    readControlPolicy(runtime.field("control_queries"), values_.control_policy);
    ProxyReader<Memory>::read(runtime.field("proxy"), values_.proxy);
  }

private:
  inline void graphics(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"pane_mib", "global_mib"});
    values_.graphics.pane_bytes = table.field("pane_mib").boundedInteger(values_.graphics.pane_bytes / GraphicsLimits::mebibyte, 2, 256) * GraphicsLimits::mebibyte;
    values_.graphics.global_bytes = table.field("global_mib").boundedInteger(values_.graphics.global_bytes / GraphicsLimits::mebibyte, 2, 512) * GraphicsLimits::mebibyte;
    if (values_.graphics.global_bytes < values_.graphics.pane_bytes) {
      table.fail("global memory must cover the pane memory limit");
    }
  }

  inline static void path(const lua::Value &field, String<Memory> &destination) {
    if (!field.present()) {
      return;
    }

    const auto text = field.string();
    if (text.empty() || text.size() > 1024 || text.contains('\0')) {
      field.fail("is not a valid path");
    }

    destination = text;
  }

  inline static void patterns(const lua::Value &field, HistoryPatternList &destination) {
    if (!field.present()) {
      return;
    }

    const auto count = field.arraySize();
    for (std::size_t index = 1; index <= count; ++index) {
      destination.append(field.element(static_cast<lua_Integer>(index)).string());
    }
  }

  inline void history(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"path", "secrets_filter", "command_filters", "cwd_filters", "output"});
    path(table.field("path"), values_.history_path);
    values_.history_filters.secrets = table.field("secrets_filter").boolean(values_.history_filters.secrets);
    patterns(table.field("command_filters"), values_.history_filters.commands);
    patterns(table.field("cwd_filters"), values_.history_filters.directories);
    const auto output = table.field("output");
    if (output.present()) {
      const auto mode = output.string();
      if (mode != "off" && mode != "bounded") {
        output.fail("must be off or bounded");
      }

      values_.capture_output = mode == "bounded";
    }
  }

  inline void session(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"path", "persist", "resume_agents"});
    path(table.field("path"), values_.session_path);
    values_.persist_session = table.field("persist").boolean(values_.persist_session);
    values_.resume_agents = table.field("resume_agents").boolean(values_.resume_agents);
  }

  inline static void helper(const lua::Value &table, CommandValues<Memory> &destination, bool engine) {
    if (!table.present()) {
      return;
    }

    if (engine) {
      table.onlyFields({"command", "timeout_ms", "idle_timeout_ms"});
    } else {
      table.onlyFields({"command", "timeout_ms"});
    }
    const auto command = table.field("command");
    const auto count = command.arraySize();
    if (count == 0 || count > 32) {
      command.fail("must contain 1..32 arguments");
    }

    destination.arguments.clear();
    auto &memory = destination.arguments.get_allocator().memory();
    std::size_t bytes = 0;
    for (std::size_t index = 1; index <= count; ++index) {
      const auto argument = command.element(static_cast<lua_Integer>(index));
      const auto text = argument.string();
      if ((index == 1 && text.empty()) || text.size() > 4096 - bytes || text.contains('\0')) {
        argument.fail("exceeds the helper command bounds");
      }

      bytes += text.size();
      destination.arguments.emplace_back(text, AllocatorRef<char, Memory>{memory});
    }

    destination.timeout = std::chrono::milliseconds{table.field("timeout_ms").boundedInteger(15'000, 1000, 60'000)};
    if (engine) {
      destination.idle_timeout = std::chrono::milliseconds{table.field("idle_timeout_ms").boundedInteger(300'000, 10'000, 3'600'000)};
    }
  }

  RuntimeValues<Memory> &values_;
};

template <Allocator Memory>
RuntimeReader(RuntimeValues<Memory> &values) -> RuntimeReader<Memory>;

}
}

// Interface: telar_config/theme_validator.cppm
export {
namespace telar::runtime::config {

class ThemeValidator {
public:
  inline static void selection(const lua::Value &configuration) {
    const auto theme = configuration.field("theme");
    const auto client = configuration.field("client");
    if (client.is(LUA_TTABLE)) {
      const auto alias = client.field("theme");
      if (theme.present() && alias.present()) {
        theme.fail("cannot be combined with client.theme");
      }
      validate(alias);
      appearance(client.field("appearance"));
    }

    validate(theme);
  }

  inline static void validate(const lua::Value &theme) {
    if (!theme.present()) {
      return;
    }
    if (theme.is(LUA_TSTRING)) {
      preset(theme);
      return;
    }

    theme.onlyFields({"base", "colors", "terminal", "syntax"});
    preset(theme.field("base"));
    colors(theme.field("colors"));
    terminal(theme.field("terminal"));
    syntax(theme.field("syntax"));
  }

private:
  inline static void preset(const lua::Value &value) {
    if (!value.present()) {
      return;
    }

    const auto text = value.string();
    constexpr std::string_view names[]{"cybervenom", "shade", "osaka-jade", "osaka_jade", "osakajade", "vesper", "catppuccin", "catppuccin-mocha", "mocha", "tokyo-night", "tokyonight", "tokyo_night", "pierre-dark", "pierre-dark-soft", "kanagawa", "kanagawa-wave", "kanagawa_wave", "kanagawa-dragon", "kanagawa_dragon", "terminal", "default"};
    const bool found = std::ranges::any_of(names, [&](std::string_view name) {
      return text.size() == name.size() && std::equal(text.begin(), text.end(), name.begin(), [](char left, char right) { return asciiLower(left) == right; });
    });
    if (!found) {
      value.fail("names an unknown theme");
    }
  }

  inline static void color(const lua::Value &value, bool allow_default) {
    if (!value.present()) {
      return;
    }

    const auto text = value.string();
    if (allow_default && text == "default") {
      return;
    }
    if (text.size() != 7 || text.front() != '#') {
      value.fail("must be an RGB hexadecimal color");
    }
    if (!std::ranges::all_of(text.substr(1), [](char byte) { return (byte >= '0' && byte <= '9') || (asciiLower(byte) >= 'a' && asciiLower(byte) <= 'f'); })) {
      value.fail("contains an invalid hexadecimal digit");
    }
  }

  inline static void colors(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"});
    table.eachField([](std::string_view, const lua::Value &value) { color(value, true); });
  }

  inline static void terminal(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"foreground", "background", "palette", "cursor_color", "cursor_text_color"});
    for (const auto *name : {"foreground", "background", "cursor_color", "cursor_text_color"}) {
      color(table.field(name), false);
    }
    const auto palette = table.field("palette");
    if (palette.present()) {
      constexpr std::size_t palette_size = 16;
      if (palette.arraySize() != palette_size) {
        palette.fail("must contain 16 RGB colors");
      }
      for (std::size_t index = 1; index <= palette_size; ++index) {
        const auto entry = palette.element(static_cast<lua_Integer>(index));
        entry.string();
        color(entry, false);
      }
    }
  }

  inline static void syntax(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"plain", "keyword", "string", "number", "comment", "constant", "builtin_constant", "builtin", "func", "type", "parameter", "property", "namespace", "operator", "punctuation"});
    table.eachField([](std::string_view, const lua::Value &style) {
      if (style.is(LUA_TTABLE)) {
        style.onlyFields({"fg", "italic", "bold"});
        color(style.field("fg"), true);
        style.field("italic").boolean(false);
        style.field("bold").boolean(false);
      } else {
        color(style, true);
      }
    });
  }

  inline static void appearance(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"light", "dark"});
      validate(table.field("light"));
      validate(table.field("dark"));
    }
  }
};

}
}

// Interface: telar_config/snapshot_reader.cppm
export {
namespace telar::runtime::config {

inline bool validProfileName(std::string_view name) noexcept {
  return !name.empty() && name.size() <= 64 && std::ranges::all_of(name, [](char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-'; });
}

template <Allocator Memory>
class SnapshotReader {
public:
  inline explicit SnapshotReader(Memory &memory, RuntimeValues<Memory> &values)
      : memory_(memory),
        values_(values) {}

  inline void read(const lua::Value &root, std::string_view selected_profile) {
    auto state = makeOwned<ClientValidationState>(memory_);
    read(root, selected_profile, *state);
  }

  template <CommandTabStore Commands>
  inline void read(const lua::Value &root, std::string_view selected_profile, BasicClientValidationState<Commands> &client_state) {
    root.onlyFields({"api_version", "theme", "client", "gui", "runtime", "plugins", "profiles"});
    if (root.field("api_version").integer() != 2) {
      root.fail("requires api_version = 2");
    }

    const auto base_client = root.field("client");
    ThemeValidator::selection(root);
    ClientValidator::validate(base_client, values_.limits, client_state);
    GuiValidator::validate(root.field("gui"));
    RuntimeReader{values_}.read(root.field("runtime"));
    PluginReader::read(root.field("plugins"), values_.plugins, values_.limits);
    const auto profiles = root.field("profiles");
    if (!profiles.present()) {
      if (!selected_profile.empty()) {
        profiles.fail("does not define the selected profile");
      }
      client_state.keymap.report(values_.limits);
      return;
    }

    profiles.eachField([&](std::string_view name, const lua::Value &profile) {
      if (!validProfileName(name)) {
        profile.fail("has an invalid name");
      }
      if (name != selected_profile) {
        auto checked = makeOwned<RuntimeValues<Memory>>(memory_, values_);
        const auto saved_commands = client_state.commands.checkpoint();
        const auto saved_keymap = client_state.keymap;
        readProfile(profile.as("config"), *checked, base_client, client_state);
        client_state.commands.restore(saved_commands);
        client_state.keymap = saved_keymap;
      }
    });
    if (selected_profile.empty()) {
      client_state.keymap.report(values_.limits);
      return;
    }

    std::array<char, 65> name{};
    if (!validProfileName(selected_profile)) {
      profiles.fail("has an invalid selected profile name");
    }
    std::copy(selected_profile.begin(), selected_profile.end(), name.begin());
    const auto selected = profiles.field(name.data());
    if (!selected.present()) {
      selected.fail("is not defined");
    }
    readProfile(selected.as("config"), values_, base_client, client_state);
    client_state.keymap.report(values_.limits);
  }

private:
  template <CommandTabStore Commands>
  inline static void readProfile(const lua::Value &profile, RuntimeValues<Memory> &values, const lua::Value &base_client, BasicClientValidationState<Commands> &client_state) {
    profile.onlyFields({"theme", "client", "gui", "runtime", "plugins"});
    ThemeValidator::selection(profile);
    ClientValidator::validate(profile.field("client"), values.limits, client_state, &base_client);
    GuiValidator::validate(profile.field("gui"));
    RuntimeReader{values}.read(profile.field("runtime"));
    PluginReader::read(profile.field("plugins"), values.plugins, values.limits);
  }

  Memory &memory_;
  RuntimeValues<Memory> &values_;
};

template <Allocator Memory>
SnapshotReader(Memory &memory, RuntimeValues<Memory> &values) -> SnapshotReader<Memory>;

}
}
