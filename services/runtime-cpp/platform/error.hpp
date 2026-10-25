#pragma once

#include <cerrno>
#include <exception>

namespace telar::runtime {

class SystemError final : public std::exception {
public:
  explicit SystemError(const char *operation, int code = errno) noexcept
      : operation_(operation),
        code_(code) {}

  const char *what() const noexcept override {
    return operation_;
  }

  int code() const noexcept {
    return code_;
  }

private:
  const char *operation_;
  int code_;
};

}
