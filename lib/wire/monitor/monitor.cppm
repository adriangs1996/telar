export module telar.wire.monitor;

// The monitor's queries, its snapshot, and the signals and priorities it sends to processes.

import std;
import telar.wire.vocabulary;
import telar.base.ds;

// The schemas specialize `BodySchema` and `MessageSchema`, which telar.wire.vocabulary declares in
// its global fragment; naming the templates here keeps them reachable from importers.
export namespace telar {
  using telar::BodySchema;
  using telar::MessageSchema;
}

export {
  namespace telar {

    // The monitor: the host's processors, memory, disks and network, and its processes, read by the
    // runtime of the machine they run on and sent only to the client that asks.

    enum class ProcessState : Byte {
      unknown = 0,
      running = 1,
      sleeping = 2,
      idle = 3,
      stopped = 4,
      zombie = 5,
    };

    enum class MonitorSort : Byte {
      cpu = 0,
      memory = 1,
      threads = 2,
      pid = 3,
      name = 4,
    };

    // Which processes a query lists: all of them, those running in a pane, or those an agent runs.
    enum class MonitorScope : Byte {
      all = 0,
      telar = 1,
      agents = 2,
    };

    // How a query orders the processes it lists: one list, each under its parent, or by the pane or
    // agent they belong to.
    enum class MonitorLayout : Byte {
      flat = 0,
      tree = 1,
      owner = 2,
    };

    // What a process is to telar: nothing, a process of a pane, an agent, a process an agent runs,
    // or telar's own runtime.
    enum class ProcessOwner : Byte {
      none = 0,
      pane = 1,
      agent = 2,
      agent_child = 3,
      telar = 4,
    };

    enum class ProcessSignal : Byte {
      terminate = 0,
      kill = 1,
      stop = 2,
      resume = 3,
      hang_up = 4,
      interrupt = 5,
    };

    struct MonitorLimits {
      static constexpr std::size_t maximum_processes = 1024;
      static constexpr std::size_t maximum_cores = 256;
      static constexpr std::size_t maximum_disks = 32;
      static constexpr std::size_t maximum_interfaces = 32;
      static constexpr std::size_t maximum_children = 256;
      // The processes a detail names from its root down to it.
      static constexpr std::size_t maximum_lineage = 16;
      // The tree's branches a query folds or unfolds against the default.
      static constexpr std::size_t maximum_toggled = 64;
      // A group for each pane, one for telar and one for the processes of no pane.
      static constexpr std::size_t maximum_groups = 258;
      // A tree draws its guides for this many levels.
      static constexpr std::size_t guide_levels = 32;
      // A tree folds a branch with more children than this until the query unfolds it.
      static constexpr std::size_t folded_children = 8;
      static constexpr std::size_t filter_bytes = 256;
      static constexpr std::size_t name_bytes = 32;
      static constexpr std::size_t user_bytes = 32;
      static constexpr std::size_t command_bytes = 256;
      static constexpr std::size_t arguments_bytes = 8192;
      static constexpr std::size_t directory_bytes = 1024;
      static constexpr std::size_t disk_path_bytes = 128;
      static constexpr std::size_t disk_device_bytes = 64;
      static constexpr std::size_t disk_type_bytes = 16;
      static constexpr std::size_t interface_name_bytes = 16;
      // The nice values a process takes, from the highest priority to the lowest.
      static constexpr std::int32_t highest_nice = -20;
      static constexpr std::int32_t lowest_nice = 20;
      // A share of the processor in thousandths: of one core, or of all of them together.
      static constexpr std::uint16_t whole_permille = 1000;
    };

    // The sections a query asks for, as bits.
    struct MonitorSections {
      static constexpr std::uint8_t host = 1;
      static constexpr std::uint8_t disks = 2;
      static constexpr std::uint8_t network = 4;
      static constexpr std::uint8_t processes = 8;
      static constexpr std::uint8_t all = static_cast<std::uint8_t>(unsigned{host} | unsigned{disks} | unsigned{network} | unsigned{processes});
    };

    // A process instance: its pid and the moment it started, which a recycled pid never repeats.
    // A start of zero names whichever process has the pid now.
    struct ProcessInstance {
      static constexpr std::uint64_t maximum_microseconds = 999'999;

      std::int32_t pid{};
      std::uint64_t started_seconds{};
      std::uint64_t started_microseconds{};

      bool operator==(const ProcessInstance&) const noexcept = default;
    };

    template <>
    struct BodySchema<ProcessInstance>
        : Serializer<
              Field<&ProcessInstance::pid, BoundedInteger<i32, 0>, "pid">,
              Field<&ProcessInstance::started_seconds, u64, "started_seconds">,
              Field<&ProcessInstance::started_microseconds, BoundedInteger<u64, 0, ProcessInstance::maximum_microseconds>, "started_microseconds">> {};

    struct QueryMonitor {
      std::uint64_t request_id{};
      std::uint8_t sections{};
      MonitorSort sort{};
      bool reverse{};
      MonitorScope scope{};
      MonitorLayout layout{};
      std::string_view filter;
      // The rows the reply lists: `limit` of them, after the first `offset` of the listing.
      std::uint32_t offset{};
      std::uint16_t limit{};
      // Whether a tree folds by default the branches with more than folded_children children.
      bool fold{};
      // The processes whose branches the tree folds when it would not, or unfolds when it would.
      std::span<const std::int32_t> toggled;
      // A process whose arguments, directory, ports and children the reply carries; pid 0 for none.
      ProcessInstance detail{};
    };

    template <>
    struct MessageSchema<QueryMonitor>
        : Schema<
              Direction::client,
              ClientTag::query_monitor,
              Field<&QueryMonitor::request_id, NonzeroU64, "request_id">,
              Field<&QueryMonitor::sections, BoundedInteger<u8, 0, MonitorSections::all>, "sections">,
              Field<&QueryMonitor::sort, EnumByte<MonitorSort, static_cast<Byte>(MonitorSort::name)>, "sort">,
              Field<&QueryMonitor::reverse, BoolByte, "reverse">,
              Field<&QueryMonitor::scope, EnumByte<MonitorScope, static_cast<Byte>(MonitorScope::agents)>, "scope">,
              Field<&QueryMonitor::layout, EnumByte<MonitorLayout, static_cast<Byte>(MonitorLayout::owner)>, "layout">,
              Field<&QueryMonitor::filter, DisplayText16<MonitorLimits::filter_bytes>, "filter">,
              Field<&QueryMonitor::offset, u32, "offset">,
              Field<&QueryMonitor::limit, BoundedInteger<u16, 0, MonitorLimits::maximum_processes>, "limit">,
              Field<&QueryMonitor::fold, BoolByte, "fold">,
              Field<&QueryMonitor::toggled, CountedSpan<u8, BoundedInteger<i32, 1>, MonitorLimits::maximum_toggled>, "toggled">,
              Field<&QueryMonitor::detail, ValueCodec<ProcessInstance>, "detail">> {};

    struct MonitorDisk {
      std::string_view path;
      std::string_view device;
      std::string_view type;
      std::uint64_t total_bytes{};
      std::uint64_t used_bytes{};
      std::uint64_t available_bytes{};
    };

    template <>
    struct BodySchema<MonitorDisk>
        : Serializer<
              Field<&MonitorDisk::path, DisplayText16<MonitorLimits::disk_path_bytes>, "path">,
              Field<&MonitorDisk::device, DisplayText16<MonitorLimits::disk_device_bytes>, "device">,
              Field<&MonitorDisk::type, DisplayText16<MonitorLimits::disk_type_bytes>, "type">,
              Field<&MonitorDisk::total_bytes, u64, "total_bytes">,
              Field<&MonitorDisk::used_bytes, u64, "used_bytes">,
              Field<&MonitorDisk::available_bytes, u64, "available_bytes">> {};

    struct MonitorInterface {
      std::string_view name;
      std::uint64_t received_per_second{};
      std::uint64_t sent_per_second{};
      std::uint64_t received_bytes{};
      std::uint64_t sent_bytes{};
    };

    template <>
    struct BodySchema<MonitorInterface>
        : Serializer<
              Field<&MonitorInterface::name, DisplayText16<MonitorLimits::interface_name_bytes, false>, "name">,
              Field<&MonitorInterface::received_per_second, u64, "received_per_second">,
              Field<&MonitorInterface::sent_per_second, u64, "sent_per_second">,
              Field<&MonitorInterface::received_bytes, u64, "received_bytes">,
              Field<&MonitorInterface::sent_bytes, u64, "sent_bytes">> {};

    struct MonitorProcess {
      ProcessInstance instance{};
      std::int32_t parent{};
      std::uint32_t user_id{};
      std::string_view user;
      std::string_view name;
      // The command line, its arguments joined by spaces and cut to command_bytes; empty when the
      // runtime may not read it.
      std::string_view command;
      ProcessState state{};
      // Whether CPU, memory and threads were read; macOS lends them for other users' processes only
      // to root.
      bool measured{};
      // Of one core: 1000 is a whole core, and a process with many threads can pass it.
      std::uint32_t cpu_permille{};
      std::uint64_t resident_bytes{};
      std::uint32_t threads{};
      std::int32_t nice{};
      // The pane it runs in, 0 outside every pane.
      std::uint64_t pane_id{};
      // The agent this process is, unknown when it is none.
      AgentProvider agent{};
      ProcessOwner owner{};
      // Its depth in a tree listing; 0 in a flat one.
      std::uint8_t depth{};
      // In a tree: bit k says the branch at depth k + 1 on its path goes on below this row, so bit
      // depth - 1 is whether a later sibling follows it. Levels past guide_levels have no bit.
      std::uint32_t guides{};
      // In a tree: its children the listing selected, and the processes of its branch it hides
      // while folded; 0 when it is unfolded.
      std::uint16_t children{};
      std::uint32_t folded{};
      // In a tree: its share of the processor with its branch's.
      std::uint32_t branch_cpu_permille{};
    };

    template <>
    struct BodySchema<MonitorProcess>
        : Serializer<
              Field<&MonitorProcess::instance, ValueCodec<ProcessInstance>, "instance">,
              Field<&MonitorProcess::parent, BoundedInteger<i32, 0>, "parent">,
              Field<&MonitorProcess::user_id, u32, "user_id">,
              Field<&MonitorProcess::user, DisplayText16<MonitorLimits::user_bytes>, "user">,
              Field<&MonitorProcess::name, DisplayText16<MonitorLimits::name_bytes>, "name">,
              Field<&MonitorProcess::command, DisplayText16<MonitorLimits::command_bytes>, "command">,
              Field<&MonitorProcess::state, EnumByte<ProcessState, static_cast<Byte>(ProcessState::zombie)>, "state">,
              Field<&MonitorProcess::measured, BoolByte, "measured">,
              Field<&MonitorProcess::cpu_permille, u32, "cpu_permille">,
              Field<&MonitorProcess::resident_bytes, u64, "resident_bytes">,
              Field<&MonitorProcess::threads, u32, "threads">,
              Field<&MonitorProcess::nice, BoundedInteger<i32, MonitorLimits::highest_nice, MonitorLimits::lowest_nice>, "nice">,
              Field<&MonitorProcess::pane_id, u64, "pane_id">,
              Field<&MonitorProcess::agent, EnumByte<AgentProvider, max_agent_provider_index>, "agent">,
              Field<&MonitorProcess::owner, EnumByte<ProcessOwner, static_cast<Byte>(ProcessOwner::telar)>, "owner">,
              Field<&MonitorProcess::depth, u8, "depth">,
              Field<&MonitorProcess::guides, u32, "guides">,
              Field<&MonitorProcess::children, u16, "children">,
              Field<&MonitorProcess::folded, u32, "folded">,
              Field<&MonitorProcess::branch_cpu_permille, u32, "branch_cpu_permille">> {};

    // A process a detail names beside the one it is of: an ancestor or a child.
    struct MonitorRelative {
      std::int32_t pid{};
      std::string_view name;
    };

    template <>
    struct BodySchema<MonitorRelative>
        : Serializer<
              Field<&MonitorRelative::pid, BoundedInteger<i32, 0>, "pid">,
              Field<&MonitorRelative::name, DisplayText16<MonitorLimits::name_bytes>, "name">> {};

    // The processes of one owner in an owner listing, in the listing's order: a pane's, telar's, or
    // those of no pane.
    struct MonitorGroup {
      ProcessOwner owner{};
      std::uint64_t pane_id{};
      std::uint32_t processes{};
      std::uint32_t cpu_permille{};
      std::uint64_t resident_bytes{};
    };

    template <>
    struct BodySchema<MonitorGroup>
        : Serializer<
              Field<&MonitorGroup::owner, EnumByte<ProcessOwner, static_cast<Byte>(ProcessOwner::telar)>, "owner">,
              Field<&MonitorGroup::pane_id, u64, "pane_id">,
              Field<&MonitorGroup::processes, u32, "processes">,
              Field<&MonitorGroup::cpu_permille, u32, "cpu_permille">,
              Field<&MonitorGroup::resident_bytes, u64, "resident_bytes">> {};

    struct MonitorDetail {
      MonitorProcess process{};
      // Every argument, joined by spaces and cut to arguments_bytes.
      std::string_view arguments;
      std::string_view directory;
      std::span<const std::uint16_t> ports;
      std::span<const MonitorRelative> children;
      // Its ancestors, from the root of its tree down to its parent, at most maximum_lineage of the
      // nearest.
      std::span<const MonitorRelative> lineage;
    };

    template <>
    struct BodySchema<MonitorDetail>
        : Serializer<
              Field<&MonitorDetail::process, ValueCodec<MonitorProcess>, "process">,
              Field<&MonitorDetail::arguments, DisplayText16<MonitorLimits::arguments_bytes>, "arguments">,
              Field<&MonitorDetail::directory, DisplayText16<MonitorLimits::directory_bytes>, "directory">,
              Field<&MonitorDetail::ports, CountedSpan<u8, BoundedInteger<u16, 1>, max_listed_ports>, "ports">,
              Field<&MonitorDetail::children, CountedSpan<u16, ValueCodec<MonitorRelative>, MonitorLimits::maximum_children>, "children">,
              Field<&MonitorDetail::lineage, CountedSpan<u8, ValueCodec<MonitorRelative>, MonitorLimits::maximum_lineage>, "lineage">> {};

    struct MonitorSnapshot {
      std::uint64_t request_id{};
      std::uint8_t sections{};
      // Counts the readings the runtime took: two answers with the same count carry the same shares.
      std::uint64_t sample{};
      // Of all cores together: 1000 is every core busy.
      std::uint16_t cpu_permille{};
      std::span<const std::uint16_t> cores;
      std::uint64_t memory_total_bytes{};
      std::uint64_t memory_used_bytes{};
      std::uint64_t memory_available_bytes{};
      std::uint64_t memory_cached_bytes{};
      std::uint64_t swap_total_bytes{};
      std::uint64_t swap_used_bytes{};
      std::uint32_t process_count{};
      // Of those, the ones telar runs: in its panes or its own, and those an agent runs.
      std::uint32_t telar_count{};
      std::uint32_t agent_count{};
      std::uint32_t thread_count{};
      std::uint64_t disk_read_per_second{};
      std::uint64_t disk_written_per_second{};
      std::span<const MonitorDisk> disks;
      std::span<const MonitorInterface> interfaces;
      // How many rows the listing has: the processes that match the query but those a folded branch
      // hides. The reply lists at most its limit of them, from its offset.
      std::uint32_t matched{};
      std::span<const MonitorProcess> processes;
      // In an owner listing, every group in the listing's order.
      std::span<const MonitorGroup> groups;
      ds::Option<MonitorDetail> detail;
    };

    template <>
    struct MessageSchema<MonitorSnapshot>
        : Schema<
              Direction::server,
              ServerTag::monitor_snapshot,
              Field<&MonitorSnapshot::request_id, NonzeroU64, "request_id">,
              Field<&MonitorSnapshot::sections, BoundedInteger<u8, 0, MonitorSections::all>, "sections">,
              Field<&MonitorSnapshot::sample, u64, "sample">,
              Field<&MonitorSnapshot::cpu_permille, BoundedInteger<u16, 0, MonitorLimits::whole_permille>, "cpu_permille">,
              Field<&MonitorSnapshot::cores, CountedSpan<u16, BoundedInteger<u16, 0, MonitorLimits::whole_permille>, MonitorLimits::maximum_cores>, "cores">,
              Field<&MonitorSnapshot::memory_total_bytes, u64, "memory_total_bytes">,
              Field<&MonitorSnapshot::memory_used_bytes, u64, "memory_used_bytes">,
              Field<&MonitorSnapshot::memory_available_bytes, u64, "memory_available_bytes">,
              Field<&MonitorSnapshot::memory_cached_bytes, u64, "memory_cached_bytes">,
              Field<&MonitorSnapshot::swap_total_bytes, u64, "swap_total_bytes">,
              Field<&MonitorSnapshot::swap_used_bytes, u64, "swap_used_bytes">,
              Field<&MonitorSnapshot::process_count, u32, "process_count">,
              Field<&MonitorSnapshot::telar_count, u32, "telar_count">,
              Field<&MonitorSnapshot::agent_count, u32, "agent_count">,
              Field<&MonitorSnapshot::thread_count, u32, "thread_count">,
              Field<&MonitorSnapshot::disk_read_per_second, u64, "disk_read_per_second">,
              Field<&MonitorSnapshot::disk_written_per_second, u64, "disk_written_per_second">,
              Field<&MonitorSnapshot::disks, CountedSpan<u8, ValueCodec<MonitorDisk>, MonitorLimits::maximum_disks>, "disks">,
              Field<&MonitorSnapshot::interfaces, CountedSpan<u8, ValueCodec<MonitorInterface>, MonitorLimits::maximum_interfaces>, "interfaces">,
              Field<&MonitorSnapshot::matched, u32, "matched">,
              Field<&MonitorSnapshot::processes, CountedSpan<u16, ValueCodec<MonitorProcess>, MonitorLimits::maximum_processes>, "processes">,
              Field<&MonitorSnapshot::groups, CountedSpan<u16, ValueCodec<MonitorGroup>, MonitorLimits::maximum_groups>, "groups">,
              Field<&MonitorSnapshot::detail, OptionalValue<ValueCodec<MonitorDetail>>, "detail">> {};

    // Sends a signal to a process the runtime's user may signal. The runtime reads the process again
    // right before, so a recycled pid never receives it. Answered by RequestCompleted.
    struct RequestProcessSignal {
      std::uint64_t request_id{};
      ProcessInstance process{};
      ProcessSignal signal{};
    };

    template <>
    struct MessageSchema<RequestProcessSignal>
        : Schema<
              Direction::client,
              ClientTag::request_process_signal,
              Field<&RequestProcessSignal::request_id, NonzeroU64, "request_id">,
              Field<&RequestProcessSignal::process, ValueCodec<ProcessInstance>, "process">,
              Field<&RequestProcessSignal::signal, EnumByte<ProcessSignal, static_cast<Byte>(ProcessSignal::interrupt)>, "signal">> {};

    // Sets a process's nice value. Answered by RequestCompleted.
    struct RequestProcessPriority {
      std::uint64_t request_id{};
      ProcessInstance process{};
      std::int32_t nice{};
    };

    template <>
    struct MessageSchema<RequestProcessPriority>
        : Schema<
              Direction::client,
              ClientTag::request_process_priority,
              Field<&RequestProcessPriority::request_id, NonzeroU64, "request_id">,
              Field<&RequestProcessPriority::process, ValueCodec<ProcessInstance>, "process">,
              Field<&RequestProcessPriority::nice, BoundedInteger<i32, MonitorLimits::highest_nice, MonitorLimits::lowest_nice>, "nice">> {};

    // Every operation of the monitor, with the CLI command, the binding action and the palette label
    // that reach it. The CLI's and the window's tests check each one against their tables, so an
    // operation never exists in one place only.
    struct MonitorOperation {
      std::string_view binding;
      std::string_view label;
      std::string_view family;
      std::string_view command;
    };

    inline constexpr ds::Array<MonitorOperation, 12> monitor_operations{
        {
            {.binding = "monitor", .label = "Open monitor", .family = "monitor", .command = "host"},
            {.binding = "process-picker", .label = "Find process", .family = "process", .command = "list"},
            {.binding = "process-terminate", .label = "Terminate process", .family = "process", .command = "signal"},
            {.binding = "process-kill", .label = "Kill process", .family = "process", .command = "signal"},
            {.binding = "process-stop", .label = "Pause process", .family = "process", .command = "signal"},
            {.binding = "process-continue", .label = "Resume process", .family = "process", .command = "signal"},
            {.binding = "process-lower-priority", .label = "Lower process priority", .family = "process", .command = "renice"},
            {.binding = "process-copy-command", .label = "Copy process command", .family = "process", .command = "get"},
            {.binding = "process-focus-pane", .label = "Go to process pane", .family = "process", .command = "get"},
            {.binding = "process-review-stack", .label = "Review process stack", .family = "process", .command = "review"},
            {.binding = "process-review-files", .label = "Review process open files", .family = "process", .command = "review"},
            {.binding = "process-review-logs", .label = "Review process logs", .family = "process", .command = "review"},
        },
    };

  }
}
