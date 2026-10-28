package moe.reader.suwayomi

import java.io.IOException
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.net.http.HttpTimeoutException
import java.time.Duration

/**
 * HostServices for JVM tests: java.net.http instead of URLSession and an
 * in-memory cookie list instead of the app's cookie storage. No browser and no
 * JavaScript engine, like the Linux harness.
 */
class DesktopServices : HostServices {
    private val client =
        HttpClient
            .newBuilder()
            .followRedirects(HttpClient.Redirect.NEVER)
            .connectTimeout(Duration.ofSeconds(30))
            .build()

    private val cookies = mutableListOf<NativeCookie>()
    private val restricted = setOf("host", "connection", "content-length", "expect", "upgrade", "keep-alive", "transfer-encoding")

    /** Requests that went through this transport. */
    val fetches = java.util.concurrent.atomic.AtomicInteger()

    override fun fetch(request: NativeRequest): NativeResponse {
        fetches.incrementAndGet()
        val builder =
            HttpRequest
                .newBuilder(URI(request.url))
                .timeout(Duration.ofMillis(request.timeoutMillis.toLong()))
                .method(request.method, request.body?.let { HttpRequest.BodyPublishers.ofByteArray(it) } ?: HttpRequest.BodyPublishers.noBody())
        for ((name, value) in request.headers) {
            if (name.lowercase() !in restricted) builder.header(name, value)
        }
        val response =
            try {
                client.send(builder.build(), HttpResponse.BodyHandlers.ofByteArray())
            } catch (timeout: HttpTimeoutException) {
                throw java.net.SocketTimeoutException(timeout.message)
            } catch (interrupted: InterruptedException) {
                throw IOException(interrupted)
            }
        val headers = response.headers().map().flatMap { (name, values) -> values.map { name to it } }.filter { !it.first.startsWith(":") }
        return NativeResponse(response.statusCode(), "", headers, response.body())
    }

    private fun matches(
        cookie: NativeCookie,
        uri: URI,
    ): Boolean {
        val host = uri.host?.lowercase() ?: return false
        val domain = cookie.domain.lowercase()
        val domainOk = if (cookie.hostOnly) host == domain else host == domain || host.endsWith(".$domain")
        val path = uri.rawPath.ifEmpty { "/" }
        return domainOk && path.startsWith(cookie.path) && (!cookie.secure || uri.scheme == "https") &&
            cookie.expiresAt > System.currentTimeMillis()
    }

    @Synchronized
    override fun cookies(url: String): List<NativeCookie> = cookies.filter { matches(it, URI(url)) }

    @Synchronized
    override fun saveCookies(
        url: String,
        cookies: List<NativeCookie>,
    ) {
        for (cookie in cookies) {
            this.cookies.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
            this.cookies += cookie
        }
    }

    @Synchronized
    override fun removeCookies(
        url: String?,
        name: String?,
    ) {
        cookies.removeAll { (url == null || matches(it, URI(url))) && (name == null || it.name == name) }
    }

    @Synchronized
    override fun allCookies(): List<NativeCookie> = cookies.toList()

    override fun solveChallenge(
        url: String,
        userAgent: String,
    ): Boolean = false

    override fun jsCreate(): Long = throw UnsupportedOperationException("no JavaScript engine in JVM tests")

    override fun jsEvaluate(
        context: Long,
        script: String,
    ): JsValue = throw JsEvaluationException("no JavaScript engine in JVM tests")

    override fun jsClose(context: Long) = Unit

    override fun log(
        level: Int,
        message: String,
    ) {
        println("[host] $message")
    }
}
