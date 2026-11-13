#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "machine_profiles_source.hpp"
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
#include "../core/memory.hpp"
#include "telar_base/memory/allocator.hpp"
#include <exception>
#include <bit>
#include <limits>
#include <new>
#include "telar_client/codecs/telar_wire.hpp"
#include <sys/stat.h>
#include <sys/param.h>
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <limits.h>
#include <stop_token>
#include <QFuture>
#include <QString>
#include <QtConcurrentRun>
#include <QtCore/qlogging.h>
#include <QtCore/qobject.h>
#include <QtCore/qtimer.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <utility>

#include "application/dependencies.hpp"


import telar.gui.machines.profile_store;
import telar.gui.machines.discovery;
import telar.gui.platform.profile_file;
import telar.gui.platform.private_file_stamp;

namespace telar::gui::qt {

namespace {

std::string_view textView(const QByteArray &text) noexcept {
  return {text.constData(), static_cast<std::size_t>(text.size())};
}

QString errorText(std::string_view text) {
  return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
}

}

static_assert(ConcurrentAllocator<ApplicationAllocator>);

MachineProfilesSource::MachineProfilesSource(ApplicationAllocator &memory, QObject *parent)
    : QObject(parent),
      memory_(memory) {
  constexpr int poll_interval_ms = 1000;
  poll_.setInterval(poll_interval_ms);
  connect(&poll_, &QTimer::timeout, this, &MachineProfilesSource::poll);
  connect(&task_, &QFutureWatcher<Result>::finished, this, &MachineProfilesSource::complete);
}

MachineProfilesSource::~MachineProfilesSource() {
  cancellation_.request_stop();
  task_.disconnect(this);
  auto future = task_.future();
  if (!future.isValid()) {
    return;
  }

  try {
    future.waitForFinished();
    if (future.resultCount() != 0) {
      static_cast<void>(future.takeResult());
    }
  } catch (const std::exception &error) {
    qWarning("Machine profile worker failed during shutdown: %s", error.what());
  }
}

void MachineProfilesSource::open(const QString &path, const QString &local_label) {
  cancellation_.request_stop();
  path_ = path.toUtf8();
  local_label_ = local_label.toUtf8();
  ++generation_;
  known_.reset();
  pending_edit_.reset();
  profiles_ = {};
  error_.clear();
  loaded_ = false;
  rescan_pending_ = false;
  reopen_pending_ = true;
  ++revision_;
  poll_.start();
  emit changed();
  emit editingChanged();
  if (!busy_) {
    start();
  }
}

void MachineProfilesSource::poll() {
  if (!busy_ && !path_.isEmpty()) {
    start();
  }
}

bool MachineProfilesSource::edit(const MachineEdit &edit) {
  if (editing()) {
    fail(errorText(MachineProfileMessages::edit_pending), FailureSource::edit);

    return false;
  }

  if (path_.isEmpty()) {
    fail(QStringLiteral("Machine profile path is unavailable"), FailureSource::edit);

    return false;
  }

  try {
    pending_edit_ = OwnedMachineEdit::copy(edit);
  } catch (const MachineFailure &failure) {
    fail(errorText(MachineProfileMessages::failure(failure.code())), FailureSource::edit);

    return false;
  }

  emit editingChanged();
  if (!busy_) {
    start();
  }

  return true;
}

const MachineProfiles &MachineProfilesSource::profiles() const noexcept {
  return profiles_;
}

const QString &MachineProfilesSource::error() const noexcept {
  return error_;
}

bool MachineProfilesSource::editError() const noexcept {
  return failure_source_ == FailureSource::edit;
}

bool MachineProfilesSource::editing() const noexcept {
  return editing_ || pending_edit_.has_value();
}

bool MachineProfilesSource::loaded() const noexcept {
  return loaded_;
}

bool MachineProfilesSource::busy() const noexcept {
  return busy_;
}

std::uint64_t MachineProfilesSource::revision() const noexcept {
  return revision_;
}

MachineProfilesSource::Result MachineProfilesSource::prepare(ApplicationAllocator &memory, const Request &request) {
  Result result{.profiles = std::nullopt, .observed = platform::FileStamp::read(request.path.constData(), platform::FileSymlinks::inspect), .error = {}, .generation = request.generation};
  if (!request.edit && !request.force && result.observed == request.known) {
    return result;
  }

  try {
    if (request.stop.stop_requested()) {
      throw platform::ProfileOperationCancelled{};
    }

    platform::ProfileFile file{textView(request.path), request.stop};
    MachineProfileStore store{memory, file};
    if (request.edit) {
      platform::SecureRandom random;
      const std::array edits{request.edit->view()};
      result.profiles = store.change(edits, random, textView(request.local_label));
    } else {
      result.profiles = store.load();
    }
  } catch (const platform::ProfileOperationCancelled &) {
    result.cancelled = true;
  } catch (const platform::InsecureProfileFile &) {
    result.error = errorText(MachineProfileMessages::insecure_file);
  } catch (const MachineFailure &failure) {
    result.error = errorText(MachineProfileMessages::failure(failure.code()));
  } catch (const std::exception &error) {
    result.error = QString::fromUtf8(error.what());
  }

  return result;
}

void MachineProfilesSource::start() {
  if (busy_) {
    return;
  }

  const auto failure_source = pending_edit_ ? FailureSource::edit : FailureSource::profile;
  try {
    cancellation_ = std::stop_source{};
    Request request{
        .path = path_,
        .local_label = local_label_,
        .known = known_,
        .edit = std::move(pending_edit_),
        .stop = cancellation_.get_token(),
        .generation = generation_,
        .force = !loaded_ || rescan_pending_,
    };
    pending_edit_.reset();
    busy_ = true;
    editing_ = request.edit.has_value();
    reopen_pending_ = false;
    task_.setFuture(QtConcurrent::run([memory = &memory_, request = std::move(request)] {
      return prepare(*memory, request);
    }));
  } catch (const std::exception &error) {
    busy_ = false;
    editing_ = false;
    pending_edit_.reset();
    fail(QString::fromUtf8(error.what()), failure_source);
    emit editingChanged();
  }
}

void MachineProfilesSource::complete() {
  const auto was_editing = editing_;
  busy_ = false;
  editing_ = false;
  try {
    auto future = task_.future();
    auto result = future.takeResult();
    if (result.generation == generation_ && !result.cancelled) {
      known_ = result.observed;
      loaded_ = true;
      rescan_pending_ = was_editing;
      if (result.profiles) {
        profiles_ = *result.profiles;
        error_.clear();
        ++revision_;
        emit changed();
      }

      if (!result.error.isEmpty()) {
        fail(std::move(result.error), was_editing ? FailureSource::edit : FailureSource::profile);
      }
    }
  } catch (const std::exception &error) {
    fail(QString::fromUtf8(error.what()), was_editing ? FailureSource::edit : FailureSource::profile);
  }

  if (was_editing) {
    emit editingChanged();
  }

  if (pending_edit_ || reopen_pending_) {
    start();
  }
}

void MachineProfilesSource::fail(QString message, FailureSource source) {
  failure_source_ = source;
  error_ = std::move(message);
  emit failed();
}

}
