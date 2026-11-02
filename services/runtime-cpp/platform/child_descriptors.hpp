#pragma once

#include <array>
#if defined(__APPLE__)
#include <libproc.h>
#else
#include <linux/close_range.h>
#include <sys/syscall.h>
#include <limits.h>
#endif
#include <unistd.h>

namespace telar::runtime {

inline void closeChildDescriptors(int retained, int descriptor_limit) noexcept {
#if defined(__APPLE__)
  // Only the forked child enumerates descriptors, so no other thread can open
  // one during the scan. proc_pidinfo copies kernel data into this stack buffer.
  std::array<proc_fdinfo, 1024> descriptors;
  const int bytes = ::proc_pidinfo(::getpid(), PROC_PIDLISTFDS, 0, descriptors.data(), sizeof(descriptors));

  if (bytes > 0 && bytes < static_cast<int>(sizeof(descriptors)) && bytes % sizeof(proc_fdinfo) == 0) {
    const auto count = static_cast<std::size_t>(bytes) / sizeof(proc_fdinfo);
    for (std::size_t index = 0; index < count; ++index) {
      const int descriptor = descriptors[index].proc_fd;
      if (descriptor > STDERR_FILENO && descriptor != retained) {
        ::close(descriptor);
      }
    }
    return;
  }
#else
  const auto first = static_cast<unsigned>(STDERR_FILENO + 1);
  const bool lower_closed = retained <= static_cast<int>(first) || ::syscall(SYS_close_range, first, static_cast<unsigned>(retained - 1), 0) == 0;
  const bool upper_closed = ::syscall(SYS_close_range, static_cast<unsigned>(retained + 1), UINT_MAX, 0) == 0;
  if (lower_closed && upper_closed) {
    return;
  }
#endif

  for (int descriptor = STDERR_FILENO + 1; descriptor < descriptor_limit; ++descriptor) {
    if (descriptor != retained) {
      ::close(descriptor);
    }
  }
}

}
