module;
#include "tbc/annotations.hpp"

export module telar.runtime.http.message;

import std;
import telar.native.zlib;
import telar.tbc;

import telar.runtime.http.content;

import telar.base.memory.allocators;
import telar.base.memory.sensitive;

import telar.runtime.vocabulary.frames;

import telar.runtime.http1.head;
import telar.base.text;
import telar.base.text.utf8;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: http/content_codec.cppm
export {
  namespace telar::runtime {

    // Editing requires complete, validated entities. Observation's prefix decoders are deliberately looser.
    template <Allocator Memory>
    class HttpContentCodec {
      struct Flate {
        Flate(Memory& upstream, bool encode, int window);

        ~Flate();

        Flate(const Flate&) = delete;
        Flate& operator=(const Flate&) = delete;
        Flate(Flate&&) = delete;
        Flate& operator=(Flate&&) = delete;

        static constexpr int memory_level = 8;
        DecoderMemory<Memory> memory;
        z_stream stream{};
        bool encoding;
      };

    public:
      // An entity in the coding asked for: storage of the allocator when a coding changed it, else the
      // input itself, which the caller keeps alive while it reads the result.
      struct Coded {
        tbc::val_a<ds::Option<DecodedBody<Memory>>> storage;
        std::span<const std::uint8_t> input;

        [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept;
      };

      // A body it produces is storage of the allocator, region `a`, not of the codec.
      explicit HttpContentCodec(tbc::mut_a<Memory> memory) noexcept;

      auto decode(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit) -> tbc::val_a<DecodedBody<Memory>>;

      auto encode(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit) -> tbc::val_a<DecodedBody<Memory>>;

      // As decode and encode, without copying an entity that only identity codings describe; the result
      // views `input` or the codec's allocator, region `a`.
      auto decodeView(tbc::val_a<std::span<const std::uint8_t>> input, std::string_view encoding, std::size_t limit) -> tbc::val_a<Coded>;

      auto encodeView(tbc::val_a<std::span<const std::uint8_t>> input, std::string_view encoding, std::size_t limit) -> tbc::val_a<Coded>;

    private:
      auto materialize(Coded coded, bool encode) -> tbc::val_a<DecodedBody<Memory>>;

      auto transform(tbc::val_a<std::span<const std::uint8_t>> entity, std::string_view encoding, std::size_t limit, bool encode) -> tbc::val_a<Coded>;

      auto one(std::span<const std::uint8_t> input, ContentCoding selected, std::size_t limit, bool encode) -> tbc::val_a<DecodedBody<Memory>>;

      auto flate(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, bool gzip, bool encode) -> std::size_t;

      auto brotli(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, bool encode) -> std::size_t;

      auto zstd(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, bool encode) -> std::size_t;

      static constexpr std::size_t maximum_bytes = std::size_t{16} * 1024 * 1024;
      static constexpr std::size_t coding_overhead_bytes = std::size_t{64} * 1024;
      static constexpr int gzip_window_offset = 16;
      static constexpr int maximum_window_log = 23;
      static constexpr unsigned brotli_quality = 4;
      tbc::mut_a<Memory> memory_;
    };

    extern template class HttpContentCodec<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;

    extern template class HttpContentCodec<Memory>;
    extern template class HttpContentCodec<ConcurrentMemory>;

  }
}

// Interface: http/fields.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class HttpFields {
      using Secure = ErasingAllocator<Memory>;

    public:
      class Field {
      public:
        // The field copies its name and value into storage of the allocator, region `a`.
        Field(tbc::mut_a<Memory> memory, std::string_view name, std::string_view value);

        [[nodiscard]] auto name() const noexcept -> std::string_view;

        [[nodiscard]] auto value() const noexcept -> std::string_view;

      private:
        [[nodiscard]] auto text() const noexcept -> std::string_view;

        tbc::val_a<SensitiveAllocation<Memory>> storage_;
        std::size_t name_bytes_;
      };

      explicit HttpFields(Memory& memory);

      ~HttpFields() = default;

      HttpFields(const HttpFields&) = delete;
      HttpFields& operator=(const HttpFields&) = delete;
      HttpFields(HttpFields&&) = delete;
      HttpFields& operator=(HttpFields&&) = delete;

      void append(std::string_view name, std::string_view value);

      void set(std::string_view name, std::string_view value);

      void remove(std::string_view name) noexcept;

      [[nodiscard]] auto get(std::string_view name) const noexcept -> ds::Option<std::string_view>;

      [[nodiscard]] auto fields() const noexcept -> std::span<const Field>;

      [[nodiscard]] auto bytes() const noexcept -> std::size_t;

      void clear() noexcept;

      static bool token(std::string_view text) noexcept;

      static void validate(std::string_view name, std::string_view value);

      static constexpr std::size_t maximum_fields = 256;
      static constexpr std::size_t maximum_bytes = std::size_t{64} * 1024;

    private:
      static constexpr std::size_t line_overhead = 4;
      Memory& upstream_;
      Secure memory_;
      ds::Vec<Field, Secure> fields_;
      std::size_t bytes_ = 0;
    };

    extern template class HttpFields<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;

    extern template class HttpFields<Memory>;
    extern template class HttpFields<ConcurrentMemory>;

  }
}

// Interface: http/message_codec.cppm
export {
  namespace telar::runtime {

    enum class HttpVersion : std::uint8_t {
      http10,
      http11,
      http2,
    };

    struct HttpMessageLimits {
      static constexpr std::size_t body_bytes = std::size_t{1024} * 1024;
      static constexpr std::size_t head_bytes = std::size_t{64} * 1024;
      static constexpr std::size_t message_bytes = body_bytes + head_bytes + 8192;
    };

    struct HttpMessageView {
      struct Field {
        std::string_view name, value;
      };

      HttpVersion version = HttpVersion::http11;
      bool response = false;
      bool response_to_head = false;
      std::uint32_t stream = 0;
      std::string_view method, target, reason, scheme, authority;
      std::uint16_t status = HttpStatus::first_success;
      ds::Array<Field, HttpFields<SystemAllocator>::maximum_fields> headers, trailers;
      std::size_t header_count = 0;
      std::size_t trailer_count = 0;
      std::span<const Byte> body;
    };

    class HttpMessageCodec {
    public:
      static auto encode(tbc::val_a<std::span<Byte>> output, const HttpMessageView& message) -> tbc::val_a<std::span<const Byte>>;

      static auto decode(std::span<const Byte> input) -> HttpMessageView;

      // Generic over the caller's message type.
      template <typename Message>
      TBC_GENERIC static auto encodeMessage(tbc::val_a<std::span<Byte>> output, const Message& message) -> tbc::val_a<std::span<const Byte>> {
        HttpMessageView view{.version = message.version, .response = message.response, .response_to_head = message.response_to_head, .stream = message.stream, .method = message.method, .target = message.target, .reason = message.reason, .scheme = message.scheme, .authority = message.authority, .status = message.status, .body = message.body};

        for (const auto& field : message.headers.fields()) {
          view.headers.atMut(view.header_count++) = {field.name(), field.value()};
        }

        for (const auto& field : message.trailers.fields()) {
          view.trailers.atMut(view.trailer_count++) = {field.name(), field.value()};
        }

        return encode(output, view);
      }

      template <typename Message>
      TBC_GENERIC static void readMessage(Message& message, std::span<const Byte> input) {
        const auto view = decode(input);
        if (view.response != message.response || view.response_to_head != message.response_to_head || view.version != message.version || view.stream != message.stream) {
          throw EncodingError{"HTTP decision changed immutable transport metadata"};
        }

        if (view.version != HttpVersion::http2 && (!view.scheme.empty() || !view.authority.empty())) {
          throw EncodingError{"HTTP/1 uses the request target and Host field"};
        }

        message.method.assign(view.method);
        message.target.assign(view.target);
        message.reason.assign(view.reason);
        message.scheme.assign(view.scheme);
        message.authority.assign(view.authority);
        message.status = view.status;
        message.headers.clear();
        message.trailers.clear();
        for (const auto& field : std::span{view.headers}.first(view.header_count)) {
          message.headers.append(field.name, field.value);
        }

        for (const auto& field : std::span{view.trailers}.first(view.trailer_count)) {
          message.trailers.append(field.name, field.value);
        }

        message.body_materialized |= !std::ranges::equal(message.body, view.body);
        message.body.clear();
        message.body.extend({view.body.begin(), view.body.end()});
      }

    private:
      static void writeFields(plugins::FrameWriter& writer, std::span<const HttpMessageView::Field> fields);

      static auto readFields(plugins::FrameReader& reader, std::span<HttpMessageView::Field> fields) -> std::size_t;

      static void validate(const HttpMessageView& message);
    };

  }
}

// Interface: http/message.cppm
export {
  namespace telar::runtime {

    // What a request's Expect field asks: nothing, 100-continue, or something no relay supports.
    enum class HttpExpectation : std::uint8_t {
      none,
      continue_,
      unsupported,
    };

    // The allocators a message's fields draw from, a private base so that they are built before the fields.
    template <Allocator Memory>
    struct HttpMessageMemory {
      constexpr explicit HttpMessageMemory(Memory& allocator)
          : upstream(allocator),
            memory(allocator) {}

      Memory& upstream;
      ErasingAllocator<Memory> memory;
    };

    template <Allocator Memory>
    class HttpMessage : HttpMessageMemory<Memory> {
      using Secure = ErasingAllocator<Memory>;
      using Text = ds::String<Secure>;

    public:
      using Bytes = ds::Vec<std::uint8_t, Secure>;

      explicit HttpMessage(Memory& memory, bool is_response = false);

      ~HttpMessage() = default;

      HttpMessage(const HttpMessage&) = delete;
      HttpMessage& operator=(const HttpMessage&) = delete;
      HttpMessage(HttpMessage&&) = delete;
      HttpMessage& operator=(HttpMessage&&) = delete;

      auto readHttp1Head(std::string_view input, bool head_response = false) -> Http1Head;

      // `wire` may be the body itself, or part of it, as an HTTP/1 relay reads it.
      void decodeBody(std::span<const std::uint8_t> wire);

      [[nodiscard]] bool bodyless() const noexcept;

      // Whether the body is an event stream, which never completes for a hook to see it whole.
      [[nodiscard]] bool streamingBody() const;

      [[nodiscard]] HttpExpectation expectation() const;

      // The body in its content coding; a view of `body` when only identity codings describe it.
      auto encodeBody() -> HttpContentCodec<Memory>::Coded;

      void validateHttp2() const;

      // Framing is regenerated from the complete entity, never copied from an application's length field.
      auto serializeHttp1() -> Bytes;

      // Serializes into `output`, which may hold another allocator than the message's.
      void serializeHttp1(Bytes& output);

      static constexpr std::size_t maximum_body_bytes = HttpMessageLimits::body_bytes;
      bool response;
      bool response_to_head = false;
      bool body_materialized = false;
      HttpVersion version = HttpVersion::http11;
      std::uint16_t status = HttpStatus::first_success;
      std::uint32_t stream = 0;
      Text method, target, reason, scheme, authority;
      HttpFields<Memory> headers, trailers;
      Bytes body;

    private:
      static HttpVersion readVersion(std::string_view value);

      void validateRequest() const;

      void validateHttp2Request() const;

      // The checks a message passes before it is written as HTTP/1.
      void validateHttp1() const;

      void validateHost() const;

      void validateLengths() const;

      void validateTrailers() const;

      auto contentEncoding() -> Text;

      static bool framingField(std::string_view name) noexcept;

      static void append(Bytes& output, std::span<const std::uint8_t> bytes);

      static void append(Bytes& output, std::string_view text);

      void writeStartLine(Bytes& output) const;

      // The end of a head whose message carries no body, with the length a response to HEAD announces.
      void writeBodylessEnd(Bytes& output);

      void writeChunked(Bytes& output, std::span<const std::uint8_t> entity) const;

      static void number(Bytes& output, std::size_t value, unsigned base = http_decimal);

      static void fieldLine(Bytes& output, const HttpMessageView::Field& field);

      static void validateHeadSize(const Bytes& head);

      static constexpr std::size_t status_line_prefix_bytes = 13;
      static constexpr std::size_t content_overhead_bytes = std::size_t{64} * 1024;
      static constexpr std::size_t maximum_wire_bytes = maximum_body_bytes + (3 * content_overhead_bytes);
    };

    extern template class HttpMessage<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;

    extern template class HttpMessage<Memory>;
    extern template class HttpMessage<ConcurrentMemory>;

  }
}
