#pragma once

#include "arguments.hpp"
#include "json_text.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_platform/error.hpp"
#include <charconv>
#include <limits>
#include <span>
#include <stdexcept>
#include <string>
#include <unistd.h>

namespace telar::runtime::cli {

inline std::string quoteJson(std::string_view text, JsonEscapes escapes = JsonEscapes::standard) {
  std::string result;
  result.reserve(text.size() + 2);
  appendJsonText(result, text, escapes);
  return result;
}

inline void writeBytes(int descriptor, std::span<const Byte> bytes) {
  while (!bytes.empty()) {
    const auto count = ::write(descriptor, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count <= 0) {
      throw std::runtime_error{"WriteFailed"};
    }

    bytes = bytes.subspan(static_cast<std::size_t>(count));
  }
}

inline void writeText(std::string_view text, int descriptor = STDOUT_FILENO) {
  writeBytes(descriptor, {reinterpret_cast<const Byte *>(text.data()), text.size()});
}

inline std::string_view textBytes(std::span<const Byte> bytes) {
  return {reinterpret_cast<const char *>(bytes.data()), bytes.size()};
}

inline std::uint64_t randomIdentity() {
  std::uint64_t value = 0;
  while (value == 0) {
    ::arc4random_buf(&value, sizeof(value));
  }

  return value;
}

inline const char *jsonBoolean(bool value) {
  return value ? "true" : "false";
}

inline const char *systemErrorName(int code) {
  switch (code) {
  case ENOENT:
    return "FileNotFound";
  case ECONNREFUSED:
    return "ConnectionRefused";
  case EACCES:
  case EPERM:
    return "AccessDenied";
  case ENOTDIR:
    return "NotDir";
  case ENAMETOOLONG:
    return "NameTooLong";
  case ELOOP:
    return "SymLinkLoop";
  default:
    return "InputOutput";
  }
}

inline std::string_view commandErrorName(const std::exception &error) {
  if (const auto *system = dynamic_cast<const SystemError *>(&error)) {
    return systemErrorName(system->code());
  }

  if (std::string_view{error.what()} == "Runtime receive timed out") {
    return "RuntimeTimeout";
  }

  return error.what();
}

}
