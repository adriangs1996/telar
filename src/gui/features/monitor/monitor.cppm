// The monitor: the active machine's processors, memory, disks, network and processes, as its
// runtime last answered, and what the window asks of it next.
export module telar.gui.features.monitor;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.monitor;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.tbc;

export namespace telar::gui::features::monitor {

  using runtime::FixedText;

  // A process as the window keeps it: its text copied out of the reply that carried it.
  struct ProcessRow {
    ProcessInstance instance{};
    std::int32_t parent = 0;
    std::uint32_t user_id = 0;
    FixedText<MonitorLimits::user_bytes> user;
    FixedText<MonitorLimits::name_bytes> name;
    FixedText<MonitorLimits::command_bytes> command;
    ProcessState state = ProcessState::unknown;
    bool measured = false;
    std::uint32_t cpu_permille = 0;
    std::uint64_t resident_bytes = 0;
    std::uint32_t threads = 0;
    std::int32_t nice = 0;
    std::uint64_t pane_id = 0;
    AgentProvider agent = AgentProvider::unknown;
    std::uint8_t depth = 0;
  };

  // What the window keeps of a mount's path, a file system's type and an interface's name.
  inline constexpr std::size_t path_bytes = 128;
  inline constexpr std::size_t short_name_bytes = 16;
  inline constexpr std::size_t error_bytes = 256;

  struct DiskRow {
    FixedText<path_bytes> path;
    FixedText<short_name_bytes> type;
    std::uint64_t total_bytes = 0;
    std::uint64_t used_bytes = 0;
    std::uint64_t available_bytes = 0;
  };

  struct InterfaceRow {
    FixedText<short_name_bytes> name;
    std::uint64_t received_per_second = 0;
    std::uint64_t sent_per_second = 0;
  };

  struct ProcessDetail {
    ProcessRow process{};
    FixedText<MonitorLimits::arguments_bytes> arguments;
    FixedText<MonitorLimits::directory_bytes> directory;
    ds::Array<std::uint16_t, max_listed_ports> ports{};
    std::uint8_t port_count = 0;
    std::uint16_t child_count = 0;
  };

  // What the window lists, and how.
  struct View {
    static constexpr std::uint16_t rows = 300;

    MonitorSort sort = MonitorSort::cpu;
    bool reverse = false;
    MonitorScope scope = MonitorScope::all;
    bool tree = false;
    FixedText<MonitorLimits::filter_bytes> filter;
    // The process whose detail the window shows; pid 0 for none.
    ProcessInstance selected{};
  };

  struct State {
    explicit State(tbc::view<Memory&, tbc::lt::a> memory);

    View view{};
    // The query in flight, 0 when none; the window asks again only once it is answered.
    std::uint64_t waiting = 0;
    // The signal or priority in flight, 0 when none.
    std::uint64_t acting = 0;
    // Grows with every answer the window keeps.
    std::uint64_t revision = 0;
    // What the runtime last refused, until the next answer.
    FixedText<error_bytes> error;

    std::uint16_t cpu_permille = 0;
    tbc::view<ds::Vec<std::uint16_t, Memory>, tbc::lt::a> cores;
    std::uint64_t memory_total_bytes = 0;
    std::uint64_t memory_used_bytes = 0;
    std::uint64_t memory_available_bytes = 0;
    std::uint64_t memory_cached_bytes = 0;
    std::uint64_t swap_total_bytes = 0;
    std::uint64_t swap_used_bytes = 0;
    std::uint32_t process_count = 0;
    std::uint32_t thread_count = 0;
    std::uint64_t disk_read_per_second = 0;
    std::uint64_t disk_written_per_second = 0;
    tbc::view<ds::Vec<DiskRow, Memory>, tbc::lt::a> disks;
    tbc::view<ds::Vec<InterfaceRow, Memory>, tbc::lt::a> interfaces;
    std::uint32_t matched = 0;
    tbc::view<ds::Vec<ProcessRow, Memory>, tbc::lt::a> processes;
    ds::Option<ProcessDetail> detail;
  };

  // The query for what the window shows, under `request_id`, which the state now waits for.
  [[nodiscard]] QueryMonitor ask(State& state, std::uint64_t request_id) noexcept;

  // Keeps the answer the state waits for; false for any other.
  bool receive(State& state, const MonitorSnapshot& snapshot);

  // The runtime refused `request_id`; false when the state waits for no such request.
  bool fail(State& state, std::uint64_t request_id, std::string_view message);

  // The signal or priority `request_id` was applied; false when the state waits for no such one.
  bool complete(State& state, std::uint64_t request_id);

  // Forgets what was asked: a new connection answers none of it.
  void reset(State& state) noexcept;

}
