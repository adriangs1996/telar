#pragma once

#include "content.hpp"
#include "input/action.hpp"
#include "telar_lua/value.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <lauxlib.h>
#include <limits>
#include <lua.h>
#include <optional>
#include <span>
#include <stdexcept>
#include <utility>

namespace telar::gui::components {

template <std::size_t MaximumReferences>
class ActionReferences {
public:
  explicit ActionReferences(lua_State &state) noexcept
      : state_(&state) {}

  ~ActionReferences() {
    clear();
  }

  ActionReferences(const ActionReferences &) = delete;
  ActionReferences &operator=(const ActionReferences &) = delete;
  ActionReferences(ActionReferences &&) = delete;
  ActionReferences &operator=(ActionReferences &&) = delete;

  void keep(BindingAction action) {
    if (action.kind != BindingActionKind::extended) {
      return;
    }

    if (count_ == MaximumReferences) {
      luaL_unref(state_, LUA_REGISTRYINDEX, action.reference);

      throw std::length_error{"Too many component action references"};
    }

    references_[count_++] = action;
  }

  [[nodiscard]] bool contains(BindingAction action) const noexcept {
    return std::ranges::contains(std::span{references_}.first(count_), action);
  }

  // Release actions omitted by the final fit, including empty containers.
  template <Capacity Bounds>
  void keepOnly(const Content<Bounds> &content) {
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

  void swap(ActionReferences &other) noexcept {
    std::swap(state_, other.state_);
    references_.swap(other.references_);
    std::swap(count_, other.count_);
  }

  void clear() noexcept {
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
  explicit ActionReader(const Reader &reader, ActionReferences<Capacity> &references, std::uint32_t &next_reference) noexcept
      : reader_(reader),
        references_(references),
        next_reference_(next_reference) {}

  [[nodiscard]] std::optional<BindingAction> read(const runtime::lua::Value &value) const {
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
