//
//  HIDPrivateAPI.h
//  Declares the private IOKit HID APIs used to observe and inject touch events
//  system-wide on non-jailbroken iOS.
//
//  These symbols live in the system IOKit framework but are not exposed in the
//  public headers. Declaring them here lets Swift call them through the
//  bridging header.
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
// Client lifecycle (private)
// ---------------------------------------------------------------------------
kern_return_t IOHIDEventSystemClientCreate(CFAllocatorRef allocator,
                                          IOHIDEventSystemClientRef *client);
void IOHIDEventSystemClientDestroy(IOHIDEventSystemClientRef client);

// ---------------------------------------------------------------------------
// Observation (private)
// ---------------------------------------------------------------------------
kern_return_t IOHIDEventSystemClientSetEventDispatchFunction(
    IOHIDEventSystemClientRef client,
    IOHIDEventSystemClientEventDispatchFunction function,
    void *context);

// ---------------------------------------------------------------------------
// Injection (private)
// ---------------------------------------------------------------------------
kern_return_t IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client,
                                                 IOHIDEventRef event);
kern_return_t IOHIDEventSystemClientDispatchEventSet(IOHIDEventSystemClientRef client,
                                                    IOHIDEventSetRef eventSet);

// ---------------------------------------------------------------------------
// Digitizer (touch) event creation (private)
// ---------------------------------------------------------------------------
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator,
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

IOHIDEventSetRef IOHIDEventCreateDigitizerEventSet(CFAllocatorRef allocator,
                                                  UInt32 maxEvents);

#ifdef __cplusplus
}
#endif
