module;
#include "telar_platform/trace_macro.hpp"

#include "telar_base/diagnostics/config.hpp"

module telar.runtime.terminal.text_reader;

import telar.ghostty.vt;
import telar.runtime.terminal.grid;
import telar.render.document;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.base.ds;
import telar.base.text;

namespace telar::runtime {
  namespace {

    // Ghostty hands its strings and rows of cells as C pointers and lengths.
    tbc::val_a<std::span<const Byte>> ghosttyBytes(tbc::val_a<GhosttyString> value) noexcept {
#pragma clang unsafe_buffer_usage begin
      return {value.ptr, value.len};
#pragma clang unsafe_buffer_usage end
    }

    tbc::val_a<std::span<const GhosttyCell>> ghosttyCells(tbc::val_a<GhosttyCellsView> view) noexcept {
#pragma clang unsafe_buffer_usage begin
      return {view.ptr, view.len};
#pragma clang unsafe_buffer_usage end
    }

    // Ghostty takes each callback as a const void*.
    template <typename Function>
    const void* callbackAddress(Function* function) noexcept {
      return reinterpret_cast<const void*>(function); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): ghostty_terminal_set takes a callback as a const void*
    }

    // The length of the UTF-8 sequence `first` leads, from its lead byte alone.
    std::size_t sequenceLength(Byte first) noexcept {
      constexpr Byte one_byte_end = 0x80;
      constexpr Byte three_byte_lead = 0xe0;
      constexpr Byte four_byte_lead = 0xf0;

      if (first < one_byte_end) {
        return 1;
      }

      if (first < three_byte_lead) {
        return 2;
      }

      return first < four_byte_lead ? 3 : 4;
    }

  }

  TextMetadataCapture::TextMetadataCapture(tbc::mut_a<ConcurrentMemory> memory)
      : links_(memory),
        runs_(memory),
        uris_(memory) {
    links_.reserve(maximum_links);
    runs_.reserve(maximum_runs);
    uris_.reserve(maximum_uri_bytes);
  }

  tbc::val_a<TextMetadata> TextMetadataCapture::view(tbc::val_a<std::span<const Byte>> row_flags) const noexcept {
    return TextMetadata{.status = status_, .row_flags = row_flags, .links = links_, .runs = runs_, .uris = uris_};
  }

  void TextMetadataCapture::capture(GhosttyRenderState state, GhosttyRenderStateRowIterator iterator, std::span<const Byte> row_flags, std::uint16_t columns) {
    links_.clear();
    runs_.clear();
    uris_.clear();
    status_ = MetadataStatus::complete;
    LinkTable table;

    checkGhostty(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, static_cast<void*>(&iterator)));
    std::uint32_t row = 0;

    while (ghostty_render_state_row_iterator_next(iterator)) {
      if ((row_flags[row] & static_cast<Byte>(RowFlag::hyperlinks)) != 0) {
        captureRow(table, iterator, row * columns);
      }

      ++row;
    }
  }

  tbc::val_a<std::string_view> TextMetadataCapture::stringView(tbc::val_a<GhosttyString> value) noexcept {
    return textView(ghosttyBytes(value));
  }

  std::size_t TextMetadataCapture::hash(const Identity& identity) noexcept {
    // FNV-1a's 64-bit prime.
    constexpr std::size_t fnv_prime = 1099511628211ULL;
    std::size_t value = identity.implicit_id;

    for (const auto text : {identity.uri, identity.explicit_id}) {
      for (const char character : text) {
        value = (value ^ static_cast<unsigned char>(character)) * fnv_prime;
      }
    }

    return value;
  }

  ds::Option<std::uint16_t> TextMetadataCapture::intern(tbc::mut_a<LinkTable> table, tbc::val_a<Identity> identity) {
    auto slot = hash(identity) % table.slots.size();

    while (table.slots[slot] != 0) {
      const auto index = static_cast<std::uint16_t>(table.slots[slot] - 1);
      if (table.identities[index] == identity) {
        return index;
      }

      slot = (slot + 1) % table.slots.size();
    }

    if (links_.size() == maximum_links || identity.uri.size() > maximum_uri_length || identity.explicit_id.size() > maximum_uri_length || identity.uri.size() > maximum_uri_bytes - uris_.size()) {
      status_ = MetadataStatus::partial;
      return ds::none;
    }

    const auto index = static_cast<std::uint16_t>(links_.size());

    links_.push(MetadataLink{.offset = static_cast<std::uint32_t>(uris_.size()), .len = static_cast<std::uint16_t>(identity.uri.size())});
    uris_.extend(byteView(identity.uri));
    table.identities.atMut(index) = identity;
    table.slots.atMut(slot) = index + 1;
    return index;
  }

  void TextMetadataCapture::captureRow(LinkTable& table, GhosttyRenderStateRowIterator iterator, std::uint32_t row_start) {
    auto reference = ghosttySized<GhosttyGridRef>();
    GhosttyCellsView cells{};

    checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_GRID_REF, &reference));
    checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &cells));
    bool continuing = false;
    const auto row_cells = ghosttyCells(cells);

    for (std::size_t column = 0; column < row_cells.size(); ++column) {
      const auto raw = row_cells[column];
      if ((cell_layout::hyperlink(raw) == 0U) || cell_layout::wide(raw) == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
        continuing = false;
        continue;
      }

      reference.x = static_cast<std::uint16_t>(column);
      GhosttyString uri{};
      GhosttyString explicit_id{};
      std::uint64_t implicit_id = 0;
      const auto result = ghostty_grid_ref_hyperlink(&reference, &uri, &explicit_id, &implicit_id);
      if (result == GHOSTTY_NO_VALUE || uri.len == 0) {
        continuing = false;
        continue;
      }

      checkGhostty(result);
      const auto index = intern(table, Identity{.uri = stringView(uri), .explicit_id = stringView(explicit_id), .implicit_id = implicit_id});
      if (!index) {
        continuing = false;
        continue;
      }

      if (continuing && runs_.back().link_index == *index) {
        ++runs_.atMut(runs_.size() - 1).len;
      } else if (runs_.size() != maximum_runs) {
        runs_.push(MetadataRun{.start = row_start + static_cast<std::uint32_t>(column), .len = 1, .link_index = *index});
      } else {
        status_ = MetadataStatus::partial;
        return;
      }

      continuing = true;
    }
  }

  bool ScreenCell::operator==(const ScreenCell& other) const noexcept {
    // Compared as its bytes, which it has no padding among.
    using Words = ds::Array<std::uint64_t, sizeof(ScreenCell) / sizeof(std::uint64_t)>;

    return std::bit_cast<Words>(*this) == std::bit_cast<Words>(other);
  }

  Cell ScreenCell::view() const noexcept {
    return Cell{.width = width, .style = style, .text = std::span<const Byte>{text}.first(length)};
  }

  Screen::Screen(ConcurrentMemory& memory)
      : cells(memory),
        row_revisions(memory),
        row_flags(memory),
        metadata(memory) {}

  void Screen::reserve(std::uint16_t columns, std::uint16_t lines) {
    constexpr std::size_t maximum_cells = 130359;
    const auto count = static_cast<std::size_t>(columns) * lines;
    if (columns == 0 || lines == 0 || count > maximum_cells) {
      throw EncodingError{"Terminal size exceeds the wire limit"};
    }

    cells.reserve(count);
    row_revisions.reserve(lines);
    row_flags.reserve(lines);
  }

  void Screen::resize(std::uint16_t columns, std::uint16_t lines) {
    reserve(columns, lines);
    cells.resize(static_cast<std::size_t>(columns) * lines);
    row_revisions.resize(lines);
    row_flags.resize(lines);
    cols = columns;
    rows = lines;
    ++revision;
    ++metadata_revision;
    std::ranges::fill(row_revisions.viewMut(), revision);
  }

  TerminalEffects::TerminalEffects(tbc::mut_a<ConcurrentMemory> memory)
      : clipboard(memory),
        document(memory),
        inline_documents(memory) {}

  void TerminalEffects::keepInline(tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> bytes, tbc::val_a<TrackedRow> first, tbc::val_a<TrackedRow> end, bool end_inclusive) {
    while (!inline_documents.empty() && (inline_documents.size() >= ::telar::render::max_pane_documents || inline_bytes + bytes.size() > ::telar::render::max_pane_document_bytes)) {
      inline_bytes -= inline_documents.front().bytes.size();
      static_cast<void>(inline_documents.remove(0));
    }

    inline_bytes += bytes.size();
    inline_documents.push(InlineDocument{.id = next_document_id++, .bytes = std::move(bytes), .first = std::move(first), .end = std::move(end), .end_inclusive = end_inclusive, .row = 0, .rows = 0, .contents = ds::Vec<std::uint64_t, ConcurrentMemory>{inline_documents.memory()}});
    ++inline_revision;
  }

  void TerminalEffects::placeInline(GhosttyTerminal terminal) noexcept { // NOLINT(bugprone-exception-escape): only growing a document's row contents throws, and a process without memory for it ends, as noexcept states
    for (std::size_t index = 0; index < inline_documents.size();) {
      auto& placed = inline_documents.atMut(index);

      const auto first = placed.first.row(terminal);
      const auto end = placed.end.row(terminal);
      const auto last = end ? *end + (placed.end_inclusive ? 1 : 0) : 0;
      if (!first || !end || last <= *first) {
        inline_bytes -= placed.bytes.size();
        static_cast<void>(inline_documents.remove(index));
        ++inline_revision;
        continue;
      }

      if (placed.row != *first || placed.rows != last - *first) {
        placed.row = *first;
        placed.rows = last - *first;
        placed.contents.clear();
        placed.contents.resize(placed.rows, 0);
        ++inline_revision;
      }

      ++index;
    }
  }

  void TerminalEffects::closeDocument() noexcept { // NOLINT(bugprone-exception-escape): shrinkToFit on an empty Vec only releases its storage, which never throws
    if (!document.empty()) {
      document.clear();
      document.shrinkToFit();
      ++document_revision;
    }
  }

  void TerminalEffects::refresh(GhosttyTerminal terminal) {
    if (title_pending) {
      GhosttyString value{};

      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &value));
      updateTitle(textView(ghosttyBytes(value)));
      title_pending = false;
    }

    if (cwd_pending) {
      GhosttyString value{};

      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &value));
      updateCwd(textView(ghosttyBytes(value)));
      cwd_pending = false;
    }
  }

  std::string_view TerminalEffects::title() const noexcept {
    return {title_.data(), title_length_};
  }

  std::string_view TerminalEffects::cwd() const noexcept {
    return {cwd_.data(), cwd_length_};
  }

  void TerminalEffects::setProgress(PaneProgressState state, ds::Option<Byte> percent) noexcept {
    if (state == progress_state && percent == progress_percent) {
      return;
    }

    progress_state = state;
    progress_percent = percent;
    ++progress_revision;
  }

  void TerminalEffects::updateTitle(std::string_view raw) {
    constexpr Byte first_printable = 0x20;
    constexpr Byte delete_character = 0x7f;
    decltype(title_) candidate{};
    std::size_t length = 0;

    while (!raw.empty()) {
      const auto first = static_cast<Byte>(raw.front());
      const std::size_t count = sequenceLength(first);
      if (raw.size() < count || count > candidate.size() - length) {
        break;
      }

      const auto sequence = raw.substr(0, count);

      raw.remove_prefix(count);
      if (count == 1 && (first < first_printable || first == delete_character)) {
        continue;
      }

      try {
        validateUtf8(sequence);
      } catch (const EncodingError&) {
        continue;
      }

      std::ranges::copy(sequence, candidate.viewMut().subspan(length).begin());
      length += count;
    }

    if (title() != std::string_view{candidate.data(), length}) {
      title_ = candidate;
      title_length_ = length;
      ++title_revision;
    }
  }

  void TerminalEffects::updateCwd(std::string_view raw) {
    bool encoded = false;

    for (const auto prefix : {std::string_view{"file://"}, std::string_view{"kitty-shell-cwd://"}}) {
      if (raw.starts_with(prefix)) {
        raw.remove_prefix(prefix.size());
        const auto slash = raw.find('/');
        if (slash == std::string_view::npos) {
          return;
        }

        raw.remove_prefix(slash);
        encoded = true;
        break;
      }
    }

    if (raw.empty() || raw.front() != '/' || raw.size() > cwd_.size()) {
      return;
    }

    decltype(cwd_) candidate{};
    std::size_t length = 0;

    while (!raw.empty()) {
      char character = raw.front();
      if (encoded && character == '%') {
        if (raw.size() < 3) {
          return;
        }

        constexpr int hexadecimal_base = 16;
        const auto byte = parseExact<unsigned>(raw.substr(1, 2), hexadecimal_base);
        if (!byte) {
          return;
        }

        character = static_cast<char>(*byte);
        raw.remove_prefix(2);
      }

      if (character == '\0') {
        return;
      }

      candidate.atMut(length++) = character;
      raw.remove_prefix(1);
    }

    if (cwd() != std::string_view{candidate.data(), length}) {
      cwd_ = candidate;
      cwd_length_ = length;
      ++cwd_revision;
    }
  }

  void encodeScreenCells(std::span<const ScreenCell> cells, std::span<Byte>& output) {
    const CellStyle* previous = nullptr;

    for (const auto& cell : cells) {
      constexpr Byte style_changed_bit = 0x80;
      constexpr unsigned width_shift = 5;
      const bool changed = previous == nullptr || !(cell.style == *previous);

      u8::encode(static_cast<Byte>(static_cast<unsigned>(cell.length) | (static_cast<unsigned>(cell.width) << width_shift) | (changed ? unsigned{style_changed_bit} : 0U)), output);

      if (changed) {
        ValueCodec<CellStyle>::encode(cell.style, output);
      }

      std::copy_n(cell.text.data(), cell.length, output.data());
      output = output.subspan(cell.length);
      previous = &cell.style;
    }
  }

  FrameSync::FrameSync(tbc::mut_a<ConcurrentMemory> memory, std::uint64_t pane_id)
      : pane_id_(pane_id),
        baseline_(memory),
        cell_bytes_(memory),
        payload_(memory),
        spans_(memory),
        metadata_bytes_(memory),
        previous_metadata_(memory) {
    spans_.reserve(maximum_spans);
    metadata_bytes_.resize(maximum_metadata_bytes);
    previous_metadata_.reserve(maximum_metadata_bytes);
  }

  bool FrameSync::acknowledge(std::uint64_t frame_id) noexcept {
    TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters_.value.ack});
    if (frame_id == 0 || frame_id != outstanding_id_) {
      return false;
    }

    acknowledged_id_ = frame_id;
    outstanding_id_ = 0;
    return true;
  }

  void FrameSync::requestSnapshot() noexcept {
    snapshot_pending_ = true;
  }

  bool FrameSync::needsSnapshot(const Screen& screen) const noexcept {
    return snapshot_pending_ || screen.cols != previous_header_.cols || screen.rows != previous_header_.rows;
  }

  bool FrameSync::waitingForAck() const noexcept {
    return outstanding_id_ != 0;
  }

  bool FrameSync::waitingForAck(const Screen& screen) const noexcept {
    return waitingForAck() && screen.cols == previous_header_.cols && screen.rows == previous_header_.rows;
  }

  std::uint64_t FrameSync::observedRevision() const noexcept {
    return observed_revision_;
  }

  std::span<const Byte> FrameSync::prepare(const Screen& screen) {
    TELAR_TRACE("frame_sync.prepare");
    TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters_.value.encode});
    if (screen.cols != previous_header_.cols || screen.rows != previous_header_.rows) {
      outstanding_id_ = 0;
      snapshot_pending_ = true;
      baseline_.resize(screen.cells.size());
      cell_bytes_.resize(screen.cells.size() * maximum_cell_bytes);
      payload_.resize(std::min(max_payload_size, (screen.cells.size() * maximum_cell_bytes) + maximum_metadata_bytes));
    }

    if (waitingForAck() || (!snapshot_pending_ && observed_revision_ == screen.revision)) {
      return {};
    }

    FrameBody header = frameHeader(screen);
    const bool full = snapshot_pending_ || acknowledged_id_ == 0;
    bool metadata_changed = false;
    std::size_t metadata_size = previous_metadata_.size();

    if (full || screen.metadata_revision != metadata_revision_) {
      auto output = std::span<Byte>{metadata_bytes_.viewMut()};

      ValueCodec<TextMetadata>::encode(screen.metadata.view(screen.row_flags), output);
      metadata_size = metadata_bytes_.size() - output.size();
      metadata_changed = metadata_size != previous_metadata_.size() || !std::equal(previous_metadata_.begin(), previous_metadata_.end(), metadata_bytes_.begin());
    }

    spans_.clear();
    // Cell bytes written so far: spans view them, so a position rather than a view travels.
    std::size_t written = 0;

    if (full) {
      appendSpan(screen.cells, 0, written);
    } else {
      appendDamage(screen, written);
      if (spans_.empty() && !metadata_changed && sameHeader(header, previous_header_)) {
        TELAR_DIAGNOSTIC(diagnostics::accumulate(counters_.value.noop_frames));
        observed_revision_ = screen.revision;
        metadata_revision_ = screen.metadata_revision;
        return {};
      }
    }

    header.frame_id = next_frame_id_;
    header.base_frame_id = full ? 0 : acknowledged_id_;
    if (full || metadata_changed) {
      header.text_metadata = screen.metadata.view(screen.row_flags);
    }

    header.spans = spans_;
    if (FrameSerializer::encodedSize(header) + 1 > payload_.size()) {
      spans_.clear();
      written = 0;
      appendSpan(screen.cells, 0, written);
      header.base_frame_id = 0;
      header.text_metadata = screen.metadata.view(screen.row_flags);
      header.spans = spans_;
    }

    auto output = std::span<Byte>{payload_.viewMut()};

    u8::encode(static_cast<Byte>(ServerTag::pane_frame), output);
    FrameSerializer::encodeBody(header, output);
    const auto size = payload_.size() - output.size();

    TELAR_DIAGNOSTIC(recordFrame(size, header.base_frame_id == 0));

    for (const auto& span : spans_) {
      std::ranges::copy(screen.cells.view().subspan(span.start, span.count), baseline_.viewMut().subspan(span.start).begin());
    }

    if (metadata_changed) {
      previous_metadata_.clear();
      previous_metadata_.extend(metadata_bytes_.view().first(metadata_size));
    }

    metadata_revision_ = screen.metadata_revision;
    // The header without the views of this frame, which the next one is compared with.
    previous_header_ = FrameBody{.pane_id = header.pane_id, .frame_id = header.frame_id, .base_frame_id = header.base_frame_id, .cols = header.cols, .rows = header.rows, .cursor = header.cursor, .mouse = header.mouse, .input_modes = header.input_modes, .pointer_shape = header.pointer_shape, .scroll = header.scroll};
    observed_revision_ = screen.revision;
    outstanding_id_ = next_frame_id_++;
    snapshot_pending_ = false;
    return std::span<const Byte>{payload_}.first(size);
  }

#if TELAR_DIAGNOSTICS
  diagnostics::FrameCounters FrameSync::Counters::take() const noexcept {
    return std::exchange(value, {});
  }

  diagnostics::FrameCounters FrameSync::takeCounters() const noexcept {
    return counters_.take();
  }
#endif

  FrameBody FrameSync::frameHeader(const Screen& screen) const noexcept {
    FrameBody header{};

    header.pane_id = pane_id_;
    header.cols = screen.cols;
    header.rows = screen.rows;
    header.cursor = screen.cursor;
    header.mouse = screen.mouse;
    header.input_modes = screen.input_modes;
    header.pointer_shape = screen.pointer_shape;
    header.scroll = screen.scroll;
    return header;
  }

  bool FrameSync::sameHeader(const FrameBody& left, const FrameBody& right) noexcept {
    const auto fields = [](const FrameBody& frame) {
      return std::tie(frame.cursor.visible, frame.cursor.x, frame.cursor.y, frame.cursor.shape, frame.cursor.blink, frame.mouse.tracking, frame.mouse.sgr, frame.mouse.pixels, frame.input_modes.cursor_keys, frame.input_modes.keypad_keys, frame.input_modes.bracketed_paste, frame.input_modes.paste_events, frame.input_modes.focus_events, frame.input_modes.alternate_scroll, frame.input_modes.alternate_screen, frame.input_modes.kitty_keyboard_flags, frame.input_modes.modify_other_keys_2, frame.pointer_shape, frame.scroll.total_rows, frame.scroll.offset);
    };

    return fields(left) == fields(right);
  }

  void FrameSync::appendDamage(const Screen& screen, std::size_t& written) {
    for (std::size_t row = 0; row < screen.rows; ++row) {
      if (screen.row_revisions[row] <= observed_revision_) {
        continue;
      }

      const auto row_start = row * screen.cols;
      std::size_t first = row_start;
      std::size_t end = row_start + screen.cols;

      while (first < end && screen.cells[first] == baseline_[first]) {
        ++first;
      }

      while (end > first && screen.cells[end - 1] == baseline_[end - 1]) {
        --end;
      }

      TELAR_DIAGNOSTIC(diagnostics::accumulate(counters_.value.damaged_rows));
      TELAR_DIAGNOSTIC(diagnostics::accumulate(counters_.value.diff_scanned_cells, first - row_start + row_start + screen.cols - end + (first < end ? 2 : 0)));

      if (first == end) {
        continue;
      }

      if (spans_.size() == maximum_spans) {
        spans_.clear();
        written = 0;
        appendSpan(screen.cells, 0, written);
        return;
      }

      appendSpan(std::span<const ScreenCell>{screen.cells}.subspan(first, end - first), first, written);
    }
  }

  void FrameSync::appendSpan(std::span<const ScreenCell> cells, std::size_t start, std::size_t& written) {
    auto output = std::span<Byte>{cell_bytes_.viewMut()}.subspan(written);
    const Byte* begin = output.data();

    encodeScreenCells(cells, output);
    written = cell_bytes_.size() - output.size();

    spans_.push(FrameSpan{
        .start = static_cast<std::uint32_t>(start),
        .count = static_cast<std::uint32_t>(cells.size()),
        .cells = {begin, static_cast<std::size_t>(output.data() - begin)},
    });
  }

#if TELAR_DIAGNOSTICS
  void FrameSync::recordFrame(std::size_t bytes, bool snapshot) noexcept {
    diagnostics::accumulate(counters_.value.frames);
    diagnostics::accumulate(counters_.value.frame_bytes, bytes);
    diagnostics::accumulate(counters_.value.frame_spans, spans_.size());
    diagnostics::accumulate(counters_.value.snapshots, static_cast<std::uint64_t>(snapshot));
    diagnostics::accumulate(counters_.value.cursor_only_frames, static_cast<std::uint64_t>(spans_.empty()));
    for (const auto& span : spans_) {
      diagnostics::accumulate(counters_.value.frame_cells, span.count);
    }
  }
#endif

  Terminal::Terminal(tbc::mut_a<ConcurrentMemory> memory, TerminalSize size, TerminalPurpose purpose, tbc::val_a<std::shared_ptr<PtyResponseQueue>> responses, tbc::val_a<GraphicsQueryResources> resources)
      : screen_(memory),
        effects_(memory),
        graphics_(memory),
        ghostty_memory_{.memory = memory},
        allocator_(ghostty_memory_),
        responses_(responses ? std::move(responses) : std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, ConcurrentMemory>{memory})),
        response_outbox_(memory, responses_),
        control_(memory, *responses_, purpose != TerminalPurpose::observation, resources),
        pending_control_input_(memory, control_input_limit),
        purpose_(purpose) {
    screen_.resize(size.cols, size.rows);
    checkGhostty(ghostty_terminal_new(allocator_.get(), terminal_.output(), size.cols, size.rows));
    checkGhostty(ghostty_render_state_new(allocator_.get(), render_state_.output()));
    checkGhostty(ghostty_render_state_row_iterator_new(allocator_.get(), row_iterator_.output()));
    checkGhostty(ghostty_render_state_row_cells_new(allocator_.get(), row_cells_.output()));
    control_.bind(terminal_.get(), render_state_.get(), purpose == TerminalPurpose::separate_media);

    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_USERDATA, this));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_WRITE_PTY, callbackAddress(&receiveResponse)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, callbackAddress(&titleChanged)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_PWD_CHANGED, callbackAddress(&cwdChanged)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, callbackAddress(&clipboardWrite)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, callbackAddress(&progressReported)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_SIZE, callbackAddress(&reportSize)));
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, default_palette_.dataMut()));
    const std::size_t scrollback_bytes = 10'000'000;

    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback_bytes));

    const GhosttyColorRgb foreground{.r = 255, .g = 255, .b = 255};
    const GhosttyColorRgb background{.r = 0, .g = 0, .b = 0};

    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background));
    const bool blink = true;

    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink));
    const bool disabled = false;
    const std::size_t image_storage = purpose == TerminalPurpose::interactive ? graphics_screen_bytes : 0;

    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &image_storage));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &disabled));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, nullptr));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &disabled));
    if (purpose != TerminalPurpose::interactive) {
      checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_PROTOCOL, &disabled));
    }

    resize(size);
  }

  tbc::val_b<std::span<const Byte>> Terminal::encodeKey(GhosttyKey key, GhosttyMods modifiers, tbc::val_b<std::span<Byte>> destination) {
    GhosttyHandle<GhosttyKeyEncoder, ghostty_key_encoder_free> encoder;
    GhosttyHandle<GhosttyKeyEvent, ghostty_key_event_free> event;

    checkGhostty(ghostty_key_encoder_new(allocator_.get(), encoder.output()));
    checkGhostty(ghostty_key_event_new(allocator_.get(), event.output()));
    ghostty_key_encoder_setopt_from_terminal(encoder.get(), terminal_.get());
    ghostty_key_event_set_action(event.get(), GHOSTTY_KEY_ACTION_PRESS);
    ghostty_key_event_set_key(event.get(), key);
    ghostty_key_event_set_mods(event.get(), modifiers);
    if (key == GHOSTTY_KEY_C) {
      ghostty_key_event_set_unshifted_codepoint(event.get(), 'c');
    }

    std::size_t length = 0;

    checkGhostty(ghostty_key_encoder_encode(encoder.get(), event.get(), reinterpret_cast<char*>(destination.data()), destination.size(), &length)); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the encoder writes chars, which Byte may alias
    return destination.first(length);
  }

  Terminal::~Terminal() {
    effects_.inline_documents.clear();
  }

  void Terminal::feed(std::span<const Byte> bytes) {
    TELAR_ASSERT(media_ == nullptr);
    feedWith(bytes, nullptr);
  }

  void Terminal::feed(std::span<const Byte> bytes, TerminalMedia& media) {
    feedWith(bytes, attached(media));
  }

  void Terminal::resumeControl() {
    TELAR_ASSERT(media_ == nullptr);
    resumeWith(nullptr);
  }

  void Terminal::resumeControl(TerminalMedia& media) {
    resumeWith(attached(media));
  }

  void Terminal::attachMedia(TerminalMedia& media) noexcept {
    TELAR_ASSERT(purpose_ == TerminalPurpose::separate_media && media_ == nullptr);
    media.requireOrderedInput();
    // Only its identity: the terminal never reaches the media through it.
    media_ = tbc::raw(&media);
    control_.enableMediaBoundaries();
  }

  bool Terminal::hasPendingControl() const noexcept {
    return response_outbox_.pending() || control_.blocked() || !pending_control_input_.empty();
  }

  void Terminal::configureClientFacts(control::ClientFacts facts) {
    control_.configureFacts(facts);
    control_.publishReports();
  }

  control::Policy& Terminal::controlPolicy() noexcept {
    return control_.policyMut();
  }

  control::Clipboard& Terminal::clipboardControl() noexcept {
    return control_.clipboard();
  }

  bool Terminal::pasteEvents() const noexcept {
    return control_.pasteEvents();
  }

  void Terminal::resize(TerminalSize size) {
    TELAR_ASSERT(media_ == nullptr);
    resizeWith(size, nullptr);
  }

  void Terminal::resize(TerminalSize size, TerminalMedia& media) {
    resizeWith(size, attached(media));
  }

  bool Terminal::hasSize(TerminalSize size) const noexcept {
    return size_ == size;
  }

  void Terminal::configureColors(const TerminalTheme& colors) {
    const auto foreground = colors.foreground ? GhosttyColorRgb{.r = (*colors.foreground)[0], .g = (*colors.foreground)[1], .b = (*colors.foreground)[2]} : GhosttyColorRgb{.r = 255, .g = 255, .b = 255};
    const auto background = colors.background ? GhosttyColorRgb{.r = (*colors.background)[0], .g = (*colors.background)[1], .b = (*colors.background)[2]} : GhosttyColorRgb{};
    const auto cursor = colors.cursor ? GhosttyColorRgb{.r = (*colors.cursor)[0], .g = (*colors.cursor)[1], .b = (*colors.cursor)[2]} : GhosttyColorRgb{};

    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, colors.cursor ? &cursor : nullptr));
    auto palette = default_palette_;

    if (colors.palette) {
      for (std::size_t index = 0; index < colors.palette->size() / 3; ++index) {
        palette.atMut(index) = {.r = (*colors.palette)[index * 3], .g = (*colors.palette)[(index * 3) + 1], .b = (*colors.palette)[(index * 3) + 2]};
      }
    }

    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette.data()));
    control_.externalColorsChanged();
    dirty_ = true;
    force_ = true;
  }

  bool Terminal::mode(GhosttyMode mode) const {
    GhosttyTerminalModeConfig query{.mode = mode, .value = false};

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MODE, &query));
    return query.value;
  }

  tbc::val_a<std::span<const Byte>> Terminal::drawScreen(tbc::val_a<std::span<Byte>> room) const {
    struct Room {
      std::span<Byte> bytes;
      std::size_t length = 0;
      bool full = false;

      bool append(std::span<const Byte> data) noexcept {
        if (full || data.size() > bytes.size() - length) {
          full = true;
          return false;
        }

        std::ranges::copy(data, bytes.subspan(length).begin());
        length += data.size();
        return true;
      }

      bool append(std::string_view text) noexcept {
        return append(byteView(text));
      }
    };

    Room drawn{.bytes = room};
    // The alternate screen is entered before its rows are drawn, so they land on it.
    constexpr std::uint16_t alternate_screen = 1049;
    constexpr std::uint16_t alternate_screen_plain = 1047;
    const bool alternate = mode(telar::ghostty::mode(alternate_screen, false)) || mode(telar::ghostty::mode(alternate_screen_plain, false));

    drawn.append("\x1b]0;");
    drawn.append(effects_.title());
    drawn.append("\x1b\\");
    if (alternate) {
      drawn.append("\x1b[?1049h");
    }

    drawn.append("\x1b[H\x1b[2J");
    auto options = ghosttySized<GhosttyFormatterTerminalOptions>();

    options.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    options.extra = ghosttySized<GhosttyFormatterTerminalExtra>();
    options.extra.modes = true;
    options.extra.scrolling_region = true;
    options.extra.screen = ghosttySized<GhosttyFormatterScreenExtra>();
    options.extra.screen.cursor = true;
    options.extra.screen.style = true;
    options.extra.screen.charsets = true;
    auto selection = ghosttySized<GhosttySelection>();

    selection.start = gridReference(terminal_.get(), GHOSTTY_POINT_TAG_ACTIVE, {.x = 0, .y = 0});
    selection.end = gridReference(terminal_.get(), GHOSTTY_POINT_TAG_ACTIVE, {.x = static_cast<std::uint16_t>(screen_.cols - 1), .y = static_cast<std::uint32_t>(screen_.rows - 1)});
    options.selection = &selection;
    FormatterHandle formatter;

    checkGhostty(ghostty_formatter_terminal_new(allocator(), formatter.output(), terminal_.get(), options));
    const auto write = [](void* userdata, const std::uint8_t* data, std::size_t length) noexcept {
    // GhosttyWriter hands the bytes as a C pointer and length.
#pragma clang unsafe_buffer_usage begin
      const std::span<const Byte> bytes{data, length};
#pragma clang unsafe_buffer_usage end

      return static_cast<Room*>(userdata)->append(bytes);
    };

    if (ghostty_formatter_format(formatter.get(), GhosttyWriter{.write = write, .userdata = &drawn}) != GHOSTTY_SUCCESS || drawn.full) {
      return {};
    }

    return room.first(drawn.length);
  }

  bool Terminal::outputSettled() const {
    bool ground = false;

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_VT_GROUND, &ground));
    return ground && control_.ground() && !hasPendingControl() && !mode(GHOSTTY_MODE_SYNC_OUTPUT);
  }

  void Terminal::refresh() {
    TELAR_TRACE("terminal.refresh");
    if (!dirty_) {
      return;
    }

    checkGhostty(ghostty_render_state_update(render_state_.get(), terminal_.get()));
    GhosttyRenderStateDirty damage{};

    checkGhostty(ghostty_render_state_get(render_state_.get(), GHOSTTY_RENDER_STATE_DATA_DIRTY, &damage));
    auto* iterator = row_iterator_.get();

    checkGhostty(ghostty_render_state_get(render_state_.get(), GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, static_cast<void*>(&iterator)));
    const bool recolored = projection_.updateColors(terminal_.get(), render_state_.get());

    ++screen_.revision;
    // Rows drawn with the previous default colors are projected again, with every other row.
    const bool all_rows = force_ || recolored || damage == GHOSTTY_RENDER_STATE_DIRTY_FULL;
    bool rebuild_links = all_rows;
    bool metadata_changed = all_rows;
    std::uint16_t row = 0;

    while (all_rows ? ghostty_render_state_row_iterator_next(iterator) : ghostty_render_state_row_iterator_next_dirty(iterator, &row)) {
      auto destination = std::span<ScreenCell>{screen_.cells.viewMut()}.subspan(static_cast<std::size_t>(row) * screen_.cols, screen_.cols);

      projection_.copyRow(iterator, row_cells_.get(), destination);
      screen_.row_revisions.atMut(row) = screen_.revision;
      const auto flags = readRowFlags(iterator);

      rebuild_links |= (static_cast<Byte>(screen_.row_flags[row] | flags) & static_cast<Byte>(RowFlag::hyperlinks)) != 0;
      metadata_changed |= screen_.row_flags[row] != flags;
      screen_.row_flags.atMut(row) = flags;

      if (all_rows) {
        ++row;
      }
    }

    if (rebuild_links) {
      screen_.metadata.capture(render_state_.get(), iterator, screen_.row_flags, screen_.cols);
    }

    if (rebuild_links || metadata_changed) {
      ++screen_.metadata_revision;
    }

    if (purpose_ == TerminalPurpose::interactive) {
      graphics_.update(terminal_.get());
    }

    updateCursor();
    updateModes();
    updateScroll();
    checkInline();
    checkGhostty(ghostty_render_state_clean(render_state_.get()));
    dirty_ = false;
    force_ = false;
  }

  void Terminal::scrollTo(std::uint32_t row) {
    GhosttyTerminalScrollViewport viewport{.tag = GHOSTTY_SCROLL_VIEWPORT_ROW, .value = {.row = row}};

    ghostty_terminal_scroll_viewport(terminal_.get(), viewport);
    dirty_ = true;
    force_ = true;
  }

  void Terminal::scrollToBottom() {
    GhosttyTerminalScrollViewport viewport{.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM, .value = {}};

    ghostty_terminal_scroll_viewport(terminal_.get(), viewport);
    dirty_ = true;
    force_ = true;
  }

  std::uint64_t Terminal::scrollbackGeneration() const noexcept {
    return scrollback_generation_;
  }

  std::uint64_t Terminal::scrollbackTrimmed() const noexcept {
    return scrollback_trimmed_;
  }

  std::uint32_t Terminal::followScrollback() {
    if (!primaryScreen()) {
      return 0;
    }

    if (!scrollback_origin_) {
      trackScrollbackOrigin();
      return 0;
    }

    const auto row = scrollbackOriginRow();
    if (row && *row == scrollback_origin_row_) {
      // Kept near the bottom, so the scrollback never drops it with its oldest rows.
      if (telar::runtime::totalRows(terminal_.get()) > static_cast<std::size_t>(scrollback_origin_row_) + origin_distance) {
        trackScrollbackOrigin();
      }

      return 0;
    }

    std::uint32_t dropped = 0;

    if (row && *row < scrollback_origin_row_) {
      dropped = scrollback_origin_row_ - *row;
      scrollback_trimmed_ += dropped;
    } else {
      ++scrollback_generation_;
    }

    trackScrollbackOrigin();
    return dropped;
  }

  std::span<const Byte> Terminal::responses() const noexcept {
    return responses_->readable();
  }

  void Terminal::consumeResponses(std::size_t count) {
    responses_->consume(count);
    resumeControl();
  }

  void Terminal::consumeResponses(std::size_t count, TerminalMedia& media) {
    responses_->consume(count);
    resumeControl(media);
  }

  void Terminal::discardResponses() noexcept {
    response_outbox_.discard();
    responses_->clear();
  }

  void Terminal::abortControl() noexcept {
    media_ = nullptr;
    control_.discard();
    response_outbox_.discard();
    pending_control_input_.clear();
    responses_->close();
  }

  bool Terminal::dirty() const noexcept {
    return dirty_;
  }

  std::uint64_t Terminal::contentRevision() const noexcept {
    return content_revision_;
  }

  std::size_t Terminal::totalRows() const {
    return telar::runtime::totalRows(handle());
  }

  GhosttyTerminal Terminal::handle() const noexcept {
    return terminal_.get();
  }

  const GhosttyAllocator* Terminal::allocator() const noexcept {
    return allocator_.get();
  }

#if TELAR_DIAGNOSTICS
  diagnostics::TerminalStorageSnapshot Terminal::storageMetrics() const {
    std::size_t page_bytes = 0;

    checkGhostty(ghostty_terminal_page_bytes(terminal_.get(), &page_bytes));
    return {.page_bytes = page_bytes, .screen_bytes = screen_.cells.size() * sizeof(ScreenCell)};
  }
#endif

  tbc::val_b<TerminalMedia*> Terminal::attached(tbc::mut_b<TerminalMedia> media) const noexcept {
    TELAR_ASSERT(media_ == nullptr || media_ == &media);
    return media_ != nullptr ? &media : nullptr;
  }

  void Terminal::feedWith(std::span<const Byte> bytes, TerminalMedia* media) {
    TELAR_TRACE("terminal.feed");
    ++content_revision_;
    resumeWith(media);
    if (hasPendingControl()) {
      pending_control_input_.append(bytes);
    } else {
      const auto consumed = feedControl(bytes, media);
      if (consumed < bytes.size()) {
        pending_control_input_.append(bytes.subspan(consumed));
      }
    }

    finishControlInput();
  }

  void Terminal::resumeWith(TerminalMedia* media) {
    const bool pending = hasPendingControl();
    if (!pending) {
      return;
    }

    if (control_.awaitingMedia()) {
      if (media == nullptr || !media->idle()) {
        return;
      }

      control_.mediaComplete();
    }

    if (!response_outbox_.drain()) {
      return;
    }

    const auto consumed = feedControl(pending_control_input_.readable(), media);

    pending_control_input_.consume(consumed);
    if (pending) {
      ++content_revision_;
      finishControlInput();
    }
  }

  void Terminal::resizeWith(TerminalSize size, TerminalMedia* media) {
    if (hasSize(size)) {
      return;
    }

    // A reflow moves the documents' text to other rows; what they hold is learnt anew.
    for (auto& document : effects_.inline_documents.viewMut()) {
      std::ranges::fill(document.contents.viewMut(), 0);
    }

    screen_.reserve(size.cols, size.rows);
    checkGhostty(ghostty_terminal_resize(terminal_.get(), size.cols, size.rows, size.cell_width_px, size.cell_height_px));
    if (screen_.cols != size.cols || screen_.rows != size.rows) {
      screen_.resize(size.cols, size.rows);
    }

    size_ = size;
    control_.configureSize(size);
    resumeWith(media);
    ++content_revision_;
    // A reflow numbers the rows anew.
    ++scrollback_generation_;
    scrollback_origin_ = {};
    dirty_ = true;
    force_ = true;
  }

  std::size_t Terminal::feedControl(std::span<const Byte> bytes, TerminalMedia* media) {
    const auto atomic = media != nullptr && control_.ground() && !control_.blocked() ? media->atomicPrefix(bytes) : 0;
    const auto consumed = atomic != 0 ? control_.feedAtomicMedia(bytes.first(atomic)) : control_.feed(bytes);

    if (control_.takeDocument(effects_.document)) {
      ++effects_.document_revision;
    }

    while (auto zone = control_.takeZone()) {
      effects_.keepInline(std::move(zone.getMut().bytes), std::move(zone.getMut().first), std::move(zone.getMut().end), zone->end_inclusive);
    }

    if (media != nullptr && consumed != 0) {
      media->output(bytes.first(consumed));
      if (media->failed()) {
        throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
      }
    }

    return consumed;
  }

  void Terminal::finishControlInput() {
    response_outbox_.drain();
    dirty_ = true;
    effects_.refresh(terminal_.get());
    if (purpose_ == TerminalPurpose::interactive) {
      graphics_.update(terminal_.get());
    }

    bool processing_error = false;

    // A processing error stays set once raised; the pane fails only when its memory ran out.
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &processing_error));
    if (processing_error && ghostty_memory_.refusals.load(std::memory_order_relaxed) != 0) {
      throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
    }
  }

  void Terminal::titleChanged(GhosttyTerminal /*terminal*/, void* context) noexcept {
    static_cast<Terminal*>(context)->effects_.title_pending = true;
  }

  void Terminal::cwdChanged(GhosttyTerminal /*terminal*/, void* context) noexcept {
    static_cast<Terminal*>(context)->effects_.cwd_pending = true;
  }

  GhosttyClipboardWriteResult Terminal::clipboardWrite(GhosttyTerminal /*terminal*/, void* context, const GhosttyClipboardWrite* write) noexcept {
    // Clipboard protocols are owned by the native controller. A backend
    // callback indicates a filter failure and must never bypass its policy.
    (void)context;
    (void)write;
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
  }

  void Terminal::progressReported(GhosttyTerminal /*terminal*/, void* context, const GhosttyTerminalProgressReport* report) noexcept {
    if (report->size < sizeof(GhosttyTerminalProgressReport)) {
      return;
    }

    const auto percent = report->progress >= 0 ? ds::Option<Byte>{static_cast<Byte>(report->progress)} : ds::none;

    static_cast<Terminal*>(context)->effects_.setProgress(static_cast<PaneProgressState>(report->state), percent);
  }

  bool Terminal::reportSize(GhosttyTerminal /*terminal*/, void* context, GhosttySizeReportSize* output) noexcept {
    const auto size = static_cast<Terminal*>(context)->size_;
    if (size.cell_width_px == 0 || size.cell_height_px == 0) {
      return false;
    }

    *output = {.rows = size.rows, .columns = size.cols, .cell_width = size.cell_width_px, .cell_height = size.cell_height_px};
    return true;
  }

  void Terminal::receiveResponse(GhosttyTerminal /*terminal*/, void* context, const Byte* bytes, std::size_t count) noexcept {
    auto& terminal = *static_cast<Terminal*>(context);
    // Ghostty hands the response as a C pointer and length.
#pragma clang unsafe_buffer_usage begin
    const std::span<const Byte> response{bytes, count};
#pragma clang unsafe_buffer_usage end

    constexpr std::string_view graphics_prefix = "\x1b_G";
    if (terminal.purpose_ != TerminalPurpose::observation && textView(response).starts_with(graphics_prefix)) {
      try {
        terminal.response_outbox_.append(response);
      } catch (...) {
        terminal.control_.failWrite();
        terminal.responses_->stopProducing();
      }
    }
  }

  Byte Terminal::readRowFlags(GhosttyRenderStateRowIterator iterator) {
    GhosttyRow row{};

    checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &row));
    bool wrap = false;
    bool continuation = false;
    bool hyperlinks = false;

    checkGhostty(ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, &wrap));
    checkGhostty(ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &continuation));
    checkGhostty(ghostty_row_get(row, GHOSTTY_ROW_DATA_HYPERLINK, &hyperlinks));
    GhosttyRowSemanticPrompt prompt = GHOSTTY_ROW_SEMANTIC_NONE;

    checkGhostty(ghostty_row_get(row, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &prompt));

    Byte flags = 0;

    if (prompt == GHOSTTY_ROW_SEMANTIC_PROMPT) {
      flags |= static_cast<Byte>(RowFlag::prompt);
    } else if (prompt == GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION) {
      flags |= static_cast<Byte>(RowFlag::prompt_continuation);
    }

    if (wrap) {
      flags |= static_cast<Byte>(RowFlag::wrap);
      GhosttyCellsView cells{};

      checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &cells));
      const auto row_cells = ghosttyCells(cells);
      if (!row_cells.empty() && cell_layout::wide(row_cells.back()) == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
        flags |= static_cast<Byte>(RowFlag::wide_padding);
      }
    }

    if (continuation) {
      flags |= static_cast<Byte>(RowFlag::continuation);
    }

    if (hyperlinks) {
      flags |= static_cast<Byte>(RowFlag::hyperlinks);
    }

    return flags;
  }

  namespace {

    using CursorVisualStyle = decltype(GhosttyRenderStateCursor::visual_style);

    CursorShape cursorShape(CursorVisualStyle style) noexcept {
      switch (style) {
      case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
        return CursorShape::bar;
      case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
        return CursorShape::block;
      case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
        return CursorShape::underline;
      case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
        return CursorShape::hollow;
      case CursorVisualStyle::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_MAX_VALUE:
        return CursorShape::default_shape;
      }

      // A style outside the enum, as the old default.
      return CursorShape::default_shape;
    }

    // The most demanding mouse tracking the terminal's modes ask for.
    MouseTracking mouseTracking(const Terminal& terminal) {
      if (terminal.mode(GHOSTTY_MODE_ANY_MOUSE)) {
        return MouseTracking::any;
      }

      if (terminal.mode(GHOSTTY_MODE_BUTTON_MOUSE)) {
        return MouseTracking::button;
      }

      if (terminal.mode(GHOSTTY_MODE_NORMAL_MOUSE)) {
        return MouseTracking::normal;
      }

      return terminal.mode(GHOSTTY_MODE_X10_MOUSE) ? MouseTracking::x10 : MouseTracking::none;
    }

  }

  void Terminal::updateCursor() {
    auto cursor = ghosttySized<GhosttyRenderStateCursor>();

    checkGhostty(ghostty_render_state_get(render_state_.get(), GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor));
    screen_.cursor.visible = cursor.visible && cursor.viewport_has_value;
    screen_.cursor.x = screen_.cursor.visible ? cursor.viewport_x : 0;
    screen_.cursor.y = screen_.cursor.visible ? cursor.viewport_y : 0;
    screen_.cursor.blink = cursor.blinking;
    bool default_shape = false;

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_CURSOR_IS_DEFAULT, &default_shape));
    if (default_shape || !screen_.cursor.visible) {
      screen_.cursor.shape = CursorShape::default_shape;
      if (!screen_.cursor.visible) {
        screen_.cursor.blink = true;
      }

      return;
    }

    screen_.cursor.shape = cursorShape(cursor.visual_style);
  }

  void Terminal::updateModes() {
    screen_.input_modes.cursor_keys = mode(GHOSTTY_MODE_DECCKM);
    screen_.input_modes.keypad_keys = mode(GHOSTTY_MODE_KEYPAD_KEYS);
    screen_.input_modes.bracketed_paste = mode(GHOSTTY_MODE_BRACKETED_PASTE);
    screen_.input_modes.paste_events = control_.pasteEvents();
    screen_.input_modes.focus_events = mode(GHOSTTY_MODE_FOCUS_EVENT);
    screen_.input_modes.alternate_scroll = mode(GHOSTTY_MODE_ALT_SCROLL);
    GhosttyTerminalScreen active_screen{};

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active_screen));
    screen_.input_modes.alternate_screen = active_screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    if (!screen_.input_modes.alternate_screen) {
      effects_.closeDocument();
      effects_.placeInline(terminal_.get());
    }

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &screen_.input_modes.kitty_keyboard_flags));

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MODIFY_OTHER_KEYS_2, &screen_.input_modes.modify_other_keys_2));
    GhosttyString pointer{};

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE_NAME, &pointer));
    static constexpr ds::Array<std::string_view, 34> shapes{
        "default",
        "context_menu",
        "help",
        "pointer",
        "progress",
        "wait",
        "cell",
        "crosshair",
        "text",
        "vertical_text",
        "alias",
        "copy",
        "move",
        "no_drop",
        "not_allowed",
        "grab",
        "grabbing",
        "all_scroll",
        "col_resize",
        "row_resize",
        "n_resize",
        "e_resize",
        "s_resize",
        "w_resize",
        "ne_resize",
        "nw_resize",
        "se_resize",
        "sw_resize",
        "ew_resize",
        "ns_resize",
        "nesw_resize",
        "nwse_resize",
        "zoom_in",
        "zoom_out",
    };

    const auto shape = textView(ghosttyBytes(pointer));
    const auto* const found = std::ranges::find(shapes, shape);

    screen_.pointer_shape = found == shapes.end() ? PointerShape::default_shape : static_cast<PointerShape>(found - shapes.begin());

    screen_.mouse.tracking = mouseTracking(*this);
    screen_.mouse.sgr = mode(GHOSTTY_MODE_SGR_MOUSE);
    screen_.mouse.pixels = mode(GHOSTTY_MODE_SGR_PIXELS_MOUSE);
  }

  bool Terminal::primaryScreen() const {
    GhosttyTerminalScreen active{};

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active));
    return active == GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  }

  void Terminal::checkInline() {
    if (effects_.inline_documents.empty() || !primaryScreen()) {
      return;
    }

    const auto top = static_cast<std::uint64_t>(screen_.scroll.offset);
    const auto rows = static_cast<std::uint64_t>(screen_.rows);
    const auto cols = static_cast<std::size_t>(screen_.cols);
    auto& documents = effects_.inline_documents;

    for (std::size_t index = 0; index < documents.size();) {
      auto& document = documents.atMut(index);

      bool changed = false;
      const auto first = std::max<std::uint64_t>(document.row, top);
      const auto end = std::min<std::uint64_t>(static_cast<std::uint64_t>(document.row) + document.rows, top + rows);

      for (auto row = first; row < end && !changed; ++row) {
        const auto screen_row = static_cast<std::size_t>(row - top);
        auto& known = document.contents.atMut(static_cast<std::size_t>(row - document.row));
        if (known != 0 && screen_.row_revisions[screen_row] != screen_.revision) {
          continue;
        }

        const auto cells = std::span<const ScreenCell>{screen_.cells}.subspan(screen_row * cols, cols);
        const auto content = std::hash<std::string_view>{}(std::string_view{reinterpret_cast<const char*>(cells.data()), cells.size_bytes()}) | std::size_t{1}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): hashes the cells' bytes, which char may alias

        changed = known != 0 && known != content;
        known = content;
      }

      if (changed) {
        effects_.inline_bytes -= document.bytes.size();
        static_cast<void>(documents.remove(index));
        ++effects_.inline_revision;
        continue;
      }

      ++index;
    }
  }

  void Terminal::trackScrollbackOrigin() {
    scrollback_origin_ = TrackedRow::active(terminal_.get(), 0);
    const auto row = scrollbackOriginRow();
    if (!row) {
      scrollback_origin_ = {};
      return;
    }

    scrollback_origin_row_ = *row;
  }

  ds::Option<std::uint32_t> Terminal::scrollbackOriginRow() const {
    return scrollback_origin_.row(terminal_.get());
  }

  void Terminal::updateScroll() {
    GhosttyTerminalScrollbar scrollbar{};

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar));
    screen_.scroll.total_rows = static_cast<std::uint32_t>(std::min<std::uint64_t>(scrollbar.total, std::numeric_limits<std::uint32_t>::max()));
    screen_.scroll.offset = static_cast<std::uint32_t>(std::min<std::uint64_t>(scrollbar.offset, std::numeric_limits<std::uint32_t>::max()));
  }

  ScrollbackRows::ScrollbackRows(tbc::mut_a<ConcurrentMemory> memory)
      : cells_(memory),
        runs_(memory) {}

  tbc::val_a<PaneRows> ScrollbackRows::read(tbc::mut_a<Terminal> terminal, const ReadPaneRows& request) {
    terminal.followScrollback();
    terminal.refresh();
    const auto trimmed = terminal.scrollbackTrimmed();
    const auto first = std::max(request.from, trimmed);
    PaneRows reply{.request_id = request.request_id, .pane_id = request.pane_id, .generation = terminal.scrollbackGeneration(), .trimmed = trimmed, .from = first};
    const auto& screen = terminal.screen();
    const auto total = static_cast<std::uint64_t>(screen.scroll.total_rows);
    const auto end = request.from + request.count;
    if (first >= end || first - trimmed >= total || screen.rows == 0 || screen.cols == 0) {
      return reply;
    }

    // One pass of the viewport: from its row, or from the last full view when the rows are
    // nearer the bottom than a screen.
    const auto row = static_cast<std::uint32_t>(first - trimmed);
    const auto top = std::min<std::uint32_t>(row, static_cast<std::uint32_t>(total - std::min<std::uint64_t>(total, screen.rows)));
    const auto skip = row - top;
    constexpr std::size_t metadata_margin = std::size_t{160} * 1024;
    const auto budget = (max_payload_size - metadata_margin) / (static_cast<std::size_t>(screen.cols) * maximum_cell_bytes);
    const auto count = static_cast<std::uint16_t>(std::min<std::uint64_t>({end - first, screen.rows - skip, total - row, budget, ReadPaneRows::maximum_rows}));
    if (count == 0) {
      return reply;
    }

    terminal.scrollTo(top);
    terminal.refresh();
    const auto& scrolled = terminal.screen();
    const auto cols = static_cast<std::size_t>(scrolled.cols);

    cells_.resize(static_cast<std::size_t>(count) * cols * maximum_cell_bytes);
    auto output = std::span<Byte>{cells_.viewMut()};

    encodeScreenCells(std::span<const ScreenCell>{scrolled.cells}.subspan(static_cast<std::size_t>(skip) * cols, static_cast<std::size_t>(count) * cols), output);

    // The links' runs of these rows, counted from their first cell.
    const auto metadata = scrolled.metadata.view(scrolled.row_flags);
    const auto first_cell = static_cast<std::uint64_t>(skip) * cols;
    const auto end_cell = first_cell + (static_cast<std::uint64_t>(count) * cols);

    runs_.clear();
    for (const auto& run : metadata.runs) {
      if (run.start >= first_cell && run.start < end_cell) {
        runs_.push(MetadataRun{.start = static_cast<std::uint32_t>(run.start - first_cell), .len = run.len, .link_index = run.link_index});
      }
    }

    reply.cells = std::span<const Byte>{cells_}.first(cells_.size() - output.size());
    // Back at the bottom before the reply views the screen: scrolling only marks the view for the
    // next refresh, so the screen still holds the rows read.
    terminal.scrollToBottom();

    const auto& read = terminal.screen();
    const auto kept = read.metadata.view(read.row_flags);

    reply.cols = read.cols;
    reply.rows = count;
    reply.text_metadata = TextMetadata{.status = kept.status, .row_flags = kept.row_flags.subspan(skip, count), .links = kept.links, .runs = runs_, .uris = kept.uris};
    return reply;
  }

  void formatTerminalSelection(const Terminal& terminal, const GhosttySelection& selection, bool unwrap, TrailingSpaces spaces, GhosttyWriter writer) {
    auto options = ghosttySized<GhosttyFormatterTerminalOptions>();

    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    options.unwrap = unwrap;
    options.trim = spaces == TrailingSpaces::trimmed;
    options.selection = &selection;
    options.extra = ghosttySized<GhosttyFormatterTerminalExtra>();
    options.extra.screen = ghosttySized<GhosttyFormatterScreenExtra>();
    FormatterHandle formatter;

    checkGhostty(ghostty_formatter_terminal_new(terminal.allocator(), formatter.output(), terminal.handle(), options));
    checkGhostty(ghostty_formatter_format(formatter.get(), writer));
  }

  TextReader::TextReader(ConcurrentMemory& memory, Terminal& terminal, std::size_t capacity)
      : terminal_(terminal),
        storage_(memory, capacity) {}

  void TextReader::read(PaneTextSource source, std::uint16_t wanted_rows) {
    const auto tag = source == PaneTextSource::screen ? GHOSTTY_POINT_TAG_ACTIVE : GHOSTTY_POINT_TAG_SCREEN;
    auto rows = source == PaneTextSource::screen ? terminal_.screen().rows : totalRows();
    const auto blank_limit = static_cast<std::size_t>(wanted_rows) + terminal_.screen().rows;
    std::size_t inspected = 0;

    while (rows != 0 && inspected++ < blank_limit && rowIsBlank(tag, rows - 1)) {
      --rows;
    }

    if (rows == 0) {
      return;
    }

    const auto count = std::min<std::uint32_t>(wanted_rows, rows);
    auto selection = ghosttySized<GhosttySelection>();

    selection.start = reference(tag, {.x = 0, .y = rows - count});
    selection.end = reference(tag, {.x = static_cast<std::uint16_t>(terminal_.screen().cols - 1), .y = rows - 1});
    format(selection, false, TrailingSpaces::kept);
  }

  void TextReader::copy(const CopySelection& request) {
    const auto columns = terminal_.screen().cols;
    const auto bottom = totalRows() - 1;
    GhosttyPointCoordinate start{
        .x = request.linewise ? std::uint16_t{0} : std::min<std::uint16_t>(request.start_x, columns - 1),
        .y = request.linewise ? std::min(request.start_y, request.end_y) : request.start_y,
    };

    GhosttyPointCoordinate end{
        .x = request.linewise ? static_cast<std::uint16_t>(columns - 1) : std::min<std::uint16_t>(request.end_x, columns - 1),
        .y = request.linewise ? std::max(request.start_y, request.end_y) : request.end_y,
    };

    for (auto* point : {&start, &end}) {
      if (point->y > bottom) {
        *point = {.x = static_cast<std::uint16_t>(columns - 1), .y = bottom};
      }
    }

    auto selection = ghosttySized<GhosttySelection>();

    selection.start = reference(GHOSTTY_POINT_TAG_SCREEN, start);
    selection.end = reference(GHOSTTY_POINT_TAG_SCREEN, end);
    format(selection, true, TrailingSpaces::trimmed);
  }

  std::span<const Byte> TextReader::bytes() const noexcept {
    return std::span<const Byte>{storage_.bytes()}.first(length_);
  }

  std::string_view TextReader::text() const noexcept {
    return textView(bytes());
  }

  bool TextReader::truncated() const noexcept {
    return wrapped_;
  }

  std::uint32_t TextReader::totalRows() const {
    return static_cast<std::uint32_t>(std::min<std::size_t>(terminal_.totalRows(), std::numeric_limits<std::uint32_t>::max()));
  }

  GhosttyGridRef TextReader::reference(GhosttyPointTag tag, GhosttyPointCoordinate coordinate) const {
    return gridReference(terminal_.handle(), tag, coordinate);
  }

  bool TextReader::rowIsBlank(GhosttyPointTag tag, std::uint32_t row) const {
    auto cell_ref = reference(tag, {.x = 0, .y = row});

    for (std::uint16_t column = 0; column < terminal_.screen().cols; ++column) {
      cell_ref.x = column;
      GhosttyCell raw = 0;

      checkGhostty(ghostty_grid_ref_cell(&cell_ref, &raw));
      if (cellHasText(raw) && cell_layout::codepoint(raw) != ' ') {
        return false;
      }
    }

    return true;
  }

  void TextReader::format(const GhosttySelection& selection, bool unwrap, TrailingSpaces spaces) {
    formatTerminalSelection(terminal_, selection, unwrap, spaces, GhosttyWriter{.write = receive, .userdata = this});

    if (!wrapped_) {
      length_ = position_;
      return;
    }

    const auto bytes = storage_.bytesMut();

    std::ranges::rotate(bytes, bytes.begin() + static_cast<std::ptrdiff_t>(position_));
    const auto newline = std::ranges::find(bytes, '\n');
    std::size_t start = newline == bytes.end() ? 0 : static_cast<std::size_t>(newline - bytes.begin() + 1);

    if (newline == bytes.end()) {
      constexpr Byte continuation_mask = 0xc0;
      constexpr Byte continuation_bits = 0x80;

      while (start < bytes.size() && (bytes[start] & continuation_mask) == continuation_bits) {
        ++start;
      }
    }

    std::ranges::move(bytes.subspan(start), bytes.begin());
    length_ = bytes.size() - start;
  }

  bool TextReader::receive(void* context, const Byte* bytes, std::size_t count) noexcept {
    auto& self = *static_cast<TextReader*>(context);
    // GhosttyWriter hands the text as a C pointer and length.
#pragma clang unsafe_buffer_usage begin
    std::span<const Byte> remaining{bytes, count};
#pragma clang unsafe_buffer_usage end

    while (!remaining.empty()) {
      if (self.position_ == self.storage_.bytes().size()) {
        self.position_ = 0;
        self.wrapped_ = true;
      }

      const auto copied = std::min(remaining.size(), self.storage_.bytes().size() - self.position_);

      std::ranges::copy(remaining.first(copied), self.storage_.bytesMut().subspan(self.position_).begin());
      remaining = remaining.subspan(copied);
      self.position_ += copied;
    }

    return true;
  }

}
