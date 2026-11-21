module telar.runtime.nvim.editor;

import std;
import telar.tbc;
import telar.msgpack;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.nvim;
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

    // Run before Neovim reads the user's configuration: vim.ui.select and vim.ui.input ask the
    // runtime, which shows them natively, and nothing loaded later can put its own in their
    // place. The answer comes back through __telar_prompt_answer.
    constexpr std::string_view prompt_bootstrap = R"lua(
local channel = ...
local pending, last = {}, 0
local function ask(kind, title, initial, choices, done)
  last = last + 1
  pending[last] = done
  vim.rpcnotify(channel, 'telar_prompt', last, kind, tostring(title or ''), tostring(initial or ''), choices)
end
local function select(items, opts, on_choice)
  opts = opts or {}
  local format = opts.format_item or tostring
  local choices = {}
  for index, item in ipairs(items) do
    choices[index] = tostring(format(item))
  end
  ask('select', opts.prompt, '', choices, function(accepted, index)
    if accepted and items[index] ~= nil then
      on_choice(items[index], index)
    else
      on_choice(nil, nil)
    end
  end)
end
local function input(opts, on_confirm)
  opts = opts or {}
  ask('input', opts.prompt, opts.default, {}, function(accepted, _, text)
    on_confirm(accepted and text or nil)
  end)
end
function _G.__telar_prompt_answer(id, accepted, index, text)
  local done = pending[id]
  pending[id] = nil
  if done then
    vim.schedule(function()
      done(accepted, index, text)
    end)
  end
end
local ui = vim.ui
local guarded = setmetatable({}, {
  __index = function(_, key)
    if key == 'select' then
      return select
    end
    if key == 'input' then
      return input
    end
    return ui[key]
  end,
  __newindex = function(_, key, value)
    if key ~= 'select' and key ~= 'input' then
      ui[key] = value
    end
  end,
})
package.loaded['vim.ui'] = guarded
vim.ui = guarded
)lua";

    constexpr std::string_view answer_script = "__telar_prompt_answer(...)";

    // Shows the file where it already is, or in the current window, then moves the cursor.
    constexpr std::string_view open_script = R"lua(
local path, line, column = ...
vim.cmd.drop(vim.fn.fnameescape(path))
if line > 0 then
  pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(column - 1, 0) })
end
)lua";

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

  NvimPromptRequest::NvimPromptRequest(ConcurrentMemory& memory)
      : title(memory),
        initial(memory),
        text(memory),
        choices(memory) {}

  NvimEditor::NvimEditor(ConcurrentMemory& memory, NvimSize size, NvimSurfaces surfaces)
      : memory_(memory),
        inbox_(memory),
        screen_(memory),
        output_(memory, output_limit),
        size_(size),
        surfaces_(surfaces),
        prompt_(memory) {
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
      return true;
    }

    const auto outcome = applyRedraw(screen_, message.subspan(reader.offset()), memory_);
    if (!outcome.accepted) {
      return fail("Neovim wrote a redraw the runtime refuses");
    }

    pulse_.flushed = pulse_.flushed || outcome.flushes != 0;
    pulse_.bell = pulse_.bell || outcome.bell;
    return true;
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
    constexpr std::uint32_t fields = 5;
    msgpack::Reader reader{parameters};
    std::uint64_t id = 0;
    std::uint32_t count = 0;

    if (!reader.tuple(fields) || !reader.unsignedInteger(id) || id == 0) {
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
    constexpr std::uint32_t argument_count = 3;
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
    });
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

    request(output_, {.id = next_request_++, .method = "nvim_exec_lua", .parameters = 2, .room = variable_room + prompt_bootstrap.size()}, [&](msgpack::Writer& writer) {
      writer.string(prompt_bootstrap);
      writer.array(1);
      writer.unsignedInteger(channel_);
    });

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
