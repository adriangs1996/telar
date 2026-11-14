export module telar.platform.daemon;

import std;

export import telar.base.memory.allocators;
export import telar.platform.paths;
export import telar.platform.process;

import telar.platform.error;
import telar.platform.primitives;
import telar.sys.posix;

// Interface: telar_platform/daemon.cppm
export {
  namespace telar::runtime::cli {

    FileDescriptor openStartLog(const char* path) noexcept;
    pid_t spawnDaemon(const char* executable, char* const* arguments, const char* log_path);

    template <Allocator Memory>
    pid_t launchDaemon(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths, const ExecutablePath& executable);

  }
}

// The allocators the template above is built for, in daemon.cpp: those of RuntimePaths.
namespace telar::runtime::cli {

  extern template pid_t launchDaemon<Memory>(Memory&, const ServerOptions&, const RuntimePaths<Memory>&, const ExecutablePath&);
  extern template pid_t launchDaemon<ConcurrentMemory>(ConcurrentMemory&, const ServerOptions&, const RuntimePaths<ConcurrentMemory>&, const ExecutablePath&);
  extern template pid_t launchDaemon<SystemAllocator>(SystemAllocator&, const ServerOptions&, const RuntimePaths<SystemAllocator>&, const ExecutablePath&);
  extern template pid_t launchDaemon<BudgetAllocator<SystemAllocator>>(BudgetAllocator<SystemAllocator>&, const ServerOptions&, const RuntimePaths<BudgetAllocator<SystemAllocator>>&, const ExecutablePath&);
  extern template pid_t launchDaemon<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>&, const ServerOptions&, const RuntimePaths<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>&, const ExecutablePath&);

}
