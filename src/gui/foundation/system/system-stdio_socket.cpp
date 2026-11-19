module telar.gui.foundation.system;

import std;

import telar.platform.error;
import telar.sys.posix;
import telar.sys.socket;
import telar.platform.primitives;
import telar.base.ds;
#ifdef __linux__
import telar.sys.linux_api;
#endif

namespace telar::gui::inline foundation::inline system {

  namespace {

    void prepareDescriptor(runtime::FileDescriptor& descriptor) {
      if (descriptor.get() <= STDERR_FILENO) {
        descriptor = runtime::duplicateCloseOnExec(descriptor.get(), STDERR_FILENO + 1);
      } else {
        runtime::setCloseOnExec(descriptor.get());
      }
    }

    int redirectDescriptor(int source, int destination) noexcept {
      while (::dup2(source, destination) < 0) {
        if (sys::lastError() != EINTR) {
          return sys::lastError();
        }
      }

      return 0;
    }

  }

  StdioSocket openStdioSocket() {
    ds::Array<int, 2> descriptors{};
#ifdef __linux__
    constexpr auto flags = SOCK_STREAM | SOCK_CLOEXEC;
#else
    constexpr auto flags = SOCK_STREAM;
#endif
    if (::socketpair(AF_UNIX, flags, 0, descriptors.dataMut()) != 0) {
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
