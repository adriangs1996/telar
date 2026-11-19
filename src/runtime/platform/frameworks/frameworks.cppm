module;
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <Security/Security.h>

export module telar.runtime.platform.frameworks;

// macOS only (MACOS_SOURCES of runtime-platform). The SDK frameworks the runtime reads, and links
// in runtime-settings: CoreFoundation, IOKit's power sources and registry, and Security's keychains. Their
// headers stay in this global module fragment only; importers reach their declarations
// through these using-declarations instead of including them.
export {
  // CoreFoundation types and the calls that create, inspect and release them.
  using ::CFArrayRef;
  using ::CFDataRef;
  using ::CFDictionaryRef;
  using ::CFIndex;
  using ::CFNumberRef;
  using ::CFStringRef;
  using ::CFTypeRef;

  using ::CFArrayCreate;
  using ::CFArrayGetCount;
  using ::CFArrayGetTypeID;
  using ::CFArrayGetValueAtIndex;
  using ::CFDataGetBytePtr;
  using ::CFDataGetLength;
  using ::CFDictionaryCreate;
  using ::CFDictionaryGetTypeID;
  using ::CFDictionaryGetValue;
  using ::CFGetTypeID;
  using ::CFNumberGetTypeID;
  using ::CFNumberGetValue;
  using ::CFRelease;

  using ::kCFAllocatorDefault;
  using ::kCFBooleanTrue;
  using ::kCFNumberSInt32Type;
  using ::kCFNumberSInt64Type;
  using ::kCFTypeArrayCallBacks;
  using ::kCFTypeDictionaryKeyCallBacks;
  using ::kCFTypeDictionaryValueCallBacks;

  // IOKit power sources.
  using ::IOPSCopyPowerSourcesInfo;
  using ::IOPSCopyPowerSourcesList;
  using ::IOPSGetPowerSourceDescription;

  // The IOKit registry, for the block storage drivers' statistics.
  using ::CFMutableDictionaryRef;
  using ::io_iterator_t;
  using ::io_object_t;
  using ::IOIteratorNext;
  using ::IOObjectRelease;
  using ::IORegistryEntryCreateCFProperties;
  using ::IOServiceGetMatchingServices;
  using ::IOServiceMatching;
  using ::kIOMainPortDefault;

  // Security keychains and certificates.
  using ::SecCertificateRef;
  using ::SecKeychainRef;

  using ::SecCertificateCopyData;
  using ::SecCertificateGetTypeID;
  using ::SecItemCopyMatching;
  using ::SecKeychainOpen;

  using ::errSecItemNotFound;
  using ::errSecSuccess;
  using ::kSecClass;
  using ::kSecClassCertificate;
  using ::kSecMatchLimit;
  using ::kSecMatchLimitAll;
  using ::kSecMatchSearchList;
  using ::kSecReturnRef;
  using ::kSecUseAuthenticationUI;
  using ::kSecUseAuthenticationUISkip;
}

// IOBlockStorageDriver.h is a kernel header; these are the keys it names for user space.
export namespace telar::runtime::block_storage_keys {
  inline constexpr const char* driver_class = "IOBlockStorageDriver";
  inline const CFStringRef statistics = CFSTR("Statistics");
  inline const CFStringRef bytes_read = CFSTR("Bytes (Read)");
  inline const CFStringRef bytes_written = CFSTR("Bytes (Write)");
}

// IOPSKeys.h spells its keys as string macros for CFSTR, and neither crosses an import.
export namespace telar::runtime::power_source_keys {
  inline const CFStringRef current_capacity = CFSTR(kIOPSCurrentCapacityKey);
  inline const CFStringRef max_capacity = CFSTR(kIOPSMaxCapacityKey);
}
