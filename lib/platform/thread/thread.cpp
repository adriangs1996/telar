module;
#include <pthread.h>
#include <unistd.h>

module telar.platform.thread;

import std;

namespace telar::runtime {

  std::uint64_t currentThreadId() noexcept {
#if defined(__APPLE__)
    std::uint64_t identity = 0;

    ::pthread_threadid_np(nullptr, &identity);
    return identity;
#else
    return static_cast<std::uint64_t>(::gettid());
#endif
  }

  void setThreadName(const char* name) noexcept {
#if defined(__APPLE__)
    ::pthread_setname_np(name);
#else
    ::pthread_setname_np(::pthread_self(), name);
#endif
  }

}
