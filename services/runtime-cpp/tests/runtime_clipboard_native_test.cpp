#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../../gui-cpp/tests/platform/private_clipboard.hpp"
#include "../diagnostics/line.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_base/diagnostics/config.hpp"
#include <array>
#include <span>
#include <sys/types.h>
#include "telar_base/memory/allocator.hpp"
#include <chrono>
#include <cstdint>
#include <bit>
#include <concepts>
#include <stdexcept>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <cassert>
#include <cstring>
#include <exception>
#include "telar_client/codecs/telar_codec.hpp"
#include <cstddef>
#include "telar_client/serializers/telar_serializer.hpp"
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <algorithm>
#include <optional>
#include "../graphics/kitty_framing.hpp"
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/trace.hpp"
#include <limits>
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include <unistd.h>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include <tuple>
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <memory>
#include "telar_base/program_identity.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>
#include "telar_base/diagnostics/limit_reach.hpp"
#include <condition_variable>
#include <pthread.h>
#include "../terminal/control/clipboard.hpp"
#include <poll.h>

#include "platform/private_clipboard.hpp"
#include <ghostty/vt.h>

import telar.runtime.tests.client_peer;
import telar.runtime.runtime.client_control;

using namespace telar;
using namespace telar::runtime;

void nativeClipboardTests(SystemAllocator &memory) {
    telar::gui::test::PrivateClipboard isolated;
    RuntimeModel model{memory};
    ClientStore<SystemAllocator> clients{memory};
    ClientPeer client{memory, model, clients, ClientRole::control};
    RuntimeClipboardService<SystemAllocator> service;
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
    check(std::equal(chunk.bytes.begin(), chunk.bytes.end(), reinterpret_cast<const Byte *>(expected.data())));

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
