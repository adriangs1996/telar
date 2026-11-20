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

  bool sameProcessInstance(ProcessInstance process) noexcept {
    const auto current = ProcessTable::find(process.pid);
    if (!current) {
      return false;
    }

    return (process.started_seconds == 0 && process.started_microseconds == 0) || (current->started_seconds == process.started_seconds && current->started_microseconds == process.started_microseconds);
  }

  ProcessActionResult ProcessTable::prioritize(ProcessInstance process, int nice) noexcept {
    if (process.pid <= 0 || !sameProcessInstance(process)) {
      return ProcessActionResult::gone;
    }

    if (::setpriority(PRIO_PROCESS, static_cast<id_t>(process.pid), nice) != 0) {
      return actionFailure(sys::lastError());
    }

    return ProcessActionResult::done;
  }

}
