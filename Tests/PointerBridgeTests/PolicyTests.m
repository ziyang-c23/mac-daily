#include <assert.h>
#include <stdio.h>
#include "../../Sources/PointerBridge/PointerBridge.m"
static CFStringRef failKey;
static CFTypeRef fakeCopy(CFTypeRef service,CFStringRef key) { CFTypeRef v=CFDictionaryGetValue(service,key); return v ? CFRetain(v) : NULL; }
static Boolean fakeSet(CFTypeRef service,CFStringRef key,CFTypeRef value) {
 if(failKey && CFEqual(key,failKey))return false;
 CFDictionarySetValue((CFMutableDictionaryRef)service,key,value);return true;
}
static void put(CFMutableDictionaryRef d,CFStringRef key,int64_t n){CFNumberRef x=CFNumberCreate(NULL,kCFNumberSInt64Type,&n);CFDictionarySetValue(d,key,x);CFRelease(x);}
static double get(CFMutableDictionaryRef d,CFStringRef key){double v=0;numberValue(CFDictionaryGetValue(d,key),&v);return v;}
int main(void){
 copyProperty=fakeCopy;setProperty=fakeSet;
 CFMutableDictionaryRef properties=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 put(properties,CFSTR("HIDPointerResolution"),400*65536);put(properties,CFSTR("HIDMouseAcceleration"),98304);put(properties,CFSTR("HIDUseLinearScalingMouseAcceleration"),0);
 CFDictionarySetValue(properties,CFSTR("HIDPointerAccelerationType"),CFSTR("HIDMouseAcceleration"));
 MDDevice device={.service=properties,.kind=1};struct MDPointerMonitor m={.devices=&device,.count=1};
 assert(MDPointerApply(&m,2,0.5,true)==1);
 assert(get(properties,CFSTR("HIDPointerResolution"))==200*65536);
 assert(get(properties,CFSTR("HIDMouseAcceleration"))==32768);
 assert(get(properties,CFSTR("HIDUseLinearScalingMouseAcceleration"))==1);
 assert(MDPointerApply(&m,2,0.5,true)==1); // Relative to baseline, no accumulation.
 assert(get(properties,CFSTR("HIDPointerResolution"))==200*65536);
 assert(MDPointerRestore(&m)==0);
 assert(get(properties,CFSTR("HIDPointerResolution"))==400*65536);
 assert(get(properties,CFSTR("HIDMouseAcceleration"))==98304);
 assert(get(properties,CFSTR("HIDUseLinearScalingMouseAcceleration"))==0);
 assert(!device.original && !device.written);
 assert(MDPointerApply(&m,2,0.5,false)==1);
 put(properties,CFSTR("HIDPointerResolution"),300*65536); // External changes win.
 assert(MDPointerRestore(&m)==0);
 assert(get(properties,CFSTR("HIDPointerResolution"))==300*65536);
 failKey=CFSTR("HIDMouseAcceleration");
 assert(MDPointerApply(&m,2,0.5,false)==0);
 assert(get(properties,CFSTR("HIDPointerResolution"))==300*65536); // Rollback partial apply.
 failKey=NULL;
 CFDictionaryRemoveValue(properties,CFSTR("HIDUseLinearScalingMouseAcceleration"));
 assert(MDPointerApply(&m,2,0.5,true)==0); // Unsupported disable acceleration does not mutate.
 assert(get(properties,CFSTR("HIDPointerResolution"))==300*65536);
 device.kind=2;
 assert(MDPointerApply(&m,2,0.5,false)==0); // Touchpad untouched.
 assert(get(properties,CFSTR("HIDMouseAcceleration"))==98304);
 if(m.status)CFRelease(m.status);CFRelease(properties);
 puts("pointer policy: baseline scaling, no accumulation, restore, external ownership, partial rollback, unsupported linear mode, touchpad exclusion PASS");
}
