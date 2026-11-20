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

// Declared in the global module, with the vocabulary these schemas build on.
// NOLINTBEGIN(misc-use-internal-linkage): exported, and declared in the global module as the vocabulary is.
export extern "C++" {
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
      bool tree{};
      std::string_view filter;
      std::uint16_t limit{};
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
              Field<&QueryMonitor::tree, BoolByte, "tree">,
              Field<&QueryMonitor::filter, DisplayText16<MonitorLimits::filter_bytes>, "filter">,
              Field<&QueryMonitor::limit, BoundedInteger<u16, 0, MonitorLimits::maximum_processes>, "limit">,
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
      // Its depth in a tree listing; 0 in a flat one.
      std::uint8_t depth{};
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
              Field<&MonitorProcess::depth, u8, "depth">> {};

    struct MonitorDetail {
      MonitorProcess process{};
      // Every argument, joined by spaces and cut to arguments_bytes.
      std::string_view arguments;
      std::string_view directory;
      std::span<const std::uint16_t> ports;
      std::span<const std::int32_t> children;
    };

    template <>
    struct BodySchema<MonitorDetail>
        : Serializer<
              Field<&MonitorDetail::process, ValueCodec<MonitorProcess>, "process">,
              Field<&MonitorDetail::arguments, DisplayText16<MonitorLimits::arguments_bytes>, "arguments">,
              Field<&MonitorDetail::directory, DisplayText16<MonitorLimits::directory_bytes>, "directory">,
              Field<&MonitorDetail::ports, CountedSpan<u8, BoundedInteger<u16, 1>, max_listed_ports>, "ports">,
              Field<&MonitorDetail::children, CountedSpan<u16, BoundedInteger<i32, 1>, MonitorLimits::maximum_children>, "children">> {};

    struct MonitorSnapshot {
      std::uint64_t request_id{};
      std::uint8_t sections{};
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
      std::uint32_t thread_count{};
      std::uint64_t disk_read_per_second{};
      std::uint64_t disk_written_per_second{};
      std::span<const MonitorDisk> disks;
      std::span<const MonitorInterface> interfaces;
      // How many processes match the query; the reply lists at most its limit of them.
      std::uint32_t matched{};
      std::span<const MonitorProcess> processes;
      ds::Option<MonitorDetail> detail;
    };

    template <>
    struct MessageSchema<MonitorSnapshot>
        : Schema<
              Direction::server,
              ServerTag::monitor_snapshot,
              Field<&MonitorSnapshot::request_id, NonzeroU64, "request_id">,
              Field<&MonitorSnapshot::sections, BoundedInteger<u8, 0, MonitorSections::all>, "sections">,
              Field<&MonitorSnapshot::cpu_permille, BoundedInteger<u16, 0, MonitorLimits::whole_permille>, "cpu_permille">,
              Field<&MonitorSnapshot::cores, CountedSpan<u16, BoundedInteger<u16, 0, MonitorLimits::whole_permille>, MonitorLimits::maximum_cores>, "cores">,
              Field<&MonitorSnapshot::memory_total_bytes, u64, "memory_total_bytes">,
              Field<&MonitorSnapshot::memory_used_bytes, u64, "memory_used_bytes">,
              Field<&MonitorSnapshot::memory_available_bytes, u64, "memory_available_bytes">,
              Field<&MonitorSnapshot::memory_cached_bytes, u64, "memory_cached_bytes">,
              Field<&MonitorSnapshot::swap_total_bytes, u64, "swap_total_bytes">,
              Field<&MonitorSnapshot::swap_used_bytes, u64, "swap_used_bytes">,
              Field<&MonitorSnapshot::process_count, u32, "process_count">,
              Field<&MonitorSnapshot::thread_count, u32, "thread_count">,
              Field<&MonitorSnapshot::disk_read_per_second, u64, "disk_read_per_second">,
              Field<&MonitorSnapshot::disk_written_per_second, u64, "disk_written_per_second">,
              Field<&MonitorSnapshot::disks, CountedSpan<u8, ValueCodec<MonitorDisk>, MonitorLimits::maximum_disks>, "disks">,
              Field<&MonitorSnapshot::interfaces, CountedSpan<u8, ValueCodec<MonitorInterface>, MonitorLimits::maximum_interfaces>, "interfaces">,
              Field<&MonitorSnapshot::matched, u32, "matched">,
              Field<&MonitorSnapshot::processes, CountedSpan<u16, ValueCodec<MonitorProcess>, MonitorLimits::maximum_processes>, "processes">,
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
// NOLINTEND(misc-use-internal-linkage)
