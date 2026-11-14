export module telar.gui.platform.stdio_socket;

import telar.platform.primitives;

export {
  namespace telar::gui::platform {

    struct StdioSocket {
      StdioSocket() = default;

      runtime::FileDescriptor local;
      runtime::FileDescriptor child;
    };

    [[nodiscard]] StdioSocket openStdioSocket();
    [[nodiscard]] int bindStandardIo(int descriptor) noexcept;

  }
}
