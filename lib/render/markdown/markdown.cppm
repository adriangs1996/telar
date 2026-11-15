export module telar.render.markdown;

import std;
import telar.render.document;
import telar.base.memory.allocators;

// Renders GitHub-flavoured Markdown into a Document. The source is never
// fetched from or resolved against anything: links and images stay text.
export namespace telar::render::markdown {

  // Limit render.max_markdown_bytes: the largest source the renderer reads.
  inline constexpr std::size_t max_source_bytes = std::size_t{4} << 20;

  enum class Error : std::uint8_t {
    none,
    too_large,          // the source exceeds max_source_bytes
    document_too_large, // the document would exceed max_document_bytes
    parser,             // md4c failed, as when it could not allocate
  };

  [[nodiscard]] Error render(std::string_view source, Document<Memory>& document);

}
