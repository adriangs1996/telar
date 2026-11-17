export module telar.gui.machines.picker;

import std;
import telar.tbc;

import telar.gui.machines.discovery;

import telar.gui.machines.profile_store;

import telar.gui.palette.navigation_label;
import telar.gui.foundation.model;
import telar.gui.foundation.text;
import telar.base.memory.containers;
import telar.wire.vocabulary;

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

      void write(MachineFields fields);
    };

  }
}

// Interface: machines/machine_token.cppm
export {
  namespace telar::gui {

    struct MachineToken {
      std::uint8_t slot = 0;
      std::uint64_t generation = 0;

      bool operator==(const MachineToken&) const noexcept = default;
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

      [[nodiscard]] Slot add(MachineFields fields, std::optional<Slot> wanted = std::nullopt);

      void update(Slot slot, MachineFields fields);

      void remove(Slot slot);

      [[nodiscard]] const MachineRow& row(Slot slot) const;

      [[nodiscard]] std::span<const MachineRow> rows() const noexcept;

      [[nodiscard]] std::optional<Slot> find(MachineId id) const noexcept;

      [[nodiscard]] std::optional<Slot> findDestination(std::string_view destination) const noexcept;

      [[nodiscard]] std::size_t count() const noexcept;

      [[nodiscard]] bool shown(Slot slot) const;

      [[nodiscard]] bool attentionElsewhere() const noexcept;

      [[nodiscard]] MachineToken token(Slot slot) const;

      [[nodiscard]] bool contains(MachineToken token) const noexcept;

      [[nodiscard]] Slot active() const noexcept;

      bool select(Slot slot);

      void setLive(Slot slot, bool live);

      void pin(Slot slot);

      void unpin(Slot slot);

      bool summarize(Slot slot, const MachineObservation& observation);

      [[nodiscard]] std::uint64_t revision() const noexcept;

    private:
      [[nodiscard]] std::optional<Slot> freeSlot() const noexcept;

      MachineRow& require(Slot slot);

      MachineRow& requireRemote(Slot slot);

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
      [[nodiscard]] static tbc::view<std::optional<std::string_view>, tbc::lt::a> saved(tbc::view<const MachineProfiles&, tbc::lt::a> profiles, std::string_view label, std::string_view hostname);

      [[nodiscard]] static std::optional<Machines::Slot> admitted(const Machines& machines, std::string_view name) noexcept;
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

      [[nodiscard]] static Matches collect(const Machines& machines, std::string_view query);

      [[nodiscard]] static Intent choose(const Machines& machines, std::optional<MachineToken> chosen, bool alternate);
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

// Interface: machines/machine_client_key.cppm
export {
  namespace telar::gui {

    struct MachineClientKey {
      MachineToken machine;
      std::uint64_t generation = 0;

      bool operator==(const MachineClientKey&) const noexcept = default;
    };

  }
}

// Interface: machines/machine_activity_target.cppm
export {
  namespace telar::gui {

    struct MachineActivityTarget {
      struct Agent {
        AgentNavigationTarget key;
        decltype(AgentSnapshotEntry::session_id) session;
      };

      struct Command {
        std::uint64_t worktree;
        std::uint64_t workspace;
      };

      // A pane no agent holds, listed by the process in its foreground.
      struct Process {
        std::uint64_t pane_id;
        std::uint64_t pane_generation;
      };

      MachineClientKey source;
      std::uint64_t runtime_generation;
      std::variant<Agent, Command, Process> owner;
    };

  }
}
