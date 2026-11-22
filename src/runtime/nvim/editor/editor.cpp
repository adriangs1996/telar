module telar.runtime.nvim.editor;

import std;
import telar.tbc;
import telar.msgpack;
import telar.base.ds;
import telar.base.text.utf8;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.editor;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.runtime.nvim.redraw;
import telar.runtime.nvim.rpc;
import telar.runtime.nvim.screen;

namespace telar::runtime {

  namespace {

    // The bytes a call needs besides the text it carries: its head, its method and its numbers.
    constexpr std::size_t call_overhead = 128;
    constexpr std::size_t paste_piece = std::size_t{32} * 1024;
    constexpr std::size_t attach_room = 256;
    constexpr std::uint64_t version_major_weight = 1000;
    constexpr tbc::val_static<std::string_view> unreadable_api = "Neovim described its API in a form the runtime does not read";

    // One request: its id, its method, how many parameters follow and the bytes they may take.
    struct Call {
      std::uint32_t id = 0;
      std::string_view method;
      std::uint32_t parameters = 0;
      std::size_t room = 0;
    };

    // Writes a message into the queue through `write`; nothing is queued when it does not fit.
    template <typename Write>
    bool enqueue(ByteQueue<ConcurrentMemory>& output, std::size_t capacity, Write write) {
      const auto before = output.readable().size();

      try {
        msgpack::Writer writer{output.appendUninitialized(capacity)};

        write(writer);

        const bool fits = !writer.overflowed();
        const auto size = writer.written().size();

        output.truncate(fits ? before + size : before);
        return fits;
      } catch (const std::exception&) {
        output.truncate(before);
        return false;
      }
    }

    // Queues `[0, id, method, [parameters...]]`, the parameters by `write`.
    template <typename Write>
    bool request(ByteQueue<ConcurrentMemory>& output, const Call& call, Write write) {
      return enqueue(output, call_overhead + call.method.size() + call.room, [&](msgpack::Writer& writer) {
        constexpr std::uint32_t request_items = 4;

        writer.array(request_items);
        writer.unsignedInteger(static_cast<std::uint64_t>(NvimMessageType::request));
        writer.unsignedInteger(call.id);
        writer.string(call.method);
        writer.array(call.parameters);
        write(writer);
      });
    }

    // What an embedded Neovim is taught: `bootstrap`, run before it reads the user's
    // configuration, and telar's modules, which it loads from the runtime instead of from disk.
#include "nvim_scripts.inc"

    // The modules, by the name Lua requires each with.
    using Module = std::pair<std::string_view, std::string_view>;
    constexpr ds::Array<Module, 4> modules{
        Module{"telar", module_telar},
        Module{"telar.theme", module_theme},
        Module{"telar.tint", module_tint},
        Module{"telar.navigate", module_navigate},
    };

    constexpr std::string_view answer_script = "__telar_prompt_answer(...)";

    // Shows a file where it is asked to, then moves the cursor.
    constexpr std::string_view open_script = R"lua(
local path, line, column, where = ...
local name = vim.fn.fnameescape(path)
if where == 1 then
  vim.cmd.split(name)
elseif where == 2 then
  vim.cmd.vsplit(name)
elseif where == 3 then
  vim.cmd.tabedit(name)
else
  vim.cmd.drop(name)
end
if line > 0 then
  pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(column - 1, 0) })
end
)lua";

    constexpr std::string_view sideName(PaneDirection direction) noexcept {
      switch (direction) {
      case PaneDirection::left:
        return "left";
      case PaneDirection::right:
        return "right";
      case PaneDirection::up:
        return "up";
      case PaneDirection::down:
        return "down";
      }

      return "left";
    }

    constexpr ds::Option<PaneDirection> sideOf(std::string_view name) noexcept {
      for (const auto direction : {PaneDirection::left, PaneDirection::right, PaneDirection::up, PaneDirection::down}) {
        if (sideName(direction) == name) {
          return direction;
        }
      }

      return ds::none;
    }

    // Text a client lists as it is: UTF-8 without a control character.
    bool displayable(std::string_view text) noexcept {
      constexpr unsigned char first_printable = 0x20;
      constexpr unsigned char delete_character = 0x7f;

      return inspectUtf8(text) == Utf8Validation::valid && std::ranges::none_of(text, [](char character) {
        const auto byte = static_cast<unsigned char>(character);

        return byte < first_printable || byte == delete_character;
      });
    }

    // A color as Neovim writes one: `#rrggbb`.
    struct HexColor {
      static constexpr std::size_t size = 7;

      explicit constexpr HexColor(std::span<const Byte> rgb) noexcept {
        constexpr std::string_view digits = "0123456789abcdef";
        constexpr unsigned nibble = 4;
        constexpr unsigned low = 0xf;

        text.atMut(0) = '#';
        for (std::size_t index = 0; index < 3; ++index) {
          const unsigned channel = rgb[index];

          text.atMut(1 + (index * 2)) = digits[channel >> nibble];
          text.atMut(2 + (index * 2)) = digits[channel & low];
        }
      }

      [[nodiscard]] constexpr std::string_view view() const noexcept {
        return std::string_view{text.view()};
      }

      ds::Array<char, size> text{};
    };

    // The start of `text` that fits `limit` bytes.
    constexpr std::string_view clipped(std::string_view text, std::size_t limit) {
      return text.substr(0, std::min(text.size(), limit));
    }

    constexpr std::string_view buttonName(NvimMouseButton button) noexcept {
      switch (button) {
      case NvimMouseButton::left:
        return "left";
      case NvimMouseButton::right:
        return "right";
      case NvimMouseButton::middle:
        return "middle";
      case NvimMouseButton::wheel:
        return "wheel";
      case NvimMouseButton::move:
        return "move";
      }

      return "left";
    }

    constexpr std::string_view actionName(NvimMouseAction action) noexcept {
      switch (action) {
      case NvimMouseAction::press:
        return "press";
      case NvimMouseAction::drag:
        return "drag";
      case NvimMouseAction::release:
        return "release";
      case NvimMouseAction::up:
        return "up";
      case NvimMouseAction::down:
        return "down";
      case NvimMouseAction::left:
        return "left";
      case NvimMouseAction::right:
        return "right";
      }

      return "press";
    }

    // The `{major, minor, ...}` of a version as one number; none for a map that is not one.
    ds::Option<std::uint64_t> versionOf(msgpack::Reader& reader) noexcept {
      std::uint32_t fields = 0;
      std::uint64_t major = 0;
      std::uint64_t minor = 0;

      if (!reader.map(fields)) {
        return ds::none;
      }

      for (std::uint32_t field = 0; field < fields; ++field) {
        const auto name = reader.string();
        const auto value = reader.value();

        if (!name || !value || value->kind == msgpack::Kind::array || value->kind == msgpack::Kind::map) {
          return ds::none;
        }

        if (*name == "major") {
          major = value->bits;
        } else if (*name == "minor") {
          minor = value->bits;
        }
      }

      return (major * version_major_weight) + minor;
    }

    // The version in what nvim_get_api_info describes, a map of which it is one value.
    ds::Option<std::uint64_t> describedVersion(msgpack::Reader& reader) noexcept {
      std::uint32_t pairs = 0;

      if (!reader.map(pairs)) {
        return ds::none;
      }

      for (std::uint32_t pair = 0; pair < pairs; ++pair) {
        const auto key = reader.string();
        if (!key) {
          return ds::none;
        }

        if (*key == "version") {
          return versionOf(reader);
        }

        if (!reader.skip()) {
          return ds::none;
        }
      }

      return ds::none;
    }

  }

  NvimBufferList::NvimBufferList(ConcurrentMemory& memory)
      : text(memory),
        names(memory) {}

  NvimPromptRequest::NvimPromptRequest(ConcurrentMemory& memory)
      : title(memory),
        initial(memory),
        origin(memory),
        text(memory),
        choices(memory) {}

  NvimEditor::NvimEditor(ConcurrentMemory& memory, NvimSize size, NvimSurfaces surfaces)
      : memory_(memory),
        inbox_(memory),
        screen_(memory),
        output_(memory, output_limit),
        size_(size),
        surfaces_(surfaces),
        prompt_(memory),
        clipboard_(memory),
        link_(memory),
        buffers_(memory) {
    request(output_, {.id = identify_request_, .method = "nvim_get_api_info"}, [](msgpack::Writer&) {});
  }

  bool NvimEditor::fail(tbc::val_static<std::string_view> reason) noexcept {
    state_ = NvimState::failed;
    failure_ = reason;
    return false;
  }

  bool NvimEditor::receive(std::span<const std::uint8_t> bytes) {
    if (state_ == NvimState::failed) {
      return false;
    }

    const bool whole = inbox_.feed(bytes, [&](std::span<const std::uint8_t> message) {
      return handle(message);
    });
    if (!whole && state_ != NvimState::failed) {
      return fail("Neovim wrote bytes that are not its protocol");
    }

    if (screen_.takeClusterOverflow()) {
      command("redraw!");
    }

    return whole;
  }

  bool NvimEditor::handle(std::span<const std::uint8_t> message) {
    constexpr std::uint32_t notification_items = 3;
    constexpr std::uint32_t call_items = 4;
    msgpack::Reader reader{message};
    std::uint32_t items = 0;
    std::uint64_t type = 0;

    if (!reader.array(items) || !reader.unsignedInteger(type)) {
      return fail("Neovim wrote a message that is not a call");
    }

    if (type == static_cast<std::uint64_t>(NvimMessageType::notification) && items == notification_items) {
      return notified(reader, message);
    }

    if (type == static_cast<std::uint64_t>(NvimMessageType::response) && items == call_items) {
      return answered(reader, message);
    }

    if (type == static_cast<std::uint64_t>(NvimMessageType::request) && items == call_items) {
      std::uint64_t id = 0;

      if (!reader.unsignedInteger(id)) {
        return fail("Neovim wrote a request without an id");
      }

      // Anything running in Neovim can call the runtime: a request it does not offer is refused.
      refuse(id);
      return true;
    }

    return fail("Neovim wrote a message of no known type");
  }

  bool NvimEditor::notified(msgpack::Reader& reader, std::span<const std::uint8_t> message) {
    const auto method = reader.string();
    if (!method) {
      return fail("Neovim wrote a notification without a name");
    }

    if (*method == "telar_prompt") {
      return prompted(message.subspan(reader.offset()));
    }

    if (*method != "redraw") {
      told(*method, message.subspan(reader.offset()));
      return true;
    }

    const auto outcome = applyRedraw(screen_, message.subspan(reader.offset()), memory_);
    if (!outcome.accepted) {
      return fail("Neovim wrote a redraw the runtime refuses");
    }

    pulse_.flushed = pulse_.flushed || outcome.flushes != 0;
    pulse_.bell = pulse_.bell || outcome.bell;
    if (outcome.flushes != 0) {
      frameFloats();
    }

    return true;
  }

  // Anything in Neovim can send these, so what does not read as what it names is passed over,
  // and what does is cut to what a client is sent.
  void NvimEditor::told(std::string_view method, std::span<const std::uint8_t> parameters) {
    msgpack::Reader reader{parameters};

    if (method == "telar_clipboard") {
      copied(reader);
    } else if (method == "telar_open") {
      opened(reader);
    } else if (method == "telar_directory") {
      moved(reader);
    } else if (method == "telar_float") {
      framed(reader);
    } else if (method == "telar_tabs") {
      changed(reader);
    } else if (method == "telar_buffers") {
      listed(reader);
    } else if (method == "telar_navigate") {
      if (const auto side = reader.tuple(1) ? reader.string() : ds::none) {
        pulse_.navigated = sideOf(*side);
      }
    } else if (method == "telar_pick") {
      const auto source = reader.tuple(1) ? reader.string() : ds::none;

      if (source && *source == "files") {
        pulse_.pick = NvimPickSource::files;
      } else if (source && *source == "grep") {
        pulse_.pick = NvimPickSource::text;
      } else if (source && *source == "buffers") {
        pulse_.pick = NvimPickSource::buffers;
      }
    }
  }

  // `[text]`: what was yanked to a clipboard register.
  void NvimEditor::copied(msgpack::Reader& reader) {
    const auto text = reader.tuple(1) ? reader.string() : ds::none;
    if (!text || text->size() > max_nvim_paste_bytes) {
      return;
    }

    clipboard_.assign(*text);
    pulse_.copied = true;
  }

  // `[uri]`: a link of the web or of mail to open where the person is.
  void NvimEditor::opened(msgpack::Reader& reader) {
    const auto uri = reader.tuple(1) ? reader.string() : ds::none;
    const bool known = uri && (uri->starts_with("https://") || uri->starts_with("http://") || uri->starts_with("mailto:"));

    if (!known || uri->size() > max_nvim_path_bytes || !std::exchange(asked_, false)) {
      return;
    }

    link_.assign(*uri);
    pulse_.opened = true;
  }

  // `[path]`: the directory of the current window.
  void NvimEditor::moved(msgpack::Reader& reader) {
    const auto path = reader.tuple(1) ? reader.string() : ds::none;
    if (!path || !path->starts_with('/') || *path == screen_.directory()) {
      return;
    }

    const bool settled = screen_.settled();

    screen_.directory(*path);
    publish(settled);
  }

  // `[window, sides, title, footer]`: a float's frame.
  // `[[tab, modified, diagnostics]...]`: what is marked on each tab page that has something.
  void NvimEditor::changed(msgpack::Reader& reader) {
    constexpr std::uint32_t fields = 3;
    ds::Array<NvimTabs::Mark, max_nvim_tabs> marks{};
    std::uint32_t count = 0;

    if (!reader.tuple(1) || !reader.array(count) || count > max_nvim_tabs) {
      return;
    }

    for (std::uint32_t index = 0; index < count; ++index) {
      auto& mark = marks.atMut(index);
      std::uint64_t diagnostics = 0;

      if (!reader.tuple(fields) || !reader.unsignedInteger(mark.handle) || !reader.boolean(mark.modified) || !reader.unsignedInteger(diagnostics)) {
        return;
      }

      mark.diagnostics = static_cast<std::uint16_t>(std::min<std::uint64_t>(diagnostics, std::numeric_limits<std::uint16_t>::max()));
    }

    const bool settled = screen_.settled();

    if (screen_.markTabs(marks.view().first(count))) {
      publish(settled);
    }
  }

  void NvimEditor::framed(msgpack::Reader& reader) {
    constexpr std::uint32_t fields = 4;
    std::uint64_t window = 0;
    std::uint64_t sides = 0;

    if (!reader.tuple(fields) || !reader.unsignedInteger(window) || !reader.unsignedInteger(sides) || sides > max_nvim_border) {
      return;
    }

    const auto title = reader.string();
    const auto footer = reader.string();
    if (!title || !footer) {
      return;
    }

    const bool settled = screen_.settled();

    if (screen_.decorate(window, {.border = static_cast<std::uint8_t>(sides), .title = clipped(*title, max_nvim_label_bytes), .footer = clipped(*footer, max_nvim_label_bytes)})) {
      publish(settled);
    }
  }

  // `[token, [name...]]`: the listed buffers.
  void NvimEditor::listed(msgpack::Reader& reader) {
    std::uint64_t token = 0;
    std::uint32_t count = 0;

    if (!reader.tuple(2) || !reader.unsignedInteger(token) || !reader.array(count)) {
      return;
    }

    buffers_.token = token;
    buffers_.text.clear();
    buffers_.names.clear();
    for (std::uint32_t index = 0; index < count; ++index) {
      const auto name = reader.string();
      if (!name) {
        break;
      }

      if (buffers_.names.size() < max_nvim_choices && !name->empty() && name->size() <= TextMatch::maximum_path_bytes && displayable(*name)) {
        buffers_.names.push({.offset = static_cast<std::uint32_t>(buffers_.text.size()), .size = static_cast<std::uint32_t>(name->size())});
        buffers_.text.extend(std::span<const char>{*name});
      }
    }

    pulse_.listed = true;
  }

  void NvimEditor::publish(bool was_settled) noexcept {
    if (was_settled) {
      screen_.flush();
      pulse_.flushed = true;
    }
  }

  void NvimEditor::frameFloats() {
    constexpr std::string_view script = "__telar_float(...)";
    constexpr std::size_t room = 64;

    for (auto window = screen_.nextUnframed(); window != 0; window = screen_.nextUnframed()) {
      request(output_, {.id = next_request_++, .method = "nvim_exec_lua", .parameters = 2, .room = room}, [&](msgpack::Writer& writer) {
        writer.string(script);
        writer.array(1);
        writer.unsignedInteger(window);
      });
    }
  }

  bool NvimEditor::answered(msgpack::Reader& reader, std::span<const std::uint8_t> message) {
    std::uint64_t id = 0;

    if (!reader.unsignedInteger(id)) {
      return fail("Neovim wrote a response without an id");
    }

    const auto error = reader.value();
    if (!error) {
      return fail("Neovim wrote a response without a result");
    }

    // Without telar's side of the conversation the editor would attach half taught.
    if (id == bootstrap_request_ && error->kind != msgpack::Kind::nil) {
      return fail("Neovim could not run what the runtime teaches it");
    }

    if (id != identify_request_ || state_ != NvimState::identifying) {
      return true;
    }

    if (error->kind != msgpack::Kind::nil) {
      return fail("Neovim refused to describe its API");
    }

    return identified(message.subspan(reader.offset()));
  }

  // What vim.ui asks: `[id, kind, title, initial, [choice...]]`. Anything in Neovim can send
  // one, so what does not read as a prompt is passed over, and what does is cut to what a
  // client is sent.
  bool NvimEditor::prompted(std::span<const std::uint8_t> parameters) {
    // The id, the kind, the title, the initial text, the choices and, after them, who asks.
    constexpr std::uint32_t fields = 5;
    constexpr std::uint32_t fields_with_origin = 6;
    msgpack::Reader reader{parameters};
    std::uint64_t id = 0;
    std::uint32_t count = 0;
    std::uint32_t given = 0;

    if (!reader.array(given) || (given != fields && given != fields_with_origin) || !reader.unsignedInteger(id) || id == 0) {
      return true;
    }

    const auto kind = reader.string();
    const auto title = reader.string();
    const auto initial = reader.string();
    if (!kind || !title || !initial || !reader.array(count) || (*kind != "select" && *kind != "input")) {
      return true;
    }

    // One prompt is open at a time: whatever asked before is told nothing was chosen.
    dismissPrompt();
    prompt_.id = id;
    prompt_.kind = *kind == "select" ? NvimPromptKind::select : NvimPromptKind::input;
    prompt_.title.assign(clipped(*title, max_nvim_label_bytes));
    prompt_.initial.assign(clipped(*initial, max_nvim_line_bytes));

    for (std::uint32_t index = 0; index < count; ++index) {
      const auto choice = reader.string();
      if (!choice) {
        break;
      }

      if (prompt_.choices.size() < max_nvim_choices) {
        const auto kept = clipped(*choice, max_nvim_label_bytes);

        prompt_.choices.push({.offset = static_cast<std::uint32_t>(prompt_.text.size()), .size = static_cast<std::uint32_t>(kept.size())});
        prompt_.text.extend(std::span<const char>{kept});
      }
    }

    prompt_.origin.clear();
    if (given == fields_with_origin) {
      if (const auto who = reader.string()) {
        prompt_.origin.assign(clipped(*who, max_nvim_label_bytes));
      }
    }

    ++prompt_serial_;
    return true;
  }

  void NvimEditor::dismissPrompt() {
    if (prompt_.id != 0) {
      static_cast<void>(answer({.id = prompt_.id}));
    }
  }

  bool NvimEditor::answer(const NvimAnswer& answer) {
    constexpr std::uint32_t parameter_count = 2;
    constexpr std::uint32_t argument_count = 4;
    constexpr std::size_t room = 64;

    if (answer.id == 0 || answer.id != prompt_.id || answer.text.size() > max_nvim_line_bytes) {
      return false;
    }

    prompt_.id = 0;
    prompt_.kind = NvimPromptKind::none;
    prompt_.title.clear();
    prompt_.initial.clear();
    prompt_.origin.clear();
    prompt_.text.clear();
    prompt_.choices.clear();
    ++prompt_serial_;
    return request(output_, {.id = next_request_++, .method = "nvim_exec_lua", .parameters = parameter_count, .room = room + answer_script.size() + answer.text.size()}, [&](msgpack::Writer& writer) {
      writer.string(answer_script);
      writer.array(argument_count);
      writer.unsignedInteger(answer.id);
      writer.boolean(answer.accepted);
      // Lua counts from one.
      writer.unsignedInteger(std::uint64_t{answer.index} + 1);
      writer.string(answer.text);
    });
  }

  bool NvimEditor::open(const NvimPlace& place) {
    constexpr std::uint32_t parameter_count = 2;
    constexpr std::uint32_t argument_count = 4;
    constexpr std::size_t room = 64;

    if (state_ == NvimState::failed || place.path.empty() || place.path.size() > max_nvim_path_bytes) {
      return false;
    }

    return request(output_, {.id = next_request_++, .method = "nvim_exec_lua", .parameters = parameter_count, .room = room + open_script.size() + place.path.size()}, [&](msgpack::Writer& writer) {
      writer.string(open_script);
      writer.array(argument_count);
      writer.string(place.path);
      writer.unsignedInteger(place.line);
      writer.unsignedInteger(place.column);
      writer.unsignedInteger(std::to_underlying(place.in));
    });
  }

  bool NvimEditor::theme(const TerminalTheme& colors) {
    if (state_ == NvimState::failed || !colors.foreground || !colors.background || !colors.palette || !colors.syntax || !colors.chrome || (theme_ && *theme_ == colors)) {
      return false;
    }

    theme_ = colors;
    // A Neovim that has not attached yet is told as it does.
    return state_ == NvimState::attached && sendTheme();
  }

  bool NvimEditor::sendTheme() {
    constexpr std::string_view script = "__telar_theme(...)";
    constexpr std::size_t room = 4096;
    constexpr std::uint32_t ansi_colors = 16;
    constexpr std::uint32_t style_fields = 3;
    const auto& colors = *theme_;

    return request(output_, {.id = next_request_++, .method = "nvim_exec_lua", .parameters = 2, .room = room}, [&](msgpack::Writer& writer) {
      const auto hex = [&](std::span<const Byte> bytes, std::size_t index) {
        writer.string(HexColor{bytes.subspan(index * 3, 3)}.view());
      };

      writer.string(script);
      writer.array(1);
      // The foreground, the background, the selection's two and the palette; the cursor's when
      // the theme names one.
      constexpr std::size_t always = 5;

      writer.map(always + (colors.cursor ? 1 : 0));
      writer.string("foreground");
      hex(colors.foreground->view(), 0);
      writer.string("background");
      hex(colors.background->view(), 0);
      if (colors.cursor) {
        writer.string("cursor");
        hex(colors.cursor->view(), 0);
      }

      writer.string("ansi");
      writer.array(ansi_colors);
      for (std::uint32_t index = 0; index < ansi_colors; ++index) {
        hex(colors.palette->view(), index);
      }

      writer.string("syntax");
      writer.map(TerminalTheme::syntax_roles);
      for (std::size_t role = 0; role < TerminalTheme::syntax_roles; ++role) {
        writer.string(TerminalTheme::syntax_names[role]);
        writer.map(style_fields);
        writer.string("color");
        hex(colors.syntax->view(), role);
        writer.string("italic");
        writer.boolean((colors.syntax_italic & (1U << role)) != 0);
        writer.string("bold");
        writer.boolean((colors.syntax_bold & (1U << role)) != 0);
      }

      writer.string("chrome");
      writer.map(TerminalTheme::chrome_roles);
      for (std::size_t role = 0; role < TerminalTheme::chrome_roles; ++role) {
        writer.string(TerminalTheme::chrome_names[role]);
        hex(colors.chrome->view(), role);
      }
    });
  }

  bool NvimEditor::navigate(PaneDirection direction) {
    constexpr std::string_view script = "__telar_navigate(...)";
    constexpr std::size_t room = 64;

    if (state_ != NvimState::attached) {
      return false;
    }

    return request(output_, {.id = next_request_++, .method = "nvim_exec_lua", .parameters = 2, .room = room}, [&](msgpack::Writer& writer) {
      writer.string(script);
      writer.array(1);
      writer.string(sideName(direction));
    });
  }

  bool NvimEditor::selectMenu(std::uint32_t item, bool accept) {
    constexpr std::uint32_t parameter_count = 4;
    constexpr std::size_t room = 32;

    if (state_ != NvimState::attached) {
      return false;
    }

    return request(output_, {.id = next_request_++, .method = "nvim_select_popupmenu_item", .parameters = parameter_count, .room = room}, [&](msgpack::Writer& writer) {
      writer.unsignedInteger(item);
      // The item's text goes in the buffer, as a key that selects it would put it.
      writer.boolean(true);
      writer.boolean(accept);
      writer.map(0);
    });
  }

  bool NvimEditor::listBuffers(std::uint64_t token) {
    constexpr std::string_view script = "__telar_buffers(...)";
    constexpr std::size_t room = 64;

    if (state_ != NvimState::attached) {
      return false;
    }

    return request(output_, {.id = next_request_++, .method = "nvim_exec_lua", .parameters = 2, .room = room}, [&](msgpack::Writer& writer) {
      writer.string(script);
      writer.array(1);
      writer.unsignedInteger(token);
    });
  }

  bool NvimEditor::preview(const NvimPlace& place, NvimArea area) {
    constexpr std::string_view script = "__telar_preview(...)";
    constexpr std::uint32_t argument_count = 6;
    constexpr std::size_t room = 96;

    if (state_ != NvimState::attached || place.path.size() > max_nvim_path_bytes) {
      return false;
    }

    return request(output_, {.id = next_request_++, .method = "nvim_exec_lua", .parameters = 2, .room = room + place.path.size()}, [&](msgpack::Writer& writer) {
      writer.string(script);
      writer.array(argument_count);
      writer.string(place.path);
      writer.unsignedInteger(place.line);
      writer.unsignedInteger(area.row);
      writer.unsignedInteger(area.column);
      writer.unsignedInteger(area.columns);
      writer.unsignedInteger(area.rows);
    });
  }

  bool NvimEditor::list(std::span<const TextMatch> places) {
    constexpr std::string_view script = "__telar_list(...)";
    constexpr std::uint32_t place_fields = 4;
    constexpr std::size_t place_room = 32;
    std::size_t room = place_room;

    if (state_ != NvimState::attached || places.empty()) {
      return false;
    }

    for (const auto& place : places) {
      room += place_room + place.path.size() + place.text.size();
    }

    return request(output_, {.id = next_request_++, .method = "nvim_exec_lua", .parameters = 2, .room = room}, [&](msgpack::Writer& writer) {
      writer.string(script);
      writer.array(1);
      writer.array(static_cast<std::uint32_t>(places.size()));
      for (const auto& place : places) {
        writer.array(place_fields);
        writer.string(place.path);
        writer.unsignedInteger(place.line);
        writer.unsignedInteger(place.column);
        writer.string(place.text);
      }
    });
  }

  std::string_view NvimEditor::clipboard() const noexcept {
    return clipboard_.view();
  }

  std::string_view NvimEditor::link() const noexcept {
    return link_.view();
  }

  const NvimBufferList& NvimEditor::buffers() const noexcept {
    return buffers_;
  }

  const NvimPromptRequest& NvimEditor::prompt() const noexcept {
    return prompt_;
  }

  std::uint64_t NvimEditor::promptSerial() const noexcept {
    return prompt_serial_;
  }

  // The result of nvim_get_api_info: `[channel, {version: {major, minor, ...}, ...}]`.
  bool NvimEditor::identified(std::span<const std::uint8_t> result) {
    msgpack::Reader reader{result};

    if (!reader.tuple(2) || !reader.unsignedInteger(channel_)) {
      return fail(unreadable_api);
    }

    const auto version = describedVersion(reader);
    if (!version) {
      return fail(unreadable_api);
    }

    if (*version < minimum_version) {
      return fail("This Neovim is older than the runtime's editor needs");
    }

    attach();
    return true;
  }

  void NvimEditor::attach() {
    constexpr std::uint32_t option_count = 8;
    constexpr std::size_t variable_room = 32;

    // Before the user's configuration loads, it learns the channel to call the runtime on.
    request(output_, {.id = next_request_++, .method = "nvim_set_var", .parameters = 2, .room = variable_room}, [&](msgpack::Writer& writer) {
      writer.string("telar_channel");
      writer.unsignedInteger(channel_);
    });

    std::size_t scripts = bootstrap.size();

    for (const auto& [name, source] : modules) {
      scripts += name.size() + source.size() + variable_room;
    }

    bootstrap_request_ = next_request_++;
    request(output_, {.id = bootstrap_request_, .method = "nvim_exec_lua", .parameters = 2, .room = variable_room + scripts}, [&](msgpack::Writer& writer) {
      writer.string(bootstrap);
      writer.array(2);
      writer.unsignedInteger(channel_);
      writer.map(static_cast<std::uint32_t>(modules.size()));
      for (const auto& [name, source] : modules) {
        writer.string(name);
        writer.string(source);
      }
    });

    // The colorscheme is the window's before the configuration loads, and after whatever it sets.
    if (theme_) {
      sendTheme();
    }

    request(output_, {.id = next_request_++, .method = "nvim_ui_attach", .parameters = 3, .room = attach_room}, [&](msgpack::Writer& writer) {
      writer.unsignedInteger(size_.columns);
      writer.unsignedInteger(size_.rows);
      writer.map(option_count);
      writer.string("rgb");
      writer.boolean(true);
      writer.string("ext_linegrid");
      writer.boolean(true);
      writer.string("ext_multigrid");
      writer.boolean(true);
      // An unset default color arrives as unset, and is drawn with the pane's theme.
      writer.string("ext_termcolors");
      writer.boolean(true);
      writer.string("ext_cmdline");
      writer.boolean(surfaces_.command_line);
      writer.string("ext_popupmenu");
      writer.boolean(surfaces_.completion);
      writer.string("ext_messages");
      writer.boolean(surfaces_.messages);
      writer.string("ext_tabline");
      writer.boolean(surfaces_.tabs);
    });

    state_ = NvimState::attached;
    if (!focused_) {
      focus(false);
    }
  }

  void NvimEditor::refuse(std::uint64_t id) {
    enqueue(output_, call_overhead, [&](msgpack::Writer& writer) {
      constexpr std::uint32_t response_items = 4;

      writer.array(response_items);
      writer.unsignedInteger(static_cast<std::uint64_t>(NvimMessageType::response));
      writer.unsignedInteger(id);
      writer.string("telar does not offer this request");
      writer.nil();
    });
  }

  std::span<const std::uint8_t> NvimEditor::pending() const noexcept {
    return output_.readable();
  }

  void NvimEditor::written(std::size_t count) noexcept {
    output_.consume(count);
  }

  bool NvimEditor::input(std::string_view keys) {
    // Keys typed before Neovim attached wait in its input, as typeahead does.
    if (state_ == NvimState::failed || keys.empty() || keys.size() > input_limit) {
      return false;
    }

    asked_ = true;
    return request(output_, {.id = next_request_++, .method = "nvim_input", .parameters = 1, .room = keys.size()}, [&](msgpack::Writer& writer) {
      writer.string(keys);
    });
  }

  bool NvimEditor::paste(std::string_view text) {
    // The phases of a paste Neovim joins: one call, or a first piece, more of them and the last.
    constexpr std::int64_t whole = -1;
    constexpr std::int64_t first = 1;
    constexpr std::int64_t middle = 2;
    constexpr std::int64_t last = 3;

    if (state_ != NvimState::attached || text.empty()) {
      return false;
    }

    const bool single = text.size() <= paste_piece;
    std::int64_t phase = single ? whole : first;

    while (!text.empty()) {
      const auto piece = text.substr(0, paste_piece);

      text.remove_prefix(piece.size());
      if (!single && text.empty()) {
        phase = last;
      }

      const bool queued = request(output_, {.id = next_request_++, .method = "nvim_paste", .parameters = 3, .room = piece.size()}, [&](msgpack::Writer& writer) {
        writer.string(piece);
        writer.boolean(false);
        writer.integer(phase);
      });
      if (!queued) {
        return false;
      }

      phase = middle;
    }

    return true;
  }

  bool NvimEditor::mouse(const NvimMouse& event) {
    constexpr std::uint32_t parameter_count = 6;
    constexpr std::size_t room = 64;

    if (state_ != NvimState::attached) {
      return false;
    }

    asked_ = true;

    ds::Array<char, 4> modifiers{};
    std::size_t count = 0;

    for (const auto [bit, letter] : {std::pair{nvim_mouse_shift, 'S'}, std::pair{nvim_mouse_control, 'C'}, std::pair{nvim_mouse_alt, 'A'}, std::pair{nvim_mouse_command, 'D'}}) {
      if ((event.modifiers & bit) != 0) {
        modifiers.atMut(count++) = letter;
      }
    }

    return request(output_, {.id = next_request_++, .method = "nvim_input_mouse", .parameters = parameter_count, .room = room}, [&](msgpack::Writer& writer) {
      writer.string(buttonName(event.button));
      writer.string(actionName(event.action));
      writer.string(std::string_view{modifiers.view()}.substr(0, count));
      writer.unsignedInteger(event.grid);
      writer.unsignedInteger(event.row);
      writer.unsignedInteger(event.column);
    });
  }

  void NvimEditor::resize(NvimSize size) {
    constexpr std::size_t room = 16;

    if (size == size_ || size.columns == 0 || size.rows == 0) {
      return;
    }

    size_ = size;
    if (state_ != NvimState::attached) {
      return;
    }

    request(output_, {.id = next_request_++, .method = "nvim_ui_try_resize", .parameters = 2, .room = room}, [&](msgpack::Writer& writer) {
      writer.unsignedInteger(size.columns);
      writer.unsignedInteger(size.rows);
    });
  }

  void NvimEditor::focus(bool focused) {
    focused_ = focused;
    if (state_ != NvimState::attached) {
      return;
    }

    request(output_, {.id = next_request_++, .method = "nvim_ui_set_focus", .parameters = 1}, [&](msgpack::Writer& writer) {
      writer.boolean(focused);
    });
  }

  bool NvimEditor::command(std::string_view command) {
    if (state_ != NvimState::attached || command.size() > input_limit) {
      return false;
    }

    return request(output_, {.id = next_request_++, .method = "nvim_command", .parameters = 1, .room = command.size()}, [&](msgpack::Writer& writer) {
      writer.string(command);
    });
  }

  NvimState NvimEditor::state() const noexcept {
    return state_;
  }

  const NvimScreen& NvimEditor::screen() const noexcept {
    return screen_;
  }

  NvimSize NvimEditor::size() const noexcept {
    return size_;
  }

  std::uint64_t NvimEditor::channel() const noexcept {
    return channel_;
  }

  tbc::val_static<std::string_view> NvimEditor::failure() const noexcept {
    return failure_;
  }

  NvimPulse NvimEditor::takePulse() noexcept {
    return std::exchange(pulse_, {});
  }

}
