module telar.gui.features.machines;

import telar.base.ds;

namespace telar::gui::features::machines {

  void MachineRow::write(MachineFields fields) {
    id = fields.id;
    label.assign(fields.label.substr(0, MachineLimits::label_bytes));
    destination.assign(fields.destination.substr(0, MachineLimits::destination_bytes));
    color.assign(fields.color.valueOr("").substr(0, MachineLimits::color_bytes));
    const auto path = fields.program.valueOr("");

    program.assign(path.size() <= MachineLimits::program_bytes ? path : std::string_view{});
    enabled = fields.enabled;
  }

  Machines::Slot Machines::add(MachineFields fields, ds::Option<Slot> wanted) {
    const auto slot = wanted ? wanted : freeSlot();
    if (!slot) {
      throw MachineFailure{MachineError::too_many};
    }

    auto& row = rows_.atCheckedMut(*slot);
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

  void Machines::update(Slot slot, MachineFields fields) {
    auto& row = require(slot);
    if (row.destination.view() != fields.destination) {
      row.generation = next_generation_++;
    }

    row.write(fields);
    ++revision_;
  }

  void Machines::remove(Slot slot) {
    auto& row = requireRemote(slot);

    row.used = false;
    row.enabled = false;
    row.pinned = false;
    row.id = {};
    ++revision_;
  }

  const MachineRow& Machines::row(Slot slot) const {
    return rows_.at(slot);
  }

  std::span<const MachineRow> Machines::rows() const noexcept {
    return rows_;
  }

  ds::Option<Machines::Slot> Machines::find(MachineId id) const noexcept {
    if (id.value() == 0) {
      return ds::none;
    }

    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (rows_[slot].used && rows_[slot].id == id) {
        return static_cast<Slot>(slot);
      }
    }

    return ds::none;
  }

  ds::Option<Machines::Slot> Machines::findDestination(std::string_view destination) const noexcept {
    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (rows_[slot].used && rows_[slot].destination.view() == destination) {
        return static_cast<Slot>(slot);
      }
    }

    return ds::none;
  }

  std::size_t Machines::count() const noexcept {
    std::size_t count = 0;

    for (const auto& row : rows_) {
      count += static_cast<std::size_t>(row.used && row.enabled);
    }

    return count;
  }

  bool Machines::shown(Slot slot) const {
    const auto& entry = row(slot);

    return entry.used && entry.enabled;
  }

  bool Machines::attentionElsewhere() const noexcept {
    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (slot != active_ && rows_[slot].used && rows_[slot].attention) {
        return true;
      }
    }

    return false;
  }

  MachineToken Machines::token(Slot slot) const {
    return {.slot = slot, .generation = row(slot).generation};
  }

  bool Machines::contains(MachineToken token) const noexcept {
    return token.slot < capacity && rows_[token.slot].used && rows_[token.slot].generation == token.generation;
  }

  Machines::Slot Machines::active() const noexcept {
    return active_;
  }

  bool Machines::select(Slot slot) {
    if (slot == active_ || !shown(slot) || !row(slot).live) {
      return false;
    }

    active_ = slot;
    ++revision_;

    return true;
  }

  void Machines::setLive(Slot slot, bool live) {
    rows_.atCheckedMut(slot).live = live;
  }

  void Machines::pin(Slot slot) {
    auto& row = requireRemote(slot);

    row.pinned = row.id.value() == 0 || !row.enabled;
    row.enabled = true;
    ++revision_;
  }

  void Machines::unpin(Slot slot) {
    requireRemote(slot).pinned = false;
  }

  bool Machines::summarize(Slot slot, const MachineObservation& observation) {
    auto& row = require(slot);
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
    const auto cpu = observation.metrics ? ds::Option{observation.metrics->cpu_percent} : ds::none;
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

  std::uint64_t Machines::revision() const noexcept {
    return revision_;
  }

  ds::Option<Machines::Slot> Machines::freeSlot() const noexcept {
    for (std::size_t slot = 1; slot < capacity; ++slot) {
      if (!rows_[slot].used && slot != active_) {
        return static_cast<Slot>(slot);
      }
    }

    return ds::none;
  }

  MachineRow& Machines::require(Slot slot) {
    auto& row = rows_.atCheckedMut(slot);
    if (!row.used) {
      throw std::logic_error{"MachineSlotNotUsed"};
    }

    return row;
  }

  MachineRow& Machines::requireRemote(Slot slot) {
    if (slot == local_slot) {
      throw std::logic_error{"LocalMachineCannotBeRemoved"};
    }

    return require(slot);
  }

  tbc::view<ds::Option<std::string_view>, tbc::lt::a> MachineOpening::saved(tbc::view<const MachineProfiles&, tbc::lt::a> profiles, std::string_view label, std::string_view hostname) {
    if (const auto index = profiles.find(label)) {
      return profiles.rows()[*index].destination();
    }

    if (profiles.localLabel().valueOr(hostname) == label) {
      return ds::none;
    }

    throw MachineFailure{MachineError::unknown_machine};
  }

  ds::Option<Machines::Slot> MachineOpening::admitted(const Machines& machines, std::string_view name) noexcept {
    const auto rows = machines.rows();

    for (std::size_t index = 1; index < Machines::capacity; ++index) {
      const auto slot = static_cast<Machines::Slot>(index);
      const auto& row = rows[index];
      if (row.used && (row.label.view() == name || row.destination.view() == name)) {
        return slot;
      }
    }

    return ds::none;
  }

  MachinePicker::Matches MachinePicker::collect(const Machines& machines, std::string_view query, Scorer score_of) {
    Matches matches;

    for (std::size_t index = 0; index < Machines::capacity; ++index) {
      const auto slot = static_cast<Machines::Slot>(index);
      const auto& row = machines.row(slot);
      if (!row.used) {
        continue;
      }

      auto score = score_of(row.label.view(), query);
      if (!score) {
        score = score_of(row.destination.view(), query);
      }

      if (score) {
        matches.addScored(machines.token(slot), *score);
      }
    }

    return matches;
  }

  MachinePicker::Intent MachinePicker::choose(const Machines& machines, ds::Option<MachineToken> chosen, bool alternate) {
    if (!chosen) {
      return Intent::add;
    }

    if (!machines.contains(*chosen)) {
      return Intent::none;
    }

    if (chosen->slot == Machines::local_slot) {
      return alternate ? Intent::none : Intent::select;
    }

    const auto& row = machines.row(chosen->slot);
    if (!alternate && row.needs_setup) {
      return Intent::setup;
    }

    if (alternate || !row.enabled) {
      return row.enabled ? Intent::disable : Intent::enable;
    }

    return Intent::select;
  }

}
