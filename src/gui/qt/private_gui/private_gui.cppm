module;
#include <QtGui/qpa/qwindowsysteminterface.h>
#include <QtGui/qpa/qwindowsysteminterface_p.h>
#include <rhi/qrhi.h>

export module telar.gui.qt.private_gui;

export {
  using ::QRhi;
  using ::QRhiResourceUpdateBatch;
  using ::QRhiTexture;
  using ::QWindowSystemEventHandler;
  using ::QWindowSystemInterface;
  using ::QWindowSystemInterfacePrivate;
}
