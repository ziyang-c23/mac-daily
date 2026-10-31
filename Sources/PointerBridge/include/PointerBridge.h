#ifndef MACDAILY_POINTER_BRIDGE_H
#define MACDAILY_POINTER_BRIDGE_H
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN
/// Read-only metadata monitoring. No IOHIDDeviceOpen and no input-monitoring grant.
typedef struct MDPointerMonitor *MDPointerMonitorRef;
typedef void (*MDPointerChangeCallback)(void * _Nullable context);
MDPointerMonitorRef _Nullable MDPointerMonitorCreate(MDPointerChangeCallback _Nullable callback, void * _Nullable context);
void MDPointerMonitorDestroy(MDPointerMonitorRef monitor);
void MDPointerMonitorRefresh(MDPointerMonitorRef monitor);
CFArrayRef MDPointerCopyDevices(MDPointerMonitorRef monitor) CF_RETURNS_RETAINED;
CFStringRef MDPointerCopyStatus(MDPointerMonitorRef monitor) CF_RETURNS_RETAINED;
/// Applies settings only to positively identified external mice, never a global setting.
int MDPointerApply(MDPointerMonitorRef monitor, double speedRatio, double acceleration, bool disableAcceleration);
/// Restores captured values when still owned; external changes are not overwritten.
int MDPointerRestore(MDPointerMonitorRef monitor);
bool MDPointerAttributionAvailable(void);
/// Pure event metadata extraction; no registry enumeration or property IO.
uint64_t MDPointerEventSenderID(CGEventRef event);
CF_ASSUME_NONNULL_END
#endif
