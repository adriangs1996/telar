module telar.runtime.host.process_table;

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

    // A NUL-padded field's text: up to its first NUL, or all of it.
    std::string_view fieldText(std::span<const char> field) noexcept {
      const auto end = std::ranges::find(field, '\0');

      return {field.data(), static_cast<std::size_t>(end - field.begin())};
    }

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

      return (ticks / timebase.denom * timebase.numer) + (ticks % timebase.denom * timebase.numer / timebase.denom);
    }

    ProcessRecord record(const kinfo_proc& process) noexcept { // NOLINT(bugprone-exception-escape): assign throws only past its capacity, which the name is cut to
      const auto& started = sys::processStarted(process);
      const auto command = fieldText(process.kp_proc.p_comm);
      ProcessRecord result{
          .pid = process.kp_proc.p_pid,
          .parent = process.kp_eproc.e_ppid,
          .user = process.kp_eproc.e_ucred.cr_uid,
          .started_seconds = static_cast<std::uint64_t>(started.tv_sec),
          .started_microseconds = static_cast<std::uint64_t>(started.tv_usec),
          .nice = static_cast<std::int8_t>(process.kp_proc.p_nice),
          .state = processState(process.kp_proc.p_stat),
      };

      result.name.assign({command.data(), std::min(command.size(), ProcessRecord::name_capacity)});

      proc_taskinfo task{};
      if (::proc_pidinfo(result.pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
        result.measured = true;
        result.cpu_nanoseconds = nanoseconds(task.pti_total_user + task.pti_total_system);
        result.resident_bytes = task.pti_resident_size;
        result.threads = static_cast<std::uint32_t>(std::max(task.pti_threadnum, 0));
        // The kernel lists a sleeping process as runnable; its threads tell them apart, as for top.
        if (result.state == ProcessState::running && task.pti_numrunning == 0) {
          result.state = ProcessState::sleeping;
        }
      }

      return result;
    }

  }

  ProcessTable::ProcessTable(ConcurrentMemory& memory) noexcept
      : buffer_(memory) {}

  bool ProcessTable::read(ds::Vec<ProcessRecord, ConcurrentMemory>& records) {
    records.clear();
    // KERN_PROC_ALL takes no argument, so the calls pass the first three words.
    ds::Array selector{CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};

    for (int attempt = 0; attempt < listing_attempts; ++attempt) {
      std::size_t length = 0;
      if (::sysctl(selector.dataMut(), 3, nullptr, &length, nullptr, 0) != 0) {
        return false;
      }

      // Room for the processes that start before the second call.
      length += length / 4;
      if (buffer_.size() < length) {
        buffer_.resize(length);
      }

      length = buffer_.size();
      if (::sysctl(selector.dataMut(), 3, buffer_.dataMut(), &length, nullptr, 0) != 0) {
        if (sys::lastError() == ENOMEM) {
          continue;
        }

        return false;
      }

      const auto count = length / sizeof(kinfo_proc);

      records.reserve(count);
      for (std::size_t index = 0; index < count; ++index) {
        kinfo_proc process;

        std::ranges::copy(buffer_.view().subspan(index * sizeof(kinfo_proc), sizeof(kinfo_proc)), std::as_writable_bytes(std::span{&process, 1}).begin());
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

    ds::Array selector{CTL_KERN, KERN_PROC, KERN_PROC_PID, process};
    kinfo_proc information{};
    std::size_t length = sizeof(information);
    if (::sysctl(selector.dataMut(), static_cast<unsigned>(selector.size()), &information, &length, nullptr, 0) != 0 || length != sizeof(information) || information.kp_proc.p_pid != process) {
      return ds::none;
    }

    return record(information);
  }

  ProcessActionResult ProcessTable::signal(ProcessInstance process, int signal) noexcept {
    if (process.pid <= 0 || !sameProcessInstance(process)) {
      return ProcessActionResult::gone;
    }

    if (::kill(process.pid, signal) != 0) {
      return actionFailure(sys::lastError());
    }

    return ProcessActionResult::done;
  }

}
