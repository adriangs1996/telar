#pragma once

#include "telar_client/request_error.hpp"
#include "telar_platform/error.hpp"
#include <new>
#include <string_view>

namespace telar::runtime {

inline std::string_view launchFailureCause(const std::exception &error) noexcept {
  if (dynamic_cast<const std::bad_alloc *>(&error) != nullptr) {
    return "OutOfMemory";
  }
  if (const auto *request = dynamic_cast<const RequestError *>(&error)) {
    return request->code() == FailureCode::resource_limit ? "PaneLimitReached" : "Unexpected";
  }
  if (const auto *system = dynamic_cast<const SystemError *>(&error)) {
    switch (system->code()) {
    case ENOMEM:
    case ENOBUFS:
      return "SystemResources";
    case EACCES:
    case EPERM:
      return "PermissionDenied";
    case EBADF:
      return "InvalidDescriptor";
    default:
      return "Unexpected";
    }
  }

  return "Unexpected";
}

}
