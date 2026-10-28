package eu.kanade.tachiyomi.network

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Modified for MoeReader: overlay of server/src/main/kotlin/eu/kanade/tachiyomi/network/NetworkHelper.kt.
 * Differences, all for the phone's CPU and radio budget:
 *  - NativeNetInterceptor runs first, so every call's final hop is the app's
 *    URLSession (HTTP/2, the system TLS stack, connection reuse shared with
 *    the app) instead of sockets and TLS interpreted inside the JVM;
 *  - no OkHttp disk cache and no logging interceptor (both cost interpreted
 *    work on every request for no benefit to a reader);
 *  - cookies live in the app's cookie storage (see PersistentCookieStore).
 * Like upstream, no Brotli interceptor: lib-1.6 extensions assert it is absent.
 */

import android.content.Context
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import moe.reader.suwayomi.Host
import moe.reader.suwayomi.net.NativeNetInterceptor
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import java.net.CookieHandler
import java.net.CookieManager
import java.net.CookiePolicy
import java.util.concurrent.TimeUnit

class NetworkHelper(
    context: Context,
) {
    val cookieStore = PersistentCookieStore(context)
    private val cookieJar: CookieJar = PersistentCookieJar(cookieStore)

    init {
        CookieHandler.setDefault(CookieManager(cookieStore, CookiePolicy.ACCEPT_ALL))
    }

    private val userAgent = Host.config.userAgent

    fun defaultUserAgentProvider(): String = userAgent

    private val baseClientBuilder: OkHttpClient.Builder
        get() =
            OkHttpClient
                .Builder()
                .cookieJar(cookieJar)
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .callTimeout(2, TimeUnit.MINUTES)
                // Must stay first: it routes the call through the app's network stack.
                .addInterceptor(NativeNetInterceptor())
                .addInterceptor(UncaughtExceptionInterceptor())
                .addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))
                .addInterceptor(CloudflareInterceptor())

    val client: OkHttpClient by lazy { baseClientBuilder.build() }

    @Deprecated("The regular client handles Cloudflare by default")
    @Suppress("UNUSED")
    val cloudflareClient: OkHttpClient by lazy { client }
}
