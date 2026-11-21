export module telar.runtime.paths.text_search;

import std;

import telar.runtime.transport.connection;
import telar.wire.editor;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::runtime {

  // What a search program wrote of one matching line, read into the places and the text it
  // names. The programs differ only in what stands between the fields: `path NUL line:column:text`
  // from ripgrep, `path NUL line NUL column NUL text` from git.
  struct FileTextLine {
    std::string_view path;
    std::uint32_t line = 0;
    std::uint32_t column = 0;
    std::string_view text;

    // None for a line that is not a match: a path too long to list, or fields that are not numbers.
    [[nodiscard]] static ds::Option<FileTextLine> parse(std::string_view written) noexcept;
  };

  // Searches the text of the files under a directory, with ripgrep where the host has it and
  // with git in a repository where it does not. It runs on a worker's thread: the search is a
  // child process, ended when it found enough, took too long or was cancelled.
  class FileTextSearch {
  public:
    explicit FileTextSearch(ConcurrentMemory& memory);

    // Sends the TextResults of `request`. Throws RequestError for a root that cannot be
    // searched, and when the search was cancelled before it found anything.
    void find(const FindText& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply);

  private:
    // One match kept: where its path and its text are in `text_`.
    struct Found {
      std::uint32_t path = 0;
      std::uint16_t path_size = 0;
      std::uint16_t text_size = 0;
      std::uint32_t line = 0;
      std::uint32_t column = 0;
    };

    // Takes what the program wrote; false once enough was found.
    bool feed(std::span<const Byte> bytes, std::size_t limit);
    void keep(const FileTextLine& line);

    ConcurrentMemory& memory_;
    // The bytes of the line being read, and whether it grew past what a match can be.
    ds::Vec<char, ConcurrentMemory> line_;
    bool oversized_ = false;
    ds::Vec<char, ConcurrentMemory> text_;
    ds::Vec<Found, ConcurrentMemory> found_;
    bool truncated_ = false;
  };

}
