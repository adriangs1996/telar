module;
#include <cstdio>
#include <cstdlib>
#include <new>

#define ZSTD_STATIC_LINKING_ONLY
#include <brotli/decode.h>
#include <brotli/encode.h>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <zlib.h>
#include <zstd.h>

module telar.runtime.http.message;

namespace telar::runtime {

  template <Allocator Memory>
  HttpContentCodec<Memory>::Flate::Flate(Memory& upstream, bool encode, int window)
      : memory(upstream),
        encoding(encode) {
    stream.zalloc = &DecoderMemory<Memory>::allocateArray;
    stream.zfree = &DecoderMemory<Memory>::release;
    stream.opaque = &memory;
    const auto result = encoding ? deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, window, memory_level, Z_DEFAULT_STRATEGY) : inflateInit2(&stream, window);
    if (result != Z_OK) {
      throw std::bad_alloc{};
    }
  }

  template <Allocator Memory>
  HttpContentCodec<Memory>::Flate::~Flate() {
    if (encoding) {
      deflateEnd(&stream);
    } else {
      inflateEnd(&stream);
    }
  }

  template <Allocator Memory>
  std::span<const std::uint8_t> HttpContentCodec<Memory>::Coded::bytes() const noexcept {
    return storage ? storage->bytes() : input;
  }

  template <Allocator Memory>
  HttpContentCodec<Memory>::HttpContentCodec(tbc::view<Memory&, tbc::lt::a> memory) noexcept
      : memory_(memory) {}

  template <Allocator Memory>
  auto HttpContentCodec<Memory>::decode(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit) -> tbc::view<DecodedBody<Memory>, tbc::lt::a> {
    return materialize(transform(input, encoding, limit, false), false);
  }

  template <Allocator Memory>
  auto HttpContentCodec<Memory>::encode(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit) -> tbc::view<DecodedBody<Memory>, tbc::lt::a> {
    return materialize(transform(input, encoding, limit, true), true);
  }

  template <Allocator Memory>
  auto HttpContentCodec<Memory>::decodeView(tbc::view<std::span<const std::uint8_t>, tbc::lt::a> input, std::string_view encoding, std::size_t limit) -> tbc::view<Coded, tbc::lt::a> {
    return transform(input, encoding, limit, false);
  }

  template <Allocator Memory>
  auto HttpContentCodec<Memory>::encodeView(tbc::view<std::span<const std::uint8_t>, tbc::lt::a> input, std::string_view encoding, std::size_t limit) -> tbc::view<Coded, tbc::lt::a> {
    return transform(input, encoding, limit, true);
  }

  template <Allocator Memory>
  auto HttpContentCodec<Memory>::materialize(Coded coded, bool encode) -> tbc::view<DecodedBody<Memory>, tbc::lt::a> {
    if (coded.storage) {
      return std::move(*coded.storage);
    }

    DecodedBody<Memory> result{memory_, coded.input.size()};

    std::ranges::copy(coded.input, result.storage.bytes().begin());
    result.size = coded.input.size();
    result.decoded = !encode;
    return result;
  }

  template <Allocator Memory>
  auto HttpContentCodec<Memory>::transform(tbc::view<std::span<const std::uint8_t>, tbc::lt::a> entity, std::string_view encoding, std::size_t limit, bool encode) -> tbc::view<Coded, tbc::lt::a> {
    if (limit == 0 || limit > maximum_bytes || entity.size() > maximum_bytes) {
      throw std::length_error{"Invalid HTTP content limit"};
    }

    // Editing refuses what a capture would pass over: an unknown or empty coding, or a third.
    const auto parsed = encoding.empty() ? ContentCodings{} : ContentCodings::parse(encoding);
    if (std::ranges::contains(parsed.list(), ContentCoding::unknown) || parsed.failure == ContentCodings::Failure::empty) {
      throw std::invalid_argument{"Unsupported HTTP content coding"};
    }

    if (parsed.failure == ContentCodings::Failure::too_many) {
      throw std::invalid_argument{"Too many HTTP content codings"};
    }

    const auto codings = parsed.codings;
    const auto count = parsed.count;

    // `input` moves from the entity to each coding's output; with no coding applied it is the entity.
    auto input = entity;
    std::optional<DecodedBody<Memory>> previous;

    for (std::size_t step = 0; step < count; ++step) {
      const auto selected = codings[encode ? step : count - step - 1];
      if (selected == ContentCoding::identity) {
        continue;
      }

      const auto capacity = step + 1 == count ? limit : std::min(maximum_bytes, limit + coding_overhead_bytes);
      auto output = one(input, selected, capacity, encode);

      previous = std::move(output);
      input = previous->bytes();
    }

    if (input.size() > limit) {
      throw std::length_error{"HTTP entity exceeds its limit"};
    }

    if (previous) {
      return {std::move(previous), {}};
    }

    return {std::nullopt, entity};
  }

  template <Allocator Memory>
  auto HttpContentCodec<Memory>::one(std::span<const std::uint8_t> input, ContentCoding selected, std::size_t limit, bool encode) -> tbc::view<DecodedBody<Memory>, tbc::lt::a> {
    DecodedBody<Memory> result{memory_, limit + 1};
    auto output = result.storage.bytes();

    if (selected == ContentCoding::gzip || selected == ContentCoding::deflate) {
      result.size = flate(input, output, selected == ContentCoding::gzip, encode);
    } else if (selected == ContentCoding::brotli) {
      result.size = brotli(input, output, encode);
    } else {
      result.size = zstd(input, output, encode);
    }

    if (result.size > limit) {
      throw std::length_error{"HTTP entity exceeds its limit"};
    }

    result.decoded = !encode;
    return result;
  }

  template <Allocator Memory>
  auto HttpContentCodec<Memory>::flate(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, bool gzip, bool encode) -> std::size_t {
    const int window = gzip ? MAX_WBITS + gzip_window_offset : MAX_WBITS;
    Flate state{memory_, encode, window};
    auto& stream = state.stream;

    stream.next_in = const_cast<std::uint8_t*>(input.data());
    stream.avail_in = static_cast<uInt>(input.size());
    stream.next_out = output.data();
    stream.avail_out = static_cast<uInt>(output.size());
    for (;;) {
      const auto before_input = stream.avail_in;
      const auto before_output = stream.avail_out;
      const auto result = encode ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH);
      if (result == Z_STREAM_END) {
        if (stream.avail_in == 0) {
          return output.size() - stream.avail_out;
        }

        if (!encode && gzip && inflateReset2(&stream, window) == Z_OK) {
          continue;
        }

        throw std::invalid_argument{"Trailing HTTP compressed bytes"};
      }

      if (stream.avail_out == 0) {
        throw std::length_error{"HTTP entity exceeds its limit"};
      }

      if (result != Z_OK || (stream.avail_in == before_input && stream.avail_out == before_output)) {
        throw std::invalid_argument{"Invalid or incomplete HTTP compressed entity"};
      }
    }
  }

  template <Allocator Memory>
  auto HttpContentCodec<Memory>::brotli(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, bool encode) -> std::size_t {
    DecoderMemory memory{memory_};
    auto remaining_input = input.size();
    auto remaining_output = output.size();
    const auto* next_input = input.data();
    auto* next_output = output.data();

    if (encode) {
      auto state = std::unique_ptr<BrotliEncoderState, decltype(&BrotliEncoderDestroyInstance)>{BrotliEncoderCreateInstance(&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory), &BrotliEncoderDestroyInstance};
      if (!state) {
        throw std::bad_alloc{};
      }

      if (!BrotliEncoderSetParameter(state.get(), BROTLI_PARAM_QUALITY, brotli_quality)) {
        throw std::invalid_argument{"Invalid Brotli parameters"};
      }

      while (!BrotliEncoderIsFinished(state.get())) {
        const auto before_input = remaining_input;
        const auto before_output = remaining_output;

        if (!BrotliEncoderCompressStream(state.get(), BROTLI_OPERATION_FINISH, &remaining_input, &next_input, &remaining_output, &next_output, nullptr)) {
          throw std::invalid_argument{"Brotli encoding failed"};
        }

        if (BrotliEncoderIsFinished(state.get())) {
          break;
        }

        if (remaining_output == 0 || (remaining_input == before_input && remaining_output == before_output)) {
          throw std::length_error{"HTTP entity exceeds its limit"};
        }
      }
    } else {
      auto state = std::unique_ptr<BrotliDecoderState, decltype(&BrotliDecoderDestroyInstance)>{BrotliDecoderCreateInstance(&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory), &BrotliDecoderDestroyInstance};
      if (!state) {
        throw std::bad_alloc{};
      }

      const auto result = BrotliDecoderDecompressStream(state.get(), &remaining_input, &next_input, &remaining_output, &next_output, nullptr);
      if (remaining_output == 0 && result == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
        throw std::length_error{"HTTP entity exceeds its limit"};
      }

      if (result != BROTLI_DECODER_RESULT_SUCCESS || remaining_input != 0) {
        throw std::invalid_argument{"Invalid or incomplete Brotli entity"};
      }
    }

    return output.size() - remaining_output;
  }

  template <Allocator Memory>
  auto HttpContentCodec<Memory>::zstd(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, bool encode) -> std::size_t {
    DecoderMemory memory{memory_};
    const ZSTD_customMem allocator{&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory};

    if (encode) {
      auto state = std::unique_ptr<ZSTD_CCtx, decltype(&ZSTD_freeCCtx)>{ZSTD_createCCtx_advanced(allocator), &ZSTD_freeCCtx};
      if (!state) {
        throw std::bad_alloc{};
      }

      if (ZSTD_isError(ZSTD_CCtx_setParameter(state.get(), ZSTD_c_checksumFlag, 1))) {
        throw std::invalid_argument{"Invalid Zstd parameters"};
      }

      const auto size = ZSTD_compress2(state.get(), output.data(), output.size(), input.data(), input.size());
      if (ZSTD_isError(size)) {
        throw std::length_error{"HTTP Zstd encoding exceeds its limit"};
      }

      return size;
    }

    auto state = std::unique_ptr<ZSTD_DCtx, decltype(&ZSTD_freeDCtx)>{ZSTD_createDCtx_advanced(allocator), &ZSTD_freeDCtx};
    if (!state) {
      throw std::bad_alloc{};
    }

    if (ZSTD_isError(ZSTD_DCtx_setParameter(state.get(), ZSTD_d_windowLogMax, maximum_window_log))) {
      throw std::invalid_argument{"Invalid Zstd parameters"};
    }

    ZSTD_inBuffer source{input.data(), input.size(), 0};
    ZSTD_outBuffer destination{output.data(), output.size(), 0};

    for (;;) {
      const auto before_input = source.pos;
      const auto before_output = destination.pos;
      const auto remaining = ZSTD_decompressStream(state.get(), &destination, &source);
      if (ZSTD_isError(remaining)) {
        throw std::invalid_argument{"Invalid Zstd entity"};
      }

      if (remaining == 0 && source.pos == source.size) {
        return destination.pos;
      }

      if (destination.pos == destination.size) {
        throw std::length_error{"HTTP entity exceeds its limit"};
      }

      if (before_input == source.pos && before_output == destination.pos) {
        throw std::invalid_argument{"Incomplete Zstd entity"};
      }
    }
  }

  template <Allocator Memory>
  HttpFields<Memory>::Field::Field(tbc::view<Memory&, tbc::lt::a> memory, std::string_view name, std::string_view value)
      : storage_(memory, name.size() + value.size()),
        name_bytes_(name.size()) {
    auto bytes = storage_.bytes();

    std::ranges::copy(name, bytes.begin());
    std::ranges::copy(value, bytes.begin() + name.size());
  }

  template <Allocator Memory>
  auto HttpFields<Memory>::Field::name() const noexcept -> std::string_view {
    return text().substr(0, name_bytes_);
  }

  template <Allocator Memory>
  auto HttpFields<Memory>::Field::value() const noexcept -> std::string_view {
    return text().substr(name_bytes_);
  }

  template <Allocator Memory>
  auto HttpFields<Memory>::Field::text() const noexcept -> std::string_view {
    const auto bytes = storage_.bytes();

    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
  }

  template <Allocator Memory>
  HttpFields<Memory>::HttpFields(Memory& memory)
      : upstream_(memory),
        memory_(memory),
        fields_(AllocatorRef<Field, Secure>{memory_}) {}

  template <Allocator Memory>
  void HttpFields<Memory>::append(std::string_view name, std::string_view value) {
    validate(name, value);
    if (fields_.size() == maximum_fields || name.size() + value.size() + line_overhead > maximum_bytes - bytes_) {
      throw std::length_error{"HTTP fields exceed their limit"};
    }

    fields_.emplace_back(upstream_, name, value);
    bytes_ += name.size() + value.size() + line_overhead;
  }

  template <Allocator Memory>
  void HttpFields<Memory>::set(std::string_view name, std::string_view value) {
    validate(name, value);
    const auto previous = std::ranges::find_if(fields_, [&](const Field& field) {
      return asciiEqualIgnoreCase(field.name(), name);
    });
    if (previous == fields_.end()) {
      append(name, value);
      return;
    }

    const auto old_bytes = previous->name().size() + previous->value().size();
    if (name.size() + value.size() > maximum_bytes - (bytes_ - old_bytes)) {
      throw std::length_error{"HTTP fields exceed their limit"};
    }

    Field replacement{upstream_, name, value};

    bytes_ = bytes_ - old_bytes + name.size() + value.size();
    *previous = std::move(replacement);
    for (auto cursor = std::next(previous); cursor != fields_.end();) {
      if (asciiEqualIgnoreCase(cursor->name(), previous->name())) {
        bytes_ -= cursor->name().size() + cursor->value().size() + line_overhead;
        cursor = fields_.erase(cursor);
      } else {
        ++cursor;
      }
    }
  }

  template <Allocator Memory>
  void HttpFields<Memory>::remove(std::string_view name) noexcept {
    std::array<bool, maximum_fields> matching{};

    for (std::size_t index = 0; index < fields_.size(); ++index) {
      matching[index] = asciiEqualIgnoreCase(fields_[index].name(), name);
    }

    for (auto index = fields_.size(); index != 0; --index) {
      if (matching[index - 1]) {
        const auto cursor = fields_.begin() + index - 1;

        bytes_ -= cursor->name().size() + cursor->value().size() + line_overhead;
        fields_.erase(cursor);
      }
    }
  }

  template <Allocator Memory>
  auto HttpFields<Memory>::get(std::string_view name) const noexcept -> std::optional<std::string_view> {
    for (const auto& field : fields_) {
      if (asciiEqualIgnoreCase(field.name(), name)) {
        return field.value();
      }
    }

    return std::nullopt;
  }

  template <Allocator Memory>
  auto HttpFields<Memory>::fields() const noexcept -> std::span<const Field> {
    return fields_;
  }

  template <Allocator Memory>
  auto HttpFields<Memory>::bytes() const noexcept -> std::size_t {
    return bytes_;
  }

  template <Allocator Memory>
  void HttpFields<Memory>::clear() noexcept {
    fields_.clear();
    bytes_ = 0;
  }

  template <Allocator Memory>
  bool HttpFields<Memory>::token(std::string_view text) noexcept {
    if (text.empty()) {
      return false;
    }

    return std::ranges::all_of(text, [](unsigned char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || std::string_view{"!#$%&'*+-.^_`|~"}.find(byte) != std::string_view::npos;
    });
  }

  template <Allocator Memory>
  void HttpFields<Memory>::validate(std::string_view name, std::string_view value) {
    if (!token(name) || name.size() > maximum_bytes || value.size() > maximum_bytes || std::ranges::any_of(value, [](unsigned char byte) {
          return (byte < 32 && byte != '\t') || byte == 127;
        })) {
      throw std::invalid_argument{"Invalid HTTP field"};
    }
  }

  auto HttpMessageCodec::encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const HttpMessageView& message) -> tbc::view<std::span<const Byte>, tbc::lt::a> {
    validate(message);
    plugins::FrameWriter writer{output};

    writer.tag(message.version);
    writer.boolean(message.response);
    writer.boolean(message.response_to_head);
    writer.integer(message.stream);
    writer.text(message.method);
    writer.text(message.target);
    writer.text(message.reason);
    writer.text(message.scheme);
    writer.text(message.authority);
    writer.integer(message.status);
    writeFields(writer, std::span{message.headers}.first(message.header_count));
    writeFields(writer, std::span{message.trailers}.first(message.trailer_count));
    writer.bytes(message.body);
    return writer.finish();
  }

  auto HttpMessageCodec::decode(std::span<const Byte> input) -> HttpMessageView {
    if (input.size() > HttpMessageLimits::message_bytes) {
      throw EncodingError{"HTTP message exceeds its frame limit"};
    }

    plugins::FrameReader reader{input};
    HttpMessageView message;

    message.version = reader.tag(HttpVersion::http2);
    message.response = reader.boolean();
    message.response_to_head = reader.boolean();
    message.stream = reader.integer<std::uint32_t>();
    message.method = reader.text();
    message.target = reader.text();
    message.reason = reader.text();
    message.scheme = reader.text();
    message.authority = reader.text();
    message.status = reader.integer<std::uint16_t>();
    message.header_count = readFields(reader, message.headers);
    message.trailer_count = readFields(reader, message.trailers);
    message.body = reader.bytes();
    reader.finish();
    validate(message);
    return message;
  }

  void HttpMessageCodec::writeFields(plugins::FrameWriter& writer, std::span<const HttpMessageView::Field> fields) {
    writer.integer(static_cast<std::uint16_t>(fields.size()));
    for (const auto& field : fields) {
      writer.text(field.name);
      writer.text(field.value);
    }
  }

  auto HttpMessageCodec::readFields(plugins::FrameReader& reader, std::span<HttpMessageView::Field> fields) -> std::size_t {
    const auto count = reader.integer<std::uint16_t>();
    if (count > fields.size()) {
      throw EncodingError{"Too many HTTP fields"};
    }

    for (auto& field : fields.first(count)) {
      field = {reader.text(), reader.text()};
    }

    return count;
  }

  void HttpMessageCodec::validate(const HttpMessageView& message) {
    if (static_cast<Byte>(message.version) > static_cast<Byte>(HttpVersion::http2) || message.header_count > message.headers.size() || message.trailer_count > message.trailers.size() || message.body.size() > HttpMessageLimits::body_bytes || message.method.size() > 64 || message.target.size() > 8192 || message.reason.size() > HttpMessageLimits::head_bytes || message.scheme.size() > 16 || message.authority.size() > 512) {
      throw EncodingError{"Invalid HTTP message bounds"};
    }

    std::size_t bytes = message.method.size() + message.target.size() + message.reason.size() + message.scheme.size() + message.authority.size();
    if (bytes > HttpMessageLimits::head_bytes) {
      throw EncodingError{"HTTP metadata exceeds its limit"};
    }

    for (const auto fields : {std::span{message.headers}.first(message.header_count), std::span{message.trailers}.first(message.trailer_count)}) {
      for (const auto& field : fields) {
        HttpFields<SystemAllocator>::validate(field.name, field.value);
        bytes += field.name.size() + field.value.size() + 4;
        if (bytes > HttpMessageLimits::head_bytes) {
          throw EncodingError{"HTTP metadata exceeds its limit"};
        }
      }
    }
  }

  template <Allocator Memory>
  HttpMessage<Memory>::HttpMessage(Memory& memory, bool response)
      : upstream_(memory),
        memory_(memory),
        response(response),
        method(AllocatorRef<char, Secure>{memory_}),
        target(AllocatorRef<char, Secure>{memory_}),
        reason(AllocatorRef<char, Secure>{memory_}),
        scheme(AllocatorRef<char, Secure>{memory_}),
        authority(AllocatorRef<char, Secure>{memory_}),
        headers(memory),
        trailers(memory),
        body(AllocatorRef<std::uint8_t, Secure>{memory_}) {}

  template <Allocator Memory>
  auto HttpMessage<Memory>::readHttp1Head(std::string_view input, bool head_response) -> Http1Head {
    if (input.size() > Http1Head::capacity || !input.ends_with("\r\n\r\n") || input.find("\r\n\r\n") != input.size() - 4) {
      throw std::invalid_argument{"Incomplete HTTP head"};
    }

    const auto analyzed = Http1Head::analyze(input, response, head_response);
    if (!analyzed) {
      throw std::invalid_argument{"Invalid HTTP framing"};
    }

    headers.clear();
    trailers.clear();
    body.clear();
    method.clear();
    target.clear();
    reason.clear();
    scheme.clear();
    authority.clear();
    stream = 0;
    body_materialized = false;
    response_to_head = head_response;
    TextFields lines{input, "\r\n"};
    const auto start = *lines.next();

    if (response) {
      if (start.size() < status_line_prefix_bytes || start[8] != ' ' || start[12] != ' ') {
        throw std::invalid_argument{"Invalid HTTP status line"};
      }

      version = readVersion(start.substr(0, 8));
      status = analyzed->status;
      reason.assign(start.substr(status_line_prefix_bytes));
      HttpFields<Memory>::validate("reason", reason);
    } else {
      const auto first = start.find(' ');
      const auto last = start.rfind(' ');
      if (first == std::string_view::npos || first == last) {
        throw std::invalid_argument{"Invalid HTTP request line"};
      }

      method.assign(start.substr(0, first));
      target.assign(start.substr(first + 1, last - first - 1));
      version = readVersion(start.substr(last + 1));
      validateRequest();
    }

    while (const auto line = lines.next()) {
      if (line->empty()) {
        break;
      }

      const auto colon = line->find(':');
      if (colon == std::string_view::npos) {
        throw std::invalid_argument{"Invalid HTTP field line"};
      }

      headers.append(line->substr(0, colon), trimText(line->substr(colon + 1), " \t"));
    }

    validateHost();
    validateLengths();
    return *analyzed;
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::decodeBody(std::span<const std::uint8_t> wire) {
    const auto coding = contentEncoding();
    const auto decoded = HttpContentCodec{upstream_}.decodeView(wire, coding, maximum_body_bytes);
    const auto bytes = decoded.bytes();
    const std::less_equal<const std::uint8_t*> before;
    if (!decoded.storage && !body.empty() && before(body.data(), bytes.data()) && before(bytes.data() + bytes.size(), body.data() + body.size())) {
      // An identity entity already in the body only has to be cut to the bytes it spans.
      body.erase(body.begin(), body.begin() + (bytes.data() - body.data()));
      body.resize(bytes.size());
    } else {
      body.assign(bytes.begin(), bytes.end());
    }

    body_materialized = true;
  }

  template <Allocator Memory>
  bool HttpMessage<Memory>::bodyless() const noexcept {
    return response && bodylessResponse(status, response_to_head);
  }

  template <Allocator Memory>
  bool HttpMessage<Memory>::streamingBody() const {
    const auto type = headers.get("content-type");

    return type && isEventStream(*type);
  }

  template <Allocator Memory>
  HttpExpectation HttpMessage<Memory>::expectation() const {
    const auto expect = headers.get("expect");
    if (!expect) {
      return HttpExpectation::none;
    }

    return asciiEqualIgnoreCase(*expect, "100-continue") ? HttpExpectation::continue_ : HttpExpectation::unsupported;
  }

  template <Allocator Memory>
  auto HttpMessage<Memory>::encodeBody() -> typename HttpContentCodec<Memory>::Coded {
    return HttpContentCodec{upstream_}.encodeView(body, contentEncoding(), maximum_body_bytes + content_overhead_bytes);
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::validateHttp2() const {
    if (version != HttpVersion::http2 || body.size() > maximum_body_bytes || headers.bytes() > HttpFields<Memory>::maximum_bytes - trailers.bytes()) {
      throw std::invalid_argument{"Invalid HTTP/2 message bounds"};
    }

    if (response) {
      if (status < 100 || status > 599 || status == 101) {
        throw std::invalid_argument{"Invalid HTTP/2 status"};
      }
    } else {
      if (!HttpFields<Memory>::token(method) || method.size() > maximum_method_bytes || authority.empty() || authority.size() > 512) {
        throw std::invalid_argument{"Invalid HTTP/2 request"};
      }

      if (method == "CONNECT") {
        if (!scheme.empty() || !target.empty()) {
          throw std::invalid_argument{"Invalid HTTP/2 CONNECT"};
        }
      } else {
        validateRequest();
        if ((scheme != "http" && scheme != "https") || (!target.starts_with('/') && !(method == "OPTIONS" && target == "*"))) {
          throw std::invalid_argument{"Invalid HTTP/2 target"};
        }
      }

      if (std::ranges::any_of(authority, [](unsigned char byte) {
            return byte <= 32 || byte >= 127 || std::string_view{"/,#?@\\"}.contains(byte);
          })) {
        throw std::invalid_argument{"Invalid HTTP/2 authority"};
      }
    }

    validateTrailers();
    for (const auto& field : headers.fields()) {
      if (asciiEqualIgnoreCase(field.name(), "connection") || asciiEqualIgnoreCase(field.name(), "keep-alive") || asciiEqualIgnoreCase(field.name(), "proxy-connection") || asciiEqualIgnoreCase(field.name(), "transfer-encoding") || asciiEqualIgnoreCase(field.name(), "upgrade") || (asciiEqualIgnoreCase(field.name(), "te") && !asciiEqualIgnoreCase(field.value(), "trailers"))) {
        throw std::invalid_argument{"Connection-specific HTTP/2 field"};
      }
    }
  }

  template <Allocator Memory>
  auto HttpMessage<Memory>::serializeHttp1() -> Bytes {
    Bytes output{AllocatorRef<std::uint8_t, Secure>{memory_}};

    serializeHttp1(output);
    return output;
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::serializeHttp1(Bytes& output) {
    output.clear();
    if (version == HttpVersion::http2) {
      throw std::invalid_argument{"HTTP/2 messages require an HTTP/2 endpoint"};
    }

    if (body.size() > maximum_body_bytes || headers.bytes() > HttpFields<Memory>::maximum_bytes - trailers.bytes()) {
      throw std::length_error{"HTTP message exceeds its limit"};
    }

    if (response) {
      if (status < 100 || status > 599) {
        throw std::invalid_argument{"Invalid HTTP status"};
      }

      HttpFields<Memory>::validate("reason", reason);
    } else {
      validateRequest();
      validateHost();
    }

    const bool without_body = bodyless();
    const bool chunked = !without_body && !trailers.fields().empty();
    if (chunked && version == HttpVersion::http10) {
      throw std::invalid_argument{"HTTP/1.0 cannot carry trailers"};
    }

    validateTrailers();
    const auto protocol = version == HttpVersion::http10 ? "HTTP/1.0" : "HTTP/1.1";

    if (response) {
      append(output, protocol);
      append(output, " ");
      number(output, status);
      append(output, " ");
      append(output, reason);
      append(output, "\r\n");
    } else {
      append(output, method);
      append(output, " ");
      append(output, target);
      append(output, " ");
      append(output, protocol);
      append(output, "\r\n");
    }

    for (const auto& field : headers.fields()) {
      if (!framingField(field.name())) {
        fieldLine(output, field.name(), field.value());
      }
    }

    if (without_body) {
      if (response_to_head && !bodylessResponse(status, false) && (body_materialized || !body.empty())) {
        const auto entity = encodeBody();

        append(output, "Content-Length: ");
        number(output, entity.bytes().size());
        append(output, "\r\n");
      } else if (status >= 200 && status != 204 && status != 205 && (response_to_head || status == 304) && headers.get("content-length")) {
        validateLengths();
        fieldLine(output, "Content-Length", *headers.get("content-length"));
      } else if (status == 205) {
        fieldLine(output, "Content-Length", "0");
      }

      append(output, "\r\n");
      validateHeadSize(output);
      return;
    }

    const auto encoded = encodeBody();
    const auto entity = encoded.bytes();

    if (chunked) {
      fieldLine(output, "Transfer-Encoding", "chunked");
      append(output, "Trailer: ");
      bool first = true;

      for (const auto& field : trailers.fields()) {
        if (!first) {
          append(output, ", ");
        }

        append(output, field.name());
        first = false;
      }

      append(output, "\r\n\r\n");
      validateHeadSize(output);
      if (!entity.empty()) {
        number(output, entity.size(), 16);
        append(output, "\r\n");
        append(output, entity);
        append(output, "\r\n");
      }

      append(output, "0\r\n");
      for (const auto& field : trailers.fields()) {
        fieldLine(output, field.name(), field.value());
      }

      append(output, "\r\n");
    } else {
      append(output, "Content-Length: ");
      number(output, entity.size());
      append(output, "\r\n\r\n");
      validateHeadSize(output);
      append(output, entity);
    }
  }

  template <Allocator Memory>
  HttpVersion HttpMessage<Memory>::readVersion(std::string_view value) {
    if (value == "HTTP/1.1") {
      return HttpVersion::http11;
    }

    if (value == "HTTP/1.0") {
      return HttpVersion::http10;
    }

    throw std::invalid_argument{"Unsupported HTTP version"};
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::validateRequest() const {
    if (!HttpFields<Memory>::token(method) || method.size() > maximum_method_bytes || target.empty() || target.size() > maximum_target_bytes || std::ranges::any_of(target, [](unsigned char byte) {
          return byte <= 32 || byte >= 127;
        })) {
      throw std::invalid_argument{"Invalid HTTP request line"};
    }
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::validateHost() const {
    if (response) {
      return;
    }

    std::size_t hosts = 0;

    for (const auto& field : headers.fields()) {
      if (asciiEqualIgnoreCase(field.name(), "host")) {
        if (field.value().empty() || std::ranges::any_of(field.value(), [](unsigned char byte) {
              return byte <= 32 || byte >= 127 || std::string_view{"/,#?@\\"}.contains(byte);
            })) {
          throw std::invalid_argument{"Invalid HTTP Host field"};
        }

        ++hosts;
      }
    }

    if (hosts > 1 || (version == HttpVersion::http11 && hosts != 1)) {
      throw std::invalid_argument{"HTTP request requires one Host field"};
    }
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::validateLengths() const {
    std::optional<std::size_t> length;
    bool transfer = false;

    for (const auto& field : headers.fields()) {
      if (asciiEqualIgnoreCase(field.name(), "content-length")) {
        TextFields values{field.value(), ","};

        while (const auto value = values.next()) {
          const auto parsed = parseHttpNumber<10>(trimText(*value, " \t"));
          if (!parsed) {
            throw std::invalid_argument{"Invalid HTTP length"};
          }

          if (length && *length != *parsed) {
            throw std::invalid_argument{"Conflicting HTTP lengths"};
          }

          length = parsed;
        }
      }

      if (asciiEqualIgnoreCase(field.name(), "transfer-encoding")) {
        if (transfer || !asciiEqualIgnoreCase(field.value(), "chunked")) {
          throw std::invalid_argument{"Unsupported HTTP transfer coding"};
        }

        transfer = true;
      }
    }

    if (transfer && length) {
      throw std::invalid_argument{"Ambiguous HTTP framing"};
    }
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::validateTrailers() const {
    for (const auto& field : trailers.fields()) {
      constexpr std::array forbidden{"host", "content-encoding", "content-type", "content-range", "connection", "authorization", "proxy-authorization", "proxy-authenticate", "www-authenticate", "cookie", "set-cookie", "cache-control", "max-forwards", "te", "upgrade", "range"};
      if (framingField(field.name()) || std::ranges::any_of(forbidden, [&](std::string_view name) {
            return asciiEqualIgnoreCase(field.name(), name);
          })) {
        throw std::invalid_argument{"Unsafe HTTP trailer"};
      }

      for (const auto& header : headers.fields()) {
        if (!asciiEqualIgnoreCase(header.name(), "connection")) {
          continue;
        }

        TextFields tokens{header.value(), ","};

        while (const auto token = tokens.next()) {
          if (asciiEqualIgnoreCase(field.name(), trimText(*token, " \t"))) {
            throw std::invalid_argument{"Hop-by-hop HTTP trailer"};
          }
        }
      }
    }
  }

  template <Allocator Memory>
  auto HttpMessage<Memory>::contentEncoding() -> Text {
    Text encoding{AllocatorRef<char, Secure>{memory_}};

    for (const auto& field : headers.fields()) {
      if (asciiEqualIgnoreCase(field.name(), "content-encoding")) {
        if (trimText(field.value(), " \t").empty()) {
          throw std::invalid_argument{"Empty HTTP content coding"};
        }

        if (!encoding.empty()) {
          encoding += ", ";
        }

        encoding += field.value();
      }
    }

    return encoding;
  }

  template <Allocator Memory>
  bool HttpMessage<Memory>::framingField(std::string_view name) noexcept {
    return asciiEqualIgnoreCase(name, "content-length") || asciiEqualIgnoreCase(name, "transfer-encoding") || asciiEqualIgnoreCase(name, "trailer");
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::append(Bytes& output, std::span<const std::uint8_t> bytes) {
    if (bytes.size() > maximum_wire_bytes - output.size()) {
      throw std::length_error{"HTTP wire message exceeds its limit"};
    }

    output.insert(output.end(), bytes.begin(), bytes.end());
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::append(Bytes& output, std::string_view text) {
    append(output, std::span{reinterpret_cast<const std::uint8_t*>(text.data()), text.size()});
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::number(Bytes& output, std::size_t value, int base) {
    std::array<char, std::numeric_limits<std::size_t>::digits10 + 1> text;
    const auto result = std::to_chars(text.data(), text.data() + text.size(), value, base);
    if (result.ec != std::errc{}) {
      throw std::length_error{"Invalid HTTP length"};
    }

    append(output, std::string_view{text.data(), result.ptr});
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::fieldLine(Bytes& output, std::string_view name, std::string_view value) {
    append(output, name);
    append(output, ": ");
    append(output, value);
    append(output, "\r\n");
  }

  template <Allocator Memory>
  void HttpMessage<Memory>::validateHeadSize(const Bytes& head) {
    if (head.size() > Http1Head::capacity) {
      throw std::length_error{"HTTP head exceeds its limit"};
    }
  }

  template class HttpContentCodec<Memory>;
  template class HttpContentCodec<ConcurrentMemory>;
  template class HttpFields<Memory>;
  template class HttpFields<ConcurrentMemory>;
  template class HttpMessage<Memory>;
  template class HttpMessage<ConcurrentMemory>;
  template class HttpContentCodec<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;
  template class HttpFields<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;
  template class HttpMessage<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;

}
