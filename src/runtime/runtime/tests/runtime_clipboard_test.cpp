#include <telar_clipboard/clipboard.hpp>
#include <expected>
#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/diagnostics/config.hpp"
#include "telar_base/diagnostics/limit_reach.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_wire/codecs/telar_codec.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/protocol/runtime.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "telar_wire/serializers/telar_serializer.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cassert>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <concepts>
#include <condition_variable>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <ghostty/vt.h>
#include <limits.h>
#include <limits>
#include <memory>
#include <optional>
#include <poll.h>
#include <pthread.h>
#include <span>
#include <stdexcept>
#include <string_view>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>
#include <thread>
#include <tuple>
#include <unistd.h>
#include <utility>
#include <variant>

import telar.runtime.runtime.tests.client_peer;
import telar.runtime.runtime.client_control;
import telar.runtime.terminal.control;
import telar.testing;
import telar.wire.clipboard;
import telar.runtime.model.client_layouts;
import telar.runtime.model.slot_store;

#ifdef TELAR_TEST_NATIVE_CLIPBOARD
// Defined in runtime_clipboard_native.cpp, which builds only with the native clipboard.
void nativeClipboardTests(telar::ConcurrentMemory& memory);
#endif

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  namespace {
    struct Reader {
      using Request = bool;
      using Result = RuntimeClipboardReader::Result;
      inline static std::atomic<bool> blocked = false;
      inline static std::atomic<unsigned> calls = 0;
      inline static std::size_t size = runtime_clipboard_chunk_bytes * 2 + 17;
      inline static bool fail = false;

      Result observe(const Request&) noexcept {
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

    void collect(auto& service, auto& clients) {
      pollfd ready{.fd = service.descriptor(), .events = POLLIN, .revents = 0};

      check(::poll(&ready, 1, 2000) == 1);
      service.collect(clients);
    }

    void rejected(auto&& action, FailureCode code) {
      try {
        action();
        check(false);
      } catch (const RequestError& error) {
        check(error.code() == code);
      }
    }

    void transferTests(ConcurrentMemory& memory) {
      RuntimeModel model{memory};
      ClientStore clients{memory};
      ClientPeer first{memory, model, clients, ClientRole::control};
      ClientPeer other{memory, model, clients, ClientRole::control};
      RuntimeClipboardService<Reader> service;

      Reader::blocked = true;
      service.read(clients, first.session().id, {.request_id = 1});
      // Submitting a blocked native read must return without blocking the runtime.
      rejected([&] {
        service.read(clients, other.session().id, {.request_id = 2});
      },
          FailureCode::resource_limit);
      Reader::blocked = false;
      collect(service, clients);
      auto chunk = first.receive<RuntimeClipboardChunk>();

      check(chunk.request_id == 1 && chunk.transfer_id == 1 && chunk.offset == 0);
      check(chunk.total_bytes == Reader::size && chunk.mime == "image/png");
      check(chunk.bytes.size() == runtime_clipboard_chunk_bytes);
      for (std::size_t index = 0; index < chunk.bytes.size(); ++index) {
        check(chunk.bytes[index] == static_cast<Byte>(index));
      }

      rejected([&] {
        service.read(clients, other.session().id, {.request_id = 3, .transfer_id = 1, .offset = chunk.bytes.size()});
      },
          FailureCode::invalid_request);
      rejected([&] {
        service.read(clients, first.session().id, {.request_id = 3, .transfer_id = 1, .offset = 7});
      },
          FailureCode::invalid_request);
      std::size_t received = chunk.bytes.size();

      while (received < Reader::size) {
        service.read(clients, first.session().id, {.request_id = 4, .transfer_id = 1, .offset = received});
        chunk = first.receive<RuntimeClipboardChunk>();
        check(chunk.offset == received && chunk.request_id == 4 && chunk.total_bytes == Reader::size);
        for (std::size_t index = 0; index < chunk.bytes.size(); ++index) {
          check(chunk.bytes[index] == static_cast<Byte>(received + index));
        }

        received += chunk.bytes.size();
      }

      check(Reader::calls == 1);
      rejected([&] {
        service.read(clients, first.session().id, {.request_id = 5, .transfer_id = 1, .offset = received});
      },
          FailureCode::invalid_request);

      service.read(clients, first.session().id, {.request_id = 6});
      collect(service, clients);
      first.receive<RuntimeClipboardChunk>();
      service.expire(clients, decltype(service)::Clock::now() + std::chrono::seconds{31});
      rejected([&] {
        service.read(clients, first.session().id, {.request_id = 7, .transfer_id = 6, .offset = runtime_clipboard_chunk_bytes});
      },
          FailureCode::invalid_request);

      Reader::size = 0;
      service.read(clients, other.session().id, {.request_id = 8});
      collect(service, clients);
      chunk = other.receive<RuntimeClipboardChunk>();
      check(chunk.total_bytes == 0 && chunk.bytes.empty());

      Reader::fail = true;
      service.read(clients, first.session().id, {.request_id = 9});
      collect(service, clients);
      const auto failure = first.receive<RequestFailed>();

      check(failure.request_id == 9 && failure.message.find("graphical session") != std::string_view::npos);
      Reader::fail = false;

      Reader::size = runtime_clipboard_chunk_bytes + 1;
      service.read(clients, first.session().id, {.request_id = 10});
      collect(service, clients);
      first.receive<RuntimeClipboardChunk>();
      first.session().connection.closing = true;
      service.read(clients, other.session().id, {.request_id = 11});
      collect(service, clients);
      other.receive<RuntimeClipboardChunk>();
      ++other.session().generation;
      rejected([&] {
        service.read(clients, other.session().id, {.request_id = 12, .transfer_id = 11, .offset = runtime_clipboard_chunk_bytes});
      },
          FailureCode::invalid_request);
    }

    void bounds() {
      std::array<Byte, 128> wire;

      try {
        Codec::encode(ReadRuntimeClipboard{.request_id = 1, .offset = 1}, wire);
        check(false);
      } catch (const EncodingError&) {
      }

      try {
        Codec::encode(RuntimeClipboardChunk{.request_id = 1, .transfer_id = 1, .offset = 1, .total_bytes = 0, .mime = "image/png"}, wire);
        check(false);
      } catch (const EncodingError&) {
      }
    }
  }

  const telar::testing::Case case_transfer{
      "runtime_clipboard.transfer",
      [] {
        SystemAllocator system;
        MemoryAdapter adapter{system};
        ConcurrentMemory& memory = adapter;

        transferTests(memory);
      },
  };
  const telar::testing::Case case_bounds{"runtime_clipboard.bounds", bounds};
#ifdef TELAR_TEST_NATIVE_CLIPBOARD
  const telar::testing::Case case_native{
      "runtime_clipboard.native",
      [] {
        SystemAllocator system;
        MemoryAdapter adapter{system};
        ConcurrentMemory& memory = adapter;

        nativeClipboardTests(memory);
      },
  };
#endif

}
