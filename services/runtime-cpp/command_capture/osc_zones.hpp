#pragma once

#include "../diagnostics/command_capture.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_platform/observation_time.hpp"
#include <charconv>
#include <cstring>
#include <limits>
#include <optional>
#include <utility>

namespace telar::runtime {

struct CommandCompletion {
  ObservationTime time;
  std::optional<int> exit_code;
  HistoryStatus status = HistoryStatus::completed;
};

template <typename Sink>
concept CommandCompletionSink = requires(Sink &sink, CommandCompletion completion) {
  { sink.complete(completion) } -> std::same_as<void>;
};

class CommandZones {
public:
  explicit CommandZones(std::string_view directory) {
    setDirectory(directory);
  }

  template <CommandCompletionSink Sink>
  void feed(std::span<const Byte> bytes, ObservationTime time, Sink &sink) {
    for (std::size_t offset = 0; offset < bytes.size(); ++offset) {
      if (parser_ == ParserState::ground) {
        const auto *next = static_cast<const Byte *>(std::memchr(bytes.data() + offset, escape, bytes.size() - offset));
        if (next == nullptr) {
          break;
        }

        offset = static_cast<std::size_t>(next - bytes.data());
      }

      const auto byte = bytes[offset];
      switch (parser_) {
      case ParserState::ground:
        if (byte == escape) {
          parser_ = ParserState::escape;
        }
        break;
      case ParserState::escape:
        parser_ = byte == ']' ? ParserState::osc : ParserState::ground;
        if (parser_ == ParserState::osc) {
          TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.osc_started));
          length_ = 0;
          overflow_ = false;
        }
        break;
      case ParserState::osc:
        if (byte == bell) {
          parser_ = ParserState::ground;
          finishSequence(time, sink);
        } else if (byte == escape) {
          parser_ = ParserState::osc_escape;
        } else if (length_ < bytes_.size()) {
          bytes_[length_++] = static_cast<char>(byte);
        } else {
          overflow_ = true;
        }
        break;
      case ParserState::osc_escape:
        parser_ = byte == escape ? ParserState::escape : ParserState::ground;
        if (byte == '\\') {
          finishSequence(time, sink);
        }
        break;
      }
    }
  }

  void input(std::span<const Byte> bytes) noexcept {
    if (zone_ == Zone::input && !bytes.empty()) {
      has_input_ = true;
    }
  }

  bool editing() const noexcept {
    return markers_ready_ && zone_ == Zone::input;
  }

  bool markersReady() const noexcept {
    return markers_ready_;
  }

  void setDirectory(std::string_view directory) {
    directory_.assign(directory.substr(0, directory_capacity));
  }

  std::string_view directory() const noexcept {
    return directory_.view();
  }

#if TELAR_DIAGNOSTICS
  diagnostics::CommandCaptureCounters takeMetrics() noexcept {
    return std::exchange(metrics_, {});
  }
#endif

private:
  enum class ParserState {
    ground,
    escape,
    osc,
    osc_escape
  };
  enum class Zone {
    unknown,
    prompt,
    input,
    output
  };
  static constexpr Byte escape = 0x1b;
  static constexpr Byte bell = 0x07;
  static constexpr std::size_t directory_capacity = 4096;

  template <CommandCompletionSink Sink>
  void finishSequence(ObservationTime time, Sink &sink) {
    TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.osc_finished));
    if (overflow_) {
      return;
    }

    const std::string_view sequence{bytes_.data(), length_};
    const auto separator = sequence.find(';');
    const auto code = sequence.substr(0, separator);
    const auto body = separator == std::string_view::npos ? std::string_view{} : sequence.substr(separator + 1);
    if (code == "133") {
      semantic(body, time, sink);
    } else if (code == "7") {
      directoryReport(body);
    }
  }

  template <CommandCompletionSink Sink>
  void semantic(std::string_view body, ObservationTime time, Sink &sink) {
    const auto separator = body.find(';');
    const auto action = body.substr(0, separator);
    const auto options = separator == std::string_view::npos ? std::string_view{} : body.substr(separator + 1);
    if (action == "A" || action == "P") {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.prompt_markers));
      if (running_) {
        sink.complete({time, std::nullopt, HistoryStatus::interrupted});
      }

      running_ = false;
      has_input_ = false;
      zone_ = Zone::prompt;
    } else if (action == "B") {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.input_markers));
      markers_ready_ |= zone_ == Zone::prompt;
      has_input_ = false;
      zone_ = Zone::input;
    } else if (action == "C") {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.output_markers));
      zone_ = Zone::output;
      running_ = has_input_;
    } else if (action == "D") {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.finished_markers));
      zone_ = Zone::prompt;
      if (running_) {
        sink.complete({time, parseExitCode(options), HistoryStatus::completed});
        running_ = false;
        has_input_ = false;
      }
    }
  }

  static std::optional<int> parseExitCode(std::string_view options) noexcept {
    auto value = options.substr(0, options.find(';'));
    const bool negative = value.starts_with('-');
    if (negative || value.starts_with('+')) {
      value.remove_prefix(1);
    }
    if (value.empty() || value.front() == '_' || value.back() == '_') {
      return std::nullopt;
    }

    constexpr std::uint32_t decimal_base = 10;
    const auto limit = static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max()) + negative;
    std::uint32_t magnitude = 0;
    for (const auto byte : value) {
      if (byte == '_') {
        continue;
      }
      if (byte < '0' || byte > '9') {
        return std::nullopt;
      }
      const auto digit = static_cast<std::uint32_t>(byte - '0');
      if (magnitude > (limit - digit) / decimal_base) {
        return std::nullopt;
      }
      magnitude = magnitude * decimal_base + digit;
    }
    const auto signed_value = negative ? -static_cast<std::int64_t>(magnitude) : magnitude;
    return static_cast<int>(signed_value);
  }

  void directoryReport(std::string_view body) {
    for (const auto prefix : {std::string_view{"file://"}, std::string_view{"kitty-shell-cwd://"}}) {
      if (!body.starts_with(prefix)) {
        continue;
      }

      const auto remainder = body.substr(prefix.size());
      const auto slash = remainder.find('/');
      if (slash == std::string_view::npos) {
        return;
      }

      const auto encoded = remainder.substr(slash);
      std::array<char, directory_capacity> decoded;
      std::size_t count = 0;
      for (std::size_t index = 0; index < encoded.size(); ++index) {
        if (count == decoded.size()) {
          return;
        }

        if (encoded[index] == '%') {
          if (encoded.size() - index < 3) {
            return;
          }

          unsigned byte = 0;
          const auto converted = std::from_chars(encoded.data() + index + 1, encoded.data() + index + 3, byte, 16);
          if (converted.ec != std::errc{} || converted.ptr != encoded.data() + index + 3) {
            return;
          }

          decoded[count++] = static_cast<char>(byte);
          index += 2;
        } else {
          decoded[count++] = encoded[index];
        }
      }

      directory_.assign({decoded.data(), count});
      return;
    }
  }

#if TELAR_DIAGNOSTICS
  diagnostics::CommandCaptureCounters metrics_;
#endif
  ParserState parser_ = ParserState::ground;
  Zone zone_ = Zone::unknown;
  std::array<char, 8 * 1024> bytes_{};
  std::size_t length_ = 0;
  bool overflow_ = false;
  bool markers_ready_ = false;
  bool has_input_ = false;
  bool running_ = false;
  FixedText<directory_capacity> directory_;
};

}
