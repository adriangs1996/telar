module telar.gui.transport.runtime_link;

import std;
import telar.base.text.utf8;

namespace telar::gui {

  template <Allocator Memory>
  FrameStream<Memory>::FrameStream(Memory& memory)
      : payload_(AllocatorRef<Byte, Memory>{memory}) {}

  template <Allocator Memory>
  void FrameStream<Memory>::reset() noexcept {
    payload_.clear();
    prefix_used_ = 0;
    expected_ = 0;
  }

  template <Allocator Memory>
  void FrameStream<Memory>::setMaximum(std::size_t maximum) {
    if (maximum == 0 || maximum > max_payload_size) {
      throw std::invalid_argument{"Invalid runtime receive capacity"};
    }

    maximum_ = maximum;
  }

  template <Allocator Memory>
  std::optional<std::span<const Byte>> FrameStream<Memory>::next(std::span<const Byte>& input) {
    while (!input.empty()) {
      if (prefix_used_ < prefix_.size()) {
        const auto count = std::min(input.size(), prefix_.size() - prefix_used_);

        std::copy_n(input.begin(), count, prefix_.begin() + prefix_used_);
        prefix_used_ += count;
        input = input.subspan(count);

        if (prefix_used_ != prefix_.size()) {
          return std::nullopt;
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

        return std::span<const Byte>{payload_};
      }
    }

    return std::nullopt;
  }

  template class FrameStream<telar::Memory>;
  template class FrameStream<telar::ConcurrentMemory>;

  bool RuntimeProtocol::supports(const SchemaId& schema) noexcept {
    return schema == handshake::schema_id || schema == cqp00003 || schema == cqp00002 || schema == schema87;
  }

  bool RuntimeProtocol::supports(const SchemaId& schema, ClientTag tag) noexcept {
    const bool current = tag == ClientTag::read_pane_rows || tag == ClientTag::search_pane_rows || tag == ClientTag::pane_command || tag == ClientTag::configure_shell_prompt;

    return supports(schema) && (schema != schema87 || tag != ClientTag::hold_tab) && (!current || readsRows(schema));
  }

  bool RuntimeProtocol::readsRows(const SchemaId& schema) noexcept {
    return schema == handshake::schema_id || schema == cqp00003;
  }

  std::optional<SchemaId> RuntimeProtocol::retry(std::span<const Byte> payload, const SchemaId& requested) {
    try {
      const auto response = HandshakeCodec::decodeResponse(payload);
      const auto* rejected = std::get_if<ServerReject>(&response);
      if (rejected != nullptr && rejected->reason == HandshakeRejectReason::incompatible_schema && rejected->expected_schema != requested && supports(requested) && supports(rejected->expected_schema)) {
        return rejected->expected_schema;
      }
    } catch (const EncodingError&) {
      return std::nullopt;
    }

    return std::nullopt;
  }

  RuntimeHandshake::Result RuntimeHandshake::inspect(std::span<const Byte> payload, const SchemaId& requested) {
    if (!RuntimeProtocol::supports(requested)) {
      return failure(MachineError::endpoint_unavailable, "InvalidServerSelection");
    }

    if (payload.size() > HandshakeCodec::max_message_size) {
      return failure(MachineError::endpoint_unavailable, "BufferTooSmall");
    }

    try {
      const auto response = HandshakeCodec::decodeResponse(payload);
      if (const auto* accepted = std::get_if<ServerAccept>(&response)) {
        return accepted->schema == requested ? Result{} : failure(MachineError::endpoint_unavailable, "InvalidServerSelection");
      }

      return rejected(std::get<ServerReject>(response));
    } catch (const EncodingError& error) {
      return failure(MachineError::endpoint_unavailable, decodingFailure(error.what()));
    }
  }

  RuntimeHandshake::Result RuntimeHandshake::failure(MachineError error, std::string_view message) {
    Result result{.error = error};

    result.detail.append(message);

    return result;
  }

  RuntimeHandshake::Result RuntimeHandshake::rejected(const ServerReject& reply) {
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

  std::string_view RuntimeHandshake::decodingFailure(std::string_view message) noexcept {
    constexpr std::array names{
        std::pair{"Invalid handshake response length", "InvalidLength"},
        std::pair{"Invalid handshake magic", "InvalidMagic"},
        std::pair{"Unknown handshake message tag", "UnknownMessage"},
        std::pair{"Unexpected handshake response", "UnexpectedMessage"},
        std::pair{"Unknown handshake rejection reason", "UnknownRejectReason"},
    };

    for (const auto& [native, original] : names) {
      if (message == native) {
        return original;
      }
    }

    return message;
  }

  void RuntimeLink::name(std::string_view text) {
    target_storage.truncate(0);
    target_storage.append(validPrefix(text, target_bytes));
  }

  std::string_view RuntimeLink::target() const noexcept {
    return target_storage.view();
  }

  void RuntimeLink::fail(std::string_view text) {
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

  std::optional<std::string_view> RuntimeLink::failure() const noexcept {
    return failure_storage.view().empty() ? std::nullopt : std::optional{failure_storage.view()};
  }

  void RuntimeLink::clearFailure() noexcept {
    failure_storage = {};
    setup_repairs = false;
  }

  void RuntimeLink::start(std::string_view text) {
    name(text);
    phase = MachinePhase::connecting;
    clearFailure();
  }

  void RuntimeLink::adopt(std::uint64_t now_ns) {
    connected_at_ns = now_ns;
    phase = MachinePhase::connected;
    if (sessions != std::numeric_limits<std::uint32_t>::max()) {
      ++sessions;
    }

    clearFailure();
  }

  void RuntimeLink::lose(std::string_view text, std::uint64_t now_ns) {
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

  void RuntimeLink::connectionFailed(MachineError error, std::string_view text) {
    fail(text);
    setup_repairs = MachineConnectionPolicy::setupRepairs(error);
    phase = MachineConnectionPolicy::permanent(error) ? MachinePhase::failed : MachinePhase::lost;
  }

  bool RuntimeLink::retry() {
    if (phase != MachinePhase::lost) {
      return false;
    }

    phase = MachinePhase::connecting;
    if (attempt != std::numeric_limits<std::uint16_t>::max()) {
      ++attempt;
    }

    return true;
  }

  bool RuntimeLink::retryNow() {
    if (phase != MachinePhase::lost && phase != MachinePhase::failed) {
      return false;
    }

    phase = MachinePhase::connecting;
    attempt = 0;

    return true;
  }

  void RuntimeLink::stop() noexcept {
    phase = MachinePhase::stopped;
    clearFailure();
  }

  int RuntimeLink::retryDelayMilliseconds() const noexcept {
    const auto shift = std::min(static_cast<unsigned>(attempt), maximum_backoff_doublings);

    return static_cast<int>(std::min(std::uint64_t{first_retry_ms} << shift, std::uint64_t{longest_retry_ms}));
  }

  RuntimeLink::Headline RuntimeLink::headline() const {
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

  std::string_view RuntimeLink::validPrefix(std::string_view text, std::size_t capacity) noexcept {
    const auto prefix = runtime::utf8Prefix(text, capacity);

    return inspectUtf8(prefix) == Utf8Validation::valid ? prefix : std::string_view{};
  }

  RuntimeLink::Headline RuntimeLink::assemble(Label label) const {
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

}
