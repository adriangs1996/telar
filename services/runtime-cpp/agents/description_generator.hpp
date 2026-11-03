#pragma once

#include "description.hpp"
#include "telar_platform/command_output.hpp"
#include "telar_platform/trace.hpp"

namespace telar::runtime {

template <Allocator Memory>
class DescriptionGenerator {
public:
  using Request = DescriptionRequest;
  using Result = DescriptionResult;

  explicit DescriptionGenerator(Memory &memory, const DescriptionOptions &options)
      : memory_(memory),
        options_(options),
        output_(memory, maximum_output_bytes, &stopping_) {}

  Result observe(const Request &request) noexcept {
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

  void stop() noexcept {
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
  CommandOutput<Memory> output_;
};

}
