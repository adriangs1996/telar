#pragma once

#include "action_references.hpp"
#include "config/limit_notices.hpp"
#include "content.hpp"
#include "content_reader.hpp"
#include "input/action.hpp"
#include "lua/value.hpp"
#include <cstdint>
#include <lua.h>
#include <utility>

namespace telar::gui::components {

template <Capacity Bounds>
class Snapshot {
public:
  explicit Snapshot(lua_State &state) noexcept
      : state_(state),
        references_(state) {}

  template <typename Actions>
  void read(const runtime::lua::Value &value, const Actions &actions, runtime::config::LimitNotices &limits, StagedContent &staged, std::uint32_t &next_reference) {
    ActionReferences<StagedContent::capacity.actions> pending{state_};
    const ActionReader reader{actions, pending, next_reference};
    Content<Bounds> next;
    constexpr auto surface = Bounds.nodes == PanelContent::capacity.nodes ? Surface::panel : Surface::bar;
    ContentReader{state_, reader, limits, staged, surface}.read(value, next);
    pending.keepOnly(next);
    references_.swap(pending);
    content_ = std::move(next);
  }

  [[nodiscard]] const Content<Bounds> &content() const noexcept {
    return content_;
  }

  [[nodiscard]] bool contains(BindingAction action) const noexcept {
    return references_.contains(action);
  }

  void clear() noexcept {
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
