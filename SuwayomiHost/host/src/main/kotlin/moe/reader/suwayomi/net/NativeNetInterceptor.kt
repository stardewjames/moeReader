/*
 * Adapted from Oneechan's NativeNetInterceptor.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Modified for MoeReader's HostServices request/response bridge.
 */

package moe.reader.suwayomi.net

import moe.reader.suwayomi.Host
import moe.reader.suwayomi.NativeRequest
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.io.IOException
import java.lang.reflect.Field

/**
 * First application interceptor of every client derived from
 * `NetworkHelper.client`. It rewrites this call's interceptor list once so the
 * JVM never opens a socket:
 *  - `ConnectInterceptor` is dropped (no JVM DNS, socket or TLS work),
 *  - `CallServerInterceptor` becomes [NativeCallInterceptor] (the app performs
 *    the request on URLSession).
 * Everything else stays OkHttp's own code: extension interceptors,
 * `RetryAndFollowUpInterceptor` (redirects with per-hop cookies),
 * `BridgeInterceptor` (cookie jar, default headers) and network interceptors.
 *
 * Adapted from Oneechan's NativeNetInterceptor (MPL-2.0).
 */
class NativeNetInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        if (!chain.request().isWebSocket()) rewrite(chain)
        return chain.proceed(chain.request())
    }

    private fun rewrite(chain: Interceptor.Chain) {
        @Suppress("UNCHECKED_CAST")
        val interceptors = interceptorsField(chain).get(chain) as? MutableList<Interceptor> ?: return
        synchronized(interceptors) {
            if (interceptors.any { it is NativeCallInterceptor }) return
            interceptors.removeAll { it.javaClass.name == CONNECT_INTERCEPTOR }
            val server = interceptors.indexOfFirst { it.javaClass.name == CALL_SERVER_INTERCEPTOR }
            check(server >= 0) { "OkHttp chain layout changed: no CallServerInterceptor" }
            interceptors[server] = NativeCallInterceptor()
        }
    }

    private fun okhttp3.Request.isWebSocket() = header("Upgrade").equals("websocket", ignoreCase = true)

    companion object {
        private const val CONNECT_INTERCEPTOR = "okhttp3.internal.connection.ConnectInterceptor"
        private const val CALL_SERVER_INTERCEPTOR = "okhttp3.internal.http.CallServerInterceptor"

        @Volatile
        private var field: Field? = null

        private fun interceptorsField(chain: Interceptor.Chain): Field =
            field ?: chain.javaClass.getDeclaredField("interceptors").apply { isAccessible = true }.also { field = it }

        /** Fails at boot, not on the first request, if OkHttp's chain no longer matches. */
        fun verifyOkHttpLayout() {
            Class.forName("okhttp3.internal.http.RealInterceptorChain").getDeclaredField("interceptors")
            Class.forName(CONNECT_INTERCEPTOR)
            Class.forName(CALL_SERVER_INTERCEPTOR)
        }
    }
}

/** Terminal interceptor: hands the request to the app's network stack. */
class NativeCallInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val call = chain.call()
        val body = request.body?.let { Buffer().also(it::writeTo).readByteArray() }
        val headers = ArrayList<Pair<String, String>>(request.headers.size + 1)
        for (index in 0 until request.headers.size) {
            headers += request.headers.name(index) to request.headers.value(index)
        }
        request.body?.contentType()?.let { type ->
            if (headers.none { it.first.equals("Content-Type", ignoreCase = true) }) headers += "Content-Type" to type.toString()
        }
        val timeout = maxOf(chain.readTimeoutMillis(), chain.connectTimeoutMillis(), 1000)
        val sentAt = System.currentTimeMillis()
        val result = Host.services.fetch(NativeRequest(request.url.toString(), request.method, headers, body, timeout))
        if (call.isCanceled()) throw IOException("Canceled")

        val responseHeaders =
            Headers
                .Builder()
                .apply { for ((name, value) in result.headers) addUnsafeNonAscii(name, value) }
                .build()
        return Response
            .Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(result.code)
            .message(result.message)
            .headers(responseHeaders)
            .body(result.body.toResponseBody(responseHeaders["Content-Type"]?.toMediaTypeOrNull()))
            .sentRequestAtMillis(sentAt)
            .receivedResponseAtMillis(System.currentTimeMillis())
            .build()
    }
}
