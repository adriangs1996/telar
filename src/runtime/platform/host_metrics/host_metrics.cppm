export module telar.runtime.platform.host_metrics;

import std;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: platform/host_metrics.cppm
export {
  namespace telar::runtime {

    struct HostCounters {
      std::uint64_t busy_ticks;
      std::uint64_t total_ticks;
      std::uint64_t memory_used_bytes;
      std::uint64_t memory_total_bytes;
      std::uint16_t cpu_count;
      ds::Option<std::uint8_t> battery_percent;
    };

    template <typename Probe>
    concept HostMetricsProbe = requires(Probe& probe) {
      { probe.read() } noexcept -> std::same_as<ds::Option<HostCounters>>;
    };

    class NativeHostMetrics {
    public:
      static ds::Option<HostCounters> read() noexcept;
    };

    static_assert(HostMetricsProbe<NativeHostMetrics>);

    struct CoreTicks {
      std::uint64_t busy = 0;
      std::uint64_t total = 0;
    };

    struct MountUsage {
      static constexpr std::size_t path_capacity = 128;
      static constexpr std::size_t device_capacity = 64;
      static constexpr std::size_t type_capacity = 16;

      FixedText<path_capacity> path;
      FixedText<device_capacity> device;
      FixedText<type_capacity> type;
      std::uint64_t total_bytes = 0;
      std::uint64_t used_bytes = 0;
      std::uint64_t available_bytes = 0;
    };

    struct InterfaceCounters {
      static constexpr std::size_t name_capacity = 16;

      FixedText<name_capacity> name;
      std::uint64_t received_bytes = 0;
      std::uint64_t sent_bytes = 0;
    };

    // What the monitor reads of the host besides its processes, only while someone watches: the
    // cumulative counters a rate is computed from, and the sizes as they are now.
    struct HostDetail {
      static constexpr std::size_t maximum_cores = 256;
      static constexpr std::size_t maximum_mounts = 32;
      static constexpr std::size_t maximum_interfaces = 32;

      ds::Array<CoreTicks, maximum_cores> cores{};
      std::uint16_t core_count = 0;
      std::uint64_t memory_total_bytes = 0;
      std::uint64_t memory_used_bytes = 0;
      std::uint64_t memory_available_bytes = 0;
      std::uint64_t memory_cached_bytes = 0;
      std::uint64_t swap_total_bytes = 0;
      std::uint64_t swap_used_bytes = 0;
      ds::Array<MountUsage, maximum_mounts> mounts{};
      std::uint8_t mount_count = 0;
      std::uint64_t disk_read_bytes = 0;
      std::uint64_t disk_written_bytes = 0;
      ds::Array<InterfaceCounters, maximum_interfaces> interfaces{};
      std::uint8_t interface_count = 0;
    };

    template <typename Probe>
    concept HostDetailProbe = requires(Probe& probe, HostDetail& detail) {
      { probe.read(detail) } noexcept -> std::same_as<bool>;
    };

    class NativeHostDetail {
    public:
      // False when the processor or memory counters cannot be read; mounts, disks and interfaces
      // that cannot be read are left out.
      bool read(HostDetail& detail) noexcept;

    private:
      static constexpr std::size_t buffer_bytes = std::size_t{64} * 1024;

      // The interface list of the routing table on macOS; the text of /proc's files on Linux.
      ds::Array<char, buffer_bytes> buffer_;
    };

    static_assert(HostDetailProbe<NativeHostDetail>);

  }
}
