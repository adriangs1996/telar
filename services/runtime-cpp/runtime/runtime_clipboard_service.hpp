#pragma once

#include "../model/runtime_model.hpp"
#include "../platform/observation_worker.hpp"
#include "clipboard.hpp"
#include "telar_base/request_error.hpp"
#include <algorithm>

namespace telar::runtime {

class RuntimeClipboardReader {
public:
  using Request = bool;
  using Result = std::expected<clipboard::content, clipboard::read_error>;

  Result observe(const Request &) noexcept {
    return clipboard::read(runtime_clipboard_max_bytes);
  }

  void stop() noexcept {}
};

// One bounded capture at a time. Pulling one chunk per request keeps a slow
// consumer from filling the response queue or stalling terminal delivery.
template <Allocator Memory, typename Reader = RuntimeClipboardReader>
class RuntimeClipboardService {
public:
  using Clock = std::chrono::steady_clock;
  static constexpr auto transfer_timeout = std::chrono::seconds{30};

  explicit RuntimeClipboardService(RuntimeModel<Memory> &model)
      : model_(model),
        worker_(reader_) {}

  void read(ClientSession<Memory> &client, const ReadRuntimeClipboard &request) {
    expire(Clock::now());
    if (request.transfer_id != 0) {
      if (pending_ || owner_ != client.id || generation_ != client.generation ||
          transfer_ != request.transfer_id || offset_ != request.offset) {
        throw RequestError{FailureCode::invalid_request, "Clipboard transfer is absent, expired or out of sequence"};
      }
      send(client, request.request_id);
      return;
    }

    if (pending_ || owner_ != 0 || !worker_.submit(true)) {
      throw RequestError{FailureCode::resource_limit, "A clipboard capture or transfer is already pending"};
    }
    owner_ = client.id;
    generation_ = client.generation;
    transfer_ = request.request_id;
    offset_ = 0;
    pending_ = true;
    expires_ = Clock::now() + transfer_timeout;
  }

  void collect() {
    worker_.collect([&](typename Reader::Result &result) {
      pending_ = false;
      auto *client = model_.clients.find(owner_);
      if (client == nullptr || client->generation != generation_ || client->connection.closing || Clock::now() >= expires_) {
        clear();
        return;
      }
      try {
        if (!result) {
          const auto code = result.error() == clipboard::read_error::content_too_large ? FailureCode::resource_limit : FailureCode::invalid_request;
          client->connection.send(RequestFailed{.request_id = transfer_, .code = code, .message = errorMessage(result.error())});
          clear();
          return;
        }
        content_ = std::move(*result);
        send(*client, transfer_);
      } catch (...) {
        clear();
        client->connection.closeImmediately();
      }
    });
  }

  void expire(Clock::time_point now) noexcept {
    if (!pending_ && owner_ != 0) {
      const auto *client = model_.clients.find(owner_);
      if (now >= expires_ || client == nullptr || client->generation != generation_ || client->connection.closing) {
        clear();
      }
    }
  }

  int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  static std::string_view errorMessage(clipboard::read_error error) noexcept {
    if (error == clipboard::read_error::content_too_large) {
      return "Clipboard exceeds clipboard.max_capture_bytes (33554432 bytes)";
    }
    return clipboard::error_message(error);
  }

  void send(ClientSession<Memory> &client, std::uint64_t request) {
    const auto bytes = std::span<const Byte>{content_.bytes}.subspan(offset_);
    const auto part = bytes.first(std::min(bytes.size(), runtime_clipboard_chunk_bytes));
    client.connection.send(RuntimeClipboardChunk{.request_id = request, .transfer_id = transfer_, .offset = offset_, .total_bytes = content_.bytes.size(), .mime = content_.mime_type, .bytes = part});
    offset_ += part.size();
    if (offset_ == content_.bytes.size()) {
      clear();
    }
  }

  void clear() noexcept {
    // Captured bytes never enter history or checkpoints. Drop storage rather
    // than retaining a maximum-sized buffer between captures.
    content_ = {};
    owner_ = 0;
    generation_ = 0;
    transfer_ = 0;
    offset_ = 0;
  }

  RuntimeModel<Memory> &model_;
  Reader reader_;
  ObservationWorker<Reader> worker_;
  clipboard::content content_;
  std::uint64_t owner_ = 0;
  std::uint64_t generation_ = 0;
  std::uint64_t transfer_ = 0;
  std::size_t offset_ = 0;
  Clock::time_point expires_{};
  bool pending_ = false;
};

}
