#import "TrackpadBridge.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <pthread.h>

// Read-only contact ABI checked against OpenMultitouchSupport's MIT
// OpenMTInternal.h. The adapter and lifecycle implementation are independent.
typedef void *MDMTDevice;
typedef struct { float x, y; } MDMTPoint;
typedef struct { MDMTPoint position, velocity; } MDMTVector;
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, fingerID, handID;
    MDMTVector normalized;
    float capacitance, pressure, angle, majorAxis, minorAxis;
    MDMTVector absolute;
    int field14, field15;
    float density;
} MDMTContact;
typedef void (*MDMTCallback)(MDMTDevice, MDMTContact *, int, double, int);
typedef CFArrayRef (*MDMTCreateList)(void);
typedef bool (*MDMTIsBuiltIn)(MDMTDevice);
typedef bool (*MDMTIsRunning)(MDMTDevice);
typedef int32_t (*MDMTGetDeviceID)(MDMTDevice, uint64_t *);
typedef void (*MDMTRegister)(MDMTDevice, MDMTCallback);
typedef int32_t (*MDMTStart)(MDMTDevice, int);
typedef int32_t (*MDMTStop)(MDMTDevice);

struct MDTrackpadMonitor {
    void *library;
    MDMTDevice device;
    MDMTRegister registerCallback, unregisterCallback;
    MDMTStart start;
    MDMTStop stop;
    MDMTIsRunning isRunning;
    MDTrackpadFrameCallback callback;
    void *context;
    uint64_t deviceID;
    bool listening, ownsStream;
    unsigned callbacksInFlight;
    CFStringRef status;
    struct MDTrackpadMonitor *next;
};

static pthread_mutex_t registryMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t drained = PTHREAD_COND_INITIALIZER;
static struct MDTrackpadMonitor *registry = NULL;

static void setStatus(MDTrackpadMonitorRef monitor, CFStringRef status) {
    if (monitor->status) CFRelease(monitor->status);
    monitor->status = CFRetain(status);
}

static void frameReceived(MDMTDevice device, MDMTContact *touches, int count, double timestamp, int frame) {
    (void)frame;
    pthread_mutex_lock(&registryMutex);
    MDTrackpadMonitorRef monitor = registry;
    while (monitor && (monitor->device != device || !monitor->listening)) monitor = monitor->next;
    if (!monitor) { pthread_mutex_unlock(&registryMutex); return; }
    monitor->callbacksInFlight++;
    MDTrackpadFrameCallback callback = monitor->callback;
    void *context = monitor->context;
    pthread_mutex_unlock(&registryMutex);

    MDTrackpadContact contacts[32];
    size_t active = 0;
    for (int i = 0; touches && i < count && active < 32; i++) {
        // MakeTouch and Touching are contact; hovering/lingering are not taps.
        if (touches[i].state != 3 && touches[i].state != 4) continue;
        contacts[active++] = (MDTrackpadContact){ (int32_t)touches[i].identifier,
                                                (double)touches[i].normalized.position.x,
                                                (double)touches[i].normalized.position.y };
    }
    if (callback) callback(context, contacts, active, timestamp);

    pthread_mutex_lock(&registryMutex);
    monitor->callbacksInFlight--;
    if (!monitor->callbacksInFlight) pthread_cond_broadcast(&drained);
    pthread_mutex_unlock(&registryMutex);
}

MDTrackpadMonitorRef MDTrackpadMonitorCreate(MDTrackpadFrameCallback callback, void *context) {
    MDTrackpadMonitorRef monitor = calloc(1, sizeof(struct MDTrackpadMonitor));
    if (!monitor) return NULL;
    monitor->callback = callback;
    monitor->context = context;
    setStatus(monitor, CFSTR("未发现内建多点触控板"));
    monitor->library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LOCAL | RTLD_LAZY);
    if (!monitor->library) { setStatus(monitor, CFSTR("无法加载系统多点触控接口")); return monitor; }
    MDMTCreateList createList = (MDMTCreateList)dlsym(monitor->library, "MTDeviceCreateList");
    MDMTIsBuiltIn builtIn = (MDMTIsBuiltIn)dlsym(monitor->library, "MTDeviceIsBuiltIn");
    MDMTGetDeviceID getID = (MDMTGetDeviceID)dlsym(monitor->library, "MTDeviceGetDeviceID");
    monitor->registerCallback = (MDMTRegister)dlsym(monitor->library, "MTRegisterContactFrameCallback");
    monitor->unregisterCallback = (MDMTRegister)dlsym(monitor->library, "MTUnregisterContactFrameCallback");
    monitor->start = (MDMTStart)dlsym(monitor->library, "MTDeviceStart");
    monitor->stop = (MDMTStop)dlsym(monitor->library, "MTDeviceStop");
    monitor->isRunning = (MDMTIsRunning)dlsym(monitor->library, "MTDeviceIsRunning");
    if (!createList || !builtIn || !getID || !monitor->registerCallback || !monitor->unregisterCallback || !monitor->start || !monitor->stop || !monitor->isRunning) {
        setStatus(monitor, CFSTR("系统多点触控接口不完整"));
        return monitor;
    }
    CFArrayRef devices = createList();
    if (!devices) return monitor;
    for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
        MDMTDevice device = (MDMTDevice)CFArrayGetValueAtIndex(devices, i);
        if (!device || !builtIn(device)) continue;
        monitor->device = (MDMTDevice)CFRetain(device);
        getID(device, &monitor->deviceID);
        setStatus(monitor, CFSTR("内建触控板已就绪"));
        break;
    }
    CFRelease(devices);
    return monitor;
}

bool MDTrackpadMonitorIsAvailable(MDTrackpadMonitorRef monitor) { return monitor && monitor->device != NULL; }
uint64_t MDTrackpadMonitorDeviceID(MDTrackpadMonitorRef monitor) { return monitor ? monitor->deviceID : 0; }
CFStringRef MDTrackpadMonitorCopyStatus(MDTrackpadMonitorRef monitor) {
    return CFRetain(monitor && monitor->status ? monitor->status : CFSTR("触控板接口不可用"));
}

bool MDTrackpadMonitorStart(MDTrackpadMonitorRef monitor) {
    if (!MDTrackpadMonitorIsAvailable(monitor)) return false;
    if (monitor->listening) return true;
    monitor->ownsStream = !monitor->isRunning(monitor->device);
    pthread_mutex_lock(&registryMutex);
    monitor->listening = true;
    monitor->next = registry;
    registry = monitor;
    pthread_mutex_unlock(&registryMutex);
    monitor->registerCallback(monitor->device, frameReceived);
    int32_t result = monitor->ownsStream ? monitor->start(monitor->device, 0) : 0;
    if (result != 0) {
        MDTrackpadMonitorStop(monitor);
        setStatus(monitor, CFSTR("无法启动内建触控板监听"));
        return false;
    }
    setStatus(monitor, CFSTR("内建触控板监听中"));
    return true;
}

void MDTrackpadMonitorStop(MDTrackpadMonitorRef monitor) {
    if (!monitor || !monitor->listening) return;
    pthread_mutex_lock(&registryMutex);
    monitor->listening = false;
    MDTrackpadMonitorRef *cursor = &registry;
    while (*cursor && *cursor != monitor) cursor = &(*cursor)->next;
    if (*cursor == monitor) *cursor = monitor->next;
    monitor->next = NULL;
    pthread_mutex_unlock(&registryMutex);
    monitor->unregisterCallback(monitor->device, frameReceived);
    if (monitor->ownsStream) monitor->stop(monitor->device);
    monitor->ownsStream = false;
    pthread_mutex_lock(&registryMutex);
    while (monitor->callbacksInFlight) pthread_cond_wait(&drained, &registryMutex);
    pthread_mutex_unlock(&registryMutex);
    setStatus(monitor, CFSTR("内建触控板已暂停"));
}

void MDTrackpadMonitorDestroy(MDTrackpadMonitorRef monitor) {
    if (!monitor) return;
    MDTrackpadMonitorStop(monitor);
    if (monitor->device) CFRelease(monitor->device);
    if (monitor->status) CFRelease(monitor->status);
    if (monitor->library) dlclose(monitor->library);
    free(monitor);
}
