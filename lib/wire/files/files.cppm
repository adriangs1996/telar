export module telar.wire.files;

// The files of a machine as its runtime lists, measures, reads and changes them for the explorer.

import std;
import telar.wire.vocabulary;

// The schemas specialize `BodySchema` and `MessageSchema`, which telar.wire.vocabulary declares in
// its global fragment; naming the templates here keeps them reachable from importers.
export namespace telar {
  using telar::BodySchema;
  using telar::MessageSchema;
}

// Declared in the global module, with the vocabulary these schemas build on.
// NOLINTBEGIN(misc-use-internal-linkage): exported, and declared in the global module as the vocabulary is.
export extern "C++" {
  namespace telar {

    // What an entry of a directory is, without following a link.
    enum class FileKind : Byte {
      file = 0,
      directory = 1,
      link = 2,
      other = 3,
    };

    // What git holds of a path, in its index or in the working tree.
    enum class FileState : Byte {
      unchanged = 0,
      modified = 1,
      added = 2,
      deleted = 3,
      renamed = 4,
      untracked = 5,
      conflicted = 6,
      ignored = 7,
    };

    struct FileLimits {
      static constexpr std::size_t path_bytes = 4096;
      static constexpr std::size_t name_bytes = 255;
      // The entries one listing carries, and the directories one measure names.
      static constexpr std::uint16_t maximum_entries = 512;
      static constexpr std::uint16_t maximum_changes = 1024;
      static constexpr std::uint8_t maximum_operations = 64;
      // An operation over a target that exists answers for both: what was there, and what took its
      // place.
      static constexpr std::uint8_t maximum_results = 2 * maximum_operations;
      static constexpr std::size_t branch_bytes = 256;
      // The head of a file a preview shows, and the diff of its changes not committed.
      static constexpr std::size_t text_bytes = std::size_t{8} * 1024;
      static constexpr std::size_t diff_bytes = std::size_t{24} * 1024;
      static constexpr std::size_t commit_bytes = 40;
      static constexpr std::size_t subject_bytes = 256;
      static constexpr std::size_t message_bytes = 4096;
      // A file's modification time holds this many nanoseconds past its second.
      static constexpr std::uint32_t maximum_nanoseconds = 999'999'999;
    };

    // What tells a file from another that took its name since a listing: its inode and when it was
    // last written. An identity of zeros names whatever has the path now.
    struct FileIdentity {
      std::uint64_t inode{};
      std::uint64_t modified_seconds{};
      std::uint32_t modified_nanoseconds{};

      bool operator==(const FileIdentity&) const noexcept = default;
    };

    template <>
    struct BodySchema<FileIdentity>
        : Serializer<
              Field<&FileIdentity::inode, u64, "inode">,
              Field<&FileIdentity::modified_seconds, u64, "modified_seconds">,
              Field<&FileIdentity::modified_nanoseconds, BoundedInteger<u32, 0, FileLimits::maximum_nanoseconds>, "modified_nanoseconds">> {};

    // Lists one directory, never what is below it: `limit` entries after the first `skip`, the
    // directories first and each group by name.
    struct ListDirectory {
      std::uint64_t request_id{};
      std::string_view path;
      std::uint32_t skip{};
      std::uint16_t limit{};
    };

    template <>
    struct MessageSchema<ListDirectory>
        : Schema<
              Direction::client,
              ClientTag::list_directory,
              Field<&ListDirectory::request_id, NonzeroU64, "request_id">,
              Field<&ListDirectory::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&ListDirectory::skip, u32, "skip">,
              Field<&ListDirectory::limit, BoundedInteger<u16, 1, FileLimits::maximum_entries>, "limit">> {};

    struct DirectoryEntry {
      std::string_view name;
      FileKind kind{};
      // Whether it lists as a directory: one, or a link to one.
      bool directory{};
      // A file's bytes; a directory's are measured apart.
      std::uint64_t size{};
      FileIdentity identity{};
    };

    template <>
    struct BodySchema<DirectoryEntry>
        : Serializer<
              Field<&DirectoryEntry::name, Text16<FileLimits::name_bytes, false>, "name">,
              Field<&DirectoryEntry::kind, EnumByte<FileKind, static_cast<Byte>(FileKind::other)>, "kind">,
              Field<&DirectoryEntry::directory, BoolByte, "directory">,
              Field<&DirectoryEntry::size, u64, "size">,
              Field<&DirectoryEntry::identity, ValueCodec<FileIdentity>, "identity">> {};

    // The entries of `path` from `skip` on, of the `total` it holds.
    struct DirectoryListing {
      std::uint64_t request_id{};
      std::string_view path;
      std::uint32_t skip{};
      std::uint32_t total{};
      std::span<const DirectoryEntry> entries;
    };

    template <>
    struct MessageSchema<DirectoryListing>
        : Schema<
              Direction::server,
              ServerTag::directory_listing,
              Field<&DirectoryListing::request_id, NonzeroU64, "request_id">,
              Field<&DirectoryListing::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&DirectoryListing::skip, u32, "skip">,
              Field<&DirectoryListing::total, u32, "total">,
              Field<&DirectoryListing::entries, CountedSpan<u16, ValueCodec<DirectoryEntry>, FileLimits::maximum_entries>, "entries">> {};

    // Measures what each directory of a listing's page holds, everything below it counted.
    struct MeasureDirectory {
      std::uint64_t request_id{};
      std::string_view path;
      std::uint32_t skip{};
      std::uint16_t limit{};
    };

    template <>
    struct MessageSchema<MeasureDirectory>
        : Schema<
              Direction::client,
              ClientTag::measure_directory,
              Field<&MeasureDirectory::request_id, NonzeroU64, "request_id">,
              Field<&MeasureDirectory::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&MeasureDirectory::skip, u32, "skip">,
              Field<&MeasureDirectory::limit, BoundedInteger<u16, 1, FileLimits::maximum_entries>, "limit">> {};

    // What a directory holds on disk. `complete` is false for one the runtime ran out of time in:
    // it holds at least `bytes`.
    struct DirectorySize {
      std::string_view name;
      std::uint64_t bytes{};
      bool complete{};
    };

    template <>
    struct BodySchema<DirectorySize>
        : Serializer<
              Field<&DirectorySize::name, Text16<FileLimits::name_bytes, false>, "name">,
              Field<&DirectorySize::bytes, u64, "bytes">,
              Field<&DirectorySize::complete, BoolByte, "complete">> {};

    struct DirectorySizes {
      std::uint64_t request_id{};
      std::string_view path;
      std::span<const DirectorySize> sizes;
    };

    template <>
    struct MessageSchema<DirectorySizes>
        : Schema<
              Direction::server,
              ServerTag::directory_sizes,
              Field<&DirectorySizes::request_id, NonzeroU64, "request_id">,
              Field<&DirectorySizes::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&DirectorySizes::sizes, CountedSpan<u16, ValueCodec<DirectorySize>, FileLimits::maximum_entries>, "sizes">> {};

    // Asks what git holds of the repository `path` is in.
    struct QueryChanges {
      std::uint64_t request_id{};
      std::string_view path;
    };

    template <>
    struct MessageSchema<QueryChanges>
        : Schema<Direction::client, ClientTag::query_changes, Field<&QueryChanges::request_id, NonzeroU64, "request_id">, Field<&QueryChanges::path, Text16<FileLimits::path_bytes, false>, "path">> {};

    // A path git says something of, from the repository's top: what its index holds of it, what
    // the working tree does, and the lines its changes add and remove. A directory git ignores or
    // does not track is named once, with a `/` at its end.
    struct FileChange {
      std::string_view path;
      FileState staged{};
      FileState unstaged{};
      std::uint32_t added{};
      std::uint32_t removed{};
    };

    template <>
    struct BodySchema<FileChange>
        : Serializer<
              Field<&FileChange::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&FileChange::staged, EnumByte<FileState, static_cast<Byte>(FileState::ignored)>, "staged">,
              Field<&FileChange::unstaged, EnumByte<FileState, static_cast<Byte>(FileState::ignored)>, "unstaged">,
              Field<&FileChange::added, u32, "added">,
              Field<&FileChange::removed, u32, "removed">> {};

    // The repository of the path asked: `root` is empty outside one. `ahead` and `behind` count
    // against the branch's upstream when it has one.
    struct RepositoryChanges {
      std::uint64_t request_id{};
      std::string_view path;
      std::string_view root;
      std::string_view branch;
      bool upstream{};
      std::uint32_t ahead{};
      std::uint32_t behind{};
      bool truncated{};
      std::span<const FileChange> changes;
    };

    template <>
    struct MessageSchema<RepositoryChanges>
        : Schema<
              Direction::server,
              ServerTag::repository_changes,
              Field<&RepositoryChanges::request_id, NonzeroU64, "request_id">,
              Field<&RepositoryChanges::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&RepositoryChanges::root, Text16<FileLimits::path_bytes>, "root">,
              Field<&RepositoryChanges::branch, Text16<FileLimits::branch_bytes>, "branch">,
              Field<&RepositoryChanges::upstream, BoolByte, "upstream">,
              Field<&RepositoryChanges::ahead, u32, "ahead">,
              Field<&RepositoryChanges::behind, u32, "behind">,
              Field<&RepositoryChanges::truncated, BoolByte, "truncated">,
              Field<&RepositoryChanges::changes, CountedSpan<u16, ValueCodec<FileChange>, FileLimits::maximum_changes>, "changes">> {};

    // Asks for what a preview shows of one path.
    struct InspectFile {
      std::uint64_t request_id{};
      std::string_view path;
    };

    template <>
    struct MessageSchema<InspectFile>
        : Schema<Direction::client, ClientTag::inspect_file, Field<&InspectFile::request_id, NonzeroU64, "request_id">, Field<&InspectFile::path, Text16<FileLimits::path_bytes, false>, "path">> {};

    // A path as a preview shows it: what it is, the head of its text unless it is `binary`, the
    // last commit that changed it, and the diff of what is not committed. `truncated` says the text
    // or the diff was cut.
    struct FileInspection {
      std::uint64_t request_id{};
      std::string_view path;
      FileKind kind{};
      std::uint64_t size{};
      FileIdentity identity{};
      // Where a link points, as it is written.
      std::string_view target;
      bool binary{};
      bool truncated{};
      std::string_view text;
      std::string_view commit;
      std::uint64_t committed_seconds{};
      std::string_view subject;
      std::string_view diff;
    };

    template <>
    struct MessageSchema<FileInspection>
        : Schema<
              Direction::server,
              ServerTag::file_inspection,
              Field<&FileInspection::request_id, NonzeroU64, "request_id">,
              Field<&FileInspection::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&FileInspection::kind, EnumByte<FileKind, static_cast<Byte>(FileKind::other)>, "kind">,
              Field<&FileInspection::size, u64, "size">,
              Field<&FileInspection::identity, ValueCodec<FileIdentity>, "identity">,
              Field<&FileInspection::target, Text16<FileLimits::path_bytes>, "target">,
              Field<&FileInspection::binary, BoolByte, "binary">,
              Field<&FileInspection::truncated, BoolByte, "truncated">,
              Field<&FileInspection::text, SizedText<u16, FileLimits::text_bytes, true, TextRule::utf8>, "text">,
              Field<&FileInspection::commit, DisplayText16<FileLimits::commit_bytes>, "commit">,
              Field<&FileInspection::committed_seconds, u64, "committed_seconds">,
              Field<&FileInspection::subject, Utf8Text16<FileLimits::subject_bytes>, "subject">,
              Field<&FileInspection::diff, SizedText<u16, FileLimits::diff_bytes, true, TextRule::utf8>, "diff">> {};

    enum class FileOperationKind : Byte {
      // An empty file, or a directory, at `target`.
      create_file = 0,
      create_directory = 1,
      // `source` becomes `target`, or a copy of it does.
      move = 2,
      copy = 3,
      // `source` goes to the machine's trash.
      trash = 4,
      // git discards what `source` changed since its commit; the file goes to the trash first.
      restore = 5,
      // git adds `source` to its index, or takes it out.
      stage = 6,
      unstage = 7,
    };

    // One change to the files of the machine. With an identity that is not zeros, the runtime
    // changes `source` only while it still is the file the identity names.
    struct FileOperation {
      FileOperationKind kind{};
      std::string_view source;
      std::string_view target;
      FileIdentity identity{};
    };

    template <>
    struct BodySchema<FileOperation>
        : Serializer<
              Field<&FileOperation::kind, EnumByte<FileOperationKind, static_cast<Byte>(FileOperationKind::unstage)>, "kind">,
              Field<&FileOperation::source, Text16<FileLimits::path_bytes>, "source">,
              Field<&FileOperation::target, Text16<FileLimits::path_bytes>, "target">,
              Field<&FileOperation::identity, ValueCodec<FileIdentity>, "identity">> {};

    // Applies the operations in order, each on its own: one that fails leaves the others to run.
    // Where a target exists, `overwrite` sends what was there to the trash; without it the runtime
    // picks a free name beside it.
    struct ChangeFiles {
      std::uint64_t request_id{};
      bool overwrite{};
      std::span<const FileOperation> operations;
    };

    template <>
    struct MessageSchema<ChangeFiles>
        : Schema<
              Direction::client,
              ClientTag::change_files,
              Field<&ChangeFiles::request_id, NonzeroU64, "request_id">,
              Field<&ChangeFiles::overwrite, BoolByte, "overwrite">,
              Field<&ChangeFiles::operations, CountedSpan<u8, ValueCodec<FileOperation>, FileLimits::maximum_operations, 1>, "operations">> {};

    enum class FileOutcome : Byte {
      done = 0,
      // Done under another name: the target existed.
      renamed = 1,
      // Skipped: the source is not the file its identity names any more.
      stale = 2,
      // Skipped: the source is gone.
      missing = 3,
      // The system refused it.
      refused = 4,
      failed = 5,
    };

    // What became of one operation, and the path its result has.
    struct FileResult {
      FileOutcome outcome{};
      std::string_view path;
    };

    template <>
    struct BodySchema<FileResult>
        : Serializer<Field<&FileResult::outcome, EnumByte<FileOutcome, static_cast<Byte>(FileOutcome::failed)>, "outcome">, Field<&FileResult::path, Text16<FileLimits::path_bytes>, "path">> {};

    // The results of a ChangeFiles, one per operation and in their order, or of an UndoFileChanges,
    // one per step it took back, the last first. `undoable` says the runtime can take these changes
    // back.
    struct FilesChanged {
      std::uint64_t request_id{};
      bool undoable{};
      std::span<const FileResult> results;
    };

    template <>
    struct MessageSchema<FilesChanged>
        : Schema<
              Direction::server,
              ServerTag::files_changed,
              Field<&FilesChanged::request_id, NonzeroU64, "request_id">,
              Field<&FilesChanged::undoable, BoolByte, "undoable">,
              Field<&FilesChanged::results, CountedSpan<u8, ValueCodec<FileResult>, FileLimits::maximum_results>, "results">> {};

    // Takes back the last changes this client applied, where nothing touched their results since.
    struct UndoFileChanges {
      std::uint64_t request_id{};
    };

    template <>
    struct MessageSchema<UndoFileChanges>
        : Schema<Direction::client, ClientTag::undo_file_changes, Field<&UndoFileChanges::request_id, NonzeroU64, "request_id">> {};

    // Commits what the index of the repository of `path` holds.
    struct CommitChanges {
      std::uint64_t request_id{};
      std::string_view path;
      std::string_view message;
    };

    template <>
    struct MessageSchema<CommitChanges>
        : Schema<
              Direction::client,
              ClientTag::commit_changes,
              Field<&CommitChanges::request_id, NonzeroU64, "request_id">,
              Field<&CommitChanges::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&CommitChanges::message, SizedText<u16, FileLimits::message_bytes, false, TextRule::multiline>, "message">> {};

    // The commit git made: its abbreviated name and the first line of its message.
    struct ChangesCommitted {
      std::uint64_t request_id{};
      std::string_view commit;
      std::string_view subject;
    };

    template <>
    struct MessageSchema<ChangesCommitted>
        : Schema<
              Direction::server,
              ServerTag::changes_committed,
              Field<&ChangesCommitted::request_id, NonzeroU64, "request_id">,
              Field<&ChangesCommitted::commit, DisplayText16<FileLimits::commit_bytes>, "commit">,
              Field<&ChangesCommitted::subject, Utf8Text16<FileLimits::subject_bytes>, "subject">> {};

  }
}
// NOLINTEND(misc-use-internal-linkage)
