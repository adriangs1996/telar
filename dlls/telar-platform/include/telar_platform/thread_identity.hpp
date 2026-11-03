#pragma once

#include <cstdint>
#include <pthread.h>
#include <unistd.h>

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
