#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "platform/private_clipboard.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
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
#include <tuple>
#include <unistd.h>
#include <utility>
#include <variant>

#include <ghostty/vt.h>

import telar.runtime.core.tests.client_peer;
import telar.runtime.core.client_control;
import telar.runtime.terminal.control;
import telar.testing;
import telar.wire.clipboard;
import telar.runtime.core.model.client_layouts;
import telar.runtime.core.model.slot_store;
import telar.wire.vocabulary;

using telar::testing::check;

using namespace telar;
using namespace telar::runtime;

void nativeClipboardTests(ConcurrentMemory& memory) {
  telar::gui::test::PrivateClipboard isolated;
  RuntimeModel model{memory};
  ClientStore clients{memory};
  ClientPeer client{memory, model, clients, ClientRole::control};
  RuntimeClipboardService<> service;
  auto collect = [&] {
    pollfd ready{.fd = service.descriptor(), .events = POLLIN, .revents = 0};

    check(::poll(&ready, 1, 2000) == 1);
    service.collect(clients);
  };

  isolated.clear();
  isolated.setText("Text: á\n");
  service.read(clients, client.session().id, {.request_id = 1});
  collect();
  auto chunk = client.receive<RuntimeClipboardChunk>();
  const std::string_view expected = "Text: á\n";

  check(chunk.mime == "text/plain;charset=utf-8" && chunk.bytes.size() == expected.size());
  check(std::equal(chunk.bytes.begin(), chunk.bytes.end(), reinterpret_cast<const Byte*>(expected.data())));

  isolated.clear();
  std::vector<Byte> image(runtime_clipboard_chunk_bytes * 2 + 73, 0x55);

  isolated.setPng(std::as_bytes(std::span{image}));
  service.read(clients, client.session().id, {.request_id = 2});
  collect();
  std::size_t offset = 0;

  do {
    chunk = client.receive<RuntimeClipboardChunk>();
    check(chunk.mime == "image/png" && chunk.total_bytes == image.size() && chunk.offset == offset);
    check(std::equal(chunk.bytes.begin(), chunk.bytes.end(), image.begin() + offset));
    offset += chunk.bytes.size();
    if (offset < image.size()) {
      service.read(clients, client.session().id, {.request_id = 3, .transfer_id = 2, .offset = offset});
    }
  } while (offset < image.size());

  std::puts("Native macOS clipboard worker and multi-chunk transfer passed. System clipboard unchanged.");
}
