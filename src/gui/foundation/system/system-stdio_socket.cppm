export module telar.gui.foundation.system:stdio_socket;

import telar.platform.primitives;

export {
  namespace telar::gui::inline foundation::inline system {

    struct StdioSocket {
      StdioSocket() = default;

      runtime::FileDescriptor local;
      runtime::FileDescriptor child;
    };

    [[nodiscard]] StdioSocket openStdioSocket();
    [[nodiscard]] int bindStandardIo(int descriptor) noexcept;

  }
}
