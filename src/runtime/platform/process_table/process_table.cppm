module;
#include "tbc/annotations.hpp"

export module telar.runtime.platform.process_table;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: platform/process_table.cppm
export {
  namespace telar::runtime {

    enum class ProcessState : std::uint8_t {
      unknown,
      running,
      sleeping,
      idle,
      stopped,
      zombie,
    };

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
      FixedText<name_capacity> name{};
    };

    // Reads the kernel's process table. It keeps the buffer a listing needs between reads, so a read
    // allocates only when the table outgrows every earlier one.
    class ProcessTable {
    public:
      explicit ProcessTable(tbc::view<ConcurrentMemory&, tbc::lt::a> memory) noexcept;

      // Replaces `records` with every process listed now; false when the table cannot be read.
      bool read(ds::Vec<ProcessRecord, ConcurrentMemory>& records);

      // One process, none once it is gone.
      static ds::Option<ProcessRecord> find(pid_t process) noexcept;

    private:
      tbc::view<ds::Vec<std::byte, ConcurrentMemory>, tbc::lt::a> buffer_;
    };

  }
}
