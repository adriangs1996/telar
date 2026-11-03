#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

namespace telar::runtime::cli {

// A command that failed after its arguments parsed: `what()` is the text after
// the family's prefix on stderr, `status` the exit status (2 for a missing
// target, 3 for a timeout), and `code` the runtime's refusal, if any.
class Failure : public std::runtime_error {
public:
  explicit Failure(std::string_view message, int status = 1, std::optional<FailureCode> code = std::nullopt)
      : std::runtime_error{std::string{message}},
        status_(status),
        code_(code) {}

  [[nodiscard]] int status() const noexcept {
    return status_;
  }

  [[nodiscard]] std::optional<FailureCode> code() const noexcept {
    return code_;
  }

private:
  int status_;
  std::optional<FailureCode> code_;
};

}
