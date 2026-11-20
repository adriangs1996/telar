module;
#include "tbc/annotations.hpp"

export module telar.runtime.metrics.monitor;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.host.host_metrics;
import telar.runtime.host.process_probe;
import telar.runtime.host.process_table;
import telar.wire.monitor;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: metrics/monitor.cppm
export {
  namespace telar::runtime {

    // A pane's shell: every process the pane runs descends from it.
    struct PaneRoot {
      pid_t process = 0;
      std::uint64_t pane_id = 0;
      // An agent runs in the pane now.
      bool agent = false;
    };

    // What one query asks, as the sampler answers it.
    struct MonitorView {
      std::uint8_t sections = MonitorSections::all;
      MonitorSort sort = MonitorSort::cpu;
      bool reverse = false;
      MonitorScope scope = MonitorScope::all;
      bool tree = false;
      FixedText<MonitorLimits::filter_bytes> filter;
      std::uint16_t limit = 0;
      ProcessInstance detail{};
    };

    // A process of the table with what the monitor derives from it. The text is read once, when the
    // instance first appears, since a process keeps its command line and its user for its life.
    struct MonitorEntry {
      ProcessRecord record;
      std::uint32_t cpu_permille = 0;
      std::uint64_t pane_id = 0;
      // The agent this process is.
      AgentProvider agent = AgentProvider::unknown;
      // It is an agent or descends from one.
      bool under_agent = false;
      bool described = false;
      FixedText<MonitorLimits::name_bytes> name;
      FixedText<MonitorLimits::user_bytes> user;
      FixedText<MonitorLimits::command_bytes> command;
    };

    inline constexpr std::size_t maximum_monitor_answers = 16;

    // The answers of one round, in the order of its queries; none for a query that names a process
    // that is gone or was replaced.
    using MonitorAnswers = ds::Array<ds::Option<MonitorSnapshot>, maximum_monitor_answers>;

    // A user's name as the sampler caches it.
    struct UserName {
      uid_t user = 0;
      FixedText<MonitorLimits::user_bytes> name;
    };

    // Keeps the processes and the host between readings and answers queries about them. A reading
    // allocates only when the table outgrows every earlier one; an answer views the sampler and stays
    // valid until the next reading or the next round of answers, so the sampler never moves.
    class MonitorSampler {
    public:
      using Clock = std::chrono::steady_clock;
      static constexpr std::size_t maximum_answers = maximum_monitor_answers;

      MonitorSampler(tbc::mut_a<ConcurrentMemory> memory, tbc::ref_a<ProcessInspector> inspector);
      ~MonitorSampler() = default;
      MonitorSampler(const MonitorSampler&) = delete;
      MonitorSampler& operator=(const MonitorSampler&) = delete;
      MonitorSampler(MonitorSampler&&) = delete;
      MonitorSampler& operator=(MonitorSampler&&) = delete;

      // Takes the processes, leaving the previous reading's storage in `records` for the next one.
      void update(ds::Vec<ProcessRecord, ConcurrentMemory>& records, const HostDetail& host, Clock::time_point now, std::span<const PaneRoot> roots);

      // Two readings were taken, so CPU and rates are known.
      [[nodiscard]] bool ready() const noexcept;

      // Answers a round of at most maximum_answers queries, but for their request ids, dropping the
      // previous round's answers.
      MonitorAnswers answer(std::span<const MonitorView> views);

      [[nodiscard]] std::span<const MonitorEntry> entries() const noexcept;

      // The entry of the instance, of any instance when its start is zero.
      [[nodiscard]] const MonitorEntry* find(const ProcessInstance& instance) const noexcept;

    private:
      struct DetailText {
        // A process that started after the last reading, read for this answer.
        MonitorEntry fresh{};
        // The entry the detail is of, or none for `fresh`.
        ds::Option<std::uint32_t> entry;
        FixedText<MonitorLimits::arguments_bytes> arguments;
        FixedText<MonitorLimits::directory_bytes> directory;
        ListeningPorts ports{};
        ds::Array<std::int32_t, MonitorLimits::maximum_children> children{};
        std::uint16_t child_count = 0;
      };

      void attribute(std::span<const PaneRoot> roots);
      void measureHost(const HostDetail& host, double seconds);
      [[nodiscard]] static bool matches(const MonitorEntry& entry, const MonitorView& view) noexcept;
      [[nodiscard]] static bool before(const MonitorEntry& left, const MonitorEntry& right, const MonitorView& view) noexcept;

      // Where a query's rows and detail are written.
      struct Placement {
        bool found = true;
        std::size_t first = 0;
        std::size_t count = 0;
        std::uint32_t matched = 0;
        ds::Option<std::size_t> detail;
      };

      using Placements = ds::Array<Placement, maximum_answers>;

      // Writes the rows and the detail of each query, dropping the previous round's; where each is.
      Placements place(std::span<const MonitorView> views);
      [[nodiscard]] ds::Option<std::uint32_t> indexOf(pid_t process) const noexcept;
      bool detail(const ProcessInstance& instance);
      void select(const MonitorView& view);
      void selectTree(const MonitorView& view);

      tbc::mut_a<ConcurrentMemory> memory_;
      tbc::val_a<ProcessInspector> inspector_;
      // Sorted by pid.
      tbc::val_a<ds::Vec<MonitorEntry, ConcurrentMemory>> entries_;
      tbc::val_a<ds::Vec<MonitorEntry, ConcurrentMemory>> previous_;
      tbc::val_a<ds::Vec<UserName, ConcurrentMemory>> users_;
      // Scratch: the selection of one query, with the depth of each row in a tree.
      tbc::val_a<ds::Vec<std::uint32_t, ConcurrentMemory>> selected_;
      tbc::val_a<ds::Vec<std::uint8_t, ConcurrentMemory>> depths_;
      tbc::val_a<ds::Vec<std::uint32_t, ConcurrentMemory>> ordered_;
      tbc::val_a<ds::Vec<std::uint8_t, ConcurrentMemory>> flags_;
      tbc::val_a<ds::Vec<std::pair<std::uint32_t, std::uint8_t>, ConcurrentMemory>> stack_;
      // What the answers of a round view.
      tbc::val_self<ds::Vec<MonitorProcess, ConcurrentMemory>> rows_;
      tbc::val_a<ds::Vec<DetailText, ConcurrentMemory>> details_;
      ds::Option<Clock::time_point> sampled_;
      std::uint32_t readings_ = 0;

      HostDetail host_{};
      ds::Array<std::uint16_t, HostDetail::maximum_cores> cores_{};
      std::uint16_t cpu_permille_ = 0;
      std::uint64_t disk_read_per_second_ = 0;
      std::uint64_t disk_written_per_second_ = 0;
      // They view host_.
      tbc::val_self<ds::Array<MonitorInterface, HostDetail::maximum_interfaces>> interfaces_{};
      tbc::val_self<ds::Array<MonitorDisk, HostDetail::maximum_mounts>> disks_{};
      std::uint32_t thread_count_ = 0;
    };

  }
}
