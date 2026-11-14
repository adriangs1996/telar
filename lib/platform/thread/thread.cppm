module;
#include "tbc/hot_path.hpp"

export module telar.platform.thread;

import std;

import telar.platform.error;

// Interface: telar_platform/start_thread.cppm
export {
  namespace telar::runtime {

    // A thread running `body`, whose failure to start is the SystemError every other system call
    // reports. Its owner joins it before anything the body touches goes away. It stays in the
    // interface because it is a template over the caller's body.
    template <typename Body>
    TBC_HOT_PATH inline std::jthread startThread(const char* operation, Body&& body) {
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

    std::uint64_t currentThreadId() noexcept;

  }
}

// Interface: telar_platform/thread_name.cppm
export {
  namespace telar::runtime {

    void setThreadName(const char* name) noexcept;

  }
}
