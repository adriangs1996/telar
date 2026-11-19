module telar.runtime.platform.process_table;

import std;
import telar.sys.posix;
import telar.sys.process;

namespace telar::runtime {

  ProcessActionResult actionFailure(int error) noexcept {
    if (error == ESRCH) {
      return ProcessActionResult::gone;
    }

    return error == EPERM || error == EACCES ? ProcessActionResult::denied : ProcessActionResult::failed;
  }

  bool sameProcessInstance(pid_t process, std::uint64_t started_seconds, std::uint64_t started_microseconds) noexcept {
    const auto current = ProcessTable::find(process);
    if (!current) {
      return false;
    }

    return (started_seconds == 0 && started_microseconds == 0) || (current->started_seconds == started_seconds && current->started_microseconds == started_microseconds);
  }

  ProcessActionResult ProcessTable::prioritize(pid_t process, std::uint64_t started_seconds, std::uint64_t started_microseconds, int nice) noexcept {
    if (process <= 0 || !sameProcessInstance(process, started_seconds, started_microseconds)) {
      return ProcessActionResult::gone;
    }

    if (::setpriority(PRIO_PROCESS, static_cast<id_t>(process), nice) != 0) {
      return actionFailure(sys::lastError());
    }

    return ProcessActionResult::done;
  }

}
