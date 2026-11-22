#include <sys/stat.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.nvim.provision;

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
    const auto config = root + "/config";
    const auto provisioned = data + "/telar/nvim/" + std::string{pinnedNeovim()} + "/bin/nvim";
    const auto named = root + "/mine/nvim";
    NvimProvision provision{memory};

    std::filesystem::create_directories(config + "/nvim");
    provision.resolve({.data_home = data, .config_home = config});
    check(provision.program() == "nvim", "without one of telar's, the PATH's Neovim");
    provision.resolve({.data_home = data, .config_home = config, .shipped = named});
    check(provision.program() == "nvim", "a package that brought none changes nothing");
    program(provisioned);
    provision.resolve({.data_home = data, .config_home = config});
    check(provision.program() == provisioned, "the Neovim telar provisioned is preferred to the PATH's");
    provision.resolve({.data_home = data, .config_home = config, .configured = named});
    check(provision.program() == provisioned, "a named Neovim that is not there is passed over");
    program(named);
    provision.resolve({.data_home = data, .config_home = config, .configured = named});
    check(provision.program() == named, "the one the user named comes first");
    provision.resolve({.data_home = data, .config_home = config, .configured = "nvim-relative"});
    check(provision.program() == provisioned, "a name that is not a path is not the user's choice of a file");
    check(::chmod(provisioned.c_str(), 0644) == 0);
    provision.resolve({.data_home = data, .config_home = config});
    check(provision.program() == "nvim", "a file that cannot be run is not a Neovim");
    provision.resolve({.data_home = data, .config_home = config, .shipped = named});
    check(provision.program() == named, "the Neovim telar's package brought comes before the PATH's");
    check(::chmod(provisioned.c_str(), 0755) == 0);
    provision.resolve({.data_home = data, .config_home = config, .shipped = named});
    check(provision.program() == provisioned, "and after the one telar provisioned");
  }

  // The configuration is the user's when the host has one, and telar's own otherwise.
  void testOwnConfigurationFillsIn() {
    testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory home{"/tmp/telar-provision-XXXXXX"};
    const std::string root{home.path()};
    const auto data = root + "/data";
    const auto config = root + "/config";
    NvimProvision provision{memory};

    std::filesystem::create_directories(data);
    std::filesystem::create_directories(config);
    provision.resolve({.data_home = data, .config_home = config});

    const std::string init{provision.ownInit()};
    const auto directory = std::filesystem::path{init}.parent_path();

    check(init.starts_with(data + "/telar/nvim-config/") && init.ends_with("/init.lua"), "a host without a configuration gets telar's, under the data directory");
    check(text(init).contains("lazy-lock.json") && text((directory / "lazy-lock.json").string()).contains("\"commit\""), "with the lockfile of its plugins beside it");
    check((std::filesystem::status(directory).permissions() & (std::filesystem::perms::group_all | std::filesystem::perms::others_all)) == std::filesystem::perms::none, "which no one else reads or writes");

    const auto written = std::filesystem::last_write_time(init);

    provision.resolve({.data_home = data, .config_home = config});
    check(provision.ownInit() == init && std::filesystem::last_write_time(init) == written, "what is there is not written again");
    std::filesystem::create_directories(config + "/nvim");
    provision.resolve({.data_home = data, .config_home = config});
    check(provision.ownInit().empty(), "a configuration the user makes later takes its place");
    provision.resolve({.data_home = {}, .config_home = config + "/missing"});
    check(provision.ownInit().empty() && provision.program() == "nvim", "without a data directory nothing is written");
  }

  const telar::testing::Case case_program{"nvim_provision.program_is_found_in_order", testProgramIsFoundInOrder};
  const telar::testing::Case case_configuration{"nvim_provision.own_configuration_fills_in", testOwnConfigurationFillsIn};

}
