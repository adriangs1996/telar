#include "client_peer.hpp"
#include "platform/private_clipboard.hpp"
#include "runtime/runtime_clipboard_service.hpp"
#import <AppKit/AppKit.h>
#include <poll.h>

using namespace telar;
using namespace telar::runtime;

void nativeClipboardTests(SystemAllocator &memory) {
  @autoreleasepool {
    telar::gui::test::PrivateClipboard isolated;
    NSPasteboard *board = [NSPasteboard generalPasteboard];
    RuntimeModel model{memory};
    ClientPeer client{memory, model, ClientRole::control};
    RuntimeClipboardService service{model};
    auto collect = [&] {
      pollfd ready{.fd = service.descriptor(), .events = POLLIN, .revents = 0};
      check(::poll(&ready, 1, 2000) == 1);
      service.collect();
    };
    isolated.clear();
    check([board setString:@"Text: á\n" forType:NSPasteboardTypeString]);
    service.read(client.session(), {.request_id = 1});
    collect();
    auto chunk = client.receive<RuntimeClipboardChunk>();
    const std::string_view expected = "Text: á\n";
    check(chunk.mime == "text/plain;charset=utf-8" && chunk.bytes.size() == expected.size());
    check(std::equal(chunk.bytes.begin(), chunk.bytes.end(), reinterpret_cast<const Byte *>(expected.data())));

    isolated.clear();
    std::vector<Byte> image(runtime_clipboard_chunk_bytes * 2 + 73, 0x55);
    check([board setData:[NSData dataWithBytes:image.data() length:image.size()] forType:NSPasteboardTypePNG]);
    service.read(client.session(), {.request_id = 2});
    collect();
    std::size_t offset = 0;
    do {
      chunk = client.receive<RuntimeClipboardChunk>();
      check(chunk.mime == "image/png" && chunk.total_bytes == image.size() && chunk.offset == offset);
      check(std::equal(chunk.bytes.begin(), chunk.bytes.end(), image.begin() + offset));
      offset += chunk.bytes.size();
      if (offset < image.size()) {
        service.read(client.session(), {.request_id = 3, .transfer_id = 2, .offset = offset});
      }
    } while (offset < image.size());
    std::puts("Native macOS clipboard worker and multi-chunk transfer passed. System clipboard unchanged.");
  }
}
