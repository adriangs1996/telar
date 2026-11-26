module;

// The session's link with its runtime: the frames of its stream, the handshake that opens it,
// the schemas it speaks and the state of the connection a window shows.
export module telar.gui.application:transport;

import std;

import telar.client;

import telar.gui.foundation.text;

import telar.gui.features.machines;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: transport/frame_stream.cppm
export {
  namespace telar::gui::application {

    template <Allocator Memory>
    class FrameStream {
    public:
      explicit FrameStream(Memory& memory);

      ~FrameStream() = default;

      FrameStream(const FrameStream&) = delete;
      FrameStream& operator=(const FrameStream&) = delete;
      FrameStream(FrameStream&&) = delete;
      FrameStream& operator=(FrameStream&&) = delete;

      void reset() noexcept;

      void setMaximum(std::size_t maximum);

      // Generic over the caller's consumer, which takes each complete frame in turn.
      template <typename Consumer>
        requires std::invocable<Consumer&, std::span<const Byte>>
      [[tbc::generic]] void feed(std::span<const Byte> input, Consumer& consume) {
        while (const auto frame = next(input)) {
          if (!consumeFrame(consume, *frame)) {
            return;
          }
        }
      }

    private:
      // Takes bytes from input until a frame completes, and returns that frame's payload; nothing
      // once input runs out first. The payload stays valid until the next call.
      [[nodiscard]] ds::Option<std::span<const Byte>> next(std::span<const Byte>& input);

      template <typename Consumer>
        requires std::invocable<Consumer&, std::span<const Byte>>
      [[nodiscard]] [[tbc::generic]] static bool consumeFrame(Consumer& consume, std::span<const Byte> frame) {
        if constexpr (std::same_as<std::invoke_result_t<Consumer&, std::span<const Byte>>, bool>) {
          return consume(frame);
        } else {
          consume(frame);

          return true;
        }
      }

      ds::Vec<Byte, Memory> payload_;
      ds::Array<Byte, frame_prefix_size> prefix_{};
      std::size_t prefix_used_ = 0;
      std::size_t expected_ = 0;
      std::size_t maximum_ = max_payload_size;
    };

    extern template class FrameStream<telar::Memory>;
    extern template class FrameStream<telar::ConcurrentMemory>;

  }
}

// Interface: transport/runtime_protocol.cppm
export {
  namespace telar::gui::application {

    struct RuntimeProtocol {
      // The window speaks every dialect of handshake::Dialect: with an older runtime it sends only the
      // requests that dialect has (handshake::speaks).
      [[nodiscard]] static bool supports(const SchemaId& schema) noexcept;

      [[nodiscard]] static bool supports(const SchemaId& schema, ClientTag tag) noexcept;

      [[nodiscard]] static ds::Option<SchemaId> retry(std::span<const Byte> payload, const SchemaId& requested);
    };

  }
}

// Interface: transport/runtime_handshake.cppm
export {
  namespace telar::gui::application {

    struct RuntimeHandshake {
      static constexpr std::size_t detail_bytes = 256;
      using Detail = BoundedText<detail_bytes>;

      struct Result {
        ds::Option<features::machines::MachineError> error;
        Detail detail{};
      };

      [[nodiscard]] static Result inspect(std::span<const Byte> payload, const SchemaId& requested = handshake::schema_id);

    private:
      [[nodiscard]] static Result failure(features::machines::MachineError error, std::string_view message);

      [[nodiscard]] static Result rejected(const ServerReject& reply);

      [[nodiscard]] static std::string_view decodingFailure(std::string_view message) noexcept;
    };

  }
}

// Interface: transport/runtime_link.cppm
export {
  namespace telar::gui::application {

    struct RuntimeLink {
      static constexpr std::size_t failure_bytes = 256;
      static constexpr std::size_t target_bytes = 255;
      static constexpr std::size_t headline_bytes = 320;
      static constexpr int first_retry_ms = 500;
      static constexpr int longest_retry_ms = 30000;
      static constexpr unsigned maximum_backoff_doublings = 16;
      static constexpr auto healthy_after_ns = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::seconds{60}).count());
      using Headline = BoundedText<headline_bytes>;

      features::machines::MachinePhase phase = features::machines::MachinePhase::connecting;
      std::uint16_t attempt = 0;
      std::uint32_t sessions = 0;
      bool setup_repairs = false;
      std::uint64_t connected_at_ns = 0;
      BoundedText<failure_bytes> failure_storage;
      BoundedText<target_bytes> target_storage;

      void name(std::string_view text);

      [[nodiscard]] std::string_view target() const noexcept;

      void fail(std::string_view text);

      [[nodiscard]] ds::Option<std::string_view> failure() const noexcept;

      void clearFailure() noexcept;

      void start(std::string_view text);

      void adopt(std::uint64_t now_ns);

      void lose(std::string_view text, std::uint64_t now_ns);

      void connectionFailed(features::machines::MachineError error, std::string_view text);

      bool retry();

      bool retryNow();

      void stop() noexcept;

      [[nodiscard]] int retryDelayMilliseconds() const noexcept;

      [[nodiscard]] Headline headline() const;

    private:
      enum class ControlByte : unsigned char {
        delete_character = 0x7f,
      };

      [[nodiscard]] static std::string_view validPrefix(std::string_view text, std::size_t capacity) noexcept;

      struct Label {
        std::string_view prefix;
        std::string_view suffix;
        std::string_view fallback;
      };

      [[nodiscard]] Headline assemble(Label label) const;
    };

  }
}
