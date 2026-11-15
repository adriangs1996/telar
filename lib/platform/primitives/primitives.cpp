module telar.platform.primitives;

import std;
import telar.platform.error;
import telar.sys.posix;
#if defined(__APPLE__)
import telar.sys.apple;
#else
import telar.sys.linux_api;
#endif

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar::runtime {

  FileDescriptor duplicateCloseOnExec(int descriptor, int minimum) {
    const int copied = ::fcntl(descriptor, F_DUPFD_CLOEXEC, minimum);
    if (copied < 0) {
      throw SystemError{"duplicate close-on-exec descriptor"};
    }

    return FileDescriptor{copied};
  }

  void setNonblocking(int descriptor) {
    const int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0) {
      throw SystemError{"set nonblocking descriptor"};
    }
  }

  void setCloseOnExec(int descriptor) {
    const int flags = fcntl(descriptor, F_GETFD);
    if (flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) < 0) {
      throw SystemError{"set close-on-exec descriptor"};
    }
  }

}
}

namespace telar::runtime {

  void randomBytes(void* data, std::size_t size) noexcept {
#if defined(__linux__)
    auto* cursor = static_cast<unsigned char*>(data);
    while (size != 0) {
      const auto count = ::getrandom(cursor, size, 0);
      if (count < 0) {
        if (sys::lastError() == EINTR) {
          continue;
        }

        std::abort();
      }

      cursor += count;
      size -= static_cast<std::size_t>(count);
    }
#else
    ::arc4random_buf(data, size);
#endif
  }

}
