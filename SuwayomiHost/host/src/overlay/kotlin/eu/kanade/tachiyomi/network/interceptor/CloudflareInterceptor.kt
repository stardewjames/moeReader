package eu.kanade.tachiyomi.network.interceptor

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Modified for MoeReader: overlay of server/src/main/kotlin/eu/kanade/tachiyomi/network/interceptor/CloudflareInterceptor.kt.
 * Upstream solves browser checks in a desktop Chromium (KCEF) inside the JVM.
 * Here the app's off-screen WKWebView does it: the interceptor recognises the
 * interstitial, asks the app to clear it with the exact user agent the retry
 * sends (the clearance is bound to it), and retries once. The retry re-runs the
 * rest of the chain, so BridgeInterceptor reads the fresh clearance cookie from
 * the shared cookie storage. Detection matches the Swift engine's
 * VMChallengeDetector markers.
 */

import moe.reader.suwayomi.Host
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

class CloudflareInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val response = chain.proceed(request)
        if (!isChallenge(response)) return response

        val userAgent = request.header("User-Agent")?.takeIf { it.isNotBlank() } ?: Host.config.userAgent
        response.close()
        val solved =
            synchronized(solveLock) {
                Host.services.solveChallenge(request.url.toString(), userAgent)
            }
        if (!solved) throw IOException("Failed to bypass the browser check at ${request.url.host}")
        return chain.proceed(request)
    }

    companion object {
        private val solveLock = Any()

        private val challengeCodes = setOf(403, 429, 503)
        private val clearanceCookiePrefixes = listOf("__ddg1_", "__ddg2_", "__ddg5_")
        private val bodyMarkers =
            listOf(
                "cf-chl",
                "cf-browser-verification",
                "_cf_chl_opt",
                "challenge-platform",
                "just a moment",
                "checking your browser before accessing",
                "ddos-guard.net",
            ) + clearanceCookiePrefixes

        fun isChallenge(response: Response): Boolean {
            if (response.code !in challengeCodes) return false
            val server = response.header("Server")?.lowercase().orEmpty()
            if ("cloudflare" in server || "ddos-guard" in server) return true
            for (value in response.headers("Set-Cookie")) {
                val lowered = value.lowercase()
                if (clearanceCookiePrefixes.any { it in lowered }) return true
            }
            val text = runCatching { response.peekBody(8192).string() }.getOrDefault("").lowercase()
            return bodyMarkers.any { it in text }
        }
    }
}
