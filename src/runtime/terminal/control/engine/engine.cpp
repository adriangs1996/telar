module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.terminal.control.engine;

import telar.ghostty.vt;
import telar.render.document;
import telar.base.text.utf8;
import telar.runtime.terminal.control.glyph;
import telar.base.ds;
import telar.base.text;

namespace telar::runtime::control {

  namespace {

    // The palette indexes SGR names with codes of their own, and the standard eight among them.
    constexpr unsigned ansi_colors = 16;
    constexpr unsigned standard_colors = 8;

    // The bytes of the UTF-8 sequence that a lead byte begins.
    constexpr std::size_t utf8Length(std::uint8_t first) noexcept {
      constexpr std::uint8_t first_multibyte = 0x80;
      constexpr std::uint8_t first_three_byte = 0xe0;
      constexpr std::uint8_t first_four_byte = 0xf0;

      if (first < first_multibyte) {
        return 1;
      }

      if (first < first_three_byte) {
        return 2;
      }

      return first < first_four_byte ? 3 : 4;
    }

    // A title's character other than a C0 or C1 control or DEL, which a reply must not carry.
    constexpr bool titleCharacter(std::string_view text) noexcept {
      constexpr std::uint8_t c1_lead = 0xc2;
      constexpr std::uint8_t c1_continuation_end = 0xa0;
      const auto first = static_cast<std::uint8_t>(text.front());

      if (text.size() == 1) {
        return first >= ' ' && first != '\x7f';
      }

      return text.size() != 2 || first != c1_lead || static_cast<std::uint8_t>(text[1]) >= c1_continuation_end;
    }

    // DECSCUSR's blinking style for the cursor's shape; the steady style is the number after it.
    constexpr unsigned blinkingCursorStyle(const GhosttyRenderStateCursor& cursor) noexcept {
      constexpr unsigned blinking_block = 1;
      constexpr unsigned blinking_underline = 3;
      constexpr unsigned blinking_bar = 5;

      if (cursor.visual_style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR) {
        return blinking_bar;
      }

      return cursor.visual_style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE ? blinking_underline : blinking_block;
    }

    // The SGR code of the first of the eight colors a palette index below 16 is among: 30, 40, 90 or 100.
    constexpr unsigned sgrColor(bool background, bool bright) noexcept {
      constexpr unsigned foreground_base = 30;
      constexpr unsigned background_offset = 10;
      constexpr unsigned bright_offset = 60;

      return foreground_base + (background ? background_offset : 0) + (bright ? bright_offset : 0);
    }

  }

  Engine::Engine(tbc::mut_a<ConcurrentMemory> memory, tbc::mut_a<PtyResponseQueue> responses, bool enabled, tbc::val_a<GraphicsQueryResources> resources)
      : parser_(memory),
        reply_(memory),
        checksum_(memory),
        clipboard_(memory),
        graphics_queries_(memory, resources),
        reports_(memory),
        document_(memory),
        zones_(memory),
        responses_(responses),
        enabled_(enabled) {}

  Policy& Engine::policyMut() noexcept {
    return policy_;
  }

  void Engine::bind(tbc::val_a<GhosttyTerminal> terminal, tbc::val_a<GhosttyRenderState> render, bool separate_media) noexcept {
    state_.bind(terminal, render, separate_media);
  }

  void Engine::failWrite() noexcept {
    closed_ = true;
    state_.failWrite();
  }

  void Engine::enableMediaBoundaries() noexcept {
    media_boundaries_ = true;
  }

  bool Engine::awaitingMedia() const noexcept {
    return awaiting_media_;
  }

  void Engine::mediaComplete() noexcept {
    awaiting_media_ = false;
  }

  void Engine::discard() noexcept {
    closed_ = true;
    responses_.release();
    parser_.discard();
    reply_.discard();
    checksum_.discard();
    clipboard_.discard();
    graphics_queries_.discard();
    reports_.discard();
    colors_.discard();
    prepared_ = false;
    clipboard_before_reply_ = false;
    capability_offset_ = 0;
    awaiting_media_ = false;
    streamed_media_ = false;
  }

  std::size_t Engine::feed(std::span<const std::uint8_t> input) {
    if (closed_) {
      return input.size();
    }

    if (awaiting_media_) {
      return 0;
    }

    const ReleaseProducer release{responses_};

    if (parser_.blocked()) {
      parser_.feed({}, *this);
      if (parser_.blocked()) {
        return 0;
      }
    }

    if ((clipboard_.hasReply() && !clipboard_.publish(responses_)) || !reports_.publish(responses_, state_, facts_, enabled_)) {
      return 0;
    }

    return parser_.feed(input, *this);
  }

  std::size_t Engine::feedAtomicMedia(std::span<const std::uint8_t> input) {
    TELAR_ASSERT(media_boundaries_ && !blocked() && parser_.ground());
    media_boundaries_ = false;
    try {
      const auto consumed = feed(input);

      media_boundaries_ = true;
      if (consumed != input.size()) {
        throw std::logic_error{"Atomic graphics envelope was interrupted"};
      }

      awaiting_media_ = true;
      return consumed;
    } catch (...) {
      media_boundaries_ = true;
      throw;
    }
  }

  bool Engine::blocked() const noexcept {
    return awaiting_media_ || parser_.blocked() || reports_.pending() || clipboard_.hasReply();
  }

  bool Engine::ground() const noexcept {
    return parser_.ground();
  }

  void Engine::ordinary(std::span<const std::uint8_t> input) {
    history_erased_ = false;
    homed_ = false;
    responses_.release();
    state_.write(input);
  }

  std::size_t Engine::ordinaryRun(std::span<const std::uint8_t> input, std::size_t offset) {
    history_erased_ = false;
    homed_ = false;
    responses_.release();
    return state_.writeOrdinaryRun(input, offset);
  }

  void Engine::escapeBoundary() {
    if (state_.needsEscapeBoundary()) {
      responses_.release();
      state_.escapeBoundary();
    }
  }

  bool Engine::streamable(Sequence sequence) noexcept {
    const bool stream = control::streamable(sequence);
    if (stream && media_boundaries_ && sequence.kind == Kind::apc && sequence.body().starts_with('G')) {
      streamed_media_ = true;
    }

    return stream;
  }

  bool Engine::borrowableApc(Sequence header) noexcept {
    return graphicsQuery(header.body());
  }

  bool Engine::streamComplete() noexcept {
    if (std::exchange(streamed_media_, false)) {
      awaiting_media_ = true;
      return false;
    }

    return true;
  }

  bool Engine::enquire() {
    escapeBoundary();
    if (!enabled_ || policy_.answerback_length == 0) {
      return true;
    }

    return responses_.tryPush(byteView(std::string_view{policy_.answerback.view().first(policy_.answerback_length)}));
  }

  bool Engine::complete(Sequence sequence) {
    if (awaiting_media_) {
      return false;
    }

    // A retry already ran the sequence, and whatever it left of the flags stays.
    const bool history_erased = !prepared_ && std::exchange(history_erased_, false);
    const bool homed = !prepared_ && std::exchange(homed_, false);

    if (const auto published = publishing(sequence)) {
      return *published;
    }

    if (!prepared_) {
      reply_.clear();
      switch (sequence.kind) {
      case Kind::escape:
        escape(sequence);
        break;
      case Kind::csi:
        csi(sequence, history_erased, homed);
        break;
      case Kind::dcs:
        dcs(sequence);
        break;
      case Kind::osc:
        osc(sequence);
        break;
      case Kind::apc:
        apc(sequence);
        break;
      }

      clipboard_before_reply_ = clipboard_.hasReply();
      prepared_ = true;
      if (media_boundaries_ && sequence.kind == Kind::apc && sequence.body().starts_with('G')) {
        awaiting_media_ = true;
        return false;
      }
    }

    if (enabled_ && clipboard_before_reply_ && clipboard_.hasReply() && !clipboard_.publish(responses_)) {
      return false;
    }

    if (enabled_ && !reply_.publish(responses_)) {
      return false;
    }

    reply_.clear();
    if (enabled_ && clipboard_.hasReply() && !clipboard_.publish(responses_)) {
      return false;
    }

    prepared_ = false;
    clipboard_before_reply_ = false;
    return true;
  }

  ds::Option<bool> Engine::publishing(Sequence sequence) {
    constexpr unsigned palette_operation = 4;
    constexpr unsigned special_color_operation = 5;

    if (sequence.kind == Kind::osc) {
      const auto operation = oscOperation(sequence.body().substr(0, sequence.body().find(';')));
      if (operation == palette_operation || operation == special_color_operation) {
        return colors_.palette({.state = state_, .reply = reply_, .policy = policy_}, sequence, enabled_, responses_);
      }
    }

    if (sequence.kind == Kind::dcs) {
      const auto header_end = sequence.body().find_first_of("@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~");
      if (header_end != std::string_view::npos) {
        const auto parameters = Parameters::parse(sequence.body().substr(0, header_end + 1));
        if (parameters && !parameters->colon && parameters->final == 'q' && parameters->modifiers() == "+") {
          return termcap(sequence.body().substr(header_end + 1));
        }
      }
    }

    return ds::none;
  }

  void Engine::configureSize(TerminalSize size) {
    state_.configureSize(size);
    if (!closed_ && state_.mode(size_events_mode)) {
      reports_.changed(Report::size);
    }
  }

  void Engine::configureFacts(ClientFacts facts) noexcept {
    if (closed_) {
      facts_ = facts;
      return;
    }

    if (facts.light != facts_.light) {
      reports_.changed(Report::scheme);
    }

    if (facts.visible != facts_.visible) {
      reports_.changed(Report::visibility);
    }

    if (facts.focused != facts_.focused) {
      reports_.changed(Report::focus);
    }

    facts_ = facts;
  }

  void Engine::publishReports() {
    if (closed_ || awaiting_media_) {
      return;
    }

    const ReleaseProducer release{responses_};

    if (!parser_.blocked() && (!clipboard_.hasReply() || clipboard_.publish(responses_))) {
      reports_.publish(responses_, state_, facts_, enabled_);
    }
  }

  void Engine::externalColorsChanged() noexcept {
    state_.invalidateColors();
    if (!closed_ && state_.mode(scheme_events_mode)) {
      reports_.changed(Report::scheme);
    }
  }

  Clipboard& Engine::clipboard() noexcept {
    return clipboard_;
  }

  auto Engine::takeZone() noexcept -> tbc::val_a<ds::Option<Zone>> { // NOLINT(bugprone-exception-escape): the zones' bytes share the engine's memory, so moving them down hands their storage over without allocating
    if (zones_.empty()) {
      return ds::none;
    }

    ds::Option<Zone> zone{std::move(zones_.frontMut())};

    static_cast<void>(zones_.remove(0));
    return zone;
  }

  bool Engine::takeDocument(ds::Vec<std::uint8_t, ConcurrentMemory>& into) noexcept { // NOLINT(bugprone-exception-escape): the terminal's document shares the engine's memory, so the swap hands storage over without allocating
    if (!document_pending_) {
      return false;
    }

    std::swap(into, document_);
    document_.clear();
    document_pending_ = false;
    return true;
  }

  bool Engine::pasteEvents() const noexcept {
    return paste_events_;
  }

  void Engine::document(std::string_view encoded) noexcept {
    if (!enabled_ || encoded.size() > ::telar::render::max_sequence_body - ::telar::render::sequence_begin.size()) {
      return;
    }

    try {
      ds::Vec<std::uint8_t, ConcurrentMemory> bytes{document_.memory()};

      bytes.resize((encoded.size() / 4 * 3) + 3);
      const auto size = base64::decode<base64::Padding::optional>(encoded, bytes.viewMut());
      if (!size || *size > ::telar::render::max_document_bytes) {
        return;
      }

      bytes.resize(*size);
      if (state_.primaryScreen()) {
        open_zone_.emplace(Zone{.bytes = std::move(bytes), .first = state_.trackCursorRow(), .end = {}, .end_inclusive = false});
      } else {
        document_ = std::move(bytes);
        document_pending_ = true;
      }
    } catch (const std::bad_alloc&) { // NOLINT(bugprone-empty-catch): a document that cannot be kept is not shown; its text stays
    }
  }

  void Engine::closeZone() noexcept {
    if (!open_zone_ || !state_.primaryScreen()) {
      return;
    }

    auto zone = std::move(open_zone_.getMut());

    open_zone_.reset();
    zone.end_inclusive = state_.cursor().column != 0;
    zone.end = state_.trackCursorRow();
    if (!zone.first || !zone.end) {
      return;
    }

    try {
      if (zones_.size() == ::telar::render::max_pane_documents) {
        static_cast<void>(zones_.remove(0));
      }

      zones_.push(std::move(zone));
    } catch (const std::bad_alloc&) { // NOLINT(bugprone-empty-catch): a zone that cannot be kept is not shown; its text stays
    }
  }

  Engine::ReleaseProducer::ReleaseProducer(PtyResponseQueue::Producer& lease) noexcept
      : producer(lease) {}

  Engine::ReleaseProducer::~ReleaseProducer() {
    producer.release();
  }

  void Engine::passthrough(Sequence sequence) {
    responses_.release();
    state_.write(sequence.bytes);
    if (sequence.ending != Ending::final_byte) {
      state_.write(byteView(sequence.terminator()));
    }
  }

  void Engine::escape(Sequence sequence) {
    if (sequence.body() == "\\") {
      return;
    }

    if (sequence.body() == "Z") {
      attributes(false);
      return;
    }

    if (sequence.body() == "c") {
      checksum_.setFlags(0);
      paste_events_ = false;
      saved_desktop_modes_.fill(false);
      clipboard_.reset();
    }

    passthrough(sequence);
  }

  void Engine::attributes(bool secondary) {
    if (!enabled_) {
      return;
    }

    if (secondary) {
      reply_.append("\x1b[>1;0;0c");
    } else {
      reply_.append(policy_.clipboard_write == Access::deny ? "\x1b[?62;22c" : "\x1b[?62;22;52c");
    }
  }

  void Engine::csi(Sequence sequence, bool history_erased, bool homed) {
    const auto body = sequence.body();
    if (body == "5n") {
      operatingStatus();
      return;
    }

    if (body == "6n" || body == "?6n") {
      reportCursor(body.size() == 3);
      return;
    }

    const auto parameters = Parameters::parse(body);
    if (!parameters) {
      return;
    }

    if (parameters->colon && parameters->final != 'm') {
      return;
    }

    if (!csiAnswered(sequence, *parameters, history_erased, homed)) {
      passthrough(sequence);
    }
  }

  bool Engine::csiAnswered(Sequence sequence, const Parameters& parameters, bool history_erased, bool homed) {
    const auto modifiers = parameters.modifiers();

    switch (parameters.final) {
    case 'H':
    case 'f':
      cursorHome(parameters, history_erased);
      return false;
    case 'J':
      if (modifiers.empty() && parameters.count <= 1) {
        eraseDisplay(sequence, parameters.count == 0 ? 0 : parameters.values[0], history_erased, homed);
        return true;
      }

      return false;
    case 'h':
    case 'l':
    case 's':
    case 'r':
      if (modifiers == "?") {
        privateModes(parameters);
        return true;
      }

      return false;
    case 'y':
      return checksumRequest(parameters);
    case 'c':
      if (modifiers.empty() || modifiers == ">") {
        attributes(modifiers == ">");
      }

      return true;
    case 'n':
      if (modifiers.empty() || modifiers == "?") {
        status(parameters);
        return true;
      }

      return false;
    case 'p':
      return modeRequest(parameters);
    case 'q':
      if (modifiers == ">") {
        versionReport();
        return true;
      }

      return false;
    case 't':
      if (modifiers.empty() && parameters.count == 1 && parameters.values[0] >= pixels_request && parameters.values[0] <= title_request) {
        sizeReport(parameters.values[0]);
        return true;
      }

      return false;
    case 'u':
      if (modifiers == "?") {
        keyboardReport();
        return true;
      }

      return false;
    default:
      return false;
    }
  }

  bool Engine::modeRequest(const Parameters& parameters) {
    const auto modifiers = parameters.modifiers();

    if (modifiers == "!") {
      checksum_.setFlags(0);
    }

    if (modifiers == "$" || modifiers == "?$") {
      modeReport(parameters);
      return true;
    }

    return false;
  }

  void Engine::versionReport() {
    if (enabled_) {
      reply_.append("\x1bP>|telar ");
      reply_.append(program_version);
      reply_.append("\x1b\\");
    }
  }

  void Engine::keyboardReport() {
    if (enabled_) {
      reply_.append("\x1b[?");
      reply_.number(state_.keyboard());
      reply_.append("u");
    }
  }

  void Engine::cursorHome(const Parameters& parameters, bool history_erased) {
    if (!parameters.modifiers().empty()) {
      return;
    }

    history_erased_ = history_erased;
    homed_ = parameters.count <= 2 && std::ranges::all_of(parameters.values.view().first(parameters.count), [](std::uint16_t value) {
      return value <= 1;
    });
  }

  bool Engine::checksumRequest(const Parameters& parameters) {
    // DECRQCRA's Pid, Pp and the four edges of its rectangle.
    constexpr std::size_t checksum_parameters = 6;
    // The five XTCHECKSUM flags of ChecksumFlag.
    constexpr unsigned checksum_flags = 0x1f;
    const auto modifiers = parameters.modifiers();

    if (modifiers == "*" && parameters.count <= checksum_parameters) {
      if (enabled_ && policy_.checksum_report) {
        reply_.append("\x1bP");
        reply_.number(parameters.count == 0 ? 0 : parameters.values[0]);
        reply_.append("!~");
        reply_.hex(checksum_.compute(state_, parameters), {.width = 4, .upper = true});
        reply_.append("\x1b\\");
      }

      return true;
    }

    if (modifiers == "#" && parameters.count <= 1) {
      if (policy_.checksum_report) {
        checksum_.setFlags(parameters.count == 0 ? 0 : static_cast<unsigned>(parameters.values[0]) & checksum_flags);
      }

      return true;
    }

    return false;
  }

  void Engine::eraseDisplay(Sequence sequence, unsigned mode, bool history_erased, bool homed) {
    static constexpr ds::Array<std::uint8_t, 4> erase_history{0x1b, '[', '3', 'J'};
    static constexpr ds::Array<std::uint8_t, 4> erase_screen{0x1b, '[', '2', 'J'};

    if (mode == 0 && homed && homeOnPrimary()) {
      responses_.release();
      state_.write(erase_screen);
      mode = 2;
    } else {
      passthrough(sequence);
    }

    if (mode == 3) {
      history_erased_ = true;
    } else if (mode == 2 && history_erased) {
      state_.write(erase_history);
    }
  }

  bool Engine::homeOnPrimary() const {
    const auto cursor = state_.cursor();

    return cursor.column == 0 && cursor.row == 0 && state_.primaryScreen();
  }

  void Engine::privateModes(const Parameters& parameters) {
    for (std::size_t index = 0; index < parameters.count; ++index) {
      const auto mode = parameters.values[index];
      const auto* const owned = std::ranges::find(desktop_modes, mode);
      if (owned != desktop_modes.end()) {
        const auto slot = static_cast<std::size_t>(owned - desktop_modes.begin());

        if (parameters.final == 's') {
          saved_desktop_modes_.atMut(slot) = state_.mode(mode);
          continue;
        }

        const bool enabled = parameters.final == 'r' ? saved_desktop_modes_[slot] : parameters.final == 'h';

        state_.setMode(mode, enabled);
        modeEffect(mode, enabled);
        continue;
      }

      forwardPrivateMode(mode, parameters.final, [this](auto command) {
        ordinary(command);
      });
    }
  }

  void Engine::modeEffect(unsigned mode, bool set) {
    switch (mode) {
    case paste_events_mode:
      paste_events_ = set;
      break;
    case focus_events_mode:
      if (set && enabled_) {
        reply_.append(facts_.focused ? "\x1b[I" : "\x1b[O");
      }

      break;
    case visibility_mode:
      if (set && enabled_) {
        reply_.append(facts_.visible ? "\x1b[?999;1n" : "\x1b[?999;2n");
      }

      break;
    case size_events_mode:
      if (set) {
        sizeEvent();
      }

      break;
    default:
      break;
    }
  }

  void Engine::operatingStatus() {
    if (!enabled_) {
      return;
    }

    static constexpr ds::Array<std::uint8_t, 4> response{0x1b, '[', '0', 'n'};
    if (!clipboard_.hasReply() && responses_.tryPushFixed(response)) {
      return;
    }

    reply_.append("\x1b[0n");
  }

  void Engine::status(const Parameters& parameters) {
    if (!enabled_ || parameters.count != 1) {
      return;
    }

    constexpr unsigned operating_status_request = 5;
    constexpr unsigned cursor_position_request = 6;
    const auto request = parameters.values[0];
    const bool private_request = parameters.modifiers() == "?";
    if (request == operating_status_request && !private_request) {
      operatingStatus();
    } else if (request == cursor_position_request) {
      reportCursor(private_request);
    } else if (private_request && request == scheme_request) {
      reply_.append(facts_.light ? "\x1b[?997;2n" : "\x1b[?997;1n");
    } else if (private_request && request == visibility_request) {
      reply_.append(facts_.visible ? "\x1b[?999;1n" : "\x1b[?999;2n");
    }
  }

  // Out of line, as in the textual control headers: the cursor report inlines into this body,
  // and the requests that share csi() and status() do not carry its frame.
  [[gnu::noinline]] void Engine::reportCursor(bool extended) {
    if (!enabled_) {
      return;
    }

    auto position = state_.cursor();

    if (state_.mode(origin_mode)) {
      const auto margins = state_.margins();

      position.column -= std::min(position.column, margins.left);
      position.row -= std::min(position.row, margins.top);
    }

    cursorReport(reply_, position, extended);
  }

  bool Engine::knownMode(std::uint16_t value, bool ansi) noexcept {
    // KAM, IRM, SRM and LNM.
    constexpr ds::Array<std::uint16_t, 4> ansi_modes{2, 4, 12, 20};
    constexpr ds::Array<std::uint16_t, 38> private_modes{1, 3, 4, 5, 6, 7, 8, 9, 12, 25, 40, 45, 47, 66, 67, 69, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 1035, 1036, 1039, 1045, 1047, 1048, 1049, 2004, 2026, 2027, 2031, 2033, 2048};

    if (ansi) {
      return std::ranges::contains(ansi_modes, value);
    }

    return std::ranges::contains(private_modes, value);
  }

  void Engine::modeReport(const Parameters& parameters) {
    if (!enabled_ || parameters.count != 1) {
      return;
    }

    enum class ModeStatus : std::uint8_t {
      unknown,
      set,
      reset,
      permanently_set,
      permanently_reset,
    };

    // The ANSI modes of a VT100 that no terminal emulator implements.
    constexpr ds::Array<std::uint16_t, 12> permanently_reset_ansi_modes{1, 5, 7, 10, 11, 13, 14, 15, 16, 17, 18, 19};
    const auto value = parameters.values[0];
    const bool ansi = parameters.modifiers() == "$";
    ModeStatus report = ModeStatus::unknown;

    if (!ansi && value == paste_events_mode) {
      report = paste_events_ ? ModeStatus::set : ModeStatus::reset;
    } else if (knownMode(value, ansi)) {
      report = state_.mode(value, ansi) ? ModeStatus::set : ModeStatus::reset;
    } else if ((!ansi && value == erase_color_mode) || (ansi && std::ranges::contains(permanently_reset_ansi_modes, value))) {
      report = ModeStatus::permanently_reset;
    }

    reply_.append(ansi ? "\x1b[" : "\x1b[?");
    reply_.number(value);
    reply_.append(";");
    reply_.number(static_cast<unsigned>(report));
    reply_.append("$y");
  }

  void Engine::sizeEvent() {
    if (!enabled_) {
      return;
    }

    control::sizeReport<SizeReport::event>(reply_, state_.size());
  }

  void Engine::sizeReport(unsigned request) {
    if (!enabled_) {
      return;
    }

    if (request == title_request) {
      if (policy_.title_report) {
        titleReport();
      }

      return;
    }

    const auto size = state_.size();

    switch (request) {
    case pixels_request:
      control::sizeReport<SizeReport::pixels>(reply_, size);
      break;
    case cell_request:
      control::sizeReport<SizeReport::cell>(reply_, size);
      break;
    case text_request:
      control::sizeReport<SizeReport::text>(reply_, size);
      break;
    case screen_request:
      control::sizeReport<SizeReport::screen>(reply_, size);
      break;
    default:
      break;
    }
  }

  void Engine::titleReport() {
    reply_.append("\x1b]l");
    auto title = state_.title();

    while (!title.empty()) {
      const auto first = static_cast<std::uint8_t>(title.front());
      const auto count = utf8Length(first);
      if (title.size() < count) {
        break;
      }

      const auto text = title.substr(0, count);

      title.remove_prefix(count);
      if (!titleCharacter(text)) {
        continue;
      }

      try {
        validateUtf8(text);
      } catch (const EncodingError&) {
        continue;
      }

      reply_.append(text);
    }

    reply_.append("\x1b\\");
  }

  bool Engine::termcap(std::string_view request) {
    if (!enabled_) {
      return true;
    }

    while (capability_offset_ < request.size()) {
      const auto end = request.find(';', capability_offset_);
      const auto count = (end == std::string_view::npos ? request.size() : end) - capability_offset_;
      const auto response = capability(request.substr(capability_offset_, count));
      if (!response.empty() && !responses_.tryPush(response)) {
        return false;
      }

      capability_offset_ += count + 1;
    }

    capability_offset_ = 0;
    return true;
  }

  void Engine::dcs(Sequence sequence) {
    const auto end = sequence.body().find_first_of("@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~");
    if (end != std::string_view::npos) {
      const auto parameters = Parameters::parse(sequence.body().substr(0, end + 1));
      if (parameters && !parameters->colon && parameters->final == 'q' && parameters->modifiers() == "$") {
        statusString(sequence.body().substr(end + 1));
        return;
      }
    }

    if (sequence.body().starts_with("+q")) {
      return;
    }

    passthrough(sequence);
  }

  void Engine::statusString(std::string_view request) {
    if (!enabled_ || request.size() > 2) {
      return;
    }

    const bool horizontal = request == "s" && state_.mode(left_right_margin_mode);
    const bool valid = request == "m" || request == " q" || request == "r" || horizontal;

    reply_.append(valid ? "\x1bP1$r" : "\x1bP0$r");
    if (request == "m") {
      attributesString();
      reply_.append("m");
    } else if (request == " q") {
      reply_.number(blinkingCursorStyle(state_.visualCursor()) + static_cast<unsigned int>(!state_.mode(cursor_blink_mode)));
      reply_.append(" q");
    } else if (request == "r" || horizontal) {
      const auto margins = state_.margins();

      reply_.number(static_cast<unsigned>(horizontal ? margins.left : margins.top) + 1);
      reply_.append(";");
      reply_.number(static_cast<unsigned>(horizontal ? margins.right : margins.bottom) + 1);
      reply_.append(horizontal ? "s" : "r");
    }

    reply_.append("\x1b\\");
  }

  void Engine::attributesString() {
    const auto style = state_.style();

    reply_.append("0");
    const ds::Array<bool, 9> flags{style.bold, style.faint, style.italic, style.underline != 0, style.overline, style.blink, style.inverse, style.invisible, style.strikethrough};
    constexpr ds::Array<unsigned, flags.size()> codes{1, 2, 3, 4, 53, 5, 7, 8, 9};

    for (std::size_t index = 0; index < flags.size(); ++index) {
      if (flags[index]) {
        reply_.append(";");
        reply_.number(codes[index]);
        if (codes[index] == 4 && style.underline != 1) {
          reply_.append(":");
          reply_.number(static_cast<std::uint64_t>(style.underline));
        }
      }
    }

    styleColor(style.fg_color, false);
    styleColor(style.bg_color, true);
  }

  void Engine::styleColor(const GhosttyStyleColor& color, bool background) {
    if (color.tag == GHOSTTY_STYLE_COLOR_NONE) {
      return;
    }

    reply_.append(";");
    if (color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
      const auto index = color.value.palette;
      if (index < ansi_colors) {
        reply_.number(sgrColor(background, index >= standard_colors) + (index % standard_colors));
      } else {
        reply_.append(background ? "48:5:" : "38:5:");
        reply_.number(index);
      }
    } else if (color.tag == GHOSTTY_STYLE_COLOR_RGB) {
      reply_.append(background ? "48:2::" : "38:2::");
      reply_.number(color.value.rgb.r);
      reply_.append(":");
      reply_.number(color.value.rgb.g);
      reply_.append(":");
      reply_.number(color.value.rgb.b);
    }
  }

  void Engine::osc(Sequence sequence) {
    responses_.release();
    if (const auto body = sequence.body(); oscOperation(body.substr(0, body.find(';'))) == ::telar::render::sequence_number) {
      if (body.starts_with(::telar::render::sequence_begin)) {
        document(body.substr(::telar::render::sequence_begin.size()));
      } else if (body == ::telar::render::sequence_end) {
        closeZone();
      }

      return;
    }

    if (colors_.handle({.state = state_, .reply = reply_, .policy = policy_}, sequence, enabled_)) {
      return;
    }

    constexpr unsigned clipboard_operation = 52;
    constexpr unsigned kitty_clipboard_operation = 5522;
    auto remaining = sequence.body();
    const auto operation = oscOperation(takeField(remaining));
    if (operation == clipboard_operation) {
      if (enabled_) {
        clipboard_.traditional(remaining, policy_);
      }

      return;
    }

    if (operation == kitty_clipboard_operation) {
      if (enabled_) {
        clipboard_.kitty(remaining, sequence.ending, policy_, reply_);
      }

      return;
    }

    passthrough(sequence);
  }

  void Engine::apc(Sequence sequence) {
    constexpr std::string_view glyph_prefix = "25a1;";

    if (sequence.body().starts_with(glyph_prefix)) {
      if (enabled_) {
        glyph(sequence.body().substr(glyph_prefix.size()), reply_);
      }

      return;
    }

    if (sequence.body().starts_with('G') && graphics_queries_.handle(sequence.body(), reply_, enabled_)) {
      return;
    }

    passthrough(sequence);
  }

}
