module telar.gui.components.builtin_content;

import std;
import telar.tbc;

import telar.base.diagnostics;
import telar.base.history;
import telar.base.text.utf8;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui::components {

  bool builtinSource(SourceKind kind) noexcept {
    return kind == SourceKind::metrics || kind == SourceKind::machines;
  }

  BarContent builtinContent(SourceKind kind) {
    BarContent content;
    Input input{};

    input.node.priority = builtin_priority;
    if (kind == SourceKind::metrics) {
      input.node.kind = Kind::group;
      input.text = "system";
      const auto group = content.append(input);

      input.text = {};
      input.node.kind = Kind::metric;
      input.node.parent = group;
      for (const auto metric : std::array{BarMetric::battery, BarMetric::cpu, BarMetric::memory}) {
        input.node.metric = metric;
        content.append(input);
      }
    } else if (kind == SourceKind::machines) {
      input.node.kind = Kind::machines;
      content.append(input);
    }

    return content;
  }

  Invocation::Invocation(int reference, const Context& context, const char* field, std::optional<std::string_view> item) noexcept
      : reference_(reference),
        context_(context),
        field_(field),
        item_(item) {}

  int Invocation::invoke(lua_State* state) {
    const auto& invocation = *static_cast<const Invocation*>(lua_touserdata(state, 1));

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

  void Invocation::pushContext(lua_State* state) const {
    lua_newtable(state);
    runtime::lua::setField(state, "sidebar_visible", static_cast<bool>(context_.client.sidebar_visible));
    runtime::lua::setField(state, "tab_count", static_cast<lua_Integer>(context_.client.tab_count));
    runtime::lua::setField(state, "active_tab_index", static_cast<lua_Integer>(static_cast<std::int64_t>(context_.client.active_tab_index) + 1));
    runtime::lua::setField(state, "pane_count", static_cast<lua_Integer>(context_.client.pane_count));
    runtime::lua::setField(state, "focused_pane_id", static_cast<lua_Integer>(static_cast<std::int64_t>(context_.client.focused_pane_id)));

    lua_newtable(state);
    runtime::lua::setField(state, "unix_seconds", static_cast<lua_Integer>(context_.time.unix_seconds));
    runtime::lua::setField(state, "year", static_cast<lua_Integer>(context_.time.year));
    runtime::lua::setField(state, "month", static_cast<lua_Integer>(context_.time.month));
    runtime::lua::setField(state, "day", static_cast<lua_Integer>(context_.time.day));
    runtime::lua::setField(state, "hour", static_cast<lua_Integer>(context_.time.hour));
    runtime::lua::setField(state, "minute", static_cast<lua_Integer>(context_.time.minute));
    runtime::lua::setField(state, "second", static_cast<lua_Integer>(context_.time.second));
    runtime::lua::setField(state, "weekday", static_cast<lua_Integer>(context_.time.weekday));
    runtime::lua::pushReadOnly(state, "callback context is immutable");
    lua_setfield(state, -2, "time");

    lua_newtable(state);
    runtime::lua::setField(state, "available", static_cast<bool>(context_.metrics.has_value()));
    if (context_.metrics) {
      runtime::lua::setField(state, "cpu_percent", static_cast<lua_Integer>(context_.metrics->cpu_percent));
      runtime::lua::setField(state, "memory_used_decigib", static_cast<lua_Integer>(context_.metrics->memory_used_decigib));
      if (context_.metrics->has_battery) {
        runtime::lua::setField(state, "battery_percent", static_cast<lua_Integer>(context_.metrics->battery_percent));
      }
    }

    runtime::lua::pushReadOnly(state, "callback context is immutable");
    lua_setfield(state, -2, "metrics");
    if (context_.output) {
      runtime::lua::setField(state, "output", *context_.output);
    }

    runtime::lua::setField(state, "pane_title", context_.pane_title);
    runtime::lua::pushReadOnly(state, "callback context is immutable");
  }

  Clock::Text Clock::format(std::string_view pattern, const Time& time) {
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

  bool Clock::showsSeconds(std::string_view pattern) noexcept {
    return pattern.contains("%S");
  }

  void Clock::decimal(Text& text, unsigned number, bool padded) {
    if (padded && number < decimal_base) {
      text.append("0");
    }

    text.appendDecimal(number);
  }

  template <std::size_t Count>
  std::string_view Clock::named(const std::array<std::string_view, Count>& names, unsigned index) noexcept {
    return names[std::min<std::size_t>(index, Count - 1)];
  }

  void Clock::directive(Text& text, char code, const Time& time) {
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

  tbc::view<Icon, tbc::lt::static_storage> Icon::find(std::string_view name) noexcept {
    const auto* const found = std::ranges::find(values, name, &Icon::name);

    return found == values.end() ? Icon{.name = {}, .glyph = {}} : *found;
  }

  void PickItems::clear() noexcept {
    count_ = 0;
    used_ = 0;
    offered_ = {};
  }

  void PickItems::keep(const PickInput& input) {
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

  std::size_t PickItems::size() const noexcept {
    return count_;
  }

  PickOption PickItems::at(std::size_t index) const {
    if (index >= count_) {
      throw std::out_of_range{"Pick option is no longer available"};
    }

    const auto& row = rows_[index];

    return {.label = text(row.label), .value = text(row.value), .detail = text(row.detail), .swatch = row.swatch, .selected = row.selected};
  }

  void PickItems::report(runtime::config::LimitNotices& limits) const noexcept {
    const auto reaches = std::to_array<LimitReach>({
        {.name = "picks.max_items", .noun = "options", .value = maximum_items, .requested = offered_.items, .route = {}},
        {.name = "picks.max_text_bytes", .noun = "option text bytes", .value = maximum_text_bytes, .requested = offered_.text_full ? std::optional<std::size_t>{offered_.text} : std::nullopt, .route = {}},
        {.name = "picks.max_label_bytes", .noun = "label bytes", .value = maximum_label_bytes, .requested = offered_.label, .route = {}},
        {.name = "picks.max_value_bytes", .noun = "value bytes", .value = maximum_value_bytes, .requested = offered_.value, .route = {}},
        {.name = "picks.max_detail_bytes", .noun = "detail bytes", .value = maximum_detail_bytes, .requested = offered_.detail, .route = {}},
    });

    for (const auto& reach : reaches) {
      if (reach.requested.value_or(0) > reach.value) {
        limits.add(reach);
      }
    }
  }

  std::uint32_t PickItems::saturated(std::size_t value) noexcept {
    return static_cast<std::uint32_t>(std::min<std::size_t>(value, std::numeric_limits<std::uint32_t>::max()));
  }

  void PickItems::offer(std::uint32_t& total, std::size_t value) noexcept {
    total += std::min(saturated(value), std::numeric_limits<std::uint32_t>::max() - total);
  }

  void PickItems::validate(std::string_view text, bool tabs) {
    validateUtf8(text);
    constexpr unsigned first_printable = 0x20;
    constexpr unsigned delete_control = 0x7f;
    if (std::ranges::any_of(text, [tabs](unsigned char byte) {
          return (byte < first_printable || byte == delete_control) && (!tabs || byte != '\t');
        })) {
      throw std::invalid_argument{"Pick options must contain printable single-line text"};
    }
  }

  PickItems::Range PickItems::store(std::string_view value) noexcept {
    const Range range{.offset = static_cast<std::uint32_t>(used_), .length = static_cast<std::uint16_t>(value.size())};

    std::ranges::copy(value, bytes_.begin() + static_cast<std::ptrdiff_t>(used_));
    used_ += value.size();

    return range;
  }

  std::string_view PickItems::text(Range range) const noexcept {
    return {bytes_.data() + range.offset, range.length};
  }

  void PickItemsReader::read(const runtime::lua::Value& value, PickItems& output, runtime::config::LimitNotices& limits) {
    keep(
        [&](const auto& collect) {
          runtime::config::PickItemsReader::read(value, collect);
        },
        output,
        limits
    );
  }

  void PickItemsReader::definition(const runtime::lua::Value& pick, PickItems& output, runtime::config::LimitNotices& limits) {
    keep(
        [&](const auto& collect) {
          runtime::config::PickItemsReader::definition(pick, collect);
        },
        output,
        limits
    );
  }

  void PickItemsReader::lines(std::string_view text, PickItems& output, runtime::config::LimitNotices& limits) {
    std::array<char, PickItems::maximum_label_bytes> label{};

    output.clear();
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

      std::ranges::transform(shown, label.begin(), [](char byte) {
        return byte == '\t' ? ' ' : byte;
      });

      PickInput input;

      input.label = {label.data(), shown.size()};
      input.value = option;
      output.keep(input);
    }

    output.report(limits);
  }

  template <typename Read>
  void PickItemsReader::keep(const Read& read, PickItems& output, runtime::config::LimitNotices& limits) {
    output.clear();
    read([&](const runtime::config::PickItemSetting& option, const runtime::lua::Value&) {
      output.keep({.label = option.label, .detail = option.detail.value_or(std::string_view{}), .value = option.value, .swatch = option.swatch, .selected = option.selected});
    });

    output.report(limits);
  }

  void PickMatches::collect(const PickItems& items, std::string_view query) {
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

  std::span<const PickMatches::Match> PickMatches::rows() const noexcept {
    return std::span{matches_}.first(count_);
  }

}

namespace telar::gui {

  CommandTabCopy::CommandTabCopy(const View& view) {
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

  CommandTabCopy::View CommandTabCopy::view() const noexcept {
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

  template <Allocator Memory>
  ResolvedActions<Memory>::ResolvedActions(Memory& memory)
      : entries_(AllocatorRef<ResolvedAction, Memory>{memory}) {}

  template <Allocator Memory>
  void ResolvedActions<Memory>::add(ResolvedAction entry) {
    if (find(entry.action) == nullptr) {
      entries_.push_back(std::move(entry));
    }
  }

  template <Allocator Memory>
  const ResolvedAction* ResolvedActions<Memory>::find(BindingAction action) const noexcept {
    const auto found = std::ranges::find(entries_, action, &ResolvedAction::action);

    return found == entries_.end() ? nullptr : &*found;
  }

  template <Allocator Memory>
  bool ResolvedActions<Memory>::contains(BindingAction action) const noexcept {
    return find(action) != nullptr;
  }

  template <components::Capacity Bounds, Allocator Memory>
  RenderedContent<Bounds, Memory>::RenderedContent(Memory& memory)
      : actions(memory) {}

  template <Allocator Memory>
  ResolvedEffects<Memory>::ResolvedEffects(Memory& memory)
      : actions(memory) {}

  template <Allocator Memory>
  RenderedElements<Memory>::RenderedElements(Memory& memory)
      : elements(AllocatorRef<components::Element, Memory>{memory}),
        text(AllocatorRef<char, Memory>{memory}),
        steps(AllocatorRef<components::CanvasStep, Memory>{memory}),
        bindings(AllocatorRef<BindingAction, Memory>{memory}),
        actions(memory) {}

  template <Allocator Memory>
  std::string_view RenderedElements<Memory>::view(components::ElementText range) const noexcept {
    return range.length == 0 || range.offset > text.size() || range.length > text.size() - range.offset ? std::string_view{} : std::string_view{text.data() + range.offset, range.length};
  }

  template class ResolvedActions<telar::Memory>;
  template class ResolvedActions<telar::ConcurrentMemory>;
  template struct RenderedContent<components::bar_capacity, telar::Memory>;
  template struct RenderedContent<components::panel_capacity, telar::Memory>;
  template struct RenderedContent<components::bar_capacity, telar::ConcurrentMemory>;
  template struct RenderedContent<components::panel_capacity, telar::ConcurrentMemory>;
  template struct ResolvedEffects<telar::Memory>;
  template struct ResolvedEffects<telar::ConcurrentMemory>;
  template struct RenderedElements<telar::Memory>;
  template struct RenderedElements<telar::ConcurrentMemory>;

}
