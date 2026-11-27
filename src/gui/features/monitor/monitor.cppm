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

export import :presentation;

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
    ProcessOwner owner = ProcessOwner::none;
    std::uint8_t depth = 0;
    std::uint32_t guides = 0;
    std::uint16_t children = 0;
    std::uint32_t folded = 0;
    std::uint32_t branch_cpu_permille = 0;
  };

  // What the window keeps of a mount's path, a file system's type and an interface's name.
  inline constexpr std::size_t path_bytes = 128;
  inline constexpr std::size_t short_name_bytes = 16;
  inline constexpr std::size_t error_bytes = 256;
  // The relatives a detail keeps: its nearest ancestors, and its first children.
  inline constexpr std::size_t kept_relatives = 16;
  // The processor shares the window keeps, one per reading of the runtime: 2 minutes at a reading
  // every 2 s.
  inline constexpr std::size_t history_samples = MonitorLimits::history_samples;
  // The interfaces the network panel shows.
  inline constexpr std::size_t shown_interfaces = 4;
  // The least a rate's meter fills against, so a trickle never fills it: 1 MiB/s of a network
  // interface, 10 MiB/s of the disks.
  inline constexpr std::uint64_t network_rate_floor = std::uint64_t{1} << 20U;
  inline constexpr std::uint64_t disk_rate_floor = std::uint64_t{10} << 20U;

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
    // Since the machine started: an interface that never carried a byte is not shown.
    std::uint64_t received_bytes = 0;
    std::uint64_t sent_bytes = 0;
  };

  // The highest rate of each of the last readings in a row, which a rate's meter fills against.
  struct RatePeaks {
    ds::Array<std::uint64_t, history_samples> values{};
    std::uint8_t count = 0;

    // Keeps the newest history_samples.
    void push(std::uint64_t rate) noexcept;

    // The highest of them, never below `floor`.
    [[nodiscard]] std::uint64_t scale(std::uint64_t floor) const noexcept;
  };

  // The interfaces the network panel shows, at most `shown.size()` of them by their index: those that
  // carry bytes now, then the quiet ones, each by the bytes they carried since the machine started.
  // One that never carried a byte is not shown. Returns how many.
  std::size_t shownInterfaces(std::span<const InterfaceRow> interfaces, std::span<std::uint8_t> shown) noexcept;

  struct Relative {
    std::int32_t pid = 0;
    FixedText<MonitorLimits::name_bytes> name;
  };

  struct ProcessDetail {
    ProcessRow process{};
    FixedText<MonitorLimits::arguments_bytes> arguments;
    FixedText<MonitorLimits::directory_bytes> directory;
    ds::Array<std::uint16_t, max_listed_ports> ports{};
    std::uint8_t port_count = 0;
    // Every child the runtime named, and the first kept_relatives of them.
    std::uint16_t child_count = 0;
    ds::Array<Relative, kept_relatives> children{};
    // From the root of its tree down to its parent.
    ds::Array<Relative, kept_relatives> lineage{};
    std::uint8_t lineage_count = 0;

    [[nodiscard]] std::span<const Relative> keptChildren() const noexcept;
    [[nodiscard]] std::span<const Relative> keptLineage() const noexcept;
  };

  // What the window lists, and how: what the person chose, and the rows the window shows.
  struct View {
    MonitorSort sort = MonitorSort::cpu;
    bool reverse = false;
    MonitorScope scope = MonitorScope::all;
    MonitorLayout layout = MonitorLayout::flat;
    FixedText<MonitorLimits::filter_bytes> filter;
    // The branches the person folded or unfolded against the tree's default.
    ds::Array<std::int32_t, MonitorLimits::maximum_toggled> toggled{};
    std::uint8_t toggled_count = 0;
    // The first row the window shows, counting an owner listing's group rows, and how many fit.
    std::uint32_t first = 0;
    std::uint16_t visible = 0;
    // The process whose detail the window shows; pid 0 for none.
    ProcessInstance selected{};
    // Grows with each change to which processes the listing holds or to their order.
    std::uint32_t listing = 0;

    [[nodiscard]] std::span<const std::int32_t> toggledPids() const noexcept;
  };

  // Folds the branch of `pid` if it shows unfolded, or unfolds it; the oldest choice goes first
  // when the view holds as many as the query carries.
  void toggle(View& view, std::int32_t pid) noexcept;

  // The view lists other processes, or in another order: the rows an older query asked for are not
  // kept. Returns the view, for the change.
  View& relist(View& view) noexcept;

  struct State {
    explicit State(tbc::mut_a<Memory> memory);

    View view{};
    // The query in flight, 0 when none; the window asks again only once it is answered.
    std::uint64_t waiting = 0;
    // The first row of the listing the query in flight asked for, and the listing it asked for.
    std::uint32_t asked_offset = 0;
    std::uint32_t asked_listing = 0;
    // The view changed while a query was in flight: the window asks again once it is answered.
    bool owed = false;
    // The signal or priority in flight, 0 when none.
    std::uint64_t acting = 0;
    // Grows with every answer the window keeps.
    std::uint64_t revision = 0;
    // What the runtime last refused, until the next answer.
    FixedText<error_bytes> error;

    std::uint16_t cpu_permille = 0;
    // The shares of all cores of the runtime's last readings in a row, oldest first, as it keeps them.
    ds::Array<std::uint16_t, history_samples> history{};
    std::uint8_t history_count = 0;
    // The runtime's reading the last answer came from: an answer that repeats it adds no peak.
    std::uint64_t sample = 0;
    // The highest rate of an interface the panel shows, and of the disks, per reading.
    RatePeaks network_peaks{};
    RatePeaks disk_peaks{};
    tbc::val_a<ds::Vec<std::uint16_t, Memory>> cores;
    std::uint64_t memory_total_bytes = 0;
    std::uint64_t memory_used_bytes = 0;
    std::uint64_t memory_available_bytes = 0;
    std::uint64_t memory_cached_bytes = 0;
    std::uint64_t swap_total_bytes = 0;
    std::uint64_t swap_used_bytes = 0;
    std::uint32_t process_count = 0;
    std::uint32_t telar_count = 0;
    std::uint32_t agent_count = 0;
    std::uint32_t agents = 0;
    std::uint32_t thread_count = 0;
    std::uint32_t unmeasured_count = 0;
    std::uint32_t unattributed_cpu_permille = 0;
    std::uint32_t user_id = 0;
    std::uint64_t disk_read_per_second = 0;
    std::uint64_t disk_written_per_second = 0;
    tbc::val_a<ds::Vec<DiskRow, Memory>> disks;
    tbc::val_a<ds::Vec<InterfaceRow, Memory>> interfaces;
    // The rows of the listing, and the first of them the window holds.
    std::uint32_t matched = 0;
    std::uint32_t offset = 0;
    tbc::val_a<ds::Vec<ProcessRow, Memory>> processes;
    tbc::val_a<ds::Vec<GroupRow, Memory>> groups;
    ds::Option<ProcessDetail> detail;

    [[nodiscard]] std::span<const std::uint16_t> cpuHistory() const noexcept;
  };

  // The detail of the process selected; none while the detail held is another's, as it is until the
  // answer about the one selected arrives.
  [[nodiscard]] const ProcessDetail* selectedDetail(const State& state) noexcept;

  // The rows of the listing the window asks for: those it shows, and as many before and after.
  [[nodiscard]] Window window(const State& state) noexcept;

  // Whether the window holds every row it shows.
  [[nodiscard]] bool covers(const State& state) noexcept;

  // The query for what the window shows. Whoever sends it gives it its id; it views the state's
  // view until then.
  [[nodiscard]] QueryMonitor query(const State& state) noexcept;

  // The state now waits for the answer to `request_id`: the query that left under it.
  void wait(State& state, std::uint64_t request_id) noexcept;

  // Keeps the answer the state waits for; false for any other. An answer to a listing the view has
  // since changed keeps the machine's readings and the detail, not the rows.
  bool receive(State& state, const MonitorSnapshot& snapshot);

  // The runtime refused `request_id`; false when the state waits for no such request.
  bool fail(State& state, std::uint64_t request_id, std::string_view message);

  // The signal or priority `request_id` was applied; false when the state waits for no such one.
  bool complete(State& state, std::uint64_t request_id);

  // Forgets what was asked: a new connection answers none of it.
  void reset(State& state) noexcept;

}
