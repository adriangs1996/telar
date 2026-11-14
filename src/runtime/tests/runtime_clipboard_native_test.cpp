#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "../../gui/tests/platform/private_clipboard.hpp"
#include "../diagnostics/line.hpp"
#include "../graphics/child_file.hpp"
#include "../graphics/kitty_control.hpp"
#include "../graphics/kitty_framing.hpp"
#include "../graphics/media_budget.hpp"
#include "../graphics/temporary_path.hpp"
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include "../terminal/graphics_cursor.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_base/diagnostics/limit_reach.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/program_identity.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/protocol/clipboard.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_serializer.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include "telar_platform/mapped_region.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/trace.hpp"
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

#include "platform/private_clipboard.hpp"
#include <ghostty/vt.h>

import telar.runtime.tests.client_peer;
import telar.runtime.runtime.client_control;
import telar.runtime.tests.check;

using namespace telar;
using namespace telar::runtime;

void nativeClipboardTests(ConcurrentMemory& memory) {
  telar::gui::test::PrivateClipboard isolated;
  RuntimeModel model{memory};
  ClientStore<ConcurrentMemory> clients{memory};
  ClientPeer client{memory, model, clients, ClientRole::control};
  RuntimeClipboardService<ConcurrentMemory> service;
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
