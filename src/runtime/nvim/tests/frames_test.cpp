import std;
import telar.msgpack;
import telar.testing;
import telar.testing.test_memory;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.runtime.nvim.frames;
import telar.runtime.nvim.redraw;
import telar.runtime.nvim.screen;
import telar.wire.nvim;
import telar.wire.vocabulary;

namespace {

  namespace {

    using namespace telar;
    using namespace telar::runtime;
    using telar::testing::check;

    constexpr std::uint64_t pane_id = 42;

    // What a client keeps of an editor pane: for each grid its cells, as the messages left them.
    struct Client {
      struct Grid {
        std::uint16_t columns = 0;
        std::uint16_t rows = 0;
        NvimPlacement placement = NvimPlacement::hidden;
        std::vector<std::string> text;
        std::vector<CellStyle> style;
      };

      // Applies a message as it crosses the wire: encoded, then decoded from its bytes.
      void apply(const NvimGrid& sent) {
        std::vector<Byte> bytes(Codec::encodedSize(sent));
        std::vector<Byte> scratch(256 * 1024);
        DecodeStorage storage{scratch};

        static_cast<void>(Codec::encode(sent, std::span<Byte>{bytes}));
        const auto message = Codec::decode<NvimGrid>(std::span<const Byte>{bytes}, storage);

        check(message.pane_id == pane_id, "the grid names its pane");
        ++messages;

        auto& grid = grids[message.grid];

        if (message.full) {
          grid.text.assign(std::size_t{message.columns} * message.rows, " ");
          grid.style.assign(std::size_t{message.columns} * message.rows, CellStyle{});
        }

        check(message.full || (grid.columns == message.columns && grid.rows == message.rows), "a grid that changes size is sent whole");
        grid.columns = message.columns;
        grid.rows = message.rows;
        grid.placement = message.placement;

        for (const auto& scroll : message.scrolls) {
          this->scroll(grid, scroll);
        }

        for (const auto& span : message.spans) {
          auto reader = span.reader();
          std::size_t index = span.start;

          while (const auto cell = reader.next()) {
            grid.text[index] = std::string{textView(cell->text)};
            grid.style[index] = cell->style;
            ++index;
            ++cells;
          }

          check(index == std::size_t{span.start} + span.count, "a span holds the cells it counts");
        }
      }

      // Moves the rows a scroll names, as the runtime's own screen did.
      static void scroll(Grid& grid, const NvimScroll& scroll) {
        const bool upward = scroll.rows > 0;
        const int last = upward ? scroll.bottom - scroll.rows : scroll.top - scroll.rows - 1;

        for (int row = upward ? scroll.top : scroll.bottom - 1; row != last; row += upward ? 1 : -1) {
          for (std::size_t column = scroll.left; column < scroll.right; ++column) {
            const auto source = (static_cast<std::size_t>(row + scroll.rows) * grid.columns) + column;
            const auto target = (static_cast<std::size_t>(row) * grid.columns) + column;

            grid.text[target] = grid.text[source];
            grid.style[target] = grid.style[source];
          }
        }
      }

      void apply(const NvimFrame& sent) {
        std::vector<Byte> bytes(Codec::encodedSize(sent));
        std::vector<Byte> scratch(16 * 1024);
        DecodeStorage storage{scratch};

        static_cast<void>(Codec::encode(sent, std::span<Byte>{bytes}));
        const auto message = Codec::decode<NvimFrame>(std::span<const Byte>{bytes}, storage);

        check(message.base_frame_id == 0 || message.base_frame_id == frame, "a frame changes the one the client has");
        if (message.base_frame_id == 0) {
          std::erase_if(grids, [&](const auto& entry) {
            return !touched.contains(entry.first);
          });
        }

        for (const auto removed : message.removed) {
          grids.erase(removed);
        }

        frame = message.frame_id;
        cursor_grid = message.cursor_grid;
        mode = std::string{message.mode};
      }

      std::map<std::uint32_t, Grid> grids;
      std::set<std::uint32_t> touched;
      std::uint64_t frame = 0;
      std::uint32_t cursor_grid = 0;
      std::string mode;
      std::size_t messages = 0;
      std::size_t cells = 0;
    };

    // Sends the client what it lacks, and says how many grid messages and cells that took.
    struct Sent {
      std::size_t messages = 0;
      std::size_t cells = 0;
    };

    Sent deliver(NvimFrames& frames, const NvimScreen& screen, Client& client) {
      const auto messages = client.messages;
      const auto cells = client.cells;

      check(screen.settled(), "a frame is made of a settled screen");
      frames.begin(screen, pane_id, client.frame);
      client.touched.clear();

      while (const auto grid = frames.next(screen)) {
        client.touched.insert(grid->grid);
        client.apply(*grid);
      }

      client.apply(frames.end(screen));
      return {.messages = client.messages - messages, .cells = client.cells - cells};
    }

    std::string cellText(const NvimScreen& screen, const NvimCell& cell) {
      ds::Array<char, NvimCell::text_capacity> storage{};
      const auto size = screen.copyText(cell, storage.viewMut());

      return {storage.data(), size};
    }

    // Whether the client shows, cell for cell, what the screen holds.
    bool mirrors(const NvimScreen& screen, const Client& client) {
      if (client.grids.size() != screen.grids().size() || client.frame != screen.flushed()) {
        return false;
      }

      for (const auto& grid : screen.grids()) {
        const auto found = client.grids.find(grid->id);
        if (found == client.grids.end() || found->second.columns != grid->columns || found->second.rows != grid->rows || found->second.placement != grid->placement) {
          return false;
        }

        for (std::size_t index = 0; index < grid->cells.size(); ++index) {
          if (found->second.text[index] != cellText(screen, grid->cells[index])) {
            return false;
          }
        }
      }

      return true;
    }

    // One redraw notification: `events` writes `count` `[name, [parameters]]` events.
    template <typename Events>
    void redraw(NvimScreen& screen, ConcurrentMemory& memory, std::uint32_t count, Events events) {
      std::vector<std::uint8_t> bytes(4 * 1024 * 1024);
      msgpack::Writer writer{bytes};

      writer.array(count + 1);
      events(writer);
      writer.array(2);
      writer.string("flush");
      writer.array(0);
      check(!writer.overflowed(), "the notification fits");
      check(applyRedraw(screen, writer.written(), memory).accepted, "the redraw is applied");
    }

    void event(msgpack::Writer& writer, std::string_view name, std::initializer_list<std::int64_t> values) {
      writer.array(2);
      writer.string(name);
      writer.array(static_cast<std::uint32_t>(values.size()));

      for (const auto value : values) {
        writer.integer(value);
      }
    }

    // A grid_line that fills `columns` cells of a row with one character and highlight.
    void fill(msgpack::Writer& writer, std::uint32_t grid, std::uint32_t row, std::string_view text, std::uint32_t columns, std::uint32_t highlight = 0) {
      writer.array(2);
      writer.string("grid_line");
      writer.array(5);
      writer.unsignedInteger(grid);
      writer.unsignedInteger(row);
      writer.unsignedInteger(0);
      writer.array(1);
      writer.array(3);
      writer.string(text);
      writer.unsignedInteger(highlight);
      writer.unsignedInteger(columns);
      writer.boolean(false);
    }

    void snapshotThenChanges() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      NvimFrames frames{memory};
      Client client;

      redraw(screen, memory, 6, [](msgpack::Writer& writer) {
        event(writer, "default_colors_set", {0xdcdccc, -1, -1, 0, 0});
        writer.array(2);
        writer.string("hl_attr_define");
        writer.array(4);
        writer.unsignedInteger(7);
        writer.map(3);
        writer.string("foreground");
        writer.unsignedInteger(0xf0dfaf);
        writer.string("bold");
        writer.boolean(true);
        writer.string("undercurl");
        writer.boolean(true);
        writer.map(0);
        writer.array(0);
        event(writer, "grid_resize", {1, 8, 3});
        fill(writer, 1, 0, "a", 8);
        fill(writer, 1, 1, "b", 8, 7);
        fill(writer, 1, 2, "c", 8);
      });

      check(NvimFrames::pending(screen, client.frame), "a client without a frame lacks the screen");

      const auto first = deliver(frames, screen, client);

      check(mirrors(screen, client) && first.messages == 1 && first.cells == 24, "a client without a frame is sent every cell");
      check(!NvimFrames::pending(screen, client.frame), "and then lacks nothing");

      const auto& highlighted = client.grids[1].style[8];
      const CellColor accent{.kind = CellColor::Kind::rgb, .channels = {0xf0, 0xdf, 0xaf}};
      const CellColor text{.kind = CellColor::Kind::rgb, .channels = {0xdc, 0xdc, 0xcc}};

      check(highlighted.foreground == accent && highlighted.background == CellColor{}, "a highlight's color, and the client's own for the one Neovim leaves unset");
      check((highlighted.flags & std::to_underlying(CellAttribute::bold)) != 0 && (highlighted.flags >> 8U) == std::to_underlying(UnderlineStyle::curly), "its attributes and its underline");
      check(client.grids[1].style[0].foreground == text, "a cell without a highlight takes Neovim's default color");

      redraw(screen, memory, 1, [](msgpack::Writer& writer) {
        fill(writer, 1, 2, "z", 8);
      });

      const auto second = deliver(frames, screen, client);

      check(mirrors(screen, client) && second.messages == 1 && second.cells == 8, "then only the row that changed");
    }

    void placementAloneSendsNoCells() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      NvimFrames frames{memory};
      Client client;

      redraw(screen, memory, 2, [](msgpack::Writer& writer) {
        event(writer, "grid_resize", {1, 4, 2});
        event(writer, "grid_resize", {2, 4, 2});
      });
      deliver(frames, screen, client);
      redraw(screen, memory, 1, [](msgpack::Writer& writer) {
        event(writer, "win_pos", {2, 1000, 0, 0, 4, 2});
      });

      const auto sent = deliver(frames, screen, client);

      check(mirrors(screen, client) && sent.messages == 1 && sent.cells == 0, "a grid that only moved is sent without cells");
      check(client.grids[2].placement == NvimPlacement::window, "the client learns where it is shown");
    }

    void scrollIsReplayed() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      NvimFrames frames{memory};
      Client client;

      redraw(screen, memory, 4, [](msgpack::Writer& writer) {
        event(writer, "grid_resize", {1, 4, 3});
        fill(writer, 1, 0, "a", 4);
        fill(writer, 1, 1, "b", 4);
        fill(writer, 1, 2, "c", 4);
      });
      deliver(frames, screen, client);
      redraw(screen, memory, 2, [](msgpack::Writer& writer) {
        event(writer, "grid_scroll", {1, 0, 3, 0, 4, 1, 0});
        fill(writer, 1, 2, "d", 4);
      });

      const auto sent = deliver(frames, screen, client);

      check(mirrors(screen, client) && sent.cells == 4, "a client one scroll behind moves its rows and is sent the new one");

      // Two scrolls in flushes of their own: a client that missed the first cannot replay the second.
      Client behind = client;

      redraw(screen, memory, 2, [](msgpack::Writer& writer) {
        event(writer, "grid_scroll", {1, 0, 3, 0, 4, 1, 0});
        fill(writer, 1, 2, "e", 4);
      });
      deliver(frames, screen, client);
      redraw(screen, memory, 2, [](msgpack::Writer& writer) {
        event(writer, "grid_scroll", {1, 0, 3, 0, 4, -1, 0});
        fill(writer, 1, 0, "f", 4);
      });
      check(mirrors(screen, client) == false && deliver(frames, screen, client).cells == 4 && mirrors(screen, client), "a scroll down is replayed as well");
      check(deliver(frames, screen, behind).cells == 12 && mirrors(screen, behind), "a client that missed a scroll is sent the grid whole");
    }

    void removedGridsAreForgotten() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      NvimFrames frames{memory};
      Client client;

      redraw(screen, memory, 2, [](msgpack::Writer& writer) {
        event(writer, "grid_resize", {1, 4, 2});
        event(writer, "grid_resize", {9, 4, 2});
      });
      deliver(frames, screen, client);
      check(client.grids.contains(9));
      redraw(screen, memory, 1, [](msgpack::Writer& writer) {
        event(writer, "grid_destroy", {9});
      });
      deliver(frames, screen, client);
      check(mirrors(screen, client) && !client.grids.contains(9), "a grid Neovim destroyed leaves the client");

      // A client that reconnects with nothing is sent the grids that are left, and no others.
      Client late;

      late.grids[9] = {};
      deliver(frames, screen, late);
      check(mirrors(screen, late), "a client that starts over forgets the grids it is not sent");
    }

    void largeGridCrossesInSeveralMessages() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      NvimFrames frames{memory};
      Client client;
      constexpr std::uint32_t columns = 400;
      constexpr std::uint32_t rows = 300;

      redraw(screen, memory, rows + 1, [](msgpack::Writer& writer) {
        event(writer, "grid_resize", {1, columns, rows});

        for (std::uint32_t row = 0; row < rows; ++row) {
          fill(writer, 1, row, row % 2 == 0 ? "x" : "ñ", columns, row % 5);
        }
      });

      const auto sent = deliver(frames, screen, client);

      check(mirrors(screen, client) && sent.cells == std::size_t{columns} * rows, "every cell of a large grid arrives");
      check(sent.messages == (std::size_t{columns} * rows + NvimFrames::message_cells - 1) / (NvimFrames::message_cells / columns * columns), "in as many messages as its cells need");
    }

    void cursorAndMode() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      NvimFrames frames{memory};

      redraw(screen, memory, 4, [](msgpack::Writer& writer) {
        event(writer, "grid_resize", {1, 4, 2});
        writer.array(2);
        writer.string("mode_info_set");
        writer.array(2);
        writer.boolean(true);
        writer.array(2);
        writer.map(1);
        writer.string("cursor_shape");
        writer.string("block");
        writer.map(2);
        writer.string("cursor_shape");
        writer.string("vertical");
        writer.string("cell_percentage");
        writer.unsignedInteger(25);
        writer.array(2);
        writer.string("mode_change");
        writer.array(2);
        writer.string("insert");
        writer.unsignedInteger(1);
        event(writer, "grid_cursor_goto", {1, 1, 3});
      });

      frames.begin(screen, pane_id, 0);

      while (frames.next(screen)) {
      }

      const auto frame = frames.end(screen);

      check(frame.frame_id == 1 && frame.base_frame_id == 0 && frame.cursor_grid == 1 && frame.cursor_row == 1 && frame.cursor_column == 3 && frame.cursor_visible, "where the cursor is");
      check(frame.cursor_shape == CursorShape::bar && frame.cursor_percentage == 25 && frame.mode == "insert", "its shape in the mode Neovim is in");
    }

  }

  namespace {

    void surfacesAreSentWhenTheyChange() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimScreen screen{memory};
      NvimFrames frames{memory};

      redraw(screen, memory, 4, [](msgpack::Writer& writer) {
        event(writer, "grid_resize", {1, 20, 4});
        // cmdline_show: content, position, first character, prompt, indent, level.
        writer.array(2);
        writer.string("cmdline_show");
        writer.array(6);
        writer.array(1);
        writer.array(2);
        writer.unsignedInteger(0);
        writer.string("write");
        writer.unsignedInteger(5);
        writer.string(":");
        writer.string("");
        writer.unsignedInteger(0);
        writer.unsignedInteger(1);
        // popupmenu_show: items of word, kind, menu and info, then selected, row, column, grid.
        writer.array(2);
        writer.string("popupmenu_show");
        writer.array(5);
        writer.array(2);
        for (const auto word : {"write", "wall"}) {
          writer.array(4);
          writer.string(word);
          writer.string("cmd");
          writer.string("");
          writer.string("");
        }
        writer.integer(0);
        writer.unsignedInteger(0);
        writer.unsignedInteger(0);
        writer.integer(-1);
        // tabline_update: current tab, tabs, current buffer, buffers.
        writer.array(2);
        writer.string("tabline_update");
        writer.array(4);
        writer.unsignedInteger(1);
        writer.array(1);
        writer.map(2);
        writer.string("tab");
        writer.unsignedInteger(1);
        writer.string("name");
        writer.string("main.cpp");
        writer.unsignedInteger(3);
        writer.array(0);
      });

      frames.begin(screen, pane_id, 0);

      while (frames.next(screen)) {
      }

      const auto line = frames.cmdline(screen);
      const auto menu = frames.popupMenu(screen);
      const auto tabs = frames.tabLine(screen);

      check(line && line->visible && line->first == ':' && line->text == "write" && line->position == 5 && line->level == 1 && line->frame_id == 1, "the command line as Neovim has it");
      check(menu && menu->visible && !menu->keeps_items && menu->selected == 0 && menu->grid == -1 && menu->total == 2 && menu->items.size() == 2 && menu->items[1].word == "wall" && menu->items[0].kind == "cmd", "the completion menu with its items");
      check(tabs && tabs->current_tab == 1 && tabs->tabs.size() == 1 && tabs->tabs[0].name == "main.cpp", "the tabs by name");
      check(!frames.messageList(screen), "a surface that never changed is not sent");

      // The selection moves: the client keeps the items it has.
      redraw(screen, memory, 1, [](msgpack::Writer& writer) {
        event(writer, "popupmenu_select", {1});
      });
      frames.begin(screen, pane_id, 1);

      while (frames.next(screen)) {
      }

      const auto moved = frames.popupMenu(screen);

      check(moved && moved->keeps_items && moved->items.empty() && moved->selected == 1, "a selection that moved is sent without the items");
      check(!frames.cmdline(screen) && !frames.tabLine(screen), "and the surfaces that did not change are left alone");

      redraw(screen, memory, 2, [](msgpack::Writer& writer) {
        event(writer, "popupmenu_hide", {});
        event(writer, "cmdline_hide", {1, 0});
      });
      frames.begin(screen, pane_id, 2);

      while (frames.next(screen)) {
      }

      check(!frames.popupMenu(screen)->visible && !frames.cmdline(screen)->visible, "a surface that closed says so");
    }

  }

  const telar::testing::Case case_surfaces{"nvim_frames.surfaces_are_sent_when_they_change", surfacesAreSentWhenTheyChange};
  const telar::testing::Case case_snapshot{"nvim_frames.snapshot_then_changes", snapshotThenChanges};
  const telar::testing::Case case_placement{"nvim_frames.placement_alone_sends_no_cells", placementAloneSendsNoCells};
  const telar::testing::Case case_scroll{"nvim_frames.scroll_is_replayed", scrollIsReplayed};
  const telar::testing::Case case_removed{"nvim_frames.removed_grids_are_forgotten", removedGridsAreForgotten};
  const telar::testing::Case case_large{"nvim_frames.large_grid_crosses_in_several_messages", largeGridCrossesInSeveralMessages};
  const telar::testing::Case case_cursor{"nvim_frames.cursor_and_mode", cursorAndMode};

}
