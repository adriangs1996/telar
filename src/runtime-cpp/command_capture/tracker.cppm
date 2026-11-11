module;
#include "telar_platform/trace_macro.hpp"
#include <new>
#include <unistd.h>
#include <cerrno>
#include <limits.h>
#include <sys/stat.h>
#include <ghostty/vt.h>
#include <stdlib.h>
#include <zlib.h>

#include <cstdint>


#include "telar_base/diagnostics/config.hpp"
#include <cstring>


#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <cassert>

export module telar.runtime.command_capture.tracker;

import std;

export import telar.platform;


export import telar.runtime.diagnostics.runtime_counters;


export import telar.runtime.terminal.text_reader;
export import telar.runtime.shell_integration.token;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: command_capture/command.cppm
export {
namespace telar::runtime {

struct CapturedCommand {
  std::string_view command;
  std::string_view directory;
  ObservationTime started{};
  std::int64_t duration_ns = 0;
  std::optional<int> exit_code = std::nullopt;
  HistoryStatus status = HistoryStatus::completed;
  HistoryAuthor author = HistoryAuthor::human;
  bool truncated = false;
  std::span<const Byte> output{};
  std::uint64_t output_observed = 0;

  inline bool outputTruncated() const noexcept {
    return output_observed > output.size();
  }
};

template <typename Sink>
concept CapturedCommandSink = requires(Sink &sink, const CapturedCommand &command) {
  { sink.emit(command) } -> std::same_as<void>;
};

struct CommandByteObservation {
  std::span<const Byte> bytes;
  ObservationTime time;
  std::optional<bool> shell_foreground;
};

}
}

// Interface: command_capture/input_scanner.cppm
export {
namespace telar::runtime {

class CommandInputScanner {
public:
  struct Event {
    bool submitted = false;
    bool cancelled = false;
  };

  inline Event feed(std::span<const Byte> bytes) noexcept {
    Event event;
    for (const auto byte : bytes) {
      switch (state_) {
      case State::ground:
        ground(byte, event);
        break;
      case State::escape:
        beginSequence(byte, false);
        break;
      case State::sequence:
        sequence(byte, false);
        break;
      case State::paste:
        if (byte == escape) {
          state_ = State::paste_escape;
        }
        break;
      case State::paste_escape:
        beginSequence(byte, true);
        break;
      case State::paste_sequence:
        sequence(byte, true);
        break;
      }
    }

    return event;
  }

  inline void reset() noexcept {
    state_ = State::ground;
    parameter_ = 0;
    has_parameter_ = false;
    typed_count_ = 0;
    typed_exact_ = true;
  }

  inline std::optional<std::string_view> typedText() const noexcept {
    return typed_exact_ ? std::optional<std::string_view>{{typed_.data(), typed_count_}} : std::nullopt;
  }

private:
  enum class State {
    ground,
    escape,
    sequence,
    paste,
    paste_escape,
    paste_sequence
  };
  static constexpr Byte escape = 0x1b;
  static constexpr unsigned paste_start = 200;
  static constexpr unsigned paste_end = 201;

  inline void ground(Byte byte, Event &event) noexcept {
    switch (byte) {
    case escape:
      state_ = State::escape;
      typed_exact_ = false;
      break;
    case '\r':
    case '\n':
      event.submitted = true;
      break;
    case 0x03:
      event.cancelled = true;
      break;
    case 0x08:
    case 0x7f:
      typed_count_ -= typed_count_ != 0;
      break;
    case 0x0c:
      break;
    default:
      if (byte >= 0x20 && byte <= 0x7e && typed_count_ < typed_.size()) {
        typed_[typed_count_++] = static_cast<char>(byte);
      } else {
        typed_exact_ = false;
      }
      break;
    }
  }

  inline void beginSequence(Byte byte, bool pasted) noexcept {
    if (byte == '[') {
      state_ = pasted ? State::paste_sequence : State::sequence;
      parameter_ = 0;
      has_parameter_ = false;
    } else {
      state_ = pasted ? State::paste : State::ground;
    }
  }

  inline void sequence(Byte byte, bool pasted) noexcept {
    if (byte >= '0' && byte <= '9') {
      parameter_ = std::min<unsigned>(UINT16_MAX, parameter_ * 10 + byte - '0');
      has_parameter_ = true;
      return;
    }

    if (byte == '~' && has_parameter_) {
      if (!pasted && parameter_ == paste_start) {
        state_ = State::paste;
        return;
      }

      if (pasted && parameter_ == paste_end) {
        state_ = State::ground;
        return;
      }
    }

    state_ = pasted ? State::paste : State::ground;
  }

  State state_ = State::ground;
  unsigned parameter_ = 0;
  bool has_parameter_ = false;
  std::array<char, 255> typed_{};
  std::size_t typed_count_ = 0;
  bool typed_exact_ = true;
};

}
}

// Interface: command_capture/osc_zones.cppm
export {
namespace telar::runtime {

struct CommandCompletion {
  ObservationTime time;
  std::optional<int> exit_code;
  HistoryStatus status = HistoryStatus::completed;
};

template <typename Sink>
concept CommandCompletionSink = requires(Sink &sink, CommandCompletion completion) {
  { sink.complete(completion) } -> std::same_as<void>;
};

// A signed mark (A, B, C or D) and the offset just past it in the bytes fed, for a sink that
// places it on the terminal those bytes reach. Two more say where the marks come from: N when
// the shell `ssh` reached takes over, U when the pane's own shell is back.
struct CommandMark {
  char action = 0;
  std::size_t end = 0;
};

class CommandZones {
public:
  // With a token, only marks signed with it count: the pane's shell integration signs its
  // own, and a program cannot sign the ones it prints.
  inline explicit CommandZones(std::string_view directory, std::optional<ShellToken> token = std::nullopt)
      : token_(token) {
    setDirectory(directory);
  }

  inline std::optional<ShellToken> token() const noexcept {
    return token_;
  }

  // Whether the marks come from a shell on another host, which `ssh` started with telar's
  // integration, and which shell that is.
  inline bool remote() const noexcept {
    return remote_.has_value();
  }

  inline IntegratedShell remoteShell() const noexcept {
    return remote_ ? remote_shell_ : IntegratedShell::none;
  }

  template <CommandCompletionSink Sink>
  inline void feed(std::span<const Byte> bytes, ObservationTime time, Sink &sink) {
    for (std::size_t offset = 0; offset < bytes.size(); ++offset) {
      if (parser_ == ParserState::ground) {
        const auto *next = static_cast<const Byte *>(std::memchr(bytes.data() + offset, escape, bytes.size() - offset));
        if (next == nullptr) {
          break;
        }

        offset = static_cast<std::size_t>(next - bytes.data());
      }

      const auto byte = bytes[offset];
      switch (parser_) {
      case ParserState::ground:
        if (byte == escape) {
          parser_ = ParserState::escape;
        }
        break;
      case ParserState::escape:
        parser_ = byte == ']' ? ParserState::osc : ParserState::ground;
        if (parser_ == ParserState::osc) {
          TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.osc_started));
          length_ = 0;
          overflow_ = false;
        }
        break;
      case ParserState::osc:
        if (byte == bell) {
          parser_ = ParserState::ground;
          finishSequence(time, sink, offset + 1);
        } else if (byte == escape) {
          parser_ = ParserState::osc_escape;
        } else if (length_ < bytes_.size()) {
          bytes_[length_++] = static_cast<char>(byte);
        } else {
          overflow_ = true;
        }
        break;
      case ParserState::osc_escape:
        parser_ = byte == escape ? ParserState::escape : ParserState::ground;
        if (byte == '\\') {
          finishSequence(time, sink, offset + 1);
        }
        break;
      }
    }
  }

  inline void input(std::span<const Byte> bytes) noexcept {
    if (zone_ == Zone::input && !bytes.empty()) {
      has_input_ = true;
    }
  }

  inline bool editing() const noexcept {
    return markers_ready_ && zone_ == Zone::input;
  }

  inline bool markersReady() const noexcept {
    return markers_ready_;
  }

  inline bool running() const noexcept {
    return markers_ready_ && zone_ == Zone::output;
  }

  inline void setDirectory(std::string_view directory) {
    directory_.assign(directory.substr(0, directory_capacity));
  }

  inline std::string_view directory() const noexcept {
    return directory_.view();
  }

  // The PATH the integrated shell last reported; empty until it does.
  inline std::string_view path() const noexcept {
    return path_.view();
  }

  // The aliases and functions the shell last reported, blank-separated: names it runs that
  // no PATH directory holds. Null until it reports them, or when they did not fit.
  inline const std::shared_ptr<const std::string> &names() const noexcept {
    return names_;
  }

  // The host a shell `ssh` reached runs on, as its working directory report names it.
  inline std::string_view remoteHost() const noexcept {
    return remote_ ? host_.view() : std::string_view{};
  }

  // Where that shell works, as it reports it; empty until it does. `directory()` stays this
  // host's.
  inline std::string_view remoteDirectory() const noexcept {
    return remote_ ? remote_directory_.view() : std::string_view{};
  }

#if TELAR_DIAGNOSTICS
  inline diagnostics::CommandCaptureCounters takeMetrics() noexcept {
    return std::exchange(metrics_, {});
  }
#endif

private:
  enum class ParserState {
    ground,
    escape,
    osc,
    osc_escape
  };
  enum class Zone {
    unknown,
    prompt,
    input,
    output
  };
  static constexpr Byte escape = 0x1b;
  static constexpr Byte bell = 0x07;
  static constexpr std::size_t directory_capacity = 4096;
  static constexpr std::size_t path_capacity = 8192;
  static constexpr std::size_t host_capacity = 255;
  static constexpr std::string_view private_code = "6973";

  template <CommandCompletionSink Sink>
  inline void finishSequence(ObservationTime time, Sink &sink, std::size_t end) {
    TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.osc_finished));
    if (overflow_) {
      // A names report too long to keep: the shell's names are unknown, not empty.
      if (std::string_view{bytes_.data(), length_}.starts_with("6973;")) {
        names_.reset();
      }
      return;
    }

    const std::string_view sequence{bytes_.data(), length_};
    const auto separator = sequence.find(';');
    const auto code = sequence.substr(0, separator);
    const auto body = separator == std::string_view::npos ? std::string_view{} : sequence.substr(separator + 1);
    if (code == "133") {
      semantic(body, time, sink, end);
    } else if (code == "7") {
      directoryReport(body);
    } else if (code == private_code && privateReport(body)) {
      note(sink, 'N', end);
    }
  }

  template <typename Sink>
  inline static void note(Sink &sink, char action, std::size_t end) {
    if constexpr (requires { sink.mark(CommandMark{}); }) {
      sink.mark(CommandMark{.action = action, .end = end});
    }
  }

  // telar's own reports, OSC 6973. The pane's shell signs three: its PATH, so completion finds
  // the commands it runs (telar=<token>;path=<PATH>), its aliases and functions
  // (telar=<token>;names=<blank-separated names>), and the one-time nonce `ssh` hands the
  // remote host before it connects (telar=<token>;nest=<nonce>). The remote shell answers
  // with the nonce and the token its own marks carry (nest=<nonce>;token=<token>;shell=<name>):
  // the nonce stands in for a signature, once, so the pane's token never leaves the host.
  // True when the remote shell took over.
  inline bool privateReport(std::string_view body) {
    if (!token_) {
      return false;
    }
    const auto signature = option(body, "telar=");
    if (signature.empty()) {
      const auto token = ShellToken::parse(option(body, "token="));
      if (nest_ && token && nest_->signs(option(body, "nest="))) {
        nest_.reset();
        remote_ = token;
        remote_shell_ = shellNamed(option(body, "shell="));
        // Unknown until the remote shell reports them.
        host_.assign(std::string_view{});
        remote_directory_.assign(std::string_view{});
        // The pane's shell still runs ssh: its command finishes when the session ends.
        nested_running_ = std::exchange(running_, false);
        return true;
      }
      return false;
    }
    if (!token_->signs(signature)) {
      return false;
    }
    if (body.find(";names=") != std::string_view::npos) {
      // The last option, so its names may be anything but the sequence's terminators.
      const auto names = body.substr(body.find(";names=") + 7);
      names_ = std::make_shared<const std::string>(names);
      return false;
    }
    if (const auto nonce = option(body, "nest="); !nonce.empty()) {
      nest_ = ShellToken::parse(nonce);
      return false;
    }
    std::array<char, path_capacity> decoded;
    if (const auto path = option(body, "path="); !path.empty()) {
      if (const auto count = percentDecode(path, decoded)) {
        path_.assign({decoded.data(), *count});
      }
    }
    return false;
  }

  inline static IntegratedShell shellNamed(std::string_view name) noexcept {
    return name == "zsh" ? IntegratedShell::zsh : name == "bash" ? IntegratedShell::bash : name == "fish" ? IntegratedShell::fish : IntegratedShell::none;
  }

  // The value of `key` among `;`-separated options, or nothing.
  inline static std::string_view option(std::string_view options, std::string_view key) noexcept {
    while (!options.empty()) {
      const auto end = options.find(';');
      const auto entry = options.substr(0, end);
      if (entry.starts_with(key)) {
        return entry.substr(key.size());
      }
      if (end == std::string_view::npos) {
        break;
      }
      options.remove_prefix(end + 1);
    }
    return {};
  }

  // Decodes %XX escapes into `output`; nothing when the text is malformed or does not fit.
  template <std::size_t Capacity>
  inline static std::optional<std::size_t> percentDecode(std::string_view encoded, std::array<char, Capacity> &output) noexcept {
    std::size_t count = 0;
    for (std::size_t index = 0; index < encoded.size(); ++index) {
      if (count == output.size()) {
        return std::nullopt;
      }
      if (encoded[index] == '%') {
        if (encoded.size() - index < 3) {
          return std::nullopt;
        }
        unsigned byte = 0;
        const auto converted = std::from_chars(encoded.data() + index + 1, encoded.data() + index + 3, byte, 16);
        if (converted.ec != std::errc{} || converted.ptr != encoded.data() + index + 3) {
          return std::nullopt;
        }
        output[count++] = static_cast<char>(byte);
        index += 2;
      } else {
        output[count++] = encoded[index];
      }
    }
    return count;
  }

  template <CommandCompletionSink Sink>
  inline void semantic(std::string_view body, ObservationTime time, Sink &sink, std::size_t end) {
    const auto separator = body.find(';');
    const auto action = body.substr(0, separator);
    const auto options = separator == std::string_view::npos ? std::string_view{} : body.substr(separator + 1);
    if (token_) {
      const auto signature = option(options, "telar=");
      if (token_->signs(signature)) {
        // The pane's own shell again: the session `ssh` nested ended, or never started.
        if (remote_) {
          remote_.reset();
          running_ = nested_running_;
          zone_ = Zone::output;
          note(sink, 'U', end);
        }
        if (action == "A" || action == "D") {
          nest_.reset();
        }
      } else if (!remote_ || !remote_->signs(signature)) {
        return;
      }
    }

    if (action.size() == 1 && (action == "A" || action == "B" || action == "C" || action == "D")) {
      note(sink, action.front(), end);
    }
    if (action == "A" || action == "P") {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.prompt_markers));
      if (running_) {
        sink.complete({time, std::nullopt, HistoryStatus::interrupted});
      }

      running_ = false;
      has_input_ = false;
      zone_ = Zone::prompt;
    } else if (action == "B") {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.input_markers));
      markers_ready_ |= zone_ == Zone::prompt;
      // A line editor redrawing its prompt mid-edit (zsh after a paste) keeps what was typed.
      has_input_ = zone_ == Zone::input && has_input_;
      zone_ = Zone::input;
    } else if (action == "C") {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.output_markers));
      zone_ = Zone::output;
      running_ = has_input_;
    } else if (action == "D") {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.finished_markers));
      zone_ = Zone::prompt;
      if (running_) {
        sink.complete({time, parseExitCode(options), HistoryStatus::completed});
        running_ = false;
        has_input_ = false;
      }
    }
  }

  inline static std::optional<int> parseExitCode(std::string_view options) noexcept {
    auto value = options.substr(0, options.find(';'));
    const bool negative = value.starts_with('-');
    if (negative || value.starts_with('+')) {
      value.remove_prefix(1);
    }
    if (value.empty() || value.front() == '_' || value.back() == '_') {
      return std::nullopt;
    }

    constexpr std::uint32_t decimal_base = 10;
    const auto limit = static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max()) + negative;
    std::uint32_t magnitude = 0;
    for (const auto byte : value) {
      if (byte == '_') {
        continue;
      }
      if (byte < '0' || byte > '9') {
        return std::nullopt;
      }
      const auto digit = static_cast<std::uint32_t>(byte - '0');
      if (magnitude > (limit - digit) / decimal_base) {
        return std::nullopt;
      }
      magnitude = magnitude * decimal_base + digit;
    }
    const auto signed_value = negative ? -static_cast<std::int64_t>(magnitude) : magnitude;
    return static_cast<int>(signed_value);
  }

  inline void directoryReport(std::string_view body) {
    for (const auto prefix : {std::string_view{"file://"}, std::string_view{"kitty-shell-cwd://"}}) {
      if (!body.starts_with(prefix)) {
        continue;
      }

      const auto remainder = body.substr(prefix.size());
      const auto slash = remainder.find('/');
      if (slash == std::string_view::npos) {
        return;
      }
      std::array<char, directory_capacity> decoded;
      const auto count = percentDecode(remainder.substr(slash), decoded);
      if (!remote_) {
        if (count) {
          directory_.assign({decoded.data(), *count});
        }
        return;
      }
      // A remote shell's report names a place on its host, which clients show as text.
      const auto printable = [](char byte) { return static_cast<unsigned char>(byte) >= 0x20 && byte != 0x7f; };
      const auto host = remainder.substr(0, slash);
      if (host.size() <= host_capacity && std::ranges::all_of(host, [&](char byte) { return byte != ' ' && printable(byte); })) {
        host_.assign(host);
      }
      if (count && std::ranges::all_of(std::string_view{decoded.data(), *count}, printable)) {
        remote_directory_.assign({decoded.data(), *count});
      }
      return;
    }
  }

#if TELAR_DIAGNOSTICS
  diagnostics::CommandCaptureCounters metrics_;
#endif
  std::optional<ShellToken> token_;
  std::optional<ShellToken> remote_;
  std::optional<ShellToken> nest_;
  IntegratedShell remote_shell_ = IntegratedShell::none;
  ParserState parser_ = ParserState::ground;
  Zone zone_ = Zone::unknown;
  std::array<char, 16 * 1024> bytes_{};
  std::size_t length_ = 0;
  bool overflow_ = false;
  bool markers_ready_ = false;
  bool has_input_ = false;
  bool running_ = false;
  bool nested_running_ = false;
  FixedText<directory_capacity> directory_;
  FixedText<path_capacity> path_;
  FixedText<host_capacity> host_;
  FixedText<directory_capacity> remote_directory_;
  std::shared_ptr<const std::string> names_;
};

}
}

// Interface: command_capture/output_tail.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class CommandOutputTail {
public:
  static constexpr std::size_t capacity = 64 * 1024;

  inline explicit CommandOutputTail(Memory &memory, bool enabled)
      : bytes_(AllocatorRef<std::uint8_t, Memory>{memory}) {
    if (enabled) {
      enable();
    }
  }

  inline void enable() {
    bytes_.resize(capacity);
  }

  inline void append(std::span<const std::uint8_t> bytes) noexcept {
    if (bytes_.empty()) {
      return;
    }

    observed_ += std::min<std::uint64_t>(bytes.size(), UINT64_MAX - observed_);
    if (bytes.size() >= capacity) {
      std::copy(bytes.end() - capacity, bytes.end(), bytes_.begin());
      length_ = capacity;
      return;
    }

    if (length_ + bytes.size() > capacity) {
      const auto keep = std::min(capacity / 2, capacity - bytes.size());
      std::move(bytes_.begin() + length_ - keep, bytes_.begin() + length_, bytes_.begin());
      length_ = keep;
    }

    std::copy(bytes.begin(), bytes.end(), bytes_.begin() + length_);
    length_ += bytes.size();
  }

  inline std::span<const std::uint8_t> bytes() const noexcept {
    return std::span<const std::uint8_t>{bytes_}.first(length_);
  }

  inline std::uint64_t observed() const noexcept {
    return observed_;
  }

  inline void clear() noexcept {
    length_ = 0;
    observed_ = 0;
  }

private:
  Vector<std::uint8_t, Memory> bytes_;
  std::size_t length_ = 0;
  std::uint64_t observed_ = 0;
};

}
}

// Interface: command_capture/terminal_selection.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class CommandSelection {
public:
  static constexpr std::size_t maximum_bytes = 64 * 1024;

  inline explicit CommandSelection(Terminal<Memory> &terminal)
      : terminal_(terminal) {
    const auto position = point(GHOSTTY_POINT_TAG_ACTIVE, cursor());
    checkGhostty(ghostty_terminal_grid_ref_track(terminal.handle(), position, anchor_.output()));
    checkGhostty(ghostty_terminal_grid_ref_track(terminal.handle(), position, right_prompt_.output()));
  }

  inline bool primary() const {
    GhosttyTerminalScreen screen{};
    checkGhostty(ghostty_terminal_get(terminal_.handle(), GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen));
    return screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  }

  inline void begin() {
    set(anchor_, GHOSTTY_POINT_TAG_ACTIVE, cursor());
    erased_ = false;
    findRightPrompt();
  }

  inline void rebase(std::optional<std::string_view> typed) {
    const auto anchor = snapshot(anchor_);
    if (!anchor) {
      return;
    }

    erased_ |= blank(*anchor, 0, columns());
    const auto position = cursor();
    const auto current = reference(GHOSTTY_POINT_TAG_ACTIVE, position);
    auto start = position.x;
    if (typed && !typed->empty() && typed->size() <= position.x && matches(current, *typed)) {
      start -= typed->size();
    }

    if (start == 0 || blank(current, 0, start)) {
      return;
    }

    const bool same_row = current.node == anchor->node && current.y == anchor->y;
    if (!erased_ && (same_row || start == position.x)) {
      return;
    }

    set(anchor_, GHOSTTY_POINT_TAG_ACTIVE, {start, position.y});
    erased_ = false;
    findRightPrompt();
  }

  inline std::optional<bool> capture(Vector<Byte, Memory> &destination) {
    TELAR_TRACE("history.captureSelection");
    destination.clear();
    const auto anchor = snapshot(anchor_);
    if (!primary() || !anchor || erased_ || blank(*anchor, 0, columns())) {
      return std::nullopt;
    }

    const auto start = coordinates(*anchor);
    auto finish = coordinates(reference(GHOSTTY_POINT_TAG_ACTIVE, cursor()));
    if (before(finish, start)) {
      return std::nullopt;
    }

    const auto maximum_rows = maximum_bytes / columns() + 2;
    if (finish.y - start.y > maximum_rows) {
      finish = {static_cast<std::uint16_t>(columns() - 1), start.y + static_cast<std::uint32_t>(maximum_rows)};
    }

    finish = selectionFinish(start, finish);
    auto selection = ghosttySized<GhosttySelection>();
    selection.start = *anchor;
    selection.end = reference(GHOSTTY_POINT_TAG_SCREEN, finish);
    destination.resize(maximum_bytes + utf8_maximum_width);
    PrefixWriter writer{destination};
    formatTerminalSelection(terminal_, selection, true, TrailingSpaces::trimmed, GhosttyWriter{.write = PrefixWriter::receive, .userdata = &writer});
    destination.resize(writer.length);
    if (destination.empty()) {
      return std::nullopt;
    }

    const bool truncated = writer.overflow || destination.size() > maximum_bytes;
    const std::string_view text{reinterpret_cast<const char *>(destination.data()), destination.size()};
    destination.resize(utf8Prefix(text, maximum_bytes).size());
    return truncated;
  }

private:
  using TrackedReference = GhosttyHandle<GhosttyTrackedGridRef, ghostty_tracked_grid_ref_free>;
  static constexpr std::size_t utf8_maximum_width = 4;
  static constexpr std::uint64_t hash_basis = 0xcbf29ce484222325;
  static constexpr std::uint64_t hash_prime = 0x100000001b3;

  struct PrefixWriter {
    std::span<Byte> destination;
    std::size_t length = 0;
    bool overflow = false;

    inline static bool receive(void *context, const Byte *bytes, std::size_t count) noexcept {
      auto &writer = *static_cast<PrefixWriter *>(context);
      const auto copied = std::min(count, writer.destination.size() - writer.length);
      std::copy_n(bytes, copied, writer.destination.data() + writer.length);
      writer.length += copied;
      writer.overflow |= copied != count;
      return true;
    }
  };

  inline std::uint16_t columns() const noexcept {
    return terminal_.screen.cols;
  }

  inline GhosttyPointCoordinate cursor() const {
    std::uint16_t column = 0;
    std::uint16_t row = 0;
    checkGhostty(ghostty_terminal_get(terminal_.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_X, &column));
    checkGhostty(ghostty_terminal_get(terminal_.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_Y, &row));
    return {column, row};
  }

  inline static GhosttyPoint point(GhosttyPointTag tag, GhosttyPointCoordinate coordinate) noexcept {
    return {.tag = tag, .value = {.coordinate = coordinate}};
  }

  inline GhosttyGridRef reference(GhosttyPointTag tag, GhosttyPointCoordinate coordinate) const {
    auto result = ghosttySized<GhosttyGridRef>();
    checkGhostty(ghostty_terminal_grid_ref(terminal_.handle(), point(tag, coordinate), &result));
    return result;
  }

  inline static std::optional<GhosttyGridRef> snapshot(const TrackedReference &tracked) {
    auto result = ghosttySized<GhosttyGridRef>();
    const auto status = ghostty_tracked_grid_ref_snapshot(tracked.get(), &result);
    if (status == GHOSTTY_NO_VALUE) {
      return std::nullopt;
    }

    checkGhostty(status);
    return result;
  }

  inline GhosttyPointCoordinate coordinates(const GhosttyGridRef &reference) const {
    GhosttyPointCoordinate result{};
    checkGhostty(ghostty_terminal_point_from_grid_ref(terminal_.handle(), &reference, GHOSTTY_POINT_TAG_SCREEN, &result));
    return result;
  }

  inline void set(TrackedReference &tracked, GhosttyPointTag tag, GhosttyPointCoordinate coordinate) {
    checkGhostty(ghostty_tracked_grid_ref_set(tracked.get(), terminal_.handle(), point(tag, coordinate)));
  }

  inline static bool before(GhosttyPointCoordinate left, GhosttyPointCoordinate right) noexcept {
    return left.y < right.y || (left.y == right.y && left.x < right.x);
  }

  inline static GhosttyCell cell(GhosttyGridRef reference, std::uint16_t column) {
    reference.x = column;
    GhosttyCell result = 0;
    checkGhostty(ghostty_grid_ref_cell(&reference, &result));
    return result;
  }

  inline static bool hasText(GhosttyCell cell) noexcept {
    const auto content = cell_layout::content_tag(cell);
    return (content == GHOSTTY_CELL_CONTENT_CODEPOINT || content == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME) && cell_layout::codepoint(cell) != 0;
  }

  inline static bool blank(GhosttyGridRef row, std::uint16_t start, std::uint16_t finish) {
    for (auto column = start; column < finish; ++column) {
      const auto value = cell(row, column);
      if (hasText(value) && cell_layout::codepoint(value) != ' ') {
        return false;
      }
    }

    return true;
  }

  inline static bool matches(GhosttyGridRef cursor, std::string_view typed) {
    const auto start = cursor.x - typed.size();
    for (std::size_t index = 0; index < typed.size(); ++index) {
      const auto value = cell(cursor, start + index);
      const auto codepoint = hasText(value) ? cell_layout::codepoint(value) : ' ';
      if (codepoint != static_cast<unsigned char>(typed[index])) {
        return false;
      }
    }

    return true;
  }

  inline std::uint64_t hash(GhosttyGridRef start) const {
    auto result = hash_basis;
    for (auto column = start.x; column < columns(); ++column) {
      result = (result ^ cell(start, column)) * hash_prime;
    }

    return result;
  }

  inline void findRightPrompt() {
    right_prompt_active_ = false;
    auto anchor = *snapshot(anchor_);
    unsigned blank_columns = 0;
    for (auto column = anchor.x; column < columns(); ++column) {
      if (!hasText(cell(anchor, column))) {
        ++blank_columns;
        continue;
      }

      if (blank_columns < 2) {
        blank_columns = 0;
        continue;
      }

      anchor.x = column;
      set(right_prompt_, GHOSTTY_POINT_TAG_SCREEN, coordinates(anchor));
      right_prompt_hash_ = hash(anchor);
      right_prompt_active_ = true;
      return;
    }
  }

  inline GhosttyPointCoordinate selectionFinish(GhosttyPointCoordinate start, GhosttyPointCoordinate fallback) const {
    const auto right_prompt = right_prompt_active_ ? snapshot(right_prompt_) : std::nullopt;
    if (!right_prompt || right_prompt->x == 0) {
      return fallback;
    }

    auto position = coordinates(*right_prompt);
    if (before(start, position) && before(position, fallback) && hash(*right_prompt) == right_prompt_hash_) {
      --position.x;
      return position;
    }

    return fallback;
  }

  Terminal<Memory> &terminal_;
  TrackedReference anchor_;
  TrackedReference right_prompt_;
  std::uint64_t right_prompt_hash_ = 0;
  bool right_prompt_active_ = false;
  bool erased_ = false;
};

}
}

// Interface: command_capture/command_blocks.cppm
export {
namespace telar::runtime {

// The commands a pane's integrated shell ran, each anchored to the row its prompt starts on
// in the pane's own terminal, so a client can mark them in the scrollback and jump to them.
// The anchors follow the rows as output scrolls and the scrollback drops its oldest lines.
template <Allocator Memory>
class CommandBlocks {
public:
  static constexpr std::size_t capacity = PaneBlocks::capacity;
  static constexpr std::size_t command_bytes = 160;

  inline CommandBlocks(Memory &memory, Terminal<Memory> &terminal)
      : terminal_(terminal),
        selection_(terminal),
        text_(AllocatorRef<Byte, Memory>{memory}) {}

  // A signed mark, reached by the terminal as the shell printed it.
  inline void mark(char action, std::chrono::steady_clock::time_point now) {
    switch (action) {
    case 'A':
      if (running_) {
        finish(CommandBlockState::interrupted, 0, now);
      }
      // The pane's shell is back without saying how ssh ended.
      if (closing_) {
        closeSession(CommandBlockState::interrupted, 0, now);
      }
      prompt_ = selection_.primary() ? track() : std::nullopt;
      break;
    case 'B':
      selection_.begin();
      break;
    case 'C':
      start(now);
      break;
    case 'D':
      if (running_) {
        finish(CommandBlockState::succeeded, 0, now);
      }
      break;
    case 'N':
      // The running command, ssh, now hosts the remote shell, whose commands follow it.
      if (running_ && count_ != 0) {
        entry(count_ - 1).state = CommandBlockState::session;
        entry(count_ - 1).nest = CommandBlockNest::opens;
        ++revision_;
      }
      running_ = false;
      prompt_.reset();
      nested_ = true;
      break;
    case 'U':
      // The remote shell is gone, maybe in the middle of a command; ssh's own D follows.
      if (running_) {
        finish(CommandBlockState::interrupted, 0, now);
      }
      prompt_.reset();
      nested_ = false;
      closing_ = true;
      break;
    default:
      break;
    }
  }

  // The status a D mark reported, for the block it ends: ssh's own, after its session.
  inline void finished(std::optional<int> status, std::chrono::steady_clock::time_point now) {
    const auto code = status.value_or(0);
    const auto state = code == 0 ? CommandBlockState::succeeded : CommandBlockState::failed;
    if (closing_) {
      closeSession(state, code, now);
    } else if (running_) {
      finish(state, code, now);
    }
  }

  // Reads where the blocks are now: output scrolled them, the scrollback dropped some, or a
  // resize reflowed them. Only the oldest is read unless it moved. The anchors are on the
  // primary screen: while a full-screen program has the alternate one, they cannot be read,
  // and they stay as they were.
  inline void follow(bool reflowed = false) {
    if (count_ == 0 || !selection_.primary()) {
      return;
    }
    if (!reflowed) {
      const auto oldest = row(entry(0).anchor);
      if (oldest && *oldest == entry(0).row) {
        return;
      }
    }
    std::size_t kept = 0;
    for (std::size_t index = 0; index < count_; ++index) {
      auto &current = entry(index);
      const auto position = row(current.anchor);
      if (!position) {
        continue;
      }
      current.row = *position;
      if (kept != index) {
        std::swap(entry(kept), current);
      }
      ++kept;
    }
    count_ = kept;
    ++revision_;
  }

  inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  inline PaneBlocks message(std::uint64_t pane_id, std::array<CommandBlock, capacity> &storage) const {
    for (std::size_t index = 0; index < count_; ++index) {
      const auto &current = entry(index);
      storage[index] = CommandBlock{.row = current.row,
                                    .rows = current.rows,
                                    .lines = current.lines,
                                    .state = current.state,
                                    .status = current.status,
                                    .duration_ms = current.duration_ms,
                                    .command = current.command.view(),
                                    .nest = current.nest};
    }
    return PaneBlocks{.pane_id = pane_id, .blocks = std::span<const CommandBlock>{storage}.first(count_)};
  }

private:
  // A tracked reference the block owns, moved as the ring drops its oldest.
  class TrackedReference {
  public:
    TrackedReference() = default;
    TrackedReference(const TrackedReference &) = delete;
    TrackedReference &operator=(const TrackedReference &) = delete;
    inline TrackedReference(TrackedReference &&other) noexcept
        : handle_(std::exchange(other.handle_, nullptr)) {}
    inline TrackedReference &operator=(TrackedReference &&other) noexcept {
      if (this != &other) {
        release();
        handle_ = std::exchange(other.handle_, nullptr);
      }
      return *this;
    }
    inline ~TrackedReference() {
      release();
    }

    inline GhosttyTrackedGridRef get() const noexcept {
      return handle_;
    }

    inline GhosttyTrackedGridRef *output() noexcept {
      return &handle_;
    }

  private:
    inline void release() noexcept {
      if (handle_ != nullptr) {
        ghostty_tracked_grid_ref_free(handle_);
        handle_ = nullptr;
      }
    }

    GhosttyTrackedGridRef handle_ = nullptr;
  };

  struct Entry {
    TrackedReference anchor;
    std::uint32_t row = 0;
    std::uint16_t rows = 1;
    std::uint16_t lines = 0;
    CommandBlockState state = CommandBlockState::running;
    CommandBlockNest nest = CommandBlockNest::none;
    std::int32_t status = 0;
    std::uint32_t duration_ms = 0;
    std::chrono::steady_clock::time_point started{};
    FixedText<command_bytes> command;
  };

  inline Entry &entry(std::size_t index) noexcept {
    return entries_[(first_ + index) % capacity];
  }

  inline const Entry &entry(std::size_t index) const noexcept {
    return entries_[(first_ + index) % capacity];
  }

  // A reference that follows the cursor's row as the terminal scrolls.
  inline std::optional<TrackedReference> track() {
    std::uint16_t row = 0;
    checkGhostty(ghostty_terminal_get(terminal_.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_Y, &row));
    TrackedReference tracked;
    const GhosttyPoint point{.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {0, row}}};
    if (ghostty_terminal_grid_ref_track(terminal_.handle(), point, tracked.output()) != GHOSTTY_SUCCESS) {
      return std::nullopt;
    }
    return tracked;
  }

  // The row `tracked` is on, from the top of the scrollback; nothing once it was dropped.
  inline std::optional<std::uint32_t> row(const TrackedReference &tracked) const {
    auto reference = ghosttySized<GhosttyGridRef>();
    if (ghostty_tracked_grid_ref_snapshot(tracked.get(), &reference) != GHOSTTY_SUCCESS) {
      return std::nullopt;
    }
    GhosttyPointCoordinate coordinate{};
    if (ghostty_terminal_point_from_grid_ref(terminal_.handle(), &reference, GHOSTTY_POINT_TAG_SCREEN, &coordinate) != GHOSTTY_SUCCESS) {
      return std::nullopt;
    }
    return coordinate.y;
  }

  // The command starts: its block takes the rows from its prompt down to the output.
  inline void start(std::chrono::steady_clock::time_point now) {
    auto prompt = std::exchange(prompt_, std::nullopt);
    if (!prompt || !selection_.primary()) {
      return;
    }
    const auto first = row(*prompt);
    const auto output = track();
    const auto last = output ? row(*output) : std::nullopt;
    if (!first || !last || *last <= *first || !selection_.capture(text_)) {
      return;
    }
    std::string_view text{reinterpret_cast<const char *>(text_.data()), text_.size()};
    while (text.ends_with('\n')) {
      text.remove_suffix(1);
    }
    const auto line = text.substr(0, text.find('\n'));
    if (line.find_first_not_of(' ') == std::string_view::npos) {
      return;
    }

    if (count_ == capacity) {
      first_ = (first_ + 1) % capacity;
      --count_;
    }
    auto &added = entry(count_++);
    added.anchor = std::move(*prompt);
    added.row = *first;
    added.rows = static_cast<std::uint16_t>(std::min<std::uint32_t>(*last - *first, std::numeric_limits<std::uint16_t>::max()));
    added.lines = static_cast<std::uint16_t>(std::min<std::size_t>(static_cast<std::size_t>(std::ranges::count(text, '\n')), std::numeric_limits<std::uint16_t>::max()));
    added.state = CommandBlockState::running;
    added.nest = nested_ ? CommandBlockNest::inside : CommandBlockNest::none;
    added.status = 0;
    added.duration_ms = 0;
    added.started = now;
    // Display text: control bytes the grid may hold become blanks.
    std::array<char, command_bytes> clean;
    const auto kept = utf8Prefix(line, command_bytes);
    std::ranges::transform(kept, clean.begin(), [](char byte) { return static_cast<unsigned char>(byte) < 0x20 || byte == 0x7f ? ' ' : byte; });
    added.command.assign({clean.data(), kept.size()});
    running_ = true;
    ++revision_;
  }

  inline void finish(CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now) {
    running_ = false;
    if (count_ != 0) {
      end(entry(count_ - 1), state, status, now);
    }
  }

  // Ends the block whose ssh hosted the session that just closed; at most one is open.
  inline void closeSession(CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now) {
    closing_ = false;
    for (auto index = count_; index > 0; --index) {
      if (auto &current = entry(index - 1); current.state == CommandBlockState::session) {
        end(current, state, status, now);
        return;
      }
    }
  }

  inline void end(Entry &block, CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now) {
    block.state = state;
    block.status = status;
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - block.started).count();
    block.duration_ms = static_cast<std::uint32_t>(std::clamp<std::int64_t>(elapsed, 0, std::numeric_limits<std::uint32_t>::max()));
    ++revision_;
  }

  Terminal<Memory> &terminal_;
  CommandSelection<Memory> selection_;
  Vector<Byte, Memory> text_;
  std::optional<TrackedReference> prompt_;
  std::array<Entry, capacity> entries_{};
  std::size_t first_ = 0;
  std::size_t count_ = 0;
  std::uint64_t revision_ = 0;
  bool running_ = false;
  // Commands run in the shell ssh reached; that shell just left, and ssh's D ends its block.
  bool nested_ = false;
  bool closing_ = false;
};

}
}

// Interface: command_capture/tracker.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class CommandTracker {
public:
  inline explicit CommandTracker(Memory &memory, Terminal<Memory> &terminal, std::string_view directory, bool capture_output = false, std::optional<ShellToken> shell_token = std::nullopt)
      : terminal_(terminal),
        selection_(terminal),
        zones_(directory, shell_token),
        output_(memory, capture_output),
        command_(AllocatorRef<Byte, Memory>{memory}),
        submitted_(AllocatorRef<Byte, Memory>{memory}) {}

  inline void enableOutputCapture() {
    output_.enable();
  }

  // The text of the command a client is about to type at the prompt. The submission that
  // follows records it as the command instead of reading the command back from the screen.
  inline void submitCommand(std::span<const Byte> text) {
    submitted_.assign(text.begin(), text.end());
  }

  template <CapturedCommandSink Sink>
  inline std::size_t input(const CommandByteObservation &observation, Sink &sink) {
    TELAR_TRACE("history.captureInput");
    const bool shell_foreground = observation.shell_foreground.value_or(zones_.editing());
    zones_.input(observation.bytes);
    if (observation.bytes.empty()) {
      return 0;
    }
    if (!shell_foreground || !selection_.primary()) {
      submitted_.clear();
      return 0;
    }

    if (phase_ == Phase::running) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.next_input_completions));
      auto finished = observation.time;
      if (last_output_ns_ >= started_.nanoseconds) {
        finished.nanoseconds = last_output_ns_;
      }

      complete({finished, std::nullopt, HistoryStatus::completed}, sink);
    }

    if (phase_ == Phase::awaiting_commit) {
      return observation.bytes.size();
    }

    if (phase_ == Phase::idle) {
      selection_.begin();
      input_.reset();
      phase_ = Phase::editing;
    }

    const auto event = input_.feed(observation.bytes);
    if (event.cancelled) {
      submitted_.clear();
      reset();
      return observation.bytes.size();
    }

    if (event.submitted && phase_ == Phase::editing) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.submissions));
      phase_ = Phase::awaiting_commit;
      started_ = observation.time;
      last_output_ns_ = started_.nanoseconds;
      saw_foreground_child_ = false;
      command_directory_.assign(zones_.directory());
    }

    return observation.bytes.size();
  }

  template <CapturedCommandSink Sink>
  inline void output(CommandByteObservation observation, Sink &sink) {
    TELAR_TRACE("history.captureOutput");
    while (!observation.bytes.empty()) {
      const auto boundary = phase_ == Phase::awaiting_commit ? std::ranges::find(observation.bytes, '\n') : observation.bytes.end();
      const bool committed = boundary != observation.bytes.end();
      const auto count = committed ? static_cast<std::size_t>(boundary - observation.bytes.begin()) + 1 : observation.bytes.size();
      const auto part = observation.bytes.first(count);
      terminal_.feed(part);
      terminal_.discardResponses();
      if (committed) {
        const auto captured = submitted_.empty() ? selection_.capture(command_) : std::optional{takeSubmitted()};
        if (captured) {
          TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.captures));
          truncated_ = *captured;
          phase_ = Phase::running;
        } else {
          TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.capture_failures));
          reset();
        }
      }

      afterOutput({part, observation.time, observation.shell_foreground}, sink);
      observation.bytes = observation.bytes.subspan(count);
    }
  }

  template <CapturedCommandSink Sink>
  inline void complete(CommandCompletion completion, Sink &sink) {
    if (phase_ == Phase::running && !command_.empty()) {
      sink.emit(CapturedCommand{
          .command = {reinterpret_cast<const char *>(command_.data()), command_.size()},
          .directory = command_directory_.view(),
          .started = started_,
          .duration_ns = std::max<std::int64_t>(0, completion.time.nanoseconds - started_.nanoseconds),
          .exit_code = completion.exit_code,
          .status = completion.status,
          .truncated = truncated_,
          .output = output_.bytes(),
          .output_observed = output_.observed(),
      });
    }

    reset();
  }

  inline void reset() noexcept {
    phase_ = Phase::idle;
    command_.clear();
    input_.reset();
    output_.clear();
    truncated_ = false;
    saw_foreground_child_ = false;
  }

  inline void resetObservation() {
    TELAR_DIAGNOSTIC(metrics_.merge(zones_.takeMetrics()));
    submitted_.clear();
    reset();
    zones_ = CommandZones{zones_.directory(), zones_.token()};
  }

  inline void updateDirectory(std::string_view directory) {
    zones_.setDirectory(directory);
  }

  inline std::string_view directory() const noexcept {
    return zones_.directory();
  }

  inline bool markersReady() const noexcept {
    return zones_.markersReady();
  }

  inline bool needsForegroundObservation() const noexcept {
    return phase_ == Phase::awaiting_commit || phase_ == Phase::running;
  }

#if TELAR_DIAGNOSTICS
  inline diagnostics::CommandCaptureCounters takeMetrics() noexcept {
    auto result = std::exchange(metrics_, {});
    result.merge(zones_.takeMetrics());
    return result;
  }
#endif

private:
  enum class Phase {
    idle,
    editing,
    awaiting_commit,
    running
  };

  template <CapturedCommandSink Sink>
  struct CompletionRelay {
    CommandTracker &tracker;
    Sink &sink;

    inline void complete(CommandCompletion completion) {
      if (tracker.phase_ == Phase::running) {
        TELAR_DIAGNOSTIC(diagnostics::accumulate(tracker.metrics_.auxiliary_completions));
        tracker.complete(completion, sink);
      }
    }
  };

  // The submitted text becomes the command, whole: the protocol bounds it to the capture's size.
  inline bool takeSubmitted() {
    command_.swap(submitted_);
    submitted_.clear();
    return false;
  }

  template <CapturedCommandSink Sink>
  inline void afterOutput(const CommandByteObservation &observation, Sink &sink) {
    last_output_ns_ = observation.time.nanoseconds;
    if ((phase_ == Phase::editing || phase_ == Phase::awaiting_commit) && !selection_.primary()) {
      reset();
    }

    if (phase_ == Phase::editing) {
      selection_.rebase(input_.typedText());
    }

    if (phase_ == Phase::running) {
      output_.append(observation.bytes);
    }

    CompletionRelay<Sink> relay{*this, sink};
    zones_.feed(observation.bytes, observation.time, relay);
    if (phase_ != Phase::running || !observation.shell_foreground) {
      return;
    }

    if (!*observation.shell_foreground) {
      saw_foreground_child_ = true;
    } else if (saw_foreground_child_) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.foreground_completions));
      complete({observation.time, std::nullopt, HistoryStatus::completed}, sink);
    }
  }

#if TELAR_DIAGNOSTICS
  diagnostics::CommandCaptureCounters metrics_;
#endif
  Terminal<Memory> &terminal_;
  CommandSelection<Memory> selection_;
  CommandZones zones_;
  CommandOutputTail<Memory> output_;
  Vector<Byte, Memory> command_;
  // Survives a previous command's completion, which the input typing this one triggers.
  Vector<Byte, Memory> submitted_;
  CommandInputScanner input_;
  FixedText<4096> command_directory_;
  ObservationTime started_;
  std::int64_t last_output_ns_ = 0;
  Phase phase_ = Phase::idle;
  bool truncated_ = false;
  bool saw_foreground_child_ = false;
};

}
}
