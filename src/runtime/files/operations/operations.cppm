export module telar.runtime.files.operations;

import std;

import telar.runtime.transport.connection;
import telar.wire.files;
import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::runtime {

  // The name beside `path` an operation takes when `path` exists: `name-1.ext`, then `name-2.ext`.
  // `attempt` counts from one.
  void besideName(ds::String<ConcurrentMemory>& candidate, std::string_view path, unsigned attempt);

  // Changes the files of the machine as a client's plan says, and takes its last changes back.
  // Nothing it does removes a file for good: what a change replaces or deletes goes to the trash
  // of the account, which is how it is taken back. It runs on a worker's thread.
  class FileChanger {
  public:
    static constexpr auto git_time = std::chrono::seconds{30};
    // The names an operation tries beside a target that exists.
    static constexpr unsigned beside_attempts = 99;

    explicit FileChanger(ConcurrentMemory& memory);

    // Applies the operations of `request` in order and sends its FilesChanged. An operation that
    // fails leaves the ones after it to run; once `cancelled` is set, the rest fail.
    void change(const ChangeFiles& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply);

    // Takes back what the last `change` did, its last step first, and sends its FilesChanged. A
    // step whose result was changed since is left alone and says so.
    void undo(const UndoFileChanges& request, EncodedReply<ConcurrentMemory>& reply);

    // Commits what the index holds and sends its ChangesCommitted. Throws RequestError when git
    // refuses.
    void commit(const CommitChanges& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply);

    // Takes bytes of a file that arrives from another machine and sends its FileWritten. The
    // first chunk makes the partial, beside the target and under a name of the runtime's own; a
    // later one goes at the end of the partial it names. Throws RequestError for a target that
    // is no plain absolute path, a partial that is not one of this target, and an offset that is
    // not where the partial ends.
    void write(const WriteFile& request, EncodedReply<ConcurrentMemory>& reply);

    // Ends a file that arrived and sends its FileWriteEnded: the partial takes the target's
    // name, as a new file of the last change, which `undo` takes back with it; or it is removed.
    void end(const EndFileWrite& request, EncodedReply<ConcurrentMemory>& reply);

    // Removes the files that were arriving and that no chunk reached for `idle`: a window that
    // closed, or whose connection ended, ends no transfer itself. Returns how many. Every file
    // that starts to arrive does it for the ones before it.
    std::size_t abandon(std::chrono::milliseconds idle);

  private:
    using Clock = std::chrono::steady_clock;
    using Path = ds::String<ConcurrentMemory>;

    // What a step did, which says how it is taken back.
    enum class Step : std::uint8_t {
      // `first` was created: it goes to the trash.
      created,
      // `first` became `second`: it is renamed back.
      moved,
      // `first`, now at `second` in the trash, is put back.
      trashed,
      // `first` holds what git restored, and `second` in the trash what it held before.
      restored,
    };

    struct Record {
      Step step = Step::created;
      Path first;
      Path second;
      // The inode of what the step left, which taking it back checks.
      std::uint64_t inode = 0;
    };

    struct Applied {
      FileOutcome outcome = FileOutcome::failed;
      Path path;
    };

    [[nodiscard]] Applied apply(const FileOperation& operation, bool overwrite, const std::atomic<bool>& cancelled);
    [[nodiscard]] Applied create(const FileOperation& operation, bool overwrite);
    [[nodiscard]] Applied transfer(const FileOperation& operation, bool overwrite);
    [[nodiscard]] Applied discard(const FileOperation& operation, const std::atomic<bool>& cancelled);
    [[nodiscard]] Applied index(const FileOperation& operation, const std::atomic<bool>& cancelled);
    [[nodiscard]] FileOutcome revert(const Record& record) const;

    // Makes room at `target`, which exists: sends it to the trash when `overwrite`, or picks a
    // free name beside it, which `target` then holds. False when neither could be done.
    [[nodiscard]] bool clear(Path& target, bool overwrite, bool& renamed);
    // Sends `path` to the trash and returns where it is there; nothing when no trash takes it.
    [[nodiscard]] ds::Option<Path> trash(std::string_view path, bool copy) const;
    // Runs the account's git in `directory`; its exit status, or -1 when it could not run.
    [[nodiscard]] int git(std::string_view directory, std::span<const std::string_view> arguments, const std::atomic<bool>& cancelled);
    void remember(Step step, std::string_view first, std::string_view second, std::uint64_t inode);

    // A file that arrives, and when its last chunk did.
    struct Arriving {
      Path partial;
      Clock::time_point touched;
    };

    ConcurrentMemory& memory_;
    // The files that arrive and have not ended.
    ds::Vec<Arriving, ConcurrentMemory> arriving_;
    // What the last change did, in order.
    ds::Vec<Record, ConcurrentMemory> journal_;
    // What git wrote last.
    ds::String<ConcurrentMemory> output_;
  };

}
