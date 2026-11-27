module telar.runtime.host.process_table;

import std;
import telar.sys.posix;
import telar.sys.linux_api;
import telar.sys.process;

import telar.runtime.host.proc_file;
import telar.platform.fs;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.wire.monitor;
import telar.base.text;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime {
  namespace {

    // /proc/PID/stat is one line of 52 fields; a name of 16 bytes keeps it far below this.
    constexpr std::size_t stat_capacity = 1024;
    constexpr std::uint64_t microseconds_per_second = 1'000'000;
    constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;

    ProcessState processState(char state) noexcept {
      switch (state) {
      case 'R':
        return ProcessState::running;
      case 'S':
      case 'D':
        return ProcessState::sleeping;
      case 'I':
        return ProcessState::idle;
      case 'T':
      case 't':
        return ProcessState::stopped;
      case 'Z':
      case 'X':
        return ProcessState::zombie;
      default:
        return ProcessState::unknown;
      }
    }

    ds::Option<ProcessRecord> record(pid_t process) noexcept {
      static const auto ticks_per_second = ::sysconf(_SC_CLK_TCK);
      static const auto page_size = ::sysconf(_SC_PAGESIZE);
      if (process <= 0 || ticks_per_second <= 0 || page_size <= 0) {
        return ds::none;
      }

      const ProcDirectory directory{process};
      ds::Array<char, stat_capacity> storage;
      const auto bytes = directory.read("stat", storage.viewMut());
      const auto status = bytes ? ProcStat::parse(*bytes) : ds::none;
      const auto owner = directory.owner();
      if (!status || !owner) {
        return ds::none;
      }

      const auto frequency = static_cast<std::uint64_t>(ticks_per_second);
      ProcessRecord result{
          .pid = process,
          .parent = status->parent,
          .user = *owner,
          .started_seconds = status->started_ticks / frequency,
          .started_microseconds = status->started_ticks % frequency * microseconds_per_second / frequency,
          .measured = true,
          .cpu_nanoseconds = status->cpu_ticks / frequency * nanoseconds_per_second + status->cpu_ticks % frequency * nanoseconds_per_second / frequency,
          .resident_bytes = status->resident_pages * static_cast<std::uint64_t>(page_size),
          .threads = status->threads,
          .nice = status->nice,
          .state = processState(status->state),
      };

      result.name.assign(utf8Prefix(status->name, ProcessRecord::name_capacity));
      return result;
    }

  }

  ProcessTable::ProcessTable(ConcurrentMemory& memory) noexcept
      : buffer_(memory) {}

  bool ProcessTable::read(ds::Vec<ProcessRecord, ConcurrentMemory>& records) {
    records.clear();
    FileDescriptor proc{::open("/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    if (!proc) {
      return false;
    }

    DirectoryStream entries{std::move(proc)};

    while (const auto* entry = entries.next()) {
      const auto process = parseExact<pid_t>(std::string_view{entry->d_name});
      if (!process) {
        continue;
      }

      if (auto found = record(*process)) {
        records.push(*found);
      }
    }

    return true;
  }

  ds::Option<ProcessRecord> ProcessTable::find(pid_t process) noexcept {
    return record(process);
  }

  // /proc/PID/stat counts a start in ticks since boot, suspended time included.
  std::chrono::microseconds ProcessTable::clock() noexcept {
    timespec now{};
    if (::clock_gettime(CLOCK_BOOTTIME, &now) != 0) {
      return {};
    }

    return std::chrono::seconds{now.tv_sec} + std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::nanoseconds{now.tv_nsec});
  }

  ProcessActionResult ProcessTable::signal(ProcessInstance process, int signal) noexcept {
    if (process.pid <= 0) {
      return ProcessActionResult::gone;
    }

    // The descriptor names this instance: the check below and the signal reach the same process.
    FileDescriptor instance{static_cast<int>(::syscall(SYS_pidfd_open, process.pid, 0))};
    if (!instance && sys::lastError() != ENOSYS) {
      return actionFailure(sys::lastError());
    }

    if (!sameProcessInstance(process)) {
      return ProcessActionResult::gone;
    }

    // Kernels before 5.3 have no pidfd; they keep the instant between the check and kill.
    const auto sent = instance ? ::syscall(SYS_pidfd_send_signal, instance.get(), signal, nullptr, 0) : ::kill(process.pid, signal);
    if (sent != 0) {
      return actionFailure(sys::lastError());
    }

    return ProcessActionResult::done;
  }

}
