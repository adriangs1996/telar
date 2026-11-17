#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <sys/stat.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.platform.fs;
import telar.platform.paths;
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

  std::string manifest(std::string_view id, std::string_view actions = "[]") {
    return std::string{R"({"api_version":1,"id":")"} + std::string{id} + R"(","version":"1","entry":"main.lua","source":{"url":"test","revision":"1"},"actions":)" + std::string{actions} + "}";
  }

  std::string actionList(std::size_t count) {
    std::string list = "[";

    for (std::size_t index = 0; index < count; ++index) {
      list += index == 0 ? "\"a" : ",\"a";
      list += std::to_string(index);
      list += '"';
    }

    return list + "]";
  }

  class DataHome final : public EnvironmentSource {
  public:
    explicit DataHome(std::string_view root)
        : root_(root) {}

    std::string_view lookup(const char* name) const noexcept override {
      return std::string_view{name} == "XDG_DATA_HOME" ? root_ : std::string_view{};
    }

  private:
    std::string_view root_;
  };

  // A plugin's id becomes a directory name under the plugins directory, so the manifest refuses
  // any id that is not a single safe path component.
  void testManifestRejectsUnsafeIds() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;

    for (const std::string_view id : {"../x", "a/b", ".hidden", "a..b", "x.", ""}) {
      check(refused([&] {
        static_cast<void>(plugins::Manifest::parse(memory, manifest(id)));
      }));
    }

    check(refused([&] {
      static_cast<void>(plugins::Manifest::parse(memory, manifest(std::string(65, 'a'))));
    }));

    const std::string_view root = "/data/home";
    const DataHome environment{root};
    plugins::Package package;

    package.manifest = plugins::Manifest::parse(memory, manifest(std::string(64, 'a')));
    package.digest.fill(0xab);
    const auto installation = plugins::Paths::installation(memory, environment, package);
    const auto normal = std::filesystem::path{std::string_view{installation}}.lexically_normal();

    check(normal.string() == std::string_view{installation});
    check(normal.parent_path().parent_path() == std::filesystem::path{"/data/home/telar/plugins"});
  }

  // Manifest::actions holds 64 entries; a manifest that declares more is refused.
  void testManifestRefusesMoreActionsThanCapacity() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;

    check(refused([&] {
      static_cast<void>(plugins::Manifest::parse(memory, manifest("demo", actionList(plugins::PackageLimits::actions + 1))));
    }));

    const auto accepted = plugins::Manifest::parse(memory, manifest("demo", actionList(plugins::PackageLimits::actions)));

    check(accepted.action_count == plugins::PackageLimits::actions);
    check(accepted.actions[plugins::PackageLimits::actions - 1].view() == "a63");
  }

  std::string digest(char digit) {
    return std::string(64, digit);
  }

  std::string grant(std::string_view plugin, std::string_view digest, std::string_view capabilities = R"(["notifications"])") {
    return std::string{R"({"plugin":")"} + std::string{plugin} + R"(","digest":")" + std::string{digest} + R"(","capabilities":)" + std::string{capabilities} + "}";
  }

  std::string store(std::string_view grants, std::string_view version = "1") {
    return std::string{R"({"version":)"} + std::string{version} + R"(,"grants":[)" + std::string{grants} + "]}";
  }

  std::string grants(std::size_t count) {
    std::string list;

    for (std::size_t index = 0; index < count; ++index) {
      if (index != 0) {
        list += ',';
      }

      list += grant("p" + std::to_string(index), digest('1'));
    }

    return list;
  }

  // trust.json decides which capabilities a plugin runs with: a store the runtime cannot read
  // unambiguously, or that would overflow its 64 grants, is refused as a whole.
  void testTrustStoreRefusesMalformedStores() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;

    const auto rejects = [&](const std::string& bytes) {
      return refused([&] {
        static_cast<void>(plugins::TrustStore::parse(memory, bytes));
      });
    };

    check(rejects(store(grant("a", digest('1')), "2")));
    check(rejects(store(grant("a", digest('1')) + "," + grant("a", digest('2')))));
    check(rejects(store(grants(plugins::PackageLimits::grants + 1))));
    check(rejects(store(grant("a", std::string(63, '1')))));
    check(rejects(store(grant("a", "g" + std::string(63, '1')))));
    check(rejects(store(grant("../a", digest('1')))));
    check(rejects(store(grant("a", digest('1'), R"(["root"])"))));

    const auto full = plugins::TrustStore::parse(memory, store(grants(plugins::PackageLimits::grants)));

    check(full.grants().size() == plugins::PackageLimits::grants);
  }

  // `telar plugin trust` twice for one plugin leaves one grant, for the digest trusted last, and
  // `telar plugin untrust` removes it: both through the file the runtime reads.
  void testTrustUpdatesReplaceAndRoundTrip() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-plugins-trust-XXXXXX"};
    const auto path = std::string{directory.path()} + "/config/trust.json";
    const auto file = [&] {
      return String<Memory>{path, AllocatorRef<char, Memory>{memory}};
    };

    plugins::Package package;
    plugins::Capabilities first;
    plugins::Capabilities second;

    package.manifest = plugins::Manifest::parse(memory, manifest("demo"));
    first.insert(plugins::Capability::proxy_tap);
    second.insert(plugins::Capability::notifications);
    const auto old_digest = plugins::TrustStore::parseDigest(digest('1'));
    const auto new_digest = plugins::TrustStore::parseDigest(digest('2'));

    package.digest = old_digest;
    plugins::updateTrust(memory, package, first, file());
    package.digest = new_digest;
    plugins::updateTrust(memory, package, second, file());

    const auto trusted = plugins::TrustStore::load(memory, path);

    check(trusted.grants().size() == 1);
    check(trusted.granted("demo", new_digest).containsAll(second) && !trusted.granted("demo", new_digest).contains(plugins::Capability::proxy_tap));
    check(!trusted.granted("demo", old_digest).contains(plugins::Capability::proxy_tap));
    check(!trusted.granted("demo", old_digest).contains(plugins::Capability::notifications));

    struct stat status{};

    check(::stat(path.c_str(), &status) == 0 && (status.st_mode & 0777) == 0600);

    plugins::revokeTrust(memory, "demo", file());
    check(plugins::TrustStore::load(memory, path).grants().empty());
  }

  const telar::testing::Case case_unsafe_ids{"manifest.rejects_ids_unsafe_as_path_components", testManifestRejectsUnsafeIds};
  const telar::testing::Case case_too_many_actions{"manifest.refuses_more_actions_than_capacity", testManifestRefusesMoreActionsThanCapacity};
  const telar::testing::Case case_malformed_trust{"trust_store.refuses_malformed_or_oversized_stores", testTrustStoreRefusesMalformedStores};
  const telar::testing::Case case_trust_updates{"trust_store.updates_replace_and_round_trip", testTrustUpdatesReplaceAndRoundTrip};

}
