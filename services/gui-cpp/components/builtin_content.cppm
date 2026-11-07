module;
#include <cstdlib>
#include <new>

#include <cstdint>
#include <cstddef>
#include <cstring>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <cmath>
#include <cstdio>
#include <cinttypes>


export module telar.gui.components.builtin_content;

import std;

export import telar.gui.components.configuration;


export import telar.gui.config.plugin_effects;


export import telar.gui.text.json_unsigned_integer;


export import telar.config;


export import telar.lua;


export import telar.base.history;
import telar.base.diagnostics;
import telar.client.protocol;

// Interface: components/builtin_content.cppm
export {
namespace telar::gui::components {

inline constexpr std::uint8_t builtin_priority = 40;

inline bool builtinSource(SourceKind kind) noexcept {
  return kind == SourceKind::metrics || kind == SourceKind::machines;
}

inline BarContent builtinContent(SourceKind kind) {
  BarContent content;
  Input input{};
  input.node.priority = builtin_priority;
  if (kind == SourceKind::metrics) {
    input.node.kind = Kind::group;
    const auto group = content.append(input);
    input.node.kind = Kind::metric;
    input.node.parent = group;
    for (const auto metric : std::array{BarMetric::cpu, BarMetric::memory, BarMetric::battery}) {
      input.node.metric = metric;
      content.append(input);
    }
  } else if (kind == SourceKind::machines) {
    input.node.kind = Kind::machines;
    content.append(input);
  }

  return content;
}

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
  inline explicit Invocation(int reference, const Context &context, const char *field = "render", std::optional<std::string_view> item = std::nullopt) noexcept
      : reference_(reference),
        context_(context),
        field_(field),
        item_(item) {}

  inline static int invoke(lua_State *state) {
    const auto &invocation = *static_cast<const Invocation *>(lua_touserdata(state, 1));
    lua_rawgeti(state, LUA_REGISTRYINDEX, invocation.reference_);
    if (invocation.field_ != nullptr) {
      lua_getfield(state, -1, invocation.field_);
      lua_remove(state, -2);
    }

    invocation.pushContext(state);
    if (invocation.item_) {
      lua_getglobal(state, "telar");
      lua_getfield(state, -1, "json");
      lua_getfield(state, -1, "decode");
      lua_pushlstring(state, invocation.item_->data(), invocation.item_->size());
      lua_call(state, 1, 1);
      lua_replace(state, -3);
      lua_pop(state, 1);
    }

    lua_call(state, invocation.item_ ? 2 : 1, 1);

    return 1;
  }

private:
  inline static void integer(lua_State *state, const char *name, std::int64_t value) {
    lua_pushinteger(state, static_cast<lua_Integer>(value));
    lua_setfield(state, -2, name);
  }

  inline static void boolean(lua_State *state, const char *name, bool value) {
    lua_pushboolean(state, static_cast<int>(value));
    lua_setfield(state, -2, name);
  }

  inline static void text(lua_State *state, const char *name, std::string_view value) {
    lua_pushlstring(state, value.data(), value.size());
    lua_setfield(state, -2, name);
  }

  inline static int immutable(lua_State *state) {
    lua_pushliteral(state, "callback context is immutable");

    return lua_error(state);
  }

  inline static void freeze(lua_State *state) {
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

  inline void pushContext(lua_State *state) const {
    lua_newtable(state);
    boolean(state, "sidebar_visible", context_.client.sidebar_visible);
    integer(state, "tab_count", context_.client.tab_count);
    integer(state, "active_tab_index", static_cast<std::int64_t>(context_.client.active_tab_index) + 1);
    integer(state, "pane_count", context_.client.pane_count);
    integer(state, "focused_pane_id", static_cast<std::int64_t>(context_.client.focused_pane_id));

    lua_newtable(state);
    integer(state, "unix_seconds", context_.time.unix_seconds);
    integer(state, "year", context_.time.year);
    integer(state, "month", context_.time.month);
    integer(state, "day", context_.time.day);
    integer(state, "hour", context_.time.hour);
    integer(state, "minute", context_.time.minute);
    integer(state, "second", context_.time.second);
    integer(state, "weekday", context_.time.weekday);
    freeze(state);
    lua_setfield(state, -2, "time");

    lua_newtable(state);
    boolean(state, "available", context_.metrics.has_value());
    if (context_.metrics) {
      integer(state, "cpu_percent", context_.metrics->cpu_percent);
      integer(state, "memory_used_decigib", context_.metrics->memory_used_decigib);
      if (context_.metrics->has_battery) {
        integer(state, "battery_percent", context_.metrics->battery_percent);
      }
    }

    freeze(state);
    lua_setfield(state, -2, "metrics");
    if (context_.output) {
      text(state, "output", *context_.output);
    }

    text(state, "pane_title", context_.pane_title);
    freeze(state);
  }

  int reference_;
  const Context &context_;
  const char *field_;
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

  [[nodiscard]] inline static Text format(std::string_view pattern, const Time &time) {
    if (pattern.size() > maximum_format_bytes) {
      throw std::length_error{"Clock format exceeds its byte limit"};
    }

    Text result;
    for (std::size_t index = 0; index < pattern.size(); ++index) {
      if (pattern[index] == '%' && index + 1 < pattern.size()) {
        directive(result, pattern[++index], time);
      } else {
        result.append(pattern.substr(index, 1));
      }
    }

    return result;
  }

  [[nodiscard]] inline static bool showsSeconds(std::string_view pattern) noexcept {
    return pattern.contains("%S");
  }

private:
  static constexpr unsigned noon = 12;
  static constexpr unsigned century = 100;
  static constexpr unsigned decimal_base = 10;
  static constexpr std::array<std::string_view, 7> weekdays{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
  static constexpr std::array<std::string_view, 7> weekday_names{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
  static constexpr std::array<std::string_view, 12> months{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
  static constexpr std::array<std::string_view, 12> month_names{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"};

  inline static void decimal(Text &text, unsigned number, bool padded = true) {
    if (padded && number < decimal_base) {
      text.append("0");
    }

    text.appendDecimal(number);
  }

  template <std::size_t Count>
  inline static std::string_view named(const std::array<std::string_view, Count> &names, unsigned index) noexcept {
    return names[std::min<std::size_t>(index, Count - 1)];
  }

  inline static void directive(Text &text, char code, const Time &time) {
    switch (code) {
    case 'H':
      decimal(text, time.hour);
      break;
    case 'M':
      decimal(text, time.minute);
      break;
    case 'S':
      decimal(text, time.second);
      break;
    case 'I':
      decimal(text, time.hour % noon == 0 ? noon : time.hour % noon);
      break;
    case 'p':
      text.append(time.hour < noon ? "AM" : "PM");
      break;
    case 'd':
      decimal(text, time.day);
      break;
    case 'e':
      decimal(text, time.day, false);
      break;
    case 'm':
      decimal(text, time.month);
      break;
    case 'y':
      decimal(text, time.year % century);
      break;
    case 'Y':
      decimal(text, time.year, false);
      break;
    case 'a':
      text.append(named(weekdays, time.weekday));
      break;
    case 'A':
      text.append(named(weekday_names, time.weekday));
      break;
    case 'b':
      text.append(named(months, time.month == 0 ? 0 : time.month - 1U));
      break;
    case 'B':
      text.append(named(month_names, time.month == 0 ? 0 : time.month - 1U));
      break;
    case '%':
      text.append("%");
      break;
    default:
      text.append("%");
      text.append({&code, 1});
      break;
    }
  }
};

}
}

// Interface: components/icon.cppm
export {
namespace telar::gui::components {

struct Icon {
  std::string_view name;
  std::string_view glyph;
  AgentProvider provider = AgentProvider::unknown;
  bool telar = false;

  [[nodiscard]] inline static Icon find(std::string_view name) noexcept {
    const auto *const found = std::ranges::find(values, name, &Icon::name);

    return found == values.end() ? Icon{.name = {}, .glyph = {}} : *found;
  }

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

  inline void clear() noexcept {
    count_ = 0;
    used_ = 0;
    offered_ = {};
  }

  // A value remains one argv element; only labels and details may be shortened.
  inline void keep(const PickInput &input) {
    const auto value = input.value.value_or(input.label);
    offer(offered_.items, 1);
    for (const auto text : {input.label, value, input.detail}) {
      offer(offered_.text, text.size());
    }

    offered_.label = std::max(offered_.label, saturated(input.label.size()));
    offered_.value = std::max(offered_.value, saturated(value.size()));
    offered_.detail = std::max(offered_.detail, saturated(input.detail.size()));
    if (value.size() > maximum_value_bytes || count_ == maximum_items || offered_.text_full) {
      return;
    }

    const auto label = runtime::utf8Prefix(input.label, maximum_label_bytes);
    const auto detail = runtime::utf8Prefix(input.detail, maximum_detail_bytes);
    if (label.empty() || value.empty()) {
      throw std::invalid_argument{"A pick option needs a label and value"};
    }

    validate(label, false);
    validate(detail, false);
    validate(value, true);
    const auto shared = label == value;
    const auto needed = label.size() + detail.size() + (shared ? 0 : value.size());
    if (needed > maximum_text_bytes - used_) {
      offered_.text_full = true;
      return;
    }

    Row row;
    row.label = store(label);
    row.value = shared ? row.label : store(value);
    row.detail = store(detail);
    row.selected = input.selected;
    row.swatch = input.swatch;
    rows_[count_++] = row;
  }

  [[nodiscard]] inline std::size_t size() const noexcept {
    return count_;
  }

  [[nodiscard]] inline PickOption at(std::size_t index) const {
    if (index >= count_) {
      throw std::out_of_range{"Pick option is no longer available"};
    }

    const auto &row = rows_[index];

    return {.label = text(row.label), .value = text(row.value), .detail = text(row.detail), .swatch = row.swatch, .selected = row.selected};
  }

  inline void report(runtime::config::LimitNotices &limits) const noexcept {
    const auto reaches = std::to_array<LimitReach>({
        {.name = "picks.max_items", .noun = "options", .value = maximum_items, .requested = offered_.items, .route = {}},
        {.name = "picks.max_text_bytes", .noun = "option text bytes", .value = maximum_text_bytes, .requested = offered_.text_full ? std::optional<std::size_t>{offered_.text} : std::nullopt, .route = {}},
        {.name = "picks.max_label_bytes", .noun = "label bytes", .value = maximum_label_bytes, .requested = offered_.label, .route = {}},
        {.name = "picks.max_value_bytes", .noun = "value bytes", .value = maximum_value_bytes, .requested = offered_.value, .route = {}},
        {.name = "picks.max_detail_bytes", .noun = "detail bytes", .value = maximum_detail_bytes, .requested = offered_.detail, .route = {}},
    });
    for (const auto &reach : reaches) {
      if (reach.requested.value_or(0) > reach.value) {
        limits.add(reach);
      }
    }
  }

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

  inline static std::uint32_t saturated(std::size_t value) noexcept {
    return static_cast<std::uint32_t>(std::min<std::size_t>(value, std::numeric_limits<std::uint32_t>::max()));
  }

  inline static void offer(std::uint32_t &total, std::size_t value) noexcept {
    total += std::min(saturated(value), std::numeric_limits<std::uint32_t>::max() - total);
  }

  inline static void validate(std::string_view text, bool tabs) {
    validateUtf8(text);
    constexpr unsigned first_printable = 0x20;
    constexpr unsigned delete_control = 0x7f;
    if (std::ranges::any_of(text, [tabs](unsigned char byte) {
          return (byte < first_printable || byte == delete_control) && (!tabs || byte != '\t');
        })) {
      throw std::invalid_argument{"Pick options must contain printable single-line text"};
    }
  }

  inline Range store(std::string_view value) noexcept {
    const Range range{.offset = static_cast<std::uint32_t>(used_), .length = static_cast<std::uint16_t>(value.size())};
    std::ranges::copy(value, bytes_.begin() + static_cast<std::ptrdiff_t>(used_));
    used_ += value.size();

    return range;
  }

  [[nodiscard]] inline std::string_view text(Range range) const noexcept {
    return {bytes_.data() + range.offset, range.length};
  }

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

class PickItemsReader {
public:
  inline static void read(const runtime::lua::Value &value, PickItems &output, runtime::config::LimitNotices &limits) {
    PickItems next;
    const auto count = value.arraySize();
    for (std::size_t index = 0; index < count; ++index) {
      item(value.element(static_cast<lua_Integer>(index) + 1), next);
    }

    output = next;
    output.report(limits);
  }

  inline static void lines(std::string_view text, PickItems &output, runtime::config::LimitNotices &limits) {
    PickItems next;
    std::array<char, PickItems::maximum_label_bytes> label{};
    while (!text.empty()) {
      const auto newline = text.find('\n');
      const auto line = text.substr(0, newline);
      text = newline == std::string_view::npos ? std::string_view{} : text.substr(newline + 1);
      constexpr std::string_view blanks = " \t\r";
      const auto first = line.find_first_not_of(blanks);
      if (first == std::string_view::npos) {
        continue;
      }

      const auto option = line.substr(first, line.find_last_not_of(blanks) - first + 1);
      const auto shown = runtime::utf8Prefix(option, label.size());
      std::ranges::transform(shown, label.begin(), [](char byte) { return byte == '\t' ? ' ' : byte; });
      PickInput input;
      input.label = {label.data(), shown.size()};
      input.value = option;
      next.keep(input);
    }

    output = next;
    output.report(limits);
  }

private:
  inline static void item(const runtime::lua::Value &value, PickItems &items) {
    PickInput input;
    if (value.is(LUA_TSTRING)) {
      input.label = value.string();
      items.keep(input);

      return;
    }

    value.onlyFields({"label", "value", "detail", "selected", "swatch"});
    const auto label = value.field("label");
    const auto chosen = value.field("value");
    const auto detail = value.field("detail");
    input.label = label.string();
    if (chosen.present()) {
      input.value = chosen.string();
    }

    if (detail.present()) {
      input.detail = detail.string();
    }

    input.selected = value.field("selected").boolean(false);
    input.swatch = swatch(value.field("swatch"));
    items.keep(input);
  }

  inline static std::optional<PickSwatch> swatch(const runtime::lua::Value &value) {
    if (!value.present()) {
      return std::nullopt;
    }

    PickSwatch result;
    if (value.arraySize() != result.size()) {
      value.fail("must contain three RGB colors");
    }

    constexpr int hexadecimal_base = 16;
    for (std::size_t index = 0; index < result.size(); ++index) {
      const auto color = value.element(static_cast<lua_Integer>(index) + 1);
      runtime::config::hexadecimalColor(color);
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

// Interface: components/pick_matches.cppm
export {
namespace telar::gui::components {

class PickMatches {
public:
  struct Match {
    std::uint32_t score = 0;
    std::uint16_t index = 0;
  };

  inline void collect(const PickItems &items, std::string_view query) {
    count_ = 0;
    for (std::size_t index = 0; index < items.size(); ++index) {
      const auto option = items.at(index);
      auto score = runtime::historyScore(option.label, query);
      if (!score) {
        score = runtime::historyScore(option.detail, query);
      }

      if (score) {
        matches_[count_++] = {.score = *score, .index = static_cast<std::uint16_t>(index)};
      }
    }

    std::ranges::sort(std::span{matches_}.first(count_), [](Match left, Match right) {
      return left.score != right.score ? left.score > right.score : left.index < right.index;
    });
  }

  [[nodiscard]] inline std::span<const Match> rows() const noexcept {
    return std::span{matches_}.first(count_);
  }

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

  inline explicit CommandTabCopy(const View &view) {
    std::size_t used = 0;
    const auto store = [&](std::string_view text) {
      if (text.size() > bytes_.size() - used) {
        throw std::length_error{"Command tab exceeds its byte capacity"};
      }

      std::ranges::copy(text, bytes_.begin() + static_cast<std::ptrdiff_t>(used));
      used += text.size();

      return static_cast<std::uint16_t>(text.size());
    };
    count_ = view.count;
    for (std::size_t index = 0; index < view.count; ++index) {
      lengths_[index] = store(view.arguments[index]);
    }

    label_ = store(view.configured_label);
  }

  [[nodiscard]] inline View view() const noexcept {
    View result;
    result.count = count_;
    std::size_t offset = 0;
    for (std::size_t index = 0; index < count_; ++index) {
      result.arguments[index] = {bytes_.data() + offset, lengths_[index]};
      offset += lengths_[index];
    }

    result.configured_label = {bytes_.data() + offset, label_};

    return result;
  }

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
  inline explicit ResolvedActions(Memory &memory)
      : entries_(AllocatorRef<ResolvedAction, Memory>{memory}) {}

  inline void add(ResolvedAction entry) {
    if (find(entry.action) == nullptr) {
      entries_.push_back(std::move(entry));
    }
  }

  [[nodiscard]] inline const ResolvedAction *find(BindingAction action) const noexcept {
    const auto found = std::ranges::find(entries_, action, &ResolvedAction::action);

    return found == entries_.end() ? nullptr : &*found;
  }

  [[nodiscard]] inline bool contains(BindingAction action) const noexcept {
    return find(action) != nullptr;
  }

private:
  Vector<ResolvedAction, Memory> entries_;
};

template <components::Capacity Bounds, Allocator Memory>
struct RenderedContent {
  inline explicit RenderedContent(Memory &memory)
      : actions(memory) {}

  components::Content<Bounds> content;
  ResolvedActions<Memory> actions;
};

template <Allocator Memory>
struct ResolvedEffects {
  inline explicit ResolvedEffects(Memory &memory)
      : actions(memory) {}

  BindingEffects effects;
  ResolvedActions<Memory> actions;
};

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
  inline explicit RenderedElements(Memory &memory)
      : elements(AllocatorRef<components::Element, Memory>{memory}),
        text(AllocatorRef<char, Memory>{memory}),
        steps(AllocatorRef<components::CanvasStep, Memory>{memory}),
        bindings(AllocatorRef<BindingAction, Memory>{memory}),
        actions(memory) {}

  [[nodiscard]] inline std::string_view view(components::ElementText range) const noexcept {
    return range.length == 0 || range.offset > text.size() || range.length > text.size() - range.offset ? std::string_view{} : std::string_view{text.data() + range.offset, range.length};
  }

  Vector<components::Element, Memory> elements;
  String<Memory> text;
  Vector<components::CanvasStep, Memory> steps;
  // Element `action` indices name these; `actions` holds what each one means.
  Vector<BindingAction, Memory> bindings;
  ResolvedActions<Memory> actions;
  // Lua handlers this render registered for `on_click` functions, by element `callback`.
  std::uint32_t callbacks = 0;
};

}
}
