#pragma once

#include "config/component_budget.hpp"
#include "config/component_shape.hpp"
#include "config/component_shape_reader.hpp"
#include "config/limit_notices.hpp"
#include "content.hpp"
#include "lua/value.hpp"
#include "node.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "value_reader.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <lua.h>
#include <optional>
#include <span>
#include <stdexcept>

namespace telar::gui::components {

enum class Surface : std::uint8_t {
  bar,
  panel,
};

template <typename Actions>
class ContentReader {
public:
  explicit ContentReader(lua_State &state, const Actions &actions, runtime::config::LimitNotices &limits, StagedContent &staged, Surface surface = Surface::bar)
      : state_(state),
        actions_(actions),
        limits_(limits),
        staged_(staged),
        surface_(surface) {}

  // Count before retaining actions so omitted components cannot retain commands.
  template <Capacity Bounds>
  void read(const runtime::lua::Value &value, Content<Bounds> &output) {
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

  void push(Position position) {
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

  void pop() noexcept {
    auto &frame = frames_[--frame_count_];
    frame.value.reset();
    lua_settop(&state_, frame.index - 1);
  }

  // The explicit traversal stack bounds both nested lists and container work.
  void walk(const runtime::lua::Value &value, Position position) {
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

  void advance() {
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

  static const runtime::lua::Value &frameValue(const Frame &frame) {
    if (!frame.value) {
      throw std::logic_error{"Component traversal frame has no value"};
    }

    return *frame.value;
  }

  void visit(Frame &frame) {
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

  void component(Frame &frame) {
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

  void values(const runtime::lua::Value &value, Input &input, SampleValues &samples) {
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

  std::optional<Staged> append(const runtime::lua::Value &value, const runtime::config::ComponentShape &shape, Input &input, Position position) {
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

  static bool allowed(Kind kind, Place place) noexcept {
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

  static runtime::config::ComponentBudget::Usage usage(const runtime::config::ComponentShape &shape) noexcept {
    return {.nodes = 1, .text = shape.text.size() + shape.detail.size() + shape.url.size(), .actions = shape.action_field == nullptr ? 0U : 1U, .samples = shape.samples};
  }

  void report(Capacity bounds) {
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
