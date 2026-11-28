#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.render.markdown;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.render.document;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::application::tests::session_fixture;

  std::vector<Byte> encoded(std::string_view markdown) {
    telar::testing::TestMemory memory;
    render::Document<telar::Memory> document{memory};

    check(render::markdown::render(markdown, document) == render::markdown::Error::none, "the fixture renders");
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
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto* pane = client.findPane(1);
    const auto bytes = encoded("# Title\n\nSome *text*.\n\n- one\n- two\n");
    const auto half = bytes.size() / 2;

    check(deliver(client, part(1, bytes, 0, half)) == application::Change::none && !pane->document_shown, "half a document shows nothing");
    check(deliver(client, part(1, bytes, half, bytes.size() - half)) == application::Change::document, "the last part completes the document");
    check(pane->document_shown && pane->document.blocks.size() == 4, "the whole document shows");
    const auto shown = pane->document_version;

    check(deliver(client, part(2, bytes, half, bytes.size() - half)) == application::Change::none && pane->document_shown, "a part out of order is dropped");
    check(deliver(client, PaneDocument{.pane_id = 1, .revision = 3}) == application::Change::document, "the runtime withdraws the document");
    check(!pane->document_shown && pane->document.blocks.empty() && pane->document_version > shown, "a withdrawn document no longer shows");
  }

  // Bytes that do not decode never show, whatever program wrote them.
  void corruptDocumentsDoNotShow() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    auto bytes = encoded("text");

    bytes[0] = 'X';
    deliver(client, part(1, bytes, 0, bytes.size()));
    check(!client.findPane(1)->document_shown, "a corrupt document does not show");
  }

  const telar::testing::Case case_parts_assemble_into_the_document{"document_session.parts_assemble_into_the_document", partsAssembleIntoTheDocument};
  const telar::testing::Case case_corrupt_documents_do_not_show{"document_session.corrupt_documents_do_not_show", corruptDocumentsDoNotShow};

}
