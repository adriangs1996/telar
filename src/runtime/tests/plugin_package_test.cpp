#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cerrno>
#include <dirent.h>
#include <fcntl.h>
#include <cstdlib>
#include <limits.h>
#include <sys/stat.h>
#include "telar_platform/open_directory.h"
#include <cstdint>
#include <cstddef>
#include <unistd.h>
#include <openssl/sha.h>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.runtime.plugins.tap_configuration;

using namespace telar;
using namespace telar::runtime;
namespace tap = telar::runtime::plugins;

namespace {

class PackageFixture {
public:
  PackageFixture() : temporary_("/tmp/telar-plugin-package-tests-XXXXXX"), root(temporary_.path()) {
    std::filesystem::create_directories(root + "/telar");
  }

  std::string package(std::string_view id, std::string_view capabilities = "[\"proxy.tap\",\"notifications\"]") const {
    const auto path = root + '/' + std::string{id};
    std::filesystem::create_directories(path + "/lib/empty");
    write(path + "/plugin.json", std::string{"{\"api_version\":1,\"id\":\""} + std::string{id} + "\",\"version\":\"1\",\"entry\":\"main.lua\",\"source\":{\"url\":\"test\",\"revision\":\"1\"},\"capabilities\":" + std::string{capabilities} + '}');
    write(path + "/main.lua", "return {on_exchange=function() return nil end}");
    write(path + "/lib/helper.lua", "return 17");
    write(path + "/.hidden", std::string_view{"a\0b", 3});
    return path;
  }

  static void write(const std::string &path, std::string_view bytes) {
    std::ofstream output{path, std::ios::binary};
    output.write(bytes.data(), bytes.size());
    check(output.good());
  }

  static std::string grant(const tap::Package &package, std::string_view capabilities) {
    constexpr std::string_view hex = "0123456789abcdef";
    std::string digest;
    for (const auto byte : package.digest) {
      digest += hex[byte >> 4];
      digest += hex[byte & 15];
    }
    return "{\"plugin\":\"" + std::string{package.manifest.id.view()} + "\",\"digest\":\"" + digest + "\",\"capabilities\":" + std::string{capabilities} + '}';
  }

  void trust(std::string_view grants) const {
    const auto path = root + "/telar/trust.json";
    write(path, "{\"version\":1,\"grants\":[" + std::string{grants} + "]}");
    check(::chmod(path.c_str(), 0600) == 0);
  }

  std::string_view lookup(const char *name) const noexcept {
    return std::string_view{name} == "XDG_CONFIG_HOME" ? std::string_view{root} : std::string_view{};
  }

private:
  TemporaryDirectory temporary_;

public:
  const std::string root;
};

template <typename Operation>
void rejects(Operation &&operation) {
  bool rejected = false;
  try {
    operation();
  } catch (const std::exception &) {
    rejected = true;
  }
  check(rejected);
}

tap::ConfiguredPlugin configured(std::string_view path, bool enabled = true) {
  tap::ConfiguredPlugin specification;
  specification.path.assign(path);
  specification.enabled = enabled;
  return specification;
}

void checkPermissions(const std::string &root) {
  for (const auto &entry : std::filesystem::recursive_directory_iterator(root)) {
    struct stat status{};
    check(::lstat(entry.path().c_str(), &status) == 0);
    check((status.st_mode & 0777) == (entry.is_directory() ? 0700 : 0600));
  }
}

void testSnapshots() {
  PackageFixture fixture;
  const auto source = fixture.package("sample");
  SystemAllocator system;
  BudgetAllocator memory{system, 32 * 1024 * 1024};
  const auto original = tap::PackageInspector::inspect(memory, source);
  std::string snapshot_root;
  {
    tap::PackageSnapshots snapshots{memory};
    check(snapshots.path().empty());
    const auto copied = snapshots.copy(original, 0);
    snapshot_root = snapshots.path();
    check(copied.digest == original.digest && copied.root.view() != original.root.view());
    checkPermissions(snapshot_root);
    fixture.write(source + "/lib/helper.lua", "return 99");
    check(tap::PackageInspector::inspect(memory, copied.root.view()).digest == original.digest);
    rejects([&] { snapshots.copy(original, 1); });
    std::filesystem::create_symlink(fixture.root, snapshot_root + "/outside");
  }
  check(!std::filesystem::exists(snapshot_root));
  check(std::filesystem::exists(source + "/plugin.json"));
  check(memory.liveBytes() == 0);

  {
    tap::PackageSnapshots snapshots{memory};
    std::filesystem::remove(source + "/lib/helper.lua");
    std::filesystem::create_symlink("../main.lua", source + "/lib/helper.lua");
    rejects([&] { snapshots.copy(original, 0); });
    snapshot_root = snapshots.path();
  }
  check(!std::filesystem::exists(snapshot_root));
  check(memory.liveBytes() == 0);
}

void testTapConfiguration() {
  PackageFixture fixture;
  SystemAllocator system;
  BudgetAllocator memory{system, 32 * 1024 * 1024};
  const auto source = fixture.package("sample");
  auto package = tap::PackageInspector::inspect(memory, source);
  const auto specifications = std::to_array({configured("missing", false), configured("./sample")});
  {
    tap::TapConfiguration configuration{memory, fixture.root, std::span{specifications}, fixture};
    check(configuration.specifications().empty());
  }
  fixture.trust(PackageFixture::grant(package, "[\"proxy.tap\",\"notifications\"]"));
  std::string snapshot_path;
  {
    tap::TapConfiguration configuration{memory, fixture.root, std::span{specifications}, fixture};
    const auto selected = configuration.specifications();
    check(selected.size() == 1);
    check(selected[0].package_index == 0 && selected[0].generation == 1);
    check(selected[0].plugin_id == tap::stableId("sample") && selected[0].digest == package.digest);
    check(selected[0].allows(tap::Capability::proxy_tap) && selected[0].allows(tap::Capability::notifications));
    check(!selected[0].allows(tap::Capability::process_spawn));
    snapshot_path = selected[0].entry.view();
    check(std::filesystem::exists(snapshot_path));
  }
  check(!std::filesystem::exists(snapshot_path));
  check(memory.liveBytes() == 0);

  fixture.trust(PackageFixture::grant(package, "[\"notifications\"]"));
  {
    tap::TapConfiguration configuration{memory, fixture.root, std::span{specifications}, fixture};
    check(configuration.specifications().empty());
  }
  package.digest[0] ^= 1;
  fixture.trust(PackageFixture::grant(package, "[\"proxy.tap\"]"));
  {
    tap::TapConfiguration configuration{memory, fixture.root, std::span{specifications}, fixture};
    check(configuration.specifications().empty());
  }

  const auto duplicate = std::to_array({configured("sample"), configured("sample")});
  rejects([&] { tap::TapConfiguration configuration{memory, fixture.root, std::span{duplicate}, fixture}; });
  const auto missing = std::to_array({configured("missing")});
  rejects([&] { tap::TapConfiguration configuration{memory, fixture.root, std::span{missing}, fixture}; });
  fixture.write(fixture.root + "/telar/trust.json", "invalid");
  rejects([&] { tap::TapConfiguration configuration{memory, fixture.root, std::span<const tap::ConfiguredPlugin>{}, fixture}; });
  {
    tap::TapConfiguration configuration{memory, "", std::span{missing}, fixture};
    check(configuration.specifications().empty());
  }
  check(memory.liveBytes() == 0);
}

void testTapWorkerLimit() {
  PackageFixture fixture;
  SystemAllocator system;
  BudgetAllocator memory{system, 32 * 1024 * 1024};
  std::array<tap::ConfiguredPlugin, tap::Limits::workers + 1> specifications;
  std::string grants;
  for (std::size_t index = 0; index < specifications.size(); ++index) {
    const auto name = "plugin-" + std::to_string(index);
    const auto path = fixture.package(name);
    specifications[index] = configured(name);
    const auto package = tap::PackageInspector::inspect(memory, path);
    if (!grants.empty()) {
      grants += ',';
    }
    grants += PackageFixture::grant(package, "[\"proxy.tap\"]");
  }
  fixture.trust(grants);
  {
    tap::TapConfiguration configuration{memory, fixture.root, std::span{specifications}.first(tap::Limits::workers), fixture};
    check(configuration.specifications().size() == tap::Limits::workers);
  }
  rejects([&] { tap::TapConfiguration configuration{memory, fixture.root, std::span{specifications}, fixture}; });
  check(memory.liveBytes() == 0);
}

}

void testPluginPackages() {
  testSnapshots();
  testTapConfiguration();
  testTapWorkerLimit();
}
