module telar.platform.thread;

import std;
import telar.sys.process;
#ifdef __APPLE__
import telar.sys.apple;
#endif
#ifdef __linux__
import telar.sys.linux_api;
#endif

namespace telar::runtime {

  std::uint64_t currentThreadId() noexcept {
#ifdef __APPLE__
    std::uint64_t identity = 0;

    ::pthread_threadid_np(nullptr, &identity);
    return identity;
#else
    return static_cast<std::uint64_t>(::gettid());
#endif
  }

  void setThreadName(const char* name) noexcept {
#ifdef __APPLE__
    ::pthread_setname_np(name);
#else
    ::pthread_setname_np(::pthread_self(), name);
#endif
  }

}
