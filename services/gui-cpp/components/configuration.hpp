#pragma once

#include "content.hpp"
#include "input/action.hpp"
#include "snapshot.hpp"
#include "source.hpp"
#include "telar_config/limit_notices.hpp"
#include "telar_lua/value.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <lua.h>

namespace telar::gui::components {

class Configuration {
public:
  explicit Configuration(lua_State &state)
      : state_(state),
        bars_{BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}, BarSnapshot{state}},
        panel_(state) {}

  [[nodiscard]] Definitions &definitions() noexcept {
    return definitions_;
  }

  [[nodiscard]] const Definitions &definitions() const noexcept {
    return definitions_;
  }

  template <typename Actions>
  void readFixed(const Actions &actions, runtime::config::LimitNotices &limits) {
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
  void readBar(Position position, const runtime::lua::Value &value, const Actions &actions, runtime::config::LimitNotices &limits) {
    bars_.at(static_cast<std::size_t>(position)).read(value, actions, limits, staged_, next_reference_);
  }

  template <typename Actions>
  void readPanel(const runtime::lua::Value &value, const Actions &actions, runtime::config::LimitNotices &limits) {
    panel_.read(value, actions, limits, staged_, next_reference_);
  }

  [[nodiscard]] const BarContent &bar(Position position) const {
    return bars_.at(static_cast<std::size_t>(position)).content();
  }

  [[nodiscard]] const PanelContent &panel() const noexcept {
    return panel_.content();
  }

  void closePanel() noexcept {
    panel_.clear();
  }

  [[nodiscard]] bool contains(BindingAction action) const noexcept {
    return panel_.contains(action) || std::ranges::any_of(bars_, [action](const auto &bar) {
             return bar.contains(action);
           });
  }

  template <typename Visitor>
  void visitActions(const Visitor &visitor) const {
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
