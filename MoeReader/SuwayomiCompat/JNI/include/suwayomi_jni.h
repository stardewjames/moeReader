//
//  suwayomi_jni.h
//  SuwayomiCompat
//
//  The app's side of the embedded JVM: start it once, call the host's
//  Bridge.call on the current thread, and serve the host's two upcalls
//  (Native.fetch, Native.call) through Swift callbacks. Everything crosses as
//  byte arrays in the host's wire format; no JNI type leaks into Swift.
//

#ifndef SUWAYOMI_JNI_H
#define SUWAYOMI_JNI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Bytes handed across the boundary. The producer owns them until `release`
/// is called with `owner` (Swift keeps the backing `NSData` alive until then,
/// so replies are not copied an extra time).
typedef struct sw_buffer {
    const uint8_t *data;
    int32_t length;
    /// Null `data` with `length == -1` encodes a Java null.
    void *owner;
} sw_buffer;

/// Performs one HTTP request. `meta`/`body` are the host's request; the
/// callee fills `out_meta` and `out_body`. Returns 0 on success.
typedef int32_t (*sw_fetch_callback)(const uint8_t *meta, int32_t meta_length,
                                     const uint8_t *body, int32_t body_length,
                                     sw_buffer *out_meta, sw_buffer *out_body);

/// Every other upcall (cookies, challenge solving, JavaScript, logging).
/// Returns 0 on success; `out` may stay null for a Java null reply.
typedef int32_t (*sw_call_callback)(int32_t op, const uint8_t *payload, int32_t length, sw_buffer *out);

/// Releases a buffer the Swift side produced.
typedef void (*sw_release_callback)(void *owner);

/// Starts the JVM and registers the host's natives. `libjvm_path` is a
/// dynamic libjvm to load (desktop and Linux test hosts); NULL looks
/// `JNI_CreateJavaVM` up in the running image, where the iOS build links the
/// VM statically. Must be called once, from a thread that stays alive.
/// Returns 0, or -1 with a message in `error`.
int32_t sw_jvm_start(const char *libjvm_path,
                     const char *const *options, int32_t option_count,
                     sw_fetch_callback fetch, sw_call_callback call, sw_release_callback release,
                     char *error, int32_t error_capacity);

/// True when this process can start a JVM without loading a library.
int32_t sw_jvm_linked(void);

/// True once `sw_jvm_start` created the VM. A start that failed before
/// creation leaves nothing behind and can be retried.
int32_t sw_jvm_running(void);

/// Calls `moe.reader.suwayomi.Bridge.call(op, request)` on the current
/// thread, attaching it to the JVM as a daemon the first time. On success the
/// reply is in `reply` and must be freed with `sw_reply_free`.
int32_t sw_bridge_call(int32_t op, const uint8_t *request, int32_t length,
                       uint8_t **reply, int32_t *reply_length,
                       char *error, int32_t error_capacity);

void sw_reply_free(uint8_t *reply);

#ifdef __cplusplus
}
#endif

#endif
