export module telar.runtime.files.repository;

import std;

import telar.runtime.transport.connection;
import telar.runtime.workspaces.git_status;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::runtime {

  // What a record of `git status --porcelain=v2` says of one path. None for a header, or for a
  // record that names no path.
  struct StatusRecord {
    std::string_view path;
    FileState staged = FileState::unchanged;
    FileState unstaged = FileState::unchanged;

    [[nodiscard]] static ds::Option<StatusRecord> parse(std::string_view record);
  };

  // Reads what git holds of a repository and of one of its paths, with the git the path index
  // runs: hardened, and ended when it takes too long. It runs on a worker's thread.
  class RepositoryReader {
  public:
    static constexpr auto status_time = std::chrono::seconds{10};
    static constexpr auto inspection_time = std::chrono::seconds{5};
    // How long the base found for a commit stands before git is asked again: the base is a
    // branch of a remote, which a fetch moves without the commit changing.
    static constexpr auto base_time = std::chrono::seconds{15};
    // The repositories whose base is kept, the last ones asked about.
    static constexpr std::size_t kept_bases = 4;

    explicit RepositoryReader(ConcurrentMemory& memory);

    // Sends the RepositoryChanges of the repository `request.path` is in; one with an empty root
    // for a path outside any, or where git does not run.
    void changes(const QueryChanges& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply);

    // Sends the FileInspection of `request.path`. Throws RequestError for a path that is not
    // absolute or does not exist.
    void inspect(const InspectFile& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply);

  private:
    using Clock = std::chrono::steady_clock;

    // The base git named for a repository at a commit, kept so that asking again what changed
    // there costs no more git than the status.
    struct Based {
      explicit Based(ConcurrentMemory& memory);

      ds::String<ConcurrentMemory> root;
      ds::String<ConcurrentMemory> commit;
      ds::String<ConcurrentMemory> upstream;
      ds::String<ConcurrentMemory> name;
      std::uint32_t ahead = 0;
      Clock::time_point read;
    };

    // One path kept: where it is in `text_`.
    struct Change {
      std::uint32_t path = 0;
      std::uint16_t path_size = 0;
      FileState staged = FileState::unchanged;
      FileState unstaged = FileState::unchanged;
      std::uint32_t added = 0;
      std::uint32_t removed = 0;
    };

    // Takes what a git command wrote, a record at a time, each ended by a NUL; false once
    // `record` asks for no more.
    template <typename Record>
    bool feed(std::span<const Byte> bytes, const Record& record);
    // Keeps what a status record says; false once the changes are as many as a reply carries.
    bool keep(std::string_view record);
    // Adds the lines a numstat record counts to the change of its path.
    void count(std::string_view record);
    [[nodiscard]] std::string_view pathOf(const Change& change) const;
    // Finds the branch this one is measured against and how far ahead of it the commit is, into
    // `base_` and `ahead_`. What was found for the same commit less than `base_time` ago is
    // taken as it was.
    void measureBase(GitRepository& git);
    // Asks git for them: the branch the remote this one follows, or `origin`, has as its head;
    // and where the remote names none, the branch this one follows. Neither leaves them empty.
    void readBase(GitRepository& git);

    ConcurrentMemory& memory_;
    // The record being read, and whether it grew past what a path can be.
    ds::Vec<char, ConcurrentMemory> record_;
    bool oversized_ = false;
    ds::Vec<char, ConcurrentMemory> text_;
    ds::Vec<Change, ConcurrentMemory> changes_;
    // Where the last numstat record found its path: git writes both lists in the same order.
    std::size_t cursor_ = 0;
    ds::String<ConcurrentMemory> root_;
    ds::String<ConcurrentMemory> branch_;
    // The commit the status was read at, the branch this one follows, and how far ahead of it
    // the status says it is.
    ds::String<ConcurrentMemory> commit_;
    ds::String<ConcurrentMemory> upstream_;
    std::uint32_t unpushed_ = 0;
    ds::String<ConcurrentMemory> base_;
    std::uint32_t ahead_ = 0;
    ds::Vec<Based, ConcurrentMemory> bases_;
    std::size_t next_base_ = 0;
    bool truncated_ = false;
    // The head of the file being inspected, and the diff of its changes.
    ds::Vec<char, ConcurrentMemory> head_;
    ds::Vec<char, ConcurrentMemory> diff_;
  };

}
