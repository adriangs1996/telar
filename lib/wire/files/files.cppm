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
      // The bytes of a file one message carries, from one machine to another through a window.
      static constexpr std::uint32_t chunk_bytes = std::uint32_t{256} * 1024;
      // The touches one answer carries, and the verb of one: the name of a program or a tool.
      static constexpr std::uint8_t maximum_touches = 128;
      static constexpr std::size_t verb_bytes = 32;
      // The places of an explorer a runtime keeps for the next window, and the bytes their texts
      // take together.
      static constexpr std::uint8_t maximum_places = 84;
      static constexpr std::size_t places_bytes = std::size_t{64} * 1024;
      // The windows an explorer that stands as a pane splits into.
      static constexpr std::uint8_t explorer_windows = 3;
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
    struct DirectoryContents {
      std::uint64_t request_id{};
      std::string_view path;
      std::uint32_t skip{};
      std::uint32_t total{};
      std::span<const DirectoryEntry> entries;
    };

    template <>
    struct MessageSchema<DirectoryContents>
        : Schema<
              Direction::server,
              ServerTag::directory_contents,
              Field<&DirectoryContents::request_id, NonzeroU64, "request_id">,
              Field<&DirectoryContents::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&DirectoryContents::skip, u32, "skip">,
              Field<&DirectoryContents::total, u32, "total">,
              Field<&DirectoryContents::entries, CountedSpan<u16, ValueCodec<DirectoryEntry>, FileLimits::maximum_entries>, "entries">> {};

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
      // A symbolic link at `target` that says `source`, which is the link's text and no path the
      // runtime reads: it is written as it is, and not followed.
      link = 8,
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
              Field<&FileOperation::kind, EnumByte<FileOperationKind, static_cast<Byte>(FileOperationKind::link)>, "kind">,
              Field<&FileOperation::source, Text16<FileLimits::path_bytes>, "source">,
              Field<&FileOperation::target, Text16<FileLimits::path_bytes>, "target">,
              Field<&FileOperation::identity, ValueCodec<FileIdentity>, "identity">> {};

    // Applies the operations in order, each on its own: one that fails leaves the others to run.
    // Where a target exists, `overwrite` sends what was there to the trash; without it the runtime
    // picks a free name beside it. What it does is the change undo takes back; with `joins` it
    // is part of the change before it, and both go back together.
    struct ChangeFiles {
      std::uint64_t request_id{};
      bool overwrite{};
      std::span<const FileOperation> operations;
      bool joins{};
    };

    template <>
    struct MessageSchema<ChangeFiles>
        : Schema<
              Direction::client,
              ClientTag::change_files,
              Field<&ChangeFiles::request_id, NonzeroU64, "request_id">,
              Field<&ChangeFiles::overwrite, BoolByte, "overwrite">,
              Field<&ChangeFiles::operations, CountedSpan<u8, ValueCodec<FileOperation>, FileLimits::maximum_operations, 1>, "operations">,
              Field<&ChangeFiles::joins, BoolByte, "joins">> {};

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

    // Asks where the home of the runtime's account is: what `~` stands for on its machine.
    struct LocateHome {
      std::uint64_t request_id{};
    };

    template <>
    struct MessageSchema<LocateHome> : Schema<Direction::client, ClientTag::locate_home, Field<&LocateHome::request_id, NonzeroU64, "request_id">> {};

    // The home of the runtime's account; empty when its environment names none.
    struct HomeLocated {
      std::uint64_t request_id{};
      std::string_view path;
    };

    template <>
    struct MessageSchema<HomeLocated>
        : Schema<Direction::server, ServerTag::home_located, Field<&HomeLocated::request_id, NonzeroU64, "request_id">, Field<&HomeLocated::path, Text16<FileLimits::path_bytes, true>, "path">> {};

    // Reads the bytes of the file at `path` from `offset`, `limit` of them at most and never more
    // than a chunk, while it still is the file `identity` names: one that was written since is
    // refused, so a file read in several chunks arrives as one file or not at all. A link is
    // not followed: with `link`, the path is one, and what it says is what is read, whole.
    struct ReadFile {
      std::uint64_t request_id{};
      std::string_view path;
      FileIdentity identity{};
      std::uint64_t offset{};
      std::uint32_t limit{};
      bool link{};
    };

    template <>
    struct MessageSchema<ReadFile>
        : Schema<
              Direction::client,
              ClientTag::read_file,
              Field<&ReadFile::request_id, NonzeroU64, "request_id">,
              Field<&ReadFile::path, Text16<FileLimits::path_bytes>, "path">,
              Field<&ReadFile::identity, ValueCodec<FileIdentity>, "identity">,
              Field<&ReadFile::offset, u64, "offset">,
              Field<&ReadFile::limit, u32, "limit">,
              Field<&ReadFile::link, BoolByte, "link">> {};

    // The bytes read at `offset` of a file `size` bytes long; `end` once they reach its end.
    struct FileChunk {
      std::uint64_t request_id{};
      std::uint64_t offset{};
      std::uint64_t size{};
      bool end{};
      std::span<const Byte> bytes;
    };

    template <>
    struct MessageSchema<FileChunk>
        : Schema<
              Direction::server,
              ServerTag::file_chunk,
              Field<&FileChunk::request_id, NonzeroU64, "request_id">,
              Field<&FileChunk::offset, u64, "offset">,
              Field<&FileChunk::size, u64, "size">,
              Field<&FileChunk::end, BoolByte, "end">,
              Field<&FileChunk::bytes, SizedBytes<u32, FileLimits::chunk_bytes>, "bytes">> {};

    // Writes bytes of a file that is arriving, which will be `target`. The first chunk names no
    // `partial`: the runtime makes one beside the target, under a name of its own that no listing
    // takes for the file, and answers it; with `parents` it first makes the directories the
    // target is in. A later chunk names that partial and the `offset` it goes at, which must be
    // where the partial ends. Nothing that exists is written over, and no link is followed.
    struct WriteFile {
      std::uint64_t request_id{};
      std::string_view target;
      std::string_view partial;
      std::uint64_t offset{};
      bool parents{};
      std::span<const Byte> bytes;
    };

    template <>
    struct MessageSchema<WriteFile>
        : Schema<
              Direction::client,
              ClientTag::write_file,
              Field<&WriteFile::request_id, NonzeroU64, "request_id">,
              Field<&WriteFile::target, Text16<FileLimits::path_bytes>, "target">,
              Field<&WriteFile::partial, Text16<FileLimits::path_bytes, true>, "partial">,
              Field<&WriteFile::offset, u64, "offset">,
              Field<&WriteFile::parents, BoolByte, "parents">,
              Field<&WriteFile::bytes, SizedBytes<u32, FileLimits::chunk_bytes>, "bytes">> {};

    // The partial the bytes went to, and how long it is now.
    struct FileWritten {
      std::uint64_t request_id{};
      std::string_view partial;
      std::uint64_t size{};
    };

    template <>
    struct MessageSchema<FileWritten>
        : Schema<Direction::server, ServerTag::file_written, Field<&FileWritten::request_id, NonzeroU64, "request_id">, Field<&FileWritten::partial, Text16<FileLimits::path_bytes>, "partial">, Field<&FileWritten::size, u64, "size">> {};

    // Ends a file that was arriving. With `keep` the partial takes the name `target`: where one
    // exists it takes another name beside it, or with `overwrite` what was there goes to the
    // trash first. Without `keep` the partial is removed, as when the transfer was cancelled or
    // its source failed. A file kept is a change undo takes back: one of its own, or with
    // `joins` part of the change before it.
    struct EndFileWrite {
      std::uint64_t request_id{};
      std::string_view partial;
      std::string_view target;
      bool keep{};
      bool overwrite{};
      bool joins{};
    };

    template <>
    struct MessageSchema<EndFileWrite>
        : Schema<
              Direction::client,
              ClientTag::end_file_write,
              Field<&EndFileWrite::request_id, NonzeroU64, "request_id">,
              Field<&EndFileWrite::partial, Text16<FileLimits::path_bytes>, "partial">,
              Field<&EndFileWrite::target, Text16<FileLimits::path_bytes>, "target">,
              Field<&EndFileWrite::keep, BoolByte, "keep">,
              Field<&EndFileWrite::overwrite, BoolByte, "overwrite">,
              Field<&EndFileWrite::joins, BoolByte, "joins">> {};

    // What became of the partial: `done` with the path the file has, `renamed` when that is
    // another name beside the target; of one removed, `done` and no path.
    struct FileWriteEnded {
      std::uint64_t request_id{};
      FileOutcome outcome{};
      std::string_view path;
    };

    template <>
    struct MessageSchema<FileWriteEnded>
        : Schema<
              Direction::server,
              ServerTag::file_write_ended,
              Field<&FileWriteEnded::request_id, NonzeroU64, "request_id">,
              Field<&FileWriteEnded::outcome, EnumByte<FileOutcome, static_cast<Byte>(FileOutcome::failed)>, "outcome">,
              Field<&FileWriteEnded::path, Text16<FileLimits::path_bytes, true>, "path">> {};

    // Who a touch is by: the person at the pane, or the agent it runs.
    enum class TouchActor : Byte {
      user = 0,
      agent = 1,
    };

    // Asks who touched the files below a directory lately.
    struct QueryTouches {
      std::uint64_t request_id{};
      std::string_view path;
    };

    template <>
    struct MessageSchema<QueryTouches>
        : Schema<Direction::client, ClientTag::query_touches, Field<&QueryTouches::request_id, NonzeroU64, "request_id">, Field<&QueryTouches::path, Text16<FileLimits::path_bytes, false>, "path">> {};

    // A file a pane touched: with which command or tool, and when. `provider` says whose agent,
    // where the runtime knows; `unknown` for the person at the pane and for an agent's own shell.
    struct FileTouch {
      std::string_view path;
      TouchActor actor{};
      AgentProvider provider{};
      std::uint64_t pane_id{};
      std::string_view verb;
      std::uint64_t seconds{};
      // What the file weighed when the runtime looked it up.
      std::uint64_t size{};
    };

    template <>
    struct BodySchema<FileTouch>
        : Serializer<
              Field<&FileTouch::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&FileTouch::actor, EnumByte<TouchActor, static_cast<Byte>(TouchActor::agent)>, "actor">,
              Field<&FileTouch::provider, EnumByte<AgentProvider, max_agent_provider_index>, "provider">,
              Field<&FileTouch::pane_id, u64, "pane_id">,
              Field<&FileTouch::verb, Text16<FileLimits::verb_bytes, false>, "verb">,
              Field<&FileTouch::seconds, u64, "seconds">,
              Field<&FileTouch::size, u64, "size">> {};

    // The touches below `path`, the newest first; `truncated` when there are more than these.
    struct FileTouches {
      std::uint64_t request_id{};
      std::string_view path;
      bool truncated{};
      std::span<const FileTouch> touches;
    };

    template <>
    struct MessageSchema<FileTouches>
        : Schema<
              Direction::server,
              ServerTag::file_touches,
              Field<&FileTouches::request_id, NonzeroU64, "request_id">,
              Field<&FileTouches::path, Text16<FileLimits::path_bytes, false>, "path">,
              Field<&FileTouches::truncated, BoolByte, "truncated">,
              Field<&FileTouches::touches, CountedSpan<u8, ValueCodec<FileTouch>, FileLimits::maximum_touches>, "touches">> {};

    // A place the explorer of a window was: a mark, with its letter, or a step of its jump list,
    // with 0. `machine` is the label the window knows the place's machine by, and empty for the
    // machine of the runtime that keeps it.
    struct KeptPlace {
      Byte letter{};
      std::string_view machine;
      std::string_view root;
      std::string_view selected;
    };

    template <>
    struct BodySchema<KeptPlace>
        : Serializer<
              Field<&KeptPlace::letter, u8, "letter">,
              Field<&KeptPlace::machine, Text16<FileLimits::name_bytes>, "machine">,
              Field<&KeptPlace::root, Text16<FileLimits::path_bytes, false>, "root">,
              Field<&KeptPlace::selected, Text16<FileLimits::path_bytes>, "selected">> {};

    // Gives the runtime the marks and the jump list of a window's explorer, to keep for the window
    // that comes after it: the marks first, then the steps from the oldest, and `jump` the step
    // the explorer is at. It answers nothing, and what it gives replaces what was kept.
    struct KeepPlaces {
      std::span<const KeptPlace> places;
      std::uint16_t jump{};
    };

    template <>
    struct MessageSchema<KeepPlaces>
        : Schema<Direction::client, ClientTag::keep_places, Field<&KeepPlaces::places, CountedSpan<u8, ValueCodec<KeptPlace>, FileLimits::maximum_places>, "places">, Field<&KeepPlaces::jump, u16, "jump">> {};

    // Asks for the places the runtime keeps.
    struct QueryPlaces {
      std::uint64_t request_id{};
    };

    template <>
    struct MessageSchema<QueryPlaces> : Schema<Direction::client, ClientTag::query_places, Field<&QueryPlaces::request_id, NonzeroU64, "request_id">> {};

    // The places it keeps, as the last window gave them; none when no window gave any.
    struct PlacesKept {
      std::uint64_t request_id{};
      std::span<const KeptPlace> places;
      std::uint16_t jump{};
    };

    template <>
    struct MessageSchema<PlacesKept>
        : Schema<
              Direction::server,
              ServerTag::places_kept,
              Field<&PlacesKept::request_id, NonzeroU64, "request_id">,
              Field<&PlacesKept::places, CountedSpan<u8, ValueCodec<KeptPlace>, FileLimits::maximum_places>, "places">,
              Field<&PlacesKept::jump, u16, "jump">> {};

    // What a window of the explorer lists: the tree below its root, what git says changed, the
    // files the panes touched lately, or the panes.
    enum class ExplorerLens : Byte {
      tree = 0,
      changes = 1,
      touched = 2,
      panes = 3,
    };

    // What orders the rows of a window.
    enum class ExplorerSort : Byte {
      name = 0,
      size = 1,
      modified = 2,
    };

    // Where a window that follows the focused pane roots itself: at the pane's directory, at the
    // workspace's, or at the home of the machine.
    enum class ExplorerScope : Byte {
      pane = 0,
      workspace = 1,
      machine = 2,
    };

    // A window of an explorer that stands as a pane, as the runtime keeps it: where it is and how
    // it lists. `machine` is the label the window knows its machine by, and empty for the machine
    // of the runtime that keeps it.
    struct ExplorerWindow {
      std::string_view machine;
      std::string_view root;
      std::string_view selected;
      ExplorerLens lens{};
      ExplorerSort sort{};
      ExplorerScope scope{};
      // Whether it follows the focused pane, and whether it lists the hidden and the ignored.
      bool follow{};
      bool hidden{};
      bool ignored{};
    };

    template <>
    struct BodySchema<ExplorerWindow>
        : Serializer<
              Field<&ExplorerWindow::machine, Text16<FileLimits::name_bytes>, "machine">,
              Field<&ExplorerWindow::root, Text16<FileLimits::path_bytes>, "root">,
              Field<&ExplorerWindow::selected, Text16<FileLimits::path_bytes>, "selected">,
              Field<&ExplorerWindow::lens, EnumByte<ExplorerLens, std::to_underlying(ExplorerLens::panes)>, "lens">,
              Field<&ExplorerWindow::sort, EnumByte<ExplorerSort, std::to_underlying(ExplorerSort::modified)>, "sort">,
              Field<&ExplorerWindow::scope, EnumByte<ExplorerScope, std::to_underlying(ExplorerScope::machine)>, "scope">,
              Field<&ExplorerWindow::follow, BoolByte, "follow">,
              Field<&ExplorerWindow::hidden, BoolByte, "hidden">,
              Field<&ExplorerWindow::ignored, BoolByte, "ignored">> {};

    // The windows of an explorer that stands as a pane: which has the keys, and whether they
    // stand side by side or one over another.
    struct ExplorerLayout {
      std::span<const ExplorerWindow> windows;
      std::uint8_t current{};
      bool side_by_side{};
    };

    template <>
    struct BodySchema<ExplorerLayout>
        : Serializer<
              Field<&ExplorerLayout::windows, CountedSpan<u8, ValueCodec<ExplorerWindow>, FileLimits::explorer_windows>, "windows">,
              Field<&ExplorerLayout::current, u8, "current">,
              Field<&ExplorerLayout::side_by_side, BoolByte, "side_by_side">> {};

    // Asks for a pane that is the explorer in a tab, with the windows `layout` gives it. It runs
    // no program. The runtime answers PaneOpened, after a PaneKindNotice that says what it is.
    struct CreateExplorerPane {
      std::uint64_t request_id{};
      TabLocation location{};
      TerminalSize size{};
      ExplorerLayout layout;
    };

    template <>
    struct MessageSchema<CreateExplorerPane>
        : Schema<
              Direction::client,
              ClientTag::create_explorer_pane,
              Field<&CreateExplorerPane::request_id, NonzeroU64, "request_id">,
              Field<&CreateExplorerPane::location, ValueCodec<TabLocation>, "location">,
              Field<&CreateExplorerPane::size, ValueCodec<TerminalSize>, "size">,
              Field<&CreateExplorerPane::layout, ValueCodec<ExplorerLayout>, "layout">> {};

    // Gives the runtime the windows of an explorer pane as they are now, to keep with the pane:
    // a window that attaches later, and a session that is restored, find them. It answers
    // nothing; a pane of another kind refuses it.
    struct KeepExplorer {
      std::uint64_t pane_id{};
      ExplorerLayout layout;
    };

    template <>
    struct MessageSchema<KeepExplorer> : Schema<Direction::client, ClientTag::keep_explorer, Field<&KeepExplorer::pane_id, NonzeroU64, "pane_id">, Field<&KeepExplorer::layout, ValueCodec<ExplorerLayout>, "layout">> {};

    // The windows the runtime keeps of an explorer pane, sent after the PaneKindNotice that says
    // the pane is one.
    struct ExplorerKept {
      std::uint64_t pane_id{};
      ExplorerLayout layout;
    };

    template <>
    struct MessageSchema<ExplorerKept> : Schema<Direction::server, ServerTag::explorer_kept, Field<&ExplorerKept::pane_id, NonzeroU64, "pane_id">, Field<&ExplorerKept::layout, ValueCodec<ExplorerLayout>, "layout">> {};

  }
}
// NOLINTEND(misc-use-internal-linkage)
