#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif

#include "../core/memory.hpp"
#include "plugin_catalog_cases.hpp"
#include "plugin_effect_cases.hpp"
#include "../qt/plugin_packages.hpp"
#include "telar_base/memory/allocator.hpp"
#include <cstdint>
#include <span>
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <dirent.h>
#include <fcntl.h>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <limits.h>
#include <string_view>
#include <sys/stat.h>
#include "telar_base/memory/fixed_text.hpp"
#include <charconv>
#include <optional>
#include <stdexcept>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <cstddef>
#include "telar_platform/open_directory.h"
#include <unistd.h>
#include <chrono>
#include <concepts>
#include <limits>
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <openssl/sha.h>
#endif
#if (defined(__APPLE__))
#endif
#include <QFile>
#include <QIODevice>
#include <QLatin1StringView>
#include <QString>
#include <QTemporaryDir>
#include <QtCore/qtypes.h>
#include <filesystem>
#include <iostream>
#include <utility>

#include "core/memory.hpp"
#include "qt/plugin_packages.hpp"
#ifdef __APPLE__
#endif

#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif

import telar.base.text;
import telar.platform;
import telar.plugins;
#if (defined(__APPLE__))
import telar.plugins;
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif

namespace {

using namespace telar::gui;
namespace plugins = telar::runtime::plugins;
using Inspector = plugins::PackageInspection<qt::PluginPackageHash>;

constexpr std::string_view manifest = R"({"api_version":1,"id":"example","version":"1","entry":"main.lua","source":{"url":"fixture","revision":"1"},"actions":["first","second"],"capabilities":["workspace.read","notifications"]})";

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void write(const QString &path, std::string_view contents) {
  QFile file{path};
  require(file.open(QIODevice::WriteOnly), "fixture file must open");
  require(file.write(contents.data(), static_cast<qint64>(contents.size())) == static_cast<qint64>(contents.size()), "fixture bytes must be complete");
}

template <typename Operation>
void rejects(Operation &&operation) {
  bool rejected = false;
  try {
    std::forward<Operation>(operation)();
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected, "invalid package must be rejected");
}

void snapshotCopies(BudgetAllocator<SystemAllocator> &memory, const plugins::Package &package) {
  const telar::runtime::TemporaryDirectory snapshot{"/tmp/telar-gui-plugin-copy-XXXXXX"};
  plugins::PackageCopyStorage<BudgetAllocator<SystemAllocator>, Inspector> copier{memory};
  const auto copied = copier.copy(package, snapshot.descriptor(), snapshot.path());
  require(copied.digest == package.digest && copied.root.view() != package.root.view(), "snapshot must retain package bytes in a separate root");
  require(Inspector::inspect(memory, snapshot.path()).digest == package.digest, "copied hidden files, empty directories and entry bytes must retain the independent digest");
  struct stat metadata{};
  constexpr mode_t permission_mask = 0777;
  constexpr mode_t private_file = S_IRUSR | S_IWUSR;
  constexpr mode_t private_directory = private_file | S_IXUSR;
  require(::fstat(snapshot.descriptor(), &metadata) == 0 && (metadata.st_mode & permission_mask) == private_directory, "snapshot root must remain private");
  require(::fstatat(snapshot.descriptor(), "main.lua", &metadata, AT_SYMLINK_NOFOLLOW) == 0 && (metadata.st_mode & permission_mask) == private_file, "snapshot files must remain private");
  require(::fstatat(snapshot.descriptor(), "lib/empty", &metadata, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(metadata.st_mode) && (metadata.st_mode & permission_mask) == private_directory, "empty directories must remain private");
  rejects([&] {
    copier.copy(package, snapshot.descriptor(), snapshot.path());
  });
  require(Inspector::inspect(memory, snapshot.path()).digest == package.digest, "rejected overwrite must preserve the first snapshot");

  auto stale = package;
  stale.digest.front() ^= 1U;
  const telar::runtime::TemporaryDirectory changed{"/tmp/telar-gui-plugin-stale-XXXXXX"};
  rejects([&] {
    copier.copy(stale, changed.descriptor(), changed.path());
  });

  const auto forbidden = std::filesystem::path{package.root.view()} / "forbidden-copy";
  std::filesystem::create_symlink("main.lua", forbidden);
  const telar::runtime::TemporaryDirectory symlink{"/tmp/telar-gui-plugin-link-XXXXXX"};
  rejects([&] {
    copier.copy(package, symlink.descriptor(), symlink.path());
  });
  std::filesystem::remove(forbidden);
  require(::mkfifo(forbidden.c_str(), S_IRUSR | S_IWUSR) == 0, "copy FIFO fixture must exist");
  const telar::runtime::TemporaryDirectory fifo{"/tmp/telar-gui-plugin-fifo-XXXXXX"};
  rejects([&] {
    copier.copy(package, fifo.descriptor(), fifo.path());
  });
  std::filesystem::remove(forbidden);
#ifdef __APPLE__
  const telar::runtime::TemporaryDirectory native{"/tmp/telar-gui-plugin-native-XXXXXX"};
  const auto native_copy = plugins::PackageCopy{memory}.copy(package, native.descriptor(), native.path());
  require(native_copy.digest == copied.digest, "default runtime copy API and Qt provider must preserve identical bytes");
#endif
}

void packages(BudgetAllocator<SystemAllocator> &memory) {
  const QTemporaryDir temporary;
  require(temporary.isValid(), "owned package directory must exist");
  const auto root = temporary.path() + QLatin1StringView{"/example"};
  std::filesystem::create_directories((root + QLatin1StringView{"/lib/empty"}).toStdString());
  write(root + QLatin1StringView{"/plugin.json"}, manifest);
  write(root + QLatin1StringView{"/main.lua"}, "return {first=function() return nil end}");
  write(root + QLatin1StringView{"/lib/helper.lua"}, "return 17");
  write(root + QLatin1StringView{"/.hidden"}, std::string_view{"a\0b", 3});
  const auto encoded = root.toUtf8();
  const auto directory = temporary.path().toUtf8();
  const std::string_view path{encoded.constData(), static_cast<std::size_t>(encoded.size())};
  const auto inspected = Inspector::inspect(memory, path);
  String<BudgetAllocator<SystemAllocator>> digest{AllocatorRef<char, BudgetAllocator<SystemAllocator>>{memory}};
  telar::runtime::appendLowerHex(digest, inspected.digest);
  require(digest == "38c0b5755058a4a00997332cc04a7678549e25854bcd8acf9e7080f81a9622b7", "package digest must match the independent SHA-256 framing control");
  snapshotCopies(memory, inspected);
#ifdef __APPLE__
  require(plugins::PackageInspector::inspect(memory, path).digest == inspected.digest, "native and Qt SHA providers must inspect identical package bytes");
#endif
  digest.clear();
  {
    std::array<plugins::ConfiguredPlugin, 2> specs{};
    specs[0].path.assign("missing-disabled");
    specs[0].enabled = false;
    specs[1].path.assign("example");
    const plugins::PackageRegistryStorage<BudgetAllocator<SystemAllocator>, Inspector> registry{memory, {directory.constData(), static_cast<std::size_t>(directory.size())}, specs};
    require(registry.packages().size() == 1 && registry.packages().front().digest == inspected.digest, "configured registry must skip disabled packages and resolve relative paths");
#ifdef __APPLE__
    const plugins::PackageRegistry native{memory, std::string_view{directory.constData(), static_cast<std::size_t>(directory.size())}, std::span<const plugins::ConfiguredPlugin>{specs}};
    require(native.packages().size() == 1 && native.packages().front().digest == inspected.digest, "runtime registry API must preserve its native package identities");
#endif
    specs[0] = specs[1];
    rejects([&] {
      const plugins::PackageRegistryStorage<BudgetAllocator<SystemAllocator>, Inspector> duplicate{memory, {directory.constData(), static_cast<std::size_t>(directory.size())}, specs};
    });
  }

  write(root + QLatin1StringView{"/lib/helper.lua"}, "return 99");
  require(Inspector::inspect(memory, path).digest != inspected.digest, "nested content changes must invalidate package identity");
  const auto forbidden = (root + QLatin1StringView{"/forbidden"}).toStdString();
  std::filesystem::create_symlink("main.lua", forbidden);
  rejects([&] {
    Inspector::inspect(memory, path);
  });
  std::filesystem::remove(forbidden);
  require(::mkfifo(forbidden.c_str(), S_IRUSR | S_IWUSR) == 0, "owned FIFO fixture must exist");
  rejects([&] {
    Inspector::inspect(memory, path);
  });
  std::filesystem::remove(forbidden);
  write(root + QLatin1StringView{"/plugin.json"}, R"({"api_version":1,"id":"example","version":"1","entry":"../outside.lua","source":{"url":"fixture","revision":"1"}})");
  rejects([&] {
    Inspector::inspect(memory, path);
  });
}

}

int main() {
  try {
    SystemAllocator system;
    constexpr std::size_t budget = std::size_t{32} * 1024 * 1024;
    BudgetAllocator memory{system, budget};
    packages(memory);
    test::pluginCatalogCases();
    test::pluginEffectCases();
    require(memory.liveBytes() == 0, "package inspection must release every injected allocation");
    std::cout << "Plugin package providers, digest, registry and file admission passed\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
