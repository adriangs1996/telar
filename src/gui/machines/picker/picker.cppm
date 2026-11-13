module;
#include <cstdio>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include "tbc/view.hpp"



export module telar.gui.machines.picker;

import std;

export import telar.gui.machines.discovery;


export import telar.gui.machines.profile_store;


export import telar.gui.palette.navigation_label;
import telar.base.memory;
import telar.client.protocol;

// Interface: machines/machine_row.cppm
export {
namespace telar::gui {

struct MachineFields {
  MachineId id{};
  std::string_view label;
  std::string_view destination;
  std::optional<std::string_view> color = std::nullopt;
  bool enabled = true;
  std::optional<std::string_view> program = std::nullopt;
};

enum class MachinePhase : std::uint8_t {
  connecting,
  connected,
  lost,
  failed,
  stopped,
};

struct MachineMetrics {
  std::uint8_t cpu_percent = 0;
  std::uint16_t cpu_count = 0;
  std::uint16_t memory_used_decigib = 0;
  std::uint16_t memory_total_decigib = 0;
};

struct MachineObservation {
  MachinePhase phase = MachinePhase::connecting;
  bool needs_setup = false;
  bool attention = false;
  std::optional<MachineMetrics> metrics = std::nullopt;
  std::uint64_t metrics_revision = 0;
  std::uint64_t agent_revision = 0;
  std::uint64_t workspace_revision = 0;
  std::uint64_t now_ns = 0;
};

struct MachineRow {
  bool used = false;
  std::uint64_t generation = 0;
  MachineId id;
  runtime::FixedText<MachineLimits::label_bytes> label;
  runtime::FixedText<MachineLimits::destination_bytes> destination;
  runtime::FixedText<MachineLimits::color_bytes> color;
  runtime::FixedText<MachineLimits::program_bytes> program;
  bool enabled = false;
  bool pinned = false;
  bool live = false;
  MachinePhase phase = MachinePhase::connecting;
  bool needs_setup = false;
  bool attention = false;
  std::optional<std::uint8_t> cpu_percent;
  std::uint16_t cpu_count = 0;
  std::uint16_t memory_used_decigib = 0;
  std::uint16_t memory_total_decigib = 0;
  std::uint64_t sampled_ns = 0;
  std::uint64_t metrics_revision = 0;
  std::uint64_t agent_revision = 0;
  std::uint64_t workspace_revision = 0;

  inline void write(MachineFields fields) {
    id = fields.id;
    label.assign(fields.label.substr(0, MachineLimits::label_bytes));
    destination.assign(fields.destination.substr(0, MachineLimits::destination_bytes));
    color.assign(fields.color.value_or("").substr(0, MachineLimits::color_bytes));
    const auto path = fields.program.value_or("");
    program.assign(path.size() <= MachineLimits::program_bytes ? path : std::string_view{});
    enabled = fields.enabled;
  }
};

}
}

// Interface: machines/machine_token.cppm
export {
namespace telar::gui {

struct MachineToken {
  std::uint8_t slot = 0;
  std::uint64_t generation = 0;

  bool operator==(const MachineToken &) const noexcept = default;
};

}
}

// Interface: machines/machines.cppm
export {
namespace telar::gui {

class Machines {
public:
  using Slot = std::uint8_t;
  static constexpr Slot local_slot = 0;
  static constexpr std::size_t capacity = MachineLimits::window_slots;

  [[nodiscard]] inline Slot add(MachineFields fields, std::optional<Slot> wanted = std::nullopt) {
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

  inline void update(Slot slot, MachineFields fields) {
    auto &row = require(slot);
    if (row.destination.view() != fields.destination) {
      row.generation = next_generation_++;
    }

    row.write(fields);
    ++revision_;
  }

  inline void remove(Slot slot) {
    auto &row = requireRemote(slot);
    row.used = false;
    row.enabled = false;
    row.pinned = false;
    row.id = {};
    ++revision_;
  }

  [[nodiscard]] inline const MachineRow &row(Slot slot) const {
    return rows_.at(slot);
  }

  [[nodiscard]] inline std::span<const MachineRow> rows() const noexcept {
    return rows_;
  }

  [[nodiscard]] inline std::optional<Slot> find(MachineId id) const noexcept {
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

  [[nodiscard]] inline std::optional<Slot> findDestination(std::string_view destination) const noexcept {
    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (rows_[slot].used && rows_[slot].destination.view() == destination) {
        return static_cast<Slot>(slot);
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] inline std::size_t count() const noexcept {
    std::size_t count = 0;
    for (const auto &row : rows_) {
      count += static_cast<std::size_t>(row.used && row.enabled);
    }

    return count;
  }

  [[nodiscard]] inline bool shown(Slot slot) const {
    const auto &entry = row(slot);

    return entry.used && entry.enabled;
  }

  [[nodiscard]] inline bool attentionElsewhere() const noexcept {
    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (slot != active_ && rows_[slot].used && rows_[slot].attention) {
        return true;
      }
    }

    return false;
  }

  [[nodiscard]] inline MachineToken token(Slot slot) const {
    return {.slot = slot, .generation = row(slot).generation};
  }

  [[nodiscard]] inline bool contains(MachineToken token) const noexcept {
    return token.slot < capacity && rows_[token.slot].used && rows_[token.slot].generation == token.generation;
  }

  [[nodiscard]] inline Slot active() const noexcept {
    return active_;
  }

  inline bool select(Slot slot) {
    if (slot == active_ || !shown(slot) || !row(slot).live) {
      return false;
    }

    active_ = slot;
    ++revision_;

    return true;
  }

  inline void setLive(Slot slot, bool live) {
    rows_.at(slot).live = live;
  }

  inline void pin(Slot slot) {
    auto &row = requireRemote(slot);
    row.pinned = row.id.value() == 0 || !row.enabled;
    row.enabled = true;
    ++revision_;
  }

  inline void unpin(Slot slot) {
    requireRemote(slot).pinned = false;
  }

  inline bool summarize(Slot slot, const MachineObservation &observation) {
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

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

private:
  [[nodiscard]] inline std::optional<Slot> freeSlot() const noexcept {
    for (std::size_t slot = 1; slot < capacity; ++slot) {
      if (!rows_[slot].used && slot != active_) {
        return static_cast<Slot>(slot);
      }
    }

    return std::nullopt;
  }

  inline MachineRow &require(Slot slot) {
    auto &row = rows_.at(slot);
    if (!row.used) {
      throw std::logic_error{"MachineSlotNotUsed"};
    }

    return row;
  }

  inline MachineRow &requireRemote(Slot slot) {
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
}

// Interface: machines/opening.cppm
export {
namespace telar::gui {

struct MachineOpening {
  // The destination is one of the profiles', region `a`.
  [[nodiscard]] inline static tbc::view<std::optional<std::string_view>, tbc::lt::a> saved(tbc::view<const MachineProfiles &, tbc::lt::a> profiles, std::string_view label, std::string_view hostname) {
    if (const auto index = profiles.find(label)) {
      return profiles.rows()[*index].destination();
    }

    if (profiles.localLabel().value_or(hostname) == label) {
      return std::nullopt;
    }

    throw MachineFailure{MachineError::unknown_machine};
  }

  [[nodiscard]] inline static std::optional<Machines::Slot> admitted(const Machines &machines, std::string_view name) noexcept {
    const auto rows = machines.rows();
    for (std::size_t index = 1; index < Machines::capacity; ++index) {
      const auto slot = static_cast<Machines::Slot>(index);
      const auto &row = rows[index];
      if (row.used && (row.label.view() == name || row.destination.view() == name)) {
        return slot;
      }
    }

    return std::nullopt;
  }
};

}
}

// Interface: machines/picker.cppm
export {
namespace telar::gui {

struct MachinePicker {
  using Matches = RankedMatches<MachineToken, Machines::capacity>;

  enum class Intent : std::uint8_t {
    none,
    add,
    select,
    setup,
    enable,
    disable,
  };

  [[nodiscard]] inline static Matches collect(const Machines &machines, std::string_view query) {
    Matches matches;
    for (std::size_t index = 0; index < Machines::capacity; ++index) {
      const auto slot = static_cast<Machines::Slot>(index);
      const auto &row = machines.row(slot);
      if (!row.used) {
        continue;
      }

      auto score = runtime::historyScore(row.label.view(), query);
      if (!score) {
        score = runtime::historyScore(row.destination.view(), query);
      }

      if (score) {
        matches.addScored(machines.token(slot), *score);
      }
    }

    return matches;
  }

  [[nodiscard]] inline static Intent choose(const Machines &machines, std::optional<MachineToken> chosen, bool alternate) {
    if (!chosen) {
      return Intent::add;
    }

    if (!machines.contains(*chosen)) {
      return Intent::none;
    }

    if (chosen->slot == Machines::local_slot) {
      return alternate ? Intent::none : Intent::select;
    }

    const auto &row = machines.row(chosen->slot);
    if (!alternate && row.needs_setup) {
      return Intent::setup;
    }

    if (alternate || !row.enabled) {
      return row.enabled ? Intent::disable : Intent::enable;
    }

    return Intent::select;
  }
};

}
}

// Interface: machines/picker_target.cppm
export {
namespace telar::gui {

struct MachinePickerTarget {
  std::optional<MachineToken> machine;
};

}
}
