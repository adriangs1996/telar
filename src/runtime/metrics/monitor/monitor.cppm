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
      MonitorLayout layout = MonitorLayout::flat;
      FixedText<MonitorLimits::filter_bytes> filter;
      std::uint32_t offset = 0;
      std::uint16_t limit = 0;
      bool fold = false;
      ds::Array<std::int32_t, MonitorLimits::maximum_toggled> toggled{};
      std::uint8_t toggled_count = 0;
      ProcessInstance detail{};

      // Whether the query folds or unfolds the branch of `pid` against the default.
      [[nodiscard]] bool toggles(std::int32_t pid) const noexcept;
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
      ProcessOwner owner = ProcessOwner::none;
      // It runs one of telar's programs beside the runtime.
      bool telar_program = false;
      bool described = false;
      FixedText<MonitorLimits::name_bytes> name;
      FixedText<MonitorLimits::user_bytes> user;
      FixedText<MonitorLimits::command_bytes> command;
    };

    inline constexpr std::size_t maximum_monitor_answers = 16;
    // The clients of the runtime the monitor names as telar's, beside the runtime itself.
    inline constexpr std::size_t maximum_monitor_clients = 64;

    // The answers of one round, in the order of its queries; none for a query that names a process
    // that is gone or was replaced.
    using MonitorAnswers = ds::Array<ds::Option<MonitorSnapshot>, maximum_monitor_answers>;

    // The exact paths of telar's programs beside the runtime, which the monitor names as telar's
    // whoever started them. Never a prefix: telar in /usr/bin would name half the system.
    struct TelarPrograms {
      static constexpr std::size_t maximum_programs = 2;

      ds::Array<FixedText<process_path_bytes>, maximum_programs> paths{};
      std::uint8_t count = 0;

      [[nodiscard]] bool contains(std::string_view path) const noexcept;
    };

    // `telar` and `telar-gateway` beside the runtime's own executable, those that are there: they are
    // built and installed together.
    [[nodiscard]] TelarPrograms siblingPrograms() noexcept;

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

      // A reading further than this from the one before follows a pause in the readings: the history
      // of the processor starts again after it.
      static constexpr auto history_gap = std::chrono::seconds{5};

      MonitorSampler(tbc::mut_a<ConcurrentMemory> memory, tbc::ref_a<ProcessInspector> inspector, const TelarPrograms& programs = {});
      ~MonitorSampler() = default;
      MonitorSampler(const MonitorSampler&) = delete;
      MonitorSampler& operator=(const MonitorSampler&) = delete;
      MonitorSampler(MonitorSampler&&) = delete;
      MonitorSampler& operator=(MonitorSampler&&) = delete;

      // Takes the processes, leaving the previous reading's storage in `records` for the next one.
      // `started_clock` is the time now on the clock the records' starts count
      // (ProcessTable::clock). `clients` are the processes connected to the runtime: its windows and
      // its CLI.
      void update(ds::Vec<ProcessRecord, ConcurrentMemory>& records, const HostDetail& host, Clock::time_point now, std::chrono::microseconds started_clock, std::span<const PaneRoot> roots, std::span<const pid_t> clients = {});

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
        // They view the names of entries_.
        ds::Array<MonitorRelative, MonitorLimits::maximum_children> children{};
        std::uint16_t child_count = 0;
        ds::Array<MonitorRelative, MonitorLimits::maximum_lineage> lineage{};
        std::uint8_t lineage_count = 0;
      };

      // One row of a query's listing.
      struct Listed {
        std::uint32_t index = 0;
        std::uint8_t depth = 0;
        std::uint32_t guides = 0;
        std::uint32_t folded = 0;
      };

      // What a tree adds up over an entry's branch, the entry included.
      struct Branch {
        std::uint64_t cpu_permille = 0;
        std::uint64_t resident_bytes = 0;
        std::uint32_t descendants = 0;
        std::uint16_t children = 0;
      };

      void attribute(std::span<const PaneRoot> roots);
      void measureHost(const HostDetail& host, double seconds);
      void remember(double seconds) noexcept;
      [[nodiscard]] static bool matches(const MonitorEntry& entry, const MonitorView& view) noexcept;
      [[nodiscard]] static bool before(const MonitorEntry& left, const MonitorEntry& right, const MonitorView& view) noexcept;
      // As `before`, but a tree orders siblings by their branches' processor and memory.
      [[nodiscard]] bool beforeBranch(std::uint32_t left, std::uint32_t right, const MonitorView& view) const noexcept;
      // It views the entry's text.
      [[nodiscard]] tbc::val_a<MonitorProcess> row(tbc::ref_a<MonitorEntry> entry, const Listed& listed) const noexcept;

      // Where a query's rows and detail are written.
      struct Placement {
        bool found = true;
        std::size_t first = 0;
        std::size_t count = 0;
        std::uint32_t matched = 0;
        std::size_t first_group = 0;
        std::size_t group_count = 0;
        ds::Option<std::size_t> detail;
      };

      using Placements = ds::Array<Placement, maximum_answers>;

      // Writes the rows and the detail of each query, dropping the previous round's; where each is.
      Placements place(std::span<const MonitorView> views);
      [[nodiscard]] ds::Option<std::uint32_t> indexOf(pid_t process) const noexcept;
      bool detail(const ProcessInstance& instance);
      void select(const MonitorView& view);
      void selectTree(const MonitorView& view);
      void selectOwners(const MonitorView& view);
      [[nodiscard]] ds::Option<std::uint32_t> selectedParent(std::uint32_t index) const noexcept;
      void sumBranches();
      void pushChildren(const Listed& listed);
      void groupOwners(std::size_t first);
      // Whether the row's branch shows folded in the view's tree.
      [[nodiscard]] bool folds(const Listed& listed, const MonitorView& view) const noexcept;

      // A process an owner listing leaves out.
      static constexpr std::uint16_t no_group = std::numeric_limits<std::uint16_t>::max();

      tbc::mut_a<ConcurrentMemory> memory_;
      tbc::val_a<ProcessInspector> inspector_;
      // Sorted by pid.
      tbc::val_a<ds::Vec<MonitorEntry, ConcurrentMemory>> entries_;
      tbc::val_a<ds::Vec<MonitorEntry, ConcurrentMemory>> previous_;
      tbc::val_a<ds::Vec<UserName, ConcurrentMemory>> users_;
      // Scratch: the selection of one query, and its listing.
      tbc::val_a<ds::Vec<std::uint32_t, ConcurrentMemory>> selected_;
      tbc::val_a<ds::Vec<Listed, ConcurrentMemory>> listed_;
      tbc::val_a<ds::Vec<std::uint32_t, ConcurrentMemory>> ordered_;
      tbc::val_a<ds::Vec<std::uint8_t, ConcurrentMemory>> flags_;
      tbc::val_a<ds::Vec<Listed, ConcurrentMemory>> stack_;
      // Scratch, by entry: what a tree adds up over its branch, and an owner listing's group.
      tbc::val_a<ds::Vec<Branch, ConcurrentMemory>> branches_;
      tbc::val_a<ds::Vec<std::uint16_t, ConcurrentMemory>> group_of_;
      // What the answers of a round view.
      tbc::val_self<ds::Vec<MonitorProcess, ConcurrentMemory>> rows_;
      tbc::val_a<ds::Vec<MonitorGroup, ConcurrentMemory>> groups_;
      // Their relatives view the names of entries_.
      tbc::val_self<ds::Vec<DetailText, ConcurrentMemory>> details_;
      ds::Option<Clock::time_point> sampled_;
      std::uint32_t readings_ = 0;
      // Every reading taken, which the answers carry so a client tells a new one from a repeat.
      std::uint64_t sample_ = 0;
      // The runtime's own process and its clients', which the monitor names as telar's.
      pid_t self_ = 0;
      ds::Array<pid_t, maximum_monitor_clients> clients_{};
      std::size_t client_count_ = 1;
      TelarPrograms programs_{};
      uid_t user_ = 0;

      HostDetail host_{};
      ds::Array<std::uint16_t, HostDetail::maximum_cores> cores_{};
      std::uint16_t cpu_permille_ = 0;
      // Of one core, as a process's share: what every core was busy together.
      std::uint64_t cores_busy_permille_ = 0;
      // The shares of the readings in a row, oldest first, until a pause.
      ds::Array<std::uint16_t, MonitorLimits::history_samples> history_{};
      std::uint8_t history_count_ = 0;
      std::uint64_t disk_read_per_second_ = 0;
      std::uint64_t disk_written_per_second_ = 0;
      // They view host_.
      tbc::val_self<ds::Array<MonitorInterface, HostDetail::maximum_interfaces>> interfaces_{};
      tbc::val_self<ds::Array<MonitorDisk, HostDetail::maximum_mounts>> disks_{};
      std::uint32_t thread_count_ = 0;
      std::uint32_t telar_count_ = 0;
      std::uint32_t agent_count_ = 0;
      std::uint32_t agents_ = 0;
      // The processes whose CPU the runtime may not read, and what the cores spent that no process it
      // read accounts for, of one core.
      std::uint32_t unmeasured_count_ = 0;
      std::uint32_t unattributed_permille_ = 0;
    };

  }
}
