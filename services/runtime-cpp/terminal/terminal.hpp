#pragma once

#include "../diagnostics/terminal_storage.hpp"
#include "../diagnostics/trace.hpp"

#include "../graphics/storage.hpp"
#include "cell_projection.hpp"
#include "effects.hpp"
#include "ghostty_allocator.hpp"
#include "graphics_cursor.hpp"
#include "control/engine.hpp"
#include "../memory/byte_queue.hpp"
#include "pty_response_queue.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

enum class TerminalPurpose {
  interactive,
  separate_media,
  observation
};

template <Allocator Memory>
class Terminal {
public:
  explicit Terminal(Memory &memory, TerminalSize size, TerminalPurpose purpose = TerminalPurpose::interactive, std::shared_ptr<PtyResponseQueue> responses = {}, GraphicsQueryResources resources = {})
      : screen(memory),
        effects(memory),
        graphics(memory),
        allocator_(memory),
        responses_(responses ? std::move(responses) : std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory})),
        control_(memory, *responses_, purpose != TerminalPurpose::observation, resources),
        pending_control_input_(memory, control_input_limit),
        purpose_(purpose) {
    screen.resize(size.cols, size.rows);
    checkGhostty(ghostty_terminal_new(allocator_.get(), terminal_.output(), size.cols, size.rows));
    checkGhostty(ghostty_render_state_new(allocator_.get(), render_state_.output()));
    checkGhostty(ghostty_render_state_row_iterator_new(allocator_.get(), row_iterator_.output()));
    checkGhostty(ghostty_render_state_row_cells_new(allocator_.get(), row_cells_.output()));
    control_.bind(terminal_.get(), render_state_.get(), purpose == TerminalPurpose::separate_media);

    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_USERDATA, this));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void *>(&receiveResponse)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, reinterpret_cast<const void *>(&titleChanged)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_PWD_CHANGED, reinterpret_cast<const void *>(&cwdChanged)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, reinterpret_cast<const void *>(&clipboardWrite)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, reinterpret_cast<const void *>(&progressReported)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_SIZE, reinterpret_cast<const void *>(&reportSize)));
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, default_palette_.data()));
    const std::size_t scrollback_bytes = 10'000'000;
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback_bytes));

    const GhosttyColorRgb foreground{255, 255, 255};
    const GhosttyColorRgb background{0, 0, 0};
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

  std::span<const Byte> encodeKey(GhosttyKey key, GhosttyMods modifiers, std::span<Byte> destination) {
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
    checkGhostty(ghostty_key_encoder_encode(encoder.get(), event.get(), reinterpret_cast<char *>(destination.data()), destination.size(), &length));
    return destination.first(length);
  }

  void feed(std::span<const Byte> bytes) {
    TELAR_TRACE("terminal.feed");
    ++content_revision_;
    resumeControl();
    if (hasPendingControl()) {
      pending_control_input_.append(bytes);
    } else {
      const auto consumed = control_.feed(bytes);
      if (consumed < bytes.size()) {
        pending_control_input_.append(bytes.subspan(consumed));
      }
    }
    finishControlInput();
  }

  void resumeControl() {
    const bool pending = hasPendingControl();
    if (!pending) {
      return;
    }
    const auto consumed = control_.feed(pending_control_input_.readable());
    pending_control_input_.consume(consumed);
    if (pending) {
      ++content_revision_;
      finishControlInput();
    }
  }

  bool hasPendingControl() const noexcept {
    return control_.blocked() || !pending_control_input_.empty();
  }

  void configureClientFacts(control::ClientFacts facts) {
    control_.configureFacts(facts);
    control_.publishReports();
  }

  control::Policy &controlPolicy() noexcept {
    return control_.policy;
  }

  control::Clipboard<Memory> &clipboardControl() noexcept {
    return control_.clipboard();
  }

  bool pasteEvents() const noexcept {
    return control_.pasteEvents();
  }

  void resize(TerminalSize size) {
    if (hasSize(size)) {
      return;
    }

    screen.reserve(size.cols, size.rows);
    checkGhostty(ghostty_terminal_resize(terminal_.get(), size.cols, size.rows, size.cell_width_px, size.cell_height_px));
    if (screen.cols != size.cols || screen.rows != size.rows) {
      screen.resize(size.cols, size.rows);
    }

    size_ = size;
    control_.configureSize(size);
    resumeControl();
    ++content_revision_;
    dirty_ = true;
    force_ = true;
  }

  bool hasSize(TerminalSize size) const noexcept {
    return size_.cols == size.cols && size_.rows == size.rows && size_.cell_width_px == size.cell_width_px && size_.cell_height_px == size.cell_height_px;
  }

  void configureColors(const ConfigureTerminalColors &colors) {
    const auto foreground = colors.foreground ? GhosttyColorRgb{(*colors.foreground)[0], (*colors.foreground)[1], (*colors.foreground)[2]} : GhosttyColorRgb{255, 255, 255};
    const auto background = colors.background ? GhosttyColorRgb{(*colors.background)[0], (*colors.background)[1], (*colors.background)[2]} : GhosttyColorRgb{};
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background));
    auto palette = default_palette_;
    if (colors.palette) {
      for (std::size_t index = 0; index < colors.palette->size() / 3; ++index) {
        palette[index] = {(*colors.palette)[index * 3], (*colors.palette)[index * 3 + 1], (*colors.palette)[index * 3 + 2]};
      }
    }
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette.data()));
    control_.invalidateColors();
    dirty_ = true;
    force_ = true;
  }

  void configureCursorColor(std::optional<std::array<Byte, 3>> color) {
    const GhosttyColorRgb rgb = color ? GhosttyColorRgb{(*color)[0], (*color)[1], (*color)[2]} : GhosttyColorRgb{};
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, color ? &rgb : nullptr));
    control_.invalidateColors();
    dirty_ = true;
  }

  bool mode(GhosttyMode mode) const {
    GhosttyTerminalModeConfig query{.mode = mode,
                                    .value = false};
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MODE, &query));
    return query.value;
  }

  bool outputSettled() const {
    bool ground = false;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_VT_GROUND, &ground));
    return ground && control_.ground() && !hasPendingControl() && !mode(GHOSTTY_MODE_SYNC_OUTPUT);
  }

  void refresh() {
    TELAR_TRACE("terminal.refresh");
    if (!dirty_) {
      return;
    }

    checkGhostty(ghostty_render_state_update(render_state_.get(), terminal_.get()));
    GhosttyRenderStateDirty damage{};
    checkGhostty(ghostty_render_state_get(render_state_.get(), GHOSTTY_RENDER_STATE_DATA_DIRTY, &damage));
    auto iterator = row_iterator_.get();
    checkGhostty(ghostty_render_state_get(render_state_.get(), GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator));
    projection_.updateColors(terminal_.get(), render_state_.get());

    ++screen.revision;
    const bool all_rows = force_ || damage == GHOSTTY_RENDER_STATE_DIRTY_FULL;
    bool rebuild_links = all_rows;
    bool metadata_changed = all_rows;
    std::uint16_t row = 0;
    while (all_rows ? ghostty_render_state_row_iterator_next(iterator) : ghostty_render_state_row_iterator_next_dirty(iterator, &row)) {
      auto destination = std::span<ScreenCell>{screen.cells}.subspan(static_cast<std::size_t>(row) * screen.cols, screen.cols);
      projection_.copyRow(iterator, row_cells_.get(), destination);
      screen.row_revisions[row] = screen.revision;
      const auto flags = readRowFlags(iterator);
      rebuild_links |= ((screen.row_flags[row] | flags) & static_cast<Byte>(RowFlag::hyperlinks)) != 0;
      metadata_changed |= screen.row_flags[row] != flags;
      screen.row_flags[row] = flags;

      if (all_rows) {
        ++row;
      }
    }

    if (rebuild_links) {
      screen.metadata.capture(render_state_.get(), iterator, screen.row_flags, screen.cols);
    }

    if (rebuild_links || metadata_changed) {
      ++screen.metadata_revision;
    }

    if (purpose_ == TerminalPurpose::interactive) {
      graphics.update(terminal_.get());
    }
    updateCursor();
    updateModes();
    updateScroll();
    checkGhostty(ghostty_render_state_clean(render_state_.get()));
    dirty_ = false;
    force_ = false;
  }

  void scrollTo(std::uint32_t row) {
    GhosttyTerminalScrollViewport viewport{.tag = GHOSTTY_SCROLL_VIEWPORT_ROW,
                                           .value = {.row = row}};
    ghostty_terminal_scroll_viewport(terminal_.get(), viewport);
    dirty_ = true;
    force_ = true;
  }

  void scrollToBottom() {
    GhosttyTerminalScrollViewport viewport{.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
                                           .value = {}};
    ghostty_terminal_scroll_viewport(terminal_.get(), viewport);
    dirty_ = true;
    force_ = true;
  }

  std::span<const Byte> responses() const noexcept {
    return responses_->readable();
  }

  void consumeResponses(std::size_t count) {
    responses_->consume(count);
    resumeControl();
  }

  void discardResponses() noexcept {
    responses_->clear();
  }

  void abortControl() noexcept {
    control_.discard();
    pending_control_input_.clear();
    responses_->close();
  }

  bool dirty() const noexcept {
    return dirty_;
  }

  std::uint64_t contentRevision() const noexcept {
    return content_revision_;
  }

  GhosttyTerminal handle() const noexcept {
    return terminal_.get();
  }

  const GhosttyAllocator *allocator() const noexcept {
    return allocator_.get();
  }

#if TELAR_DIAGNOSTICS
  diagnostics::TerminalStorageSnapshot storageMetrics() const {
    std::size_t page_bytes = 0;
    checkGhostty(ghostty_terminal_page_bytes(terminal_.get(), &page_bytes));
    return {page_bytes, screen.cells.size() * sizeof(ScreenCell)};
  }
#endif

  Screen<Memory> screen;
  TerminalEffects<Memory> effects;
  GraphicsStorage<Memory> graphics;

private:
  void finishControlInput() {
    dirty_ = true;
    effects.refresh(terminal_.get());
    if (purpose_ == TerminalPurpose::interactive) {
      graphics.update(terminal_.get());
    }

    bool processing_error = false;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &processing_error));
    if (processing_error) {
      throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
    }
  }

  static void titleChanged(GhosttyTerminal, void *context) noexcept {
    static_cast<Terminal *>(context)->effects.title_pending = true;
  }

  static void cwdChanged(GhosttyTerminal, void *context) noexcept {
    static_cast<Terminal *>(context)->effects.cwd_pending = true;
  }

  static GhosttyClipboardWriteResult clipboardWrite(GhosttyTerminal, void *context, const GhosttyClipboardWrite *write) noexcept {
    // Clipboard protocols are owned by the native controller. A backend
    // callback indicates a filter failure and must never bypass its policy.
    (void)context;
    (void)write;
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
  }

  static void progressReported(GhosttyTerminal, void *context, const GhosttyTerminalProgressReport *report) noexcept {
    if (report->size < sizeof(GhosttyTerminalProgressReport)) {
      return;
    }

    const auto percent = report->progress >= 0 ? std::optional<Byte>{static_cast<Byte>(report->progress)} : std::nullopt;
    static_cast<Terminal *>(context)->effects.setProgress(static_cast<PaneProgressState>(report->state), percent);
  }

  static bool reportSize(GhosttyTerminal, void *context, GhosttySizeReportSize *output) noexcept {
    const auto size = static_cast<Terminal *>(context)->size_;
    if (size.cell_width_px == 0 || size.cell_height_px == 0) {
      return false;
    }
    *output = {.rows = size.rows,
               .columns = size.cols,
               .cell_width = size.cell_width_px,
               .cell_height = size.cell_height_px};
    return true;
  }

  static void receiveResponse(GhosttyTerminal, void *context, const Byte *bytes, std::size_t count) noexcept {
    auto &terminal = *static_cast<Terminal *>(context);

    constexpr std::string_view graphics_prefix = "\x1b_G";
    if (terminal.purpose_ != TerminalPurpose::observation && count >= graphics_prefix.size() && std::memcmp(bytes, graphics_prefix.data(), graphics_prefix.size()) == 0) {
      terminal.responses_->push({bytes, count});
    }
  }

  static Byte readRowFlags(GhosttyRenderStateRowIterator iterator) {
    GhosttyRow row{};
    checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &row));
    bool wrap = false;
    bool continuation = false;
    bool hyperlinks = false;
    checkGhostty(ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, &wrap));
    checkGhostty(ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &continuation));
    checkGhostty(ghostty_row_get(row, GHOSTTY_ROW_DATA_HYPERLINK, &hyperlinks));

    Byte flags = 0;
    if (wrap) {
      flags |= static_cast<Byte>(RowFlag::wrap);
      GhosttyCellsView cells{};
      checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &cells));
      if (cells.len != 0 && cell_layout::wide(cells.ptr[cells.len - 1]) == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
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

  void updateCursor() {
    auto cursor = ghosttySized<GhosttyRenderStateCursor>();
    checkGhostty(ghostty_render_state_get(render_state_.get(), GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor));
    screen.cursor.visible = cursor.visible && cursor.viewport_has_value;
    screen.cursor.x = screen.cursor.visible ? cursor.viewport_x : 0;
    screen.cursor.y = screen.cursor.visible ? cursor.viewport_y : 0;
    screen.cursor.blink = cursor.blinking;
    bool default_shape = false;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_CURSOR_IS_DEFAULT, &default_shape));
    if (default_shape || !screen.cursor.visible) {
      screen.cursor.shape = CursorShape::default_shape;
      if (!screen.cursor.visible) {
        screen.cursor.blink = true;
      }
      return;
    }

    switch (cursor.visual_style) {
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
      screen.cursor.shape = CursorShape::bar;
      break;
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
      screen.cursor.shape = CursorShape::block;
      break;
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
      screen.cursor.shape = CursorShape::underline;
      break;
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
      screen.cursor.shape = CursorShape::hollow;
      break;
    default:
      screen.cursor.shape = CursorShape::default_shape;
      break;
    }
  }

  void updateModes() {
    screen.input_modes.cursor_keys = mode(GHOSTTY_MODE_DECCKM);
    screen.input_modes.keypad_keys = mode(GHOSTTY_MODE_KEYPAD_KEYS);
    screen.input_modes.bracketed_paste = mode(GHOSTTY_MODE_BRACKETED_PASTE);
    screen.input_modes.focus_events = mode(GHOSTTY_MODE_FOCUS_EVENT);
    screen.input_modes.alternate_scroll = mode(GHOSTTY_MODE_ALT_SCROLL);
    GhosttyTerminalScreen active_screen{};
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active_screen));
    screen.input_modes.alternate_screen = active_screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &screen.input_modes.kitty_keyboard_flags));

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MODIFY_OTHER_KEYS_2, &screen.input_modes.modify_other_keys_2));
    GhosttyString pointer{};
#if defined(GHOSTTY_TELAR_STATE_VERSION) && GHOSTTY_TELAR_STATE_VERSION >= 2
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE_NAME, &pointer));
#else
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE, &pointer));
#endif
    static constexpr std::array<std::string_view, 34> shapes{
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
    const std::string_view shape{reinterpret_cast<const char *>(pointer.ptr), pointer.len};
    const auto found = std::find(shapes.begin(), shapes.end(), shape);
    screen.pointer_shape = found == shapes.end() ? PointerShape::default_shape : static_cast<PointerShape>(found - shapes.begin());

    screen.mouse.tracking = mode(GHOSTTY_MODE_ANY_MOUSE)      ? MouseTracking::any
                            : mode(GHOSTTY_MODE_BUTTON_MOUSE) ? MouseTracking::button
                            : mode(GHOSTTY_MODE_NORMAL_MOUSE) ? MouseTracking::normal
                            : mode(GHOSTTY_MODE_X10_MOUSE)    ? MouseTracking::x10
                                                              : MouseTracking::none;
    screen.mouse.sgr = mode(GHOSTTY_MODE_SGR_MOUSE);
    screen.mouse.pixels = mode(GHOSTTY_MODE_SGR_PIXELS_MOUSE);
  }

  void updateScroll() {
    GhosttyTerminalScrollbar scrollbar{};
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar));
    screen.scroll.total_rows = static_cast<std::uint32_t>(std::min<std::uint64_t>(scrollbar.total, UINT32_MAX));
    screen.scroll.offset = static_cast<std::uint32_t>(std::min<std::uint64_t>(scrollbar.offset, UINT32_MAX));
  }

  GhosttyAllocatorBridge<Memory> allocator_;
  TerminalHandle terminal_;
  RenderStateHandle render_state_;
  RowIteratorHandle row_iterator_;
  RowCellsHandle row_cells_;
  std::shared_ptr<PtyResponseQueue> responses_;
  static constexpr std::size_t control_input_limit = 128 * 1024;
  control::Engine<Memory> control_;
  ByteQueue<Memory> pending_control_input_;
  TerminalPurpose purpose_;
  CellProjection projection_;
  TerminalSize size_{};
  std::array<GhosttyColorRgb, 256> default_palette_{};
  bool dirty_ = true;
  bool force_ = true;
  std::uint64_t content_revision_ = 1;
};

}
