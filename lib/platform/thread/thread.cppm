module;
#include <pthread.h>
#include <unistd.h>

export module telar.platform.thread;

import std;

import telar.platform.error;

// Interface: telar_platform/start_thread.cppm
export {
  namespace telar::runtime {

    // A thread running `body`, whose failure to start is the SystemError every other system call
    // reports. Its owner joins it before anything the body touches goes away.
    template <typename Body>
    inline std::jthread startThread(const char* operation, Body&& body) {
      try {
        return std::jthread{std::forward<Body>(body)};
      } catch (const std::system_error& error) {
        throw SystemError{operation, error.code().value()};
      }
    }

  }
}

// Interface: telar_platform/thread_identity.cppm
export {
  namespace telar::runtime {

    inline std::uint64_t currentThreadId() noexcept {
#if defined(__APPLE__)
      std::uint64_t identity = 0;

      ::pthread_threadid_np(nullptr, &identity);
      return identity;
#else
      return static_cast<std::uint64_t>(::gettid());
#endif
    }

  }
}

// Interface: telar_platform/thread_name.cppm
export {
  namespace telar::runtime {

    inline void setThreadName(const char* name) noexcept {
#if defined(__APPLE__)
      ::pthread_setname_np(name);
#else
      ::pthread_setname_np(::pthread_self(), name);
#endif
    }

  }
}
