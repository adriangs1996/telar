#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_platform/file_descriptor.hpp"
#include <cerrno>
#include <exception>
#include <fcntl.h>



import telar.platform;

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
