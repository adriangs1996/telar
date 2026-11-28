module;
#include "telar_base/diagnostics/config.hpp"
#include "telar_platform/trace_macro.hpp"

module telar.runtime.terminal.command_capture.tracker;

import std;
import telar.base.text;
import telar.base.text.utf8;
import telar.ghostty.vt;
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.grid;
import telar.sys.process;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // The control bytes typed input may hold, and the printable range it keeps.
    constexpr Byte interrupt = 0x03;
    constexpr Byte backspace = 0x08;
    constexpr Byte form_feed = 0x0c;
    constexpr Byte first_printable = 0x20;
    constexpr Byte last_printable = 0x7e;
    constexpr Byte delete_byte = 0x7f;

    constexpr unsigned decimal = 10;
    constexpr int hexadecimal = 16;

    // Whether a character is shown as itself rather than as a control.
    constexpr bool printable(char byte) noexcept {
      return static_cast<unsigned char>(byte) >= first_printable && static_cast<unsigned char>(byte) != delete_byte;
    }

    // At most `capacity` bytes of `text` cut on a character, or nothing when a client could not
    // show it: what a shell reports is not always UTF-8 or free of controls.
    std::string_view displayed(std::string_view text, std::size_t capacity) noexcept {
      const auto kept = utf8Prefix(text, capacity);

      return inspectUtf8(kept) == Utf8Validation::valid && std::ranges::all_of(kept, printable) ? kept : std::string_view{};
    }

    // A host or user name as a remote shell reports it: printable, without blanks, that fits.
    bool nameFits(std::string_view name, std::size_t capacity) noexcept {
      return name.size() <= capacity && std::ranges::all_of(name, [](char byte) {
        return byte != ' ' && printable(byte);
      });
    }

    // A socket path as ssh.sh names one: absolute, without a `.` or `..` part or an empty one,
    // of characters that need no quoting anywhere, that fits a socket address.
    bool controlFits(std::string_view path) {
      const auto plain = [](char byte) {
        return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || std::string_view{"/._@+,:=-"}.contains(byte);
      };

      if (path.size() < 2 || path.size() > CommandZones::control_capacity || !path.starts_with('/') || path.ends_with('/') || !std::ranges::all_of(path, plain)) {
        return false;
      }

      for (auto rest = path.substr(1); !rest.empty();) {
        const auto end = std::min(rest.find('/'), rest.size());
        const std::string_view part{rest.data(), end};
        if (part.empty() || part == "." || part == "..") {
          return false;
        }

        rest.remove_prefix(std::min(end + 1, rest.size()));
      }

      return true;
    }

    // A mark for a sink that places it on the terminal the bytes reach.
    void note(CommandZoneSink& sink, char action, std::size_t end, ds::Option<int> status = ds::none) {
      sink.mark(CommandMark{.action = action, .end = end, .status = status});
    }

    IntegratedShell shellNamed(std::string_view name) noexcept {
      if (name == "zsh") {
        return IntegratedShell::zsh;
      }

      if (name == "bash") {
        return IntegratedShell::bash;
      }

      return name == "fish" ? IntegratedShell::fish : IntegratedShell::none;
    }

    // The options telar's reports and marks carry.
    enum class ReportOption : std::uint8_t {
      telar,
      token,
      nest,
      shell,
      path,
      typeahead,
      user,
      control,
      jobs,
    };

    constexpr std::string_view optionKey(ReportOption key) noexcept {
      switch (key) {
      case ReportOption::telar:
        return "telar=";
      case ReportOption::token:
        return "token=";
      case ReportOption::nest:
        return "nest=";
      case ReportOption::shell:
        return "shell=";
      case ReportOption::path:
        return "path=";
      case ReportOption::typeahead:
        return "typeahead=";
      case ReportOption::user:
        return "user=";
      case ReportOption::control:
        return "control=";
      case ReportOption::jobs:
        return "jobs=";
      }

      // A value no enumerator names has no key, which no option starts with.
      return {};
    }

    // The value of `key` among `;`-separated options, or nothing.
    tbc::val_a<std::string_view> option(tbc::val_a<std::string_view> options, ReportOption key) noexcept {
      const auto prefix = optionKey(key);

      while (!options.empty()) {
        const auto end = options.find(';');
        const auto entry = textPrefix(options, end);
        if (entry.starts_with(prefix)) {
          return textAfter(entry, prefix.size());
        }

        if (end == std::string_view::npos) {
          break;
        }

        options.remove_prefix(end + 1);
      }

      return {};
    }

    // Decodes %XX escapes into `output`; nothing when the text is malformed or does not fit.
    ds::Option<std::size_t> percentDecode(std::string_view encoded, std::span<char> output) noexcept {
      std::size_t count = 0;

      for (std::size_t index = 0; index < encoded.size(); ++index) {
        if (count == output.size()) {
          return ds::none;
        }

        if (encoded[index] == '%') {
          if (encoded.size() - index < 3) {
            return ds::none;
          }

          const auto byte = parseExact<unsigned>(textPrefix(textAfter(encoded, index + 1), 2), hexadecimal);
          if (!byte) {
            return ds::none;
          }

          output[count++] = static_cast<char>(*byte);
          index += 2;
        } else {
          output[count++] = encoded[index];
        }
      }

      return count;
    }

    ds::Option<int> parseExitCode(std::string_view options) noexcept {
      auto value = textPrefix(options, options.find(';'));
      const bool negative = value.starts_with('-');
      if (negative || value.starts_with('+')) {
        value.remove_prefix(1);
      }

      const auto limit = static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max()) + static_cast<std::uint32_t>(negative);
      const auto parsed = unsignedNumber<std::uint32_t>(value, limit);
      if (!parsed) {
        return ds::none;
      }

      const auto magnitude = *parsed;
      const auto signed_value = negative ? -static_cast<std::int64_t>(magnitude) : magnitude;

      return static_cast<int>(signed_value);
    }

  }

  // CommandInputScanner

  CommandInputScanner::Event CommandInputScanner::feed(std::span<const Byte> bytes) noexcept {
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

  void CommandInputScanner::reset() noexcept {
    state_ = State::ground;
    parameter_ = 0;
    has_parameter_ = false;
    typed_count_ = 0;
    typed_exact_ = true;
  }

  ds::Option<std::string_view> CommandInputScanner::typedText() const noexcept {
    return typed_exact_ ? ds::Option<std::string_view>{{typed_.data(), typed_count_}} : ds::none;
  }

  void CommandInputScanner::ground(Byte byte, Event& event) noexcept {
    switch (byte) {
    case escape:
      state_ = State::escape;
      typed_exact_ = false;
      break;
    case '\r':
    case '\n':
      event.submitted = true;
      break;
    case interrupt:
      event.cancelled = true;
      break;
    case backspace:
    case delete_byte:
      typed_count_ -= static_cast<std::size_t>(typed_count_ != 0);
      break;
    case form_feed:
      break;
    default:
      if (byte >= first_printable && byte <= last_printable && typed_count_ < typed_.size()) {
        typed_.atMut(typed_count_++) = static_cast<char>(byte);
      } else {
        typed_exact_ = false;
      }

      break;
    }
  }

  void CommandInputScanner::beginSequence(Byte byte, bool pasted) noexcept {
    if (byte == '[') {
      state_ = pasted ? State::paste_sequence : State::sequence;
      parameter_ = 0;
      has_parameter_ = false;
    } else {
      state_ = pasted ? State::paste : State::ground;
    }
  }

  void CommandInputScanner::sequence(Byte byte, bool pasted) noexcept {
    if (byte >= '0' && byte <= '9') {
      parameter_ = std::min<unsigned>(std::numeric_limits<std::uint16_t>::max(), (parameter_ * decimal) + byte - '0');
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

  // CommandZones

  CommandZones::CommandZones(ConcurrentMemory& memory, std::string_view directory, ds::Option<ShellToken> token) {
    shell_.memory_ = &memory;
    shell_.token_ = token;
    setDirectory(directory);
  }

  ConcurrentMemory& CommandZones::memory() const noexcept {
    return *shell_.memory_;
  }

  ds::Option<ShellToken> CommandZones::token() const noexcept {
    return shell_.token_;
  }

  bool CommandZones::remote() const noexcept {
    return shell_.remote_.hasValue();
  }

  IntegratedShell CommandZones::remoteShell() const noexcept {
    return shell_.remote_ ? shell_.remote_shell_ : IntegratedShell::none;
  }

  void CommandZones::scan(std::span<const Byte> bytes, ObservationTime time, CommandZoneSink& sink) {
    for (std::size_t offset = 0; offset < bytes.size(); ++offset) {
      if (parser_ == ParserState::ground) {
        // A find over bytes is a memchr: the bytes outside sequences are skipped whole.
        const auto rest = bytes.subspan(offset);
        const auto next = std::ranges::find(rest, escape);
        if (next == rest.end()) {
          break;
        }

        offset += static_cast<std::size_t>(next - rest.begin());
      }

      step(bytes[offset], time, sink, offset + 1);
    }
  }

  void CommandZones::step(Byte byte, ObservationTime time, CommandZoneSink& sink, std::size_t end) {
    switch (parser_) {
    case ParserState::ground:
      if (byte == escape) {
        parser_ = ParserState::escape;
      }

      break;
    case ParserState::escape:
      parser_ = byte == ']' ? ParserState::osc : ParserState::ground;
      if (parser_ == ParserState::osc) {
        TELAR_DIAGNOSTIC(diagnostics::accumulate(shell_.metrics_.osc_started));
        length_ = 0;
        overflow_ = false;
      }

      break;
    case ParserState::osc:
      if (byte == bell) {
        parser_ = ParserState::ground;
        finishSequence(time, sink, end);
      } else if (byte == escape) {
        parser_ = ParserState::osc_escape;
      } else if (length_ < bytes_.size()) {
        bytes_.atMut(length_++) = static_cast<char>(byte);
      } else {
        overflow_ = true;
      }

      break;
    case ParserState::osc_escape:
      parser_ = byte == escape ? ParserState::escape : ParserState::ground;
      if (byte == '\\') {
        finishSequence(time, sink, end);
      }

      break;
    }
  }

  void CommandZones::restart() {
    Shell shell;

    shell.memory_ = shell_.memory_;
    shell.token_ = shell_.token_;
    shell.directory_ = shell_.directory_;
    // Clients tell a report from the ones they heard by its count, which goes on.
    shell.typeahead_serial_ = shell_.typeahead_serial_;
    shell_ = std::move(shell);
    parser_ = ParserState::ground;
    length_ = 0;
    overflow_ = false;
  }

  void CommandZones::input(std::span<const Byte> bytes) noexcept {
    if (shell_.zone_ == Zone::input && !bytes.empty()) {
      shell_.has_input_ = true;
    }
  }

  bool CommandZones::editing() const noexcept {
    return shell_.markers_ready_ && shell_.zone_ == Zone::input;
  }

  bool CommandZones::markersReady() const noexcept {
    return shell_.markers_ready_;
  }

  bool CommandZones::running() const noexcept {
    return shell_.markers_ready_ && shell_.zone_ == Zone::output;
  }

  void CommandZones::setDirectory(std::string_view directory) {
    shell_.directory_.assign(directory.substr(0, directory_capacity));
  }

  std::string_view CommandZones::directory() const noexcept {
    return shell_.directory_.view();
  }

  std::string_view CommandZones::path() const noexcept {
    return shell_.path_.view();
  }

  const std::shared_ptr<const ds::String<ConcurrentMemory>>& CommandZones::names() const noexcept {
    return shell_.names_;
  }

  std::string_view CommandZones::remoteHost() const noexcept {
    return shell_.remote_ ? shell_.host_.view() : std::string_view{};
  }

  std::string_view CommandZones::remoteDirectory() const noexcept {
    return shell_.remote_ ? shell_.remote_directory_.view() : std::string_view{};
  }

  std::string_view CommandZones::remoteControl() const noexcept {
    return shell_.remote_ ? shell_.control_.view() : std::string_view{};
  }

  std::string_view CommandZones::typeahead() const noexcept {
    return shell_.typeahead_.view();
  }

  std::uint64_t CommandZones::typeaheadSerial() const noexcept {
    return shell_.typeahead_serial_;
  }

#if TELAR_DIAGNOSTICS
  diagnostics::CommandCaptureCounters CommandZones::takeMetrics() noexcept {
    return std::exchange(shell_.metrics_, {});
  }
#endif

  void CommandZones::finishSequence(ObservationTime time, CommandZoneSink& sink, std::size_t end) {
    TELAR_DIAGNOSTIC(diagnostics::accumulate(shell_.metrics_.osc_finished));
    if (overflow_) {
      // A names report too long to keep: the shell's names are unknown, not empty.
      if (std::string_view{bytes_.data(), length_}.starts_with("6973;")) {
        shell_.names_.reset();
      }

      return;
    }

    const std::string_view sequence{bytes_.data(), length_};
    const auto separator = sequence.find(';');
    const auto code = sequence.substr(0, separator);
    const auto body = separator == std::string_view::npos ? std::string_view{} : sequence.substr(separator + 1);

    if (code == "133") {
      shell_.semantic(body, time, sink, end);
    } else if (code == "7") {
      shell_.directoryReport(body);
    } else if (code == private_code && shell_.endReport(body)) {
      note(sink, 'E', end);
    } else if (const auto above = code == private_code ? shell_.jobsReport(body) : ds::none) {
      note(sink, 'J', end, above);
    } else if (code == private_code && shell_.privateReport(body)) {
      note(sink, 'N', end);
    }
  }

  // telar's own reports, OSC 6973. The pane's shell signs three: its PATH, so completion finds
  // the commands it runs (telar=<token>;path=<PATH>), its aliases and functions
  // (telar=<token>;names=<blank-separated names>), and the one-time nonce `ssh` hands the
  // remote host before it connects (telar=<token>;nest=<nonce>, with ;control=<socket> when the
  // session shares its connection). The remote shell answers
  // with the nonce and the token its own marks carry (nest=<nonce>;token=<token>;shell=<name>):
  // the nonce stands in for a signature, once, so the pane's token never leaves the host.
  // True when the remote shell took over.
  bool CommandZones::Shell::privateReport(std::string_view body) {
    if (!token_) {
      return false;
    }

    const auto signature = option(body, ReportOption::telar);
    if (signature.empty()) {
      const auto token = ShellToken::parse(option(body, ReportOption::token));
      if (nest_ && token && nest_->signs(option(body, ReportOption::nest))) {
        nest_.reset();
        remote_ = token;
        remote_shell_ = shellNamed(option(body, ReportOption::shell));
        // Older remote scripts name no user.
        const auto user = option(body, ReportOption::user);

        remote_user_.assign(nameFits(user, user_capacity) ? user : std::string_view{});
        // Only the pane's own shell names the socket; the remote one cannot.
        control_ = nest_control_;
        nest_control_.assign(std::string_view{});
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
      // The shell `ssh` reached signs its line with its own token: it runs the commands telar's
      // editor sends while it hosts the pane.
      if (remote_ && remote_->signs(signature)) {
        if (const auto line = option(body, ReportOption::typeahead); !line.empty()) {
          typeaheadReport(line);
        }
      }

      return false;
    }

    if (const auto line = option(body, ReportOption::typeahead); !line.empty()) {
      typeaheadReport(line);
      return false;
    }

    constexpr std::string_view names_option = ";names=";

    if (body.contains(names_option)) {
      if (memory_ == nullptr) {
        return false;
      }

      // The last option, so its names may be anything but the sequence's terminators.
      const auto names = body.substr(body.find(names_option) + names_option.size());

      // The shell's own copy, made before the shared object that hands it to other threads.
      ds::String<ConcurrentMemory> copied{*memory_, names};

      names_ = std::allocate_shared<ds::String<ConcurrentMemory>>(AllocatorRef<ds::String<ConcurrentMemory>, ConcurrentMemory>{*memory_}, std::move(copied));
      return false;
    }

    if (const auto nonce = option(body, ReportOption::nest); !nonce.empty()) {
      nestReport(body);
      return false;
    }

    ds::Array<char, path_capacity> decoded; // NOLINT(cppcoreguidelines-pro-type-member-init): percentDecode writes each byte it counts before the path reads it, so zeroing 8 KiB for every report would be waste

    if (const auto path = option(body, ReportOption::path); !path.empty()) {
      if (const auto count = percentDecode(path, decoded.viewMut())) {
        path_.assign({decoded.data(), *count});
      }
    }

    return false;
  }

  void CommandZones::Shell::nestReport(std::string_view body) {
    const auto control = option(body, ReportOption::control);

    nest_ = ShellToken::parse(option(body, ReportOption::nest));
    nest_control_.assign(nest_ && controlFits(control) ? control : std::string_view{});
  }

  void CommandZones::Shell::semantic(std::string_view body, ObservationTime time, CommandZoneSink& sink, std::size_t end) {
    const auto separator = body.find(';');
    const auto action = body.substr(0, separator);
    const auto options = separator == std::string_view::npos ? std::string_view{} : body.substr(separator + 1);

    if (token_ && !signedMark(options, action == "A" || action == "D", sink, end)) {
      return;
    }

    if (action == "A" || action == "B") {
      note(sink, action.front(), end);
    } else if (action == "C") {
      sink.mark(CommandMark{.action = 'C', .end = end, .place = place()});
    } else if (action == "D") {
      note(sink, 'D', end, parseExitCode(options));
    }

    if (action == "A" || action == "P") {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.prompt_markers));
      if (running_) {
        sink.complete({.time = time, .exit_code = ds::none, .status = HistoryStatus::interrupted});
      }

      running_ = false;
      has_input_ = false;
      zone_ = Zone::prompt;
    } else if (action == "B") {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.input_markers));
      markers_ready_ |= zone_ == Zone::prompt;
      // A prompt where output was due: the line editor took the command back before it ran, as
      // zsh's spelling correction does when the answer is e(dit). It never ran, so nothing ends.
      if (zone_ == Zone::output) {
        running_ = false;
      }

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
        sink.complete({.time = time, .exit_code = parseExitCode(options), .status = HistoryStatus::completed});
        running_ = false;
        has_input_ = false;
      }
    }
  }

  bool CommandZones::Shell::signedMark(std::string_view options, bool clears_nest, CommandZoneSink& sink, std::size_t end) {
    const auto signature = option(options, ReportOption::telar);
    if (!token_->signs(signature)) {
      return remote_ && remote_->signs(signature);
    }

    // The pane's own shell again: the session `ssh` nested ended, or never started.
    if (remote_) {
      remote_.reset();
      running_ = nested_running_;
      zone_ = Zone::output;
      note(sink, 'U', end);
    }

    if (clears_nest) {
      nest_.reset();
    }

    return true;
  }

  void CommandZones::Shell::directoryReport(std::string_view body) {
    for (const auto prefix : {std::string_view{"file://"}, std::string_view{"kitty-shell-cwd://"}}) {
      if (!body.starts_with(prefix)) {
        continue;
      }

      const auto remainder = body.substr(prefix.size());
      const auto slash = remainder.find('/');
      if (slash == std::string_view::npos) {
        return;
      }

      ds::Array<char, directory_capacity> decoded; // NOLINT(cppcoreguidelines-pro-type-member-init): percentDecode writes each byte it counts before the directory reads it, so zeroing 4 KiB for every report would be waste
      const auto count = percentDecode(remainder.substr(slash), decoded.viewMut());
      const auto host = remainder.substr(0, slash);

      if (!remote_) {
        if (count) {
          directory_.assign({decoded.data(), *count});
        }

        if (nameFits(host, host_capacity)) {
          local_host_.assign(host);
        }

        return;
      }

      // A remote shell's report names a place on its host, which clients show as text.
      if (nameFits(host, host_capacity)) {
        host_.assign(host);
      }

      if (count && std::ranges::all_of(std::string_view{decoded.data(), *count}, printable)) {
        remote_directory_.assign({decoded.data(), *count});
      }

      return;
    }
  }

  bool CommandZones::Shell::endReport(std::string_view body) const noexcept {
    constexpr std::string_view ended = ";ended";
    const auto signature = option(body, ReportOption::telar);

    if (!body.ends_with(ended) || signature.empty()) {
      return false;
    }

    // The pane's shell, or the one ssh reached while it hosts the pane.
    return (token_ && token_->signs(signature)) || (remote_ && remote_->signs(signature));
  }

  // The end of what the shell reported of its background jobs once a command ended
  // (telar=<token>;jobs=<lines>), with the count of lines bash may have reported above where the
  // command's output ended, as it waited for the command: at most a screen's worth.
  ds::Option<int> CommandZones::Shell::jobsReport(std::string_view body) const noexcept {
    constexpr int most_lines = 256;
    const auto signature = option(body, ReportOption::telar);
    const auto lines = option(body, ReportOption::jobs);
    if (signature.empty() || lines.empty() || !((token_ && token_->signs(signature)) || (remote_ && remote_->signs(signature)))) {
      return ds::none;
    }

    const auto count = parseExact<int>(lines);
    if (!count || *count < 0) {
      return ds::none;
    }

    return std::min(*count, most_lines);
  }

  CommandPlace CommandZones::Shell::place() const noexcept {
    if (remote_) {
      return {.directory = remote_directory_.view(), .host = host_.view(), .user = remote_user_.view(), .remote = true};
    }

    return {.directory = directory_.view(), .host = local_host_.view()};
  }

  // The line the shell's editor held (telar=<token>;typeahead=<%-encoded line>), which its
  // integration reports and clears when telar types its flush key before a command. A line
  // longer than telar keeps is cut on a character; one that is not UTF-8 is not text to show.
  void CommandZones::Shell::typeaheadReport(std::string_view encoded) {
    // Room for the rest of a character the capacity cuts, which the prefix below drops.
    constexpr std::size_t scalar_rest = 3;
    ds::Array<char, typeahead_capacity + scalar_rest> decoded; // NOLINT(cppcoreguidelines-pro-type-member-init): the loop writes each byte it counts before the line reads it
    std::size_t count = 0;

    for (std::size_t index = 0; index < encoded.size() && count < decoded.size(); ++index) {
      auto byte = encoded[index];
      if (byte == '%') {
        const auto value = encoded.size() - index < 3 ? ds::none : parseExact<unsigned>(textPrefix(textAfter(encoded, index + 1), 2), hexadecimal);
        if (!value) {
          return;
        }

        byte = static_cast<char>(*value);
        index += 2;
      }

      decoded.atMut(count++) = byte;
    }

    const auto size = utf8Prefix({decoded.data(), count}, typeahead_capacity).size();
    if (inspectUtf8({decoded.data(), size}) != Utf8Validation::valid) {
      return;
    }

    // What the editor shows: a control byte the line held (a ^V-quoted one, say) is a blank.
    for (auto& byte : decoded.viewMut().first(size)) {
      byte = printable(byte) || byte == '\n' || byte == '\t' ? byte : ' ';
    }

    typeahead_.assign({decoded.data(), size});
    ++typeahead_serial_;
  }

  // CommandOutputWindow

  void CommandOutputWindow::append(std::span<std::uint8_t> storage, std::span<const std::uint8_t> bytes) noexcept {
    if (storage.empty()) {
      return;
    }

    observed_ += std::min<std::uint64_t>(bytes.size(), std::numeric_limits<std::uint64_t>::max() - observed_);
    if (bytes.size() >= storage.size()) {
      std::ranges::copy(bytes.last(storage.size()), storage.begin());
      head_ = 0;
      length_ = storage.size();
      return;
    }

    const auto write = (head_ + length_) % storage.size();
    const auto first = std::min(bytes.size(), storage.size() - write);

    std::ranges::copy(bytes.first(first), storage.subspan(write).begin());
    std::ranges::copy(bytes.subspan(first), storage.begin());
    length_ += bytes.size();
    if (length_ > storage.size()) {
      head_ = (head_ + length_ - storage.size()) % storage.size();
      length_ = storage.size();
    }
  }

  namespace {

    constexpr std::uint8_t escape_byte = 0x1b;

    // Where the escape sequence that starts at `start` ends, one past its last byte, or the end of
    // `bytes` for one they leave open: a CSI at its final byte, a string (OSC, DCS, APC, PM, SOS)
    // at its terminator, any other at the byte that completes it.
    std::size_t sequenceEnd(std::span<const std::uint8_t> bytes, std::size_t start) noexcept {
      constexpr std::uint8_t bell = 0x07;
      constexpr std::uint8_t first_intermediate = 0x20;
      constexpr std::uint8_t last_intermediate = 0x2f;
      constexpr std::uint8_t last_parameter = 0x3f;
      auto index = start + 1;

      if (index >= bytes.size()) {
        return bytes.size();
      }

      const auto kind = bytes[index++];

      if (kind == '[') {
        while (index < bytes.size() && bytes[index] >= first_intermediate && bytes[index] <= last_parameter) {
          ++index;
        }

        return std::min(index + 1, bytes.size());
      }

      if (kind == ']' || kind == 'P' || kind == 'X' || kind == '^' || kind == '_') {
        for (; index < bytes.size(); ++index) {
          if (bytes[index] == bell) {
            return index + 1;
          }

          if (bytes[index] == escape_byte) {
            return index + 1 < bytes.size() && bytes[index + 1] == '\\' ? index + 2 : index;
          }
        }

        return bytes.size();
      }

      while (kind >= first_intermediate && kind <= last_intermediate && index < bytes.size() && bytes[index] >= first_intermediate && bytes[index] <= last_intermediate) {
        ++index;
      }

      return kind >= first_intermediate && kind <= last_intermediate ? std::min(index + 1, bytes.size()) : index;
    }

    // The first byte at or after `start` that begins a character outside an escape sequence: an
    // escape that began in the lookback before it and is still open there is skipped, and so are
    // the continuation bytes of a character the cut split.
    std::size_t boundary(std::span<const std::uint8_t> bytes, std::size_t start) noexcept {
      constexpr std::uint8_t continuation_mask = 0xc0;
      constexpr std::uint8_t continuation_tag = 0x80;
      constexpr std::size_t longest_character = 4;
      const auto floor = start > CommandOutputWindow::lookback ? start - CommandOutputWindow::lookback : 0;

      for (auto index = start; index > floor; --index) {
        if (bytes[index - 1] == escape_byte) {
          start = std::max(start, sequenceEnd(bytes, index - 1));
          break;
        }
      }

      for (std::size_t skipped = 1; skipped < longest_character && start < bytes.size() && (bytes[start] & continuation_mask) == continuation_tag; ++skipped) {
        ++start;
      }

      return start;
    }

  }

  tbc::val_a<std::span<const std::uint8_t>> CommandOutputWindow::bytes(tbc::val_a<std::span<std::uint8_t>> storage) noexcept {
    // A ring starts anywhere but at the front only once it is full, so it fills the storage.
    if (head_ != 0) {
      std::ranges::rotate(storage, storage.begin() + static_cast<std::ptrdiff_t>(head_));
      head_ = 0;
    }

    const std::span<const std::uint8_t> held = storage.first(length_);
    const auto cut = held.size() > capacity ? held.size() - capacity : 0;

    return held.subspan(cut == 0 ? 0 : boundary(held, cut));
  }

  std::uint64_t CommandOutputWindow::observed() const noexcept {
    return observed_;
  }

  void CommandOutputWindow::clear() noexcept {
    head_ = 0;
    length_ = 0;
    observed_ = 0;
  }

  // CommandTextWriter

  CommandTextWriter::CommandTextWriter(tbc::val_a<std::span<Byte>> destination) noexcept
      : destination_(destination) {}

  GhosttyWriter CommandTextWriter::ghostty() noexcept {
    return GhosttyWriter{.write = receive, .userdata = this};
  }

  ds::Option<bool> CommandTextWriter::finish() noexcept {
    if (length_ == 0) {
      return ds::none;
    }

    const bool truncated = overflow_ || length_ > CommandSelection::maximum_bytes;
    const auto text = textView(destination_.first(length_));

    length_ = utf8Prefix(text, CommandSelection::maximum_bytes).size();
    return truncated;
  }

  std::size_t CommandTextWriter::length() const noexcept {
    return length_;
  }

  bool CommandTextWriter::receive(void* context, const Byte* bytes, std::size_t count) noexcept {
    auto& writer = *static_cast<CommandTextWriter*>(context);
    const auto copied = std::min(count, writer.destination_.size() - writer.length_);

    std::copy_n(bytes, copied, writer.destination_.subspan(writer.length_).begin());
    writer.length_ += copied;
    writer.overflow_ |= copied != count;
    return true;
  }

  // CommandSelection

  namespace {

    using SelectionReference = GhosttyHandle<GhosttyTrackedGridRef, ghostty_tracked_grid_ref_free>;

    GhosttyPointCoordinate cursor(GhosttyTerminal terminal) {
      std::uint16_t column = 0;
      std::uint16_t row = 0;

      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &column));
      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &row));
      return {.x = column, .y = row};
    }

    GhosttyPoint point(GhosttyPointTag tag, GhosttyPointCoordinate coordinate) noexcept {
      return {.tag = tag, .value = {.coordinate = coordinate}};
    }

    ds::Option<GhosttyGridRef> snapshot(const SelectionReference& tracked) {
      auto result = ghosttySized<GhosttyGridRef>();
      const auto status = ghostty_tracked_grid_ref_snapshot(tracked.get(), &result);
      if (status == GHOSTTY_NO_VALUE) {
        return ds::none;
      }

      checkGhostty(status);
      return result;
    }

    GhosttyPointCoordinate coordinates(GhosttyTerminal terminal, const GhosttyGridRef& reference) {
      GhosttyPointCoordinate result{};

      checkGhostty(ghostty_terminal_point_from_grid_ref(terminal, &reference, GHOSTTY_POINT_TAG_SCREEN, &result));
      return result;
    }

    void set(SelectionReference& tracked, GhosttyTerminal terminal, GhosttyPointTag tag, GhosttyPointCoordinate coordinate) { // NOLINT(misc-const-correctness): ghostty writes through the handle, which tbc reads const as forbidding
      checkGhostty(ghostty_tracked_grid_ref_set(tracked.get(), terminal, point(tag, coordinate)));
    }

    GhosttyPointCoordinate leftOf(GhosttyPointCoordinate position) noexcept {
      --position.x;
      return position;
    }

    bool before(GhosttyPointCoordinate left, GhosttyPointCoordinate right) noexcept {
      return left.y < right.y || (left.y == right.y && left.x < right.x);
    }

    GhosttyCell cell(GhosttyGridRef reference, std::uint16_t column) {
      reference.x = column;
      GhosttyCell result = 0;

      checkGhostty(ghostty_grid_ref_cell(&reference, &result));
      return result;
    }

    // Whether the row's first `columns` cells hold nothing but blanks.
    bool blank(GhosttyGridRef row, std::uint16_t columns) {
      for (std::uint16_t column = 0; column < columns; ++column) {
        const auto value = cell(row, column);
        if (cellHasText(value) && cell_layout::codepoint(value) != ' ') {
          return false;
        }
      }

      return true;
    }

    bool matches(GhosttyGridRef cursor, std::string_view typed) {
      const auto start = cursor.x - typed.size();

      for (std::size_t index = 0; index < typed.size(); ++index) {
        const auto value = cell(cursor, static_cast<std::uint16_t>(start + index));
        const auto codepoint = cellHasText(value) ? cell_layout::codepoint(value) : ' ';
        if (codepoint != static_cast<unsigned char>(typed[index])) {
          return false;
        }
      }

      return true;
    }

    std::uint64_t hash(GhosttyGridRef start, std::uint16_t columns) {
      auto result = fnv1a64_basis;

      for (auto column = start.x; column < columns; ++column) {
        result = (result ^ cell(start, column)) * fnv1a64_prime;
      }

      return result;
    }

  }

  CommandSelection::CommandSelection(GhosttyTerminal terminal) {
    const auto position = point(GHOSTTY_POINT_TAG_ACTIVE, cursor(terminal));

    checkGhostty(ghostty_terminal_grid_ref_track(terminal, position, anchor_.output()));
    checkGhostty(ghostty_terminal_grid_ref_track(terminal, position, right_prompt_.output()));
  }

  bool CommandSelection::primary(CommandScreen screen) {
    GhosttyTerminalScreen active{};

    checkGhostty(ghostty_terminal_get(screen.terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active));
    return active == GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  }

  void CommandSelection::begin(CommandScreen screen) {
    set(anchor_, screen.terminal, GHOSTTY_POINT_TAG_ACTIVE, cursor(screen.terminal));
    erased_ = false;
    findRightPrompt(screen);
  }

  void CommandSelection::rebase(CommandScreen screen, ds::Option<std::string_view> typed) {
    const auto anchor = snapshot(anchor_);
    if (!anchor) {
      return;
    }

    erased_ |= blank(*anchor, screen.columns);
    const auto position = cursor(screen.terminal);
    const auto current = gridReference(screen.terminal, GHOSTTY_POINT_TAG_ACTIVE, position);
    auto start = position.x;

    if (typed && !typed->empty() && typed->size() <= position.x && matches(current, *typed)) {
      start -= typed->size();
    }

    if (start == 0 || blank(current, start)) {
      return;
    }

    const bool same_row = current.node == anchor->node && current.y == anchor->y;
    if (!erased_ && (same_row || start == position.x)) {
      return;
    }

    set(anchor_, screen.terminal, GHOSTTY_POINT_TAG_ACTIVE, {.x = start, .y = position.y});
    erased_ = false;
    findRightPrompt(screen);
  }

  tbc::val_a<ds::Option<GhosttySelection>> CommandSelection::select(tbc::val_a<CommandScreen> screen) const {
    const auto anchor = snapshot(anchor_);
    if (!primary(screen) || !anchor || erased_ || blank(*anchor, screen.columns)) {
      return ds::none;
    }

    const auto start = coordinates(screen.terminal, *anchor);
    auto finish = coordinates(screen.terminal, gridReference(screen.terminal, GHOSTTY_POINT_TAG_ACTIVE, cursor(screen.terminal)));
    if (before(finish, start)) {
      return ds::none;
    }

    const auto maximum_rows = (maximum_bytes / screen.columns) + 2;
    if (finish.y - start.y > maximum_rows) {
      finish = {.x = static_cast<std::uint16_t>(screen.columns - 1), .y = start.y + static_cast<std::uint32_t>(maximum_rows)};
    }

    finish = selectionFinish(screen, start, finish);
    auto selection = ghosttySized<GhosttySelection>();

    selection.start = *anchor;
    selection.end = gridReference(screen.terminal, GHOSTTY_POINT_TAG_SCREEN, finish);
    return selection;
  }

  void CommandSelection::findRightPrompt(CommandScreen screen) {
    right_prompt_active_ = false;
    auto anchor = *snapshot(anchor_);
    unsigned blank_columns = 0;

    for (auto column = anchor.x; column < screen.columns; ++column) {
      if (!cellHasText(cell(anchor, column))) {
        ++blank_columns;
        continue;
      }

      if (blank_columns < 2) {
        blank_columns = 0;
        continue;
      }

      anchor.x = column;
      set(right_prompt_, screen.terminal, GHOSTTY_POINT_TAG_SCREEN, coordinates(screen.terminal, anchor));
      right_prompt_hash_ = hash(anchor, screen.columns);
      right_prompt_active_ = true;
      return;
    }
  }

  GhosttyPointCoordinate CommandSelection::selectionFinish(CommandScreen screen, GhosttyPointCoordinate start, GhosttyPointCoordinate fallback) const {
    const auto right_prompt = right_prompt_active_ ? snapshot(right_prompt_) : ds::none;
    if (!right_prompt || right_prompt->x == 0) {
      return fallback;
    }

    const auto position = coordinates(screen.terminal, *right_prompt);
    if (before(start, position) && before(position, fallback) && hash(*right_prompt, screen.columns) == right_prompt_hash_) {
      return leftOf(position);
    }

    return fallback;
  }

  // CommandBlockRing

  CommandBlockRing::TrackedReference::TrackedReference(TrackedReference&& other) noexcept
      : handle_(std::exchange(other.handle_, nullptr)) {}

  CommandBlockRing::TrackedReference& CommandBlockRing::TrackedReference::operator=(TrackedReference&& other) noexcept {
    if (this != &other) {
      release();
      handle_ = std::exchange(other.handle_, nullptr);
    }

    return *this;
  }

  CommandBlockRing::TrackedReference::~TrackedReference() {
    release();
  }

  GhosttyTrackedGridRef CommandBlockRing::TrackedReference::get() const noexcept {
    return handle_;
  }

  GhosttyTrackedGridRef* CommandBlockRing::TrackedReference::output() noexcept {
    return &handle_;
  }

  void CommandBlockRing::TrackedReference::release() noexcept {
    if (handle_ != nullptr) {
      ghostty_tracked_grid_ref_free(handle_);
      handle_ = nullptr;
    }
  }

  CommandBlockRing::Place::Place(ConcurrentMemory& memory)
      : directory(memory),
        host(memory),
        user(memory),
        branch(memory) {}

  CommandBlockRing::CommandBlockRing(tbc::mut_c<ConcurrentMemory> memory, tbc::val_a<GhosttyTerminal> terminal)
      : memory_(memory),
        selection_(terminal) {}

  void CommandBlockRing::mark(char action, std::chrono::steady_clock::time_point now, const CommandPlace& place) {
    switch (action) {
    case 'A':
      if (running_) {
        finish(CommandBlockState::interrupted, 0, now);
      }

      // The pane's shell is back without saying how ssh ended.
      if (closing_) {
        closeSession(CommandBlockState::interrupted, 0, now);
      }

      // What the shell reported of its jobs once the command ended is no part of its output.
      background(now, true);
      report_.reset();

      prompt_ = CommandSelection::primary(screen()) ? track() : ds::none;
      prompt_height_.reset();
      if (prompt_) {
        if (const auto prompt_row = row(*prompt_)) {
          cover(*prompt_row);
        }
      }

      break;
    case 'B': {
      // A prompt while a command runs: the line editor took the command back before it ran, as
      // zsh's spelling correction does when the answer is e(dit).
      const bool taken = running_;

      if (taken) {
        takeBack();
      }

      redrawn(now, !taken);
      selection_.begin(screen());
      break;
    }
    case 'C':
      report_.reset();
      reported_.reset();
      start(now, place);
      break;
    case 'E':
      if (!report_) {
        reportStarts();
      }

      break;
    case 'D':
      if (running_) {
        finish(CommandBlockState::succeeded, 0, now);
      }

      break;
    case 'N':
      // The running command, ssh, now hosts the remote shell, whose commands follow it.
      if (running_ && count_ != 0) {
        entryMut(count_ - 1).state = CommandBlockState::session;
        entryMut(count_ - 1).nest = CommandBlockNest::opens;
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

  void CommandBlockRing::place(CommandMark mark, std::chrono::steady_clock::time_point now) {
    if (mark.action == 'D') {
      // bash and fish say nothing between the command's output and its end mark.
      if (!report_) {
        reportStarts();
      }

      finished(mark.status, now);
    } else if (mark.action == 'J') {
      reportEnds(static_cast<std::uint32_t>(std::max(mark.status.valueOr(0), 0)));
    } else {
      this->mark(mark.action, now, mark.place);
    }
  }

  void CommandBlockRing::finished(ds::Option<int> status, std::chrono::steady_clock::time_point now) {
    // A shell reports a command a signal ended as 128 plus the signal: Ctrl-C's SIGINT, or the
    // SIGPIPE of a pipeline whose reader stopped early (`yes | head`). Neither failed.
    constexpr int interrupted_status = 128 + SIGINT;
    constexpr int broken_pipe_status = 128 + SIGPIPE;
    const auto code = status.valueOr(0);
    auto state = code == 0 ? CommandBlockState::succeeded : CommandBlockState::failed;

    if (code == interrupted_status || code == broken_pipe_status) {
      state = CommandBlockState::interrupted;
    }

    if (closing_) {
      closeSession(state, code, now);
    } else if (running_) {
      finish(state, code, now);
    }
  }

  void CommandBlockRing::follow(bool reflowed) {
    if (count_ == 0 || !CommandSelection::primary(screen())) {
      return;
    }

    // Restored blocks come first and have no rows to follow.
    std::size_t live = 0;

    while (live < count_ && entry(live).restored) {
      ++live;
    }

    if (live == count_) {
      return;
    }

    if (!reflowed) {
      const auto oldest = row(entry(live).anchor);
      if (oldest && *oldest == entry(live).row) {
        return;
      }
    }

    // Newest first, so a block whose rows were erased, or that a later prompt was drawn over,
    // goes: its output would start below the next block's prompt.
    ds::Array<bool, capacity> keep{};
    auto limit = std::numeric_limits<std::uint32_t>::max();

    for (std::size_t index = 0; index < live; ++index) {
      keep.atMut(index) = true;
    }

    for (auto index = count_; index-- > live;) {
      auto& current = entryMut(index);
      const auto first = row(current.anchor);
      const auto last = outputRow(current, first);
      if (!last || *last > limit || (current.state == CommandBlockState::background && *first >= limit)) {
        continue;
      }

      current.row = *first;
      current.rows = static_cast<std::uint16_t>(std::min<std::uint32_t>(*last - *first, std::numeric_limits<std::uint16_t>::max()));
      limit = *first;
      keep.atMut(index) = true;
    }

    std::size_t kept = 0;

    for (std::size_t index = 0; index < count_; ++index) {
      if (!keep[index]) {
        continue;
      }

      if (kept != index) {
        std::swap(entryMut(kept), entryMut(index));
      }

      ++kept;
    }

    // The anchors of the blocks that went stop costing the terminal its tracking.
    for (auto index = kept; index < count_; ++index) {
      entryMut(index) = Entry{};
    }

    count_ = kept;
    ++revision_;
  }

  std::uint64_t CommandBlockRing::revision() const noexcept {
    return revision_;
  }

  const ds::Option<CommandBlockRing::Latest>& CommandBlockRing::latest() const noexcept {
    return latest_;
  }

  std::uint64_t CommandBlockRing::commandRevision() const noexcept {
    return command_revision_;
  }

  tbc::val_b<PaneBlocks> CommandBlockRing::message(std::uint64_t pane_id, tbc::mut_b<ds::Array<CommandBlock, capacity>> storage) const {
    for (std::size_t index = 0; index < count_; ++index) {
      const auto& current = entry(index);

      auto& block = storage.atMut(index);

      block = CommandBlock{.row = current.row, .rows = current.rows, .lines = current.lines, .state = current.state, .status = current.status, .duration_ms = current.duration_ms, .command = current.command.view(), .nest = current.nest, .started_ms = current.started_ms, .restored = current.restored};
      if (current.restored) {
        block.row = 0;
        block.rows = 0;
      }

      if (current.place) {
        block.directory = current.place->directory.view();
        block.host = current.place->host.view();
        block.user = current.place->user.view();
        block.branch = current.place->branch.view();
      }
    }

    return PaneBlocks{.pane_id = pane_id, .blocks = std::span<const CommandBlock>{storage}.first(count_)};
  }

  tbc::val_b<std::span<const CommandBlockRecord>> CommandBlockRing::records(tbc::mut_b<ds::Array<CommandBlockRecord, capacity>> storage) const {
    std::size_t count = 0;

    for (std::size_t index = 0; index < count_; ++index) {
      const auto& current = entry(index);
      if (current.state == CommandBlockState::background) {
        continue;
      }

      auto& record = storage.atMut(count++);

      record = CommandBlockRecord{.state = current.state, .status = current.status, .duration_ms = current.duration_ms, .started_ms = current.started_ms, .lines = current.lines, .nest = current.nest, .command = current.command.view()};
      if (current.place) {
        record.directory = current.place->directory.view();
        record.host = current.place->host.view();
        record.user = current.place->user.view();
        record.branch = current.place->branch.view();
      }
    }

    return std::span<const CommandBlockRecord>{storage}.first(count);
  }

  void CommandBlockRing::restore(const CommandBlockRecord& block) {
    if (count_ == capacity) {
      return;
    }

    // After the restored ones, which come first: the blocks of this runtime move back one.
    std::size_t restored = 0;

    while (restored < count_ && entry(restored).restored) {
      ++restored;
    }

    for (auto index = count_; index > restored; --index) {
      std::swap(entryMut(index), entryMut(index - 1));
    }

    ++count_;
    auto& added = entryMut(restored);
    const bool ended = block.state == CommandBlockState::succeeded || block.state == CommandBlockState::failed || block.state == CommandBlockState::interrupted;

    added = Entry{};
    added.restored = true;
    added.lines = block.lines;
    added.state = ended ? block.state : CommandBlockState::interrupted;
    added.nest = block.nest;
    added.status = ended ? block.status : 0;
    added.duration_ms = block.duration_ms;
    added.started_ms = block.started_ms;
    added.command.assign(displayed(block.command, command_bytes));

    auto& where = added.place.emplace(memory_);

    where.directory.assign(displayed(block.directory, max_block_directory_bytes));
    where.host.assign(displayed(block.host, max_block_host_bytes));
    where.user.assign(displayed(block.user, max_block_user_bytes));
    where.branch.assign(displayed(block.branch, max_branch_bytes));
    ++revision_;
  }

  CommandBlockRing::Entry& CommandBlockRing::entryMut(std::size_t index) noexcept {
    return entries_.atMut((first_ + index) % capacity);
  }

  tbc::ref_b<CommandBlockRing::Entry> CommandBlockRing::entry(std::size_t index) const noexcept {
    return entries_[(first_ + index) % capacity];
  }

  // A reference that follows the cursor's row as the terminal scrolls.
  ds::Option<CommandBlockRing::TrackedReference> CommandBlockRing::track() {
    auto* const terminal = screen().terminal;
    std::uint16_t row = 0;

    checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &row));
    TrackedReference tracked;
    const GhosttyPoint point{.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {.x = 0, .y = row}}};
    if (ghostty_terminal_grid_ref_track(terminal, point, tracked.output()) != GHOSTTY_SUCCESS) {
      return ds::none;
    }

    return tracked;
  }

  ds::Option<CommandBlockRing::TrackedReference> CommandBlockRing::track(std::uint16_t row) {
    TrackedReference tracked;
    const GhosttyPoint point{.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {.x = 0, .y = row}}};
    if (ghostty_terminal_grid_ref_track(screen().terminal, point, tracked.output()) != GHOSTTY_SUCCESS) {
      return ds::none;
    }

    return tracked;
  }

  void CommandBlockRing::redrawn(std::chrono::steady_clock::time_point now, bool idle) {
    const auto view = screen();
    if (!prompt_ || !CommandSelection::primary(view)) {
      return;
    }

    std::uint16_t cursor_row = 0;

    checkGhostty(ghostty_terminal_get(view.terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursor_row));
    const auto bottom = coordinates(view.terminal, gridReference(view.terminal, GHOSTTY_POINT_TAG_ACTIVE, {.x = 0, .y = cursor_row})).y;

    // The first B after the A: how tall the shell's prompt is.
    if (!prompt_height_) {
      const auto top = row(*prompt_);

      prompt_height_ = top && *top <= bottom ? bottom - *top : 0;
      return;
    }

    const auto height = static_cast<std::uint16_t>(std::min<std::uint32_t>(*prompt_height_, cursor_row));
    const auto top = row(*prompt_);
    auto moved = track(static_cast<std::uint16_t>(cursor_row - height));
    if (!moved) {
      return;
    }

    // Drawn lower, though not at the top of a screen cleared for it (Ctrl-L): output came at the
    // prompt, a background job's that zsh's job report follows, or one bash's line editor finds
    // when telar's key redraws the line. It is a block of its own, not the last command's.
    if (idle && top && *top < bottom - height && cursor_row != height) {
      background(now);
    }

    prompt_ = std::move(moved);
    cover(bottom - height);
  }

  void CommandBlockRing::background(std::chrono::steady_clock::time_point now, bool reported) {
    auto anchor = std::exchange(reported ? reported_ : prompt_, ds::none);
    const auto first = anchor ? row(*anchor) : ds::none;
    if (!first) {
      return;
    }

    cover(*first);
    if (count_ == capacity) {
      first_ = (first_ + 1) % capacity;
      --count_;
    }

    auto& added = entryMut(count_++);

    added = Entry{};
    added.anchor = std::move(anchor.getMut());
    added.row = *first;
    added.rows = 0;
    added.state = CommandBlockState::background;
    added.nest = nested_ ? CommandBlockNest::inside : CommandBlockNest::none;
    added.started = now;
    added.started_ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    ++revision_;
  }

  void CommandBlockRing::reportStarts() {
    const auto view = screen();
    if (!CommandSelection::primary(view)) {
      return;
    }

    const auto position = cursor(view.terminal);

    report_ = track();
    // The shell's report starts on a line of its own.
    report_next_row_ = position.x != 0;
  }

  void CommandBlockRing::reportEnds(std::uint32_t above) {
    const auto start = report_ ? row(*report_) : ds::none;
    const auto view = screen();
    if (!start || !CommandSelection::primary(view)) {
      report_.reset();
      return;
    }

    const auto position = cursor(view.terminal);
    const auto end = coordinates(view.terminal, gridReference(view.terminal, GHOSTTY_POINT_TAG_ACTIVE, position)).y + (position.x != 0 ? 1U : 0U);
    auto first = *start + (report_next_row_ ? 1U : 0U);

    report_.reset();
    // Never above where the newest command's output starts.
    if (above != 0 && count_ != 0 && !entry(count_ - 1).restored) {
      const auto& newest = entry(count_ - 1);
      const auto floor = outputRow(newest, row(newest.anchor));

      if (floor && *floor < first) {
        first = reportsAbove(first, above, *floor);
      }
    }

    if (end > first) {
      reported_ = trackScreen(first);
    }
  }

  namespace {

    bool wrapped(GhosttyTerminal terminal, std::uint32_t row) {
      const auto reference = gridReference(terminal, GHOSTTY_POINT_TAG_SCREEN, {.x = 0, .y = row});
      GhosttyRow found = 0;
      bool wraps = false;

      return ghostty_grid_ref_row(&reference, &found) == GHOSTTY_SUCCESS && ghostty_row_get(found, GHOSTTY_ROW_DATA_WRAP, &wraps) == GHOSTTY_SUCCESS && wraps;
    }

    char32_t codepointAt(GhosttyGridRef row, std::uint16_t column) {
      const auto value = cell(row, column);

      return cellHasText(value) ? static_cast<char32_t>(cell_layout::codepoint(value)) : U' ';
    }

    // Whether the row starts as bash reports a job: [<number>], the mark of the current or the
    // previous job or a blank, then two blanks.
    bool jobReportLine(CommandScreen view, std::uint32_t row) {
      // [1]+ and the two blanks.
      constexpr std::uint16_t shortest = 6;
      const auto columns = view.columns;
      const auto reference = gridReference(view.terminal, GHOSTTY_POINT_TAG_SCREEN, {.x = 0, .y = row});
      std::uint16_t column = 1;

      if (columns < shortest || codepointAt(reference, 0) != U'[') {
        return false;
      }

      while (column < columns && codepointAt(reference, column) >= U'0' && codepointAt(reference, column) <= U'9') {
        ++column;
      }

      if (column == 1 || column + 4 > columns || codepointAt(reference, column) != U']') {
        return false;
      }

      const auto mark = codepointAt(reference, column + 1);

      return (mark == U'+' || mark == U'-' || mark == U' ') && codepointAt(reference, column + 2) == U' ' && codepointAt(reference, column + 3) == U' ';
    }

  }

  std::uint32_t CommandBlockRing::reportsAbove(std::uint32_t row, std::uint32_t above, std::uint32_t floor) const {
    const auto view = screen();

    for (; above != 0 && row > floor; --above) {
      // The first row of the line that ends just above `row`.
      auto first = row - 1;

      while (first > floor && wrapped(view.terminal, first - 1)) {
        --first;
      }

      if (!jobReportLine(view, first)) {
        break;
      }

      row = first;
    }

    return row;
  }

  ds::Option<CommandBlockRing::TrackedReference> CommandBlockRing::trackScreen(std::uint32_t row) {
    TrackedReference tracked;
    const GhosttyPoint point{.tag = GHOSTTY_POINT_TAG_SCREEN, .value = {.coordinate = {.x = 0, .y = row}}};
    if (ghostty_terminal_grid_ref_track(screen().terminal, point, tracked.output()) != GHOSTTY_SUCCESS) {
      return ds::none;
    }

    return tracked;
  }

  ds::Option<std::uint32_t> CommandBlockRing::outputRow(const Entry& block, ds::Option<std::uint32_t> first) const {
    if (!first) {
      return ds::none;
    }

    if (block.state == CommandBlockState::background) {
      return first;
    }

    const auto output = row(block.output);
    if (!output || *output <= *first) {
      return ds::none;
    }

    return *output;
  }

  void CommandBlockRing::cover(std::uint32_t row) {
    while (count_ != 0) {
      auto& newest = entryMut(count_ - 1);
      if (newest.restored) {
        return;
      }

      const auto first = this->row(newest.anchor);
      const auto output = outputRow(newest, first);
      if (output && *output <= row && *first < row) {
        return;
      }

      newest = Entry{};
      --count_;
      ++revision_;
    }
  }

  // The command never ran: its block goes, and the prompt it was typed at, drawn again, is the
  // next block's.
  void CommandBlockRing::takeBack() {
    running_ = false;
    if (count_ != 0 && entry(count_ - 1).state == CommandBlockState::running) {
      auto& newest = entryMut(count_ - 1);

      prompt_ = std::move(newest.anchor);
      newest = Entry{};
      --count_;
      ++revision_;
    }

    latest_ = std::move(previous_);
    previous_.reset();
    ++command_revision_;
  }

  // The row `tracked` is on, from the top of the scrollback; nothing once it was dropped.
  ds::Option<std::uint32_t> CommandBlockRing::row(const TrackedReference& tracked) const {
    if (tracked.get() == nullptr) {
      return ds::none;
    }

    auto reference = ghosttySized<GhosttyGridRef>();
    if (ghostty_tracked_grid_ref_snapshot(tracked.get(), &reference) != GHOSTTY_SUCCESS) {
      return ds::none;
    }

    GhosttyPointCoordinate coordinate{};
    if (ghostty_terminal_point_from_grid_ref(screen().terminal, &reference, GHOSTTY_POINT_TAG_SCREEN, &coordinate) != GHOSTTY_SUCCESS) {
      return ds::none;
    }

    return coordinate.y;
  }

  // The command starts: its block takes the rows from its prompt down to the output.
  void CommandBlockRing::start(std::chrono::steady_clock::time_point now, const CommandPlace& place) {
    auto prompt = std::exchange(prompt_, ds::none);
    if (!prompt || !CommandSelection::primary(screen())) {
      return;
    }

    const auto first = row(*prompt);
    auto output = track();
    const auto last = output ? row(*output) : ds::none;
    if (!first || !last || *last <= *first) {
      return;
    }

    cover(*first);

    TELAR_TRACE("history.captureSelection");
    const auto selection = selection_.select(screen());
    if (!selection || !capture(*selection)) {
      return;
    }

    const auto bytes = captured();
    auto text = textView(bytes);

    while (text.ends_with('\n')) {
      text.remove_suffix(1);
    }

    const auto line = text.substr(0, text.find('\n'));
    if (line.find_first_not_of(' ') == std::string_view::npos) {
      return;
    }

    const auto lines = static_cast<std::size_t>(std::ranges::count(text, '\n'));
    // Display text: control bytes the grid may hold become blanks.
    ds::Array<char, command_bytes> clean{};
    const auto kept = utf8Prefix(line, command_bytes);

    std::ranges::transform(kept, clean.viewMut().begin(), [](char byte) {
      return printable(byte) ? byte : ' ';
    });

    const auto clean_size = kept.size();

    if (count_ == capacity) {
      first_ = (first_ + 1) % capacity;
      --count_;
    }

    auto& added = entryMut(count_++);

    added.anchor = std::move(prompt.getMut());
    added.output = std::move(output.getMut());
    added.row = *first;
    added.rows = static_cast<std::uint16_t>(std::min<std::uint32_t>(*last - *first, std::numeric_limits<std::uint16_t>::max()));
    added.lines = static_cast<std::uint16_t>(std::min<std::size_t>(lines, std::numeric_limits<std::uint16_t>::max()));
    added.cut = kept.size() < line.size();
    added.state = CommandBlockState::running;
    added.nest = nested_ ? CommandBlockNest::inside : CommandBlockNest::none;
    added.status = 0;
    added.duration_ms = 0;
    added.started = now;
    added.started_ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    auto& where = added.place.emplace(memory_);

    where.directory.assign(displayed(place.directory, max_block_directory_bytes));
    where.host.assign(displayed(place.host, max_block_host_bytes));
    where.user.assign(displayed(place.user, max_block_user_bytes));
    where.branch.assign(displayed(place.branch, max_branch_bytes));
    added.command.assign({clean.data(), clean_size});
    running_ = true;
    ++revision_;

    previous_ = latest_;
    auto& latest = latest_.emplace();

    latest.truncated = added.lines != 0 || added.cut;
    latest.started = now;
    latest.command.assign({clean.data(), clean_size});
    ++command_revision_;
  }

  void CommandBlockRing::finish(CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now) {
    running_ = false;
    // A prompt drawn over the running block's rows dropped it; the newest is an older one.
    if (count_ != 0 && entry(count_ - 1).state == CommandBlockState::running) {
      end(entryMut(count_ - 1), state, status, now);
    }

    settle(state, status, now);
  }

  // Ends the block whose ssh hosted the session that just closed; at most one is open.
  void CommandBlockRing::closeSession(CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now) {
    closing_ = false;
    for (auto index = count_; index > 0; --index) {
      if (auto& current = entryMut(index - 1); current.state == CommandBlockState::session) {
        end(current, state, status, now);

        // The ssh is the command the pane's own shell just finished, after any its session ran.
        auto& latest = latest_.emplace();

        latest.state = current.state;
        latest.status = current.status;
        latest.duration_ms = current.duration_ms;
        latest.truncated = current.lines != 0 || current.cut;
        latest.started = current.started;
        latest.command.assign(current.command.view());
        ++command_revision_;
        return;
      }
    }

    // The scrollback dropped the ssh's block: the command still running is that ssh.
    settle(state, status, now);
  }

  void CommandBlockRing::end(Entry& block, CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now) {
    block.state = state;
    block.status = status;
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - block.started).count();

    block.duration_ms = static_cast<std::uint32_t>(std::clamp<std::int64_t>(elapsed, 0, std::numeric_limits<std::uint32_t>::max()));
    ++revision_;
  }

  void CommandBlockRing::settle(CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now) {
    if (!latest_ || latest_->state != CommandBlockState::running) {
      return;
    }

    auto& latest = latest_.getMut();
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - latest.started).count();

    latest.state = state;
    latest.status = status;
    latest.duration_ms = static_cast<std::uint32_t>(std::clamp<std::int64_t>(elapsed, 0, std::numeric_limits<std::uint32_t>::max()));
    ++command_revision_;
  }

  // CommandTrackerCore

  // Hears the completions the shell's marks report, for the command that runs.
  // Hears the marks in `bytes` as they are scanned: a mark that ends the running command ends
  // its output there, and what follows is the next prompt's.
  class CommandTrackerCore::CompletionRelay final : public CommandZoneSink {
  public:
    CompletionRelay(tbc::mut_a<CommandTrackerCore> tracker, tbc::mut_a<CapturedCommandEmitter> emitter, tbc::val_a<std::span<const Byte>> bytes, bool committed) noexcept
        : tracker_(tracker),
          emitter_(emitter),
          bytes_(bytes),
          committed_(committed) {}

    void complete(CommandCompletion completion) override;

    void mark(CommandMark mark) override {
      mark_end_ = mark.end;
      // The command starts here: what the line editor drew as it gave the line up (its last
      // redraw, the bracketed paste's end) is the shell's, not the command's output.
      if (mark.action == 'C') {
        tracker_.output_.clear();
        tracker_.marks_.reset();
        tracker_.output_ended_ = false;
        appended_ = std::max(appended_, mark.end);
      }

      // The command's output ends here; what the shell prints until its end mark is not the
      // command's.
      if (mark.action == 'E' && tracker_.phase_ == Phase::running && !tracker_.output_ended_) {
        if (mark.end > appended_) {
          tracker_.appendOutput(bytes_.subspan(appended_, mark.end - appended_));
          appended_ = mark.end;
        }

        tracker_.output_ended_ = true;
      }

      // The line editor took the command back before it ran: there is nothing to record. A
      // prompt drawn before the newline that started the command is the one it was typed at.
      if (mark.action == 'B' && tracker_.phase_ == Phase::running && !committed_) {
        tracker_.reset();
      }
    }

    // The bytes the output has not taken yet.
    [[nodiscard]] std::span<const Byte> rest() const noexcept {
      return bytes_.subspan(appended_);
    }

  private:
    tbc::mut_a<CommandTrackerCore> tracker_;
    tbc::mut_a<CapturedCommandEmitter> emitter_;
    tbc::val_a<std::span<const Byte>> bytes_;
    std::size_t appended_ = 0;
    std::size_t mark_end_ = 0;
    bool committed_ = false;
  };

  void CommandTrackerCore::CompletionRelay::complete(CommandCompletion completion) {
    if (tracker_.phase_ == Phase::running) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(tracker_.metrics_.auxiliary_completions));
      if (mark_end_ > appended_) {
        tracker_.appendOutput(bytes_.subspan(appended_, mark_end_ - appended_));
        appended_ = mark_end_;
      }

      tracker_.complete(completion, emitter_);
    }
  }

  CommandTrackerCore::CommandTrackerCore(ConcurrentMemory& memory, GhosttyTerminal terminal, std::string_view directory, ds::Option<ShellToken> shell_token)
      : selection_(terminal),
        zones_(memory, directory, shell_token) {}

  std::size_t CommandTrackerCore::input(const CommandByteObservation& observation, CapturedCommandEmitter& emitter) {
    TELAR_TRACE("history.captureInput");
    const bool shell_foreground = observation.shell_foreground.valueOr(zones_.editing());

    zones_.input(observation.bytes);
    if (observation.bytes.empty()) {
      return 0;
    }

    if (!shell_foreground || !CommandSelection::primary(screen())) {
      clearSubmitted();
      return 0;
    }

    if (phase_ == Phase::running) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.next_input_completions));
      auto finished = observation.time;

      if (last_output_ns_ >= started_.nanoseconds) {
        finished.nanoseconds = last_output_ns_;
      }

      complete({.time = finished, .exit_code = ds::none, .status = HistoryStatus::completed}, emitter);
    }

    if (phase_ == Phase::awaiting_commit) {
      return observation.bytes.size();
    }

    if (phase_ == Phase::idle) {
      selection_.begin(screen());
      input_.reset();
      phase_ = Phase::editing;
    }

    const auto event = input_.feed(observation.bytes);
    if (event.cancelled) {
      clearSubmitted();
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

  void CommandTrackerCore::output(CommandByteObservation observation, CapturedCommandEmitter& emitter) {
    TELAR_TRACE("history.captureOutput");
    while (!observation.bytes.empty()) {
      const auto boundary = phase_ == Phase::awaiting_commit ? std::ranges::find(observation.bytes, '\n') : observation.bytes.end();
      const bool committed = boundary != observation.bytes.end();
      const auto count = committed ? static_cast<std::size_t>(boundary - observation.bytes.begin()) + 1 : observation.bytes.size();
      const auto part = observation.bytes.first(count);

      feedTerminal(part);
      if (committed) {
        commit(emitter);
      }

      afterOutput({.bytes = part, .time = observation.time, .shell_foreground = observation.shell_foreground}, emitter, committed);
      observation.bytes = observation.bytes.subspan(count);
    }
  }

  void CommandTrackerCore::commit(CapturedCommandEmitter& emitter) {
    ds::Option<bool> taken{false};

    if (!adoptSubmitted()) {
      TELAR_TRACE("history.captureSelection");
      const auto selection = selection_.select(screen());

      taken = selection ? capture(*selection) : ds::none;
    }

    if (!taken) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.capture_failures));
      reset();
      return;
    }

    TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.captures));
    truncated_ = *taken;
    phase_ = Phase::running;
    // The history keeps it from now, running, so a long one shows while it runs and a crash
    // does not lose it.
    if (!command().empty()) {
      emitter.start(captured());
    }
  }

  CapturedCommand CommandTrackerCore::captured() const noexcept {
    return {
        .command = textView(command()),
        .directory = command_directory_.view(),
        .host = zones_.remote() ? zones_.remoteHost() : std::string_view{},
        .started = started_,
        .status = HistoryStatus::running,
        .truncated = truncated_,
    };
  }

  void CommandTrackerCore::complete(CommandCompletion completion, CapturedCommandEmitter& emitter) {
    if (phase_ == Phase::running) {
      const auto output = output_.bytes(outputStorage());

      if (!command().empty()) {
        auto finished = captured();

        finished.duration_ns = std::max<std::int64_t>(0, completion.time.nanoseconds - started_.nanoseconds);
        finished.exit_code = completion.exit_code;
        finished.status = completion.status;
        finished.output = output;
        finished.output_observed = output_.observed();
        emitter.emit(finished);
      }
    }

    reset();
  }

  void CommandTrackerCore::appendOutput(std::span<const Byte> bytes) noexcept {
    if (output_ended_) {
      return;
    }

    marks_.feed(bytes, [&](std::span<const std::uint8_t> kept) {
      output_.append(outputStorage(), kept);
    });
  }

  void CommandTrackerCore::reset() noexcept {
    phase_ = Phase::idle;
    clearCommand();
    input_.reset();
    output_.clear();
    marks_.reset();
    truncated_ = false;
    output_ended_ = false;
    saw_foreground_child_ = false;
  }

  void CommandTrackerCore::resetObservation() {
    TELAR_DIAGNOSTIC(metrics_.merge(zones_.takeMetrics()));
    clearSubmitted();
    reset();
    zones_.restart();
  }

  void CommandTrackerCore::updateDirectory(std::string_view directory) {
    zones_.setDirectory(directory);
  }

  std::string_view CommandTrackerCore::directory() const noexcept {
    return zones_.directory();
  }

  bool CommandTrackerCore::markersReady() const noexcept {
    return zones_.markersReady();
  }

  bool CommandTrackerCore::needsForegroundObservation() const noexcept {
    return phase_ == Phase::awaiting_commit || phase_ == Phase::running;
  }

#if TELAR_DIAGNOSTICS
  diagnostics::CommandCaptureCounters CommandTrackerCore::takeMetrics() noexcept {
    auto result = std::exchange(metrics_, {});

    result.merge(zones_.takeMetrics());
    return result;
  }
#endif

  void CommandTrackerCore::afterOutput(const CommandByteObservation& observation, CapturedCommandEmitter& emitter, bool committed) {
    last_output_ns_ = observation.time.nanoseconds;
    if ((phase_ == Phase::editing || phase_ == Phase::awaiting_commit) && !CommandSelection::primary(screen())) {
      reset();
    }

    if (phase_ == Phase::editing) {
      selection_.rebase(screen(), input_.typedText());
    }

    CompletionRelay relay{*this, emitter, observation.bytes, committed};

    zones_.scan(observation.bytes, observation.time, relay);
    if (phase_ == Phase::running) {
      appendOutput(relay.rest());
    }

    if (phase_ != Phase::running || !observation.shell_foreground) {
      return;
    }

    if (!*observation.shell_foreground) {
      saw_foreground_child_ = true;
    } else if (saw_foreground_child_) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.foreground_completions));
      complete({.time = observation.time, .exit_code = ds::none, .status = HistoryStatus::completed}, emitter);
    }
  }

  template <Allocator Memory>
  CommandOutputTail<Memory>::CommandOutputTail(Memory& memory, bool enabled)
      : bytes_(memory) {
    if (enabled) {
      enable();
    }
  }

  template <Allocator Memory>
  void CommandOutputTail<Memory>::enable() {
    bytes_.resize(CommandOutputWindow::storage_bytes);
  }

  template <Allocator Memory>
  void CommandOutputTail<Memory>::append(std::span<const std::uint8_t> bytes) noexcept {
    window_.append(bytes_.viewMut(), bytes);
  }

  template <Allocator Memory>
  std::span<const std::uint8_t> CommandOutputTail<Memory>::bytes() noexcept {
    return window_.bytes(bytes_.viewMut());
  }

  template <Allocator Memory>
  std::uint64_t CommandOutputTail<Memory>::observed() const noexcept {
    return window_.observed();
  }

  template <Allocator Memory>
  void CommandOutputTail<Memory>::clear() noexcept {
    window_.clear();
  }

  template class CommandOutputTail<ConcurrentMemory>;

  CommandScreen commandScreen(const Terminal& terminal) noexcept {
    return {.terminal = terminal.handle(), .columns = terminal.screen().cols};
  }

  ds::Option<bool> captureCommandText(const Terminal& terminal, const GhosttySelection& selection, ds::Vec<Byte, ConcurrentMemory>& destination) {
    destination.resize(CommandSelection::buffer_bytes);
    CommandTextWriter writer{destination.viewMut()};

    formatTerminalSelection(terminal, selection, true, TrailingSpaces::trimmed, writer.ghostty());
    const auto captured = writer.finish();

    destination.resize(writer.length());
    return captured;
  }

  CommandBlocks::CommandBlocks(ConcurrentMemory& memory, Terminal& terminal)
      : CommandBlockRing(memory, terminal.handle()),
        terminal_(terminal),
        text_(memory) {}

  CommandScreen CommandBlocks::screen() const noexcept {
    return commandScreen(terminal_);
  }

  ds::Option<bool> CommandBlocks::capture(const GhosttySelection& selection) {
    return captureCommandText(terminal_, selection, text_);
  }

  std::span<const Byte> CommandBlocks::captured() const noexcept {
    return text_;
  }

  CommandTracker::CommandTracker(ConcurrentMemory& memory, Terminal& terminal, std::string_view directory, bool capture_output, ds::Option<ShellToken> shell_token)
      : CommandTrackerCore(memory, terminal.handle(), directory, shell_token),
        terminal_(terminal),
        output_(memory),
        command_(memory),
        submitted_(memory) {
    if (capture_output) {
      enableOutputCapture();
    }
  }

  void CommandTracker::enableOutputCapture() {
    output_.resize(CommandOutputWindow::storage_bytes);
  }

  void CommandTracker::submitCommand(std::span<const Byte> text) {
    submitted_.clear();
    submitted_.extend({text.begin(), text.end()});
  }

  CommandScreen CommandTracker::screen() const noexcept {
    return commandScreen(terminal_);
  }

  void CommandTracker::feedTerminal(std::span<const Byte> bytes) {
    terminal_.feed(bytes);
    terminal_.discardResponses();
  }

  ds::Option<bool> CommandTracker::capture(const GhosttySelection& selection) {
    return captureCommandText(terminal_, selection, command_);
  }

  std::span<const Byte> CommandTracker::command() const noexcept {
    return command_;
  }

  void CommandTracker::clearCommand() noexcept {
    command_.clear();
  }

  bool CommandTracker::adoptSubmitted() noexcept { // NOLINT(bugprone-exception-escape): both Vecs draw from the tracker's one memory, so the swap hands storage over without allocating
    if (submitted_.empty()) {
      return false;
    }

    std::swap(command_, submitted_);
    submitted_.clear();
    return true;
  }

  void CommandTracker::clearSubmitted() noexcept {
    submitted_.clear();
  }

  std::span<std::uint8_t> CommandTracker::outputStorage() noexcept {
    return output_.viewMut();
  }

}
