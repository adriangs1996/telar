#pragma once

#include "../../diagnostics/trace.hpp"
#include "../../platform/error.hpp"
#include "object.hpp"
#include "validation.hpp"
#include <unistd.h>

namespace telar::runtime::cli::hooks {

template <Allocator Memory>
class Input {
public:
  static constexpr std::size_t maximum_bytes = 16 * 1024 * 1024;

  explicit Input(Memory &memory)
      : text_(AllocatorRef<char, Memory>{memory}) {}

  void read(int descriptor) {
    TELAR_TRACE("hooks.readInput");
    std::array<char, 4096> buffer;
    for (;;) {
      const auto count = ::read(descriptor, buffer.data(), buffer.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0) {
        throw SystemError{"Read hook input"};
      }
      if (count == 0) {
        break;
      }

      received_ += static_cast<std::size_t>(count);
      text_.append(buffer.data(), std::min(static_cast<std::size_t>(count), maximum_bytes - text_.size()));
    }

    if (limited()) {
      keepWholeMembers();
    }
  }

  bool limited() const noexcept { return received_ > maximum_bytes; }
  std::uint64_t received() const noexcept { return received_; }
  std::string_view text() const noexcept { return text_; }

private:
  void keepWholeMembers() {
    const auto opening = text_.find_first_not_of(" \r\n\t");
    if (opening == std::string_view::npos || text_[opening] != '{') {
      text_ = "{}";
      return;
    }

    std::size_t depth = 0;
    std::size_t complete = 0;
    std::size_t member_start = opening + 1;
    String<Memory> candidate{text_.get_allocator()};
    bool quoted = false;
    bool escaped = false;
    for (std::size_t index = 0; index < text_.size(); ++index) {
      const char byte = text_[index];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (byte == '\\') {
          escaped = true;
        } else if (byte == '"') {
          quoted = false;
        }

        continue;
      }
      if (byte == '"') {
        quoted = true;
      } else if (byte == '{' || byte == '[') {
        ++depth;
      } else if (byte == '}' || byte == ']') {
        if (depth == 0) {
          break;
        }
        if (--depth == 0) {
          if (completeMember(member_start, index, candidate)) {
            complete = index;
          }

          break;
        }
      } else if (byte == ',' && depth == 1) {
        if (!completeMember(member_start, index, candidate)) {
          break;
        }

        complete = index;
        member_start = index + 1;
      }
    }

    if (complete == 0) {
      text_ = "{}";
    } else {
      text_.resize(complete);
      text_.push_back('}');
    }
  }

  bool completeMember(std::size_t start, std::size_t end, String<Memory> &candidate) {
    if (std::string_view{text_.data() + start, end - start}.find_first_not_of(" \r\n\t") == std::string_view::npos) {
      return false;
    }

    candidate = "{";
    candidate.append(text_.data() + start, end - start);
    candidate += "}";
    try {
      JsonValue::parse(candidate);
      validateUnicodeEscapes(candidate.get_allocator().memory(), candidate);
      return true;
    } catch (const RequestError &) {
      return false;
    }
  }

  String<Memory> text_;
  std::uint64_t received_ = 0;
};

template <Allocator Memory>
Input(Memory &memory) -> Input<Memory>;

}
