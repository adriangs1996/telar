#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.platform.fs;
import telar.plugins;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  template <typename Operation>
  bool refused(Operation&& operation) {
    try {
      operation();
    } catch (const std::exception&) {
      return true;
    }

    return false;
  }

  void write(const std::filesystem::path& path, std::string_view bytes) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream file{path, std::ios::binary | std::ios::trunc};

    file.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    check(static_cast<bool>(file));
  }

  std::string manifest(std::string_view id) {
    return std::string{R"({"api_version":1,"id":")"} + std::string{id} + R"(","version":"1","entry":"main.lua","source":{"url":"test","revision":"1"}})";
  }

  // A package directory with its manifest and entry, under `root`.
  std::filesystem::path package(const std::filesystem::path& root, std::string_view id, std::string_view entry = "return {}") {
    const auto directory = root / id;

    write(directory / "plugin.json", manifest(id));
    write(directory / "main.lua", entry);
    return directory;
  }

  plugins::Package inspect(Memory& memory, const std::filesystem::path& path) {
    return plugins::PackageInspector::inspect(memory, path.string());
  }

  // A package is inspected before anyone trusts it, so its file count, its manifest, its entry
  // and its total size are bounded.
  void testInspectionRefusesPackagesBeyondLimits() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-plugin-limits-XXXXXX"};
    const std::filesystem::path root{std::string{directory.path()}};

    // plugin.json and main.lua count among the files.
    const auto files = package(root, "files");

    for (std::size_t index = 0; index < plugins::PackageLimits::files - 2; ++index) {
      write(files / ("f" + std::to_string(index)), "x");
    }

    check(!refused([&] {
      static_cast<void>(inspect(memory, files));
    }));
    write(files / "excess", "x");
    check(refused([&] {
      static_cast<void>(inspect(memory, files));
    }));

    const auto entry = package(root, "entry", std::string(plugins::Limits::entry_bytes + 1, '-'));

    check(refused([&] {
      static_cast<void>(inspect(memory, entry));
    }));

    const auto large_manifest = package(root, "manifest");

    write(large_manifest / "plugin.json", manifest("manifest") + std::string(plugins::PackageLimits::manifest_bytes, ' '));
    check(refused([&] {
      static_cast<void>(inspect(memory, large_manifest));
    }));

    const auto total = package(root, "total");
    const std::string mebibyte(std::size_t{1024} * 1024, 'x');

    for (std::size_t index = 0; index <= plugins::PackageLimits::total_bytes / mebibyte.size(); ++index) {
      write(total / ("part" + std::to_string(index)), mebibyte);
    }

    check(refused([&] {
      static_cast<void>(inspect(memory, total));
    }));
  }

  // `telar plugin install` publishes the package's bytes at the destination, accepts a
  // destination that already holds the same package, and refuses one that holds anything else.
  void testInstallationIsIdempotentAndRefusesForeignTargets() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-plugin-install-XXXXXX"};
    const std::filesystem::path root{std::string{directory.path()}};
    const auto demo = inspect(memory, package(root / "sources", "demo"));
    const auto other = inspect(memory, package(root / "sources", "other", "return {other = true}"));
    plugins::PackageInstallation installation{memory};
    const auto destination = root / "installed" / "demo";

    installation.install(demo, destination.string());
    check(inspect(memory, destination).digest == demo.digest);
    installation.install(demo, destination.string());
    check(inspect(memory, destination).digest == demo.digest);

    const auto foreign = root / "installed" / "foreign";

    installation.install(other, foreign.string());
    check(refused([&] {
      installation.install(demo, foreign.string());
    }));
    check(inspect(memory, foreign).digest == other.digest);

    const auto file = root / "installed" / "file";

    write(file, "not a package");
    check(refused([&] {
      installation.install(demo, file.string());
    }));
  }

  const telar::testing::Case case_inspection_limits{"package.refuses_packages_beyond_limits", testInspectionRefusesPackagesBeyondLimits};
  const telar::testing::Case case_installation{"installation.is_idempotent_and_refuses_foreign_targets", testInstallationIsIdempotentAndRefusesForeignTargets};

}
