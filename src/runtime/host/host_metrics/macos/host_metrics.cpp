module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.host.host_metrics;

import std;
import telar.sys.apple;
import telar.sys.posix;
import telar.sys.socket;

import telar.platform.primitives;
import telar.runtime.host.frameworks;
import telar.base.memory.containers;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime {
  namespace {

    // Whether `bits` carries `flag`, as the kernel's flag words carry them; tested unsigned.
    template <std::integral Bits>
    constexpr bool hasFlag(Bits bits, int flag) noexcept {
      return (static_cast<unsigned>(bits) & static_cast<unsigned>(flag)) != 0;
    }

    // The statistics host_statistics64 fills, which it takes as an array of words.
    template <typename Info>
    host_info64_t hostInfo(Info& info) noexcept {
      return reinterpret_cast<host_info64_t>(&info); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): host_statistics64 takes every kind of statistics as an array of words
    }

    ds::Option<std::int32_t> integerValue(CFDictionaryRef dictionary, CFStringRef key) noexcept {
      const auto* const value = CFDictionaryGetValue(dictionary, key);
      if (value == nullptr || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return ds::none;
      }

      std::int32_t integer = 0;
      if (CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt32Type, &integer) == 0U) {
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

      const auto* const array = static_cast<CFArrayRef>(sources.get());
      const auto count = CFArrayGetCount(array);

      for (CFIndex index = 0; index < count; ++index) {
        const auto* const description = IOPSGetPowerSourceDescription(information.get(), CFArrayGetValueAtIndex(array, index));
        if (description == nullptr) {
          continue;
        }

        const auto current = integerValue(description, power_source_keys::current_capacity);
        const auto maximum = integerValue(description, power_source_keys::max_capacity);
        if (!current || !maximum || *current < 0 || *maximum <= 0) {
          continue;
        }

        constexpr std::int64_t full_percent = 100;

        return static_cast<std::uint8_t>(std::min<std::int64_t>(full_percent, static_cast<std::int64_t>(*current) * full_percent / *maximum));
      }

      return ds::none;
    }

    // Activity Monitor's memory used: the anonymous pages but those an app marked purgeable, wired
    // pages and the compressor's. File-backed pages, active or not, are the cache.
    std::uint64_t usedPages(const vm_statistics64_data_t& memory) noexcept {
      const auto internal = static_cast<std::uint64_t>(memory.internal_page_count);
      const auto purgeable = static_cast<std::uint64_t>(memory.purgeable_count);

      return (internal > purgeable ? internal - purgeable : 0) + memory.wire_count + memory.compressor_page_count;
    }

    std::uint64_t cachedPages(const vm_statistics64_data_t& memory) noexcept {
      return static_cast<std::uint64_t>(memory.external_page_count) + memory.purgeable_count;
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
    const auto cpu_result = ::host_statistics64(host, HOST_CPU_LOAD_INFO, hostInfo(cpu), &cpu_words);
    vm_statistics64_data_t memory{};
    mach_msg_type_number_t memory_words = HOST_VM_INFO64_COUNT;
    const auto memory_result = ::host_statistics64(host, HOST_VM_INFO64, hostInfo(memory), &memory_words);

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

    // A NUL-padded field's text: up to its first NUL, or all of it.
    std::string_view fieldText(std::span<const char> field) noexcept {
      const auto end = std::ranges::find(field, '\0');

      return {field.data(), static_cast<std::size_t>(end - field.begin())};
    }

    template <std::size_t Capacity>
    void assignPrefix(FixedText<Capacity>& output, std::span<const char> field) noexcept { // NOLINT(bugprone-exception-escape): assign throws only past its capacity, which utf8Prefix rules out
      output.assign(utf8Prefix(fieldText(field), Capacity));
    }

    // The per-processor load records host_processor_info hands over as an array of words.
    std::span<const processor_cpu_load_info_data_t> processorLoads(const std::remove_pointer_t<processor_info_array_t>* information, natural_t count) noexcept {
      const auto* const loads = reinterpret_cast<const processor_cpu_load_info_data_t*>(information); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): host_processor_info returns its records as an array of words

#pragma clang unsafe_buffer_usage begin
      return {loads, count};
#pragma clang unsafe_buffer_usage end
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

      const auto loads = processorLoads(information, count);

      detail.core_count = static_cast<std::uint16_t>(std::min<std::size_t>(count, HostDetail::maximum_cores));
      for (std::size_t core = 0; core < detail.core_count; ++core) {
        const auto& ticks = loads[core].cpu_ticks;
        const auto busy = static_cast<std::uint64_t>(ticks[CPU_STATE_USER]) + ticks[CPU_STATE_SYSTEM] + ticks[CPU_STATE_NICE];

        detail.cores.atMut(core) = {.busy = busy, .total = busy + ticks[CPU_STATE_IDLE]};
      }

      ::vm_deallocate(::mach_task_self(), reinterpret_cast<vm_address_t>(information), static_cast<vm_size_t>(words) * sizeof(*information)); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): vm_deallocate takes the address as an integer
      return true;
    }

    bool readMemory(HostDetail& detail) noexcept {
      const auto host = ::mach_host_self();
      vm_statistics64_data_t memory{};
      mach_msg_type_number_t memory_words = HOST_VM_INFO64_COUNT;
      const auto result = ::host_statistics64(host, HOST_VM_INFO64, hostInfo(memory), &memory_words);

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
      // File-backed and purgeable pages: what the kernel drops first when memory runs short.
      detail.memory_cached_bytes = cachedPages(memory) * page;
      if (::sysctlbyname("vm.swapusage", &swap, &swap_size, nullptr, 0) == 0 && swap_size == sizeof(swap)) {
        detail.swap_total_bytes = swap.xsu_total;
        detail.swap_used_bytes = swap.xsu_used;
      }

      return true;
    }

    // The mount table getmntinfo keeps for the process, which hands it over as a pointer and a count.
    std::span<const sys::FileSystemStatus> mountTable() noexcept {
      sys::FileSystemStatus* table = nullptr;
      const auto count = ::getmntinfo(&table, MNT_NOWAIT);
      if (count <= 0) {
        return {};
      }

#pragma clang unsafe_buffer_usage begin
      return {table, static_cast<std::size_t>(count)};
#pragma clang unsafe_buffer_usage end
    }

    void readMounts(HostDetail& detail) noexcept {
      const auto table = mountTable();

      detail.mount_count = 0;
      for (std::size_t index = 0; index < table.size() && detail.mount_count < HostDetail::maximum_mounts; ++index) {
        const auto& mount = table[index];
        const auto type = fieldText(mount.f_fstypename);
        if (!hasFlag(mount.f_flags, MNT_LOCAL) || hasFlag(mount.f_flags, MNT_DONTBROWSE) || type == "devfs" || mount.f_blocks == 0) {
          continue;
        }

        auto& usage = detail.mounts.atMut(detail.mount_count++);
        const auto block = static_cast<std::uint64_t>(mount.f_bsize);

        assignPrefix(usage.path, mount.f_mntonname);
        assignPrefix(usage.device, mount.f_mntfromname);
        assignPrefix(usage.type, mount.f_fstypename);
        usage.total_bytes = mount.f_blocks * block;
        usage.used_bytes = (mount.f_blocks - std::min(mount.f_bfree, mount.f_blocks)) * block;
        usage.available_bytes = mount.f_bavail * block;
      }
    }

    std::uint64_t numberValue(CFDictionaryRef dictionary, CFStringRef key) noexcept {
      const auto* const value = CFDictionaryGetValue(dictionary, key);
      std::int64_t number = 0;
      if (value == nullptr || CFGetTypeID(value) != CFNumberGetTypeID() || (CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt64Type, &number) == 0U)) {
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
          const auto* const statistics = CFDictionaryGetValue(properties, block_storage_keys::statistics);
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
      ds::Array selector{CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
      auto length = buffer.size();

      detail.interface_count = 0;
      if (::sysctl(selector.dataMut(), static_cast<unsigned>(selector.size()), buffer.data(), &length, nullptr, 0) != 0) {
        return;
      }

      std::size_t offset = 0;

      while (offset + sizeof(if_msghdr2) <= length && detail.interface_count < HostDetail::maximum_interfaces) {
        if_msghdr2 message;

        std::ranges::copy(std::as_bytes(buffer.subspan(offset, sizeof(message))), std::as_writable_bytes(std::span{&message, 1}).begin());
        if (message.ifm_msglen == 0) {
          return;
        }

        offset += message.ifm_msglen;
        const auto active = hasFlag(message.ifm_flags, IFF_UP) && !hasFlag(message.ifm_flags, IFF_LOOPBACK);
        if (message.ifm_type != RTM_IFINFO2 || !active || (message.ifm_data.ifi_ibytes == 0 && message.ifm_data.ifi_obytes == 0)) {
          continue;
        }

        ds::Array<char, IF_NAMESIZE> name{};
        if (::if_indextoname(message.ifm_index, name.dataMut()) == nullptr) {
          continue;
        }

        auto& counters = detail.interfaces.atMut(detail.interface_count++);

        assignPrefix(counters.name, name.view());
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
