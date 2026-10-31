#ifndef MACDAILY_TRACKPAD_BRIDGE_H
#define MACDAILY_TRACKPAD_BRIDGE_H
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

CF_ASSUME_NONNULL_BEGIN
typedef struct {
    int32_t identifier;
    double x;
    double y;
} MDTrackpadContact;

typedef struct MDTrackpadMonitor *MDTrackpadMonitorRef;
/// The contact buffer is valid only for the callback. Copy it before returning.
/// Lifecycle methods must be called outside this callback.
typedef void (*MDTrackpadFrameCallback)(void * _Nullable context,
                                      const MDTrackpadContact *contacts,
                                      size_t count, double timestamp);

/// Loads interfaces and enumerates built-in devices, without starting a stream.
MDTrackpadMonitorRef _Nullable MDTrackpadMonitorCreate(MDTrackpadFrameCallback _Nullable callback,
                                                      void * _Nullable context);
bool MDTrackpadMonitorIsAvailable(MDTrackpadMonitorRef monitor);
uint64_t MDTrackpadMonitorDeviceID(MDTrackpadMonitorRef monitor);
CFStringRef MDTrackpadMonitorCopyStatus(MDTrackpadMonitorRef monitor) CF_RETURNS_RETAINED;
bool MDTrackpadMonitorStart(MDTrackpadMonitorRef monitor);
/// Unregisters the callback and waits for callbacks already in progress.
void MDTrackpadMonitorStop(MDTrackpadMonitorRef monitor);
void MDTrackpadMonitorDestroy(MDTrackpadMonitorRef monitor);
CF_ASSUME_NONNULL_END
#endif
