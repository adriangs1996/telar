import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.ghostty.vt;
import telar.runtime.terminal.text_reader;
import telar.wire.vocabulary;
import telar.base.ds;

// A terminal drawn from another's picture of its screen shows what the other shows.
namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void feed(Terminal& terminal, std::string_view text) {
    terminal.feed({reinterpret_cast<const Byte*>(text.data()), text.size()});
    terminal.refresh();
  }

  std::string rowText(const Screen& screen, std::size_t row) {
    std::string text;

    for (const auto& cell : std::span{screen.cells}.subspan(row * screen.cols, screen.cols)) {
      text.append(cell.length == 0 ? std::string_view{" "} : std::string_view{reinterpret_cast<const char*>(cell.text.data()), cell.length});
    }

    return text;
  }

  bool sameScreen(const Terminal& left, const Terminal& right) {
    const auto& a = left.screen();
    const auto& b = right.screen();
    if (a.rows != b.rows || a.cols != b.cols || a.cursor.x != b.cursor.x || a.cursor.y != b.cursor.y || a.cursor.visible != b.cursor.visible) {
      return false;
    }

    for (std::size_t row = 0; row < a.rows; ++row) {
      if (rowText(a, row) != rowText(b, row)) {
        return false;
      }
    }

    for (std::size_t index = 0; index < a.cells.size(); ++index) {
      if (a.cells[index].style.flags != b.cells[index].style.flags) {
        return false;
      }
    }

    return left.effects().title() == right.effects().title();
  }

  void drawsTheScreen() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const TerminalSize size{40, 8, 8, 16};

    for (const bool alternate : {false, true}) {
      Terminal source{memory, size};

      feed(source, "scrolled away\r\n");
      if (alternate) {
        feed(source, "\x1b[?1049h");
      }

      feed(source, "\x1b]0;\xe2\x97\x90 Working\x1b\\\x1b[2;1H\xe2\x9c\xb6 Processing\xe2\x80\xa6 (4s)\x1b[5;1H\xe2\x9d\xaf\xc2\xa0\x1b[2mplaceholder\x1b[0m\x1b[8;1Hfooter\x1b[5;3H\x1b[?25l");

      ds::Array<Byte, 65536> room{};
      const auto picture = source.drawScreen(room.viewMut());

      check(!picture.empty(), "a picture of a small screen does not fit");
      Terminal copy{memory, size};

      feed(copy, {reinterpret_cast<const char*>(picture.data()), picture.size()});
      check(sameScreen(source, copy), alternate ? "the alternate screen drawn from its picture differs" : "the screen drawn from its picture differs");
      check(copy.mode(telar::ghostty::mode(1049, false)) == alternate, "the picture loses the alternate screen");
    }
  }

  void refusesWhatDoesNotFit() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Terminal source{memory, TerminalSize{40, 8, 8, 16}};

    feed(source, "a row of text that needs room");
    ds::Array<Byte, 16> room{};

    check(source.drawScreen(room.viewMut()).empty(), "a picture that does not fit is cut");
  }

  const telar::testing::Case case_draws_the_screen{"draw_screen.draws_the_screen", drawsTheScreen};
  const telar::testing::Case case_refuses_what_does_not_fit{"draw_screen.refuses_what_does_not_fit", refusesWhatDoesNotFit};

}
