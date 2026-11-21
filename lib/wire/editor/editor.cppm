export module telar.wire.editor;

// telar's prompt editor: suggestions, completions, command specs, the external
// editor and path search.

import std;
import telar.wire.vocabulary;

// The schemas specialize `MessageSchema`, which telar.wire.vocabulary declares in its global
// fragment; naming the template here keeps it reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

// Declared in the global module, with the vocabulary these schemas build on, so the module's
// implementation unit defines their members there too.
// NOLINTBEGIN(misc-use-internal-linkage): exported, and declared in the global module for editor.cpp.
export extern "C++" {
  namespace telar {

    struct SuggestCommand {
      static constexpr std::size_t maximum_text_bytes = 512;

      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::string_view text;
    };

    template <>
    struct MessageSchema<SuggestCommand>
        : Schema<Direction::client, ClientTag::suggest_command, Field<&SuggestCommand::request_id, NonzeroU64, "request_id">, Field<&SuggestCommand::pane_id, NonzeroU64, "pane_id">, Field<&SuggestCommand::text, Text16<SuggestCommand::maximum_text_bytes, false>, "text">> {};

    struct OpenEditor {
      static constexpr std::size_t maximum_editor_bytes = 4096;
      static constexpr std::size_t maximum_path_bytes = 4096;

      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
      std::string_view editor;
      std::string_view path;
      std::uint32_t line{};
      std::uint32_t column{};

      void validate() const;
    };

    template <>
    struct MessageSchema<OpenEditor>
        : Schema<Direction::client, ClientTag::open_editor, Field<&OpenEditor::request_id, NonzeroU64, "request_id">, Field<&OpenEditor::pane_id, NonzeroU64, "pane_id">, Field<&OpenEditor::pane_generation, u64, "pane_generation">, Field<&OpenEditor::editor, DisplayText16<OpenEditor::maximum_editor_bytes, false>, "editor">, Field<&OpenEditor::path, DisplayText16<OpenEditor::maximum_path_bytes, false>, "path">, Field<&OpenEditor::line, u32, "line">, Field<&OpenEditor::column, u32, "column">> {};

    struct FindPaths {
      static constexpr std::size_t maximum_root_bytes = 4096;
      static constexpr std::size_t maximum_query_bytes = 64;
      static constexpr std::uint16_t maximum_limit = 50;

      std::uint64_t request_id{};
      std::string_view root;
      std::string_view query;
      PathKindFilter kind{};
      std::uint16_t limit{};
      bool refresh{};

      void validate() const;
    };

    template <>
    struct MessageSchema<FindPaths>
        : Schema<Direction::client, ClientTag::find_paths, Field<&FindPaths::request_id, NonzeroU64, "request_id">, Field<&FindPaths::root, Text16<FindPaths::maximum_root_bytes, false>, "root">, Field<&FindPaths::query, SizedText<u16, FindPaths::maximum_query_bytes, true, TextRule::utf8_no_nul>, "query">, Field<&FindPaths::kind, EnumByte<PathKindFilter, 2>, "kind">, Field<&FindPaths::limit, BoundedInteger<u16, 1, FindPaths::maximum_limit>, "limit">, Field<&FindPaths::refresh, BoolByte, "refresh">> {};

    // Searches the text of the files under `root` for `query`, taken as it is written: the
    // files of its repository when it is one, every file otherwise. A new search by the same
    // client ends the one before it.
    struct FindText {
      static constexpr std::size_t maximum_query_bytes = 256;
      static constexpr std::uint16_t maximum_limit = 200;

      std::uint64_t request_id{};
      std::string_view root;
      std::string_view query;
      std::uint16_t limit{};
    };

    template <>
    struct MessageSchema<FindText>
        : Schema<Direction::client, ClientTag::find_text, Field<&FindText::request_id, NonzeroU64, "request_id">, Field<&FindText::root, Text16<FindPaths::maximum_root_bytes, false>, "root">, Field<&FindText::query, SizedText<u16, FindText::maximum_query_bytes, false, TextRule::utf8_no_nul>, "query">, Field<&FindText::limit, BoundedInteger<u16, 1, FindText::maximum_limit>, "limit">> {};

    // A line of a file that matches: its path under the root, the line and the column the match
    // starts at, both counted from one, and the line's text, cut to what a list shows.
    struct TextMatch {
      static constexpr std::size_t maximum_path_bytes = 1024;
      static constexpr std::size_t maximum_text_bytes = 512;

      std::string_view path;
      std::uint32_t line{};
      std::uint32_t column{};
      std::string_view text;
    };

    template <>
    struct BodySchema<TextMatch>
        : Serializer<Field<&TextMatch::path, SizedText<u16, TextMatch::maximum_path_bytes, false, TextRule::opaque>, "path">, Field<&TextMatch::line, u32, "line">, Field<&TextMatch::column, u32, "column">, Field<&TextMatch::text, SizedText<u16, TextMatch::maximum_text_bytes, true, TextRule::opaque>, "text">> {};

    // What FindText found, in the order the search met it. `truncated` says there was more than
    // the limit asked for.
    struct TextResults {
      std::uint64_t request_id{};
      std::string_view root;
      bool truncated{};
      std::span<const TextMatch> matches;
    };

    template <>
    struct MessageSchema<TextResults>
        : Schema<Direction::server, ServerTag::text_results, Field<&TextResults::request_id, NonzeroU64, "request_id">, Field<&TextResults::root, Text16<FindPaths::maximum_root_bytes, false>, "root">, Field<&TextResults::truncated, BoolByte, "truncated">, Field<&TextResults::matches, CountedSpan<u16, ValueCodec<TextMatch>, FindText::maximum_limit>, "matches">> {};

    struct CommandSuggestion {
      static constexpr std::size_t maximum_text_bytes = 1024;

      std::uint64_t request_id{};
      SuggestionStatus status{};
      std::string_view text;

      void validate() const;
    };

    template <>
    struct MessageSchema<CommandSuggestion>
        : Schema<Direction::server, ServerTag::command_suggestion, Field<&CommandSuggestion::request_id, NonzeroU64, "request_id">, Field<&CommandSuggestion::status, EnumByte<SuggestionStatus, 3>, "status">, Field<&CommandSuggestion::text, Text16<CommandSuggestion::maximum_text_bytes>, "text">> {};

    // What a command spec leaves to the runtime: values that live where the shell runs.
    enum class CompletionProvider : Byte {
      command = 0,
      branch = 1,
      ssh_host = 2,
      make_target = 3,
      remote = 4,
      stash = 5,
      process = 6,
      // Read from files in the shell's directory or its parents: a justfile's recipes, the
      // nearest package.json's scripts and a compose file's services.
      just_recipe = 7,
      package_script = 8,
      compose_service = 9,
    };

    // Asks for the values of `provider` that start with `prefix`, for the pane's integrated shell.
    struct CompleteWords {
      static constexpr std::size_t maximum_prefix_bytes = 256;

      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      CompletionProvider provider{};
      std::string_view prefix;
    };

    template <>
    struct MessageSchema<CompleteWords>
        : Schema<Direction::client, ClientTag::complete_words, Field<&CompleteWords::request_id, NonzeroU64, "request_id">, Field<&CompleteWords::pane_id, NonzeroU64, "pane_id">, Field<&CompleteWords::provider, EnumByte<CompletionProvider, std::to_underlying(CompletionProvider::compose_service)>, "provider">, Field<&CompleteWords::prefix, DisplayText16<CompleteWords::maximum_prefix_bytes>, "prefix">> {};

    struct CompletionWords {
      static constexpr std::size_t maximum_words = 256;

      std::uint64_t request_id{};
      bool truncated{};
      std::span<const CompletionWord> words;
    };

    template <>
    struct MessageSchema<CompletionWords>
        : Schema<Direction::server, ServerTag::completion_words, Field<&CompletionWords::request_id, NonzeroU64, "request_id">, Field<&CompletionWords::truncated, BoolByte, "truncated">, SpanCountField<&CompletionWords::words, u16, ValueCodec<CompletionWord>, CompletionWords::maximum_words, "word_count", 0>, SpanItemsField<&CompletionWords::words, ValueCodec<CompletionWord>, "words">> {};

    // The completion spec of a command, which the runtime holds: the specs telar ships and the
    // ones in the user's completions directory. It answers only for a command the pane's
    // shell runs; with the digest of the spec the client holds, an unchanged one is not sent.
    struct RequestCommandSpec {
      static constexpr std::size_t maximum_command_bytes = 64;

      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::string_view command;
      std::uint64_t known_digest = 0;
    };

    template <>
    struct MessageSchema<RequestCommandSpec>
        : Schema<Direction::client, ClientTag::request_command_spec, Field<&RequestCommandSpec::request_id, NonzeroU64, "request_id">, Field<&RequestCommandSpec::pane_id, NonzeroU64, "pane_id">, Field<&RequestCommandSpec::command, DisplayText16<RequestCommandSpec::maximum_command_bytes, false>, "command">, Field<&RequestCommandSpec::known_digest, u64, "known_digest">> {};

    enum class CommandSpecState : Byte {
      // `source` is the spec, and `digest` names it.
      available = 0,
      // The spec the client holds, with the digest it sent, still stands.
      unchanged = 1,
      // The shell does not run the command, or no spec describes it.
      unavailable = 2,
    };

    struct CommandSpec {
      static constexpr std::size_t maximum_source = std::size_t{256} * 1024;
      static constexpr std::size_t maximum_expansion_bytes = 256;

      std::uint64_t request_id{};
      std::string_view command;
      CommandSpecState state{};
      std::uint64_t digest = 0;
      std::string_view source;
      // When the command is an alias, the words it stands for: the spec is the first word's,
      // and completion follows the words.
      std::string_view expansion;

      void validate() const;
    };

    template <>
    struct MessageSchema<CommandSpec>
        : Schema<Direction::server, ServerTag::command_spec, Field<&CommandSpec::request_id, NonzeroU64, "request_id">, Field<&CommandSpec::command, DisplayText16<RequestCommandSpec::maximum_command_bytes, false>, "command">, Field<&CommandSpec::state, EnumByte<CommandSpecState, 2>, "state">, Field<&CommandSpec::digest, u64, "digest">, Field<&CommandSpec::source, SizedText<u32, CommandSpec::maximum_source, true, TextRule::utf8>, "source">, Field<&CommandSpec::expansion, DisplayText16<CommandSpec::maximum_expansion_bytes>, "expansion">> {};

    struct EditorOpened {
      std::uint64_t request_id{};
      EditorOutcome outcome{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};

      void validate() const;
    };

    template <>
    struct MessageSchema<EditorOpened>
        : Schema<Direction::server, ServerTag::editor_opened, Field<&EditorOpened::request_id, NonzeroU64, "request_id">, Field<&EditorOpened::outcome, EnumByte<EditorOutcome, 3>, "outcome">, Field<&EditorOpened::pane_id, u64, "pane_id">, Field<&EditorOpened::pane_generation, u64, "pane_generation">> {};

    struct PathResults {
      std::uint64_t request_id{};
      std::string_view root;
      std::uint32_t scanned{};
      bool complete{};
      bool truncated{};
      std::span<const PathMatch> matches;

      void validate() const;
    };

    template <>
    struct MessageSchema<PathResults>
        : Schema<
              Direction::server,
              ServerTag::path_results,
              Field<&PathResults::request_id, NonzeroU64, "request_id">,
              Field<&PathResults::root, Text16<FindPaths::maximum_root_bytes, false>, "root">,
              Field<&PathResults::scanned, u32, "scanned">,
              Field<&PathResults::complete, BoolByte, "complete">,
              Field<&PathResults::truncated, BoolByte, "truncated">,
              SpanCountField<&PathResults::matches, u16, ValueCodec<PathMatch>, FindPaths::maximum_limit, "match_count", 0>,
              SpanItemsField<&PathResults::matches, ValueCodec<PathMatch>, "matches">> {};

  }
}
// NOLINTEND(misc-use-internal-linkage)
