module;
#include "tbc/view.hpp"
#include "telar_platform/trace_macro.hpp"
#include <cstdio>
#include <cstdlib>
#include <new>
#include <unistd.h>

#include <cstddef>
#include <cstring>
#include <cstdint>


#include <cassert>
#include <cerrno>
#include <sys/types.h>
#include <limits.h>
#include <poll.h>
#include <sys/wait.h>


export module telar.runtime.agents.description_generator;

import std;

export import telar.runtime.terminal.osc_scanner;
export import telar.base.memory;


export import telar.platform;


export import telar.runtime.platform.process_probe;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: agents/description_capture.cppm
export {
namespace telar::runtime {

inline constexpr std::size_t description_query_capacity = 4096;
using DescriptionQuery = SensitiveText<description_query_capacity>;

class DescriptionCapture {
public:
  inline ~DescriptionCapture() {
    clear();
  }

  inline bool feed(std::span<const Byte> input) {
    if (submitted_) {
      return false;
    }

    for (const auto byte : input) {
      if (raw_.view().size() < description_query_capacity) {
        const char character = static_cast<char>(byte);
        raw_.append({&character, 1});
      }

      const auto event = scanner_.feed({&byte, 1});
      if (event.cancelled) {
        clear();
      } else if (event.submitted) {
        submitted_ = true;
        return true;
      }
    }

    return false;
  }

  inline void clear() noexcept {
    raw_.clear();
    scanner_.clearSensitive();
    submitted_ = false;
  }

  inline DescriptionQuery normalized() const {
    DescriptionQuery query;
    auto remaining = raw_.view();
    bool pasted = false;
    while (!remaining.empty()) {
      if (remaining.starts_with("\x1b[200~") || remaining.starts_with("\x1b[201~")) {
        pasted = remaining[4] == '0';
        remaining.remove_prefix(6);
        continue;
      }

      const auto byte = static_cast<unsigned char>(remaining.front());
      remaining.remove_prefix(1);
      if (byte == static_cast<Byte>(ControlByte::escape)) {
        skipEscape(remaining);
      } else if (byte == '\r' || byte == '\n') {
        if (!pasted) {
          break;
        }

        appendSpace(query);
      } else if (byte == ' ' || byte == '\t') {
        appendSpace(query);
      } else if (byte == static_cast<Byte>(ControlByte::backspace) || byte == static_cast<Byte>(ControlByte::delete_previous)) {
        removeScalar(query);
      } else if (byte == clear_line) {
        query.clear();
      } else if (byte == erase_word) {
        while (query.view().ends_with(' ')) {
          query.truncate(query.view().size() - 1);
        }

        while (!query.view().empty() && !query.view().ends_with(' ')) {
          removeScalar(query);
        }
      } else if (byte >= ' ') {
        const auto scalar = nextScalar(byte, remaining);
        validateUtf8(scalar);
        query.append(scalar);
        remaining.remove_prefix(scalar.size() - 1);
      }
    }

    if (query.view().ends_with(' ')) {
      query.truncate(query.view().size() - 1);
    }
    if (query.view().empty()) {
      throw EncodingError{"Empty agent description query"};
    }

    return query;
  }

private:
  static constexpr Byte clear_line = 0x15;
  static constexpr Byte erase_word = 0x17;

  inline static void skipEscape(std::string_view &remaining) noexcept {
    if (remaining.empty()) {
      return;
    }

    const bool sequence = remaining.front() == '[';
    remaining.remove_prefix(1);
    if (sequence) {
      while (!remaining.empty()) {
        const auto byte = static_cast<unsigned char>(remaining.front());
        remaining.remove_prefix(1);
        if (byte >= 0x40 && byte <= 0x7e) {
          break;
        }
      }
    }
  }

  inline static std::string_view nextScalar(unsigned char byte, std::string_view remaining) {
    const std::size_t length = byte < 0x80 ? 1 : byte < 0xe0 ? 2
                                             : byte < 0xf0   ? 3
                                                             : 4;
    if (remaining.size() < length - 1) {
      throw EncodingError{"Incomplete description query UTF-8"};
    }

    return {remaining.data() - 1, length};
  }

  inline static void appendSpace(DescriptionQuery &query) {
    if (!query.view().empty() && !query.view().ends_with(' ')) {
      query.append(" ");
    }
  }

  inline static void removeScalar(DescriptionQuery &query) noexcept {
    auto text = query.view();
    if (text.empty()) {
      return;
    }

    std::size_t length = text.size() - 1;
    while (length != 0 && (static_cast<unsigned char>(text[length]) & 0xc0) == 0x80) {
      --length;
    }

    query.truncate(length);
  }

  DescriptionQuery raw_;
  InputScanner scanner_;
  bool submitted_ = false;
};

}
}

// Interface: agents/description.cppm
export {
namespace telar::runtime {

enum class DescriptionPhase {
  waiting_query,
  waiting_work,
  queued,
  running,
  finished,
  failed
};

enum class DescriptionStatus {
  success,
  unavailable,
  timeout,
  invalid_output,
  failed
};

struct DescriptionOptions {
  std::span<const std::string_view> arguments;
  std::chrono::milliseconds timeout{15'000};
};

struct DescriptionIdentity {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  std::array<Byte, 16> session{};
  std::uint64_t revision = 0;

  bool operator==(const DescriptionIdentity &) const = default;
};

struct DescriptionRequest {
  DescriptionIdentity identity;
  DescriptionQuery query{};
};

struct DescriptionResult {
  DescriptionIdentity identity;
  DescriptionStatus status = DescriptionStatus::failed;
  FixedText<96> title{};
};

inline FixedText<96> normalizeDescriptionTitle(std::string_view output) {
  constexpr std::string_view whitespace = " \t\r\n";
  const auto first = output.find_first_not_of(whitespace);
  if (first == std::string_view::npos) {
    throw EncodingError{"Empty generated title"};
  }

  output = output.substr(first, output.find_last_not_of(whitespace) - first + 1);
  if (output.size() >= 2 && (output.front() == '"' || output.front() == '\'') && output.back() == output.front()) {
    output.remove_prefix(1);
    output.remove_suffix(1);
    const auto first_character = output.find_first_not_of(" \t");
    output = first_character == std::string_view::npos ? std::string_view{} : output.substr(first_character, output.find_last_not_of(" \t") - first_character + 1);
  }

  if (output.empty() || output.size() > 96 || std::ranges::any_of(output, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; })) {
    throw EncodingError{"Invalid generated title"};
  }

  validateUtf8(output);
  FixedText<96> title;
  title.assign(output);
  return title;
}

}
}

// Interface: agents/description_generator.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class DescriptionGenerator {
public:
  using Request = DescriptionRequest;
  using Result = DescriptionResult;

  inline explicit DescriptionGenerator(Memory &memory, const DescriptionOptions &options)
      : memory_(memory),
        options_(options),
        output_(memory, maximum_output_bytes, &stopping_) {}

  inline Result observe(const Request &request) noexcept {
    TELAR_TRACE("agents.generateDescription");
    Result result{.identity = request.identity};
    if (options_.arguments.empty()) {
      result.status = DescriptionStatus::unavailable;
      return result;
    }

    try {
      Command command{memory_, Launch{.cwd = "/", .arguments = options_.arguments}, CommandPurpose::configured_helper};
      const std::array input{prompt_prefix, request.query.view(), std::string_view{"\n"}};
      const int status = output_.runWithInput(command, std::chrono::steady_clock::now() + options_.timeout, input);
      if (output_.truncated()) {
        result.status = DescriptionStatus::invalid_output;
      } else if (status == 0) {
        result.title = normalizeDescriptionTitle(output_.text());
        result.status = DescriptionStatus::success;
      }
    } catch (const EncodingError &) {
      result.status = DescriptionStatus::invalid_output;
    } catch (const RequestError &error) {
      result.status = error.code() == FailureCode::resource_limit ? DescriptionStatus::timeout : DescriptionStatus::failed;
    } catch (const SystemError &error) {
      result.status = error.code() == ENOENT ? DescriptionStatus::unavailable : DescriptionStatus::failed;
    } catch (const std::exception &) {
    }

    return result;
  }

  inline void stop() noexcept {
    stopping_.store(true, std::memory_order_relaxed);
  }

private:
  static constexpr std::size_t maximum_output_bytes = 512;
  static constexpr std::string_view prompt_prefix =
      "Create a short session title for the user request below. "
      "Return exactly one plain-text line, no quotes, labels, markdown, or explanation. "
      "Use at most 24 display characters. Do not execute tools.\n\nUser request:\n";

  Memory &memory_;
  DescriptionOptions options_;
  std::atomic<bool> stopping_{false};
  // Watches stopping_.
  tbc::view<CommandOutput<Memory>, tbc::lt::self> output_;
};

}
}

// Interface: agents/reporter_state.cppm
export {
namespace telar::runtime {

struct ReporterIdentity {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  AgentProvider provider = AgentProvider::unknown;
};

struct RejectedReporter {
  pid_t group = 0;
  pid_t agent = 0;
  pid_t process = 0;
  bool operator==(const RejectedReporter &) const = default;
};

template <Allocator Memory>
struct DeferredReport {
  inline explicit DeferredReport(Memory &memory)
      : payload(AllocatorRef<Byte, Memory>{memory}) {}

  inline bool rechecked(std::uint32_t completed) const noexcept {
    return std::bit_cast<std::int32_t>(completed - required_recheck) >= 0;
  }

  inline ObservationTime reportTime() const noexcept {
    return answering ? observed : ObservationTime::now();
  }

  Vector<Byte, Memory> payload;
  ReporterIdentity reporter;
  ObservationTime observed;
  std::uint64_t sequence = 0;
  std::uint32_t required_recheck = 0;
  bool pending = false;
  bool answering = false;
  bool answer_rechecked = false;
};

}
}
