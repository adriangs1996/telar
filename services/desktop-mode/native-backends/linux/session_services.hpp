#pragma once

#include <QObject>
#include <QStringList>
#include <QTimer>
#include <memory>
#include <vector>

namespace linux_desktop {
  class SessionServices final : public QObject {
  public:
    static void prepare(bool standalone);
    explicit SessionServices(bool standalone);
    ~SessionServices() override;
    void lock();

  private:
    struct Child;
    std::vector<std::unique_ptr<Child>> processes_;
    Child *locker_ = nullptr;
    QTimer reap_timer_;
    QString lock_command_;
    bool enabled_ = false;
    Child *start(QString program, QStringList arguments = {});
    void startServices();
  };
} // namespace linux_desktop
