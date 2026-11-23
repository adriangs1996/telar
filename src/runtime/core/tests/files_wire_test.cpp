#include <cstdlib>

import std;
import telar.testing;
import telar.platform.fs;
import telar.runtime.core.tests.protocol_peer;
import telar.runtime.core.tests.runtime_host;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // A client lists a directory of the runtime's machine, changes its files and takes the change
  // back, and is refused a directory that does not exist: the explorer's requests, end to end.
  void testAClientListsAndChangesFiles() {
    TemporaryDirectory home{"/tmp/telar-files-wire-XXXXXX"};
    const std::string root{home.path()};

    // The trash a change fills is this case's own.
    ::setenv("HOME", root.c_str(), 1);                      // NOLINT(concurrency-mt-unsafe): the runtime host starts after it, in this process
    ::setenv("XDG_DATA_HOME", (root + "/data").c_str(), 1); // NOLINT(concurrency-mt-unsafe): the runtime host starts after it, in this process
    std::filesystem::create_directories(root + "/work/src");
    std::ofstream{root + "/work/notes.md"} << "notes\n";

    RuntimeHost host;
    ProtocolPeer explorer{host.socket()};
    const std::string work = root + "/work";
    const auto listing = explorer.exchange<DirectoryContents>(ListDirectory{.request_id = 1, .path = work, .skip = 0, .limit = FileLimits::maximum_entries});

    check(listing.path == work && listing.total == 2 && listing.entries.size() == 2);
    check(listing.entries[0].name == "src" && listing.entries[0].directory && listing.entries[1].name == "notes.md" && listing.entries[1].size == 6);

    const auto identity = listing.entries[1].identity;
    const std::string notes = work + "/notes.md";
    const std::string renamed = work + "/src/renamed.md";
    const ds::Array<FileOperation, 1> operations{FileOperation{.kind = FileOperationKind::move, .source = notes, .target = renamed, .identity = identity}};
    const auto changed = explorer.exchange<FilesChanged>(ChangeFiles{.request_id = 2, .operations = operations.view()});

    check(changed.undoable && changed.results.size() == 1 && changed.results[0].outcome == FileOutcome::done && changed.results[0].path == renamed);
    check(std::filesystem::exists(renamed) && !std::filesystem::exists(notes), "the runtime moved the file");

    const auto undone = explorer.exchange<FilesChanged>(UndoFileChanges{.request_id = 3});

    check(undone.results.size() == 1 && undone.results[0].outcome == FileOutcome::done && std::filesystem::exists(notes), "and took the move back");

    const auto sizes = explorer.exchange<DirectorySizes>(MeasureDirectory{.request_id = 4, .path = work, .skip = 0, .limit = FileLimits::maximum_entries});

    check(sizes.sizes.size() == 1 && sizes.sizes[0].name == "src" && sizes.sizes[0].complete);

    const auto inspected = explorer.exchange<FileInspection>(InspectFile{.request_id = 5, .path = notes});

    check(inspected.kind == FileKind::file && inspected.text == "notes\n" && !inspected.binary);

    const auto changes = explorer.exchange<RepositoryChanges>(QueryChanges{.request_id = 6, .path = work});

    check(changes.root.empty() && changes.changes.empty(), "a directory outside any repository has no changes");

    bool refused = false;

    try {
      explorer.exchange<DirectoryContents>(ListDirectory{.request_id = 7, .path = work + "/missing", .skip = 0, .limit = 1});
    } catch (const ProtocolFailure& failure) {
      refused = failure.code == FailureCode::invalid_request;
    }

    check(refused, "a directory that does not exist is refused, not answered empty");
  }

  const telar::testing::Case case_a_client_lists_and_changes_files{"files_wire.a_client_lists_and_changes_files", testAClientListsAndChangesFiles};

}
