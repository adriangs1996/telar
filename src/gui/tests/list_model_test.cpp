#include "list_model.hpp"
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

namespace {

using telar::gui::qt::ListModel;

void require(bool condition, const char *message) {
  if (!condition) {
    std::cerr << message << '\n';
    std::exit(EXIT_FAILURE);
  }
}

QVariantMap record(int key, int revision) {
  return {
      {QStringLiteral("key"), QString::number(key)},
      {QStringLiteral("command"), QStringLiteral("echo row %1 revision %2").arg(key).arg(revision)},
      {QStringLiteral("details"), QVariantMap{{QStringLiteral("revision"), revision}}},
  };
}

void snapshotNotificationsPreservePositions() {
  ListModel model;
  QAbstractItemModelTester tester{&model, QAbstractItemModelTester::FailureReportingMode::Fatal};
  const QSignalSpy inserted{&model, &QAbstractItemModel::rowsInserted};
  const QSignalSpy removed{&model, &QAbstractItemModel::rowsRemoved};
  const QSignalSpy changed{&model, &QAbstractItemModel::dataChanged};
  const QSignalSpy moved{&model, &QAbstractItemModel::rowsMoved};
  const QSignalSpy reset{&model, &QAbstractItemModel::modelReset};
  const QList<QVariantMap> initial{record(1, 0), record(2, 0), record(3, 0)};
  model.replaceRows(initial);
  require(inserted.size() == 1 && inserted.front()[1].toInt() == 0 && inserted.front()[2].toInt() == 2, "Initial rows must be inserted as one range");
  const QPersistentModelIndex position{model.index(1)};
  const QPersistentModelIndex tail{model.index(2)};
  model.replaceRows(initial);
  require(changed.empty() && removed.empty() && inserted.size() == 1, "An identical snapshot must not notify views");
  model.replaceRows({record(1, 0), record(8, 1), record(9, 1)});
  require(changed.size() == 1 && changed.front()[0].value<QModelIndex>().row() == 1 && changed.front()[1].value<QModelIndex>().row() == 2, "Changed records must notify one bounded range");
  require(changed.front()[2].value<QList<int>>() == QList<int>{ListModel::record_role}, "Only the record role changes");
  require(position.isValid() && position.row() == 1 && position.data(ListModel::record_role).toMap() == record(8, 1), "A snapshot persistent index must identify its position");
  require(inserted.size() == 1 && removed.empty() && moved.empty() && reset.empty(), "Replacing equal-sized snapshots must retain delegates without structural notifications");
  model.replaceRows({record(9, 1), record(8, 1)});
  require(removed.size() == 1 && removed.front()[1].toInt() == 2 && removed.front()[2].toInt() == 2, "Shrinking removes only the suffix");
  require(position.isValid() && !tail.isValid(), "Shrinking must invalidate only removed positions");
  model.replaceRows({});
  require(model.rowCount() == 0 && !position.isValid(), "An empty snapshot must retire every position");
}

void snapshotsMatchKeyedReconciliation() {
  constexpr int maximum_rows = 100;
  constexpr int identity_count = maximum_rows * 2;
  constexpr int trials = 4096;
  ListModel reference;
  ListModel candidate;
  QAbstractItemModelTester tester{&candidate, QAbstractItemModelTester::FailureReportingMode::Fatal};
  std::mt19937 random{0x28b4c31};
  std::vector<int> identities(identity_count);
  std::iota(identities.begin(), identities.end(), 0);
  for (int trial = 0; trial < trials; ++trial) {
    std::shuffle(identities.begin(), identities.end(), random);
    const auto count = static_cast<int>(random() % (maximum_rows + 1));
    QList<QVariantMap> incoming;
    for (int row = 0; row < count; ++row) {
      incoming.append(record(identities[row], static_cast<int>(random() % 4)));
    }

    reference.reconcile(incoming);
    candidate.replaceRows(incoming);
    require(reference.rowCount() == candidate.rowCount(), "Snapshot and keyed reference counts differ");
    for (int row = 0; row < count; ++row) {
      require(reference.data(reference.index(row), ListModel::record_role) == candidate.data(candidate.index(row), ListModel::record_role), "Snapshot and keyed reference records differ");
    }

    const QSignalSpy unchanged{&candidate, &QAbstractItemModel::dataChanged};
    candidate.replaceRows(incoming);
    require(unchanged.empty(), "Repeated random snapshots must not notify views");
  }
}

}

int main(int argc, char **argv) {
  QCoreApplication application{argc, argv};
  snapshotNotificationsPreservePositions();
  snapshotsMatchKeyedReconciliation();
  std::cout << "Snapshot model: 4096 reference cases and notification contracts passed\n";
}
