module telar.platform.error;

import std;

namespace telar::runtime {

  SystemError::SystemError(const char* operation, int code) noexcept
      : operation_(operation),
        code_(code) {}

  const char* SystemError::what() const noexcept {
    return operation_;
  }

  int SystemError::code() const noexcept {
    return code_;
  }

}
