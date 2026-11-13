#pragma once

#include "../serializers/telar_frame.hpp"
#include "../serializers/telar_messages.hpp"

namespace telar {

  struct OpenPane {
    std::uint64_t request_id{};
    PaneTarget target{};
    TerminalSize size{};
    std::optional<Launch> launch{};
  };

  template <>
  struct MessageSchema<OpenPane>
      : Schema<Direction::client, ClientTag::open_pane, Field<&OpenPane::request_id, NonzeroU64, "request_id">, Field<&OpenPane::target, ValueCodec<PaneTarget>, "target">, Field<&OpenPane::size, ValueCodec<TerminalSize>, "size">, ContextField<&OpenPane::launch, &OpenPane::target, TargetLaunch, "launch">> {};

  struct PaneInput {
    std::uint64_t pane_id{};
    std::span<const Byte> bytes{};
  };

  template <>
  struct MessageSchema<PaneInput> : Schema<Direction::client, ClientTag::pane_input, Field<&PaneInput::pane_id, NonzeroU64, "pane_id">, Field<&PaneInput::bytes, TailBytes<65536, 1>, "bytes">> {
  };

  // A command telar's editor runs at the shell's prompt. The runtime types it there, as one
  // paste when the shell asked for bracketed paste and then Enter, and its history keeps this
  // text instead of reading the command back from the screen.
  struct PaneCommand {
    std::uint64_t pane_id{};
    std::span<const Byte> text{};
  };

  template <>
  struct MessageSchema<PaneCommand> : Schema<Direction::client, ClientTag::pane_command, Field<&PaneCommand::pane_id, NonzeroU64, "pane_id">, Field<&PaneCommand::text, TailBytes<65536, 1>, "text">> {
  };

  // Whether this client draws telar's editor in place of the shell's prompt. The shells of the
  // panes it opens from now on print no prompt of their own, only the marks telar reads.
  struct ConfigureShellPrompt {
    bool bare{};
  };

  template <>
  struct MessageSchema<ConfigureShellPrompt> : Schema<Direction::client, ClientTag::configure_shell_prompt, Field<&ConfigureShellPrompt::bare, BoolByte, "bare">> {
  };

  struct PaneResize {
    std::uint64_t pane_id{};
    TerminalSize size{};
  };

  template <>
  struct MessageSchema<PaneResize>
      : Schema<Direction::client, ClientTag::pane_resize, Field<&PaneResize::pane_id, NonzeroU64, "pane_id">, Field<&PaneResize::size, ValueCodec<TerminalSize>, "size">> {};

  template <>
  struct MessageSchema<PaneFrame>
      : MessageLayout<Direction::server, ServerTag::pane_frame, BodySchema<FrameBody>> {};

  struct FrameAck {
    std::uint64_t pane_id{};
    std::uint64_t frame_id{};
  };

  template <>
  struct MessageSchema<FrameAck> : Schema<Direction::client, ClientTag::frame_ack, Field<&FrameAck::pane_id, NonzeroU64, "pane_id">, Field<&FrameAck::frame_id, u64, "frame_id">> {};

  struct RequestSnapshot {
    std::uint64_t pane_id{};
    std::uint64_t known_frame_id{};
  };

  template <>
  struct MessageSchema<RequestSnapshot>
      : Schema<Direction::client, ClientTag::request_snapshot, Field<&RequestSnapshot::pane_id, NonzeroU64, "pane_id">, Field<&RequestSnapshot::known_frame_id, u64, "known_frame_id">> {};

  struct DetachPane {
    std::uint64_t pane_id{};
  };

  template <>
  struct MessageSchema<DetachPane> : Schema<Direction::client, ClientTag::detach_pane, Field<&DetachPane::pane_id, NonzeroU64, "pane_id">> {};

  struct CreatePane {
    std::uint64_t request_id{};
    TabLocation location{};
    TerminalSize size{};
    Launch launch{};
  };

  template <>
  struct MessageSchema<CreatePane>
      : Schema<Direction::client, ClientTag::create_pane, Field<&CreatePane::request_id, NonzeroU64, "request_id">, Field<&CreatePane::location, ValueCodec<TabLocation>, "location">, Field<&CreatePane::size, ValueCodec<TerminalSize>, "size">, Field<&CreatePane::launch, ValueCodec<Launch>, "launch">> {};

  struct ClosePane {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
  };

  template <>
  struct MessageSchema<ClosePane> : Schema<Direction::client, ClientTag::close_pane, Field<&ClosePane::request_id, NonzeroU64, "request_id">, Field<&ClosePane::pane_id, NonzeroU64, "pane_id">> {};

  struct SetPaneViewport {
    std::uint64_t pane_id{};
    std::uint32_t offset{};
  };

  template <>
  struct MessageSchema<SetPaneViewport>
      : Schema<Direction::client, ClientTag::set_pane_viewport, Field<&SetPaneViewport::pane_id, NonzeroU64, "pane_id">, Field<&SetPaneViewport::offset, u32, "offset">> {};

  struct SendPaneText {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    PaneTextMode mode{};
    std::string_view text{};
    std::optional<std::uint64_t> sender{};

    void validate() const {
      if (text.empty() && mode != PaneTextMode::raw_enter) {
        throw EncodingError{"Empty pane text"};
      }
    }
  };

  template <>
  struct MessageSchema<SendPaneText>
      : Schema<Direction::client, ClientTag::send_pane_text, Field<&SendPaneText::request_id, NonzeroU64, "request_id">, Field<&SendPaneText::pane_id, NonzeroU64, "pane_id">, Field<&SendPaneText::pane_generation, u64, "pane_generation">, Field<&SendPaneText::mode, EnumByte<PaneTextMode, 2>, "mode">, Field<&SendPaneText::text, Text32<65536>, "text">, Field<&SendPaneText::sender, OptionalValue<NonzeroU64>, "sender">> {};

  struct ConfigureTerminalColors {
    std::optional<std::array<Byte, 3>> foreground{};
    std::optional<std::array<Byte, 3>> background{};
    std::optional<std::array<Byte, 48>> palette{};
  };

  template <>
  struct MessageSchema<ConfigureTerminalColors>
      : Schema<
            Direction::client,
            ClientTag::configure_terminal_colors,
            Field<&ConfigureTerminalColors::foreground, OptionalValue<FixedBytes<3>>, "foreground">,
            Field<&ConfigureTerminalColors::background, OptionalValue<FixedBytes<3>>, "background">,
            Field<&ConfigureTerminalColors::palette, OptionalValue<FixedBytes<48>>, "palette">> {};

  struct ConfigurePaneDesktop {
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    bool visible{};
    bool focused{};
    bool light{};
    bool clipboard{};
    std::optional<std::array<Byte, 3>> foreground{};
    std::optional<std::array<Byte, 3>> background{};
    std::optional<std::array<Byte, 3>> cursor{};
    std::optional<std::array<Byte, 48>> palette{};

    void validate() const {
      if (focused && !visible) {
        throw EncodingError{"A focused pane must be visible"};
      }
    }

    bool operator==(const ConfigurePaneDesktop&) const = default;
  };

  template <>
  struct MessageSchema<ConfigurePaneDesktop>
      : Schema<Direction::client, ClientTag::configure_pane_desktop, Field<&ConfigurePaneDesktop::pane_id, NonzeroU64, "pane_id">, Field<&ConfigurePaneDesktop::pane_generation, NonzeroU64, "pane_generation">, Field<&ConfigurePaneDesktop::visible, BoolByte, "visible">, Field<&ConfigurePaneDesktop::focused, BoolByte, "focused">, Field<&ConfigurePaneDesktop::light, BoolByte, "light">, Field<&ConfigurePaneDesktop::clipboard, BoolByte, "clipboard">, Field<&ConfigurePaneDesktop::foreground, OptionalValue<FixedBytes<3>>, "foreground">, Field<&ConfigurePaneDesktop::background, OptionalValue<FixedBytes<3>>, "background">, Field<&ConfigurePaneDesktop::cursor, OptionalValue<FixedBytes<3>>, "cursor">, Field<&ConfigurePaneDesktop::palette, OptionalValue<FixedBytes<48>>, "palette">> {};

  struct VerifyPaneDescent {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
  };

  template <>
  struct MessageSchema<VerifyPaneDescent>
      : Schema<Direction::client, ClientTag::verify_pane_descent, Field<&VerifyPaneDescent::request_id, NonzeroU64, "request_id">, Field<&VerifyPaneDescent::pane_id, NonzeroU64, "pane_id">, Field<&VerifyPaneDescent::pane_generation, u64, "pane_generation">> {};

  struct ConfigureFrameInterval {
    std::uint64_t interval_ns{};
  };

  template <>
  struct MessageSchema<ConfigureFrameInterval>
      : Schema<Direction::client, ClientTag::configure_frame_interval, Field<&ConfigureFrameInterval::interval_ns, BoundedInteger<u64, 1000000000 / 240, 1000000000 / 30>, "interval_ns">> {};

  struct PaneOpened {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    TabLocation location{};
    bool created{};
    std::uint64_t pane_generation{};
  };

  template <>
  struct MessageSchema<PaneOpened>
      : Schema<Direction::server, ServerTag::pane_opened, Field<&PaneOpened::request_id, NonzeroU64, "request_id">, Field<&PaneOpened::pane_id, NonzeroU64, "pane_id">, Field<&PaneOpened::location, ValueCodec<TabLocation>, "location">, Field<&PaneOpened::created, BoolByte, "created">, Field<&PaneOpened::pane_generation, u64, "pane_generation">> {};

  struct PaneExited {
    std::uint64_t pane_id{};
    ExitKind kind{};
    std::uint32_t value{};
  };

  template <>
  struct MessageSchema<PaneExited> : Schema<Direction::server, ServerTag::pane_exited, Field<&PaneExited::pane_id, NonzeroU64, "pane_id">, Field<&PaneExited::kind, EnumByte<ExitKind, 1>, "kind">, Field<&PaneExited::value, u32, "value">> {};

  // Every live pane, so a client can list the ones it has not opened. Bounded by the runtime's
  // pane capacity.
  inline constexpr std::size_t max_pane_list_entries = 256;

  struct PaneList {
    std::uint64_t revision{};
    std::span<const PaneListEntry> entries{};
  };

  template <>
  struct MessageSchema<PaneList>
      : Schema<Direction::server, ServerTag::pane_list, Field<&PaneList::revision, u64, "revision">, SpanCountField<&PaneList::entries, u16, ValueCodec<PaneListEntry>, max_pane_list_entries, "entry_count", 0>, SpanItemsField<&PaneList::entries, ValueCodec<PaneListEntry>, "entries">> {
  };

  struct PaneCwd {
    std::uint64_t pane_id{};
    std::string_view cwd{};
  };

  template <>
  struct MessageSchema<PaneCwd> : Schema<Direction::server, ServerTag::pane_cwd, Field<&PaneCwd::pane_id, NonzeroU64, "pane_id">, Field<&PaneCwd::cwd, Text16<4096, false>, "cwd">> {};

  template <>
  struct MessageSchema<PaneForeground>
      : Schema<Direction::server, ServerTag::pane_foreground, Field<&PaneForeground::pane_id, NonzeroU64, "pane_id">, Field<&PaneForeground::name, Text16<48, false>, "name">> {};

  struct PaneTitle {
    std::uint64_t pane_id{};
    std::string_view title{};
  };

  template <>
  struct MessageSchema<PaneTitle> : Schema<Direction::server, ServerTag::pane_title, Field<&PaneTitle::pane_id, NonzeroU64, "pane_id">, Field<&PaneTitle::title, Text16<256>, "title">> {};

  struct PaneProgress {
    std::uint64_t pane_id{};
    PaneProgressState state{};
    std::optional<Byte> percent{};

    void validate() const {
      if ((state == PaneProgressState::remove || state == PaneProgressState::indeterminate) &&
          percent) {
        throw EncodingError{"Unexpected progress percent"};
      }

      if (state == PaneProgressState::set && !percent) {
        throw EncodingError{"Missing progress percent"};
      }
    }
  };

  template <>
  struct MessageSchema<PaneProgress>
      : Schema<Direction::server, ServerTag::pane_progress, Field<&PaneProgress::pane_id, NonzeroU64, "pane_id">, Field<&PaneProgress::state, EnumByte<PaneProgressState, 4>, "state">, Field<&PaneProgress::percent, PercentSentinel, "percent">> {};

  // What a native command editor needs to decide who gets the keyboard: whether the pane's
  // integrated shell is reading a command, and how the terminal's line discipline is set
  // for the program that is not. The control characters are 0 when disabled.
  struct PaneShell {
    std::uint64_t pane_id{};
    IntegratedShell shell{};
    ShellPhase phase{};
    bool shell_foreground = false;
    bool canonical = false;
    bool echo = false;
    bool signal_keys = false;
    Byte interrupt{};
    Byte quit{};
    Byte suspend{};
    Byte end_of_file{};
    // Counts the commands the shell reported finished, and the last one's exit status.
    std::uint32_t commands = 0;
    std::int32_t status = 0;
    // The shell runs on another host, which `ssh` reached: the line discipline above is the
    // local one ssh set raw, and the files, repositories and PATH are not this host's.
    bool remote = false;
    // The host the shell runs on, as its working directory report names it; empty when
    // the shell runs on this one.
    std::string_view host{};
    // The round trip to that host, from input reaching its line editor to the echo, in
    // milliseconds; 0 until timed.
    std::uint32_t link_ms = 0;
    // Where the shell works on that host, as it reports it; empty until it does, and when the
    // shell runs on this one.
    std::string_view directory{};

    bool operator==(const PaneShell&) const = default;

    void validate() const {
      if (shell == IntegratedShell::none && phase != ShellPhase::unknown) {
        throw EncodingError{"Shell phase without an integrated shell"};
      }
    }
  };

  template <>
  struct MessageSchema<PaneShell>
      : Schema<Direction::server, ServerTag::pane_shell, Field<&PaneShell::pane_id, NonzeroU64, "pane_id">, Field<&PaneShell::shell, EnumByte<IntegratedShell, 3>, "shell">, Field<&PaneShell::phase, EnumByte<ShellPhase, 2>, "phase">, Field<&PaneShell::shell_foreground, BoolByte, "shell_foreground">, Field<&PaneShell::canonical, BoolByte, "canonical">, Field<&PaneShell::echo, BoolByte, "echo">, Field<&PaneShell::signal_keys, BoolByte, "signal_keys">, Field<&PaneShell::interrupt, u8, "interrupt">, Field<&PaneShell::quit, u8, "quit">, Field<&PaneShell::suspend, u8, "suspend">, Field<&PaneShell::end_of_file, u8, "end_of_file">, Field<&PaneShell::commands, u32, "commands">, Field<&PaneShell::status, i32, "status">, Field<&PaneShell::remote, BoolByte, "remote">, Field<&PaneShell::host, DisplayText16<255>, "host">, Field<&PaneShell::link_ms, u32, "link_ms">, Field<&PaneShell::directory, DisplayText16<4096>, "directory">> {};

  // The git repository an integrated shell's working directory is in, read by the runtime after
  // each command. Counts the native reader could not establish are flagged unknown.
  struct PaneGit {
    std::uint64_t pane_id{};
    bool repository = false;
    bool detached = false;
    std::string_view branch{};
    bool divergence_known = false;
    std::uint32_t ahead = 0;
    std::uint32_t behind = 0;
    bool changes_known = false;
    std::uint32_t staged = 0;
    std::uint32_t unstaged = 0;
    std::uint32_t conflicted = 0;

    bool operator==(const PaneGit&) const = default;
  };

  template <>
  struct MessageSchema<PaneGit>
      : Schema<Direction::server, ServerTag::pane_git, Field<&PaneGit::pane_id, NonzeroU64, "pane_id">, Field<&PaneGit::repository, BoolByte, "repository">, Field<&PaneGit::detached, BoolByte, "detached">, Field<&PaneGit::branch, DisplayText16<256>, "branch">, Field<&PaneGit::divergence_known, BoolByte, "divergence_known">, Field<&PaneGit::ahead, u32, "ahead">, Field<&PaneGit::behind, u32, "behind">, Field<&PaneGit::changes_known, BoolByte, "changes_known">, Field<&PaneGit::staged, u32, "staged">, Field<&PaneGit::unstaged, u32, "unstaged">, Field<&PaneGit::conflicted, u32, "conflicted">> {};

} // namespace telar
