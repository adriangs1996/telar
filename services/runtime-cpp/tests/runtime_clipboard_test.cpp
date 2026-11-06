#include "client_peer.hpp"
#include "runtime/runtime_clipboard_service.hpp"
#include <atomic>
#include <poll.h>
#include <thread>

using namespace telar;
using namespace telar::runtime;

#ifdef TELAR_TEST_NATIVE_CLIPBOARD
void nativeClipboardTests(SystemAllocator &memory);
#endif

namespace {
struct Reader {
  using Request = bool;
  using Result = RuntimeClipboardReader::Result;
  inline static std::atomic<bool> blocked = false;
  inline static std::atomic<unsigned> calls = 0;
  inline static std::size_t size = runtime_clipboard_chunk_bytes * 2 + 17;
  inline static bool fail = false;

  Result observe(const Request &) noexcept {
    ++calls;
    while (blocked.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
    if (fail) {
      return std::unexpected(clipboard::read_error::session_unavailable);
    }
    clipboard::content value{.mime_type = "image/png", .bytes = std::vector<Byte>(size)};
    for (std::size_t index = 0; index < value.bytes.size(); ++index) {
      value.bytes[index] = static_cast<Byte>(index);
    }
    return value;
  }

  void stop() noexcept {
    blocked = false;
  }
};

void collect(auto &service) {
  pollfd ready{.fd = service.descriptor(), .events = POLLIN, .revents = 0};
  check(::poll(&ready, 1, 2000) == 1);
  service.collect();
}

void rejected(auto &&action, FailureCode code) {
  try {
    action();
    check(false);
  } catch (const RequestError &error) {
    check(error.code() == code);
  }
}

void transferTests(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientPeer first{memory, model, ClientRole::control};
  ClientPeer other{memory, model, ClientRole::control};
  RuntimeClipboardService<SystemAllocator, Reader> service{model};
  Reader::blocked = true;
  service.read(first.session(), {.request_id = 1});
  // Submitting a blocked native read must return without blocking the runtime.
  rejected([&] { service.read(other.session(), {.request_id = 2}); }, FailureCode::resource_limit);
  Reader::blocked = false;
  collect(service);
  auto chunk = first.receive<RuntimeClipboardChunk>();
  check(chunk.request_id == 1 && chunk.transfer_id == 1 && chunk.offset == 0);
  check(chunk.total_bytes == Reader::size && chunk.mime == "image/png");
  check(chunk.bytes.size() == runtime_clipboard_chunk_bytes);
  for (std::size_t index = 0; index < chunk.bytes.size(); ++index) {
    check(chunk.bytes[index] == static_cast<Byte>(index));
  }
  rejected([&] { service.read(other.session(), {.request_id = 3, .transfer_id = 1, .offset = chunk.bytes.size()}); }, FailureCode::invalid_request);
  rejected([&] { service.read(first.session(), {.request_id = 3, .transfer_id = 1, .offset = 7}); }, FailureCode::invalid_request);
  std::size_t received = chunk.bytes.size();
  while (received < Reader::size) {
    service.read(first.session(), {.request_id = 4, .transfer_id = 1, .offset = received});
    chunk = first.receive<RuntimeClipboardChunk>();
    check(chunk.offset == received && chunk.request_id == 4 && chunk.total_bytes == Reader::size);
    for (std::size_t index = 0; index < chunk.bytes.size(); ++index) {
      check(chunk.bytes[index] == static_cast<Byte>(received + index));
    }
    received += chunk.bytes.size();
  }
  check(Reader::calls == 1);
  rejected([&] { service.read(first.session(), {.request_id = 5, .transfer_id = 1, .offset = received}); }, FailureCode::invalid_request);

  service.read(first.session(), {.request_id = 6});
  collect(service);
  first.receive<RuntimeClipboardChunk>();
  service.expire(decltype(service)::Clock::now() + std::chrono::seconds{31});
  rejected([&] { service.read(first.session(), {.request_id = 7, .transfer_id = 6, .offset = runtime_clipboard_chunk_bytes}); }, FailureCode::invalid_request);

  Reader::size = 0;
  service.read(other.session(), {.request_id = 8});
  collect(service);
  chunk = other.receive<RuntimeClipboardChunk>();
  check(chunk.total_bytes == 0 && chunk.bytes.empty());

  Reader::fail = true;
  service.read(first.session(), {.request_id = 9});
  collect(service);
  const auto failure = first.receive<RequestFailed>();
  check(failure.request_id == 9 && failure.message.find("graphical session") != std::string_view::npos);
  Reader::fail = false;

  Reader::size = runtime_clipboard_chunk_bytes + 1;
  service.read(first.session(), {.request_id = 10});
  collect(service);
  first.receive<RuntimeClipboardChunk>();
  first.session().connection.closing = true;
  service.read(other.session(), {.request_id = 11});
  collect(service);
  other.receive<RuntimeClipboardChunk>();
  ++other.session().generation;
  rejected([&] { service.read(other.session(), {.request_id = 12, .transfer_id = 11, .offset = runtime_clipboard_chunk_bytes}); }, FailureCode::invalid_request);
}

void bounds() {
  std::array<Byte, 128> wire;
  try {
    Codec::encode(ReadRuntimeClipboard{.request_id = 1, .offset = 1}, wire);
    check(false);
  } catch (const EncodingError &) {
  }
  try {
    Codec::encode(RuntimeClipboardChunk{.request_id = 1, .transfer_id = 1, .offset = 1, .total_bytes = 0, .mime = "image/png"}, wire);
    check(false);
  } catch (const EncodingError &) {
  }
}
}

int main() {
  SystemAllocator memory;
  transferTests(memory);
  bounds();
#ifdef TELAR_TEST_NATIVE_CLIPBOARD
  nativeClipboardTests(memory);
#endif
  std::puts("Runtime clipboard: async capture, exact chunks, ownership, expiry, disconnect, empty content and failures passed");
}
