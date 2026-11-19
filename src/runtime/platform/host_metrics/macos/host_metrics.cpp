module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.platform.host_metrics;

import std;
import telar.sys.apple;
import telar.sys.posix;
import telar.sys.socket;

import telar.platform.primitives;
import telar.runtime.platform.frameworks;
import telar.base.memory.containers;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime {
  namespace {

    ds::Option<std::int32_t> integerValue(CFDictionaryRef dictionary, CFStringRef key) noexcept {
      const auto value = CFDictionaryGetValue(dictionary, key);
      if (value == nullptr || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return ds::none;
      }

      std::int32_t integer = 0;
      if (!CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt32Type, &integer)) {
        return ds::none;
      }

      return integer;
    }

    ds::Option<std::uint8_t> batteryPercent() noexcept {
      const std::unique_ptr<const void, decltype(&CFRelease)> information{IOPSCopyPowerSourcesInfo(), &CFRelease};
      if (!information) {
        return ds::none;
      }

      const std::unique_ptr<const void, decltype(&CFRelease)> sources{IOPSCopyPowerSourcesList(information.get()), &CFRelease};
      if (!sources) {
        return ds::none;
      }

      const auto array = static_cast<CFArrayRef>(sources.get());
      const auto count = CFArrayGetCount(array);

      for (CFIndex index = 0; index < count; ++index) {
        const auto description = IOPSGetPowerSourceDescription(information.get(), CFArrayGetValueAtIndex(array, index));
        if (description == nullptr) {
          continue;
        }

        const auto current = integerValue(description, power_source_keys::current_capacity);
        const auto maximum = integerValue(description, power_source_keys::max_capacity);
        if (!current || !maximum || *current < 0 || *maximum <= 0) {
          continue;
        }

        return static_cast<std::uint8_t>(std::min<std::int64_t>(100, static_cast<std::int64_t>(*current) * 100 / *maximum));
      }

      return ds::none;
    }

    std::uint64_t usedPages(const vm_statistics64_data_t& memory) noexcept {
      return static_cast<std::uint64_t>(memory.active_count) + memory.wire_count + memory.compressor_page_count;
    }

    template <typename Integer>
    Integer systemCounter(const char* name) noexcept {
      Integer value = 0;
      auto size = sizeof(value);
      if (::sysctlbyname(name, &value, &size, nullptr, 0) != 0 || size != sizeof(value)) {
        return 0;
      }

      return value;
    }

  }

  ds::Option<HostCounters> NativeHostMetrics::read() noexcept {
    TELAR_TRACE("metrics.readHost");
    const auto host = ::mach_host_self();
    host_cpu_load_info_data_t cpu{};
    mach_msg_type_number_t cpu_words = HOST_CPU_LOAD_INFO_COUNT;
    const auto cpu_result = ::host_statistics64(host, HOST_CPU_LOAD_INFO, reinterpret_cast<host_info64_t>(&cpu), &cpu_words);
    vm_statistics64_data_t memory{};
    mach_msg_type_number_t memory_words = HOST_VM_INFO64_COUNT;
    const auto memory_result = ::host_statistics64(host, HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&memory), &memory_words);

    ::mach_port_deallocate(::mach_task_self(), host);
    if (cpu_result != KERN_SUCCESS || memory_result != KERN_SUCCESS) {
      return ds::none;
    }

    const auto busy = static_cast<std::uint64_t>(cpu.cpu_ticks[CPU_STATE_USER]) + cpu.cpu_ticks[CPU_STATE_SYSTEM] + cpu.cpu_ticks[CPU_STATE_NICE];
    const auto used_pages = usedPages(memory);
    const auto cpu_count = std::clamp(systemCounter<int>("hw.logicalcpu"), 0, static_cast<int>(std::numeric_limits<std::uint16_t>::max()));

    return HostCounters{
        .busy_ticks = busy,
        .total_ticks = busy + cpu.cpu_ticks[CPU_STATE_IDLE],
        .memory_used_bytes = used_pages * static_cast<std::uint64_t>(::getpagesize()),
        .memory_total_bytes = systemCounter<std::uint64_t>("hw.memsize"),
        .cpu_count = static_cast<std::uint16_t>(cpu_count),
        .battery_percent = batteryPercent(),
    };
  }

  namespace {

    template <std::size_t Capacity>
    void assignPrefix(FixedText<Capacity>& output, const char* text, std::size_t size) noexcept {
      output.assign(utf8Prefix({text, ::strnlen(text, size)}, Capacity));
    }

    bool readCores(HostDetail& detail) noexcept {
      natural_t count = 0;
      processor_info_array_t information = nullptr;
      mach_msg_type_number_t words = 0;
      const auto host = ::mach_host_self();
      const auto result = ::host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &information, &words);

      ::mach_port_deallocate(::mach_task_self(), host);
      if (result != KERN_SUCCESS) {
        return false;
      }

      const auto* loads = reinterpret_cast<const processor_cpu_load_info_data_t*>(information);

      detail.core_count = static_cast<std::uint16_t>(std::min<std::size_t>(count, HostDetail::maximum_cores));
      for (std::size_t core = 0; core < detail.core_count; ++core) {
        const auto& ticks = loads[core].cpu_ticks;
        const auto busy = static_cast<std::uint64_t>(ticks[CPU_STATE_USER]) + ticks[CPU_STATE_SYSTEM] + ticks[CPU_STATE_NICE];

        detail.cores.atMut(core) = {.busy = busy, .total = busy + ticks[CPU_STATE_IDLE]};
      }

      ::vm_deallocate(::mach_task_self(), reinterpret_cast<vm_address_t>(information), static_cast<vm_size_t>(words) * sizeof(*information));
      return true;
    }

    bool readMemory(HostDetail& detail) noexcept {
      const auto host = ::mach_host_self();
      vm_statistics64_data_t memory{};
      mach_msg_type_number_t memory_words = HOST_VM_INFO64_COUNT;
      const auto result = ::host_statistics64(host, HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&memory), &memory_words);

      ::mach_port_deallocate(::mach_task_self(), host);
      if (result != KERN_SUCCESS) {
        return false;
      }

      const auto page = static_cast<std::uint64_t>(::getpagesize());
      const auto total = systemCounter<std::uint64_t>("hw.memsize");
      const auto used = std::min(total, usedPages(memory) * page);
      xsw_usage swap{};
      auto swap_size = sizeof(swap);

      detail.memory_total_bytes = total;
      detail.memory_used_bytes = used;
      detail.memory_available_bytes = total - used;
      // File-backed pages: what the kernel drops first when memory runs short.
      detail.memory_cached_bytes = static_cast<std::uint64_t>(memory.external_page_count) * page;
      if (::sysctlbyname("vm.swapusage", &swap, &swap_size, nullptr, 0) == 0 && swap_size == sizeof(swap)) {
        detail.swap_total_bytes = swap.xsu_total;
        detail.swap_used_bytes = swap.xsu_used;
      }

      return true;
    }

    void readMounts(HostDetail& detail) noexcept {
      sys::FileSystemStatus* table = nullptr;
      const auto count = ::getmntinfo(&table, MNT_NOWAIT);

      detail.mount_count = 0;
      for (int index = 0; index < count && detail.mount_count < HostDetail::maximum_mounts; ++index) {
        const auto& mount = table[index];
        const std::string_view type{mount.f_fstypename, ::strnlen(mount.f_fstypename, sizeof(mount.f_fstypename))};
        if ((mount.f_flags & MNT_LOCAL) == 0 || (mount.f_flags & MNT_DONTBROWSE) != 0 || type == "devfs" || mount.f_blocks == 0) {
          continue;
        }

        auto& usage = detail.mounts.atMut(detail.mount_count++);
        const auto block = static_cast<std::uint64_t>(mount.f_bsize);

        assignPrefix(usage.path, mount.f_mntonname, sizeof(mount.f_mntonname));
        assignPrefix(usage.device, mount.f_mntfromname, sizeof(mount.f_mntfromname));
        assignPrefix(usage.type, mount.f_fstypename, sizeof(mount.f_fstypename));
        usage.total_bytes = mount.f_blocks * block;
        usage.used_bytes = (mount.f_blocks - std::min(mount.f_bfree, mount.f_blocks)) * block;
        usage.available_bytes = mount.f_bavail * block;
      }
    }

    std::uint64_t numberValue(CFDictionaryRef dictionary, CFStringRef key) noexcept {
      const auto value = CFDictionaryGetValue(dictionary, key);
      std::int64_t number = 0;
      if (value == nullptr || CFGetTypeID(value) != CFNumberGetTypeID() || !CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt64Type, &number)) {
        return 0;
      }

      return static_cast<std::uint64_t>(std::max<std::int64_t>(number, 0));
    }

    // Every block storage driver's bytes read and written since boot.
    void readDisks(HostDetail& detail) noexcept {
      io_iterator_t drivers = 0;

      detail.disk_read_bytes = 0;
      detail.disk_written_bytes = 0;
      // The matching dictionary is consumed by the call, even when it fails.
      if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(block_storage_keys::driver_class), &drivers) != KERN_SUCCESS) {
        return;
      }

      while (const auto driver = IOIteratorNext(drivers)) {
        CFMutableDictionaryRef properties = nullptr;
        if (IORegistryEntryCreateCFProperties(driver, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties != nullptr) {
          const auto statistics = CFDictionaryGetValue(properties, block_storage_keys::statistics);
          if (statistics != nullptr && CFGetTypeID(statistics) == CFDictionaryGetTypeID()) {
            detail.disk_read_bytes += numberValue(static_cast<CFDictionaryRef>(statistics), block_storage_keys::bytes_read);
            detail.disk_written_bytes += numberValue(static_cast<CFDictionaryRef>(statistics), block_storage_keys::bytes_written);
          }

          CFRelease(properties);
        }

        IOObjectRelease(driver);
      }

      IOObjectRelease(drivers);
    }

    // The 64-bit byte counters of every interface that is up, from the routing table's interface
    // list; getifaddrs reports 32-bit ones, which wrap at 4 GiB.
    void readInterfaces(HostDetail& detail, std::span<char> buffer) noexcept {
      int selector[]{CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
      auto length = buffer.size();

      detail.interface_count = 0;
      if (::sysctl(selector, 6, buffer.data(), &length, nullptr, 0) != 0) {
        return;
      }

      std::size_t offset = 0;

      while (offset + sizeof(if_msghdr2) <= length && detail.interface_count < HostDetail::maximum_interfaces) {
        if_msghdr2 message;

        std::memcpy(&message, buffer.data() + offset, sizeof(message));
        if (message.ifm_msglen == 0) {
          return;
        }

        offset += message.ifm_msglen;
        const auto up = (message.ifm_flags & IFF_UP) != 0 && (message.ifm_flags & IFF_LOOPBACK) == 0;
        if (message.ifm_type != RTM_IFINFO2 || !up || (message.ifm_data.ifi_ibytes == 0 && message.ifm_data.ifi_obytes == 0)) {
          continue;
        }

        ds::Array<char, IF_NAMESIZE> name{};
        if (::if_indextoname(message.ifm_index, name.dataMut()) == nullptr) {
          continue;
        }

        auto& counters = detail.interfaces.atMut(detail.interface_count++);

        assignPrefix(counters.name, name.data(), name.size());
        counters.received_bytes = message.ifm_data.ifi_ibytes;
        counters.sent_bytes = message.ifm_data.ifi_obytes;
      }
    }

  }

  bool NativeHostDetail::read(HostDetail& detail) noexcept {
    TELAR_TRACE("metrics.readHostDetail");
    if (!readCores(detail) || !readMemory(detail)) {
      return false;
    }

    readMounts(detail);
    readDisks(detail);
    readInterfaces(detail, buffer_.viewMut());
    return true;
  }

}
