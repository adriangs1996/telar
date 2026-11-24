#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.history;
import telar.testing;

namespace {

  using telar::testing::check;

  using namespace telar::runtime;

  // `output` fed `piece` bytes at a time, as it reaches the tracker, without its marks.
  std::string filtered(std::string_view output, std::size_t piece) {
    IntegrationMarkFilter filter;
    std::string kept;

    for (std::size_t offset = 0; offset < output.size(); offset += piece) {
      const auto part = output.substr(offset, piece);

      filter.feed(std::span{reinterpret_cast<const std::uint8_t*>(part.data()), part.size()}, [&](std::span<const std::uint8_t> run) {
        kept.append(reinterpret_cast<const char*>(run.data()), run.size());
      });
    }

    return kept;
  }

  // The marks the shell integration prints carry the pane's token; the output the history keeps
  // never does, however the bytes are split.
  void dropsIntegrationMarks() {
    const std::string_view output = "\x1b]133;C;telar=0123abcd\x07hello\n\x1b]6973;names;ls\x1b\\world\x1b]133;D;0;telar=0123abcd\x07\x1b]133;A;telar=0123abcd\x1b\\";

    for (const std::size_t piece : {std::size_t{1}, std::size_t{2}, std::size_t{3}, std::size_t{7}, output.size()}) {
      const auto kept = filtered(output, piece);

      check(kept == "hello\nworld", "the marks are dropped");
      check(!kept.contains("telar="), "the token never stays");
    }
  }

  // Other escapes, and OSCs that only start like a mark, are output of the command.
  void keepsOtherSequences() {
    const std::string_view output = "\x1b[31mred\x1b[0m \x1b]0;title\x07 \x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\ \x1b]1337;x\x07 \x1b]13;y\x07 \x1b]69730;z\x07";

    for (const std::size_t piece : {std::size_t{1}, std::size_t{4}, output.size()}) {
      check(filtered(output, piece) == output, "sequences that are no mark are kept whole");
    }

    check(filtered("a\x1b]133;D;0\x1b"
                   "b",
              1) == "ab",
        "an escape that ends a mark is no part of it");
  }

  const telar::testing::Case case_drops_integration_marks{"integration_marks.drops_integration_marks", dropsIntegrationMarks};
  const telar::testing::Case case_keeps_other_sequences{"integration_marks.keeps_other_sequences", keepsOtherSequences};

}
