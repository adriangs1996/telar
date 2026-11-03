#pragma once

#include "telar_config/component_shape.hpp"
#include "telar_config/limit_notices.hpp"

namespace telar::runtime::config {

class ComponentBudget {
public:
  struct Usage {
    std::size_t nodes = 0;
    std::size_t text = 0;
    std::size_t actions = 0;
    std::size_t samples = 0;

    Usage operator+(Usage other) const noexcept {
      return {nodes + other.nodes, text + other.text, actions + other.actions, samples + other.samples};
    }

    Usage operator-(Usage other) const noexcept {
      return {nodes - other.nodes, text - other.text, actions - other.actions, samples - other.samples};
    }

    bool fits(Usage room) const noexcept {
      return nodes <= room.nodes && text <= room.text && actions <= room.actions && samples <= room.samples;
    }
  };

  void count(const ComponentShape &shape, unsigned rank) noexcept {
    const auto needed = usage(shape);
    offered_ = offered_ + needed;
    ranked_[rank] = ranked_[rank] + needed;
  }

  void prepare() noexcept {
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

  bool admit(const ComponentShape &shape, unsigned rank) noexcept {
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

  void release(const ComponentShape &shape, unsigned rank) noexcept {
    if (rank == cutoff_) {
      taken_ = taken_ - usage(shape);
    }
  }

  bool stage(const ComponentShape &shape) noexcept {
    const auto next = staged_ + usage(shape);
    if (!next.fits(staging_capacity)) {
      return false;
    }
    staged_ = next;
    return true;
  }

  bool nodesFull() const noexcept {
    return staged_.nodes == staging_capacity.nodes;
  }

  void report(LimitNotices &limits) const noexcept {
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
  static Usage usage(const ComponentShape &shape) noexcept {
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
