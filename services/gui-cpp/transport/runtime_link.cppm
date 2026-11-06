module;

#include "../core/memory.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include <concepts>
#include <cstddef>
#include <stdexcept>
#include <type_traits>


#include <array>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <optional>


#include <cstdint>
#include <charconv>
#include <cstring>
#include <string_view>
#include <system_error>
#include <utility>


#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <chrono>
#include <limits>

export module telar.gui.transport.runtime_link;

export import telar.client;


export import telar.gui.machines.discovery;

export import telar.gui.text.json_unsigned_integer;


export import telar.gui.machines.picker;

// Interface: transport/frame_stream.cppm
export {
namespace telar::gui {

template <Allocator Memory>
class FrameStream {
public:
  inline explicit FrameStream(Memory &memory)
      : payload_(AllocatorRef<Byte, Memory>{memory}) {}

  ~FrameStream() = default;

  FrameStream(const FrameStream &) = delete;
  FrameStream &operator=(const FrameStream &) = delete;
  FrameStream(FrameStream &&) = delete;
  FrameStream &operator=(FrameStream &&) = delete;

  inline void reset() noexcept {
    payload_.clear();
    prefix_used_ = 0;
    expected_ = 0;
  }

  inline void setMaximum(std::size_t maximum) {
    if (maximum == 0 || maximum > max_payload_size) {
      throw std::invalid_argument{"Invalid runtime receive capacity"};
    }

    maximum_ = maximum;
  }

  template <typename Consumer>
    requires std::invocable<Consumer &, std::span<const Byte>>
  void feed(std::span<const Byte> input, Consumer &consume) {
    while (!input.empty()) {
      if (prefix_used_ < prefix_.size()) {
        const auto count = std::min(input.size(), prefix_.size() - prefix_used_);
        std::copy_n(input.begin(), count, prefix_.begin() + prefix_used_);
        prefix_used_ += count;
        input = input.subspan(count);

        if (prefix_used_ != prefix_.size()) {
          return;
        }

        std::span<const Byte> prefix{prefix_};
        expected_ = u32::decode(prefix);
        if (expected_ == 0) {
          throw EncodingError{"InvalidLength"};
        }

        if (expected_ > max_payload_size) {
          throw EncodingError{"FrameTooLarge"};
        }

        if (expected_ > maximum_) {
          throw EncodingError{"BufferTooSmall"};
        }

        payload_.clear();
        payload_.reserve(expected_);
      }

      const auto count = std::min(input.size(), expected_ - payload_.size());
      payload_.insert(payload_.end(), input.begin(), input.begin() + count);
      input = input.subspan(count);

      if (payload_.size() == expected_) {
        prefix_used_ = 0;
        if (!consumeFrame(consume)) {
          return;
        }
      }
    }
  }

private:
  template <typename Consumer>
    requires std::invocable<Consumer &, std::span<const Byte>>
  [[nodiscard]] bool consumeFrame(Consumer &consume) {
    if constexpr (std::same_as<std::invoke_result_t<Consumer &, std::span<const Byte>>, bool>) {
      return consume(std::span<const Byte>{payload_});
    } else {
      consume(std::span<const Byte>{payload_});

      return true;
    }
  }

  Vector<Byte, Memory> payload_;
  std::array<Byte, frame_prefix_size> prefix_{};
  std::size_t prefix_used_ = 0;
  std::size_t expected_ = 0;
  std::size_t maximum_ = max_payload_size;
};

}
}

// Interface: transport/runtime_protocol.cppm
export {
namespace telar::gui {

struct RuntimeProtocol {
  // Schema 88 only adds hold_tab (0x47); existing schema 87 message layouts are unchanged.
  static constexpr SchemaId schema87{'8', '7', '6', 'b', '4', '8', '0', 'd'};

  [[nodiscard]] inline static bool supports(const SchemaId &schema) noexcept {
    return schema == handshake::schema_id || schema == schema87;
  }

  [[nodiscard]] inline static bool supports(const SchemaId &schema, ClientTag tag) noexcept {
    return supports(schema) && (schema != schema87 || tag != ClientTag::hold_tab);
  }

  [[nodiscard]] inline static std::optional<SchemaId> retry(std::span<const Byte> payload, const SchemaId &requested) {
    try {
      const auto response = HandshakeCodec::decodeResponse(payload);
      const auto *rejected = std::get_if<ServerReject>(&response);
      if (rejected != nullptr && rejected->reason == HandshakeRejectReason::incompatible_schema && rejected->expected_schema != requested && supports(requested) && supports(rejected->expected_schema)) {
        return rejected->expected_schema;
      }
    } catch (const EncodingError &) {
      return std::nullopt;
    }

    return std::nullopt;
  }
};

}
}

// Interface: transport/runtime_handshake.cppm
export {
namespace telar::gui {

struct RuntimeHandshake {
  static constexpr std::size_t detail_bytes = 256;
  using Detail = BoundedText<detail_bytes>;

  struct Result {
    std::optional<MachineError> error;
    Detail detail{};
  };

  [[nodiscard]] inline static Result inspect(std::span<const Byte> payload, const SchemaId &requested = handshake::schema_id) {
    if (!RuntimeProtocol::supports(requested)) {
      return failure(MachineError::endpoint_unavailable, "InvalidServerSelection");
    }

    if (payload.size() > HandshakeCodec::max_message_size) {
      return failure(MachineError::endpoint_unavailable, "BufferTooSmall");
    }

    try {
      const auto response = HandshakeCodec::decodeResponse(payload);
      if (const auto *accepted = std::get_if<ServerAccept>(&response)) {
        return accepted->schema == requested ? Result{} : failure(MachineError::endpoint_unavailable, "InvalidServerSelection");
      }

      return rejected(std::get<ServerReject>(response));
    } catch (const EncodingError &error) {
      return failure(MachineError::endpoint_unavailable, decodingFailure(error.what()));
    }
  }

private:
  [[nodiscard]] inline static Result failure(MachineError error, std::string_view message) {
    Result result{.error = error};
    result.detail.append(message);

    return result;
  }

  [[nodiscard]] inline static Result rejected(const ServerReject &reply) {
    if (reply.reason == HandshakeRejectReason::client_limit_reached) {
      return failure(MachineError::endpoint_unavailable, "clients.max_clients: the runtime holds its limit of 32 clients (windows, CLI calls and agent hooks); close a window or retry once running commands finish");
    }

    Result result{.error = MachineError::incompatible_schema};
    result.detail.append("the runtime speaks wire schema ");
    result.detail.append(textView(std::span{reply.expected_schema}));
    result.detail.append("; this telar speaks ");
    result.detail.append(textView(std::span{handshake::schema_id}));
    result.detail.append(". Update telar on one side");

    return result;
  }

  [[nodiscard]] inline static std::string_view decodingFailure(std::string_view message) noexcept {
    constexpr std::array names{
        std::pair{"Invalid handshake response length", "InvalidLength"},
        std::pair{"Invalid handshake magic", "InvalidMagic"},
        std::pair{"Unknown handshake message tag", "UnknownMessage"},
        std::pair{"Unexpected handshake response", "UnexpectedMessage"},
        std::pair{"Unknown handshake rejection reason", "UnknownRejectReason"},
    };
    for (const auto &[native, original] : names) {
      if (message == native) {
        return original;
      }
    }

    return message;
  }
};

}
}

// Interface: transport/runtime_link.cppm
export {
namespace telar::gui {

struct RuntimeLink {
  static constexpr std::size_t failure_bytes = 256;
  static constexpr std::size_t target_bytes = 255;
  static constexpr std::size_t headline_bytes = 320;
  static constexpr int first_retry_ms = 500;
  static constexpr int longest_retry_ms = 30000;
  static constexpr unsigned maximum_backoff_doublings = 16;
  static constexpr auto healthy_after_ns = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::seconds{60}).count());
  using Headline = BoundedText<headline_bytes>;

  MachinePhase phase = MachinePhase::connecting;
  std::uint16_t attempt = 0;
  std::uint32_t sessions = 0;
  bool setup_repairs = false;
  std::uint64_t connected_at_ns = 0;
  BoundedText<failure_bytes> failure_storage;
  BoundedText<target_bytes> target_storage;

  inline void name(std::string_view text) {
    target_storage.truncate(0);
    target_storage.append(validPrefix(text, target_bytes));
  }

  [[nodiscard]] inline std::string_view target() const noexcept {
    return target_storage.view();
  }

  inline void fail(std::string_view text) {
    failure_storage.truncate(0);
    const auto first = text.find_first_not_of(" \t\r\n");
    if (first == std::string_view::npos) {
      return;
    }

    const auto last = text.find_last_not_of(" \t\r\n");
    const auto kept = validPrefix(text.substr(first, last - first + 1), failure_bytes);
    std::array<char, failure_bytes> cleaned{};
    for (std::size_t index = 0; index < kept.size(); ++index) {
      const auto byte = static_cast<unsigned char>(kept[index]);
      cleaned[index] = byte < static_cast<unsigned char>(' ') || byte == static_cast<unsigned char>(ControlByte::delete_character) ? ' ' : kept[index];
    }

    failure_storage.append({cleaned.data(), kept.size()});
  }

  [[nodiscard]] inline std::optional<std::string_view> failure() const noexcept {
    return failure_storage.view().empty() ? std::nullopt : std::optional{failure_storage.view()};
  }

  inline void clearFailure() noexcept {
    failure_storage = {};
    setup_repairs = false;
  }

  inline void start(std::string_view text) {
    name(text);
    phase = MachinePhase::connecting;
    clearFailure();
  }

  inline void adopt(std::uint64_t now_ns) {
    connected_at_ns = now_ns;
    phase = MachinePhase::connected;
    if (sessions != std::numeric_limits<std::uint32_t>::max()) {
      ++sessions;
    }

    clearFailure();
  }

  inline void lose(std::string_view text, std::uint64_t now_ns) {
    if (phase != MachinePhase::connected) {
      return;
    }

    if (now_ns >= connected_at_ns && now_ns - connected_at_ns >= healthy_after_ns) {
      attempt = 0;
    }

    fail(text);
    setup_repairs = false;
    phase = MachinePhase::lost;
  }

  inline void connectionFailed(MachineError error, std::string_view text) {
    fail(text);
    setup_repairs = MachineConnectionPolicy::setupRepairs(error);
    phase = MachineConnectionPolicy::permanent(error) ? MachinePhase::failed : MachinePhase::lost;
  }

  inline bool retry() {
    if (phase != MachinePhase::lost) {
      return false;
    }

    phase = MachinePhase::connecting;
    if (attempt != std::numeric_limits<std::uint16_t>::max()) {
      ++attempt;
    }

    return true;
  }

  inline bool retryNow() {
    if (phase != MachinePhase::lost && phase != MachinePhase::failed) {
      return false;
    }

    phase = MachinePhase::connecting;
    attempt = 0;

    return true;
  }

  inline void stop() noexcept {
    phase = MachinePhase::stopped;
    clearFailure();
  }

  [[nodiscard]] inline int retryDelayMilliseconds() const noexcept {
    const auto shift = std::min(static_cast<unsigned>(attempt), maximum_backoff_doublings);
    return static_cast<int>(std::min(std::uint64_t{first_retry_ms} << shift, std::uint64_t{longest_retry_ms}));
  }

  [[nodiscard]] inline Headline headline() const {
    switch (phase) {
    case MachinePhase::connected:
      return {};
    case MachinePhase::connecting:
      if (sessions == 0 && attempt == 0) {
        return assemble({.prefix = "Connecting to ", .suffix = "…", .fallback = "Connecting…"});
      }

      {
        auto result = assemble({.prefix = "Reconnecting to ", .suffix = "", .fallback = "Reconnecting…"});
        result.append(" (attempt ");
        result.appendDecimal(static_cast<std::uint32_t>(attempt) + 1);
        result.append(")…");

        return result;
      }
    case MachinePhase::lost:
      return assemble({.prefix = "", .suffix = " is unreachable; trying again shortly", .fallback = "The runtime is unreachable"});
    case MachinePhase::failed:
      return setup_repairs ? assemble({.prefix = "", .suffix = " lacks this telar build; choose it in the machine list to set it up", .fallback = "This machine lacks this telar build"}) : assemble({.prefix = "Cannot connect to ", .suffix = "; retry it from the machine list", .fallback = "Cannot connect to the runtime"});
    case MachinePhase::stopped:
      return assemble({.prefix = "", .suffix = " is disabled", .fallback = "The machine is disabled"});
    }

    return {};
  }

private:
  enum class ControlByte : unsigned char {
    delete_character = 0x7f,
  };

  [[nodiscard]] inline static std::string_view validPrefix(std::string_view text, std::size_t capacity) noexcept {
    const auto prefix = runtime::utf8Prefix(text, capacity);

    return inspectUtf8(prefix) == Utf8Validation::valid ? prefix : std::string_view{};
  }

  struct Label {
    std::string_view prefix;
    std::string_view suffix;
    std::string_view fallback;
  };

  [[nodiscard]] inline Headline assemble(Label label) const {
    Headline result;
    if (label.prefix.size() + target().size() + label.suffix.size() > headline_bytes) {
      result.append(label.fallback);
    } else {
      result.append(label.prefix);
      result.append(target());
      result.append(label.suffix);
    }

    return result;
  }
};

}
}
