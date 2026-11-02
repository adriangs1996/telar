#pragma once

#include <pthread.h>

namespace telar::runtime {

inline void setThreadName(const char *name) noexcept {
#if defined(__APPLE__)
  ::pthread_setname_np(name);
#else
  ::pthread_setname_np(::pthread_self(), name);
#endif
}

}
