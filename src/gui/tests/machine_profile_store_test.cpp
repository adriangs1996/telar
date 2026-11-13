#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include "../core/memory.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <string_view>
#include <system_error>
#include <span>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include "telar_base/memory/allocator.hpp"
#include <exception>
#include <bit>
#include <limits>
#include <new>
#include "telar_client/codecs/telar_wire.hpp"
#include <iostream>

#include "core/memory.hpp"


import telar.gui.machines.profile_store;
import telar.gui.machines.discovery;

namespace {

using namespace telar::gui;
using telar::gui::test::require;

struct Random {
  std::uint8_t next = 1;

  void fill(std::span<std::uint8_t> output) {
    std::ranges::fill(output, 0);
    output.back() = next++;
  }
};

class MemoryFile {
public:
  bool locked = false;
  bool fail_replace = false;
  unsigned replacements = 0;
  telar::runtime::FixedText<MachineLimits::file_bytes> source;

  template <Allocator Memory>
  std::optional<Vector<telar::Byte, Memory>> read(Memory &memory) const {
    if (source.view().empty()) {
      return std::nullopt;
    }

    const auto bytes = telar::byteView(source.view());

    return Vector<telar::Byte, Memory>{bytes.begin(), bytes.end(), AllocatorRef<telar::Byte, Memory>{memory}};
  }

  class Transaction {
  public:
    explicit Transaction(MemoryFile &file)
        : file_(file) {
      require(!file_.locked, "a profile transaction must not overlap another transaction");
      file_.locked = true;
    }

    ~Transaction() {
      file_.locked = false;
    }

    Transaction(const Transaction &) = delete;
    Transaction &operator=(const Transaction &) = delete;
    Transaction(Transaction &&) = delete;
    Transaction &operator=(Transaction &&) = delete;

    template <Allocator Memory>
    std::optional<Vector<telar::Byte, Memory>> read(Memory &memory) const {
      require(file_.locked, "transaction reads must hold the file lock");

      return file_.read(memory);
    }

    void replace(std::string_view source) {
      require(file_.locked, "replacement must remain inside the read-change-write lock");
      if (file_.fail_replace) {
        throw std::runtime_error{"Injected profile replacement failure"};
      }

      file_.source.assign(source);
      ++file_.replacements;
    }

  private:
    MemoryFile &file_;
  };

  Transaction lock() {
    return Transaction{*this};
  }
};

void batchesCommitEveryEditWithOriginalMetadata() {
  SystemAllocator system;
  constexpr std::size_t allocation_budget = std::size_t{128} * 1024;
  BudgetAllocator memory{system, allocation_budget};
  MemoryFile file;
  MachineProfileStore store{memory, file};
  require(store.load().rows().empty(), "a missing profile file must load as an empty list");
  Random random;
  const std::array edits{
      MachineEdit{.kind = MachineEditKind::add, .label = "build", .value = "dev@build", .color = "accent"},
      MachineEdit{.kind = MachineEditKind::rename, .label = "build", .value = "gpu"},
      MachineEdit{.kind = MachineEditKind::place_program, .label = "gpu", .value = "/opt/bin/telar"},
      MachineEdit{.kind = MachineEditKind::record_login, .label = "gpu", .value = {}, .login_agent = MachineAgent::codex, .login = MachineLogin::done},
      MachineEdit{.kind = MachineEditKind::disable, .label = "gpu", .value = {}},
  };
  const auto result = store.change(edits, random, "local");
  require(result.rows().size() == 1 && result.rows().front().label() == "gpu", "a committed batch must include the renamed machine");
  require(result.rows().front().destination() == "dev@build" && result.rows().front().program() == "/opt/bin/telar", "a batch must preserve the destination while setting its program path");
  require(result.rows().front().login(MachineAgent::codex) == MachineLogin::done && !result.rows().front().enabled(), "a batch must retain login and enablement edits");
  require(result.rows().front().identity().format().view() == "m-010000000000", "saved identities must come from the injected random source");
  require(file.replacements == 1 && !file.locked, "all edits must reach disk in one replacement before releasing the lock");
  const auto loaded = store.load();
  require(loaded.rows().front().label() == "gpu" && loaded.version() == 2, "committed setup metadata must reload through the original JSON format");
  require(memory.liveBytes() == 0, "profile operations must release every temporary byte");
}

void rejectedBatchesAndWriteFailuresPreserveTheSavedFile() {
  SystemAllocator memory;
  MemoryFile file;
  file.source.assign("{\"version\":1,\"machines\":[]}\n");
  const auto original = file.source;
  MachineProfileStore store{memory, file};
  Random random;
  const std::array invalid{
      MachineEdit{.kind = MachineEditKind::add, .label = "valid", .value = "dev@valid"},
      MachineEdit{.kind = MachineEditKind::add, .label = "invalid", .value = "bad host"},
  };
  bool rejected = false;
  try {
    static_cast<void>(store.change(invalid, random, "local"));
  } catch (const MachineFailure &failure) {
    require(failure.code() == MachineError::invalid_destination, "the rejected edit must retain its original validation failure");
    rejected = true;
  }

  require(rejected && file.source.view() == original.view() && file.replacements == 0 && !file.locked, "a rejected later edit must leave the complete saved file untouched and unlock");
  file.fail_replace = true;
  const std::array valid{invalid.front()};
  bool failed = false;
  try {
    static_cast<void>(store.change(valid, random, "local"));
  } catch (const std::runtime_error &) {
    failed = true;
  }

  require(failed && !file.locked && file.source.view() == original.view(), "a failed replacement must release the transaction without publishing its staged profiles");
}

void everyTransactionReloadsExternalChangesAndRespectsTheLocalAlias() {
  SystemAllocator memory;
  MemoryFile file;
  MachineProfileStore store{memory, file};
  Random random;
  const std::array first{MachineEdit{.kind = MachineEditKind::add, .label = "build", .value = "dev@build"}};
  static_cast<void>(store.change(first, random, "hostname"));
  file.source.assign("{\"version\":1,\"local_label\":\"local-alias\",\"machines\":[]}\n");
  const std::array second{MachineEdit{.kind = MachineEditKind::add, .label = "hostname", .value = "dev@other"}};
  const auto profiles = store.change(second, random, "hostname");
  require(profiles.rows().size() == 1 && profiles.rows().front().label() == "hostname", "an external local alias must replace the hostname and external file changes must be reloaded under lock");
  const std::array rename{MachineEdit{.kind = MachineEditKind::rename, .label = "hostname", .value = "local-alias"}};
  bool rejected = false;
  try {
    static_cast<void>(store.change(rename, random, "hostname"));
  } catch (const MachineFailure &failure) {
    require(failure.code() == MachineError::duplicate_label, "renaming to the local alias must retain the original duplicate-label error");
    rejected = true;
  }

  require(rejected && !file.locked && store.load().rows().front().label() == "hostname", "a rejected local-label collision must preserve the saved remote label");
}

void allocationFailureReleasesTheLockBeforeReturning() {
  SystemAllocator system;
  BudgetAllocator memory{system, 0};
  MemoryFile file;
  file.source.assign("{\"version\":1,\"machines\":[]}\n");
  MachineProfileStore store{memory, file};
  Random random;
  bool failed = false;
  try {
    static_cast<void>(store.change({}, random, "local"));
  } catch (const std::bad_alloc &) {
    failed = true;
  }

  require(failed && !file.locked && file.replacements == 0 && memory.liveBytes() == 0, "allocation failure must release the lock and every temporary allocation before returning");
}

}

int main() {
  try {
    batchesCommitEveryEditWithOriginalMetadata();
    rejectedBatchesAndWriteFailuresPreserveTheSavedFile();
    everyTransactionReloadsExternalChangesAndRespectsTheLocalAlias();
    allocationFailureReleasesTheLockBeforeReturning();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
