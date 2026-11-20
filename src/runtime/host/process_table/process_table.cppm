module;
#include "tbc/annotations.hpp"

export module telar.runtime.host.process_table;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.monitor;
import telar.base.ds;

// Interface: platform/process_table.cppm
export {
  namespace telar::runtime {

    // One process as the kernel lists it, of any user.
    struct ProcessRecord {
      static constexpr std::size_t name_capacity = 32;

      pid_t pid = 0;
      pid_t parent = 0;
      uid_t user = 0;
      // The start the process inspector names an instance by (ProcessIdentity::started_*).
      std::uint64_t started_seconds = 0;
      std::uint64_t started_microseconds = 0;
      // CPU time, resident memory and threads; macOS lends them only for the user's own
      // processes unless the runtime runs as root.
      bool measured = false;
      std::uint64_t cpu_nanoseconds = 0;
      std::uint64_t resident_bytes = 0;
      std::uint32_t threads = 0;
      std::int8_t nice = 0;
      ProcessState state = ProcessState::unknown;
      FixedText<name_capacity> name;
    };

    enum class ProcessActionResult : std::uint8_t {
      done,
      // No process has the pid, or another one does now.
      gone,
      // The runtime's user may not act on it.
      denied,
      failed,
    };

    // Reads the kernel's process table. It keeps the buffer a listing needs between reads, so a read
    // allocates only when the table outgrows every earlier one.
    class ProcessTable {
    public:
      explicit ProcessTable(tbc::mut_a<ConcurrentMemory> memory) noexcept;

      // Replaces `records` with every process listed now; false when the table cannot be read.
      bool read(ds::Vec<ProcessRecord, ConcurrentMemory>& records);

      // One process, none once it is gone.
      static ds::Option<ProcessRecord> find(pid_t process) noexcept;

      // Sends the signal to the process if it is still that instance; a start of
      // zero accepts whichever process has the pid. Linux sends it through a pidfd, so a pid recycled
      // after the check never receives it; macOS has none, which leaves the instant between the
      // check and kill.
      static ProcessActionResult signal(ProcessInstance process, int signal) noexcept;

      // Sets the nice value of the process if it is still that instance.
      static ProcessActionResult prioritize(ProcessInstance process, int nice) noexcept;

    private:
      tbc::val_a<ds::Vec<std::byte, ConcurrentMemory>> buffer_;
    };

  }
}

// Shared by the platforms' units of this module.
namespace telar::runtime {

  // Whether the process with the pid is still the instance that started then.
  bool sameProcessInstance(ProcessInstance process) noexcept;

  ProcessActionResult actionFailure(int error) noexcept;

}
