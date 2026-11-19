module;
#include "tbc/annotations.hpp"

export module telar.runtime.metrics.monitor;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.platform.host_metrics;
import telar.runtime.platform.process_probe;
import telar.runtime.platform.process_table;
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
      FixedText<MonitorLimits::filter_bytes> filter{};
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
      FixedText<MonitorLimits::name_bytes> name{};
      FixedText<MonitorLimits::user_bytes> user{};
      FixedText<MonitorLimits::command_bytes> command{};
    };

    // Keeps the processes and the host between readings and answers queries about them. A reading
    // allocates only when the table outgrows every earlier one; an answer views the sampler and stays
    // valid until the next reading or the next round of answers.
    class MonitorSampler {
    public:
      using Clock = std::chrono::steady_clock;
      static constexpr std::size_t maximum_answers = 16;

      MonitorSampler(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, const ProcessInspector& inspector);

      // Takes the processes, leaving the previous reading's storage in `records` for the next one.
      void update(ds::Vec<ProcessRecord, ConcurrentMemory>& records, const HostDetail& host, Clock::time_point now, std::span<const PaneRoot> roots);

      // Two readings were taken, so CPU and rates are known.
      [[nodiscard]] bool ready() const noexcept;

      // Starts a round of at most maximum_answers answers listing `rows` processes together,
      // dropping the previous round's.
      void beginAnswers(std::size_t count, std::size_t rows);

      // Fills the snapshot except its request id. False when the query names a process that is
      // gone or was replaced; the snapshot is then left as it was.
      bool answer(const MonitorView& view, MonitorSnapshot& snapshot);

      [[nodiscard]] std::span<const MonitorEntry> entries() const noexcept;

      // The entry of the instance, of any instance when its start is zero.
      [[nodiscard]] const MonitorEntry* find(const ProcessInstance& instance) const noexcept;

    private:
      struct UserName {
        uid_t user = 0;
        FixedText<MonitorLimits::user_bytes> name{};
      };

      struct DetailText {
        // A process that started after the last reading, read for this answer.
        MonitorEntry fresh{};
        FixedText<MonitorLimits::arguments_bytes> arguments{};
        FixedText<MonitorLimits::directory_bytes> directory{};
        ListeningPorts ports{};
        ds::Array<std::int32_t, MonitorLimits::maximum_children> children{};
        std::uint16_t child_count = 0;
      };

      void describe(MonitorEntry& entry);
      FixedText<MonitorLimits::user_bytes> userName(uid_t user);
      void attribute(std::span<const PaneRoot> roots);
      void measureHost(const HostDetail& host, double seconds);
      [[nodiscard]] bool matches(const MonitorEntry& entry, const MonitorView& view) const noexcept;
      [[nodiscard]] bool before(const MonitorEntry& left, const MonitorEntry& right, const MonitorView& view) const noexcept;
      [[nodiscard]] ds::Option<std::uint32_t> indexOf(pid_t process) const noexcept;
      void select(const MonitorView& view);
      void selectTree(const MonitorView& view);
      MonitorProcess row(const MonitorEntry& entry, std::uint8_t depth) const noexcept;

      tbc::view<ConcurrentMemory&, tbc::lt::a> memory_;
      ProcessInspector inspector_;
      // Sorted by pid.
      tbc::view<ds::Vec<MonitorEntry, ConcurrentMemory>, tbc::lt::a> entries_;
      tbc::view<ds::Vec<MonitorEntry, ConcurrentMemory>, tbc::lt::a> previous_;
      tbc::view<ds::Vec<UserName, ConcurrentMemory>, tbc::lt::a> users_;
      // Scratch: the selection of one query, with the depth of each row in a tree.
      tbc::view<ds::Vec<std::uint32_t, ConcurrentMemory>, tbc::lt::a> selected_;
      tbc::view<ds::Vec<std::uint8_t, ConcurrentMemory>, tbc::lt::a> depths_;
      tbc::view<ds::Vec<std::uint32_t, ConcurrentMemory>, tbc::lt::a> ordered_;
      tbc::view<ds::Vec<std::uint8_t, ConcurrentMemory>, tbc::lt::a> flags_;
      tbc::view<ds::Vec<std::pair<std::uint32_t, std::uint8_t>, ConcurrentMemory>, tbc::lt::a> stack_;
      // What the answers of a round view.
      tbc::view<ds::Vec<MonitorProcess, ConcurrentMemory>, tbc::lt::a> rows_;
      tbc::view<ds::Vec<DetailText, ConcurrentMemory>, tbc::lt::a> details_;
      ds::Option<Clock::time_point> sampled_;
      std::uint32_t readings_ = 0;

      HostDetail host_{};
      ds::Array<std::uint16_t, HostDetail::maximum_cores> cores_{};
      std::uint16_t cpu_permille_ = 0;
      std::uint64_t disk_read_per_second_ = 0;
      std::uint64_t disk_written_per_second_ = 0;
      ds::Array<MonitorInterface, HostDetail::maximum_interfaces> interfaces_{};
      ds::Array<MonitorDisk, HostDetail::maximum_mounts> disks_{};
      std::uint32_t thread_count_ = 0;
    };

  }
}
