#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "assertions.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_client/protocol/content.hpp"

import std;
import telar.gui.tests.session_fixture;
import telar.gui.application.workspace_replica;
import telar.gui.application.session;
import telar.render.markdown;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::test;

  std::vector<Byte> encoded(std::string_view markdown) {
    SystemAllocator memory;
    render::Document<SystemAllocator> document{memory};

    require(render::markdown::render(markdown, document) == render::markdown::Error::none, "the fixture renders");
    std::vector<Byte> bytes(*render::encodedSize(document));

    render::encode(document, bytes);
    return bytes;
  }

  PaneDocument part(std::uint64_t revision, std::span<const Byte> document, std::size_t offset, std::size_t size) {
    return PaneDocument{
        .pane_id = 1,
        .revision = revision,
        .size = static_cast<std::uint32_t>(document.size()),
        .offset = static_cast<std::uint32_t>(offset),
        .bytes = document.subspan(offset, size),
    };
  }

  // A document shows once all its parts arrived in order, and goes away when the runtime says so.
  void partsAssembleIntoTheDocument() {
    SystemAllocator memory;
    Transport transport;
    Session client{memory, transport};

    openFirstPane(client, transport);
    auto* pane = client.findPane(1);
    const auto bytes = encoded("# Title\n\nSome *text*.\n\n- one\n- two\n");
    const auto half = bytes.size() / 2;

    require(deliver(client, part(1, bytes, 0, half)) == Change::none && !pane->document_shown, "half a document shows nothing");
    require(deliver(client, part(1, bytes, half, bytes.size() - half)) == Change::document, "the last part completes the document");
    require(pane->document_shown && pane->document.blocks.size() == 4, "the whole document shows");
    const auto shown = pane->document_version;

    require(deliver(client, part(2, bytes, half, bytes.size() - half)) == Change::none && pane->document_shown, "a part out of order is dropped");
    require(deliver(client, PaneDocument{.pane_id = 1, .revision = 3}) == Change::document, "the runtime withdraws the document");
    require(!pane->document_shown && pane->document.blocks.empty() && pane->document_version > shown, "a withdrawn document no longer shows");
  }

  // Bytes that do not decode never show, whatever program wrote them.
  void corruptDocumentsDoNotShow() {
    SystemAllocator memory;
    Transport transport;
    Session client{memory, transport};

    openFirstPane(client, transport);
    auto bytes = encoded("text");

    bytes[0] = 'X';
    deliver(client, part(1, bytes, 0, bytes.size()));
    require(!client.findPane(1)->document_shown, "a corrupt document does not show");
  }

}

int main() {
  partsAssembleIntoTheDocument();
  corruptDocumentsDoNotShow();
  return 0;
}
