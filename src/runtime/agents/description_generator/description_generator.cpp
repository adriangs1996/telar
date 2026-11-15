module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.agents.description_generator;

import std;
import telar.sys.posix;
import telar.tbc;
import telar.base.text;
import telar.platform.error;
import telar.platform.primitives;

namespace telar::runtime {

  DescriptionCapture::~DescriptionCapture() {
    clear();
  }

  bool DescriptionCapture::feed(std::span<const Byte> input) {
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

  void DescriptionCapture::clear() noexcept {
    raw_.clear();
    scanner_.clearSensitive();
    submitted_ = false;
  }

  DescriptionQuery DescriptionCapture::normalized() const {
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

  void DescriptionCapture::skipEscape(std::string_view& remaining) noexcept {
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

  std::string_view DescriptionCapture::nextScalar(unsigned char byte, std::string_view remaining) {
    const std::size_t length = byte < 0x80 ? 1 : byte < 0xe0 ? 2
                                             : byte < 0xf0   ? 3
                                                             : 4;
    if (remaining.size() < length - 1) {
      throw EncodingError{"Incomplete description query UTF-8"};
    }

    return {remaining.data() - 1, length};
  }

  void DescriptionCapture::appendSpace(DescriptionQuery& query) {
    if (!query.view().empty() && !query.view().ends_with(' ')) {
      query.append(" ");
    }
  }

  void DescriptionCapture::removeScalar(DescriptionQuery& query) noexcept {
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

  FixedText<96> normalizeDescriptionTitle(std::string_view output) {
    output = trimText(output, " \t\r\n");
    if (output.empty()) {
      throw EncodingError{"Empty generated title"};
    }

    if (output.size() >= 2 && (output.front() == '"' || output.front() == '\'') && output.back() == output.front()) {
      output.remove_prefix(1);
      output.remove_suffix(1);
      output = trimText(output, " \t");
    }

    if (output.empty() || output.size() > 96 || std::ranges::any_of(output, [](unsigned char byte) {
          return byte < 0x20 || byte == 0x7f;
        })) {
      throw EncodingError{"Invalid generated title"};
    }

    validateUtf8(output);
    FixedText<96> title;

    title.assign(output);
    return title;
  }

  template <Allocator Memory>
  DescriptionGenerator<Memory>::DescriptionGenerator(Memory& memory, const DescriptionOptions& options)
      : memory_(memory),
        options_(options),
        output_(memory, maximum_output_bytes, &stopping_) {}

  template <Allocator Memory>
  auto DescriptionGenerator<Memory>::observe(const Request& request) noexcept -> Result {
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
    } catch (const EncodingError&) {
      result.status = DescriptionStatus::invalid_output;
    } catch (const RequestError& error) {
      result.status = error.code() == FailureCode::resource_limit ? DescriptionStatus::timeout : DescriptionStatus::failed;
    } catch (const SystemError& error) {
      result.status = error.code() == ENOENT ? DescriptionStatus::unavailable : DescriptionStatus::failed;
    } catch (const std::exception&) {
    }

    return result;
  }

  template <Allocator Memory>
  void DescriptionGenerator<Memory>::stop() noexcept {
    stopping_.store(true, std::memory_order_relaxed);
  }

  template class DescriptionGenerator<Memory>;
  template class DescriptionGenerator<ConcurrentMemory>;

  template <Allocator Memory>
  DeferredReport<Memory>::DeferredReport(Memory& memory)
      : payload(AllocatorRef<Byte, Memory>{memory}) {}

  template <Allocator Memory>
  bool DeferredReport<Memory>::rechecked(std::uint32_t completed) const noexcept {
    return std::bit_cast<std::int32_t>(completed - required_recheck) >= 0;
  }

  template <Allocator Memory>
  ObservationTime DeferredReport<Memory>::reportTime() const noexcept {
    return answering ? observed : ObservationTime::now();
  }

  template struct DeferredReport<ConcurrentMemory>;

}
