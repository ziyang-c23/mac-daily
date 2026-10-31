// MacDaily's dynamically loaded HID adapter.
// Property semantics informed by LinearMouse PointerKit (MIT, copyright 2021–2026
// LinearMouse). No linked third-party binary or copied implementation is required.
#include "PointerBridge.h"
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef CFTypeRef (*CreateClientFn)(CFAllocatorRef);
typedef CFArrayRef (*CopyServicesFn)(CFTypeRef);
typedef CFTypeRef (*CopyPropertyFn)(CFTypeRef, CFStringRef);
typedef Boolean (*SetPropertyFn)(CFTypeRef, CFStringRef, CFTypeRef);
typedef CFTypeRef (*RegistryIDFn)(CFTypeRef);
typedef boolean_t (*ConformsFn)(CFTypeRef, uint32_t, uint32_t);
typedef CFTypeRef (*CopyEventFn)(CGEventRef);
typedef uint64_t (*SenderFn)(CFTypeRef);
static CreateClientFn createClient;
static CopyServicesFn copyServices;
static CopyPropertyFn copyProperty;
static SetPropertyFn setProperty;
static RegistryIDFn registryID;
static ConformsFn conforms;
static CopyEventFn copyEvent;
static SenderFn eventSender;
static dispatch_once_t symbolOnce;

static void loadSymbols(void) {
    dispatch_once(&symbolOnce, ^{
        // Frameworks stay loaded for the process lifetime; event-thread function
        // pointers must remain valid after a settings window has been closed.
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_GLOBAL);
        dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_GLOBAL);
        createClient = (CreateClientFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        if (!createClient) createClient = (CreateClientFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateSimpleClient");
        copyServices = (CopyServicesFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
        copyProperty = (CopyPropertyFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
        setProperty = (SetPropertyFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientSetProperty");
        registryID = (RegistryIDFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetRegistryID");
        conforms = (ConformsFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientConformsTo");
        copyEvent = (CopyEventFn)dlsym(RTLD_DEFAULT, "CGEventCopyIOHIDEvent");
        eventSender = (SenderFn)dlsym(RTLD_DEFAULT, "IOHIDEventGetSenderID");
    });
}

typedef struct {
    CFTypeRef service;
    uint64_t identifier;
    int kind; // 0 unknown, 1 external mouse, 2 touch device
    CFStringRef name;
    CFMutableDictionaryRef original;
    CFMutableDictionaryRef written;
} MDDevice;

struct MDPointerMonitor {
    CFTypeRef client;
    MDDevice *devices;
    size_t count;
    IONotificationPortRef notificationPort;
    io_iterator_t addedIterator;
    io_iterator_t removedIterator;
    CFRunLoopTimerRef refreshTimer;
    MDPointerChangeCallback callback;
    void *context;
    CFStringRef status;
    bool refreshing;
};

static void statusSet(MDPointerMonitorRef m, CFStringRef s) {
    if (m->status) CFRelease(m->status);
    m->status = CFRetain(s);
}
static bool numberValue(CFTypeRef value, double *out) {
    if (!value) return false;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) { *out = CFBooleanGetValue(value) ? 1 : 0; return true; }
    return CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue(value, kCFNumberDoubleType, out);
}
static double numericProperty(CFTypeRef service, CFStringRef key, double fallback) {
    CFTypeRef value = copyProperty(service, key); double result = fallback;
    numberValue(value, &result); if (value) CFRelease(value); return result;
}
static bool contains(CFStringRef text, CFStringRef term) {
    return text && CFStringFind(text, term, kCFCompareCaseInsensitive).location != kCFNotFound;
}
static uint64_t serviceIdentifier(CFTypeRef service) {
    CFTypeRef value = registryID(service); int64_t result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberSInt64Type, &result);
    return (uint64_t)result; // GetRegistryID is not retained.
}
static int classify(CFTypeRef service, CFStringRef name) {
    bool pointer = conforms(service, 1, 2) || conforms(service, 1, 1);
    bool digitizer = conforms(service, 13, 5) || conforms(service, 13, 4);
    if (digitizer || contains(name, CFSTR("trackpad")) || contains(name, CFSTR("magic mouse"))) return 2;
    if (!pointer) return 0;
    if (!name || contains(name, CFSTR("virtual")) || contains(name, CFSTR("karabiner")) || contains(name, CFSTR("synergy"))) return 0;
    if (numericProperty(service, CFSTR("Built-In"), 0) != 0) return 2;
    // Composite BLE keyboards can advertise mouse usages too (the local NuPhy
    // does). A zero/absent hardware identity is not sufficient evidence for
    // rewriting pointer input. Unknown devices keep their native behavior.
    if (numericProperty(service, CFSTR("VendorID"), 0) <= 0 || numericProperty(service, CFSTR("ProductID"), 0) <= 0) return 0;
    if (contains(name, CFSTR("keyboard"))) return 0;
    return 1;
}
static void deviceRelease(MDDevice *d) {
    if (d->service) CFRelease(d->service);
    if (d->name) CFRelease(d->name);
    if (d->original) CFRelease(d->original);
    if (d->written) CFRelease(d->written);
    memset(d, 0, sizeof(*d));
}
// Returns number of values that could not be restored. Always leaves unresolved
// values in the dictionaries so pause/quit may retry a transient write failure.
static int restoreDevice(MDDevice *d) {
    if (!d->original || !d->written || !setProperty) return 0;
    CFIndex count = CFDictionaryGetCount(d->original);
    const void **keys = calloc((size_t)count, sizeof(void *));
    const void **values = calloc((size_t)count, sizeof(void *));
    if (count && (!keys || !values)) { free(keys); free(values); return (int)count; }
    CFDictionaryGetKeysAndValues(d->original, keys, values);
    int failed = 0;
    // Resolution first, acceleration next, linear mode last, so HID recalculates
    // its acceleration curve after the resolution is restored.
    CFStringRef ordered[3] = {CFSTR("HIDPointerResolution"), NULL, CFSTR("HIDUseLinearScalingMouseAcceleration")};
    for (CFIndex i=0;i<count;i++) if (!CFEqual(keys[i], ordered[0]) && !CFEqual(keys[i], ordered[2])) ordered[1] = keys[i];
    for (int index=0;index<3;index++) {
        CFStringRef key = ordered[index]; if (!key) continue;
        CFTypeRef original = CFDictionaryGetValue(d->original, key);
        CFTypeRef written = CFDictionaryGetValue(d->written, key);
        if (!original || !written) continue;
        CFTypeRef current = copyProperty(d->service, key);
        if (current && CFEqual(current, original)) {
            CFDictionaryRemoveValue(d->written, key);
        } else if (current && CFEqual(current, written)) {
            if (setProperty(d->service, key, original)) CFDictionaryRemoveValue(d->written, key);
            else failed++;
        } else if (current) {
            // Another app or the user changed this property; relinquish ownership.
            CFDictionaryRemoveValue(d->written, key);
        } else failed++;
        if (current) CFRelease(current);
    }
    free(keys); free(values);
    if (CFDictionaryGetCount(d->written) == 0) { CFRelease(d->original); d->original = NULL; CFRelease(d->written); d->written = NULL; }
    return failed;
}

void MDPointerMonitorRefresh(MDPointerMonitorRef m) {
    if (!m || m->refreshing) return;
    m->refreshing = true;
    CFArrayRef services = copyServices(m->client);
    if (!services) { m->refreshing = false; return; }
    size_t capacity = (size_t)CFArrayGetCount(services);
    MDDevice *next = capacity ? calloc(capacity, sizeof(MDDevice)) : NULL;
    if (capacity && !next) { CFRelease(services); m->refreshing = false; return; }
    size_t nextCount = 0;
    for (CFIndex i=0;i<(CFIndex)capacity;i++) {
        CFTypeRef service = CFArrayGetValueAtIndex(services, i);
        uint64_t identifier = serviceIdentifier(service); if (!identifier) continue;
        CFTypeRef product = copyProperty(service, CFSTR("Product"));
        CFStringRef name = product && CFGetTypeID(product) == CFStringGetTypeID() ? product : NULL;
        int kind = classify(service, name);
        if (kind == 0) { if (product) CFRelease(product); continue; }
        MDDevice *d = &next[nextCount++];
        d->service = CFRetain(service); d->identifier = identifier; d->kind = kind;
        d->name = CFRetain(name ?: CFSTR("触控设备"));
        for (size_t old=0;old<m->count;old++) if (m->devices[old].identifier == identifier) {
            // Registry IDs identify one connection lifetime, not just a model.
            d->original = m->devices[old].original; m->devices[old].original = NULL;
            d->written = m->devices[old].written; m->devices[old].written = NULL;
            break;
        }
        if (product) CFRelease(product);
    }
    for (size_t i=0;i<m->count;i++) { restoreDevice(&m->devices[i]); deviceRelease(&m->devices[i]); }
    free(m->devices); m->devices = next; m->count = nextCount;
    CFRelease(services); m->refreshing = false;
    if (m->callback) m->callback(m->context);
}

static void refreshTimerFired(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    MDPointerMonitorRef m = context;
    if (m->refreshTimer) { CFRelease(m->refreshTimer); m->refreshTimer = NULL; }
    MDPointerMonitorRefresh(m);
}
static void deviceTopologyChanged(void *context, io_iterator_t iterator) {
    io_object_t item;
    while ((item = IOIteratorNext(iterator))) IOObjectRelease(item);
    MDPointerMonitorRef m = context;
    if (m->refreshTimer) { CFRunLoopTimerInvalidate(m->refreshTimer); CFRelease(m->refreshTimer); }
    CFRunLoopTimerContext timerContext = {0, m, NULL, NULL, NULL};
    // A single delayed refresh after topology changes lets HID publish its child
    // event service. This is not a periodic polling timer or an input callback.
    m->refreshTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent()+0.25, 0, 0, 0, refreshTimerFired, &timerContext);
    CFRunLoopAddTimer(CFRunLoopGetMain(), m->refreshTimer, kCFRunLoopCommonModes);
}

MDPointerMonitorRef MDPointerMonitorCreate(MDPointerChangeCallback callback, void *context) {
    loadSymbols();
    if (!createClient || !copyServices || !copyProperty || !registryID || !conforms) return NULL;
    CFTypeRef client = createClient(kCFAllocatorDefault); if (!client) return NULL;
    MDPointerMonitorRef m = calloc(1,sizeof(struct MDPointerMonitor));
    if (!m) { CFRelease(client); return NULL; }
    m->client = client; m->context = context;
    statusSet(m, CFSTR("指针保持系统设置"));
    MDPointerMonitorRefresh(m);
    m->callback = callback;
    if (callback) {
        m->notificationPort = IONotificationPortCreate(kIOMainPortDefault);
        if (m->notificationPort) {
            CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(m->notificationPort);
            if (source) CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
            kern_return_t add = IOServiceAddMatchingNotification(m->notificationPort, kIOFirstMatchNotification,
                IOServiceMatching("IOHIDDevice"), deviceTopologyChanged, m, &m->addedIterator);
            if (add == KERN_SUCCESS) deviceTopologyChanged(m, m->addedIterator);
            kern_return_t remove = IOServiceAddMatchingNotification(m->notificationPort, kIOTerminatedNotification,
                IOServiceMatching("IOHIDDevice"), deviceTopologyChanged, m, &m->removedIterator);
            if (remove == KERN_SUCCESS) deviceTopologyChanged(m, m->removedIterator);
        }
    }
    return m;
}

CFArrayRef MDPointerCopyDevices(MDPointerMonitorRef m) {
    CFMutableArrayRef result = CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    for (size_t i=0;i<m->count;i++) {
        MDDevice *d = &m->devices[i];
        CFNumberRef identifier = CFNumberCreate(NULL,kCFNumberSInt64Type,&d->identifier);
        CFNumberRef kind = CFNumberCreate(NULL,kCFNumberIntType,&d->kind);
        CFBooleanRef builtIn = numericProperty(d->service, CFSTR("Built-In"), 0) != 0 ? kCFBooleanTrue : kCFBooleanFalse;
        const void *keys[] = {CFSTR("id"), CFSTR("kind"), CFSTR("name"), CFSTR("builtIn")};
        const void *values[] = {identifier,kind,d->name,builtIn};
        CFDictionaryRef dict = CFDictionaryCreate(NULL,keys,values,4,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(result,dict); CFRelease(dict); CFRelease(identifier); CFRelease(kind);
    }
    return result;
}
CFStringRef MDPointerCopyStatus(MDPointerMonitorRef m) { return CFRetain(m->status); }

static CFStringRef accelerationKey(MDDevice *d) {
    CFTypeRef type = copyProperty(d->service,CFSTR("HIDPointerAccelerationType"));
    if (type && CFGetTypeID(type)==CFStringGetTypeID()) return type;
    if (type) CFRelease(type);
    CFTypeRef value = copyProperty(d->service,CFSTR("HIDPointerAcceleration"));
    if (value) { CFRelease(value); return CFRetain(CFSTR("HIDPointerAcceleration")); }
    return CFRetain(CFSTR("HIDMouseAcceleration"));
}
static bool capture(MDDevice *d, CFStringRef key, bool required) {
    CFTypeRef value = copyProperty(d->service,key); double number;
    if (!numberValue(value,&number)) { if(value) CFRelease(value); return !required; }
    CFDictionarySetValue(d->original,key,value); CFRelease(value); return true;
}
static bool writeNumber(MDDevice *d, CFStringRef key, int64_t number) {
    CFNumberRef value = CFNumberCreate(NULL,kCFNumberSInt64Type,&number);
    bool success = setProperty(d->service,key,value);
    // A successful setter owns this value even if an immediate readback fails.
    if (success) CFDictionarySetValue(d->written,key,value);
    CFRelease(value); return success;
}
int MDPointerApply(MDPointerMonitorRef m, double speedRatio, double acceleration, bool disabled) {
    if (!setProperty || !isfinite(speedRatio) || !isfinite(acceleration) || speedRatio<0.2 || speedRatio>4 || acceleration<0 || acceleration>3) {
        statusSet(m,CFSTR("当前系统不支持设备指针设置")); return -1;
    }
    int changed=0, unsupported=0;
    for (size_t i=0;i<m->count;i++) {
        MDDevice *d=&m->devices[i]; if(d->kind!=1) continue;
        CFStringRef accelKey=accelerationKey(d);
        if(!d->original) {
            d->original=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
            d->written=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
            bool supported=capture(d,CFSTR("HIDPointerResolution"),true) && capture(d,accelKey,true);
            capture(d,CFSTR("HIDUseLinearScalingMouseAcceleration"),false);
            if(!supported) { restoreDevice(d); unsupported++; CFRelease(accelKey); continue; }
        }
        CFTypeRef linear=CFDictionaryGetValue(d->original,CFSTR("HIDUseLinearScalingMouseAcceleration"));
        if(disabled && !linear) { restoreDevice(d); unsupported++; CFRelease(accelKey); continue; }
        double originalResolution=0;
        if(!numberValue(CFDictionaryGetValue(d->original,CFSTR("HIDPointerResolution")),&originalResolution) || originalResolution<=0) {
            restoreDevice(d); unsupported++; CFRelease(accelKey); continue;
        }
        int64_t resolution=(int64_t)llround(fmax(10*65536.0,fmin(1995*65536.0,originalResolution/speedRatio)));
        bool ok=writeNumber(d,CFSTR("HIDPointerResolution"),resolution);
        if(ok) ok=writeNumber(d,accelKey,(int64_t)llround(acceleration*65536.0));
        if(ok && linear) ok=writeNumber(d,CFSTR("HIDUseLinearScalingMouseAcceleration"),disabled ? 1 : 0);
        if(ok) changed++; else { restoreDevice(d); unsupported++; }
        CFRelease(accelKey);
    }
    if(changed && !unsupported) statusSet(m,CFSTR("已应用到外接鼠标；暂停时恢复系统设置"));
    else if(changed) statusSet(m,CFSTR("部分鼠标已应用；不支持的设备保持原设置"));
    else if(unsupported) statusSet(m,CFSTR("设备不支持这组指针设置；已尝试恢复原值"));
    else statusSet(m,CFSTR("尚未识别到可调整的外接鼠标"));
    return changed;
}
int MDPointerRestore(MDPointerMonitorRef m) {
    int failures=0;
    for(size_t i=0;i<m->count;i++) failures+=restoreDevice(&m->devices[i]);
    statusSet(m,failures ? CFSTR("部分设备已断开或设置恢复失败；请重新连接后检查系统设置") : CFSTR("指针保持系统设置"));
    return failures;
}
void MDPointerMonitorDestroy(MDPointerMonitorRef m) {
    if(!m) return;
    m->callback=NULL;
    if(m->refreshTimer) { CFRunLoopTimerInvalidate(m->refreshTimer); CFRelease(m->refreshTimer); }
    if(m->addedIterator) IOObjectRelease(m->addedIterator);
    if(m->removedIterator) IOObjectRelease(m->removedIterator);
    if(m->notificationPort) IONotificationPortDestroy(m->notificationPort);
    MDPointerRestore(m);
    for(size_t i=0;i<m->count;i++) deviceRelease(&m->devices[i]);
    free(m->devices); CFRelease(m->client); CFRelease(m->status); free(m);
}
bool MDPointerAttributionAvailable(void) { loadSymbols(); return copyEvent && eventSender; }
uint64_t MDPointerEventSenderID(CGEventRef event) {
    loadSymbols(); if(!copyEvent || !eventSender) return 0;
    CFTypeRef hidEvent=copyEvent(event); if(!hidEvent) return 0;
    uint64_t sender=eventSender(hidEvent); CFRelease(hidEvent); return sender;
}
