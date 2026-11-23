#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.files.content;
import telar.runtime.files.directory;
import telar.runtime.files.operations;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  FileIdentity identityOf(const std::string& path) {
    struct stat status{};

    check(::lstat(path.c_str(), &status) == 0, "the file is there to name");
#ifdef __APPLE__
    const auto& modified = status.st_mtimespec;
#else
    const auto& modified = status.st_mtim;
#endif
    return {.inode = static_cast<std::uint64_t>(status.st_ino), .modified_seconds = static_cast<std::uint64_t>(modified.tv_sec), .modified_nanoseconds = static_cast<std::uint32_t>(modified.tv_nsec)};
  }

  void write(const std::string& path, std::string_view text) {
    std::ofstream{path, std::ios::binary} << text;
  }

  std::string read(const std::string& path) {
    std::ifstream file{path, std::ios::binary};

    return {std::istreambuf_iterator<char>{file}, std::istreambuf_iterator<char>{}};
  }

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the bytes of a text
  }

  template <typename Work>
  bool refused(const Work& work) {
    try {
      work();
    } catch (const RequestError&) {
      return true;
    }

    return false;
  }

  // What one chunk of a file says, read through a reader.
  struct Chunk {
    std::string text;
    std::uint64_t size = 0;
    bool end = false;
  };

  Chunk chunk(FileContent& content, ConcurrentMemory& memory, const ReadFile& request) {
    EncodedReply reply{memory};
    std::vector<Byte> scratch(1024);
    DecodeStorage storage{scratch};

    content.read(request, reply);

    const auto read = Codec::decode<FileChunk>(reply.payload(), storage);

    check(read.request_id == request.request_id && read.offset == request.offset);
    return {.text = std::string{reinterpret_cast<const char*>(read.bytes.data()), read.bytes.size()}, .size = read.size, .end = read.end}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the bytes of a text
  }

  void testAFileIsReadAChunkAtATimeWhileItIsTheOneListed() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const TemporaryDirectory directory{"/tmp/telar-transfer-XXXXXX"};
    const std::string root{directory.path()};
    const auto path = root + "/notes.txt";
    FileContent content{memory};

    write(path, "0123456789");

    const auto listed = identityOf(path);
    const auto first = chunk(content, memory, {.request_id = 1, .path = path, .identity = listed, .offset = 0, .limit = 4});
    const auto last = chunk(content, memory, {.request_id = 2, .path = path, .identity = listed, .offset = 8, .limit = 4});

    check(first.text == "0123" && first.size == 10 && !first.end, "a chunk is as long as was asked, and says how long the file is");
    check(last.text == "89" && last.end, "the last one says the file ends there");
    check(chunk(content, memory, {.request_id = 3, .path = path, .identity = listed, .offset = 10, .limit = 4}).end, "at its end there is nothing more, and that is no failure");
    check(refused([&] {
      static_cast<void>(chunk(content, memory, {.request_id = 4, .path = path, .identity = listed, .offset = 11, .limit = 4}));
    }),
        "past its end is refused");

    // A link is not followed, and a directory is no file.
    std::filesystem::create_symlink(path, root + "/link");
    check(refused([&] {
      static_cast<void>(chunk(content, memory, {.request_id = 5, .path = root + "/link", .identity = {}, .offset = 0, .limit = 4}));
    }),
        "a link is not read through");
    check(refused([&] {
      static_cast<void>(chunk(content, memory, {.request_id = 6, .path = root, .identity = {}, .offset = 0, .limit = 4}));
    }));

    // Written since it was listed: the rest of it does not arrive.
    write(path, "another file, longer");
    std::filesystem::last_write_time(path, std::filesystem::last_write_time(path) + std::chrono::seconds{2});
    check(refused([&] {
      static_cast<void>(chunk(content, memory, {.request_id = 7, .path = path, .identity = listed, .offset = 4, .limit = 4}));
    }),
        "a file that changed is refused, so it never arrives as two halves");
  }

  // What the runtime answers a chunk written, and the end of a file that arrived.
  struct Arrived {
    std::string partial;
    std::uint64_t size = 0;
  };

  Arrived arrive(FileChanger& changer, ConcurrentMemory& memory, const WriteFile& request) {
    EncodedReply reply{memory};
    std::vector<Byte> scratch(8192);
    DecodeStorage storage{scratch};

    changer.write(request, reply);

    const auto written = Codec::decode<FileWritten>(reply.payload(), storage);

    return {.partial = std::string{written.partial}, .size = written.size};
  }

  struct Ended {
    FileOutcome outcome = FileOutcome::failed;
    std::string path;
  };

  Ended finish(FileChanger& changer, ConcurrentMemory& memory, const EndFileWrite& request) {
    EncodedReply reply{memory};
    std::vector<Byte> scratch(8192);
    DecodeStorage storage{scratch};

    changer.end(request, reply);

    const auto ended = Codec::decode<FileWriteEnded>(reply.payload(), storage);

    return {.outcome = ended.outcome, .path = std::string{ended.path}};
  }

  void testAFileArrivesUnderANameOfItsOwnAndThenTakesItsTarget() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const TemporaryDirectory directory{"/tmp/telar-transfer-XXXXXX"};
    const std::string root{directory.path()};
    const auto target = root + "/in/deep/report.txt";
    FileChanger changer{memory};

    check(refused([&] {
      static_cast<void>(arrive(changer, memory, {.request_id = 1, .target = target, .offset = 0, .bytes = bytes("ab")}));
    }),
        "without the directories it goes in, and not asked to make them, it is refused");

    const auto first = arrive(changer, memory, {.request_id = 2, .target = target, .offset = 0, .parents = true, .bytes = bytes("hello ")});

    check(first.size == 6 && first.partial.starts_with(root + "/in/deep/.telar-partial-") && !std::filesystem::exists(target), "the first chunk makes a partial beside the target, and not the target");
    check(refused([&] {
      static_cast<void>(arrive(changer, memory, {.request_id = 3, .target = target, .partial = first.partial, .offset = 3, .bytes = bytes("x")}));
    }),
        "a chunk goes where the partial ends, and nowhere else");
    check(refused([&] {
      static_cast<void>(arrive(changer, memory, {.request_id = 4, .target = target, .partial = root + "/in/deep/other.txt", .offset = 0, .bytes = bytes("x")}));
    }),
        "what is no partial of the runtime's is not written");
    check(refused([&] {
      static_cast<void>(arrive(changer, memory, {.request_id = 5, .target = root + "/elsewhere.txt", .partial = first.partial, .offset = 6, .bytes = bytes("x")}));
    }),
        "nor a partial of another directory");
    check(arrive(changer, memory, {.request_id = 6, .target = target, .partial = first.partial, .offset = 6, .bytes = bytes("world")}).size == 11);
    check(read(first.partial) == "hello world");

    const auto ended = finish(changer, memory, {.request_id = 7, .partial = first.partial, .target = target, .keep = true});

    check(ended.outcome == FileOutcome::done && ended.path == target && read(target) == "hello world" && !std::filesystem::exists(first.partial), "whole, it takes the target's name");

    // Another one arrives at a name that is taken: it stands beside it.
    const auto second = arrive(changer, memory, {.request_id = 8, .target = target, .offset = 0, .bytes = bytes("again")});
    const auto beside = finish(changer, memory, {.request_id = 9, .partial = second.partial, .target = target, .keep = true});

    check(beside.outcome == FileOutcome::renamed && beside.path == root + "/in/deep/report-1.txt" && read(beside.path) == "again" && read(target) == "hello world", "it does not replace what is there unless asked to");

    // One that is cancelled leaves nothing.
    const auto third = arrive(changer, memory, {.request_id = 10, .target = target, .offset = 0, .bytes = bytes("half")});

    check(finish(changer, memory, {.request_id = 11, .partial = third.partial, .target = target, .keep = false}).outcome == FileOutcome::done && !std::filesystem::exists(third.partial), "ended without keeping it, the partial is removed");
    check(finish(changer, memory, {.request_id = 12, .partial = third.partial, .target = target, .keep = true}).outcome == FileOutcome::missing, "and a partial that is gone cannot take the name");
  }

  void testAnArrivalIsPartOfTheLastChangeAndGoesBackWithIt() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const TemporaryDirectory directory{"/tmp/telar-transfer-XXXXXX"};
    const std::string root{directory.path()};
    const auto target = root + "/report.txt";
    FileChanger changer{memory};
    const auto arrived = arrive(changer, memory, {.request_id = 1, .target = target, .offset = 0, .bytes = bytes("new")});

    check(finish(changer, memory, {.request_id = 2, .partial = arrived.partial, .target = target, .keep = true}).outcome == FileOutcome::done);

    EncodedReply reply{memory};
    std::vector<Byte> scratch(8192);
    DecodeStorage storage{scratch};

    changer.undo(UndoFileChanges{.request_id = 3}, reply);

    const auto undone = Codec::decode<FilesChanged>(reply.payload(), storage);

    check(undone.results.size() == 1 && undone.results[0].outcome == FileOutcome::done && !std::filesystem::exists(target), "undo takes the file that arrived away again");

    // Two arrivals of one plan go back together, where the second joins the first; one that
    // does not join is a change of its own, and leaves the ones before it be.
    const auto other = root + "/other.txt";
    const auto late = root + "/late.txt";
    const auto one = arrive(changer, memory, {.request_id = 4, .target = target, .offset = 0, .bytes = bytes("one")});

    check(finish(changer, memory, {.request_id = 5, .partial = one.partial, .target = target, .keep = true}).outcome == FileOutcome::done);

    const auto two = arrive(changer, memory, {.request_id = 6, .target = other, .offset = 0, .bytes = bytes("two")});

    check(finish(changer, memory, {.request_id = 7, .partial = two.partial, .target = other, .keep = true, .joins = true}).outcome == FileOutcome::done);
    changer.undo(UndoFileChanges{.request_id = 8}, reply);
    check(!std::filesystem::exists(target) && !std::filesystem::exists(other), "what joined goes back with what it joined");

    const auto kept = arrive(changer, memory, {.request_id = 9, .target = target, .offset = 0, .bytes = bytes("kept")});

    check(finish(changer, memory, {.request_id = 10, .partial = kept.partial, .target = target, .keep = true}).outcome == FileOutcome::done);

    const auto last = arrive(changer, memory, {.request_id = 11, .target = late, .offset = 0, .bytes = bytes("last")});

    check(finish(changer, memory, {.request_id = 12, .partial = last.partial, .target = late, .keep = true}).outcome == FileOutcome::done);
    changer.undo(UndoFileChanges{.request_id = 13}, reply);
    check(std::filesystem::exists(target) && !std::filesystem::exists(late), "an arrival of its own goes back alone");
  }

  void testAFileNoChunkReachesAnyMoreIsRemoved() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const TemporaryDirectory directory{"/tmp/telar-transfer-XXXXXX"};
    const std::string root{directory.path()};
    const auto target = root + "/report.txt";
    FileChanger changer{memory};
    const auto arrived = arrive(changer, memory, {.request_id = 1, .target = target, .offset = 0, .bytes = bytes("half")});

    // While it arrives no listing shows it.
    DirectoryReader reader{memory};
    EncodedReply reply{memory};
    std::vector<Byte> scratch(8192);
    DecodeStorage storage{scratch};

    reader.list(ListDirectory{.request_id = 2, .path = root, .skip = 0, .limit = FileLimits::maximum_entries}, reply);

    const auto listing = Codec::decode<DirectoryContents>(reply.payload(), storage);

    check(std::filesystem::exists(arrived.partial) && listing.total == 0 && listing.entries.empty(), "a file that is still arriving is no entry");

    // A window that closed ends no transfer: what no chunk reaches any more is removed.
    check(changer.abandon(std::chrono::minutes{15}) == 0 && std::filesystem::exists(arrived.partial), "one a chunk just reached stays");
    check(changer.abandon(std::chrono::milliseconds{0}) == 1 && !std::filesystem::exists(arrived.partial));
    check(refused([&] {
      static_cast<void>(arrive(changer, memory, {.request_id = 3, .target = target, .partial = arrived.partial, .offset = 4, .bytes = bytes("more")}));
    }),
        "and takes no chunk more");

    // One that ended is no longer watched.
    const auto whole = arrive(changer, memory, {.request_id = 4, .target = target, .offset = 0, .bytes = bytes("whole")});

    check(finish(changer, memory, {.request_id = 5, .partial = whole.partial, .target = target, .keep = true}).outcome == FileOutcome::done);
    check(changer.abandon(std::chrono::milliseconds{0}) == 0 && std::filesystem::exists(target));
  }

  const telar::testing::Case case_abandoned{"transfer.a_file_no_chunk_reaches_any_more_is_removed", testAFileNoChunkReachesAnyMoreIsRemoved};
  const telar::testing::Case case_read{"transfer.a_file_is_read_a_chunk_at_a_time_while_it_is_the_one_listed", testAFileIsReadAChunkAtATimeWhileItIsTheOneListed};
  const telar::testing::Case case_arrives{"transfer.a_file_arrives_under_a_name_of_its_own_and_then_takes_its_target", testAFileArrivesUnderANameOfItsOwnAndThenTakesItsTarget};
  const telar::testing::Case case_undone{"transfer.an_arrival_is_part_of_the_last_change_and_goes_back_with_it", testAnArrivalIsPartOfTheLastChangeAndGoesBackWithIt};

}
