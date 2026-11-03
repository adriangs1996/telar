#pragma once

#include "../http1/number.hpp"
#include "telar_base/text/ascii.hpp"
#include "telar_base/text/fields.hpp"
#include <algorithm>

namespace telar::runtime {

class Http2HeaderMetadata {
public:
  void observe(std::string_view name, std::string_view value) noexcept {
    if (name == ":status") {
      const auto parsed = parseHttpNumber<10>(value);
      status_ = parsed && *parsed <= std::numeric_limits<std::uint16_t>::max() ? static_cast<std::uint16_t>(*parsed) : 0;
    }
    if (name == ":method") {
      request_ = true;
    }
    if (equalIgnoringCase(name, "content-type")) {
      if (content_type_seen_) {
        metadata_valid_ = false;
      } else {
        content_type_seen_ = true;
        event_stream_ = equalIgnoringCase(trimText(value.substr(0, value.find(';')), " \t"), "text/event-stream");
      }
    }
    if (equalIgnoringCase(name, "content-encoding") && !identityEncoding(value)) {
      identity_encoding_ = false;
    }
  }

  std::uint16_t status() const noexcept { return status_; }
  bool request() const noexcept { return request_; }
  bool eventStream() const noexcept { return metadata_valid_ && content_type_seen_ && event_stream_ && identity_encoding_; }

private:
  static bool equalIgnoringCase(std::string_view left, std::string_view right) noexcept {
    return std::ranges::equal(left, right, [](char first, char second) { return asciiLower(first) == asciiLower(second); });
  }

  static bool identityEncoding(std::string_view value) noexcept {
    TextFields fields{value, ","};
    while (const auto field = fields.next()) {
      if (!equalIgnoringCase(trimText(*field, " \t"), "identity")) {
        return false;
      }
    }
    return true;
  }

  std::uint16_t status_ = 0;
  bool request_ = false;
  bool content_type_seen_ = false;
  bool event_stream_ = false;
  bool identity_encoding_ = true;
  bool metadata_valid_ = true;
};

}
