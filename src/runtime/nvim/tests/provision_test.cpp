#include <sys/stat.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.nvim.provision;
import telar.wire.nvim;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::runtime;

  // A file that may be run, as a Neovim would be.
  void program(const std::string& path) {
    std::filesystem::create_directories(std::filesystem::path{path}.parent_path());
    std::ofstream{path} << "#!/bin/sh\n";
    check(::chmod(path.c_str(), 0755) == 0);
  }

  std::string text(const std::string& path) {
    std::ifstream file{path};

    return {std::istreambuf_iterator<char>{file}, std::istreambuf_iterator<char>{}};
  }

  // The Neovim a pane starts: the one the user named, else the one telar provisioned, else
  // whatever the PATH has.
  void testProgramIsFoundInOrder() {
    testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory home{"/tmp/telar-provision-XXXXXX"};
    const std::string root{home.path()};
    const auto data = root + "/data";
    const auto provisioned = data + "/telar/nvim/" + std::string{pinnedNeovim()} + "/bin/nvim";
    const auto named = root + "/mine/nvim";
    NvimProvision provision{memory};

    provision.resolve({.data_home = data});
    check(provision.program() == "nvim", "without one of telar's, the PATH's Neovim");
    provision.resolve({.data_home = data, .shipped = named});
    check(provision.program() == "nvim", "a package that brought none changes nothing");
    program(provisioned);
    provision.resolve({.data_home = data});
    check(provision.program() == provisioned, "the Neovim telar provisioned is preferred to the PATH's");
    provision.resolve({.data_home = data, .configured = named});
    check(provision.program() == provisioned, "a named Neovim that is not there is passed over");
    program(named);
    provision.resolve({.data_home = data, .configured = named});
    check(provision.program() == named, "the one the user named comes first");
    provision.resolve({.data_home = data, .configured = "nvim-relative"});
    check(provision.program() == provisioned, "a name that is not a path is not the user's choice of a file");
    check(::chmod(provisioned.c_str(), 0644) == 0);
    provision.resolve({.data_home = data});
    check(provision.program() == "nvim", "a file that cannot be run is not a Neovim");
    provision.resolve({.data_home = data, .shipped = named});
    check(provision.program() == named, "the Neovim telar's package brought comes before the PATH's");
    check(::chmod(provisioned.c_str(), 0755) == 0);
    provision.resolve({.data_home = data, .shipped = named});
    check(provision.program() == provisioned, "and after the one telar provisioned");
  }

  // The configuration is always telar's own, whatever configuration of Neovim the user has.
  void testOwnConfigurationIsTheOnly() {
    testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory home{"/tmp/telar-provision-XXXXXX"};
    const std::string root{home.path()};
    const auto data = root + "/data";
    NvimProvision provision{memory};

    std::filesystem::create_directories(data);
    provision.resolve({.data_home = data});

    const std::string init{provision.ownInit()};
    const auto directory = std::filesystem::path{init}.parent_path();

    check(init.starts_with(data + "/telar/nvim-config/") && init.ends_with("/init.lua"), "telar's configuration, under the data directory");
    check(text(init).contains("telar's own Neovim configuration") && !text(init).contains("clone") && !text(init).contains("require(\"lazy\")"), "which installs nothing");
    check(text(init).contains("stdpath(\"config\") .. \"/init.lua\""), "and loads the user's layer over itself");
    check((std::filesystem::status(directory).permissions() & (std::filesystem::perms::group_all | std::filesystem::perms::others_all)) == std::filesystem::perms::none, "which no one else reads or writes");

    const auto written = std::filesystem::last_write_time(init);

    provision.resolve({.data_home = data});
    check(provision.ownInit() == init && std::filesystem::last_write_time(init) == written, "what is there is not written again");
    provision.resolve({.data_home = {}});
    check(provision.ownInit().empty() && provision.program() == "nvim", "without a data directory nothing is written");
  }

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the configuration's files are bytes
  }

  // A client's configuration replaces the machine's: what differs is written, what the client
  // lacks goes, and what starts with a dot is the machine's own.
  void testConfigurationIsMirrored() {
    testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory home{"/tmp/telar-provision-XXXXXX"};
    const std::filesystem::path editor = std::string{home.path()} + "/config/telar/editor";
    const ds::Array first{
        NvimConfigurationFile{.path = "init.lua", .content = bytes("require('config')\n")},
        NvimConfigurationFile{.path = "lua/config/init.lua", .content = bytes("vim.o.number = true\n")},
        NvimConfigurationFile{.path = "lua/plugins/ui.lua", .content = bytes("return {}\n")},
        NvimConfigurationFile{.path = "lazy-lock.json", .content = bytes("{}\n")},
    };

    auto change = mirrorNvimConfiguration(memory, editor.native(), first.view());
    check(change.written == 4 && change.removed == 0 && text((editor / "lua/plugins/ui.lua").string()) == "return {}\n", "the files are written, with the directories they are in");

    change = mirrorNvimConfiguration(memory, editor.native(), first.view());
    check(change.written == 0 && change.removed == 0, "the same configuration again changes nothing");

    std::filesystem::create_directories(editor / ".git");
    std::ofstream{editor / ".git/HEAD"} << "ref: refs/heads/main\n";
    std::ofstream{editor / "stray.lua"} << "-- the machine's\n";
    std::filesystem::create_symlink("/etc/hosts", editor / "linked");
    const ds::Array second{
        NvimConfigurationFile{.path = "init.lua", .content = bytes("require('config')\nvim.o.wrap = true\n")},
        NvimConfigurationFile{.path = "lua/config/init.lua", .content = bytes("vim.o.number = true\n")},
        NvimConfigurationFile{.path = "lazy-lock.json", .content = bytes("{}\n")},
    };

    change = mirrorNvimConfiguration(memory, editor.native(), second.view());
    check(change.written == 1 && text((editor / "init.lua").string()).contains("wrap"), "a file that differs is written again");
    check(change.removed == 3 && !std::filesystem::exists(editor / "lua/plugins") && !std::filesystem::exists(editor / "stray.lua") && !std::filesystem::is_symlink(editor / "linked"), "what the client lacks goes, a directory left empty with it");
    check(std::filesystem::exists("/etc/hosts") && std::filesystem::exists(editor / ".git/HEAD"), "a link goes without what it points at, and a dot entry stays");

    // A file where the client has a directory, and a directory where it has a file.
    std::filesystem::remove(editor / "lazy-lock.json");
    std::filesystem::create_directories(editor / "lazy-lock.json/inside");
    std::ofstream{editor / "lua/config/init.lua.d"} << "x";
    const ds::Array third{
        NvimConfigurationFile{.path = "lazy-lock.json", .content = bytes("{}\n")},
        NvimConfigurationFile{.path = "lua/config/init.lua.d/more.lua", .content = bytes("--\n")},
    };

    change = mirrorNvimConfiguration(memory, editor.native(), third.view());
    check(std::filesystem::is_regular_file(editor / "lazy-lock.json") && std::filesystem::is_regular_file(editor / "lua/config/init.lua.d/more.lua"), "what stands in the way of a file or a directory goes");

    const auto refused = [&](std::string_view path) {
      const ds::Array one{NvimConfigurationFile{.path = path, .content = bytes("x")}};

      try {
        static_cast<void>(mirrorNvimConfiguration(memory, editor.native(), one.view()));
      } catch (const std::invalid_argument&) {
        return std::filesystem::exists(editor / "lazy-lock.json");
      }

      return false;
    };

    for (const auto path : {"../escape.lua", "/etc/passwd", ".git/config", "lua/../../x", "a//b", "lua/.hidden", "dir/", "", "a\\b"}) {
      check(refused(path), std::format("{:?} is refused before anything is touched", path));
    }

    const ds::Array twice{NvimConfigurationFile{.path = "init.lua", .content = bytes("a")}, NvimConfigurationFile{.path = "init.lua", .content = bytes("b")}};
    bool doubled = false;

    try {
      static_cast<void>(mirrorNvimConfiguration(memory, editor.native(), twice.view()));
    } catch (const std::invalid_argument&) {
      doubled = true;
    }

    check(doubled, "a path named twice is refused");
  }

  const telar::testing::Case case_program{"nvim_provision.program_is_found_in_order", testProgramIsFoundInOrder};
  const telar::testing::Case case_mirror{"nvim_provision.configuration_is_mirrored", testConfigurationIsMirrored};
  const telar::testing::Case case_configuration{"nvim_provision.own_configuration_is_the_only", testOwnConfigurationIsTheOnly};

}
