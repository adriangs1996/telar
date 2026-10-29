#include "stdio_socket.hpp"
#include "platform/error.hpp"
#include "platform/file_descriptor.hpp"
#include <array>
#include <cerrno>
#include <sys/socket.h>
#include <unistd.h>

namespace telar::gui::platform {

namespace {

void prepareDescriptor(runtime::FileDescriptor &descriptor) {
  if (descriptor.get() <= STDERR_FILENO) {
    descriptor = runtime::duplicateCloseOnExec(descriptor.get(), STDERR_FILENO + 1);
  } else {
    runtime::setCloseOnExec(descriptor.get());
  }
}

int redirectDescriptor(int source, int destination) noexcept {
  while (::dup2(source, destination) < 0) {
    if (errno != EINTR) {
      return errno;
    }
  }

  return 0;
}

}

StdioSocket openStdioSocket() {
  std::array<int, 2> descriptors{};
#ifdef __linux__
  constexpr auto flags = SOCK_STREAM | SOCK_CLOEXEC;
#else
  constexpr auto flags = SOCK_STREAM;
#endif
  if (::socketpair(AF_UNIX, flags, 0, descriptors.data()) != 0) {
    throw runtime::SystemError{"Create SSH bridge socket"};
  }

  StdioSocket result;
  result.local.reset(descriptors[0]);
  result.child.reset(descriptors[1]);
  prepareDescriptor(result.local);
  prepareDescriptor(result.child);

  return result;
}

int bindStandardIo(int descriptor) noexcept {
  const auto input_error = redirectDescriptor(descriptor, STDIN_FILENO);

  return input_error != 0 ? input_error : redirectDescriptor(descriptor, STDOUT_FILENO);
}

}
