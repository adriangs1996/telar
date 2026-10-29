#pragma once

#include "application/dependencies.hpp"
#include "machines/edit.hpp"
#include "machines/owned_edit.hpp"
#include "machines/profiles.hpp"
#include "platform/file_stamp.hpp"
#include <QByteArray>
#include <QFutureWatcher>
#include <QObject>
#include <QString>
#include <QTimer>
#include <cstdint>
#include <optional>
#include <stop_token>

namespace telar::gui::qt {

class MachineProfilesSource final : public QObject {
  Q_OBJECT

public:
  explicit MachineProfilesSource(ApplicationAllocator &memory, QObject *parent = nullptr);
  ~MachineProfilesSource() override;
  MachineProfilesSource(const MachineProfilesSource &) = delete;
  MachineProfilesSource &operator=(const MachineProfilesSource &) = delete;
  MachineProfilesSource(MachineProfilesSource &&) = delete;
  MachineProfilesSource &operator=(MachineProfilesSource &&) = delete;

  void open(const QString &path, const QString &local_label);
  void poll();
  bool edit(const MachineEdit &edit);
  [[nodiscard]] const MachineProfiles &profiles() const noexcept;
  [[nodiscard]] const QString &error() const noexcept;
  [[nodiscard]] bool editing() const noexcept;
  [[nodiscard]] bool busy() const noexcept;
  [[nodiscard]] bool loaded() const noexcept;
  [[nodiscard]] std::uint64_t revision() const noexcept;

signals:
  void changed();
  void failed();
  void editingChanged();

private:
  struct Request {
    QByteArray path;
    QByteArray local_label;
    std::optional<platform::FileStamp> known;
    std::optional<OwnedMachineEdit> edit;
    std::stop_token stop;
    std::uint64_t generation = 0;
    bool force = false;
  };

  struct Result {
    std::optional<MachineProfiles> profiles;
    std::optional<platform::FileStamp> observed;
    QString error;
    std::uint64_t generation = 0;
    bool cancelled = false;
  };

  [[nodiscard]] static Result prepare(ApplicationAllocator &memory, const Request &request);
  void start();
  void complete();
  void fail(QString message);

  ApplicationAllocator &memory_;
  QTimer poll_;
  QFutureWatcher<Result> task_;
  std::stop_source cancellation_;
  QByteArray path_;
  QByteArray local_label_;
  std::optional<platform::FileStamp> known_;
  std::optional<OwnedMachineEdit> pending_edit_;
  MachineProfiles profiles_;
  QString error_;
  std::uint64_t generation_ = 0;
  std::uint64_t revision_ = 0;
  bool loaded_ = false;
  bool busy_ = false;
  bool editing_ = false;
  bool reopen_pending_ = false;
  bool rescan_pending_ = false;
};

}
