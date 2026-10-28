package moe.reader.suwayomi

import android.webkit.CookieManager
import com.sun.net.httpserver.HttpServer
import eu.kanade.tachiyomi.network.NetworkHelper
import okhttp3.Request
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.GZIPOutputStream
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Extension HTTP through NetworkHelper.client: the final hop is the app's
 * transport (here DesktopServices), while redirects, cookies and gzip stay
 * OkHttp's job, as they are on the phone.
 */
class NativeNetworkTest {
    private lateinit var server: HttpServer
    private val fetches = AtomicInteger()
    private lateinit var base: String

    @BeforeTest
    fun start() {
        TestHost.boot()
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/start") { exchange ->
            fetches.incrementAndGet()
            exchange.responseHeaders.add("Set-Cookie", "session=abc; Path=/")
            exchange.responseHeaders.add("Location", "/landing")
            exchange.sendResponseHeaders(302, -1)
            exchange.close()
        }
        server.createContext("/landing") { exchange ->
            fetches.incrementAndGet()
            val cookie = exchange.requestHeaders.getFirst("Cookie").orEmpty()
            val body =
                ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write("cookie=$cookie".toByteArray()) } }.toByteArray()
            exchange.responseHeaders.add("Content-Encoding", "gzip")
            exchange.sendResponseHeaders(200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        base = "http://127.0.0.1:${server.address.port}"
    }

    @AfterTest
    fun stop() {
        server.stop(0)
    }

    @Test
    fun redirectsCookiesAndGzipRunInOkHttpOverTheAppTransport() {
        val before = TestHost.services.fetches.get()
        val client = Injekt.get<NetworkHelper>().client
        client.newCall(Request.Builder().url("$base/start").build()).execute().use { response ->
            assertEquals(200, response.code)
            assertEquals("cookie=session=abc", response.body.string())
            assertEquals(302, response.priorResponse?.code, "the redirect hop is OkHttp's")
        }
        assertEquals(2, fetches.get())
        assertEquals(2, TestHost.services.fetches.get() - before, "both hops went through the app transport")
        // The cookie went into the app's store, visible to android.webkit.
        assertTrue(CookieManager.getInstance().getCookie(base).contains("session=abc"))
    }

    @Test
    fun clientsDerivedByExtensionsKeepTheAppTransport() {
        val derived =
            Injekt
                .get<NetworkHelper>()
                .client
                .newBuilder()
                .addInterceptor { chain -> chain.proceed(chain.request().newBuilder().header("X-Ext", "1").build()) }
                .build()
        val before = TestHost.services.fetches.get()
        derived.newCall(Request.Builder().url("$base/landing").build()).execute().use { response ->
            assertEquals(200, response.code)
        }
        assertEquals(1, TestHost.services.fetches.get() - before)
    }
}
