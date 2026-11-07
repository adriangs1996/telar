module;

#include <string_view>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <variant>
#include <utility>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include "telar_base/memory/fixed_text.hpp"
#include <algorithm>
#include <limits>
#include <span>


#include "telar_client/codecs/telar_value_codec.hpp"


#include "telar_base/memory/allocator.hpp"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <string>


#include "telar_client/serializers/telar_protocol.hpp"
#include <cinttypes>
#include "telar_base/text/utf8.hpp"

export module telar.gui.components.configuration;

export import telar.gui.core.metrics;
export import telar.gui.input.copy_pointer;
export import telar.gui.presentation.history_filter_geometry;
export import telar.config;


export import telar.lua;


export import telar.base.text;

// Interface: components/node.cppm
export {
namespace telar::gui::components {

using Kind = runtime::config::ComponentKind;

enum class Tone : std::uint8_t {
  neutral,
  muted,
  accent,
  success,
  warning,
  danger,
};

enum class Mark : std::uint8_t {
  claude,
  codex,
  pi,
  telar,
};

struct Style {
  std::optional<ColorName::Value> foreground = std::nullopt;
  std::optional<ColorName::Value> background = std::nullopt;
  bool bold = false;
  bool italic = false;
  bool faint = false;
  bool underline = false;
  bool strikethrough = false;
};

struct Range {
  std::uint16_t offset = 0;
  std::uint16_t length = 0;
};

struct Node {
  static constexpr std::uint8_t no_parent = std::numeric_limits<std::uint8_t>::max();
  static constexpr std::uint8_t no_action = no_parent;
  static constexpr std::size_t maximum_nodes = no_parent - 1;
  static constexpr std::size_t maximum_samples = 120;
  static constexpr std::size_t maximum_icon_bytes = 32;
  static constexpr std::uint8_t default_priority = 50;
  static constexpr std::uint8_t maximum_priority = 100;
  static constexpr std::uint16_t full_scale = 1000;
  static constexpr std::uint8_t warning_bonus = 20;
  static constexpr std::uint8_t danger_bonus = 40;

  Kind kind = Kind::label;
  std::uint8_t parent = no_parent;
  bool tooltip = false;
  Range text{};
  Range detail{};
  Range url{};
  Range samples{};
  std::optional<runtime::FixedText<maximum_icon_bytes>> icon = std::nullopt;
  std::optional<Mark> mark = std::nullopt;
  BarMetric metric = BarMetric::cpu;
  Tone tone = Tone::neutral;
  Style style{};
  std::uint16_t value = 0;
  std::optional<std::uint16_t> marker = std::nullopt;
  std::uint8_t priority = default_priority;
  bool primary = false;
  std::uint8_t action = no_action;

  [[nodiscard]] inline unsigned effectivePriority() const noexcept {
    unsigned bonus = 0;
    if (tone == Tone::warning) {
      bonus = warning_bonus;
    } else if (tone == Tone::danger) {
      bonus = danger_bonus;
    }

    return std::min<unsigned>(priority + bonus, std::numeric_limits<std::uint8_t>::max());
  }

  [[nodiscard]] inline bool container() const noexcept {
    return kind == Kind::group || kind == Kind::callout || kind == Kind::actions;
  }
};

struct Input {
  Node node{};
  std::string_view text;
  std::string_view detail;
  std::string_view url;
  std::span<const std::uint8_t> samples;
  std::optional<BindingAction> action = std::nullopt;
};

}
}

// Interface: components/content.cppm
export {
namespace telar::gui::components {

struct Capacity {
  std::size_t nodes;
  std::size_t text;
  std::size_t samples;
  std::size_t actions;
};

template <Capacity Bounds>
class Content {
  static_assert(Bounds.nodes <= Node::maximum_nodes && Bounds.actions <= Node::maximum_nodes);
  static_assert(Bounds.text <= std::numeric_limits<std::uint16_t>::max() && Bounds.samples <= std::numeric_limits<std::uint16_t>::max());

public:
  static constexpr auto capacity = Bounds;
  using Parents = std::array<bool, Node::maximum_nodes>;

  // Validate and reserve the complete node before changing any owned storage.
  inline std::uint8_t append(const Input &input) {
    if (node_count_ == Bounds.nodes) {
      throw std::length_error{"TooManyBarComponents"};
    }

    validateParent(input.node);
    if (input.node.value > Node::full_scale || input.node.marker.value_or(0) > Node::full_scale) {
      throw std::invalid_argument{"InvalidBarValue"};
    }

    if (input.samples.size() > Node::maximum_samples || input.samples.size() > Bounds.samples - sample_length_) {
      throw std::length_error{"TooManyBarSamples"};
    }

    if (input.action && action_count_ == Bounds.actions) {
      throw std::length_error{"TooManyBarActions"};
    }

    auto remaining = Bounds.text - text_length_;
    for (const auto value : {input.text, input.detail, input.url}) {
      if (value.size() > remaining) {
        throw std::length_error{"BarTextTooLong"};
      }

      remaining -= value.size();
      validateText(value);
    }

    validateUrl(input.url);
    auto node = input.node;
    node.priority = std::min(node.priority, Node::maximum_priority);
    node.text = copyText(input.text);
    node.detail = copyText(input.detail);
    node.url = copyText(input.url);
    node.samples = {.offset = static_cast<std::uint16_t>(sample_length_), .length = static_cast<std::uint16_t>(input.samples.size())};
    std::ranges::copy(input.samples, samples_.begin() + static_cast<std::ptrdiff_t>(sample_length_));
    sample_length_ += input.samples.size();
    node.action = Node::no_action;
    if (input.action) {
      node.action = static_cast<std::uint8_t>(action_count_);
      actions_[action_count_++] = *input.action;
    }

    const auto index = node_count_++;
    nodes_[index] = node;

    return static_cast<std::uint8_t>(index);
  }

  inline void clear() noexcept {
    node_count_ = 0;
    text_length_ = 0;
    sample_length_ = 0;
    action_count_ = 0;
  }

  [[nodiscard]] inline std::span<const Node> nodes() const noexcept {
    return std::span{nodes_}.first(node_count_);
  }

  [[nodiscard]] inline bool empty() const noexcept {
    return node_count_ == 0;
  }

  [[nodiscard]] inline std::string_view text(Range range) const {
    validateRange(range, text_length_);
    if (range.length == 0) {
      return {};
    }

    return {text_.data() + range.offset, range.length};
  }

  [[nodiscard]] inline std::span<const std::uint8_t> samples(const Node &node) const {
    validateRange(node.samples, sample_length_);

    return std::span{samples_}.subspan(node.samples.offset, node.samples.length);
  }

  [[nodiscard]] inline std::optional<BindingAction> action(const Node &node) const {
    if (node.action == Node::no_action) {
      return std::nullopt;
    }

    if (node.action >= action_count_) {
      throw std::out_of_range{"InvalidBarAction"};
    }

    return actions_[node.action];
  }

  [[nodiscard]] inline Input inputAt(std::size_t index) const {
    if (index >= node_count_) {
      throw std::out_of_range{"InvalidBarComponent"};
    }

    const auto &node = nodes_[index];

    return {.node = node, .text = text(node.text), .detail = text(node.detail), .url = text(node.url), .samples = samples(node), .action = action(node)};
  }

  // Rank children with their container, reserve by priority, then copy in document order.
  template <Capacity SourceBounds>
  inline void keepFitting(const Content<SourceBounds> &source, const Parents *known_children = nullptr) {
    if (static_cast<const void *>(this) == static_cast<const void *>(&source)) {
      throw std::invalid_argument{"Component fitting requires a distinct source"};
    }

    const auto count = source.nodes().size();
    std::array<unsigned, Node::maximum_nodes> ranks{};
    std::array<std::uint8_t, Node::maximum_nodes> order{};
    auto empty_containers = known_children == nullptr ? Parents{} : *known_children;
    for (std::size_t index = 0; index < count; ++index) {
      const auto &node = source.nodes()[index];
      ranks[index] = node.effectivePriority();
      order[index] = static_cast<std::uint8_t>(index);
      if (node.parent != Node::no_parent) {
        ranks[index] = std::min(ranks[index], ranks[node.parent]);
        empty_containers[node.parent] = false;
      }
    }

    const auto sorted = std::span{order}.first(count);
    std::ranges::sort(sorted, [&](auto left, auto right) {
      return ranks[left] == ranks[right] ? left < right : ranks[left] > ranks[right];
    });
    Parents kept{};
    Usage used;
    for (const auto index : sorted) {
      const auto &node = source.nodes()[index];
      if (empty_containers[index] || (node.parent != Node::no_parent && !kept[node.parent])) {
        continue;
      }

      const auto next = used.with(node);
      if (next.fits(Bounds)) {
        kept[index] = true;
        used = next;
      }
    }

    dropEmpty(source.nodes(), kept, known_children);
    clear();
    std::array<std::uint8_t, Node::maximum_nodes> copied{};
    for (std::size_t index = 0; index < count; ++index) {
      if (!kept[index]) {
        continue;
      }

      auto input = source.inputAt(index);
      if (input.node.parent != Node::no_parent) {
        input.node.parent = copied[input.node.parent];
      }

      copied[index] = append(input);
    }
  }

private:
  struct Usage {
    std::size_t nodes = 0;
    std::size_t text = 0;
    std::size_t samples = 0;
    std::size_t actions = 0;

    [[nodiscard]] inline Usage with(const Node &node) const noexcept {
      return {.nodes = nodes + 1, .text = text + node.text.length + node.detail.length + node.url.length, .samples = samples + node.samples.length, .actions = actions + (node.action != Node::no_action ? 1 : 0)};
    }

    [[nodiscard]] inline bool fits(Capacity room) const noexcept {
      return nodes <= room.nodes && text <= room.text && samples <= room.samples && actions <= room.actions;
    }
  };

  inline static void dropEmpty(std::span<const Node> source, Parents &kept, const Parents *known_children) noexcept {
    auto had_children = known_children == nullptr ? Parents{} : *known_children;
    std::array<std::uint8_t, Node::maximum_nodes> children{};
    for (std::size_t index = 0; index < source.size(); ++index) {
      const auto &node = source[index];
      if (node.parent != Node::no_parent) {
        had_children[node.parent] = true;
        if (kept[index]) {
          ++children[node.parent];
        }
      }
    }

    for (auto index = source.size(); index-- > 0;) {
      if (kept[index] && had_children[index] && children[index] == 0) {
        kept[index] = false;
        const auto &node = source[index];
        if (node.parent != Node::no_parent) {
          --children[node.parent];
        }
      }
    }
  }

  inline void validateParent(const Node &node) const {
    if (node.parent == Node::no_parent) {
      if (node.tooltip) {
        throw std::invalid_argument{"InvalidBarParent"};
      }

      return;
    }

    if (node.parent >= node_count_ || !nodes_[node.parent].container() || (node.tooltip && nodes_[node.parent].kind != Kind::group)) {
      throw std::invalid_argument{"InvalidBarParent"};
    }
  }

  inline static void validateText(std::string_view value) {
    validateUtf8(value);
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_control = 0x7f;
    if (std::ranges::any_of(value, [](unsigned char byte) {
          return byte < first_printable || byte == delete_control;
        })) {
      throw std::invalid_argument{"InvalidBarText"};
    }
  }

  inline static void validateUrl(std::string_view value) {
    constexpr std::size_t maximum_url_bytes = 1024;
    if (!value.empty() && (value.size() > maximum_url_bytes || value.contains(' ') || (!value.starts_with("https://") && !value.starts_with("http://")))) {
      throw std::invalid_argument{"InvalidBarUrl"};
    }
  }

  inline static void validateRange(Range range, std::size_t length) {
    if (range.offset > length || range.length > length - range.offset) {
      throw std::out_of_range{"InvalidBarContentRange"};
    }
  }

  inline Range copyText(std::string_view value) noexcept {
    const Range range{.offset = static_cast<std::uint16_t>(text_length_), .length = static_cast<std::uint16_t>(value.size())};
    std::ranges::copy(value, text_.begin() + static_cast<std::ptrdiff_t>(text_length_));
    text_length_ += value.size();

    return range;
  }

  std::array<Node, Bounds.nodes> nodes_{};
  std::array<char, Bounds.text> text_{};
  std::array<std::uint8_t, Bounds.samples> samples_{};
  std::array<BindingAction, Bounds.actions> actions_{};
  std::size_t node_count_ = 0;
  std::size_t text_length_ = 0;
  std::size_t sample_length_ = 0;
  std::size_t action_count_ = 0;
};

inline constexpr Capacity bar_capacity{.nodes = 64, .text = 4096, .samples = 256, .actions = 32};
inline constexpr Capacity panel_capacity{.nodes = 128, .text = std::size_t{16} * std::size_t{1024}, .samples = 1024, .actions = 32};
inline constexpr Capacity staging_capacity{.nodes = Node::maximum_nodes, .text = std::size_t{32} * std::size_t{1024}, .samples = 2048, .actions = 64};
using BarContent = Content<bar_capacity>;
using PanelContent = Content<panel_capacity>;
using StagedContent = Content<staging_capacity>;

}
}

// Interface: components/action_references.cppm
export {
namespace telar::gui::components {

template <std::size_t MaximumReferences>
class ActionReferences {
public:
  inline explicit ActionReferences(lua_State &state) noexcept
      : state_(&state) {}

  inline ~ActionReferences() {
    clear();
  }

  ActionReferences(const ActionReferences &) = delete;
  ActionReferences &operator=(const ActionReferences &) = delete;
  ActionReferences(ActionReferences &&) = delete;
  ActionReferences &operator=(ActionReferences &&) = delete;

  inline void keep(BindingAction action) {
    if (action.kind != BindingActionKind::extended) {
      return;
    }

    if (count_ == MaximumReferences) {
      luaL_unref(state_, LUA_REGISTRYINDEX, action.reference);

      throw std::length_error{"Too many component action references"};
    }

    references_[count_++] = action;
  }

  [[nodiscard]] inline bool contains(BindingAction action) const noexcept {
    return std::ranges::contains(std::span{references_}.first(count_), action);
  }

  // Release actions omitted by the final fit, including empty containers.
  template <Capacity Bounds>
  inline void keepOnly(const Content<Bounds> &content) {
    std::size_t kept = 0;
    for (const auto retained : std::span{references_}.first(count_)) {
      const bool used = std::ranges::any_of(content.nodes(), [&](const Node &node) {
        const auto action = content.action(node);

        return action == retained;
      });
      if (used) {
        references_[kept++] = retained;
      } else {
        luaL_unref(state_, LUA_REGISTRYINDEX, retained.reference);
      }
    }

    count_ = kept;
  }

  inline void swap(ActionReferences &other) noexcept {
    std::swap(state_, other.state_);
    references_.swap(other.references_);
    std::swap(count_, other.count_);
  }

  inline void clear() noexcept {
    for (const auto retained : std::span{references_}.first(count_)) {
      luaL_unref(state_, LUA_REGISTRYINDEX, retained.reference);
    }

    count_ = 0;
  }

private:
  lua_State *state_;
  std::array<BindingAction, MaximumReferences> references_{};
  std::size_t count_ = 0;
};

template <typename Reader, std::size_t Capacity>
class ActionReader {
public:
  inline explicit ActionReader(const Reader &reader, ActionReferences<Capacity> &references, std::uint32_t &next_reference) noexcept
      : reader_(reader),
        references_(references),
        next_reference_(next_reference) {}

  [[nodiscard]] inline std::optional<BindingAction> read(const runtime::lua::Value &value) const {
    auto action = reader_.read(value);
    if (action && action->kind == BindingActionKind::extended) {
      if (next_reference_ == static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())) {
        references_.keep(*action);

        throw std::length_error{"Component action identity exhausted"};
      }

      action->parameter = -static_cast<std::int32_t>(++next_reference_);
      references_.keep(*action);
    }

    return action;
  }

private:
  const Reader &reader_;
  ActionReferences<Capacity> &references_;
  std::uint32_t &next_reference_;
};

}
}

// Interface: components/value_reader.cppm
export {
namespace telar::gui::components {

struct SampleValues {
  std::array<std::uint8_t, Node::maximum_samples> values{};
  std::size_t length = 0;
};

class ValueReader {
public:
  inline static Style style(const runtime::lua::Value &value) {
    Style result;
    result.foreground = color(value.field("fg"));
    result.background = color(value.field("bg"));
    constexpr auto fields = std::to_array<std::pair<const char *, bool Style::*>>({
        {"bold", &Style::bold},
        {"italic", &Style::italic},
        {"faint", &Style::faint},
        {"underline", &Style::underline},
        {"strikethrough", &Style::strikethrough},
    });
    for (const auto &[name, member] : fields) {
      result.*member = value.field(name).boolean(false);
    }

    return result;
  }

  inline static Tone tone(const runtime::lua::Value &value) {
    if (!value.present()) {
      return Tone::neutral;
    }

    constexpr std::array names{"neutral", "muted", "accent", "success", "warning", "danger"};
    const auto name = value.string();
    for (std::size_t index = 0; index < names.size(); ++index) {
      if (name == names[index]) {
        return static_cast<Tone>(index);
      }
    }

    value.fail("names an unknown component tone");
  }

  inline static std::optional<Mark> mark(const runtime::lua::Value &value) {
    if (!value.present()) {
      return std::nullopt;
    }

    runtime::config::uiMark(value);
    constexpr std::array names{"claude", "codex", "pi", "telar"};
    const auto name = value.string();

    return static_cast<Mark>(std::ranges::find(names, name) - names.begin());
  }

  inline static BarMetric metric(const runtime::lua::Value &value) {
    constexpr std::array names{"cpu", "memory", "battery"};
    const auto name = value.string();
    const auto *const found = std::ranges::find(names, name);
    if (found == names.end()) {
      value.fail("names an unknown component metric");
    }

    return static_cast<BarMetric>(found - names.begin());
  }

  inline static std::optional<runtime::FixedText<Node::maximum_icon_bytes>> icon(const runtime::lua::Value &value) {
    if (!value.present()) {
      return std::nullopt;
    }

    runtime::config::uiIcon(value);
    runtime::FixedText<Node::maximum_icon_bytes> result;
    std::array<char, Node::maximum_icon_bytes> normalized{};
    const auto name = value.string();
    if (name.size() > normalized.size()) {
      value.fail("exceeds the component icon name limit");
    }

    std::ranges::transform(name, normalized.begin(), [](char byte) {
      return byte == '-' ? '_' : runtime::asciiLower(byte);
    });
    result.assign({normalized.data(), name.size()});

    return result;
  }

  inline static std::optional<std::uint16_t> fraction(const runtime::lua::Value &value) {
    if (!value.present()) {
      return std::nullopt;
    }

    const auto number = value.boundedNumber(0, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());

    return static_cast<std::uint16_t>(std::round(std::clamp(number, 0.0, 1.0) * Node::full_scale));
  }

  inline static SampleValues samples(const runtime::lua::Value &value, runtime::config::LimitNotices &limits) {
    const auto maximum = value.field("max");
    const auto values = value.field("values");
    const auto total = values.listLength();
    SampleValues result;
    result.length = std::min(total, result.values.size());
    if (total > result.length) {
      limits.add({.name = "bars.max_node_samples", .noun = "sparkline values", .value = Node::maximum_samples, .requested = total, .route = {}});
    }

    std::array<double, Node::maximum_samples> kept{};
    double largest = 0;
    for (std::size_t index = 0; index < result.length; ++index) {
      const auto sample = values.element(static_cast<lua_Integer>(total - result.length) + static_cast<lua_Integer>(index) + 1);
      if (!sample.present()) {
        sample.fail("must be a number");
      }

      const auto number = sample.boundedNumber(0, 0, std::numeric_limits<double>::max());
      kept[index] = number;
      largest = std::max(largest, number);
    }

    const auto scale = maximum.boundedNumber(largest, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());
    constexpr double percent_scale = 100;
    for (std::size_t index = 0; index < result.length; ++index) {
      const auto fraction = scale > 0 ? std::clamp(kept[index] / scale, 0.0, 1.0) : 0;
      result.values[index] = static_cast<std::uint8_t>(std::round(fraction * percent_scale));
    }

    return result;
  }

private:
  inline static std::optional<ColorName::Value> color(const runtime::lua::Value &value) {
    if (!value.present()) {
      return std::nullopt;
    }

    constexpr auto maximum_index = std::numeric_limits<std::uint8_t>::max();
    if (const auto index = value.asInteger()) {
      if (*index < 0 || std::cmp_greater(*index, maximum_index)) {
        value.fail("is outside the component color index range");
      }

      return CellColor{.kind = CellColor::Kind::indexed, .channels = {static_cast<std::uint8_t>(*index), 0, 0}};
    }

    const auto parsed = ColorName::parse(value.string());
    if (!parsed) {
      value.fail("is not a supported component color");
    }

    return parsed;
  }
};

}
}

// Interface: components/content_reader.cppm
export {
namespace telar::gui::components {

enum class Surface : std::uint8_t {
  bar,
  panel,
};

template <typename Actions>
class ContentReader {
public:
  inline explicit ContentReader(lua_State &state, const Actions &actions, runtime::config::LimitNotices &limits, StagedContent &staged, Surface surface = Surface::bar)
      : state_(state),
        actions_(actions),
        limits_(limits),
        staged_(staged),
        surface_(surface) {}

  // Count before retaining actions so omitted components cannot retain commands.
  template <Capacity Bounds>
  inline void read(const runtime::lua::Value &value, Content<Bounds> &output) {
    budget_ = {};
    demand_ = {};
    had_children_.fill(false);
    counting_ = true;
    staged_.clear();
    const Position root{.place = surface_ == Surface::bar ? Place::bar : Place::panel};
    walk(value, root);
    budget_.prepare();
    counting_ = false;
    walk(value, root);
    output.keepFitting(staged_, &had_children_);
    report(Bounds);
  }

private:
  enum class Place : std::uint8_t {
    bar,
    panel,
    group,
    tooltip,
    buttons,
  };

  struct Position {
    Place place = Place::bar;
    std::uint8_t parent = Node::no_parent;
    unsigned priority = Node::default_priority;
    unsigned rank = std::numeric_limits<std::uint8_t>::max();
    unsigned depth = 0;
  };

  struct Staged {
    std::uint8_t index;
    unsigned rank;
  };

  enum class Phase : std::uint8_t {
    visit,
    list,
    children,
    tooltip,
    button,
    done,
  };

  struct Frame {
    std::optional<runtime::lua::Value> value = std::nullopt;
    Position position;
    Position child;
    Phase phase = Phase::visit;
    bool tooltip = false;
    int index = 0;
    std::size_t next = 0;
    std::size_t count = 0;
  };

  static constexpr unsigned maximum_list_depth = 4;
  static constexpr std::size_t maximum_frames = (std::size_t{maximum_list_depth} + 2) * 2;

  inline void push(Position position) {
    if (frame_count_ == frames_.size()) {
      throw std::length_error{"Component traversal stack exceeded"};
    }

    auto &frame = frames_[frame_count_++];
    frame.index = lua_gettop(&state_);
    frame.value.emplace(&state_, frame.index, "component");
    frame.position = position;
    frame.phase = Phase::visit;
    frame.tooltip = false;
    frame.next = 0;
    frame.count = 0;
  }

  inline void pop() noexcept {
    auto &frame = frames_[--frame_count_];
    frame.value.reset();
    lua_settop(&state_, frame.index - 1);
  }

  // The explicit traversal stack bounds both nested lists and container work.
  inline void walk(const runtime::lua::Value &value, Position position) {
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

  inline void advance() {
    auto &frame = frames_[frame_count_ - 1];
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
      child.place = tooltip ? Place::tooltip : Place::buttons;
      child.priority = Node::default_priority;
      push(child);
    } break;
    case Phase::done:
      pop();
      break;
    }
  }

  inline static const runtime::lua::Value &frameValue(const Frame &frame) {
    if (!frame.value) {
      throw std::logic_error{"Component traversal frame has no value"};
    }

    return *frame.value;
  }

  inline void visit(Frame &frame) {
    const auto &value = frameValue(frame);
    const auto position = frame.position;
    frame.phase = Phase::done;
    if (!value.present()) {
      return;
    }

    if (value.is(LUA_TSTRING)) {
      Input input;
      input.node.priority = static_cast<std::uint8_t>(position.priority);
      input.text = value.string();
      const runtime::config::ComponentShape shape{.text = input.text, .priority = position.priority};
      static_cast<void>(append(value, shape, input, position));

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
      const auto shape = runtime::config::ComponentShapeReader::segment(value, position.priority);
      Input input;
      input.node.kind = shape.kind;
      input.node.priority = static_cast<std::uint8_t>(shape.priority);
      input.node.icon = ValueReader::icon(value.field("icon"));
      input.node.style = ValueReader::style(value);
      input.text = shape.text;
      static_cast<void>(append(value, shape, input, position));

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

  inline void component(Frame &frame) {
    const auto &value = frameValue(frame);
    const auto shape = runtime::config::ComponentShapeReader::read(value, frame.position.priority, limits_);
    Input input;
    input.node.kind = shape.kind;
    input.node.priority = static_cast<std::uint8_t>(shape.priority);
    input.node.tone = ValueReader::tone(value.field("tone"));
    input.text = shape.text;
    input.detail = shape.detail;
    input.url = shape.url;
    SampleValues samples;
    values(value, input, samples);
    const auto node = append(value, shape, input, frame.position);
    if (!node) {
      return;
    }

    frame.child = {.parent = node->index, .rank = node->rank};
    switch (shape.kind) {
    case Kind::group:
      frame.child.place = Place::group;
      frame.child.priority = shape.priority;
      frame.tooltip = true;
      frame.count = value.listLength();
      frame.phase = Phase::children;
      break;
    case Kind::actions:
      frame.child.place = Place::buttons;
      frame.count = value.listLength();
      frame.phase = Phase::children;
      break;
    case Kind::callout:
      frame.phase = Phase::button;
      break;
    default:
      break;
    }
  }

  inline void values(const runtime::lua::Value &value, Input &input, SampleValues &samples) {
    switch (input.node.kind) {
    case Kind::label:
      input.node.style = ValueReader::style(value);
      break;
    case Kind::icon:
      input.node.icon = ValueReader::icon(value.field("name"));
      break;
    case Kind::mark:
      input.node.mark = ValueReader::mark(value.field("name"));
      break;
    case Kind::meter:
    case Kind::meter_row:
      input.node.value = ValueReader::fraction(value.field("value")).value_or(0);
      input.node.marker = ValueReader::fraction(value.field("marker"));
      break;
    case Kind::sparkline:
      samples = ValueReader::samples(value, limits_);
      input.samples = std::span{samples.values}.first(samples.length);
      break;
    case Kind::metric:
      input.node.metric = ValueReader::metric(value.field("name"));
      break;
    case Kind::group:
      input.node.mark = ValueReader::mark(value.field("mark"));
      [[fallthrough]];
    case Kind::callout:
      input.node.icon = ValueReader::icon(value.field("icon"));
      break;
    case Kind::button:
      input.node.primary = value.field("primary").boolean(false);
      break;
    default:
      break;
    }
  }

  inline std::optional<Staged> append(const runtime::lua::Value &value, const runtime::config::ComponentShape &shape, Input &input, Position position) {
    if (!allowed(shape.kind, position.place)) {
      value.fail("contains a component unsupported in this position");
    }

    const auto rank = std::min(shape.priority + shape.tone_bonus, position.rank);
    if (counting_) {
      budget_.count(shape, rank);
      demand_ = demand_ + usage(shape);

      return Staged{.index = 0, .rank = rank};
    }

    if (position.parent != Node::no_parent) {
      had_children_[position.parent] = true;
    }

    if (!budget_.admit(shape, rank)) {
      return std::nullopt;
    }

    if (shape.action_field != nullptr) {
      const auto action = value.field(shape.action_field);
      if (action.is(LUA_TFUNCTION)) {
        action.fail("cannot be a callback in a component");
      }

      input.action = actions_.read(action);
      if (!input.action) {
        budget_.release(shape, rank);

        return std::nullopt;
      }
    }

    if (!budget_.stage(shape)) {
      return std::nullopt;
    }

    input.node.parent = position.parent;
    input.node.tooltip = position.place == Place::tooltip;

    return Staged{.index = staged_.append(input), .rank = rank};
  }

  inline static bool allowed(Kind kind, Place place) noexcept {
    switch (place) {
    case Place::bar:
      return kind <= Kind::group;
    case Place::panel:
      return true;
    case Place::group:
      return kind < Kind::group;
    case Place::tooltip:
      return kind != Kind::group && kind != Kind::callout && kind != Kind::actions && kind != Kind::button;
    case Place::buttons:
      return kind == Kind::button;
    }

    return false;
  }

  inline static runtime::config::ComponentBudget::Usage usage(const runtime::config::ComponentShape &shape) noexcept {
    return {.nodes = 1, .text = shape.text.size() + shape.detail.size() + shape.url.size(), .actions = shape.action_field == nullptr ? 0U : 1U, .samples = shape.samples};
  }

  inline void report(Capacity bounds) {
    const bool panel = surface_ == Surface::panel;
    const auto reaches = std::to_array<LimitReach>({
        {.name = panel ? "panels.max_panel_nodes" : "bars.max_bar_nodes", .noun = "components", .value = bounds.nodes, .requested = demand_.nodes, .route = {}},
        {.name = panel ? "panels.max_panel_text_bytes" : "bars.max_bar_text_bytes", .noun = "text bytes", .value = bounds.text, .requested = demand_.text, .route = {}},
        {.name = panel ? "panels.max_panel_actions" : "bars.max_bar_actions", .noun = "click actions", .value = bounds.actions, .requested = demand_.actions, .route = {}},
        {.name = panel ? "panels.max_samples" : "bars.max_samples", .noun = "sparkline samples", .value = bounds.samples, .requested = demand_.samples, .route = {}},
    });
    for (const auto &reach : reaches) {
      if (reach.requested.value_or(0) > reach.value) {
        limits_.add(reach);
      }
    }
  }

  lua_State &state_;
  std::array<Frame, maximum_frames> frames_{};
  std::size_t frame_count_ = 0;
  const Actions &actions_;
  runtime::config::LimitNotices &limits_;
  StagedContent &staged_;
  Surface surface_;
  runtime::config::ComponentBudget budget_;
  runtime::config::ComponentBudget::Usage demand_;
  StagedContent::Parents had_children_{};
  bool counting_ = true;
};

}
}

// Interface: components/snapshot.cppm
export {
namespace telar::gui::components {

template <Capacity Bounds>
class Snapshot {
public:
  inline explicit Snapshot(lua_State &state) noexcept
      : state_(state),
        references_(state) {}

  template <typename Actions>
  inline void read(const runtime::lua::Value &value, const Actions &actions, runtime::config::LimitNotices &limits, StagedContent &staged, std::uint32_t &next_reference) {
    ActionReferences<StagedContent::capacity.actions> pending{state_};
    const ActionReader reader{actions, pending, next_reference};
    Content<Bounds> next;
    constexpr auto surface = Bounds.nodes == PanelContent::capacity.nodes ? Surface::panel : Surface::bar;
    ContentReader{state_, reader, limits, staged, surface}.read(value, next);
    pending.keepOnly(next);
    references_.swap(pending);
    content_ = std::move(next);
  }

  [[nodiscard]] inline const Content<Bounds> &content() const noexcept {
    return content_;
  }

  [[nodiscard]] inline bool contains(BindingAction action) const noexcept {
    return references_.contains(action);
  }

  inline void clear() noexcept {
    references_.clear();
    content_.clear();
  }

private:
  lua_State &state_;
  ActionReferences<StagedContent::capacity.actions> references_;
  Content<Bounds> content_;
};

using BarSnapshot = Snapshot<BarContent::capacity>;
using PanelSnapshot = Snapshot<PanelContent::capacity>;

}
}

// Interface: components/source.cppm
export {
namespace telar::gui::components {

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

inline constexpr const auto &slot_names = runtime::config::component_slots;
static_assert(slot_names.size() == static_cast<std::size_t>(Slot::count) && slot_names[static_cast<std::size_t>(Slot::agent_status)] == "agent_status");

// Native pieces `ui.builtin` can place: every slot plus parts of the two bars.
inline constexpr std::array<std::string_view, 27> builtin_names{
    "tab", "pane_header", "agent_card",
    "tab_cards", "tab_title", "tab_path", "tab_activity",
    "pane_mark", "pane_program", "pane_context", "pane_status", "pane_progress", "pane_actions",
    "agent_mark", "agent_title", "agent_project", "agent_status",
    "sidebar_toggle", "workspace_identity", "project_switcher", "tabs", "palette_button", "new_tab",
    "metrics", "bar_left", "bar_center", "bar_right",
};

struct Source {
  static constexpr std::chrono::milliseconds default_interval{1000};
  static constexpr std::chrono::milliseconds default_timeout{2000};
  static constexpr std::uint64_t minimum_interval_ms = 100;
  static constexpr std::uint64_t maximum_interval_ms = 3600000;
  static constexpr std::uint64_t minimum_timeout_ms = 100;
  static constexpr std::uint64_t maximum_timeout_ms = 10000;
  SourceKind kind = SourceKind::empty;
  std::optional<std::chrono::milliseconds> interval = std::nullopt;
  std::chrono::milliseconds timeout = default_timeout;
  int reference = LUA_NOREF;
  bool has_render = false;

  inline static Source read(lua_State &state, const runtime::lua::Value &value, bool panel = false) {
    Source result;
    if (!value.present()) {
      return result;
    }

    const auto kind = value.field("bar_kind").string();
    constexpr std::array<std::string_view, 6> names{"tabs", "metrics", "machines", "static", "dynamic", "command"};
    const auto *const found = std::ranges::find(names, kind);
    if (found == names.end()) {
      value.fail("names an unsupported bar source");
    }

    result.kind = static_cast<SourceKind>(found - names.begin() + 1);
    if (result.kind == SourceKind::dynamic || result.kind == SourceKind::command) {
      const auto every = value.field("every_ms");
      if (!panel || every.present()) {
        result.interval = std::chrono::milliseconds{every.boundedInteger(default_interval.count(), minimum_interval_ms, maximum_interval_ms)};
      }

      result.has_render = value.field("render").present();
      result.timeout = std::chrono::milliseconds{value.field("timeout_ms").boundedInteger(default_timeout.count(), minimum_timeout_ms, maximum_timeout_ms)};
    }

    value.pushCopy();
    result.reference = luaL_ref(&state, LUA_REGISTRYINDEX);

    return result;
  }
};

struct Heading {
  static constexpr std::size_t maximum_name_bytes = 32;
  static constexpr std::size_t maximum_title_bytes = 128;
  runtime::FixedText<maximum_name_bytes> name;
  runtime::FixedText<maximum_title_bytes> title;

  inline void read(std::string_view key, const runtime::lua::Value &value) {
    name.assign(key);
    const auto text = value.field("title");
    title.assign(runtime::utf8Prefix(text.present() ? text.string() : key, maximum_title_bytes));
  }
};

struct Panel {
  static constexpr std::uint16_t default_width = 420;
  static constexpr std::uint16_t minimum_width = 240;
  static constexpr std::uint16_t maximum_width = 720;
  Heading heading;
  Source source;
  std::optional<Mark> mark = std::nullopt;
  std::optional<runtime::FixedText<Node::maximum_icon_bytes>> icon = std::nullopt;
  std::uint16_t width = default_width;
};

struct Pick {
  static constexpr std::uint64_t maximum_timeout_ms = 60000;
  Heading heading;
  std::chrono::milliseconds timeout = Source::default_timeout;
  int reference = LUA_NOREF;
  bool command = false;
  bool render = false;
  bool refresh = true;
};

class Definitions {
public:
  static constexpr std::size_t positions = static_cast<std::size_t>(Position::count);
  static constexpr std::size_t maximum_definitions = 16;

  inline Definitions() noexcept {
    sources_[static_cast<std::size_t>(Position::bottom_left)].kind = SourceKind::metrics;
    sources_[static_cast<std::size_t>(Position::bottom_right)].kind = SourceKind::tabs;
    sources_[static_cast<std::size_t>(Position::footer_left)].kind = SourceKind::metrics;
  }

  inline void apply(lua_State &state, const runtime::lua::Value &client) {
    if (!client.present()) {
      return;
    }

    bars(state, client.field("bars"));
    slots(state, client.field("components"));
    named(client.field("panels"), panel_count_, [&](std::string_view name, const runtime::lua::Value &value, std::size_t index) {
      auto &panel = panels_[index];
      panel.heading.read(name, value);
      panel.width = static_cast<std::uint16_t>(value.field("width").boundedInteger(Panel::default_width, Panel::minimum_width, Panel::maximum_width));
      panel.mark = ValueReader::mark(value.field("mark"));
      panel.icon = ValueReader::icon(value.field("icon"));
      panel.source = Source::read(state, value.field("source"), true);
    });
    named(client.field("picks"), pick_count_, [&](std::string_view name, const runtime::lua::Value &value, std::size_t index) {
      auto &pick = picks_[index];
      pick.heading.read(name, value);
      pick.timeout = std::chrono::milliseconds{value.field("timeout_ms").boundedInteger(Source::default_timeout.count(), Source::minimum_timeout_ms, Pick::maximum_timeout_ms)};
      pick.command = value.field("command").present();
      pick.render = value.field("items").is(LUA_TFUNCTION);
      pick.refresh = value.field("refresh").boolean(true);
      value.pushCopy();
      pick.reference = luaL_ref(&state, LUA_REGISTRYINDEX);
    });
  }

  [[nodiscard]] inline const Source &source(Position position) const {
    return sources_.at(static_cast<std::size_t>(position));
  }

  // A registry reference to the slot's render function, or LUA_NOREF when QML draws it.
  [[nodiscard]] inline int slot(Slot slot) const noexcept {
    return slots_[static_cast<std::size_t>(slot)];
  }

  [[nodiscard]] inline bool drawsAny() const noexcept {
    return std::ranges::any_of(slots_, [](int reference) {
      return reference != LUA_NOREF;
    });
  }

  [[nodiscard]] inline std::span<const Panel> panels() const noexcept {
    return std::span{panels_}.first(panel_count_);
  }

  [[nodiscard]] inline std::span<const Pick> picks() const noexcept {
    return std::span{picks_}.first(pick_count_);
  }

private:
  inline void bars(lua_State &state, const runtime::lua::Value &value) {
    if (!value.present()) {
      return;
    }

    const auto bottom = value.field("bottom");
    if (bottom.present()) {
      constexpr std::array names{"left", "center", "right"};
      for (std::size_t index = 0; index < names.size(); ++index) {
        sources_[index] = Source::read(state, bottom.field(names[index]));
      }
    }

    const auto top = value.field("top");
    if (top.present()) {
      sources_[static_cast<std::size_t>(Position::top_right)] = Source::read(state, top.field("right"));
    }

    const auto footer = value.field("sidebar_footer");
    if (footer.present()) {
      constexpr std::size_t footer_slots = 3;
      const auto count = footer.arraySize();
      for (std::size_t index = 0; index < footer_slots; ++index) {
        sources_[static_cast<std::size_t>(Position::footer_left) + index] = index < count ? Source::read(state, footer.element(static_cast<lua_Integer>(index) + 1)) : Source{};
      }
    }
  }

  inline void slots(lua_State &state, const runtime::lua::Value &value) {
    if (!value.present()) {
      return;
    }

    value.eachField([&](std::string_view name, const runtime::lua::Value &entry) {
      const auto *const found = std::ranges::find(slot_names, name);
      if (found == slot_names.end()) {
        const auto message = std::string{"names an unknown component slot \""} + std::string{name} + "\"";
        entry.fail(message.c_str());
      }

      if (!entry.is(LUA_TFUNCTION)) {
        entry.fail("must be a function from the context and the item to an element");
      }

      auto &reference = slots_[static_cast<std::size_t>(found - slot_names.begin())];
      if (reference != LUA_NOREF) {
        luaL_unref(&state, LUA_REGISTRYINDEX, reference);
      }

      entry.pushCopy();
      reference = luaL_ref(&state, LUA_REGISTRYINDEX);
    });
  }

  template <typename Read>
  inline static void named(const runtime::lua::Value &value, std::size_t &count, const Read &read) {
    if (!value.present()) {
      return;
    }

    std::array<std::string_view, maximum_definitions> names;
    count = 0;
    value.eachField([&](std::string_view name, const runtime::lua::Value &) {
      auto *const end = names.begin() + static_cast<std::ptrdiff_t>(count);
      auto *const place = std::lower_bound(names.begin(), end, name);
      if (count == names.size() && place == end) {
        return;
      }

      auto *const last = count < names.size() ? end : end - 1;
      std::move_backward(place, last, last + 1);
      *place = name;
      count = std::min(count + 1, names.size());
    });
    for (std::size_t index = 0; index < count; ++index) {
      read(names[index], value.entry(names[index]), index);
    }
  }

  std::array<Source, positions> sources_{};
  std::array<Panel, maximum_definitions> panels_{};
  std::array<Pick, maximum_definitions> picks_{};
  std::size_t panel_count_ = 0;
  std::size_t pick_count_ = 0;
  std::array<int, static_cast<std::size_t>(Slot::count)> slots_ = [] {
    std::array<int, static_cast<std::size_t>(Slot::count)> result{};
    result.fill(LUA_NOREF);

    return result;
  }();
};

}
}

// Interface: components/configuration.cppm
export {
namespace telar::gui::components {

class Configuration {
public:
  inline explicit Configuration(lua_State &state)
      : state_(state),
        bars_{BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}},
        panel_(state) {}

  [[nodiscard]] inline Definitions &definitions() noexcept {
    return definitions_;
  }

  [[nodiscard]] inline const Definitions &definitions() const noexcept {
    return definitions_;
  }

  template <typename Actions>
  inline void readFixed(const Actions &actions, runtime::config::LimitNotices &limits) {
    const runtime::lua::Value registry{&state_, LUA_REGISTRYINDEX, "bar registry"};
    for (std::size_t index = 0; index < bars_.size(); ++index) {
      const auto &source = definitions_.source(static_cast<Position>(index));
      if (source.kind == SourceKind::fixed) {
        const auto value = registry.element(source.reference);
        bars_[index].read(value.field("value"), actions, limits, staged_, next_reference_);
      }
    }
  }

  template <typename Actions>
  inline void readBar(Position position, const runtime::lua::Value &value, const Actions &actions, runtime::config::LimitNotices &limits) {
    bars_.at(static_cast<std::size_t>(position)).read(value, actions, limits, staged_, next_reference_);
  }

  template <typename Actions>
  inline void readPanel(const runtime::lua::Value &value, const Actions &actions, runtime::config::LimitNotices &limits) {
    panel_.read(value, actions, limits, staged_, next_reference_);
  }

  [[nodiscard]] inline const BarContent &bar(Position position) const {
    return bars_.at(static_cast<std::size_t>(position)).content();
  }

  [[nodiscard]] inline const PanelContent &panel() const noexcept {
    return panel_.content();
  }

  inline void closePanel() noexcept {
    panel_.clear();
  }

  [[nodiscard]] inline bool contains(BindingAction action) const noexcept {
    return panel_.contains(action) || std::ranges::any_of(bars_, [action](const auto &bar) {
             return bar.contains(action);
           });
  }

  template <typename Visitor>
  inline void visitActions(const Visitor &visitor) const {
    const auto visit = [&](const auto &content) {
      for (const auto &node : content.nodes()) {
        if (const auto action = content.action(node)) {
          visitor(*action);
        }
      }
    };
    for (const auto &bar : bars_) {
      visit(bar.content());
    }

    visit(panel_.content());
  }

private:
  lua_State &state_;
  Definitions definitions_;
  std::array<BarSnapshot, Definitions::positions> bars_;
  PanelSnapshot panel_;
  StagedContent staged_;
  std::uint32_t next_reference_ = 0;
};

}
}
