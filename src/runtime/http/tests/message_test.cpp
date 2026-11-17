import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.runtime.http.message;
import telar.runtime.http1.head;
import telar.runtime.vocabulary.frames;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  template <typename Exception, typename Function>
  bool throws(Function&& function) {
    try {
      function();
    } catch (const Exception&) {
      return true;
    } catch (...) {
      return false;
    }

    return false;
  }

  struct Fixture {
    SystemAllocator system;
    MemoryAdapter<SystemAllocator> adapter{system};
    Memory& memory = adapter;
  };

  auto frame(std::span<Byte> buffer, const HttpMessageView& view) -> std::vector<Byte> {
    const auto written = HttpMessageCodec::encode(buffer, view);

    return {written.begin(), written.end()};
  }

  // A plugin's decision rewrites what the relay forwards, never where it goes: a decision that turns a
  // request into a response, or moves it to another HTTP/2 stream, would be serialized toward the
  // wrong peer or stream.
  void testDecisionMetadataImmutable() {
    Fixture fixture;
    HttpMessage request{fixture.memory};

    request.readHttp1Head("POST /original HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 4\r\n\r\n");
    request.body.assign({'b', 'o', 'd', 'y'});
    std::vector<Byte> buffer(HttpMessageLimits::message_bytes);
    const auto original = HttpMessageCodec::encodeMessage(std::span{buffer}, request);
    const auto view = HttpMessageCodec::decode(original);

    auto edited = view;

    edited.target = "/edited";
    std::vector<Byte> output(HttpMessageLimits::message_bytes);
    const auto accepted = frame(output, edited);

    HttpMessageCodec::readMessage(request, accepted);
    check(request.target == "/edited");

    const std::array<void (*)(HttpMessageView&), 6> mutations{
        [](HttpMessageView& message) {
          message.response = true;
        },
        [](HttpMessageView& message) {
          message.response_to_head = true;
        },
        [](HttpMessageView& message) {
          message.version = HttpVersion::http2;
        },
        [](HttpMessageView& message) {
          message.stream = 3;
        },
        [](HttpMessageView& message) {
          message.scheme = "https";
        },
        [](HttpMessageView& message) {
          message.authority = "other.test";
        },
    };

    for (const auto mutate : mutations) {
      auto decision = view;

      decision.target = "/rejected";
      mutate(decision);
      const auto bytes = frame(output, decision);

      check(throws<EncodingError>([&] {
        HttpMessageCodec::readMessage(request, bytes);
      }));
      check(request.target == "/edited" && !request.response && request.version == HttpVersion::http11 && request.stream == 0);
      check(request.headers.fields().size() == 2 && std::ranges::equal(request.body, std::string_view{"body"}));
    }
  }

  // A plugin frame sizes the decoded view's field arrays: a count past them must be refused before
  // any field is read into them.
  void testCodecBounds() {
    std::vector<Byte> buffer(HttpMessageLimits::message_bytes);

    for (const std::size_t declared : {HttpFields<SystemAllocator>::maximum_fields + 1, std::size_t{std::numeric_limits<std::uint16_t>::max()}}) {
      plugins::FrameWriter writer{std::span{buffer}};

      writer.tag(HttpVersion::http11);
      writer.boolean(false);
      writer.boolean(false);
      writer.integer(std::uint32_t{0});
      writer.text("GET");
      writer.text("/");
      writer.text("");
      writer.text("");
      writer.text("");
      writer.integer(std::uint16_t{200});
      writer.integer(static_cast<std::uint16_t>(declared));
      for (std::size_t index = 0; index < declared; ++index) {
        writer.text("");
        writer.text("");
      }

      writer.integer(std::uint16_t{0});
      writer.bytes({});
      const auto input = writer.finish();

      check(input.size() <= HttpMessageLimits::message_bytes);
      check(throws<EncodingError>([&] {
        static_cast<void>(HttpMessageCodec::decode(input));
      }));
    }
  }

  // An HTTP/2 message the child or a plugin hands the endpoint carries no userinfo in its authority,
  // no connection-specific field and no status HTTP/2 forbids.
  void testHttp2Validation() {
    Fixture fixture;

    auto request = [&](std::string_view method, std::string_view scheme, std::string_view target) {
      auto message = std::make_unique<HttpMessage<Memory>>(fixture.memory);

      message->version = HttpVersion::http2;
      message->method = method;
      message->scheme = scheme;
      message->authority = "fixture.test";
      message->target = target;
      return message;
    };

    auto rejected = [](const HttpMessage<Memory>& message) {
      return throws<std::invalid_argument>([&] {
        message.validateHttp2();
      });
    };

    auto userinfo = request("GET", "https", "/");

    userinfo->authority = "user@fixture.test";
    check(rejected(*userinfo));

    auto transfer = request("POST", "https", "/");

    transfer->headers.append("transfer-encoding", "chunked");
    check(rejected(*transfer));

    auto te = request("GET", "https", "/");

    te->headers.append("te", "gzip");
    check(rejected(*te));
    te->headers.set("te", "trailers");
    check(!rejected(*te));

    check(!rejected(*request("OPTIONS", "https", "*")));
    check(!rejected(*request("CONNECT", "", "")));

    HttpMessage response{fixture.memory, true};

    response.version = HttpVersion::http2;
    response.status = 200;
    check(!rejected(response));
    response.status = 101;
    check(rejected(response));
  }

  // The field list bounds what the codec later copies into a view of maximum_fields entries, so a
  // head or a plugin cannot grow it past that.
  void testFieldLimits() {
    Fixture fixture;
    constexpr auto maximum = HttpFields<Memory>::maximum_fields;
    std::string head = "GET / HTTP/1.1\r\nHost: fixture.test\r\n";

    for (std::size_t index = 0; index < maximum; ++index) {
      head += std::format("X-{}: v\r\n", index);
    }

    head += "\r\n";
    check(head.size() < Http1Head::capacity);
    HttpMessage message{fixture.memory};

    check(throws<std::exception>([&] {
      message.readHttp1Head(head);
    }));

    HttpFields fields{fixture.memory};

    for (std::size_t index = 0; index < maximum; ++index) {
      fields.append("X-Field", "v");
    }

    check(throws<std::length_error>([&] {
      fields.append("X-Field", "v");
    }));
    check(fields.fields().size() == maximum);
  }

  const telar::testing::Case case_decision_metadata_immutable{"http_message.decision_metadata_immutable", testDecisionMetadataImmutable};
  const telar::testing::Case case_codec_bounds{"http_message.codec_bounds", testCodecBounds};
  const telar::testing::Case case_http2_validation{"http_message.http2_validation", testHttp2Validation};
  const telar::testing::Case case_field_limits{"http_message.field_limits", testFieldLimits};

}
