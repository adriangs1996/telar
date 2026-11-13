#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../application/dependencies.hpp"
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
#include <sys/stat.h>
#include <QByteArray>
#include <QFutureWatcher>
#include <QObject>
#include <QString>
#include <QTimer>
#include <stop_token>

#pragma once

#include "application/dependencies.hpp"


import telar.gui.machines.profile_store;
import telar.gui.platform.profile_file;

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
  [[nodiscard]] bool editError() const noexcept;
  [[nodiscard]] bool busy() const noexcept;
  [[nodiscard]] bool loaded() const noexcept;
  [[nodiscard]] std::uint64_t revision() const noexcept;

signals:
  void changed();
  void failed();
  void editingChanged();

private:
  enum class FailureSource : std::uint8_t {
    profile,
    edit,
  };

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
  void fail(QString message, FailureSource source = FailureSource::profile);

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
  FailureSource failure_source_ = FailureSource::profile;
  bool reopen_pending_ = false;
  bool rescan_pending_ = false;
};

}
