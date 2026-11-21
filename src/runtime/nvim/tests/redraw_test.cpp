import std;
import telar.msgpack;
import telar.testing;
import telar.testing.test_memory;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.runtime.nvim.redraw;
import telar.runtime.nvim.screen;

namespace {

  namespace {

    using namespace telar;
    using namespace telar::runtime;
    using telar::testing::check;

    // Builds the parameters of one `redraw` notification the way Neovim writes them: a list of
    // `[name, arguments...]`, each `arguments` the parameters of one event.
    class Batch {
    public:
      Batch()
          : storage_(64 * 1024),
            writer_(storage_) {}

      // One event with one tuple of parameters, written by `arguments`.
      template <typename Arguments>
      Batch& event(std::string_view name, std::uint32_t count, Arguments arguments) {
        ++events_;
        writer_.array(2);
        writer_.string(name);
        writer_.array(count);
        arguments(writer_);
        return *this;
      }

      Batch& event(std::string_view name) {
        return event(name, 0, [](msgpack::Writer&) {});
      }

      Batch& integers(std::string_view name, std::initializer_list<std::int64_t> values) {
        return event(name, static_cast<std::uint32_t>(values.size()), [&](msgpack::Writer& writer) {
          for (const auto value : values) {
            writer.integer(value);
          }
        });
      }

      // A grid_line whose cells are `[text, highlight, repeat]`.
      struct Cell {
        std::string_view text;
        int highlight = -1;
        int repeat = 0;
      };

      Batch& line(std::uint32_t grid, std::uint32_t row, std::uint32_t column, std::initializer_list<Cell> cells) {
        return event("grid_line", 5, [&](msgpack::Writer& writer) {
          writer.unsignedInteger(grid);
          writer.unsignedInteger(row);
          writer.unsignedInteger(column);
          writer.array(static_cast<std::uint32_t>(cells.size()));

          for (const auto& cell : cells) {
            writer.array(cell.repeat > 0 ? 3 : cell.highlight >= 0 ? 2
                                                                   : 1);
            writer.string(cell.text);
            if (cell.highlight >= 0 || cell.repeat > 0) {
              writer.integer(std::max(cell.highlight, 0));
            }

            if (cell.repeat > 0) {
              writer.integer(cell.repeat);
            }
          }

          writer.boolean(false);
        });
      }

      NvimRedraw apply(NvimScreen& screen, ConcurrentMemory& memory) {
        check(!writer_.overflowed(), "the batch fits its buffer");

        std::vector<std::uint8_t> message(8);
        msgpack::Writer head{message};

        head.array(events_);
        message.resize(head.written().size());
        message.insert(message.end(), writer_.written().begin(), writer_.written().end());

        return applyRedraw(screen, message, memory);
      }

    private:
      std::vector<std::uint8_t> storage_;
      msgpack::Writer writer_;
      std::uint32_t events_ = 0;
    };

    std::string cellText(const NvimScreen& screen, const NvimCell& cell) {
      ds::Array<char, NvimCell::text_capacity> storage{};
      const auto size = screen.copyText(cell, storage.viewMut());

      return {storage.data(), size};
    }

    std::string rowText(const NvimScreen& screen, std::uint32_t grid, std::uint32_t row) {
      std::string text;
      const auto* found = screen.grid(grid);

      check(found != nullptr, "the grid exists");

      for (const auto& cell : found->row(row)) {
        text += cellText(screen, cell);
      }

      return text;
    }

    void linesAndRepeats() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      const auto outcome = Batch{}
                               .integers("grid_resize", {1, 10, 2})
                               .line(1, 0, 0, {{.text = "h", .highlight = 3}, {.text = "i"}, {.text = " ", .highlight = 0, .repeat = 8}})
                               .line(1, 1, 2, {{.text = "ñ", .highlight = 7, .repeat = 3}})
                               .event("flush")
                               .apply(screen, memory);

      check(outcome.accepted && outcome.flushes == 1, "the batch is applied and flushed");
      check(rowText(screen, 1, 0) == "hi        ", "the first row");
      check(rowText(screen, 1, 1) == "  ñññ     ", "a repeated cell");
      check(screen.grid(1)->row(0)[1].highlight == 3, "a cell without a highlight keeps the one before it");
      check(screen.grid(1)->row(1)[4].highlight == 7 && screen.grid(1)->row(1)[5].highlight == 0, "the repeat ends where it says");
      check(screen.settled() && screen.flushed() == 1, "the screen is settled after the flush");
    }

    void wideAndClusters() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      const std::string_view family = "👨‍👩‍👧";
      const std::string_view accented = "é̂";

      check(Batch{}.integers("grid_resize", {1, 6, 1}).line(1, 0, 0, {{.text = "漢", .highlight = 1}, {.text = ""}, {.text = accented}, {.text = family}, {.text = ""}, {.text = "x"}}).event("flush").apply(screen, memory).accepted);

      const auto row = screen.grid(1)->row(0);

      check((row[0].flags & NvimCell::wide) != 0 && (row[1].flags & NvimCell::continuation) != 0, "a wide character and its right half");
      check(cellText(screen, row[0]) == "漢" && cellText(screen, row[1]).empty(), "the right half has no text");
      check((row[2].flags & NvimCell::cluster) != 0 && cellText(screen, row[2]) == accented, "a cluster longer than four bytes");
      check((row[3].flags & NvimCell::cluster) != 0 && cellText(screen, row[3]).size() <= NvimCell::text_capacity, "a cluster is cut at what a cell holds");
      check(cellText(screen, row[5]) == "x", "a packed cell after them");
    }

    void scrollKeepsRowStamps() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};

      check(Batch{}.integers("grid_resize", {2, 3, 4}).line(2, 0, 0, {{.text = "a", .highlight = 0, .repeat = 3}}).line(2, 1, 0, {{.text = "b", .highlight = 0, .repeat = 3}}).line(2, 2, 0, {{.text = "c", .highlight = 0, .repeat = 3}}).line(2, 3, 0, {{.text = "d", .highlight = 0, .repeat = 3}}).event("flush").apply(screen, memory).accepted);
      check(Batch{}.integers("grid_scroll", {2, 0, 4, 0, 3, 1, 0}).line(2, 3, 0, {{.text = "e", .highlight = 0, .repeat = 3}}).event("flush").apply(screen, memory).accepted);

      const auto* grid = screen.grid(2);

      check(rowText(screen, 2, 0) == "bbb" && rowText(screen, 2, 2) == "ddd" && rowText(screen, 2, 3) == "eee", "the rows moved up");
      check(grid->row_changed_at[0] == 1 && grid->row_changed_at[2] == 1, "a moved row keeps the flush that drew it");
      check(grid->row_changed_at[3] == 2, "the row scrolled in belongs to the new flush");
      check(grid->scrolled_at == 2 && grid->scrolled_before == 0 && grid->scrolls.size() == 1 && grid->scrolls[0].rows == 1, "the scroll is kept for clients to replay");

      check(Batch{}.integers("grid_scroll", {2, 1, 4, 0, 3, -1, 0}).event("flush").apply(screen, memory).accepted);
      check(rowText(screen, 2, 1) == "ccc" && rowText(screen, 2, 2) == "ccc" && rowText(screen, 2, 3) == "ddd", "the rows moved down, the source left as it was");
      check(grid->scrolled_at == 3 && grid->scrolled_before == 2, "each flush's scrolls replace the last one's");
    }

    void highlightsAndColors() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};

      check(Batch{}.integers("default_colors_set", {0xdcdccc, -1, 0xff0000, 0, 0}).event("hl_attr_define", 4, [](msgpack::Writer& writer) {
                                                                                    writer.unsignedInteger(9);
                                                                                    writer.map(6);
                                                                                    writer.string("foreground");
                                                                                    writer.unsignedInteger(0xf0dfaf);
                                                                                    writer.string("bold");
                                                                                    writer.boolean(true);
                                                                                    writer.string("undercurl");
                                                                                    writer.boolean(true);
                                                                                    writer.string("blend");
                                                                                    writer.unsignedInteger(30);
                                                                                    writer.string("url");
                                                                                    writer.string("https://example.com");
                                                                                    writer.string("a key of a later Neovim");
                                                                                    writer.unsignedInteger(1);
                                                                                    writer.map(0);
                                                                                    writer.array(0);
                                                                                  })
              .event("flush")
              .apply(screen, memory)
              .accepted);

      const auto& highlight = screen.highlightOf(9);

      check(highlight.foreground == 0xf0dfaf && highlight.background == NvimHighlight::unset, "the colors it names, and none for the rest");
      check(highlight.attributes == (NvimHighlight::bold | NvimHighlight::undercurl) && highlight.blend == 30, "its attributes");
      check(screen.linkOf(highlight) == "https://example.com", "its link");
      check(screen.defaults().foreground == 0xdcdccc && screen.defaults().background == NvimHighlight::unset, "an unset default color stays unset");
      check(screen.highlightOf(4000) == NvimHighlight{}, "an id never defined is the default");
    }

    void windowsAndViewports() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      std::vector<std::uint8_t> bytes(256);
      msgpack::Writer writer{bytes};

      // [[win_pos, [2, window 1000, 1, 0, 80, 20]], [win_float_pos, [...]], [win_viewport, [...]], [win_hide, [2]]]
      writer.array(5);
      writer.array(2);
      writer.string("grid_resize");
      writer.array(3);
      writer.unsignedInteger(3);
      writer.unsignedInteger(40);
      writer.unsignedInteger(10);
      writer.array(2);
      writer.string("win_pos");
      writer.array(6);
      writer.unsignedInteger(2);
      writer.unsignedInteger(1000);
      writer.unsignedInteger(1);
      writer.unsignedInteger(0);
      writer.unsignedInteger(80);
      writer.unsignedInteger(20);
      writer.array(2);
      writer.string("win_float_pos");
      writer.array(11);
      writer.unsignedInteger(3);
      writer.unsignedInteger(1001);
      writer.string("NE");
      writer.unsignedInteger(2);
      writer.floating(4.5);
      writer.unsignedInteger(7);
      writer.boolean(false);
      writer.unsignedInteger(50);
      writer.unsignedInteger(2);
      writer.unsignedInteger(5);
      writer.unsignedInteger(12);
      writer.array(3);
      writer.string("win_viewport");
      writer.array(8);
      writer.unsignedInteger(2);
      writer.unsignedInteger(1000);
      writer.unsignedInteger(10);
      writer.unsignedInteger(30);
      writer.unsignedInteger(12);
      writer.unsignedInteger(4);
      writer.unsignedInteger(300);
      writer.integer(-3);
      writer.array(8);
      writer.unsignedInteger(2);
      writer.unsignedInteger(1000);
      writer.unsignedInteger(8);
      writer.unsignedInteger(28);
      writer.unsignedInteger(12);
      writer.unsignedInteger(4);
      writer.unsignedInteger(300);
      writer.integer(-2);
      writer.array(2);
      writer.string("flush");
      writer.array(0);
      check(!writer.overflowed());

      check(applyRedraw(screen, writer.written(), memory).accepted, "the events are applied");

      const auto* placed = screen.grid(2);
      const auto* floating = screen.grid(3);

      check(placed != nullptr && placed->placement == NvimPlacement::window && placed->window == 1000 && placed->start_row == 1 && placed->width == 80, "a window's place");
      check(placed->viewport.top_line == 8 && placed->viewport.line_count == 300 && placed->scrolled_lines == -5, "its viewport, and the lines it scrolled summed");
      check(floating->placement == NvimPlacement::floating && floating->anchor == NvimAnchor::north_east && floating->anchor_row == 4.5, "a float's anchor");
      check(floating->z_index == 50 && floating->composition_index == 2 && floating->start_row == 5 && floating->start_column == 12 && !floating->mouse_enabled, "a float's order and place");

      check(Batch{}.integers("win_hide", {2}).event("flush").apply(screen, memory).accepted);
      check(screen.grid(2)->placement == NvimPlacement::none && screen.grid(2)->placed_at == 2, "a hidden window keeps its grid");
    }

    void surfaces() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      const auto chunk = [](msgpack::Writer& writer, std::uint32_t attribute, std::string_view text) {
        writer.array(3);
        writer.unsignedInteger(attribute);
        writer.string(text);
        writer.unsignedInteger(0);
      };

      check(Batch{}.event("cmdline_show", 7, [&](msgpack::Writer& writer) {
                     writer.array(2);
                     chunk(writer, 5, "%s/");
                     chunk(writer, 6, "old");
                     writer.unsignedInteger(6);
                     writer.string(":");
                     writer.string("");
                     writer.unsignedInteger(0);
                     writer.unsignedInteger(1);
                     writer.unsignedInteger(0);
                   })
              .event("popupmenu_show", 5, [](msgpack::Writer& writer) {
                writer.array(2);
                writer.array(4);
                writer.string("request_id");
                writer.string("Field");
                writer.string("u64");
                writer.string("The request's id.");
                writer.array(4);
                writer.string("reply");
                writer.string("Variable");
                writer.string("");
                writer.string("");
                writer.integer(0);
                writer.integer(3);
                writer.integer(9);
                writer.integer(-1);
              })
              .event("msg_show", 7, [&](msgpack::Writer& writer) {
                writer.string("emsg");
                writer.array(1);
                chunk(writer, 2, "E37: No write since last change");
                writer.boolean(false);
                writer.boolean(true);
                writer.boolean(false);
                writer.unsignedInteger(41);
                writer.string("");
              })
              .event("flush")
              .apply(screen, memory)
              .accepted);

      const auto& line = screen.commandLine();
      const auto& completion = screen.completion();
      const auto& messages = screen.messages();

      check(line.visible && line.first == ':' && line.content.view() == "%s/old" && line.position == 6 && line.level == 1, "the command line");
      check(line.content.chunks.size() == 2 && line.content.chunks[1].highlight == 6 && line.content.chunks[1].offset == 3, "its highlighted runs");
      check(completion.visible && completion.items.size() == 2 && completion.selected == 0 && completion.grid == -1, "the completion's items");

      const auto& first = completion.items[0];
      const std::string_view text{completion.text.data(), completion.text.size()};

      check(first.word.of(text) == "request_id" && first.info.of(text) == "The request's id.", "an item's word and documentation");
      check(messages.visible.size() == 1 && messages.visible[0].kind == NvimMessageKind::error && messages.visible[0].id == 41 && messages.visible[0].history, "an error message");

      // A message with the id of a visible one replaces it; the command line hides at its level.
      check(Batch{}.event("msg_show", 7, [&](msgpack::Writer& writer) {
                     writer.string("echo");
                     writer.array(1);
                     chunk(writer, 0, "written");
                     writer.boolean(false);
                     writer.boolean(false);
                     writer.boolean(false);
                     writer.unsignedInteger(41);
                     writer.string("");
                   })
              .integers("popupmenu_select", {1})
              .event("cmdline_hide", 2, [](msgpack::Writer& writer) {
                writer.unsignedInteger(1);
                writer.boolean(false);
              })
              .event("flush")
              .apply(screen, memory)
              .accepted);
      check(messages.visible.size() == 1 && messages.visible[0].content.view() == "written" && messages.visible[0].kind == NvimMessageKind::plain, "the message is replaced");
      check(completion.selected == 1 && completion.items_at == 1 && completion.changed_at == 2, "a selection changes no item");
      check(!line.visible && line.changed_at == 2, "the command line hid");
    }

    void unknownEventsAreSkipped() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      const auto outcome = Batch{}
                               .event("an_event_of_a_later_neovim", 2, [](msgpack::Writer& writer) {
                                 writer.map(1);
                                 writer.string("nested");
                                 writer.array(2);
                                 writer.nil();
                                 writer.floating(1.0);
                                 writer.string("more");
                               })
                               .integers("grid_resize", {1, 4, 1, 99, 98})
                               .event("bell")
                               .event("flush")
                               .apply(screen, memory);

      check(outcome.accepted && outcome.bell && outcome.flushes == 1, "what follows an unknown event is applied");
      check(screen.grid(1) != nullptr && screen.grid(1)->columns == 4, "parameters past the known ones are skipped");
    }

    void refusals() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;

      {
        NvimScreen screen{memory};

        check(!Batch{}.integers("grid_resize", {1, NvimLimits::columns + 1, 10}).apply(screen, memory).accepted, "a grid wider than the limit");
      }

      {
        NvimScreen screen{memory};

        check(Batch{}.integers("grid_resize", {1, 4, 2}).apply(screen, memory).accepted);
        check(!Batch{}.line(1, 0, 2, {{.text = "x", .highlight = 0, .repeat = 3}}).apply(screen, memory).accepted, "cells past the end of a row");
        check(!Batch{}.line(1, 2, 0, {{.text = "x"}}).apply(screen, memory).accepted, "a row the grid does not have");
        check(!Batch{}.line(7, 0, 0, {{.text = "x"}}).apply(screen, memory).accepted, "a grid Neovim never sized");
        check(!Batch{}.integers("grid_scroll", {1, 0, 9, 0, 4, 1, 0}).apply(screen, memory).accepted, "a scroll outside the grid");
        check(!Batch{}.integers("grid_line", {1, 0}).apply(screen, memory).accepted, "an event short of its parameters");
      }

      {
        NvimScreen screen{memory};
        std::uint32_t grids = 0;

        while (Batch{}.integers("grid_resize", {grids + 1, NvimLimits::columns, NvimLimits::rows}).apply(screen, memory).accepted) {
          ++grids;
        }

        check(grids == NvimLimits::cells / (std::size_t{NvimLimits::columns} * NvimLimits::rows), "the grids together hold no more cells than the limit");
      }
    }

    void destroyedGridsAreForgotten() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};

      check(Batch{}.integers("grid_resize", {1, 4, 2}).integers("grid_resize", {5, 4, 2}).event("flush").apply(screen, memory).accepted);
      check(Batch{}.integers("grid_destroy", {5}).event("flush").apply(screen, memory).accepted);
      check(screen.grid(5) == nullptr && screen.grids().size() == 1 && screen.gridsRemovedAt() == 2, "the grid is gone, and clients older than its flush hear of it");
      check(Batch{}.integers("grid_resize", {5, 2, 2}).line(5, 1, 1, {{.text = "z"}}).event("flush").apply(screen, memory).accepted, "its id can be sized again");
    }

  }

  const telar::testing::Case case_lines{"nvim_redraw.lines_and_repeats", linesAndRepeats};
  const telar::testing::Case case_wide{"nvim_redraw.wide_and_clusters", wideAndClusters};
  const telar::testing::Case case_scroll{"nvim_redraw.scroll_keeps_row_stamps", scrollKeepsRowStamps};
  const telar::testing::Case case_highlights{"nvim_redraw.highlights_and_colors", highlightsAndColors};
  const telar::testing::Case case_windows{"nvim_redraw.windows_and_viewports", windowsAndViewports};
  const telar::testing::Case case_surfaces{"nvim_redraw.surfaces", surfaces};
  const telar::testing::Case case_unknown{"nvim_redraw.unknown_events_are_skipped", unknownEventsAreSkipped};
  const telar::testing::Case case_refusals{"nvim_redraw.refusals", refusals};
  const telar::testing::Case case_destroyed{"nvim_redraw.destroyed_grids_are_forgotten", destroyedGridsAreForgotten};

}
