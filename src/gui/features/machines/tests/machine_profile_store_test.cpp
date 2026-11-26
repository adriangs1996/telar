#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

import telar.testing;
import telar.gui.features.machines;
import telar.base.ds;
import telar.gui.foundation.core;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::machines;

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
    telar::ds::Option<telar::ds::Vec<telar::Byte, Memory>> read(Memory& memory) const {
      if (source.view().empty()) {
        return telar::ds::none;
      }

      const auto bytes = telar::byteView(source.view());

      return telar::ds::Vec<telar::Byte, Memory>{memory, bytes};
    }

    class Transaction {
    public:
      explicit Transaction(MemoryFile& file)
          : file_(file) {
        check(!file_.locked, "a profile transaction must not overlap another transaction");
        file_.locked = true;
      }

      ~Transaction() {
        file_.locked = false;
      }

      Transaction(const Transaction&) = delete;
      Transaction& operator=(const Transaction&) = delete;
      Transaction(Transaction&&) = delete;
      Transaction& operator=(Transaction&&) = delete;

      template <Allocator Memory>
      telar::ds::Option<telar::ds::Vec<telar::Byte, Memory>> read(Memory& memory) const {
        check(file_.locked, "transaction reads must hold the file lock");

        return file_.read(memory);
      }

      void replace(std::string_view source) {
        check(file_.locked, "replacement must remain inside the read-change-write lock");
        if (file_.fail_replace) {
          throw std::runtime_error{"Injected profile replacement failure"};
        }

        file_.source.assign(source);
        ++file_.replacements;
      }

    private:
      MemoryFile& file_;
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
    telar::MemoryAdapter erased{memory};
    MachineProfileStore<telar::Memory, MemoryFile> store{erased, file};

    check(store.load().rows().empty(), "a missing profile file must load as an empty list");
    Random random;
    const telar::ds::Array edits{
        MachineEdit{.kind = MachineEditKind::add, .label = "build", .value = "dev@build", .color = "accent"},
        MachineEdit{.kind = MachineEditKind::rename, .label = "build", .value = "gpu"},
        MachineEdit{.kind = MachineEditKind::place_program, .label = "gpu", .value = "/opt/bin/telar"},
        MachineEdit{.kind = MachineEditKind::record_login, .label = "gpu", .value = {}, .login_agent = MachineAgent::codex, .login = MachineLogin::done},
        MachineEdit{.kind = MachineEditKind::disable, .label = "gpu", .value = {}},
    };

    const auto result = store.change(edits, random, "local");

    check(result.rows().size() == 1 && result.rows().front().label() == "gpu", "a committed batch must include the renamed machine");
    check(result.rows().front().destination() == "dev@build" && result.rows().front().program() == "/opt/bin/telar", "a batch must preserve the destination while setting its program path");
    check(result.rows().front().login(MachineAgent::codex) == MachineLogin::done && !result.rows().front().enabled(), "a batch must retain login and enablement edits");
    check(result.rows().front().identity().format().view() == "m-010000000000", "saved identities must come from the injected random source");
    check(file.replacements == 1 && !file.locked, "all edits must reach disk in one replacement before releasing the lock");
    const auto loaded = store.load();

    check(loaded.rows().front().label() == "gpu" && loaded.version() == 2, "committed setup metadata must reload through the original JSON format");
    check(memory.liveBytes() == 0, "profile operations must release every temporary byte");
  }

  void rejectedBatchesAndWriteFailuresPreserveTheSavedFile() {
    SystemAllocator memory;
    MemoryFile file;

    file.source.assign("{\"version\":1,\"machines\":[]}\n");
    const auto original = file.source;
    telar::MemoryAdapter erased{memory};
    MachineProfileStore<telar::Memory, MemoryFile> store{erased, file};
    Random random;
    const telar::ds::Array invalid{
        MachineEdit{.kind = MachineEditKind::add, .label = "valid", .value = "dev@valid"},
        MachineEdit{.kind = MachineEditKind::add, .label = "invalid", .value = "bad host"},
    };

    bool rejected = false;

    try {
      static_cast<void>(store.change(invalid, random, "local"));
    } catch (const MachineFailure& failure) {
      check(failure.code() == MachineError::invalid_destination, "the rejected edit must retain its original validation failure");
      rejected = true;
    }

    check(rejected && file.source.view() == original.view() && file.replacements == 0 && !file.locked, "a rejected later edit must leave the complete saved file untouched and unlock");
    file.fail_replace = true;
    const telar::ds::Array valid{invalid.front()};
    bool failed = false;

    try {
      static_cast<void>(store.change(valid, random, "local"));
    } catch (const std::runtime_error&) {
      failed = true;
    }

    check(failed && !file.locked && file.source.view() == original.view(), "a failed replacement must release the transaction without publishing its staged profiles");
  }

  void everyTransactionReloadsExternalChangesAndRespectsTheLocalAlias() {
    SystemAllocator memory;
    MemoryFile file;
    telar::MemoryAdapter erased{memory};
    MachineProfileStore<telar::Memory, MemoryFile> store{erased, file};
    Random random;
    const telar::ds::Array first{MachineEdit{.kind = MachineEditKind::add, .label = "build", .value = "dev@build"}};

    static_cast<void>(store.change(first, random, "hostname"));
    file.source.assign("{\"version\":1,\"local_label\":\"local-alias\",\"machines\":[]}\n");
    const telar::ds::Array second{MachineEdit{.kind = MachineEditKind::add, .label = "hostname", .value = "dev@other"}};
    const auto profiles = store.change(second, random, "hostname");

    check(profiles.rows().size() == 1 && profiles.rows().front().label() == "hostname", "an external local alias must replace the hostname and external file changes must be reloaded under lock");
    const telar::ds::Array rename{MachineEdit{.kind = MachineEditKind::rename, .label = "hostname", .value = "local-alias"}};
    bool rejected = false;

    try {
      static_cast<void>(store.change(rename, random, "hostname"));
    } catch (const MachineFailure& failure) {
      check(failure.code() == MachineError::duplicate_label, "renaming to the local alias must retain the original duplicate-label error");
      rejected = true;
    }

    check(rejected && !file.locked && store.load().rows().front().label() == "hostname", "a rejected local-label collision must preserve the saved remote label");
  }

  void allocationFailureReleasesTheLockBeforeReturning() {
    SystemAllocator system;
    BudgetAllocator memory{system, 0};
    MemoryFile file;

    file.source.assign("{\"version\":1,\"machines\":[]}\n");
    telar::MemoryAdapter erased{memory};
    MachineProfileStore<telar::Memory, MemoryFile> store{erased, file};
    Random random;
    bool failed = false;

    try {
      static_cast<void>(store.change({}, random, "local"));
    } catch (const std::bad_alloc&) {
      failed = true;
    }

    check(failed && !file.locked && file.replacements == 0 && memory.liveBytes() == 0, "allocation failure must release the lock and every temporary allocation before returning");
  }

  const telar::testing::Case case_batches_commit_every_edit_with_original_metadata{"machine_profile_store.batches_commit_every_edit_with_original_metadata", batchesCommitEveryEditWithOriginalMetadata};
  const telar::testing::Case case_rejected_batches_and_write_failures_preserve_the_saved_file{"machine_profile_store.rejected_batches_and_write_failures_preserve_the_saved_file", rejectedBatchesAndWriteFailuresPreserveTheSavedFile};
  const telar::testing::Case case_every_transaction_reloads_external_changes_and_respects_the_local_alias{"machine_profile_store.every_transaction_reloads_external_changes_and_respects_the_local_alias", everyTransactionReloadsExternalChangesAndRespectsTheLocalAlias};
  const telar::testing::Case case_allocation_failure_releases_the_lock_before_returning{"machine_profile_store.allocation_failure_releases_the_lock_before_returning", allocationFailureReleasesTheLockBeforeReturning};

}
