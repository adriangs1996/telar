export module telar.wire.nvim;

// The editor pane: a Neovim the runtime starts and draws for the client, grid by grid.

import std;
import telar.wire.vocabulary;
import telar.wire.editor;

// The schemas specialize `MessageSchema`, which telar.wire.vocabulary declares in its global
// fragment; naming the template here keeps it reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

// Declared in the global module, with the vocabulary these schemas build on, so the module's
// implementation unit defines their members there too.
// NOLINTBEGIN(misc-use-internal-linkage): exported, and declared in the global module for nvim.cpp.
export extern "C++" {
  namespace telar {

    // The byte and count limits of the editor's messages.
    inline constexpr std::size_t max_nvim_files = 64;
    inline constexpr std::size_t max_nvim_path_bytes = 4096;
    inline constexpr std::size_t max_nvim_input_bytes = 65536;
    inline constexpr std::size_t max_nvim_paste_bytes = std::size_t{1024} * 1024;
    inline constexpr std::size_t max_nvim_grid_spans = 2048;
    inline constexpr std::size_t max_nvim_scrolls = 64;
    inline constexpr std::size_t max_nvim_removed_grids = 256;
    inline constexpr std::size_t max_nvim_mode_bytes = 64;
    // A cursor that covers its whole cell, in hundredths.
    inline constexpr Byte max_nvim_cursor_percentage = 100;
    // The native surfaces: the command line, the completion menu, the messages and the tabs.
    inline constexpr std::size_t max_nvim_line_bytes = std::size_t{16} * 1024;
    inline constexpr std::size_t max_nvim_label_bytes = 512;
    inline constexpr std::size_t max_nvim_menu_items = 512;
    inline constexpr std::size_t max_nvim_messages = 32;
    inline constexpr std::size_t max_nvim_tabs = 128;
    inline constexpr std::size_t max_nvim_choices = 1024;
    // Every side of a float bordered: top 1, right 2, bottom 4 and left 8.
    inline constexpr Byte max_nvim_border = 15;

    // Text that Neovim, or what runs in it, wrote: bounded, and otherwise taken as it comes. A
    // client reads it as untrusted bytes that may not be UTF-8.
    template <std::size_t Maximum>
    using NvimText = SizedText<u16, Maximum, true, TextRule::opaque>;

    // Opens an editor pane on `files` in `cwd`: beside the panes of the location's tab, or in a
    // tab of its own in the location's workspace. Answered as CreatePane or CreateTab is, after
    // a PaneKindNotice that says the pane is an editor.
    struct CreateNvimPane {
      std::uint64_t request_id{};
      TabLocation location{};
      bool new_tab{};
      TerminalSize size{};
      std::string_view cwd;
      std::span<const std::string_view> files;
      // Where the cursor starts in the first file, counted from one; zero leaves it to Neovim.
      std::uint32_t line{};
      std::uint32_t column{};
    };

    template <>
    struct MessageSchema<CreateNvimPane>
        : Schema<
              Direction::client,
              ClientTag::create_nvim_pane,
              Field<&CreateNvimPane::request_id, NonzeroU64, "request_id">,
              Field<&CreateNvimPane::location, ValueCodec<TabLocation>, "location">,
              Field<&CreateNvimPane::new_tab, BoolByte, "new_tab">,
              Field<&CreateNvimPane::size, ValueCodec<TerminalSize>, "size">,
              Field<&CreateNvimPane::cwd, Text16<max_nvim_path_bytes>, "cwd">,
              Field<&CreateNvimPane::files, CountedSpan<u16, Text16<max_nvim_path_bytes, false>, max_nvim_files>, "files">,
              Field<&CreateNvimPane::line, u32, "line">,
              Field<&CreateNvimPane::column, u32, "column">> {};

    // Keys typed into an editor pane, in Neovim's own notation: `<C-w>`, `<LT>` for a literal `<`.
    struct NvimInput {
      std::uint64_t pane_id{};
      std::span<const Byte> keys;
    };

    template <>
    struct MessageSchema<NvimInput> : Schema<Direction::client, ClientTag::nvim_input, Field<&NvimInput::pane_id, NonzeroU64, "pane_id">, Field<&NvimInput::keys, TailBytes<max_nvim_input_bytes, 1>, "keys">> {};

    // Text pasted into an editor pane, which Neovim inserts as one change.
    struct NvimPaste {
      std::uint64_t pane_id{};
      std::span<const Byte> text;
    };

    template <>
    struct MessageSchema<NvimPaste> : Schema<Direction::client, ClientTag::nvim_paste, Field<&NvimPaste::pane_id, NonzeroU64, "pane_id">, Field<&NvimPaste::text, TailBytes<max_nvim_paste_bytes, 1>, "text">> {};

    enum class NvimMouseButton : Byte {
      left,
      right,
      middle,
      wheel,
      move,
    };

    enum class NvimMouseAction : Byte {
      press,
      drag,
      release,
      up,
      down,
      left,
      right,
    };

    // The modifier keys held with a mouse event, as bits of NvimMouse::modifiers.
    inline constexpr Byte nvim_mouse_shift = 1;
    inline constexpr Byte nvim_mouse_control = 2;
    inline constexpr Byte nvim_mouse_alt = 4;
    inline constexpr Byte nvim_mouse_command = 8;
    inline constexpr Byte nvim_mouse_modifiers = 15;

    // A mouse event on a cell of one of the pane's grids.
    struct NvimMouse {
      std::uint64_t pane_id{};
      std::uint32_t grid{};
      std::uint16_t row{};
      std::uint16_t column{};
      NvimMouseButton button{};
      NvimMouseAction action{};
      Byte modifiers{};
    };

    template <>
    struct MessageSchema<NvimMouse>
        : Schema<
              Direction::client,
              ClientTag::nvim_mouse,
              Field<&NvimMouse::pane_id, NonzeroU64, "pane_id">,
              Field<&NvimMouse::grid, u32, "grid">,
              Field<&NvimMouse::row, u16, "row">,
              Field<&NvimMouse::column, u16, "column">,
              Field<&NvimMouse::button, EnumByte<NvimMouseButton, std::to_underlying(NvimMouseButton::move)>, "button">,
              Field<&NvimMouse::action, EnumByte<NvimMouseAction, std::to_underlying(NvimMouseAction::right)>, "action">,
              Field<&NvimMouse::modifiers, BoundedInteger<u8, 0, nvim_mouse_modifiers>, "modifiers">> {};

    // Whether the window showing an editor pane has the keyboard's focus there.
    struct NvimFocus {
      std::uint64_t pane_id{};
      bool focused{};
    };

    template <>
    struct MessageSchema<NvimFocus> : Schema<Direction::client, ClientTag::nvim_focus, Field<&NvimFocus::pane_id, NonzeroU64, "pane_id">, Field<&NvimFocus::focused, BoolByte, "focused">> {};

    // What the user answered to the prompt `prompt_id` of an NvimPrompt: the choice at `index`
    // of a selection or the `text` of an input, or nothing when they dismissed it.
    struct NvimPromptReply {
      std::uint64_t pane_id{};
      std::uint64_t prompt_id{};
      bool accepted{};
      std::uint32_t index{};
      std::string_view text;
    };

    template <>
    struct MessageSchema<NvimPromptReply>
        : Schema<
              Direction::client,
              ClientTag::nvim_prompt_reply,
              Field<&NvimPromptReply::pane_id, NonzeroU64, "pane_id">,
              Field<&NvimPromptReply::prompt_id, NonzeroU64, "prompt_id">,
              Field<&NvimPromptReply::accepted, BoolByte, "accepted">,
              Field<&NvimPromptReply::index, u32, "index">,
              Field<&NvimPromptReply::text, NvimText<max_nvim_line_bytes>, "text">> {};

    // Where a file is shown in an editor: in the window that already shows it or else the
    // current one, in a window made under or beside the current one, or in a tab page.
    enum class NvimOpenIn : Byte {
      place,
      split,
      vertical_split,
      tab,
    };

    // Shows a file in an editor pane, with the cursor at `line` and `column` when they are not
    // zero. Both count from one.
    struct NvimOpen {
      std::uint64_t pane_id{};
      std::string_view path;
      std::uint32_t line{};
      std::uint32_t column{};
      NvimOpenIn in{};
    };

    template <>
    struct MessageSchema<NvimOpen>
        : Schema<Direction::client, ClientTag::nvim_open, Field<&NvimOpen::pane_id, NonzeroU64, "pane_id">, Field<&NvimOpen::path, Text16<max_nvim_path_bytes, false>, "path">, Field<&NvimOpen::line, u32, "line">, Field<&NvimOpen::column, u32, "column">, Field<&NvimOpen::in, EnumByte<NvimOpenIn, std::to_underlying(NvimOpenIn::tab)>, "in">> {};

    // Moves to the editor's window on a side of the current one. When it has none there the
    // runtime answers NvimNavigated, and the pane on that side is the client's to focus.
    struct NvimNavigate {
      std::uint64_t pane_id{};
      PaneDirection direction{};
    };

    template <>
    struct MessageSchema<NvimNavigate>
        : Schema<Direction::client, ClientTag::nvim_navigate, Field<&NvimNavigate::pane_id, NonzeroU64, "pane_id">, Field<&NvimNavigate::direction, EnumByte<PaneDirection, std::to_underlying(PaneDirection::down)>, "direction">> {};

    // The editor had no window on that side of its current one.
    struct NvimNavigated {
      std::uint64_t pane_id{};
      PaneDirection direction{};
    };

    template <>
    struct MessageSchema<NvimNavigated>
        : Schema<Direction::server, ServerTag::nvim_navigated, Field<&NvimNavigated::pane_id, NonzeroU64, "pane_id">, Field<&NvimNavigated::direction, EnumByte<PaneDirection, std::to_underlying(PaneDirection::down)>, "direction">> {};

    // Selects an item of the completion menu, counted from zero among all it has; `accept`
    // also takes it and closes the menu, as a click on it does.
    struct NvimMenuSelect {
      std::uint64_t pane_id{};
      std::uint32_t item{};
      bool accept{};
    };

    template <>
    struct MessageSchema<NvimMenuSelect>
        : Schema<Direction::client, ClientTag::nvim_menu_select, Field<&NvimMenuSelect::pane_id, NonzeroU64, "pane_id">, Field<&NvimMenuSelect::item, u32, "item">, Field<&NvimMenuSelect::accept, BoolByte, "accept">> {};

    // The editor's listed buffers whose names match `query`, best first, answered as
    // PathResults with an empty root. An empty query lists them most recently used first.
    struct NvimBuffers {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::string_view query;
      std::uint16_t limit{};
    };

    template <>
    struct MessageSchema<NvimBuffers>
        : Schema<Direction::client, ClientTag::nvim_buffers, Field<&NvimBuffers::request_id, NonzeroU64, "request_id">, Field<&NvimBuffers::pane_id, NonzeroU64, "pane_id">, Field<&NvimBuffers::query, SizedText<u16, FindPaths::maximum_query_bytes, true, TextRule::utf8_no_nul>, "query">, Field<&NvimBuffers::limit, BoundedInteger<u16, 1, FindPaths::maximum_limit>, "limit">> {};

    // Shows a file in a float of the editor that takes no focus, over the cells a picker leaves
    // for it, with `line` in view. Without columns or rows, the float is closed.
    struct NvimPreview {
      std::uint64_t pane_id{};
      std::string_view path;
      std::uint32_t line{};
      std::uint16_t row{};
      std::uint16_t column{};
      std::uint16_t columns{};
      std::uint16_t rows{};
    };

    template <>
    struct MessageSchema<NvimPreview>
        : Schema<Direction::client, ClientTag::nvim_preview, Field<&NvimPreview::pane_id, NonzeroU64, "pane_id">, Field<&NvimPreview::path, Text16<max_nvim_path_bytes>, "path">, Field<&NvimPreview::line, u32, "line">, Field<&NvimPreview::row, u16, "row">, Field<&NvimPreview::column, u16, "column">, Field<&NvimPreview::columns, u16, "columns">, Field<&NvimPreview::rows, u16, "rows">> {};

    // Fills the editor's quickfix list with places and opens it.
    struct NvimList {
      static constexpr std::size_t maximum_places = FindText::maximum_limit;

      std::uint64_t pane_id{};
      std::span<const TextMatch> places;
    };

    template <>
    struct MessageSchema<NvimList>
        : Schema<Direction::client, ClientTag::nvim_list, Field<&NvimList::pane_id, NonzeroU64, "pane_id">, Field<&NvimList::places, CountedSpan<u16, ValueCodec<TextMatch>, NvimList::maximum_places>, "places">> {};

    // What a picker lists: files by name, lines of files by their text, or the editor's buffers.
    enum class NvimPickSource : Byte {
      files,
      text,
      buffers,
    };

    // Something in the editor asked for a picker, as `:Telar files` does.
    struct NvimPick {
      std::uint64_t pane_id{};
      NvimPickSource source{};
    };

    template <>
    struct MessageSchema<NvimPick>
        : Schema<Direction::server, ServerTag::nvim_pick, Field<&NvimPick::pane_id, NonzeroU64, "pane_id">, Field<&NvimPick::source, EnumByte<NvimPickSource, std::to_underlying(NvimPickSource::buffers)>, "source">> {};

    // Something in the editor opened a link, as `gx` does: it opens where the person is, not
    // on the machine Neovim runs on.
    struct NvimLink {
      std::uint64_t pane_id{};
      std::string_view uri;
    };

    template <>
    struct MessageSchema<NvimLink> : Schema<Direction::server, ServerTag::nvim_link, Field<&NvimLink::pane_id, NonzeroU64, "pane_id">, Field<&NvimLink::uri, Text16<max_nvim_path_bytes, false>, "uri">> {};

    // How a grid is shown: not at all, as a window in the editor's layout, floating over it, in
    // a window of its own, or as the rows messages scroll in.
    enum class NvimPlacement : Byte {
      hidden,
      window,
      floating,
      external,
      message,
    };

    // A copy of whole or partial rows a client makes on the cells it has, in place of being
    // sent them again: more than zero rows moves the region's cells up.
    struct NvimScroll {
      std::uint16_t top{};
      std::uint16_t bottom{};
      std::uint16_t left{};
      std::uint16_t right{};
      std::int32_t rows{};
    };

    template <>
    struct BodySchema<NvimScroll>
        : Serializer<Field<&NvimScroll::top, u16, "top">, Field<&NvimScroll::bottom, u16, "bottom">, Field<&NvimScroll::left, u16, "left">, Field<&NvimScroll::right, u16, "right">, Field<&NvimScroll::rows, i32, "rows">> {};

    // One grid of an editor pane as of frame `frame_id`: where it is shown and the cells that
    // changed since the frame the client has. It takes effect with the NvimFrame of that id.
    struct NvimGrid {
      std::uint64_t pane_id{};
      std::uint64_t frame_id{};
      std::uint32_t grid{};
      std::uint16_t columns{};
      std::uint16_t rows{};
      NvimPlacement placement{};
      bool mouse_enabled{};
      // A window's place on the default grid, or a float's on the screen, in cells.
      std::int32_t row{};
      std::int32_t column{};
      std::uint16_t width{};
      std::uint16_t height{};
      std::uint32_t z_index{};
      std::uint32_t composition_index{};
      // Neovim's handle of the window the grid shows; zero for a grid that shows none.
      std::uint64_t window{};
      // The buffer lines the window shows and where its cursor is among them.
      std::uint32_t top_line{};
      std::uint32_t bottom_line{};
      std::uint32_t cursor_line{};
      std::uint32_t cursor_column{};
      std::uint32_t line_count{};
      // The lines the window's top line has moved since the grid was made, summed.
      std::int64_t scrolled_lines{};
      // The cells at each edge that are the window's frame, not its text.
      std::uint16_t margin_top{};
      std::uint16_t margin_bottom{};
      std::uint16_t margin_left{};
      std::uint16_t margin_right{};
      // A float's frame as its window's configuration gives it: the sides Neovim draws a border
      // on, as top 1, right 2, bottom 4 and left 8, its title and its footer. A client draws
      // them itself, in place of the cells of those sides.
      Byte border{};
      std::string_view title;
      std::string_view footer;
      // Every row follows: the client forgets what the grid showed.
      bool full{};
      std::span<const NvimScroll> scrolls;
      // Runs of cells, each starting at a cell counted from the grid's first, row by row.
      std::span<const FrameSpan> spans;

      void validate() const;
    };

    template <>
    struct MessageSchema<NvimGrid>
        : Schema<
              Direction::server,
              ServerTag::nvim_grid,
              Field<&NvimGrid::pane_id, NonzeroU64, "pane_id">,
              Field<&NvimGrid::frame_id, NonzeroU64, "frame_id">,
              Field<&NvimGrid::grid, BoundedInteger<u32, 1>, "grid">,
              Field<&NvimGrid::columns, u16, "columns">,
              Field<&NvimGrid::rows, u16, "rows">,
              Field<&NvimGrid::placement, EnumByte<NvimPlacement, std::to_underlying(NvimPlacement::message)>, "placement">,
              Field<&NvimGrid::mouse_enabled, BoolByte, "mouse_enabled">,
              Field<&NvimGrid::row, i32, "row">,
              Field<&NvimGrid::column, i32, "column">,
              Field<&NvimGrid::width, u16, "width">,
              Field<&NvimGrid::height, u16, "height">,
              Field<&NvimGrid::z_index, u32, "z_index">,
              Field<&NvimGrid::composition_index, u32, "composition_index">,
              Field<&NvimGrid::window, u64, "window">,
              Field<&NvimGrid::top_line, u32, "top_line">,
              Field<&NvimGrid::bottom_line, u32, "bottom_line">,
              Field<&NvimGrid::cursor_line, u32, "cursor_line">,
              Field<&NvimGrid::cursor_column, u32, "cursor_column">,
              Field<&NvimGrid::line_count, u32, "line_count">,
              Field<&NvimGrid::scrolled_lines, i64, "scrolled_lines">,
              Field<&NvimGrid::margin_top, u16, "margin_top">,
              Field<&NvimGrid::margin_bottom, u16, "margin_bottom">,
              Field<&NvimGrid::margin_left, u16, "margin_left">,
              Field<&NvimGrid::margin_right, u16, "margin_right">,
              Field<&NvimGrid::border, BoundedInteger<u8, 0, max_nvim_border>, "border">,
              Field<&NvimGrid::title, NvimText<max_nvim_label_bytes>, "title">,
              Field<&NvimGrid::footer, NvimText<max_nvim_label_bytes>, "footer">,
              Field<&NvimGrid::full, BoolByte, "full">,
              Field<&NvimGrid::scrolls, CountedSpan<u8, ValueCodec<NvimScroll>, max_nvim_scrolls>, "scrolls">,
              Field<&NvimGrid::spans, CountedSpan<u16, ValueCodec<FrameSpan>, max_nvim_grid_spans>, "spans">> {};

    // Ends a frame of an editor pane: the NvimGrid messages of `frame_id` before it take effect
    // together. `base_frame_id` is the frame they change, zero for one that stands alone; a
    // client that has another asks for a snapshot.
    struct NvimFrame {
      std::uint64_t pane_id{};
      std::uint64_t frame_id{};
      std::uint64_t base_frame_id{};
      std::uint32_t cursor_grid{};
      std::uint16_t cursor_row{};
      std::uint16_t cursor_column{};
      bool cursor_visible{};
      CursorShape cursor_shape{};
      // How much of its cell a bar or an underline cursor covers, in hundredths.
      Byte cursor_percentage{};
      std::uint16_t blink_wait_ms{};
      std::uint16_t blink_on_ms{};
      std::uint16_t blink_off_ms{};
      // Neovim's name for the mode it is in: "normal", "insert", "cmdline_normal"...
      std::string_view mode;
      // The grids Neovim destroyed since the base frame.
      std::span<const std::uint32_t> removed;
    };

    template <>
    struct MessageSchema<NvimFrame>
        : Schema<
              Direction::server,
              ServerTag::nvim_frame,
              Field<&NvimFrame::pane_id, NonzeroU64, "pane_id">,
              Field<&NvimFrame::frame_id, NonzeroU64, "frame_id">,
              Field<&NvimFrame::base_frame_id, u64, "base_frame_id">,
              Field<&NvimFrame::cursor_grid, u32, "cursor_grid">,
              Field<&NvimFrame::cursor_row, u16, "cursor_row">,
              Field<&NvimFrame::cursor_column, u16, "cursor_column">,
              Field<&NvimFrame::cursor_visible, BoolByte, "cursor_visible">,
              Field<&NvimFrame::cursor_shape, EnumByte<CursorShape, std::to_underlying(CursorShape::hollow)>, "cursor_shape">,
              Field<&NvimFrame::cursor_percentage, BoundedInteger<u8, 0, max_nvim_cursor_percentage>, "cursor_percentage">,
              Field<&NvimFrame::blink_wait_ms, u16, "blink_wait_ms">,
              Field<&NvimFrame::blink_on_ms, u16, "blink_on_ms">,
              Field<&NvimFrame::blink_off_ms, u16, "blink_off_ms">,
              Field<&NvimFrame::mode, NvimText<max_nvim_mode_bytes>, "mode">,
              Field<&NvimFrame::removed, CountedSpan<u16, u32, max_nvim_removed_grids>, "removed">> {};

    // The surfaces below are Neovim's own, which a client draws natively in place of the cells
    // Neovim would have used. Each is sent with the frame `frame_id` that changed it, before the
    // NvimFrame that ends it, and takes effect with that frame.

    // The command line: `:`, a search, or the prompt of input(). Not visible, it is closed.
    struct NvimCmdline {
      std::uint64_t pane_id{};
      std::uint64_t frame_id{};
      bool visible{};
      // How deep it is nested: one for the command line, more for one opened from another.
      std::uint32_t level{};
      // The character that opened it, `:` `/` or `?`; zero for a prompt.
      Byte first{};
      // A character shown at the cursor while a key is awaited, zero for none.
      Byte special{};
      // Where the cursor is in `text`, in bytes, and how far the text is indented, in cells.
      std::uint32_t position{};
      std::uint32_t indent{};
      std::string_view prompt;
      std::string_view text;
      // The lines of a block above it, as a function being typed has, each ended by a newline.
      std::string_view block;
    };

    template <>
    struct MessageSchema<NvimCmdline>
        : Schema<
              Direction::server,
              ServerTag::nvim_cmdline,
              Field<&NvimCmdline::pane_id, NonzeroU64, "pane_id">,
              Field<&NvimCmdline::frame_id, NonzeroU64, "frame_id">,
              Field<&NvimCmdline::visible, BoolByte, "visible">,
              Field<&NvimCmdline::level, u32, "level">,
              Field<&NvimCmdline::first, u8, "first">,
              Field<&NvimCmdline::special, u8, "special">,
              Field<&NvimCmdline::position, u32, "position">,
              Field<&NvimCmdline::indent, u32, "indent">,
              Field<&NvimCmdline::prompt, NvimText<max_nvim_label_bytes>, "prompt">,
              Field<&NvimCmdline::text, NvimText<max_nvim_line_bytes>, "text">,
              Field<&NvimCmdline::block, NvimText<max_nvim_line_bytes>, "block">> {};

    // One entry of the completion menu: the word, what kind of thing it is, and a note.
    struct NvimMenuItem {
      std::string_view word;
      std::string_view kind;
      std::string_view menu;
    };

    template <>
    struct BodySchema<NvimMenuItem>
        : Serializer<Field<&NvimMenuItem::word, NvimText<max_nvim_label_bytes>, "word">, Field<&NvimMenuItem::kind, NvimText<max_nvim_label_bytes>, "kind">, Field<&NvimMenuItem::menu, NvimText<max_nvim_label_bytes>, "menu">> {};

    // The completion menu. `items` are sent when they changed; a message that only moves the
    // selection leaves them as the client has them, and says so in `keeps_items`.
    struct NvimPopupMenu {
      std::uint64_t pane_id{};
      std::uint64_t frame_id{};
      bool visible{};
      bool keeps_items{};
      // The item selected, -1 for none.
      std::int32_t selected{};
      // The cell the menu hangs from: on a grid, or on the command line when `grid` is -1,
      // where `column` is a byte of its text.
      std::int32_t grid{};
      std::int32_t row{};
      std::int32_t column{};
      // The index of the first of `items` among all the menu has, and how many it has.
      std::uint32_t first{};
      std::uint32_t total{};
      std::span<const NvimMenuItem> items;
    };

    template <>
    struct MessageSchema<NvimPopupMenu>
        : Schema<
              Direction::server,
              ServerTag::nvim_popup_menu,
              Field<&NvimPopupMenu::pane_id, NonzeroU64, "pane_id">,
              Field<&NvimPopupMenu::frame_id, NonzeroU64, "frame_id">,
              Field<&NvimPopupMenu::visible, BoolByte, "visible">,
              Field<&NvimPopupMenu::keeps_items, BoolByte, "keeps_items">,
              Field<&NvimPopupMenu::selected, i32, "selected">,
              Field<&NvimPopupMenu::grid, i32, "grid">,
              Field<&NvimPopupMenu::row, i32, "row">,
              Field<&NvimPopupMenu::column, i32, "column">,
              Field<&NvimPopupMenu::first, u32, "first">,
              Field<&NvimPopupMenu::total, u32, "total">,
              Field<&NvimPopupMenu::items, CountedSpan<u16, ValueCodec<NvimMenuItem>, max_nvim_menu_items>, "items">> {};

    // What a message is, which says how a client shows it.
    enum class NvimMessageKind : Byte {
      plain,
      error,
      warning,
      confirm,
      progress,
      search_count,
      // The output of a command that lists: :ls, :set, a shell command.
      list,
    };

    struct NvimMessageItem {
      // Neovim's id for it: a message with the id of one shown replaces it.
      std::uint64_t id{};
      NvimMessageKind kind{};
      std::string_view text;
    };

    template <>
    struct BodySchema<NvimMessageItem>
        : Serializer<Field<&NvimMessageItem::id, u64, "id">, Field<&NvimMessageItem::kind, EnumByte<NvimMessageKind, std::to_underlying(NvimMessageKind::list)>, "kind">, Field<&NvimMessageItem::text, NvimText<max_nvim_line_bytes>, "text">> {};

    // The messages Neovim shows now, oldest first, and the three it keeps apart: the mode
    // ("-- INSERT --"), the keys of a command being typed, and the ruler.
    struct NvimMessageList {
      std::uint64_t pane_id{};
      std::uint64_t frame_id{};
      std::string_view mode;
      std::string_view command;
      std::string_view ruler;
      std::span<const NvimMessageItem> messages;
    };

    template <>
    struct MessageSchema<NvimMessageList>
        : Schema<
              Direction::server,
              ServerTag::nvim_message_list,
              Field<&NvimMessageList::pane_id, NonzeroU64, "pane_id">,
              Field<&NvimMessageList::frame_id, NonzeroU64, "frame_id">,
              Field<&NvimMessageList::mode, NvimText<max_nvim_label_bytes>, "mode">,
              Field<&NvimMessageList::command, NvimText<max_nvim_label_bytes>, "command">,
              Field<&NvimMessageList::ruler, NvimText<max_nvim_label_bytes>, "ruler">,
              Field<&NvimMessageList::messages, CountedSpan<u8, ValueCodec<NvimMessageItem>, max_nvim_messages>, "messages">> {};

    // A tab page or a buffer, by Neovim's handle and the name it shows.
    struct NvimTab {
      std::uint64_t handle{};
      std::string_view name;
    };

    template <>
    struct BodySchema<NvimTab> : Serializer<Field<&NvimTab::handle, u64, "handle">, Field<&NvimTab::name, NvimText<max_nvim_label_bytes>, "name">> {};

    // Neovim's tab pages and listed buffers, and which of each is current.
    struct NvimTabLine {
      std::uint64_t pane_id{};
      std::uint64_t frame_id{};
      std::uint64_t current_tab{};
      std::uint64_t current_buffer{};
      std::span<const NvimTab> tabs;
      std::span<const NvimTab> buffers;
    };

    template <>
    struct MessageSchema<NvimTabLine>
        : Schema<
              Direction::server,
              ServerTag::nvim_tab_line,
              Field<&NvimTabLine::pane_id, NonzeroU64, "pane_id">,
              Field<&NvimTabLine::frame_id, NonzeroU64, "frame_id">,
              Field<&NvimTabLine::current_tab, u64, "current_tab">,
              Field<&NvimTabLine::current_buffer, u64, "current_buffer">,
              Field<&NvimTabLine::tabs, CountedSpan<u8, ValueCodec<NvimTab>, max_nvim_tabs>, "tabs">,
              Field<&NvimTabLine::buffers, CountedSpan<u8, ValueCodec<NvimTab>, max_nvim_tabs>, "buffers">> {};

    enum class NvimPromptKind : Byte {
      // No prompt: the one the client shows, if any, was answered elsewhere or withdrawn.
      none,
      // One of `choices`, as vim.ui.select asks.
      select,
      // A line of text that starts as `initial`, as vim.ui.input asks.
      input,
    };

    // What something in Neovim asks the user through vim.ui: a client shows it natively and
    // answers with NvimPromptReply. `serial` grows with every change, so a client tells a new
    // prompt from the one it shows.
    struct NvimPrompt {
      std::uint64_t pane_id{};
      std::uint64_t serial{};
      std::uint64_t prompt_id{};
      NvimPromptKind kind{};
      std::string_view title;
      std::string_view initial;
      std::span<const std::string_view> choices;
    };

    template <>
    struct MessageSchema<NvimPrompt>
        : Schema<
              Direction::server,
              ServerTag::nvim_prompt,
              Field<&NvimPrompt::pane_id, NonzeroU64, "pane_id">,
              Field<&NvimPrompt::serial, NonzeroU64, "serial">,
              Field<&NvimPrompt::prompt_id, u64, "prompt_id">,
              Field<&NvimPrompt::kind, EnumByte<NvimPromptKind, std::to_underlying(NvimPromptKind::input)>, "kind">,
              Field<&NvimPrompt::title, NvimText<max_nvim_label_bytes>, "title">,
              Field<&NvimPrompt::initial, NvimText<max_nvim_line_bytes>, "initial">,
              Field<&NvimPrompt::choices, CountedSpan<u16, NvimText<max_nvim_label_bytes>, max_nvim_choices>, "choices">> {};

  }
}
// NOLINTEND(misc-use-internal-linkage)
