//
//  HIDPrivateAPI.h
//  Declares the private IOKit HID APIs used to observe and inject touch events
//  system-wide on non-jailbroken iOS.
//
//  These symbols live in the system IOKit framework but are not exposed in the
//  public headers. We resolve them at RUNTIME with dlopen/dlsym instead of
//  linking them directly: if a future iOS release removes a symbol, the build
//  still succeeds and the app degrades gracefully (the UI reports "HID
//  unavailable") instead of failing to link or crashing at launch.
//
//  The public IOHIDEvent* helpers (getters, field constants) are still imported
//  normally from <IOKit/hid/IOHIDEvent.h> and linked directly — those are safe.
//

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDEvent.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Opaque reference types
// ---------------------------------------------------------------------------
// IOHIDEventRef and IOHIDEventSetRef are defined in <IOKit/hid/IOHIDEvent.h>.
// IOHIDEventSystemClientRef is private.
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

// ---------------------------------------------------------------------------
// Event dispatch callback (private)
// ---------------------------------------------------------------------------
typedef void (*IOHIDEventSystemClientEventDispatchFunction)(void *context,
                                                           IOHIDEventRef event);

// ---------------------------------------------------------------------------
// Function-pointer typedefs for the private symbols (resolved via dlsym)
// ---------------------------------------------------------------------------
typedef kern_return_t (*PFN_IOHIDEventSystemClientCreate)(CFAllocatorRef allocator,
                                                         IOHIDEventSystemClientRef *client);
typedef void (*PFN_IOHIDEventSystemClientDestroy)(IOHIDEventSystemClientRef client);
typedef kern_return_t (*PFN_IOHIDEventSystemClientSetEventDispatchFunction)(
    IOHIDEventSystemClientRef client,
    IOHIDEventSystemClientEventDispatchFunction function,
    void *context);
typedef kern_return_t (*PFN_IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef client,
                                                               IOHIDEventRef event);
typedef kern_return_t (*PFN_IOHIDEventSystemClientDispatchEventSet)(IOHIDEventSystemClientRef client,
                                                                  IOHIDEventSetRef eventSet);
typedef IOHIDEventRef (*PFN_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef allocator,
                                                           UInt32 timestamp,
                                                           UInt32 type,
                                                           UInt32 subType,
                                                           UInt32 index,
                                                           UInt32 range,
                                                           UInt32 digitizerType,
                                                           Float32 x,
                                                           Float32 y,
                                                           Float32 z,
                                                           Float32 v,
                                                           UInt32 options);

#ifdef __cplusplus
}
#endif
