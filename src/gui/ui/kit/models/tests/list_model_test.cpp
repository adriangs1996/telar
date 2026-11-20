#include "ui/kit/models/list_model.hpp"
#include <QAbstractItemModelTester>
#include <QCoreApplication>
#include <QPersistentModelIndex>
#include <QSignalSpy>
#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <numeric>
#include <random>
#include <vector>

import telar.testing;

namespace {

  using telar::gui::qt::ListModel;
  using telar::testing::check;

  QVariantMap record(int key, int revision) {
    return {
        {QStringLiteral("key"), QString::number(key)},
        {QStringLiteral("command"), QStringLiteral("echo row %1 revision %2").arg(key).arg(revision)},
        {QStringLiteral("details"), QVariantMap{{QStringLiteral("revision"), revision}}},
    };
  }

  void snapshotNotificationsPreservePositions() {
    ListModel model;
    const QAbstractItemModelTester tester{&model, QAbstractItemModelTester::FailureReportingMode::Fatal};
    const QSignalSpy inserted{&model, &QAbstractItemModel::rowsInserted};
    const QSignalSpy removed{&model, &QAbstractItemModel::rowsRemoved};
    const QSignalSpy changed{&model, &QAbstractItemModel::dataChanged};
    const QSignalSpy moved{&model, &QAbstractItemModel::rowsMoved};
    const QSignalSpy reset{&model, &QAbstractItemModel::modelReset};
    const QList<QVariantMap> initial{record(1, 0), record(2, 0), record(3, 0)};
    // The keys that take the second and third rows' places.
    constexpr int second_replacement = 8;
    constexpr int third_replacement = 9;

    model.replaceRows(initial);
    check(inserted.size() == 1 && inserted.front()[1].toInt() == 0 && inserted.front()[2].toInt() == 2, "Initial rows must be inserted as one range");
    const QPersistentModelIndex position{model.index(1)};
    const QPersistentModelIndex tail{model.index(2)};

    model.replaceRows(initial);
    check(changed.empty() && removed.empty() && inserted.size() == 1, "An identical snapshot must not notify views");
    model.replaceRows({record(1, 0), record(second_replacement, 1), record(third_replacement, 1)});
    check(changed.size() == 1 && changed.front()[0].value<QModelIndex>().row() == 1 && changed.front()[1].value<QModelIndex>().row() == 2, "Changed records must notify one bounded range");
    check(changed.front()[2].value<QList<int>>() == QList<int>{ListModel::record_role}, "Only the record role changes");
    check(position.isValid() && position.row() == 1 && position.data(ListModel::record_role).toMap() == record(second_replacement, 1), "A snapshot persistent index must identify its position");
    check(inserted.size() == 1 && removed.empty() && moved.empty() && reset.empty(), "Replacing equal-sized snapshots must retain delegates without structural notifications");
    model.replaceRows({record(third_replacement, 1), record(second_replacement, 1)});
    check(removed.size() == 1 && removed.front()[1].toInt() == 2 && removed.front()[2].toInt() == 2, "Shrinking removes only the suffix");
    check(position.isValid() && !tail.isValid(), "Shrinking must invalidate only removed positions");
    model.replaceRows({});
    check(model.rowCount() == 0 && !position.isValid(), "An empty snapshot must retire every position");
  }

  void snapshotsMatchKeyedReconciliation() {
    constexpr int maximum_rows = 100;
    constexpr int identity_count = maximum_rows * 2;
    constexpr int trials = 4096;
    ListModel reference;
    ListModel candidate;
    const QAbstractItemModelTester tester{&candidate, QAbstractItemModelTester::FailureReportingMode::Fatal};
    constexpr std::mt19937::result_type seed = 0x28b4c31;
    std::mt19937 random{seed}; // NOLINT(bugprone-random-generator-seed,cert-msc32-c,cert-msc51-cpp): a fixed seed keeps every run's snapshots reproducible.
    std::vector<int> identities(identity_count);

    std::ranges::iota(identities, 0);
    for (int trial = 0; trial < trials; ++trial) {
      std::ranges::shuffle(identities, random);
      const auto count = static_cast<int>(random() % (maximum_rows + 1));
      QList<QVariantMap> incoming;

      for (int row = 0; row < count; ++row) {
        incoming.append(record(identities[row], static_cast<int>(random() % 4)));
      }

      reference.reconcile(incoming);
      candidate.replaceRows(incoming);
      check(reference.rowCount() == candidate.rowCount(), "Snapshot and keyed reference counts differ");
      for (int row = 0; row < count; ++row) {
        check(reference.data(reference.index(row), ListModel::record_role) == candidate.data(candidate.index(row), ListModel::record_role), "Snapshot and keyed reference records differ");
      }

      const QSignalSpy unchanged{&candidate, &QAbstractItemModel::dataChanged};

      candidate.replaceRows(incoming);
      check(unchanged.empty(), "Repeated random snapshots must not notify views");
    }
  }

  const telar::testing::Case case_snapshot_notifications{"list_model.snapshot_notifications_preserve_positions", snapshotNotificationsPreservePositions};
  const telar::testing::Case case_keyed_reconciliation{"list_model.snapshots_match_keyed_reconciliation", snapshotsMatchKeyedReconciliation};

}
