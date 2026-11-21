module telar.runtime.nvim.redraw;

import std;
import telar.tbc;
import telar.msgpack;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.runtime.nvim.screen;

namespace telar::runtime {

  namespace {

    // The events of one notification, read front to back: its batches, each batch's name and the
    // parameter tuples that follow it. What it hands out views the notification's bytes, so it
    // outlives the reads that come after.
    class Arguments {
    public:
      explicit Arguments(tbc::val_a<std::span<const std::uint8_t>> notification) noexcept
          : reader_(notification) {}

      bool batches(std::uint32_t& count) noexcept {
        return reader_.array(count);
      }

      // The name of the next batch, a `[name, parameters...]`, and how many items it has.
      tbc::val_a<ds::Option<std::string_view>> batch(std::uint32_t& items) noexcept {
        if (!reader_.array(items) || items == 0) {
          reader_.fail();
          return ds::none;
        }

        return reader_.string();
      }

      // Starts the next tuple of parameters.
      bool begin() noexcept {
        return reader_.array(left_);
      }

      // Skips what the tuple has that this build does not read.
      bool end() noexcept {
        while (left_ > 0) {
          --left_;
          if (!reader_.skip()) {
            return false;
          }
        }

        return !reader_.failed();
      }

      bool integer(std::int64_t& value) noexcept {
        return take() && reader_.integer(value);
      }

      // An integer no less than zero that 32 bits hold.
      bool count(std::uint32_t& value) noexcept {
        std::int64_t wide = 0;

        if (!integer(wide) || !std::in_range<std::uint32_t>(wide)) {
          return reader_.fail();
        }

        value = static_cast<std::uint32_t>(wide);
        return true;
      }

      bool number(double& value) noexcept {
        return take() && reader_.number(value);
      }

      bool boolean(bool& value) noexcept {
        return take() && reader_.boolean(value);
      }

      tbc::val_a<ds::Option<std::string_view>> string() noexcept {
        if (!take()) {
          return ds::none;
        }

        return reader_.string();
      }

      bool array(std::uint32_t& items) noexcept {
        return take() && reader_.array(items);
      }

      bool map(std::uint32_t& pairs) noexcept {
        return take() && reader_.map(pairs);
      }

      // A buffer, window or tab page: an extension holding its number, or the number itself.
      bool handle(std::uint64_t& value) noexcept {
        if (!take()) {
          return false;
        }

        const auto token = reader_.value();

        return token && (handleOf(*token, value) || reader_.fail());
      }

      static bool handleOf(const msgpack::Token& token, std::uint64_t& value) noexcept {
        if (token.kind == msgpack::Kind::unsigned_integer) {
          value = token.bits;
          return true;
        }

        if (token.kind != msgpack::Kind::extension) {
          return false;
        }

        msgpack::Reader inner{token.bytes};

        return inner.unsignedInteger(value);
      }

      // The reader itself, for a parameter that holds more than one value.
      [[nodiscard]] msgpack::Reader& reader() noexcept {
        return reader_;
      }

      // Whether the tuple has a parameter left to read.
      [[nodiscard]] bool more() const noexcept {
        return left_ > 0;
      }

      [[nodiscard]] bool failed() const noexcept {
        return reader_.failed();
      }

    private:
      bool take() noexcept {
        if (left_ == 0) {
          return reader_.fail();
        }

        --left_;
        return true;
      }

      tbc::val_a<msgpack::Reader> reader_;
      std::uint32_t left_ = 0;
    };

    // What an event changes and where it reports.
    struct Context {
      NvimScreen& screen;
      NvimRedraw& outcome;
      ConcurrentMemory& memory;
    };

    constexpr std::size_t prompt_bytes = 1024;
    constexpr std::int64_t rgb_last = 0xff'ffff;

    constexpr std::uint16_t highlightId(std::int64_t id) noexcept {
      return id < 0 || std::cmp_greater_equal(id, NvimLimits::highlights) ? std::uint16_t{0} : static_cast<std::uint16_t>(id);
    }

    constexpr std::uint32_t color(std::int64_t value) noexcept {
      return value < 0 || value > rgb_last ? NvimHighlight::unset : static_cast<std::uint32_t>(value);
    }

    constexpr std::uint16_t extent(std::uint32_t value) noexcept {
      return static_cast<std::uint16_t>(std::min<std::uint32_t>(value, std::numeric_limits<std::uint16_t>::max()));
    }

    // A whole number clamped to what 32 signed bits hold between `lowest` and their largest.
    constexpr std::int32_t clamped(std::int64_t value, std::int64_t lowest) noexcept {
      return static_cast<std::int32_t>(std::clamp<std::int64_t>(value, lowest, std::numeric_limits<std::int32_t>::max()));
    }

    // A value of a map that is neither an array nor a map: the only ones the events' maps hold.
    tbc::val_a<ds::Option<msgpack::Token>> scalar(tbc::holds<msgpack::Reader&, tbc::lt::a> reader) noexcept {
      const auto value = reader.value();
      if (!value || value->kind == msgpack::Kind::array || value->kind == msgpack::Kind::map) {
        reader.fail();
        return ds::none;
      }

      return *value;
    }

    // The items of an array: how many it has and how many of them were read.
    struct Parts {
      std::uint32_t total = 0;
      std::uint32_t read = 0;
    };

    // Skips the items of an array that this build does not read.
    bool skipExtra(msgpack::Reader& reader, Parts parts) noexcept {
      for (auto extra = parts.read; extra < parts.total; ++extra) {
        if (!reader.skip()) {
          return false;
        }
      }

      return true;
    }

    // The text of one cell of a grid_line, a `[text, highlight?, repeat?]` whose highlight and
    // repeat go to `run`: the highlight stays the cell before's when it names none.
    tbc::val_a<ds::Option<std::string_view>> cell(tbc::holds<msgpack::Reader&, tbc::lt::a> reader, NvimRun& run) noexcept {
      std::uint32_t parts = 0;
      std::int64_t repeat = 1;

      if (!reader.array(parts) || parts == 0) {
        reader.fail();
        return ds::none;
      }

      const auto text = reader.string();
      if (!text) {
        return ds::none;
      }

      if (parts > 1) {
        std::int64_t id = 0;

        reader.integer(id);
        run.highlight = highlightId(id);
      }

      if (parts > 2) {
        reader.integer(repeat);
      }

      if (repeat < 0 || std::cmp_greater(repeat, NvimLimits::columns) || !skipExtra(reader, {.total = parts, .read = 3})) {
        reader.fail();
        return ds::none;
      }

      run.repeat = static_cast<std::uint32_t>(repeat);
      return *text;
    }

    bool gridLine(Context& context, Arguments& arguments) {
      std::uint32_t grid = 0;
      NvimPoint start;
      std::uint32_t cells = 0;

      if (!arguments.count(grid) || !arguments.count(start.row) || !arguments.count(start.column) || !arguments.array(cells) || !context.screen.line(grid, start)) {
        return false;
      }

      NvimRun run;

      for (std::uint32_t index = 0; index < cells; ++index) {
        const auto text = cell(arguments.reader(), run);

        if (!text || !context.screen.put(*text, run)) {
          return false;
        }
      }

      return true;
    }

    struct Flag {
      std::string_view name;
      std::uint16_t bit = 0;
    };

    constexpr ds::Array<Flag, 13> highlight_flags{
        Flag{.name = "bold", .bit = NvimHighlight::bold},
        Flag{.name = "italic", .bit = NvimHighlight::italic},
        Flag{.name = "reverse", .bit = NvimHighlight::reverse},
        Flag{.name = "strikethrough", .bit = NvimHighlight::strikethrough},
        Flag{.name = "underline", .bit = NvimHighlight::underline},
        Flag{.name = "undercurl", .bit = NvimHighlight::undercurl},
        Flag{.name = "underdouble", .bit = NvimHighlight::underdouble},
        Flag{.name = "underdotted", .bit = NvimHighlight::underdotted},
        Flag{.name = "underdashed", .bit = NvimHighlight::underdashed},
        Flag{.name = "dim", .bit = NvimHighlight::dim},
        Flag{.name = "blink", .bit = NvimHighlight::blink},
        Flag{.name = "conceal", .bit = NvimHighlight::conceal},
        Flag{.name = "overline", .bit = NvimHighlight::overline},
    };

    void highlightField(NvimScreen& screen, NvimHighlight& highlight, std::string_view key, const msgpack::Token& value) {
      if (key == "foreground") {
        highlight.foreground = color(value.integer());
      } else if (key == "background") {
        highlight.background = color(value.integer());
      } else if (key == "special") {
        highlight.special = color(value.integer());
      } else if (key == "blend") {
        highlight.blend = static_cast<std::uint8_t>(std::clamp<std::int64_t>(value.integer(), 0, NvimHighlight::opaque_blend));
      } else if (key == "url") {
        highlight.link = screen.link(value.text());
      } else if (value.kind == msgpack::Kind::boolean && value.boolean()) {
        for (const auto& flag : highlight_flags) {
          if (flag.name == key) {
            highlight.attributes |= flag.bit;
          }
        }
      }
    }

    bool highlightDefine(Context& context, Arguments& arguments) {
      std::uint32_t id = 0;
      std::uint32_t pairs = 0;
      NvimHighlight highlight;

      // The RGB attributes are the map that follows the id.
      if (!arguments.count(id) || !arguments.map(pairs)) {
        return false;
      }

      for (std::uint32_t index = 0; index < pairs; ++index) {
        const auto key = arguments.reader().string();
        const auto value = scalar(arguments.reader());

        if (!key || !value) {
          return false;
        }

        highlightField(context.screen, highlight, *key, *value);
      }

      return context.screen.highlight(id, highlight);
    }

    bool defaultColors(Context& context, Arguments& arguments) {
      std::int64_t foreground = 0;
      std::int64_t background = 0;
      std::int64_t special = 0;

      if (!arguments.integer(foreground) || !arguments.integer(background) || !arguments.integer(special)) {
        return false;
      }

      context.screen.defaultColors(color(foreground), color(background), color(special));
      return true;
    }

    bool gridResize(Context& context, Arguments& arguments) {
      std::uint32_t grid = 0;
      NvimExtent size;

      return arguments.count(grid) && arguments.count(size.columns) && arguments.count(size.rows) && context.screen.resize(grid, size);
    }

    bool gridClear(Context& context, Arguments& arguments) {
      std::uint32_t grid = 0;

      if (!arguments.count(grid)) {
        return false;
      }

      context.screen.clear(grid);
      return true;
    }

    bool gridDestroy(Context& context, Arguments& arguments) {
      std::uint32_t grid = 0;

      if (!arguments.count(grid)) {
        return false;
      }

      context.screen.destroy(grid);
      return true;
    }

    bool gridCursor(Context& context, Arguments& arguments) {
      std::uint32_t grid = 0;
      NvimPoint place;

      if (!arguments.count(grid) || !arguments.count(place.row) || !arguments.count(place.column)) {
        return false;
      }

      context.screen.moveCursor(grid, place);
      return true;
    }

    bool gridScroll(Context& context, Arguments& arguments) {
      std::uint32_t grid = 0;
      std::uint32_t top = 0;
      std::uint32_t bottom = 0;
      std::uint32_t left = 0;
      std::uint32_t right = 0;
      std::int64_t rows = 0;

      if (!arguments.count(grid) || !arguments.count(top) || !arguments.count(bottom) || !arguments.count(left) || !arguments.count(right) || !arguments.integer(rows)) {
        return false;
      }

      if (bottom > NvimLimits::rows || right > NvimLimits::columns || std::cmp_greater(std::abs(rows), NvimLimits::rows)) {
        return false;
      }

      return context.screen.scroll(
          grid,
          {
              .top = static_cast<std::uint16_t>(top),
              .bottom = static_cast<std::uint16_t>(bottom),
              .left = static_cast<std::uint16_t>(left),
              .right = static_cast<std::uint16_t>(right),
              .rows = static_cast<std::int16_t>(rows),
          }
      );
    }

    bool windowPosition(Context& context, Arguments& arguments) {
      std::uint32_t id = 0;
      std::uint64_t window = 0;
      std::int64_t row = 0;
      std::int64_t column = 0;
      std::uint32_t width = 0;
      std::uint32_t height = 0;

      if (!arguments.count(id) || !arguments.handle(window) || !arguments.integer(row) || !arguments.integer(column) || !arguments.count(width) || !arguments.count(height)) {
        return false;
      }

      auto* grid = context.screen.place(id, NvimPlacement::window);
      if (grid == nullptr) {
        return false;
      }

      grid->window = window;
      grid->start_row = static_cast<std::int32_t>(std::clamp<std::int64_t>(row, 0, NvimLimits::rows));
      grid->start_column = static_cast<std::int32_t>(std::clamp<std::int64_t>(column, 0, NvimLimits::columns));
      grid->width = extent(width);
      grid->height = extent(height);
      return true;
    }

    constexpr NvimAnchor anchorOf(std::string_view name) noexcept {
      if (name == "NE") {
        return NvimAnchor::north_east;
      }

      if (name == "SW") {
        return NvimAnchor::south_west;
      }

      return name == "SE" ? NvimAnchor::south_east : NvimAnchor::north_west;
    }

    // Where a float is anchored: the parameters of win_float_pos after its window.
    bool floatAnchor(Arguments& arguments, NvimGrid& grid) {
      const auto anchor = arguments.string();
      if (!anchor) {
        return false;
      }

      grid.anchor = anchorOf(*anchor);
      return arguments.count(grid.anchor_grid) && arguments.number(grid.anchor_row) && arguments.number(grid.anchor_column) && arguments.boolean(grid.mouse_enabled);
    }

    bool floatPosition(Context& context, Arguments& arguments) {
      std::uint32_t id = 0;
      std::uint64_t window = 0;
      std::int64_t screen_row = 0;
      std::int64_t screen_column = 0;

      if (!arguments.count(id) || !arguments.handle(window)) {
        return false;
      }

      auto* grid = context.screen.place(id, NvimPlacement::floating);

      // Neovim 0.11 added the order it composes floats in and where it put this one.
      if (grid == nullptr || !floatAnchor(arguments, *grid) || !arguments.count(grid->z_index) || !arguments.count(grid->composition_index) || !arguments.integer(screen_row) || !arguments.integer(screen_column)) {
        return false;
      }

      grid->window = window;
      grid->start_row = static_cast<std::int32_t>(std::clamp<std::int64_t>(screen_row, -std::int64_t{NvimLimits::rows}, NvimLimits::rows));
      grid->start_column = static_cast<std::int32_t>(std::clamp<std::int64_t>(screen_column, -std::int64_t{NvimLimits::columns}, NvimLimits::columns));
      grid->width = grid->columns;
      grid->height = grid->rows;
      return true;
    }

    bool externalPosition(Context& context, Arguments& arguments) {
      std::uint32_t id = 0;
      std::uint64_t window = 0;

      if (!arguments.count(id) || !arguments.handle(window)) {
        return false;
      }

      auto* grid = context.screen.place(id, NvimPlacement::external);
      if (grid == nullptr) {
        return false;
      }

      grid->window = window;
      return true;
    }

    bool windowHide(Context& context, Arguments& arguments) {
      std::uint32_t grid = 0;

      if (!arguments.count(grid)) {
        return false;
      }

      context.screen.hide(grid);
      return true;
    }

    bool messagePosition(Context& context, Arguments& arguments) {
      std::uint32_t id = 0;
      std::uint32_t row = 0;
      bool scrolled = false;
      std::uint32_t z_index = 0;
      std::uint32_t composition_index = 0;

      if (!arguments.count(id) || !arguments.count(row) || !arguments.boolean(scrolled) || !arguments.string() || !arguments.count(z_index) || !arguments.count(composition_index)) {
        return false;
      }

      auto* grid = context.screen.place(id, NvimPlacement::message);
      if (grid == nullptr) {
        return false;
      }

      grid->start_row = static_cast<std::int32_t>(std::min<std::uint32_t>(row, NvimLimits::rows));
      grid->start_column = 0;
      grid->z_index = z_index;
      grid->composition_index = composition_index;
      return true;
    }

    bool windowViewport(Context& context, Arguments& arguments) {
      std::uint32_t id = 0;
      std::uint64_t window = 0;
      NvimViewport viewport;
      std::int64_t scroll_delta = 0;

      if (!arguments.count(id) || !arguments.handle(window) || !arguments.count(viewport.top_line) || !arguments.count(viewport.bottom_line) || !arguments.count(viewport.cursor_line) || !arguments.count(viewport.cursor_column) || !arguments.count(viewport.line_count) || !arguments.integer(scroll_delta)) {
        return false;
      }

      context.screen.viewport(id, viewport, scroll_delta);
      return true;
    }

    bool windowMargins(Context& context, Arguments& arguments) {
      std::uint32_t id = 0;
      std::uint64_t window = 0;
      std::uint32_t top = 0;
      std::uint32_t bottom = 0;
      std::uint32_t left = 0;
      std::uint32_t right = 0;

      if (!arguments.count(id) || !arguments.handle(window) || !arguments.count(top) || !arguments.count(bottom) || !arguments.count(left) || !arguments.count(right)) {
        return false;
      }

      context.screen.margins(id, {.top = extent(top), .bottom = extent(bottom), .left = extent(left), .right = extent(right)});
      return true;
    }

    constexpr NvimCursorShape cursorShape(std::string_view name) noexcept {
      if (name == "horizontal") {
        return NvimCursorShape::horizontal;
      }

      return name == "vertical" ? NvimCursorShape::vertical : NvimCursorShape::block;
    }

    void modeField(NvimMode& mode, std::string_view key, const msgpack::Token& value) noexcept {
      const auto milliseconds = static_cast<std::uint16_t>(std::clamp<std::int64_t>(value.integer(), 0, std::numeric_limits<std::uint16_t>::max()));

      if (key == "cursor_shape") {
        mode.shape = cursorShape(value.text());
      } else if (key == "cell_percentage") {
        mode.cell_percentage = static_cast<std::uint8_t>(std::clamp<std::int64_t>(value.integer(), 0, NvimMode::whole_cell));
      } else if (key == "blinkwait") {
        mode.blink_wait = milliseconds;
      } else if (key == "blinkon") {
        mode.blink_on = milliseconds;
      } else if (key == "blinkoff") {
        mode.blink_off = milliseconds;
      } else if (key == "attr_id") {
        mode.attribute = highlightId(value.integer());
      }
    }

    bool modeOf(msgpack::Reader& reader, NvimMode& mode) noexcept {
      std::uint32_t pairs = 0;

      if (!reader.map(pairs)) {
        return false;
      }

      for (std::uint32_t pair = 0; pair < pairs; ++pair) {
        const auto key = reader.string();
        const auto value = scalar(reader);

        if (!key || !value) {
          return false;
        }

        modeField(mode, *key, *value);
      }

      return true;
    }

    bool modeInfo(Context& context, Arguments& arguments) {
      bool styled = false;
      std::uint32_t modes = 0;

      if (!arguments.boolean(styled) || !arguments.array(modes)) {
        return false;
      }

      for (std::uint32_t index = 0; index < modes; ++index) {
        NvimMode mode;

        if (!modeOf(arguments.reader(), mode) || (index < NvimLimits::modes && !context.screen.mode(index, mode))) {
          return false;
        }
      }

      context.screen.truncateModes(modes);
      return true;
    }

    bool modeChange(Context& context, Arguments& arguments) {
      const auto mode = arguments.string();
      std::uint32_t index = 0;

      if (!mode || !arguments.count(index)) {
        return false;
      }

      context.screen.currentMode(index, *mode);
      return true;
    }

    bool busyStart(Context& context, Arguments& /*arguments*/) {
      context.screen.hideCursor(true);
      return true;
    }

    bool busyStop(Context& context, Arguments& /*arguments*/) {
      context.screen.hideCursor(false);
      return true;
    }

    bool mouseOn(Context& context, Arguments& /*arguments*/) {
      context.screen.mouse(true);
      return true;
    }

    bool mouseOff(Context& context, Arguments& /*arguments*/) {
      context.screen.mouse(false);
      return true;
    }

    bool changeDirectory(Context& context, Arguments& arguments) {
      const auto path = arguments.string();
      if (!path) {
        return false;
      }

      context.screen.directory(*path);
      return true;
    }

    bool setTitle(Context& context, Arguments& arguments) {
      const auto title = arguments.string();
      if (!title) {
        return false;
      }

      context.screen.title(*title);
      return true;
    }

    bool bell(Context& context, Arguments& /*arguments*/) {
      context.outcome.bell = true;
      return true;
    }

    bool flush(Context& context, Arguments& /*arguments*/) {
      context.screen.flush();
      ++context.outcome.flushes;
      return true;
    }

    // Reads one `[attribute, text, group]` chunk into a surface's text. Older Neovim sends the
    // attributes themselves, a map, where newer ones send their id.
    bool chunk(msgpack::Reader& reader, NvimStyledText& text) {
      std::uint32_t parts = 0;

      if (!reader.array(parts) || parts < 2) {
        return false;
      }

      const auto attribute = reader.value();
      if (!attribute || attribute->kind == msgpack::Kind::array) {
        return false;
      }

      for (std::uint64_t value = 0; attribute->kind == msgpack::Kind::map && value < attribute->bits * 2; ++value) {
        if (!reader.skip()) {
          return false;
        }
      }

      const auto run = reader.string();
      if (!run || !skipExtra(reader, {.total = parts, .read = 2})) {
        return false;
      }

      text.append(*run, attribute->kind == msgpack::Kind::unsigned_integer ? highlightId(attribute->integer()) : std::uint16_t{0});
      return true;
    }

    bool chunks(msgpack::Reader& reader, std::uint32_t count, NvimStyledText& text) {
      for (std::uint32_t index = 0; index < count; ++index) {
        if (!chunk(reader, text)) {
          return false;
        }
      }

      return true;
    }

    bool content(Arguments& arguments, NvimStyledText& text) {
      std::uint32_t count = 0;

      text.clear();
      return arguments.array(count) && chunks(arguments.reader(), count, text);
    }

    bool commandLineShow(Context& context, Arguments& arguments) {
      auto& line = context.screen.commandLineMut();

      if (!content(arguments, line.content) || !arguments.count(line.position)) {
        return false;
      }

      const auto first = arguments.string();
      const auto prompt = arguments.string();

      if (!first || !prompt || !arguments.count(line.indent) || !arguments.count(line.level)) {
        return false;
      }

      line.first = first->empty() ? '\0' : first->front();
      line.prompt.assign(prompt->substr(0, prompt_bytes));
      line.special = 0;
      line.visible = true;
      return true;
    }

    bool commandLinePosition(Context& context, Arguments& arguments) {
      std::uint32_t position = 0;
      std::uint32_t level = 0;

      if (!arguments.count(position) || !arguments.count(level)) {
        return false;
      }

      auto& line = context.screen.commandLineMut();
      if (line.level == level) {
        line.position = position;
      }

      return true;
    }

    bool commandLineSpecial(Context& context, Arguments& arguments) {
      const auto character = arguments.string();
      bool shift = false;
      std::uint32_t level = 0;

      if (!character || !arguments.boolean(shift) || !arguments.count(level)) {
        return false;
      }

      auto& line = context.screen.commandLineMut();
      if (line.level == level) {
        line.special = character->empty() ? '\0' : character->front();
        line.special_shifts = shift;
      }

      return true;
    }

    bool commandLineHide(Context& context, Arguments& arguments) {
      std::uint32_t level = 0;

      if (!arguments.count(level)) {
        return false;
      }

      auto& line = context.screen.commandLineMut();
      if (line.level == level) {
        line.visible = false;
        line.content.clear();
        line.special = 0;
      }

      return true;
    }

    bool blockLine(msgpack::Reader& reader, std::uint32_t count, NvimStyledText& block) {
      if (!chunks(reader, count, block)) {
        return false;
      }

      block.append("\n", 0);
      return true;
    }

    bool commandLineBlockShow(Context& context, Arguments& arguments) {
      auto& line = context.screen.commandLineMut();
      std::uint32_t lines = 0;

      line.block.clear();
      if (!arguments.array(lines)) {
        return false;
      }

      for (std::uint32_t index = 0; index < lines; ++index) {
        std::uint32_t count = 0;

        if (!arguments.reader().array(count) || !blockLine(arguments.reader(), count, line.block)) {
          return false;
        }
      }

      return true;
    }

    bool commandLineBlockAppend(Context& context, Arguments& arguments) {
      std::uint32_t count = 0;

      return arguments.array(count) && blockLine(arguments.reader(), count, context.screen.commandLineMut().block);
    }

    bool commandLineBlockHide(Context& context, Arguments& /*arguments*/) {
      context.screen.commandLineMut().block.clear();
      return true;
    }

    // Keeps `text` in the storage of a surface and names where: nothing once the surface is full.
    NvimSlice keep(ds::Vec<char, ConcurrentMemory>& storage, std::string_view text) {
      const auto room = NvimLimits::surface_bytes - std::min(NvimLimits::surface_bytes, storage.size());
      const auto kept = text.substr(0, std::min(text.size(), room));
      const NvimSlice slice{.offset = static_cast<std::uint32_t>(storage.size()), .size = static_cast<std::uint32_t>(kept.size())};

      storage.extend(std::span<const char>{kept});
      return slice;
    }

    // One item of a completion: `[word, kind, menu, documentation]`.
    bool completionItem(msgpack::Reader& reader, NvimCompletion& completion) {
      std::uint32_t parts = 0;
      NvimCompletion::Item item;

      if (!reader.array(parts)) {
        return false;
      }

      for (auto* field : {&item.word, &item.kind, &item.menu, &item.info}) {
        if (parts == 0) {
          break;
        }

        const auto text = reader.string();
        if (!text) {
          return false;
        }

        --parts;
        *field = keep(completion.text, *text);
      }

      if (!skipExtra(reader, {.total = parts, .read = 0})) {
        return false;
      }

      if (completion.items.size() < NvimLimits::completion_items) {
        completion.items.push(item);
      }

      return true;
    }

    bool completionShow(Context& context, Arguments& arguments) {
      const auto stamp = context.screen.stamp();
      auto& completion = context.screen.completionMut();
      std::uint32_t items = 0;
      std::int64_t selected = 0;
      std::int64_t row = 0;
      std::int64_t column = 0;
      std::int64_t grid = 0;

      completion.text.clear();
      completion.items.clear();
      if (!arguments.array(items)) {
        return false;
      }

      for (std::uint32_t index = 0; index < items; ++index) {
        if (!completionItem(arguments.reader(), completion)) {
          return false;
        }
      }

      if (!arguments.integer(selected) || !arguments.integer(row) || !arguments.integer(column) || !arguments.integer(grid)) {
        return false;
      }

      completion.selected = clamped(selected, -1);
      completion.row = clamped(row, std::numeric_limits<std::int32_t>::min());
      completion.column = clamped(column, std::numeric_limits<std::int32_t>::min());
      completion.grid = clamped(grid, -1);
      completion.visible = true;
      completion.items_at = stamp;
      return true;
    }

    bool completionSelect(Context& context, Arguments& arguments) {
      std::int64_t selected = 0;

      if (!arguments.integer(selected)) {
        return false;
      }

      context.screen.completionMut().selected = clamped(selected, -1);
      return true;
    }

    bool completionHide(Context& context, Arguments& /*arguments*/) {
      const auto stamp = context.screen.stamp();
      auto& completion = context.screen.completionMut();

      completion.visible = false;
      completion.items.clear();
      completion.text.clear();
      completion.items_at = stamp;
      return true;
    }

    // One `{tab|buffer: handle, name: text}` map, its name kept in the tabs' text.
    bool tabEntry(msgpack::Reader& reader, NvimTabs& tabs, NvimTabs::Entry& entry) {
      std::uint32_t pairs = 0;

      if (!reader.map(pairs)) {
        return false;
      }

      for (std::uint32_t pair = 0; pair < pairs; ++pair) {
        const auto key = reader.string();
        const auto value = scalar(reader);

        if (!key || !value) {
          return false;
        }

        if (*key == "name") {
          entry.name = keep(tabs.text, value->text());
        } else if (*key == "tab" || *key == "buffer") {
          Arguments::handleOf(*value, entry.handle);
        }
      }

      return true;
    }

    // The tabs or the buffers of a tab line: which of the two, and how many follow.
    bool tabEntries(Arguments& arguments, NvimTabs& tabs, bool buffers) {
      std::uint32_t count = 0;

      if (!arguments.array(count)) {
        return false;
      }

      for (std::uint32_t index = 0; index < count; ++index) {
        NvimTabs::Entry entry;

        if (!tabEntry(arguments.reader(), tabs, entry)) {
          return false;
        }

        auto& entries = buffers ? tabs.buffers : tabs.tabs;

        if (entries.size() < NvimLimits::tabs) {
          entries.push(entry);
        }
      }

      return true;
    }

    bool tablineUpdate(Context& context, Arguments& arguments) {
      auto& tabs = context.screen.tabsMut();

      tabs.text.clear();
      tabs.tabs.clear();
      tabs.buffers.clear();
      return arguments.handle(tabs.current_tab) && tabEntries(arguments, tabs, false) && arguments.handle(tabs.current_buffer) && tabEntries(arguments, tabs, true);
    }

    struct KindName {
      std::string_view name;
      NvimMessageKind kind = NvimMessageKind::plain;
    };

    constexpr ds::Array<KindName, 14> message_kinds{
        KindName{.name = "emsg", .kind = NvimMessageKind::error},
        KindName{.name = "echoerr", .kind = NvimMessageKind::error},
        KindName{.name = "lua_error", .kind = NvimMessageKind::error},
        KindName{.name = "rpc_error", .kind = NvimMessageKind::error},
        KindName{.name = "shell_err", .kind = NvimMessageKind::error},
        KindName{.name = "wmsg", .kind = NvimMessageKind::warning},
        KindName{.name = "confirm", .kind = NvimMessageKind::confirm},
        KindName{.name = "progress", .kind = NvimMessageKind::progress},
        KindName{.name = "search_count", .kind = NvimMessageKind::search_count},
        KindName{.name = "list_cmd", .kind = NvimMessageKind::list},
        KindName{.name = "shell_out", .kind = NvimMessageKind::list},
        KindName{.name = "shell_cmd", .kind = NvimMessageKind::list},
        KindName{.name = "shell_ret", .kind = NvimMessageKind::list},
        KindName{.name = "wildlist", .kind = NvimMessageKind::list},
    };

    constexpr NvimMessageKind messageKind(std::string_view kind) noexcept {
      for (const auto& known : message_kinds) {
        if (known.name == kind) {
          return known.kind;
        }
      }

      return NvimMessageKind::plain;
    }

    constexpr std::uint64_t textId(std::string_view text) noexcept {
      constexpr std::uint64_t offset = 0xcbf2'9ce4'8422'2325ULL;
      constexpr std::uint64_t prime = 0x0000'0100'0000'01b3ULL;
      // Apart from the ids Neovim numbers.
      constexpr std::uint64_t named = std::uint64_t{1} << 63U;
      std::uint64_t value = offset;

      for (const auto character : text) {
        value = (value ^ static_cast<std::uint8_t>(character)) * prime;
      }

      return value | named;
    }

    // What a msg_show says of its message besides its text.
    struct MessageHead {
      std::uint64_t id = 0;
      bool replace_last = false;
      bool history = false;
      bool append = false;
    };

    // The id of a message, a number or a name; Neovim 0.11 added it and the two flags before it.
    bool messageHead(Arguments& arguments, MessageHead& head) noexcept {
      if (!arguments.boolean(head.replace_last)) {
        return false;
      }

      if (!arguments.more()) {
        return true;
      }

      if (!arguments.boolean(head.history) || !arguments.boolean(head.append) || !arguments.more()) {
        return !arguments.failed();
      }

      if (arguments.reader().peek() == msgpack::Kind::string) {
        const auto name = arguments.string();

        if (name) {
          head.id = textId(*name);
        }
      } else {
        std::int64_t number = 0;

        if (arguments.integer(number)) {
          head.id = static_cast<std::uint64_t>(number);
        }
      }

      return !arguments.failed();
    }

    // The visible message a new one changes: the one with its id, or the last one when it
    // replaces or continues it. A new message otherwise, the oldest leaving once they are full.
    tbc::mut_a<NvimMessage> messageTarget(tbc::mut_a<NvimMessages> messages, const MessageHead& head, ConcurrentMemory& memory) {
      for (std::size_t index = 0; head.id != 0 && index < messages.visible.size(); ++index) {
        if (messages.visible[index].id == head.id) {
          return messages.visible.atMut(index);
        }
      }

      if ((head.replace_last || head.append) && !messages.visible.empty()) {
        return messages.visible.backMut();
      }

      if (messages.visible.size() == NvimLimits::messages) {
        [[maybe_unused]] const auto oldest = messages.visible.remove(0);
      }

      return messages.visible.push(NvimMessage{memory});
    }

    bool messageShow(Context& context, Arguments& arguments) {
      const auto name = arguments.string();
      std::uint32_t count = 0;
      MessageHead head;
      NvimStyledText text{context.memory};

      if (!name || !arguments.array(count) || !chunks(arguments.reader(), count, text) || !messageHead(arguments, head)) {
        return false;
      }

      if (*name == "empty") {
        return true;
      }

      auto& target = messageTarget(context.screen.messagesMut(), head, context.memory);

      if (!head.append) {
        target.content.clear();
      }

      for (const auto& piece : text.chunks) {
        target.content.append(text.view().substr(piece.offset, piece.size), piece.highlight);
      }

      target.id = head.id;
      target.kind = messageKind(*name);
      target.history = head.history;
      return true;
    }

    bool messageClear(Context& context, Arguments& /*arguments*/) {
      context.screen.messagesMut().visible.clear();
      return true;
    }

    bool messageMode(Context& context, Arguments& arguments) {
      return content(arguments, context.screen.messagesMut().mode);
    }

    bool messageCommand(Context& context, Arguments& arguments) {
      return content(arguments, context.screen.messagesMut().command);
    }

    bool messageRuler(Context& context, Arguments& arguments) {
      return content(arguments, context.screen.messagesMut().ruler);
    }

    // One entry of :messages: `[kind, content, append]`.
    bool historyEntry(msgpack::Reader& reader, NvimStyledText& history) {
      std::uint32_t parts = 0;
      std::uint32_t count = 0;

      if (!reader.array(parts) || parts < 2 || !reader.string() || !reader.array(count) || !chunks(reader, count, history) || !skipExtra(reader, {.total = parts, .read = 2})) {
        return false;
      }

      history.append("\n", 0);
      return true;
    }

    bool messageHistory(Context& context, Arguments& arguments) {
      const auto stamp = context.screen.stamp();
      auto& messages = context.screen.messagesMut();
      std::uint32_t entries = 0;

      messages.history.clear();
      if (!arguments.array(entries)) {
        return false;
      }

      for (std::uint32_t index = 0; index < entries; ++index) {
        if (!historyEntry(arguments.reader(), messages.history)) {
          return false;
        }
      }

      messages.history_at = stamp;
      return true;
    }

    struct Event {
      std::string_view name;
      bool (*apply)(Context&, Arguments&) = nullptr;
    };

    // The events this build reads, the ones a redraw repeats most first.
    constexpr ds::Array<Event, 44> known_events{
        Event{.name = "grid_line", .apply = gridLine},
        Event{.name = "grid_cursor_goto", .apply = gridCursor},
        Event{.name = "flush", .apply = flush},
        Event{.name = "win_viewport", .apply = windowViewport},
        Event{.name = "grid_scroll", .apply = gridScroll},
        Event{.name = "hl_attr_define", .apply = highlightDefine},
        Event{.name = "win_viewport_margins", .apply = windowMargins},
        Event{.name = "win_pos", .apply = windowPosition},
        Event{.name = "win_float_pos", .apply = floatPosition},
        Event{.name = "grid_resize", .apply = gridResize},
        Event{.name = "grid_clear", .apply = gridClear},
        Event{.name = "grid_destroy", .apply = gridDestroy},
        Event{.name = "win_external_pos", .apply = externalPosition},
        Event{.name = "win_hide", .apply = windowHide},
        Event{.name = "win_close", .apply = windowHide},
        Event{.name = "msg_set_pos", .apply = messagePosition},
        Event{.name = "default_colors_set", .apply = defaultColors},
        Event{.name = "mode_info_set", .apply = modeInfo},
        Event{.name = "mode_change", .apply = modeChange},
        Event{.name = "busy_start", .apply = busyStart},
        Event{.name = "busy_stop", .apply = busyStop},
        Event{.name = "mouse_on", .apply = mouseOn},
        Event{.name = "mouse_off", .apply = mouseOff},
        Event{.name = "chdir", .apply = changeDirectory},
        Event{.name = "set_title", .apply = setTitle},
        Event{.name = "bell", .apply = bell},
        Event{.name = "visual_bell", .apply = bell},
        Event{.name = "cmdline_show", .apply = commandLineShow},
        Event{.name = "cmdline_pos", .apply = commandLinePosition},
        Event{.name = "cmdline_special_char", .apply = commandLineSpecial},
        Event{.name = "cmdline_hide", .apply = commandLineHide},
        Event{.name = "cmdline_block_show", .apply = commandLineBlockShow},
        Event{.name = "cmdline_block_append", .apply = commandLineBlockAppend},
        Event{.name = "cmdline_block_hide", .apply = commandLineBlockHide},
        Event{.name = "popupmenu_show", .apply = completionShow},
        Event{.name = "popupmenu_select", .apply = completionSelect},
        Event{.name = "popupmenu_hide", .apply = completionHide},
        Event{.name = "tabline_update", .apply = tablineUpdate},
        Event{.name = "msg_show", .apply = messageShow},
        Event{.name = "msg_clear", .apply = messageClear},
        Event{.name = "msg_showmode", .apply = messageMode},
        Event{.name = "msg_showcmd", .apply = messageCommand},
        Event{.name = "msg_ruler", .apply = messageRuler},
        Event{.name = "msg_history_show", .apply = messageHistory},
    };

    // What applies an event; null for one this build does not draw, whose parameters are skipped.
    constexpr tbc::val_static<const Event*> eventNamed(std::string_view name) noexcept {
      for (const auto& event : known_events) {
        if (event.name == name) {
          return &event;
        }
      }

      return nullptr;
    }

    // One `[name, parameters...]` of a notification: the event applied once per parameter tuple.
    bool applyBatch(Context& context, Arguments& arguments) {
      std::uint32_t items = 0;
      const auto name = arguments.batch(items);
      if (!name) {
        return false;
      }

      const auto* event = eventNamed(*name);

      for (std::uint32_t item = 1; item < items; ++item) {
        if (!arguments.begin() || (event != nullptr && !event->apply(context, arguments)) || !arguments.end()) {
          return false;
        }
      }

      return true;
    }

  }

  NvimRedraw applyRedraw(NvimScreen& screen, std::span<const std::uint8_t> notification, ConcurrentMemory& memory) {
    NvimRedraw outcome;
    Context context{.screen = screen, .outcome = outcome, .memory = memory};
    Arguments arguments{notification};
    std::uint32_t batches = 0;

    outcome.accepted = arguments.batches(batches);

    for (std::uint32_t batch = 0; outcome.accepted && batch < batches; ++batch) {
      outcome.accepted = applyBatch(context, arguments);
    }

    outcome.accepted = outcome.accepted && !arguments.failed();
    return outcome;
  }

}
