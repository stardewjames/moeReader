package moe.reader.suwayomi

import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.interceptor.rateLimit
import okhttp3.CookieJar
import kotlin.time.Duration.Companion.seconds
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Page images skip the JVM only for clients that add nothing to a request;
 * anything an extension adds, rate limits included, keeps the host path.
 */
class PlainClientTest {
    @BeforeTest
    fun boot() = TestHost.boot()

    private val base get() = Injekt.get<NetworkHelper>().client

    @Test
    fun theHostsBaseClientIsPlain() {
        assertTrue(SourceCalls.isPlainClient(base))
        assertTrue(SourceCalls.isPlainClient(base.newBuilder().build()))
    }

    @Test
    fun extensionInterceptorsRateLimitsAndNetworkInterceptorsAreNot() {
        assertFalse(SourceCalls.isPlainClient(base.newBuilder().addInterceptor { it.proceed(it.request()) }.build()))
        assertFalse(SourceCalls.isPlainClient(base.newBuilder().rateLimit(2, 1.seconds).build()))
        assertFalse(SourceCalls.isPlainClient(base.newBuilder().addNetworkInterceptor { it.proceed(it.request()) }.build()))
        assertFalse(SourceCalls.isPlainClient(base.newBuilder().followRedirects(false).build()))
        assertFalse(SourceCalls.isPlainClient(base.newBuilder().followSslRedirects(false).build()))
        assertFalse(SourceCalls.isPlainClient(base.newBuilder().cookieJar(CookieJar.NO_COOKIES).build()))
    }
}
