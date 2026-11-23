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
    check(explorer.exchange<HomeLocated>(LocateHome{.request_id = 8}).path == root, "and it says where the home of its account is");

    // A file arrives a chunk at a time, as one a window brings from another machine, and is read
    // back as it was written.
    const auto arriving = work + "/arrived.bin";
    const std::string_view sent = "bytes that crossed";
    const std::span<const Byte> crossing{reinterpret_cast<const Byte*>(sent.data()), sent.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the bytes of a text
    const std::string partial{explorer.exchange<FileWritten>(WriteFile{.request_id = 9, .target = arriving, .offset = 0, .bytes = crossing}).partial};

    check(explorer.exchange<FileWriteEnded>(EndFileWrite{.request_id = 10, .partial = partial, .target = arriving, .keep = true}).outcome == FileOutcome::done);

    const auto arrived = explorer.exchange<FileInspection>(InspectFile{.request_id = 11, .path = arriving}).identity;
    const auto back = explorer.exchange<FileChunk>(ReadFile{.request_id = 12, .path = arriving, .identity = arrived, .offset = 0, .limit = FileLimits::chunk_bytes});

    check(back.end && back.size == sent.size() && std::ranges::equal(back.bytes, crossing), "what was written in chunks reads back whole");

    // Nothing touched a file yet: the answer names the directory asked and holds no touch.
    const auto touches = explorer.exchange<FileTouches>(QueryTouches{.request_id = 13, .path = work});

    check(touches.path == work && touches.touches.empty() && !touches.truncated, "who touched what is asked of the runtime too");

    // A link is made as it is said, and read back as what it says, not as what it points to.
    const auto link = work + "/latest";
    const ds::Array<FileOperation, 1> linked{{{.kind = FileOperationKind::link, .source = "arrived.bin", .target = link}}};
    const auto made = explorer.exchange<FilesChanged>(ChangeFiles{.request_id = 14, .operations = linked.view(), .joins = true});

    check(made.results.size() == 1 && made.results[0].outcome == FileOutcome::done && made.results[0].path == link);

    const auto listed = explorer.exchange<FileInspection>(InspectFile{.request_id = 15, .path = link});
    const auto said = explorer.exchange<FileChunk>(ReadFile{.request_id = 16, .path = link, .identity = listed.identity, .link = true});
    const std::string_view text{reinterpret_cast<const char*>(said.bytes.data()), said.bytes.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the bytes of a text

    check(listed.kind == FileKind::link && said.end && text == "arrived.bin", "a link crosses as its text");
  }

  void testTheExplorersPlacesOutliveTheWindowThatGaveThem() {
    RuntimeHost host;
    const ds::Array<KeptPlace, 3> places{{
        {.letter = Byte{'a'}, .root = "/srv/site", .selected = "/srv/site/index.html"},
        {.letter = Byte{'B'}, .machine = "box", .root = "/var/log"},
        {.root = "/srv", .selected = "/srv/site"},
    }};

    {
      ProtocolPeer window{host.socket()};

      check(window.exchange<PlacesKept>(QueryPlaces{.request_id = 1}).places.empty(), "a runtime no window gave places keeps none");
      window.send(KeepPlaces{.places = places.view(), .jump = 1});
      // What says more than the runtime keeps is not taken, and what it kept stays.
      const ds::Array<KeptPlace, 1> wrong{{{.letter = Byte{'!'}, .root = "/srv"}}};

      window.send(KeepPlaces{.places = wrong.view()});
      check(window.exchange<PlacesKept>(QueryPlaces{.request_id = 2}).places.size() == 3);
    }

    // The window is gone: the one that comes after it reads them back.
    ProtocolPeer next{host.socket()};
    const auto kept = next.exchange<PlacesKept>(QueryPlaces{.request_id = 3});

    check(kept.places.size() == 3 && kept.jump == 1);
    check(kept.places[0].letter == Byte{'a'} && kept.places[0].machine.empty() && kept.places[0].root == "/srv/site" && kept.places[0].selected == "/srv/site/index.html");
    check(kept.places[1].letter == Byte{'B'} && kept.places[1].machine == "box" && kept.places[1].root == "/var/log" && kept.places[1].selected.empty(), "a mark keeps the label of its machine");
    check(kept.places[2].letter == Byte{0} && kept.places[2].root == "/srv", "and a step of the jump list has no letter");
  }

  const telar::testing::Case case_places{"files_wire.the_explorers_places_outlive_the_window_that_gave_them", testTheExplorersPlacesOutliveTheWindowThatGaveThem};
  const telar::testing::Case case_a_client_lists_and_changes_files{"files_wire.a_client_lists_and_changes_files", testAClientListsAndChangesFiles};

}
