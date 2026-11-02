#pragma once

#include "platform/file_descriptor.hpp"

namespace telar::gui::platform {

struct StdioSocket {
  StdioSocket() = default;

  runtime::FileDescriptor local;
  runtime::FileDescriptor child;
};

[[nodiscard]] StdioSocket openStdioSocket();
[[nodiscard]] int bindStandardIo(int descriptor) noexcept;

}
