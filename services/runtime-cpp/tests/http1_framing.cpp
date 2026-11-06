#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <string_view>
#include <limits>
#include <optional>
#include <cstdint>
#include <concepts>
#include <span>
#include <algorithm>
#include <cstring>
#include <array>



import telar.runtime.http1.head;
import telar.runtime.http1.intercepted_relay;

struct Result {
  std::uint64_t length;
  std::uint32_t kind;
  std::uint16_t status;
  std::uint8_t flags;
  std::uint8_t valid;
};

extern "C" void analyze(const char *bytes, std::size_t length, std::uint8_t flags, Result *result) {
  *result = {};
  const auto parsed = telar::runtime::Http1Head::analyze({bytes, length}, flags & 1, flags & 2);
  if (!parsed) {
    return;
  }
  result->valid = 1;
  result->length = parsed->framing.length;
  result->kind = static_cast<std::uint32_t>(parsed->framing.kind);
  result->status = parsed->status;
  result->flags = parsed->head_request | (parsed->informational << 1) | (parsed->upgrade << 2) | (parsed->closes << 3);
}

extern "C" bool number(const char *bytes, std::size_t length, std::uint8_t base, std::uint64_t *result) {
  const auto parsed = base == 10 ? telar::runtime::parseHttpNumber<10>({bytes, length}) : telar::runtime::parseHttpNumber<16>({bytes, length});
  if (!parsed) {
    return false;
  }
  *result = *parsed;
  return true;
}

struct Input {
  const std::uint8_t *bytes;
  std::size_t length;
  std::uint8_t *output;
  std::uint8_t *payload;
  std::size_t capacity;
  std::size_t fragment;
  std::uint8_t flags;
};

struct RelayResult {
  std::size_t forwarded;
  std::size_t payload;
  std::size_t consumed;
  std::size_t heads;
  std::size_t head_limits;
  std::size_t chunk_limits;
  std::size_t trailer_limits;
  std::uint8_t valid;
};

class MessageStream {
public:
  using StreamResult = telar::runtime::StreamResult;

  explicit MessageStream(const Input &input, RelayResult &result) : input_(input), result_(result) {}

  telar::runtime::StreamView peekView(std::size_t maximum) noexcept {
    const auto count = std::min({maximum, input_.length - result_.consumed, input_.fragment});
    return {count == 0 ? StreamResult::State::ended : StreamResult::State::data, {input_.bytes + result_.consumed, count}};
  }

  void consume(std::size_t count) noexcept {
    result_.consumed += count;
  }

  StreamResult peek(std::span<std::uint8_t> destination) noexcept {
    const auto count = std::min({destination.size(), input_.length - result_.consumed, input_.fragment});
    if (count == 0) {
      return {StreamResult::State::ended};
    }
    std::memcpy(destination.data(), input_.bytes + result_.consumed, count);
    return {StreamResult::State::data, count};
  }

  StreamResult read(std::span<std::uint8_t> destination) noexcept {
    const auto received = peek(destination);
    result_.consumed += received.bytes;
    return received;
  }

  StreamResult write(std::span<const std::uint8_t> bytes) noexcept {
    if (bytes.size() > input_.capacity - result_.forwarded) {
      return {StreamResult::State::failed};
    }
    std::memcpy(input_.output + result_.forwarded, bytes.data(), bytes.size());
    result_.forwarded += bytes.size();
    return {StreamResult::State::data, bytes.size()};
  }

  void halfClose() noexcept {}
  void headStarted() noexcept { ++result_.heads; }
  void head(std::string_view) noexcept {}

  void payload(std::span<const std::uint8_t> bytes) noexcept {
    if (!bytes.empty()) {
      std::memcpy(input_.payload + result_.payload, bytes.data(), bytes.size());
      result_.payload += bytes.size();
    }
  }

  void lineTooLong(telar::runtime::Http1Line line) noexcept {
    ++(line == telar::runtime::Http1Line::chunk_size ? result_.chunk_limits : result_.trailer_limits);
  }

private:
  const Input &input_;
  RelayResult &result_;
};

static void relayMessage(telar::runtime::Http1MessageRelay &message, const Input *input, RelayResult *result) {
  using Message = telar::runtime::Http1MessageRelay;
  *result = {};
  MessageStream stream{*input, *result};
  message.reset(input->flags & 1, input->flags & 2);
  while (message.state() < Message::State::complete) {
    message.advance(stream, stream, stream);
  }
  result->valid = message.state() == Message::State::complete;
  result->head_limits = message.state() == Message::State::head_too_large;
}

extern "C" void relay(const Input *input, RelayResult *result) {
  telar::runtime::Http1MessageRelay message;
  relayMessage(message, input, result);
}

extern "C" std::uint64_t batch(const Input *input, std::size_t iterations) {
  telar::runtime::Http1MessageRelay message;
  std::uint64_t checksum = 0;
  for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
    RelayResult result;
    relayMessage(message, input, &result);
    checksum += result.forwarded + result.payload + result.consumed + result.valid;
  }
  return checksum;
}
