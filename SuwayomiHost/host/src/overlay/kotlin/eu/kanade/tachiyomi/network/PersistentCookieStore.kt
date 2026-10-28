package eu.kanade.tachiyomi.network

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Modified for MoeReader: overlay of server/src/main/kotlin/eu/kanade/tachiyomi/network/PersistentCookieStore.kt
 * with the same public API. Upstream keeps its own cookie map and rewrites a
 * SharedPreferences file on every change. Here the app's cookie storage is the
 * single store: the same jar serves the Swift engine, cover and page loads and
 * the WKWebView challenge solver, so a clearance cookie obtained anywhere
 * applies to extension requests, and the host does no cookie disk I/O at all.
 * Matching (domain, path, secure, expiry) is the platform's.
 */

import android.content.Context
import moe.reader.suwayomi.Host
import moe.reader.suwayomi.NativeCookie
import okhttp3.Cookie
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.CookieStore
import java.net.HttpCookie
import java.net.URI

@Suppress("UNUSED_PARAMETER")
class PersistentCookieStore(
    context: Context,
) : CookieStore {
    fun addAll(
        url: HttpUrl,
        cookies: List<Cookie>,
    ) {
        Host.services.saveCookies(url.toString(), cookies.map { it.toNative() })
    }

    override fun removeAll(): Boolean {
        val hadCookies = Host.services.allCookies().isNotEmpty()
        Host.services.removeCookies(null, null)
        return hadCookies
    }

    fun remove(uri: URI) {
        Host.services.removeCookies(uri.normalizedUrl(), null)
    }

    override fun get(uri: URI): List<HttpCookie> = get(uri.normalizedUrl().toHttpUrlOrNull() ?: return emptyList()).map { it.toHttpCookie() }

    fun get(url: HttpUrl): List<Cookie> = Host.services.cookies(url.toString()).map { it.toOkHttp() }

    override fun add(
        uri: URI?,
        cookie: HttpCookie,
    ) {
        val native = cookie.toNative(uri?.host) ?: return
        Host.services.saveCookies(uri?.normalizedUrl() ?: "https://${native.domain}/", listOf(native))
    }

    override fun getCookies(): List<HttpCookie> = getStoredCookies().map { it.toHttpCookie() }

    fun getStoredCookies(): List<Cookie> = Host.services.allCookies().map { it.toOkHttp() }

    override fun getURIs(): List<URI> =
        Host.services
            .allCookies()
            .map { it.domain }
            .distinct()
            .map { URI("http://$it") }

    override fun remove(
        uri: URI?,
        cookie: HttpCookie,
    ): Boolean {
        val domain = (cookie.domain ?: uri?.host ?: return false).removePrefix(".")
        val url = uri?.normalizedUrl() ?: "https://$domain/"
        val present = Host.services.cookies(url).any { it.name == cookie.name }
        if (present) Host.services.removeCookies(url, cookie.name)
        return present
    }

    private fun URI.normalizedUrl(): String = if (scheme == null) "http://$this" else toString()

    private fun Cookie.toNative(): NativeCookie =
        NativeCookie(
            name = name,
            value = value,
            domain = domain,
            path = path,
            expiresAt = if (persistent) expiresAt else Long.MAX_VALUE,
            secure = secure,
            httpOnly = httpOnly,
            hostOnly = hostOnly,
        )

    private fun NativeCookie.toOkHttp(): Cookie =
        Cookie
            .Builder()
            .name(name)
            .value(value)
            .path(path.ifEmpty { "/" })
            .apply {
                val bare = domain.removePrefix(".")
                if (hostOnly) hostOnlyDomain(bare) else domain(bare)
                if (expiresAt != Long.MAX_VALUE) expiresAt(expiresAt)
                if (secure) secure()
                if (httpOnly) httpOnly()
            }.build()

    private fun HttpCookie.toNative(urlDomain: String?): NativeCookie? {
        val rawDomain = domain ?: urlDomain ?: return null
        return NativeCookie(
            name = name,
            value = value,
            domain = rawDomain.removePrefix("."),
            path = path ?: "/",
            expiresAt = if (maxAge == -1L) Long.MAX_VALUE else System.currentTimeMillis() + maxAge * 1000,
            secure = secure,
            httpOnly = isHttpOnly,
            hostOnly = domain == null || !domain.startsWith('.'),
        )
    }

    private fun Cookie.toHttpCookie(): HttpCookie {
        val source = this
        return HttpCookie(source.name, source.value).apply {
            domain = if (source.hostOnly) source.domain else "." + source.domain
            path = source.path
            secure = source.secure
            maxAge = if (source.persistent) ((source.expiresAt - System.currentTimeMillis()) / 1000).coerceAtLeast(0) else -1
            isHttpOnly = source.httpOnly
        }
    }
}
