export module telar.wire.pane_io;

// Pane lifecycle and I/O: opening and closing panes, input, resizing, frames and
// the state a pane reports.

import std;
import telar.wire.vocabulary;
import telar.base.ds;

export namespace telar {
  using telar::BodySchema;
  using telar::MessageSchema;
  using telar::PaneForeground;
  using telar::PaneFrame;
}

export {
  namespace telar {

    struct OpenPane {
      std::uint64_t request_id{};
      PaneTarget target{};
      TerminalSize size{};
      ds::Option<Launch> launch;
    };

    template <>
    struct MessageSchema<OpenPane>
        : Schema<Direction::client, ClientTag::open_pane, Field<&OpenPane::request_id, NonzeroU64, "request_id">, Field<&OpenPane::target, ValueCodec<PaneTarget>, "target">, Field<&OpenPane::size, ValueCodec<TerminalSize>, "size">, ContextField<&OpenPane::launch, &OpenPane::target, TargetLaunch, "launch">> {};

    // The bytes one message types into a pane, and the text one sends it.
    inline constexpr std::size_t max_pane_input_bytes = 65536;
    inline constexpr std::size_t max_pane_text_bytes = 65536;

    struct PaneInput {
      std::uint64_t pane_id{};
      std::span<const Byte> bytes;
    };

    template <>
    struct MessageSchema<PaneInput> : Schema<Direction::client, ClientTag::pane_input, Field<&PaneInput::pane_id, NonzeroU64, "pane_id">, Field<&PaneInput::bytes, TailBytes<max_pane_input_bytes, 1>, "bytes">> {
    };

    // A command telar's editor runs at the shell's prompt. The runtime types it there, as one
    // paste when the shell asked for bracketed paste and then Enter, and its history keeps this
    // text instead of reading the command back from the screen.
    struct PaneCommand {
      std::uint64_t pane_id{};
      std::span<const Byte> text;
    };

    template <>
    struct MessageSchema<PaneCommand> : Schema<Direction::client, ClientTag::pane_command, Field<&PaneCommand::pane_id, NonzeroU64, "pane_id">, Field<&PaneCommand::text, TailBytes<max_pane_input_bytes, 1>, "text">> {
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
      std::string_view text;
      ds::Option<std::uint64_t> sender;

      void validate() const;
    };

    template <>
    struct MessageSchema<SendPaneText>
        : Schema<Direction::client, ClientTag::send_pane_text, Field<&SendPaneText::request_id, NonzeroU64, "request_id">, Field<&SendPaneText::pane_id, NonzeroU64, "pane_id">, Field<&SendPaneText::pane_generation, u64, "pane_generation">, Field<&SendPaneText::mode, EnumByte<PaneTextMode, 2>, "mode">, Field<&SendPaneText::text, Text32<max_pane_text_bytes>, "text">, Field<&SendPaneText::sender, OptionalValue<NonzeroU64>, "sender">> {};

    // A client's theme as RGB triples. Programs in a pane read the terminal's part (foreground,
    // background, cursor and the 16 ANSI colors) through OSC 4, 10, 11 and 12; `telar pane theme`
    // also gives them the editor colors a telar theme adds. `syntax` holds one color per telar
    // syntax role and `chrome` one per palette role, in the order the GUI's theme declares them;
    // bit N of `syntax_italic` and `syntax_bold` styles syntax role N.
    struct TerminalTheme {
      static constexpr std::size_t syntax_roles = 15;
      static constexpr std::size_t chrome_roles = 16;
      static constexpr std::uint16_t syntax_mask = (1U << syntax_roles) - 1;
      // The 16 ANSI colors, three bytes each.
      static constexpr std::size_t palette_bytes = 48;
      static constexpr ds::Array<std::string_view, syntax_roles> syntax_names{"plain", "keyword", "string", "number", "comment", "constant", "builtin_constant", "builtin", "func", "type", "parameter", "property", "namespace", "operator", "punctuation"};
      static constexpr ds::Array<std::string_view, chrome_roles> chrome_names{"accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"};

      ds::Option<ds::Array<Byte, 3>> foreground;
      ds::Option<ds::Array<Byte, 3>> background;
      ds::Option<ds::Array<Byte, palette_bytes>> palette;
      ds::Option<ds::Array<Byte, 3>> cursor;
      ds::Option<ds::Array<Byte, syntax_roles * 3>> syntax;
      std::uint16_t syntax_italic{};
      std::uint16_t syntax_bold{};
      ds::Option<ds::Array<Byte, chrome_roles * 3>> chrome;

      bool operator==(const TerminalTheme&) const = default;

      // Whether a pane's terminal shows `other` as it shows this: the editor colors stay out of it.
      [[nodiscard]] constexpr bool sameTerminalColors(const TerminalTheme& other) const noexcept {
        return foreground == other.foreground && background == other.background && palette == other.palette && cursor == other.cursor;
      }
    };

    template <>
    struct BodySchema<TerminalTheme>
        : Serializer<
              Field<&TerminalTheme::foreground, OptionalValue<FixedBytes<3>>, "foreground">,
              Field<&TerminalTheme::background, OptionalValue<FixedBytes<3>>, "background">,
              Field<&TerminalTheme::palette, OptionalValue<FixedBytes<TerminalTheme::palette_bytes>>, "palette">,
              Field<&TerminalTheme::cursor, OptionalValue<FixedBytes<3>>, "cursor">,
              Field<&TerminalTheme::syntax, OptionalValue<FixedBytes<TerminalTheme::syntax_roles * 3>>, "syntax">,
              Field<&TerminalTheme::syntax_italic, BoundedInteger<u16, 0, TerminalTheme::syntax_mask>, "syntax_italic">,
              Field<&TerminalTheme::syntax_bold, BoundedInteger<u16, 0, TerminalTheme::syntax_mask>, "syntax_bold">,
              Field<&TerminalTheme::chrome, OptionalValue<FixedBytes<TerminalTheme::chrome_roles * 3>>, "chrome">> {};

    // The theme of the client that sends it, for the panes of the workspaces whose geometry it owns.
    struct ConfigureTerminalColors : TerminalTheme {};

    template <>
    struct MessageSchema<ConfigureTerminalColors> : MessageLayout<Direction::client, ClientTag::configure_terminal_colors, BodySchema<TerminalTheme>> {};

    // Asks for the theme of the client that owns a pane's workspace. Answered by `PaneTheme`.
    struct ReadPaneTheme {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
    };

    template <>
    struct MessageSchema<ReadPaneTheme>
        : Schema<Direction::client, ClientTag::read_pane_theme, Field<&ReadPaneTheme::request_id, NonzeroU64, "request_id">, Field<&ReadPaneTheme::pane_id, NonzeroU64, "pane_id">, Field<&ReadPaneTheme::pane_generation, u64, "pane_generation">> {};

    // No theme when no client owns the pane's workspace.
    struct PaneTheme {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      ds::Option<TerminalTheme> theme;
    };

    template <>
    struct MessageSchema<PaneTheme>
        : Schema<Direction::server, ServerTag::pane_theme, Field<&PaneTheme::request_id, NonzeroU64, "request_id">, Field<&PaneTheme::pane_id, NonzeroU64, "pane_id">, Field<&PaneTheme::theme, OptionalValue<ValueCodec<TerminalTheme>>, "theme">> {};

    struct ConfigurePaneDesktop {
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
      bool visible{};
      bool focused{};
      bool light{};
      bool clipboard{};
      ds::Option<ds::Array<Byte, 3>> foreground;
      ds::Option<ds::Array<Byte, 3>> background;
      ds::Option<ds::Array<Byte, 3>> cursor;
      ds::Option<ds::Array<Byte, TerminalTheme::palette_bytes>> palette;

      void validate() const;

      bool operator==(const ConfigurePaneDesktop&) const = default;
    };

    template <>
    struct MessageSchema<ConfigurePaneDesktop>
        : Schema<Direction::client, ClientTag::configure_pane_desktop, Field<&ConfigurePaneDesktop::pane_id, NonzeroU64, "pane_id">, Field<&ConfigurePaneDesktop::pane_generation, NonzeroU64, "pane_generation">, Field<&ConfigurePaneDesktop::visible, BoolByte, "visible">, Field<&ConfigurePaneDesktop::focused, BoolByte, "focused">, Field<&ConfigurePaneDesktop::light, BoolByte, "light">, Field<&ConfigurePaneDesktop::clipboard, BoolByte, "clipboard">, Field<&ConfigurePaneDesktop::foreground, OptionalValue<FixedBytes<3>>, "foreground">, Field<&ConfigurePaneDesktop::background, OptionalValue<FixedBytes<3>>, "background">, Field<&ConfigurePaneDesktop::cursor, OptionalValue<FixedBytes<3>>, "cursor">, Field<&ConfigurePaneDesktop::palette, OptionalValue<FixedBytes<TerminalTheme::palette_bytes>>, "palette">> {};

    struct VerifyPaneDescent {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
    };

    template <>
    struct MessageSchema<VerifyPaneDescent>
        : Schema<Direction::client, ClientTag::verify_pane_descent, Field<&VerifyPaneDescent::request_id, NonzeroU64, "request_id">, Field<&VerifyPaneDescent::pane_id, NonzeroU64, "pane_id">, Field<&VerifyPaneDescent::pane_generation, u64, "pane_generation">> {};

    // Between a frame at 240 Hz and one at 30 Hz.
    struct ConfigureFrameInterval {
      static constexpr std::uint64_t minimum_interval_ns = std::uint64_t{1'000'000'000} / 240;
      static constexpr std::uint64_t maximum_interval_ns = std::uint64_t{1'000'000'000} / 30;

      std::uint64_t interval_ns{};
    };

    template <>
    struct MessageSchema<ConfigureFrameInterval>
        : Schema<Direction::client, ClientTag::configure_frame_interval, Field<&ConfigureFrameInterval::interval_ns, BoundedInteger<u64, ConfigureFrameInterval::minimum_interval_ns, ConfigureFrameInterval::maximum_interval_ns>, "interval_ns">> {};

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

    // What a pane is, sent before the first message that names a pane that is not a terminal: a
    // client takes a pane it was told nothing about for one.
    struct PaneKindNotice {
      std::uint64_t pane_id{};
      PaneKind kind = PaneKind::terminal;
    };

    template <>
    struct MessageSchema<PaneKindNotice>
        : Schema<Direction::server, ServerTag::pane_kind_notice, Field<&PaneKindNotice::pane_id, NonzeroU64, "pane_id">, Field<&PaneKindNotice::kind, EnumByte<PaneKind, std::to_underlying(PaneKind::explorer), std::to_underlying(PaneKind::terminal)>, "kind">> {};

    // Every live pane, so a client can list the ones it has not opened. Bounded by the runtime's
    // pane capacity.
    inline constexpr std::size_t max_pane_list_entries = 256;

    struct PaneList {
      std::uint64_t revision{};
      std::span<const PaneListEntry> entries;
    };

    template <>
    struct MessageSchema<PaneList>
        : Schema<Direction::server, ServerTag::pane_list, Field<&PaneList::revision, u64, "revision">, SpanCountField<&PaneList::entries, u16, ValueCodec<PaneListEntry>, max_pane_list_entries, "entry_count", 0>, SpanItemsField<&PaneList::entries, ValueCodec<PaneListEntry>, "entries">> {
    };

    struct PaneCwd {
      std::uint64_t pane_id{};
      std::string_view cwd;
    };

    template <>
    struct MessageSchema<PaneCwd> : Schema<Direction::server, ServerTag::pane_cwd, Field<&PaneCwd::pane_id, NonzeroU64, "pane_id">, Field<&PaneCwd::cwd, Text16<max_path_bytes, false>, "cwd">> {};

    template <>
    struct MessageSchema<PaneForeground>
        : Schema<Direction::server, ServerTag::pane_foreground, Field<&PaneForeground::pane_id, NonzeroU64, "pane_id">, Field<&PaneForeground::name, Text16<max_foreground_bytes, false>, "name">> {};

    inline constexpr std::size_t max_pane_title_bytes = 256;

    struct PaneTitle {
      std::uint64_t pane_id{};
      std::string_view title;
    };

    template <>
    struct MessageSchema<PaneTitle> : Schema<Direction::server, ServerTag::pane_title, Field<&PaneTitle::pane_id, NonzeroU64, "pane_id">, Field<&PaneTitle::title, Text16<max_pane_title_bytes>, "title">> {};

    struct PaneProgress {
      std::uint64_t pane_id{};
      PaneProgressState state{};
      ds::Option<Byte> percent;

      void validate() const;
    };

    template <>
    struct MessageSchema<PaneProgress>
        : Schema<Direction::server, ServerTag::pane_progress, Field<&PaneProgress::pane_id, NonzeroU64, "pane_id">, Field<&PaneProgress::state, EnumByte<PaneProgressState, 4>, "state">, Field<&PaneProgress::percent, PercentSentinel, "percent">> {};

    // What a native command editor needs to decide who gets the keyboard: whether the pane's
    // integrated shell is reading a command, and how the terminal's line discipline is set
    // for the program that is not. The control characters are 0 when disabled.
    // The longest host name DNS allows.
    inline constexpr std::size_t max_host_bytes = 255;

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
      std::string_view host;
      // The round trip to that host, from input reaching its line editor to the echo, in
      // milliseconds; 0 until timed.
      std::uint32_t link_ms = 0;
      // Where the shell works on that host, as it reports it; empty until it does, and when the
      // shell runs on this one.
      std::string_view directory;

      bool operator==(const PaneShell&) const = default;

      void validate() const;
    };

    template <>
    struct MessageSchema<PaneShell>
        : Schema<Direction::server, ServerTag::pane_shell, Field<&PaneShell::pane_id, NonzeroU64, "pane_id">, Field<&PaneShell::shell, EnumByte<IntegratedShell, 3>, "shell">, Field<&PaneShell::phase, EnumByte<ShellPhase, 2>, "phase">, Field<&PaneShell::shell_foreground, BoolByte, "shell_foreground">, Field<&PaneShell::canonical, BoolByte, "canonical">, Field<&PaneShell::echo, BoolByte, "echo">, Field<&PaneShell::signal_keys, BoolByte, "signal_keys">, Field<&PaneShell::interrupt, u8, "interrupt">, Field<&PaneShell::quit, u8, "quit">, Field<&PaneShell::suspend, u8, "suspend">, Field<&PaneShell::end_of_file, u8, "end_of_file">, Field<&PaneShell::commands, u32, "commands">, Field<&PaneShell::status, i32, "status">, Field<&PaneShell::remote, BoolByte, "remote">, Field<&PaneShell::host, DisplayText16<max_host_bytes>, "host">, Field<&PaneShell::link_ms, u32, "link_ms">, Field<&PaneShell::directory, DisplayText16<max_path_bytes>, "directory">> {};

    // The git repository an integrated shell's working directory is in, read by the runtime after
    // each command. Counts the native reader could not establish are flagged unknown.
    inline constexpr std::size_t max_git_branch_bytes = 256;

    struct PaneGit {
      std::uint64_t pane_id{};
      bool repository = false;
      bool detached = false;
      std::string_view branch;
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
        : Schema<Direction::server, ServerTag::pane_git, Field<&PaneGit::pane_id, NonzeroU64, "pane_id">, Field<&PaneGit::repository, BoolByte, "repository">, Field<&PaneGit::detached, BoolByte, "detached">, Field<&PaneGit::branch, DisplayText16<max_git_branch_bytes>, "branch">, Field<&PaneGit::divergence_known, BoolByte, "divergence_known">, Field<&PaneGit::ahead, u32, "ahead">, Field<&PaneGit::behind, u32, "behind">, Field<&PaneGit::changes_known, BoolByte, "changes_known">, Field<&PaneGit::staged, u32, "staged">, Field<&PaneGit::unstaged, u32, "unstaged">, Field<&PaneGit::conflicted, u32, "conflicted">> {};

    // The command a pane's integrated shell runs or last ran, where the pane works and the
    // repository there: what a client lists beside a pane it has not opened. Sent for every live
    // pane to the clients that take the pane list, after the list that names the pane and again
    // whenever one of these changes. Since cqp00013.
    inline constexpr std::size_t max_pane_command_bytes = 160;
    // The directory is labelled as the agent snapshot labels an agent's.
    inline constexpr std::size_t max_pane_directory_bytes = max_cwd_label_bytes;
    inline constexpr std::size_t max_pane_branch_bytes = 96;
    inline constexpr std::size_t max_pane_document_bytes = max_pane_command_bytes;

    struct PaneFacts {
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
      PaneCommandState command_state = PaneCommandState::none;
      // The command's first line, cut to max_pane_command_bytes; `command_truncated` says it had more.
      std::string_view command;
      bool command_truncated = false;
      // The status a finished command exited with; none while it runs and when the shell never
      // reported one, as for a command its prompt interrupted.
      ds::Option<std::int32_t> exit_code;
      // How long a finished command ran; 0 otherwise.
      std::uint32_t duration_ms = 0;
      // The pane's working directory, the user's home shown as `~`, cut to max_pane_directory_bytes.
      std::string_view directory;
      // Whether that directory is the pane's workspace's, or lies in it.
      bool in_workspace = false;
      // The branch of the repository the integrated shell works in, cut to max_pane_branch_bytes;
      // empty outside a repository and for a pane without an integrated shell.
      std::string_view branch;
      // That repository has staged, unstaged or conflicted changes.
      bool dirty = false;
      // What an editor pane titles itself: the file its focused window shows, and a mark while it
      // has unwritten changes. Cut to max_pane_document_bytes; empty for every other pane.
      std::string_view document;

      void validate() const;
    };

    template <>
    struct MessageSchema<PaneFacts>
        : Schema<Direction::server, ServerTag::pane_facts, Field<&PaneFacts::pane_id, NonzeroU64, "pane_id">, Field<&PaneFacts::pane_generation, NonzeroU64, "pane_generation">, Field<&PaneFacts::command_state, EnumByte<PaneCommandState, 2>, "command_state">, Field<&PaneFacts::command, DisplayText16<max_pane_command_bytes>, "command">, Field<&PaneFacts::command_truncated, BoolByte, "command_truncated">, Field<&PaneFacts::exit_code, OptionalValue<i32>, "exit_code">, Field<&PaneFacts::duration_ms, u32, "duration_ms">, Field<&PaneFacts::directory, DisplayText16<max_pane_directory_bytes>, "directory">, Field<&PaneFacts::in_workspace, BoolByte, "in_workspace">, Field<&PaneFacts::branch, DisplayText16<max_pane_branch_bytes>, "branch">, Field<&PaneFacts::dirty, BoolByte, "dirty">, Field<&PaneFacts::document, DisplayText16<max_pane_document_bytes>, "document">> {};

  } // namespace telar
}
