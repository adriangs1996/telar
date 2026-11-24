// The files the changes of the clients moved.
export module telar.runtime.files.moves;

import std;

import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::runtime {

  // A file a change moved: where it was, and where it is.
  struct FileMove {
    std::string_view from;
    std::string_view to;
  };

  // The moves the clients asked the files worker for, kept from a request until its answer says
  // which of them were done, so the runtime can tell what shows those files, its editors, where
  // they went. The runtime's thread owns it: the worker answers as it did, and never sees it.
  class FileMoves {
  public:
    // The moves kept, waiting for their answer or for the undo that takes them back. One that
    // finds no room takes the place of the oldest.
    static constexpr std::size_t kept_moves = 256;

    explicit FileMoves(ConcurrentMemory& memory);

    // Keeps what `request` moves. One that does not join the change before it starts a change:
    // an undo no longer takes back what the client moved before.
    void asked(std::uint64_t client, const ChangeFiles& request);

    // Whether an answer may say that something moved.
    [[nodiscard]] bool waiting() const noexcept;

    // How many moves the payload of a client's FilesChanged says were made: those of its
    // ChangeFiles that were done, or with `undone` those its undo took back, from where they
    // had gone. None for a payload that is no FilesChanged.
    [[nodiscard]] std::size_t answered(std::uint64_t client, std::span<const Byte> payload, bool undone);

    // One of the moves the last answer told, until the next call.
    [[nodiscard]] FileMove told(std::size_t index) const noexcept;

  private:
    enum class State : std::uint8_t {
      asked,
      // Done, and told by the call that runs.
      told,
      done,
      undone,
      gone,
    };

    struct Kept {
      explicit Kept(ConcurrentMemory& memory);

      std::uint64_t client = 0;
      // The request whose answer says what became of it.
      std::uint64_t request = 0;
      // Its place among the operations of the request, which is its result's among the answer's.
      std::uint8_t operation = 0;
      State state = State::asked;
      ds::String<ConcurrentMemory> from;
      ds::String<ConcurrentMemory> to;
    };

    // Forgets what was undone or failed, and what the last call told.
    void settle();
    void change(std::uint64_t client, const FilesChanged& answer);
    void undo(std::uint64_t client, const FilesChanged& answer);
    // Lists in `told_` the moves the call that runs made known.
    void tell(State made);

    ConcurrentMemory& memory_;
    // The oldest first.
    ds::Vec<Kept, ConcurrentMemory> kept_;
    // The places in `kept_` of the moves the last answer told.
    ds::Vec<std::uint32_t, ConcurrentMemory> told_;
  };

}
