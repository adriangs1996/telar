#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.files.directory;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct Listed {
    std::vector<std::string> names;
    std::vector<DirectoryEntry> entries;
    std::uint32_t total = 0;
    std::uint32_t skip = 0;
  };

  Listed list(ConcurrentMemory& memory, std::string_view path, std::uint32_t skip = 0, std::uint16_t limit = FileLimits::maximum_entries) {
    DirectoryReader reader{memory};
    EncodedReply reply{memory};
    std::vector<Byte> scratch(256 * 1024);
    DecodeStorage storage{scratch};

    reader.list(ListDirectory{.request_id = 7, .path = path, .skip = skip, .limit = limit}, reply);

    const auto listing = Codec::decode<DirectoryContents>(reply.payload(), storage);
    Listed listed{.total = listing.total, .skip = listing.skip};

    check(listing.request_id == 7 && listing.path == path);
    for (const auto& entry : listing.entries) {
      listed.names.emplace_back(entry.name);
      listed.entries.push_back(entry);
    }

    return listed;
  }

  void write(const std::string& path, std::string_view text) {
    std::ofstream{path} << text;
  }

  void testAListingPutsDirectoriesFirstAndFoldsCase() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-files-XXXXXX"};
    const std::string root{directory.path()};

    std::filesystem::create_directories(root + "/src");
    std::filesystem::create_directories(root + "/Docs");
    std::filesystem::create_directories(root + "/.git");
    write(root + "/README.md", "read me\n");
    write(root + "/plugins.md", "plugins\n");
    write(root + "/remote.md", "remote\n");
    write(root + "/.gitignore", "out/\n");
    std::filesystem::create_symlink(root + "/src", root + "/link");
    std::filesystem::create_symlink(root + "/nowhere", root + "/broken");

    const auto listed = list(memory, root);
    const std::vector<std::string> expected{".git", "Docs", "link", "src", ".gitignore", "broken", "plugins.md", "README.md", "remote.md"};

    check(listed.names == expected, "directories first, then files, each by name without regard to case");
    check(listed.total == expected.size() && listed.skip == 0);
    check(listed.entries[2].kind == FileKind::link && listed.entries[2].directory, "a link to a directory lists as one");
    check(listed.entries[5].kind == FileKind::link && !listed.entries[5].directory, "a link that points nowhere lists as a file");
    check(listed.entries[7].kind == FileKind::file && listed.entries[7].size == 8, "a file says its bytes");
    check(listed.entries[7].identity.inode != 0 && listed.entries[7].identity.modified_seconds != 0, "and what tells it from another of its name");
    check(listed.entries[0].size == 0, "a directory's bytes are measured apart");
  }

  void testAListingIsReadAPageAtATime() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-files-XXXXXX"};
    const std::string root{directory.path()};

    for (int index = 0; index < 10; ++index) {
      write(root + "/file" + std::to_string(index), "x");
    }

    const auto first = list(memory, root, 0, 4);
    const auto last = list(memory, root, 8, 4);
    const auto past = list(memory, root, 40, 4);

    check(first.names == std::vector<std::string>{"file0", "file1", "file2", "file3"} && first.total == 10);
    check(last.names == std::vector<std::string>{"file8", "file9"} && last.skip == 8, "the last page holds what is left");
    check(past.names.empty() && past.skip == 10 && past.total == 10, "past the end there is nothing, and the total still says how many there are");
  }

  void testTheNextPageGoesOnWithWhatTheFirstRead() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-files-XXXXXX"};
    const std::string root{directory.path()};
    DirectoryReader reader{memory};
    const auto page = [&](std::uint32_t skip) {
      EncodedReply reply{memory};
      std::vector<Byte> scratch(64 * 1024);
      DecodeStorage storage{scratch};

      reader.list(ListDirectory{.request_id = 9, .path = root, .skip = skip, .limit = 2}, reply);

      const auto listing = Codec::decode<DirectoryContents>(reply.payload(), storage);
      Listed listed{.total = listing.total, .skip = listing.skip};

      for (const auto& entry : listing.entries) {
        listed.names.emplace_back(entry.name);
        listed.entries.push_back(entry);
      }

      return listed;
    };

    write(root + "/a.md", "a\n");
    write(root + "/b.md", "b\n");
    write(root + "/c.md", "c\n");
    check(page(0).names == std::vector<std::string>{"a.md", "b.md"});

    // A file grows, which leaves the directory as it was: the page that follows is of the
    // listing the first one read, and the first page reads the directory again.
    write(root + "/c.md", "longer\n");
    check(page(2).entries.at(0).size == 2, "a later page is of the same reading");
    check(page(0).total == 3);
    check(page(2).entries.at(0).size == 7, "the first page reads the directory as it is");

    // An entry comes: the directory changed, and a later page reads it again.
    write(root + "/d.md", "d\n");
    std::filesystem::last_write_time(root, std::filesystem::last_write_time(root) + std::chrono::seconds{2});

    const auto after = page(2);

    check(after.total == 4 && after.names == std::vector<std::string>{"c.md", "d.md"}, "a directory that changed is read again");
  }

  void testAListingRefusesWhatIsNoDirectory() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-files-XXXXXX"};
    const std::string root{directory.path()};
    const auto refused = [&](std::string_view path) {
      try {
        list(memory, path);
      } catch (const RequestError& error) {
        return error.code() == FailureCode::invalid_request;
      }

      return false;
    };

    write(root + "/file", "x");
    check(refused("relative/path"), "a path that is not absolute");
    check(refused(root + "/missing"), "a directory that does not exist");
    check(refused(root + "/file"), "a file");
  }

  void testDirectoriesAreMeasuredWithWhatIsBelowThem() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-files-XXXXXX"};
    const std::string root{directory.path()};
    const std::string large(256 * 1024, 'x');

    std::filesystem::create_directories(root + "/big/deep/deeper");
    std::filesystem::create_directories(root + "/empty");
    write(root + "/big/one", large);
    write(root + "/big/deep/deeper/two", large);
    write(root + "/file", large);
    // Two names of one file take its blocks once.
    std::filesystem::create_hard_link(root + "/big/one", root + "/big/again");

    const std::atomic<bool> cancelled{false};
    DirectoryReader reader{memory};
    EncodedReply reply{memory};
    std::vector<Byte> scratch(256 * 1024);
    DecodeStorage storage{scratch};

    reader.measure(MeasureDirectory{.request_id = 9, .path = root, .skip = 0, .limit = FileLimits::maximum_entries}, cancelled, reply);

    const auto sizes = Codec::decode<DirectorySizes>(reply.payload(), storage);

    check(sizes.request_id == 9 && sizes.path == root && sizes.sizes.size() == 2, "one size for each directory, none for a file");
    check(sizes.sizes[0].name == "big" && sizes.sizes[0].complete);
    check(sizes.sizes[0].bytes >= 2 * large.size() && sizes.sizes[0].bytes < 3 * large.size(), "what a directory holds at every level, a file with two names once");
    check(sizes.sizes[1].name == "empty" && sizes.sizes[1].complete && sizes.sizes[1].bytes == 0);

    const std::atomic<bool> already{true};

    reader.measure(MeasureDirectory{.request_id = 10, .path = root, .skip = 0, .limit = FileLimits::maximum_entries}, already, reply);

    const auto unfinished = Codec::decode<DirectorySizes>(reply.payload(), storage);

    check(unfinished.sizes.size() == 2 && !unfinished.sizes[0].complete, "a measure that was cancelled says what it did not finish");
  }

  void testTheOrderOfAListing() {
    check(listsBefore("b", true, "a", false), "a directory before a file");
    check(listsBefore("plugins.md", false, "README.md", false) && listsBefore("README.md", false, "remote.md", false), "case does not count");
    check(listsBefore("A", false, "a", false) && !listsBefore("a", false, "A", false), "two names that differ only in case go by their bytes");
    check(!listsBefore("same", false, "same", false));
  }

  const telar::testing::Case case_order{"directory.the_order_of_a_listing", testTheOrderOfAListing};
  const telar::testing::Case case_listing{"directory.a_listing_puts_directories_first_and_folds_case", testAListingPutsDirectoriesFirstAndFoldsCase};
  const telar::testing::Case case_pages{"directory.a_listing_is_read_a_page_at_a_time", testAListingIsReadAPageAtATime};
  const telar::testing::Case case_continued{"directory.the_next_page_goes_on_with_what_the_first_read", testTheNextPageGoesOnWithWhatTheFirstRead};
  const telar::testing::Case case_refused{"directory.a_listing_refuses_what_is_no_directory", testAListingRefusesWhatIsNoDirectory};
  const telar::testing::Case case_measured{"directory.directories_are_measured_with_what_is_below_them", testDirectoriesAreMeasuredWithWhatIsBelowThem};

}
