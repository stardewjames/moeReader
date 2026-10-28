package moe.reader.suwayomi

import java.io.IOException

/** A request the app performs on its own network stack (URLSession on iOS). */
class NativeRequest(
    val url: String,
    val method: String,
    /** Header lines in order; repeated names are allowed. */
    val headers: List<Pair<String, String>>,
    val body: ByteArray?,
    val timeoutMillis: Int,
)

/**
 * The app's answer. Redirects are never followed natively (OkHttp follows them
 * so every hop sees the cookie jar), and the body arrives content-decoded, so
 * the app strips `Content-Encoding`/`Content-Length`.
 */
class NativeResponse(
    val code: Int,
    val message: String,
    val headers: List<Pair<String, String>>,
    val body: ByteArray,
)

/** A cookie as the app's cookie storage holds it. */
data class NativeCookie(
    val name: String,
    val value: String,
    val domain: String,
    val path: String,
    /** Epoch milliseconds; [Long.MAX_VALUE] for a session cookie. */
    val expiresAt: Long,
    val secure: Boolean,
    val httpOnly: Boolean,
    val hostOnly: Boolean,
)

/** Result of one JavaScript evaluation. */
sealed interface JsValue {
    data object Undefined : JsValue

    data class Bool(val value: Boolean) : JsValue

    data class Number(val value: Double) : JsValue

    data class Text(val value: String) : JsValue

    data class Array(val values: List<JsValue>) : JsValue
}

class JsEvaluationException(
    message: String,
) : Exception(message)

/**
 * Everything Android would provide that the host asks the app for. The app is
 * the single owner of the network stack, the cookie storage (shared with the
 * rest of MoeReader and its challenge solver) and JavaScriptCore.
 */
interface HostServices {
    @Throws(IOException::class)
    fun fetch(request: NativeRequest): NativeResponse

    fun cookies(url: String): List<NativeCookie>

    fun saveCookies(
        url: String,
        cookies: List<NativeCookie>,
    )

    /** Removes cookies matching [url] (all cookies when null) and, when set, [name]. */
    fun removeCookies(
        url: String?,
        name: String?,
    )

    fun allCookies(): List<NativeCookie>

    /** Clears a browser check for [url] presenting [userAgent]; true when the retry may succeed. */
    fun solveChallenge(
        url: String,
        userAgent: String,
    ): Boolean

    fun jsCreate(): Long

    @Throws(JsEvaluationException::class)
    fun jsEvaluate(
        context: Long,
        script: String,
    ): JsValue

    fun jsClose(context: Long)

    fun log(
        level: Int,
        message: String,
    )

    companion object {
        const val LOG_DEBUG = 0
        const val LOG_INFO = 1
        const val LOG_WARN = 2
        const val LOG_ERROR = 3
    }
}

/** Upcall operation codes understood by the app's `Native.call` handler. */
internal object Upcall {
    const val LOG = 1
    const val COOKIES_GET = 2
    const val COOKIES_SAVE = 3
    const val COOKIES_REMOVE = 4
    const val COOKIES_ALL = 5
    const val SOLVE_CHALLENGE = 6
    const val JS_CREATE = 7
    const val JS_EVALUATE = 8
    const val JS_CLOSE = 9
}

/** The JNI-backed services the embedded host uses. */
class NativeHostServices : HostServices {
    override fun fetch(request: NativeRequest): NativeResponse {
        val meta =
            WireWriter(256 + request.url.length)
                .string(request.url)
                .string(request.method)
                .list(request.headers) { (name, value) ->
                    string(name)
                    string(value)
                }.i32(request.timeoutMillis)
                .toByteArray()
        val reply = Native.fetch(meta, request.body)
        val replyMeta = reply.getOrNull(0) ?: throw IOException("native transport returned no response")
        val reader = WireReader(replyMeta)
        if (reader.u8() != 0) {
            val timedOut = reader.bool()
            val message = reader.string() ?: "network error"
            throw if (timedOut) java.net.SocketTimeoutException(message) else IOException(message)
        }
        val code = reader.i32()
        val message = reader.string().orEmpty()
        val headers =
            reader.list {
                requireString() to requireString()
            }
        return NativeResponse(code, message, headers, reply.getOrNull(1) ?: ByteArray(0))
    }

    override fun cookies(url: String): List<NativeCookie> =
        call(Upcall.COOKIES_GET, WireWriter().string(url))?.let { readCookies(WireReader(it)) }.orEmpty()

    override fun saveCookies(
        url: String,
        cookies: List<NativeCookie>,
    ) {
        if (cookies.isEmpty()) return
        call(Upcall.COOKIES_SAVE, writeCookies(WireWriter().string(url), cookies))
    }

    override fun removeCookies(
        url: String?,
        name: String?,
    ) {
        call(Upcall.COOKIES_REMOVE, WireWriter().string(url).string(name))
    }

    override fun allCookies(): List<NativeCookie> =
        call(Upcall.COOKIES_ALL, WireWriter())?.let { readCookies(WireReader(it)) }.orEmpty()

    override fun solveChallenge(
        url: String,
        userAgent: String,
    ): Boolean =
        call(Upcall.SOLVE_CHALLENGE, WireWriter().string(url).string(userAgent))
            ?.let { WireReader(it).bool() } ?: false

    override fun jsCreate(): Long =
        call(Upcall.JS_CREATE, WireWriter())?.let { WireReader(it).i64() }
            ?: throw UnsupportedOperationException("JavaScript engine is not available")

    override fun jsEvaluate(
        context: Long,
        script: String,
    ): JsValue {
        val reply =
            call(Upcall.JS_EVALUATE, WireWriter(script.length + 16).i64(context).string(script))
                ?: throw JsEvaluationException("JavaScript engine is not available")
        val reader = WireReader(reply)
        if (reader.u8() != 0) throw JsEvaluationException(reader.string() ?: "JavaScript error")
        return readJsValue(reader, 0)
    }

    override fun jsClose(context: Long) {
        call(Upcall.JS_CLOSE, WireWriter().i64(context))
    }

    override fun log(
        level: Int,
        message: String,
    ) {
        call(Upcall.LOG, WireWriter().i32(level).string(message))
    }

    private fun call(
        op: Int,
        payload: WireWriter,
    ): ByteArray? = Native.call(op, payload.toByteArray())

    companion object {
        fun writeCookies(
            writer: WireWriter,
            cookies: List<NativeCookie>,
        ): WireWriter =
            writer.list(cookies) { cookie ->
                string(cookie.name)
                string(cookie.value)
                string(cookie.domain)
                string(cookie.path)
                i64(cookie.expiresAt)
                bool(cookie.secure)
                bool(cookie.httpOnly)
                bool(cookie.hostOnly)
            }

        fun readCookies(reader: WireReader): List<NativeCookie> =
            reader.list {
                NativeCookie(
                    name = requireString(),
                    value = requireString(),
                    domain = requireString(),
                    path = requireString(),
                    expiresAt = i64(),
                    secure = bool(),
                    httpOnly = bool(),
                    hostOnly = bool(),
                )
            }

        private const val JS_UNDEFINED = 0
        private const val JS_BOOL = 1
        private const val JS_NUMBER = 2
        private const val JS_STRING = 3
        private const val JS_ARRAY = 4

        fun readJsValue(
            reader: WireReader,
            depth: Int,
        ): JsValue {
            if (depth > 16) throw WireFormatException("JavaScript value nested too deeply")
            return when (val tag = reader.u8()) {
                JS_UNDEFINED -> JsValue.Undefined
                JS_BOOL -> JsValue.Bool(reader.bool())
                JS_NUMBER -> JsValue.Number(reader.f64())
                JS_STRING -> JsValue.Text(reader.requireString())
                JS_ARRAY -> JsValue.Array(reader.list { readJsValue(this, depth + 1) })
                else -> throw WireFormatException("unknown JavaScript value tag $tag")
            }
        }
    }
}

/** Natives registered by the app's JNI shim (SuwayomiCompat/JNI/suwayomi_jni.c). */
object Native {
    /** Performs one HTTP request: `[meta, body]` in, `[meta, body]` out. */
    @JvmStatic
    external fun fetch(
        meta: ByteArray,
        body: ByteArray?,
    ): Array<ByteArray?>

    /** Every other upcall: [Upcall] code and payload; null when the app has no answer. */
    @JvmStatic
    external fun call(
        op: Int,
        payload: ByteArray,
    ): ByteArray?
}
