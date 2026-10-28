//
//  suwayomi_jni.c
//  SuwayomiCompat
//
//  See suwayomi_jni.h. The shim holds the JavaVM, the Bridge method and the
//  three Swift callbacks. It never keeps a thread of its own: calls run on the
//  caller's thread, which the shim attaches once as a daemon.
//

#include "include/suwayomi_jni.h"
#include "jdk/jni.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef jint (JNICALL *create_vm_fn)(JavaVM **, void **, void *);

#if defined(__APPLE__)
// Resolve a packaged static VM at link time, without relying on the app's
// dynamic export table. A Swift-only build leaves the weak import null.
extern jint JNICALL JNI_CreateJavaVM(JavaVM **, void **, void *) __attribute__((weak_import));
#endif

static create_vm_fn linked_create_vm(void) {
#if defined(__APPLE__)
    return JNI_CreateJavaVM;
#else
    return (create_vm_fn)dlsym(RTLD_DEFAULT, "JNI_CreateJavaVM");
#endif
}

static JavaVM *g_vm;
static jclass g_bridge_class;
static jmethodID g_bridge_call;
static jclass g_byte_array_class;
static sw_fetch_callback g_fetch;
static sw_call_callback g_call;
static sw_release_callback g_release;

static void set_error(char *error, int32_t capacity, const char *message) {
    if (error && capacity > 0) {
        snprintf(error, (size_t)capacity, "%s", message);
    }
}

/// Describes and clears a pending Java exception into `error`.
static int32_t take_exception(JNIEnv *env, char *error, int32_t capacity, const char *context) {
    if (!(*env)->ExceptionCheck(env)) return 0;
    jthrowable thrown = (*env)->ExceptionOccurred(env);
    (*env)->ExceptionClear(env);
    const char *detail = "Java exception";
    jstring text = NULL;
    if (thrown) {
        jclass throwable = (*env)->FindClass(env, "java/lang/Throwable");
        jmethodID to_string = throwable ? (*env)->GetMethodID(env, throwable, "toString", "()Ljava/lang/String;") : NULL;
        if (to_string) text = (jstring)(*env)->CallObjectMethod(env, thrown, to_string);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            text = NULL;
        }
        if (throwable) (*env)->DeleteLocalRef(env, throwable);
    }
    const char *chars = text ? (*env)->GetStringUTFChars(env, text, NULL) : NULL;
    if (chars) detail = chars;
    if (error && capacity > 0) snprintf(error, (size_t)capacity, "%s: %s", context, detail);
    if (chars) (*env)->ReleaseStringUTFChars(env, text, chars);
    if (text) (*env)->DeleteLocalRef(env, text);
    if (thrown) (*env)->DeleteLocalRef(env, thrown);
    return -1;
}

/// Copies a Java byte array into malloc'ed memory (no JNI critical section:
/// the callee blocks on the network). Sets `*length` to -1 for null.
static uint8_t *copy_array(JNIEnv *env, jbyteArray array, int32_t *length) {
    if (!array) {
        *length = -1;
        return NULL;
    }
    jsize count = (*env)->GetArrayLength(env, array);
    *length = (int32_t)count;
    uint8_t *bytes = (uint8_t *)malloc(count > 0 ? (size_t)count : 1);
    if (!bytes) {
        jclass oom = (*env)->FindClass(env, "java/lang/OutOfMemoryError");
        if (oom) {
            (*env)->ThrowNew(env, oom, "copying native request");
            (*env)->DeleteLocalRef(env, oom);
        }
        *length = -1;
        return NULL;
    }
    if (count > 0) (*env)->GetByteArrayRegion(env, array, 0, count, (jbyte *)bytes);
    return bytes;
}

/// A Java byte[] from a Swift buffer, which is released afterwards.
static jbyteArray make_array(JNIEnv *env, sw_buffer *buffer) {
    jbyteArray array = NULL;
    if (buffer->data || buffer->length >= 0) {
        jsize count = buffer->length > 0 ? buffer->length : 0;
        array = (*env)->NewByteArray(env, count);
        if (array && count > 0) (*env)->SetByteArrayRegion(env, array, 0, count, (const jbyte *)buffer->data);
    }
    if (buffer->owner && g_release) g_release(buffer->owner);
    buffer->owner = NULL;
    buffer->data = NULL;
    return array;
}

static jobjectArray JNICALL native_fetch(JNIEnv *env, jclass cls, jbyteArray meta, jbyteArray body) {
    (void)cls;
    int32_t meta_length = 0, body_length = 0;
    uint8_t *meta_bytes = copy_array(env, meta, &meta_length);
    if ((*env)->ExceptionCheck(env)) {
        free(meta_bytes);
        return NULL;
    }
    uint8_t *body_bytes = copy_array(env, body, &body_length);
    if ((*env)->ExceptionCheck(env)) {
        free(meta_bytes);
        free(body_bytes);
        return NULL;
    }
    sw_buffer out_meta = { NULL, -1, NULL };
    sw_buffer out_body = { NULL, -1, NULL };
    int32_t status = g_fetch ? g_fetch(meta_bytes, meta_length, body_bytes, body_length, &out_meta, &out_body) : -1;
    free(meta_bytes);
    free(body_bytes);

    jobjectArray result = (*env)->NewObjectArray(env, 2, g_byte_array_class, NULL);
    if (!result) {
        if (out_meta.owner && g_release) g_release(out_meta.owner);
        if (out_body.owner && g_release) g_release(out_body.owner);
        return NULL;
    }
    if (status == 0) {
        jbyteArray meta_array = make_array(env, &out_meta);
        jbyteArray body_array = make_array(env, &out_body);
        (*env)->SetObjectArrayElement(env, result, 0, meta_array);
        (*env)->SetObjectArrayElement(env, result, 1, body_array);
        if (meta_array) (*env)->DeleteLocalRef(env, meta_array);
        if (body_array) (*env)->DeleteLocalRef(env, body_array);
    } else {
        if (out_meta.owner && g_release) g_release(out_meta.owner);
        if (out_body.owner && g_release) g_release(out_body.owner);
    }
    return result;
}

static jbyteArray JNICALL native_call(JNIEnv *env, jclass cls, jint op, jbyteArray payload) {
    (void)cls;
    int32_t length = 0;
    uint8_t *bytes = copy_array(env, payload, &length);
    if ((*env)->ExceptionCheck(env)) {
        free(bytes);
        return NULL;
    }
    sw_buffer out = { NULL, -1, NULL };
    int32_t status = g_call ? g_call((int32_t)op, bytes, length, &out) : -1;
    free(bytes);
    if (status != 0) {
        if (out.owner && g_release) g_release(out.owner);
        return NULL;
    }
    return make_array(env, &out);
}

int32_t sw_jvm_linked(void) {
    return linked_create_vm() != NULL ? 1 : 0;
}

int32_t sw_jvm_start(const char *libjvm_path,
                     const char *const *options, int32_t option_count,
                     sw_fetch_callback fetch, sw_call_callback call, sw_release_callback release,
                     char *error, int32_t error_capacity) {
    if (g_vm) {
        set_error(error, error_capacity, "the JVM is already running");
        return -1;
    }
    create_vm_fn create = linked_create_vm();
    if (libjvm_path && libjvm_path[0]) {
        void *handle = dlopen(libjvm_path, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            const char *reason = dlerror();
            set_error(error, error_capacity, reason ? reason : "cannot load libjvm");
            return -1;
        }
        create = (create_vm_fn)dlsym(handle, "JNI_CreateJavaVM");
    }
    if (!create) {
        set_error(error, error_capacity, "JNI_CreateJavaVM is not linked into this build");
        return -1;
    }

    JavaVMOption *vm_options = (JavaVMOption *)calloc(option_count > 0 ? (size_t)option_count : 1, sizeof(JavaVMOption));
    if (!vm_options) {
        set_error(error, error_capacity, "out of memory");
        return -1;
    }
    for (int32_t i = 0; i < option_count; i++) vm_options[i].optionString = (char *)options[i];
    JavaVMInitArgs args;
    memset(&args, 0, sizeof(args));
    args.version = JNI_VERSION_10;
    args.nOptions = option_count;
    args.options = vm_options;
    args.ignoreUnrecognized = JNI_FALSE;

    JNIEnv *env = NULL;
    jint created = create(&g_vm, (void **)&env, &args);
    free(vm_options);
    if (created != JNI_OK || !env) {
        g_vm = NULL;
        char message[96];
        snprintf(message, sizeof(message), "JNI_CreateJavaVM failed (%d)", (int)created);
        set_error(error, error_capacity, message);
        return -1;
    }

    g_fetch = fetch;
    g_call = call;
    g_release = release;

    jclass byte_array = (*env)->FindClass(env, "[B");
    jclass bridge = (*env)->FindClass(env, "moe/reader/suwayomi/Bridge");
    jclass native = (*env)->FindClass(env, "moe/reader/suwayomi/Native");
    if (!byte_array || !bridge || !native) {
        if (!take_exception(env, error, error_capacity, "host classes")) {
            set_error(error, error_capacity, "host classes are missing from the class path");
        }
        return -1;
    }
    g_byte_array_class = (jclass)(*env)->NewGlobalRef(env, byte_array);
    g_bridge_class = (jclass)(*env)->NewGlobalRef(env, bridge);
    if (!g_byte_array_class || !g_bridge_class) {
        take_exception(env, error, error_capacity, "host class references");
        return -1;
    }
    g_bridge_call = (*env)->GetStaticMethodID(env, bridge, "call", "(I[B)[B");
    if (!g_bridge_call) return take_exception(env, error, error_capacity, "Bridge.call");

    JNINativeMethod methods[] = {
        { (char *)"fetch", (char *)"([B[B)[[B", (void *)native_fetch },
        { (char *)"call", (char *)"(I[B)[B", (void *)native_call },
    };
    if ((*env)->RegisterNatives(env, native, methods, 2) != JNI_OK) {
        return take_exception(env, error, error_capacity, "RegisterNatives");
    }
    (*env)->DeleteLocalRef(env, byte_array);
    (*env)->DeleteLocalRef(env, bridge);
    (*env)->DeleteLocalRef(env, native);
    return 0;
}

static JNIEnv *attached_env(char *error, int32_t error_capacity) {
    if (!g_vm) {
        set_error(error, error_capacity, "the JVM is not running");
        return NULL;
    }
    JNIEnv *env = NULL;
    jint status = (*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_10);
    if (status == JNI_EDETACHED) {
        if ((*g_vm)->AttachCurrentThreadAsDaemon(g_vm, (void **)&env, NULL) != JNI_OK) {
            set_error(error, error_capacity, "cannot attach the thread to the JVM");
            return NULL;
        }
    } else if (status != JNI_OK) {
        set_error(error, error_capacity, "the JVM rejected the thread");
        return NULL;
    }
    return env;
}

int32_t sw_bridge_call(int32_t op, const uint8_t *request, int32_t length,
                       uint8_t **reply, int32_t *reply_length,
                       char *error, int32_t error_capacity) {
    *reply = NULL;
    *reply_length = 0;
    JNIEnv *env = attached_env(error, error_capacity);
    if (!env) return -1;
    if ((*env)->PushLocalFrame(env, 8) != JNI_OK) return take_exception(env, error, error_capacity, "local frame");

    jbyteArray input = (*env)->NewByteArray(env, length > 0 ? length : 0);
    if (!input) {
        int32_t failed = take_exception(env, error, error_capacity, "request");
        (*env)->PopLocalFrame(env, NULL);
        return failed ? failed : -1;
    }
    if (length > 0) (*env)->SetByteArrayRegion(env, input, 0, length, (const jbyte *)request);
    jbyteArray output = (jbyteArray)(*env)->CallStaticObjectMethod(env, g_bridge_class, g_bridge_call, (jint)op, input);
    if (take_exception(env, error, error_capacity, "Bridge.call")) {
        (*env)->PopLocalFrame(env, NULL);
        return -1;
    }
    if (!output) {
        set_error(error, error_capacity, "Bridge.call returned null");
        (*env)->PopLocalFrame(env, NULL);
        return -1;
    }
    jsize count = (*env)->GetArrayLength(env, output);
    uint8_t *bytes = (uint8_t *)malloc(count > 0 ? (size_t)count : 1);
    if (!bytes) {
        set_error(error, error_capacity, "out of memory");
        (*env)->PopLocalFrame(env, NULL);
        return -1;
    }
    if (count > 0) (*env)->GetByteArrayRegion(env, output, 0, count, (jbyte *)bytes);
    (*env)->PopLocalFrame(env, NULL);
    *reply = bytes;
    *reply_length = (int32_t)count;
    return 0;
}

void sw_reply_free(uint8_t *reply) {
    free(reply);
}
