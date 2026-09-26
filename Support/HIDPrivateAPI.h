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
#include <stdint.h>

// IOHIDEventRef and IOHIDEventSetRef are defined in the private
// <IOKit/hid/IOHIDEvent.h>, which is not shipped in the SDK. We only use these
// types as opaque pointers (never accessing members), so forward-declare them
// instead of importing the private header.
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSet *IOHIDEventSetRef;

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
                                            uint32_t timestamp,
                                            uint32_t type,
                                            uint32_t subType,
                                            uint32_t index,
                                            uint32_t range,
                                            uint32_t digitizerType,
                                            float x,
                                            float y,
                                            float z,
                                            float v,
                                            uint32_t options);

IOHIDEventSetRef IOHIDEventCreateDigitizerEventSet(CFAllocatorRef allocator,
                                                  uint32_t maxEvents);

// ---------------------------------------------------------------------------
// Event query (private) — normally provided by <IOKit/hid/IOHIDEvent.h>
// ---------------------------------------------------------------------------
uint32_t IOHIDEventGetEventType(IOHIDEventRef event);
float IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#ifdef __cplusplus
}
#endif
