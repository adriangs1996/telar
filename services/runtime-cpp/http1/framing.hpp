#pragma once

#include <cstddef>

namespace telar::runtime {

struct Http1Framing {
  enum class Kind {
    none,
    content_length,
    chunked,
    until_close
  };

  Kind kind = Kind::none;
  std::size_t length = 0;

  bool hasBody() const noexcept {
    return kind == Kind::chunked || kind == Kind::until_close || (kind == Kind::content_length && length != 0);
  }
};

}
