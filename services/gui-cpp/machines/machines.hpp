#pragma once

#include "failure.hpp"
#include "identity.hpp"
#include "limits.hpp"
#include "machine_row.hpp"
#include "machine_token.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class Machines {
public:
  using Slot = std::uint8_t;
  static constexpr Slot local_slot = 0;
  static constexpr std::size_t capacity = MachineLimits::slots;

  [[nodiscard]] Slot add(MachineFields fields, std::optional<Slot> wanted = std::nullopt) {
    const auto slot = wanted ? wanted : freeSlot();
    if (!slot) {
      throw MachineFailure{MachineError::too_many};
    }

    auto &row = rows_.at(*slot);
    if (row.used) {
      throw std::logic_error{"MachineSlotAlreadyUsed"};
    }

    const auto live = row.live;
    row = {};
    row.live = live;
    row.used = true;
    row.generation = next_generation_++;
    row.write(fields);
    ++revision_;

    return *slot;
  }

  void update(Slot slot, MachineFields fields) {
    auto &row = require(slot);
    if (row.destination.view() != fields.destination) {
      row.generation = next_generation_++;
    }

    row.write(fields);
    ++revision_;
  }

  void remove(Slot slot) {
    auto &row = requireRemote(slot);
    row.used = false;
    row.enabled = false;
    row.pinned = false;
    row.id = {};
    ++revision_;
  }

  [[nodiscard]] const MachineRow &row(Slot slot) const {
    return rows_.at(slot);
  }

  [[nodiscard]] std::span<const MachineRow> rows() const noexcept {
    return rows_;
  }

  [[nodiscard]] std::optional<Slot> find(MachineId id) const noexcept {
    if (id.value() == 0) {
      return std::nullopt;
    }

    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (rows_[slot].used && rows_[slot].id == id) {
        return static_cast<Slot>(slot);
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] std::optional<Slot> findDestination(std::string_view destination) const noexcept {
    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (rows_[slot].used && rows_[slot].destination.view() == destination) {
        return static_cast<Slot>(slot);
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] std::size_t count() const noexcept {
    std::size_t count = 0;
    for (const auto &row : rows_) {
      count += static_cast<std::size_t>(row.used && row.enabled);
    }

    return count;
  }

  [[nodiscard]] bool shown(Slot slot) const {
    const auto &entry = row(slot);

    return entry.used && entry.enabled;
  }

  [[nodiscard]] bool attentionElsewhere() const noexcept {
    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (slot != active_ && rows_[slot].used && rows_[slot].attention) {
        return true;
      }
    }

    return false;
  }

  [[nodiscard]] MachineToken token(Slot slot) const {
    return {.slot = slot, .generation = row(slot).generation};
  }

  [[nodiscard]] bool contains(MachineToken token) const noexcept {
    return token.slot < capacity && rows_[token.slot].used && rows_[token.slot].generation == token.generation;
  }

  [[nodiscard]] Slot active() const noexcept {
    return active_;
  }

  bool select(Slot slot) {
    if (slot == active_ || !shown(slot) || !row(slot).live) {
      return false;
    }

    active_ = slot;
    ++revision_;

    return true;
  }

  void setLive(Slot slot, bool live) {
    rows_.at(slot).live = live;
  }

  void pin(Slot slot) {
    auto &row = requireRemote(slot);
    row.pinned = row.id.value() == 0 || !row.enabled;
    row.enabled = true;
    ++revision_;
  }

  void unpin(Slot slot) {
    requireRemote(slot).pinned = false;
  }

  bool summarize(Slot slot, const MachineObservation &observation) {
    auto &row = require(slot);
    const bool needs_setup = observation.phase == MachinePhase::failed && observation.needs_setup;
    const bool metrics_changed = observation.metrics_revision != row.metrics_revision;
    const bool agents_changed = observation.agent_revision != row.agent_revision;
    const bool workspaces_changed = observation.workspace_revision != row.workspace_revision;
    if (row.phase == observation.phase && row.needs_setup == needs_setup && !metrics_changed && !agents_changed && !workspaces_changed) {
      return false;
    }

    if (metrics_changed) {
      row.metrics_revision = observation.metrics_revision;
      if (observation.metrics) {
        row.cpu_count = observation.metrics->cpu_count;
        row.memory_used_decigib = observation.metrics->memory_used_decigib;
        row.memory_total_decigib = observation.metrics->memory_total_decigib;
        row.sampled_ns = observation.now_ns;
      }
    }

    const bool attention = agents_changed ? observation.attention : row.attention;
    row.agent_revision = observation.agent_revision;
    row.workspace_revision = observation.workspace_revision;
    const auto cpu = observation.metrics ? std::optional{observation.metrics->cpu_percent} : std::nullopt;
    if (row.phase == observation.phase && row.needs_setup == needs_setup && row.attention == attention && row.cpu_percent == cpu && !agents_changed && !workspaces_changed) {
      return false;
    }

    row.phase = observation.phase;
    row.needs_setup = needs_setup;
    row.attention = attention;
    row.cpu_percent = cpu;
    ++revision_;

    return true;
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

private:
  [[nodiscard]] std::optional<Slot> freeSlot() const noexcept {
    for (std::size_t slot = 1; slot < capacity; ++slot) {
      if (!rows_[slot].used && slot != active_) {
        return static_cast<Slot>(slot);
      }
    }

    return std::nullopt;
  }

  MachineRow &require(Slot slot) {
    auto &row = rows_.at(slot);
    if (!row.used) {
      throw std::logic_error{"MachineSlotNotUsed"};
    }

    return row;
  }

  MachineRow &requireRemote(Slot slot) {
    if (slot == local_slot) {
      throw std::logic_error{"LocalMachineCannotBeRemoved"};
    }

    return require(slot);
  }

  std::array<MachineRow, capacity> rows_;
  std::uint64_t next_generation_ = 1;
  Slot active_ = local_slot;
  std::uint64_t revision_ = 0;
};

}
