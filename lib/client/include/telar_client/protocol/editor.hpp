#pragma once

#include "../serializers/telar_messages.hpp"

namespace telar {

  struct SuggestCommand {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::string_view text{};
  };

  template <>
  struct MessageSchema<SuggestCommand>
      : Schema<Direction::client, ClientTag::suggest_command, Field<&SuggestCommand::request_id, NonzeroU64, "request_id">, Field<&SuggestCommand::pane_id, NonzeroU64, "pane_id">, Field<&SuggestCommand::text, Text16<512, false>, "text">> {};

  struct OpenEditor {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    std::string_view editor{};
    std::string_view path{};
    std::uint32_t line{};
    std::uint32_t column{};

    void validate() const {
      if (pane_generation == 0 || editor.empty() || editor.front() == '-' || path.empty() ||
          path.front() != '/' || (column != 0 && line == 0)) {
        throw EncodingError{"Invalid editor target"};
      }
    }
  };

  template <>
  struct MessageSchema<OpenEditor>
      : Schema<Direction::client, ClientTag::open_editor, Field<&OpenEditor::request_id, NonzeroU64, "request_id">, Field<&OpenEditor::pane_id, NonzeroU64, "pane_id">, Field<&OpenEditor::pane_generation, u64, "pane_generation">, Field<&OpenEditor::editor, DisplayText16<4096, false>, "editor">, Field<&OpenEditor::path, DisplayText16<4096, false>, "path">, Field<&OpenEditor::line, u32, "line">, Field<&OpenEditor::column, u32, "column">> {};

  struct FindPaths {
    std::uint64_t request_id{};
    std::string_view root{};
    std::string_view query{};
    PathKindFilter kind{};
    std::uint16_t limit{};
    bool refresh{};

    void validate() const {
      if (root.empty() || root.front() != '/') {
        throw EncodingError{"Invalid path root"};
      }
    }
  };

  template <>
  struct MessageSchema<FindPaths>
      : Schema<Direction::client, ClientTag::find_paths, Field<&FindPaths::request_id, NonzeroU64, "request_id">, Field<&FindPaths::root, Text16<4096, false>, "root">, Field<&FindPaths::query, SizedText<u16, 64, true, TextRule::utf8_no_nul>, "query">, Field<&FindPaths::kind, EnumByte<PathKindFilter, 2>, "kind">, Field<&FindPaths::limit, BoundedInteger<u16, 1, 50>, "limit">, Field<&FindPaths::refresh, BoolByte, "refresh">> {};

  struct CommandSuggestion {
    std::uint64_t request_id{};
    SuggestionStatus status{};
    std::string_view text{};

    void validate() const {
      if (status != SuggestionStatus::ready && !text.empty()) {
        throw EncodingError{"Unexpected suggestion text"};
      }
    }
  };

  template <>
  struct MessageSchema<CommandSuggestion>
      : Schema<Direction::server, ServerTag::command_suggestion, Field<&CommandSuggestion::request_id, NonzeroU64, "request_id">, Field<&CommandSuggestion::status, EnumByte<SuggestionStatus, 3>, "status">, Field<&CommandSuggestion::text, Text16<1024>, "text">> {};

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
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    CompletionProvider provider{};
    std::string_view prefix{};
  };

  template <>
  struct MessageSchema<CompleteWords>
      : Schema<Direction::client, ClientTag::complete_words, Field<&CompleteWords::request_id, NonzeroU64, "request_id">, Field<&CompleteWords::pane_id, NonzeroU64, "pane_id">, Field<&CompleteWords::provider, EnumByte<CompletionProvider, 9>, "provider">, Field<&CompleteWords::prefix, DisplayText16<256>, "prefix">> {};

  struct CompletionWords {
    std::uint64_t request_id{};
    bool truncated{};
    std::span<const CompletionWord> words{};
  };

  template <>
  struct MessageSchema<CompletionWords>
      : Schema<Direction::server, ServerTag::completion_words, Field<&CompletionWords::request_id, NonzeroU64, "request_id">, Field<&CompletionWords::truncated, BoolByte, "truncated">, SpanCountField<&CompletionWords::words, u16, ValueCodec<CompletionWord>, 256, "word_count", 0>, SpanItemsField<&CompletionWords::words, ValueCodec<CompletionWord>, "words">> {};

  // The completion spec of a command, which the runtime holds: the specs telar ships and the
  // ones in the user's completions directory. It answers only for a command the pane's
  // shell runs; with the digest of the spec the client holds, an unchanged one is not sent.
  struct RequestCommandSpec {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::string_view command{};
    std::uint64_t known_digest = 0;
  };

  template <>
  struct MessageSchema<RequestCommandSpec>
      : Schema<Direction::client, ClientTag::request_command_spec, Field<&RequestCommandSpec::request_id, NonzeroU64, "request_id">, Field<&RequestCommandSpec::pane_id, NonzeroU64, "pane_id">, Field<&RequestCommandSpec::command, DisplayText16<64, false>, "command">, Field<&RequestCommandSpec::known_digest, u64, "known_digest">> {};

  enum class CommandSpecState : Byte {
    // `source` is the spec, and `digest` names it.
    available = 0,
    // The spec the client holds, with the digest it sent, still stands.
    unchanged = 1,
    // The shell does not run the command, or no spec describes it.
    unavailable = 2,
  };

  struct CommandSpec {
    static constexpr std::size_t maximum_source = 256 * 1024;

    std::uint64_t request_id{};
    std::string_view command{};
    CommandSpecState state{};
    std::uint64_t digest = 0;
    std::string_view source{};
    // When the command is an alias, the words it stands for: the spec is the first word's,
    // and completion follows the words.
    std::string_view expansion{};

    void validate() const {
      if ((state == CommandSpecState::available) == source.empty()) {
        throw EncodingError{"Command spec source does not match its state"};
      }
    }
  };

  template <>
  struct MessageSchema<CommandSpec>
      : Schema<Direction::server, ServerTag::command_spec, Field<&CommandSpec::request_id, NonzeroU64, "request_id">, Field<&CommandSpec::command, DisplayText16<64, false>, "command">, Field<&CommandSpec::state, EnumByte<CommandSpecState, 2>, "state">, Field<&CommandSpec::digest, u64, "digest">, Field<&CommandSpec::source, SizedText<u32, CommandSpec::maximum_source, true, TextRule::utf8>, "source">, Field<&CommandSpec::expansion, DisplayText16<256>, "expansion">> {};

  struct EditorOpened {
    std::uint64_t request_id{};
    EditorOutcome outcome{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};

    void validate() const {
      if (outcome == EditorOutcome::opened && (pane_id == 0 || pane_generation == 0)) {
        throw EncodingError{"Missing editor pane identity"};
      }
    }
  };

  template <>
  struct MessageSchema<EditorOpened>
      : Schema<Direction::server, ServerTag::editor_opened, Field<&EditorOpened::request_id, NonzeroU64, "request_id">, Field<&EditorOpened::outcome, EnumByte<EditorOutcome, 3>, "outcome">, Field<&EditorOpened::pane_id, u64, "pane_id">, Field<&EditorOpened::pane_generation, u64, "pane_generation">> {};

  struct PathResults {
    std::uint64_t request_id{};
    std::string_view root{};
    std::uint32_t scanned{};
    bool complete{};
    bool truncated{};
    std::span<const PathMatch> matches{};

    void validate() const {
      if (root.empty() || root.front() != '/') {
        throw EncodingError{"Invalid path root"};
      }
    }
  };

  template <>
  struct MessageSchema<PathResults>
      : Schema<
            Direction::server,
            ServerTag::path_results,
            Field<&PathResults::request_id, NonzeroU64, "request_id">,
            Field<&PathResults::root, Text16<4096, false>, "root">,
            Field<&PathResults::scanned, u32, "scanned">,
            Field<&PathResults::complete, BoolByte, "complete">,
            Field<&PathResults::truncated, BoolByte, "truncated">,
            SpanCountField<&PathResults::matches, u16, ValueCodec<PathMatch>, 50, "match_count", 0>,
            SpanItemsField<&PathResults::matches, ValueCodec<PathMatch>, "matches">> {};

} // namespace telar
