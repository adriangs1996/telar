export module telar.runtime.files.repository;

import std;

import telar.runtime.transport.connection;
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

    explicit RepositoryReader(ConcurrentMemory& memory);

    // Sends the RepositoryChanges of the repository `request.path` is in; one with an empty root
    // for a path outside any, or where git does not run.
    void changes(const QueryChanges& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply);

    // Sends the FileInspection of `request.path`. Throws RequestError for a path that is not
    // absolute or does not exist.
    void inspect(const InspectFile& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply);

  private:
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
    bool upstream_ = false;
    std::uint32_t ahead_ = 0;
    std::uint32_t behind_ = 0;
    bool truncated_ = false;
    // The head of the file being inspected, and the diff of its changes.
    ds::Vec<char, ConcurrentMemory> head_;
    ds::Vec<char, ConcurrentMemory> diff_;
  };

}
