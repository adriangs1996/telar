#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <exception>

namespace telar::runtime {

class RequestError final : public std::exception {
public:
  explicit RequestError(FailureCode code, const char *message) noexcept
      : code_(code),
        message_(message) {}

  FailureCode code() const noexcept {
    return code_;
  }

  const char *what() const noexcept override {
    return message_;
  }

private:
  FailureCode code_;
  const char *message_;
};

}
