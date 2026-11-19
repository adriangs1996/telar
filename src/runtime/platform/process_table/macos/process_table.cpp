module telar.runtime.platform.process_table;

import std;
import telar.sys.posix;
import telar.sys.apple;
import telar.sys.process;

import telar.base.memory.allocators;
import telar.wire.monitor;
import telar.base.ds;

namespace telar::runtime {
  namespace {

    // Tries the listing again when processes appear between sizing the buffer and filling it.
    constexpr int listing_attempts = 4;

    ProcessState processState(char status) noexcept {
      switch (status) {
      case SIDL:
        return ProcessState::idle;
      case SRUN:
        return ProcessState::running;
      case SSLEEP:
        return ProcessState::sleeping;
      case SSTOP:
        return ProcessState::stopped;
      case SZOMB:
        return ProcessState::zombie;
      default:
        return ProcessState::unknown;
      }
    }

    // Task times count Mach absolute ticks, which are not nanoseconds on Apple silicon.
    std::uint64_t nanoseconds(std::uint64_t ticks) noexcept {
      static const auto timebase = [] {
        mach_timebase_info_data_t info{};
        if (::mach_timebase_info(&info) != KERN_SUCCESS || info.denom == 0) {
          info = {.numer = 1, .denom = 1};
        }

        return info;
      }();

      return ticks / timebase.denom * timebase.numer + ticks % timebase.denom * timebase.numer / timebase.denom;
    }

    ProcessRecord record(const kinfo_proc& process) noexcept {
      const auto& started = sys::processStarted(process);
      const auto& command = process.kp_proc.p_comm;
      ProcessRecord result{
          .pid = process.kp_proc.p_pid,
          .parent = process.kp_eproc.e_ppid,
          .user = process.kp_eproc.e_ucred.cr_uid,
          .started_seconds = static_cast<std::uint64_t>(started.tv_sec),
          .started_microseconds = static_cast<std::uint64_t>(started.tv_usec),
          .nice = static_cast<std::int8_t>(process.kp_proc.p_nice),
          .state = processState(process.kp_proc.p_stat),
      };

      result.name.assign({command, std::min(::strnlen(command, sizeof(command)), ProcessRecord::name_capacity)});

      proc_taskinfo task{};
      if (::proc_pidinfo(result.pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
        result.measured = true;
        result.cpu_nanoseconds = nanoseconds(task.pti_total_user + task.pti_total_system);
        result.resident_bytes = task.pti_resident_size;
        result.threads = static_cast<std::uint32_t>(std::max(task.pti_threadnum, 0));
      }

      return result;
    }

  }

  ProcessTable::ProcessTable(ConcurrentMemory& memory) noexcept
      : buffer_(memory) {}

  bool ProcessTable::read(ds::Vec<ProcessRecord, ConcurrentMemory>& records) {
    records.clear();
    int selector[]{CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};

    for (int attempt = 0; attempt < listing_attempts; ++attempt) {
      std::size_t length = 0;
      if (::sysctl(selector, 3, nullptr, &length, nullptr, 0) != 0) {
        return false;
      }

      // Room for the processes that start before the second call.
      length += length / 4;
      if (buffer_.size() < length) {
        buffer_.resize(length);
      }

      length = buffer_.size();
      if (::sysctl(selector, 3, buffer_.dataMut(), &length, nullptr, 0) != 0) {
        if (sys::lastError() == ENOMEM) {
          continue;
        }

        return false;
      }

      const auto count = length / sizeof(kinfo_proc);

      records.reserve(count);
      for (std::size_t index = 0; index < count; ++index) {
        kinfo_proc process;

        std::memcpy(&process, buffer_.data() + index * sizeof(kinfo_proc), sizeof(kinfo_proc));
        if (process.kp_proc.p_pid > 0) {
          records.push(record(process));
        }
      }

      return true;
    }

    return false;
  }

  ds::Option<ProcessRecord> ProcessTable::find(pid_t process) noexcept {
    if (process <= 0) {
      return ds::none;
    }

    int selector[]{CTL_KERN, KERN_PROC, KERN_PROC_PID, process};
    kinfo_proc information{};
    std::size_t length = sizeof(information);
    if (::sysctl(selector, 4, &information, &length, nullptr, 0) != 0 || length != sizeof(information) || information.kp_proc.p_pid != process) {
      return ds::none;
    }

    return record(information);
  }

  ProcessActionResult ProcessTable::signal(pid_t process, std::uint64_t started_seconds, std::uint64_t started_microseconds, int signal) noexcept {
    if (process <= 0 || !sameProcessInstance(process, started_seconds, started_microseconds)) {
      return ProcessActionResult::gone;
    }

    if (::kill(process, signal) != 0) {
      return actionFailure(sys::lastError());
    }

    return ProcessActionResult::done;
  }

}
