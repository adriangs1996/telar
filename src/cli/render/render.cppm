export module telar.cli.render;

import std;
import telar.base.memory.allocators;
import telar.base.text;
import telar.render.document;
import telar.render.markdown;
import telar.render.terminal;

// `telar render KIND [FILE]`: renders content into a document. Inside a Telar
// pane it prints styled terminal text that the window shows natively in place,
// or with --pager takes the pane's alternate screen until the user quits;
// elsewhere it prints the styled text alone.
export namespace telar::runtime::cli::render_command {

  struct RenderOptions {
    enum class Kind : std::uint8_t {
      markdown,
    };
    enum class Format : std::uint8_t {
      automatic,
      native,
      ansi,
    };

    Kind kind = Kind::markdown;
    std::string_view path; // empty or "-" reads standard input
    Format format = Format::automatic;
    std::optional<std::uint16_t> width;
    bool pager = false;

    static RenderOptions parse(std::span<char* const> words);
  };

  int run(Memory& memory, const RenderOptions& options);

}
