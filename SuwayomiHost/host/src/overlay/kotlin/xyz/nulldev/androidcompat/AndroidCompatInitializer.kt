package xyz.nulldev.androidcompat

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Modified for MoeReader: overlay of AndroidCompat's AndroidCompatInitializer.
 * The config modules are registered by moe.reader.suwayomi.Host before Koin
 * starts, and there is no desktop Chromium (KCEF): an extension that drives an
 * android.webkit.WebView gets a typed UnsupportedOperationException instead of
 * a browser the phone cannot host inside the JVM. Browser checks are cleared by
 * the app's WKWebView through CloudflareInterceptor instead.
 */

import android.webkit.WebView
import moe.reader.suwayomi.Host

class AndroidCompatInitializer {
    fun init() {
        WebView.setProviderFactory { _: WebView ->
            throw UnsupportedOperationException("android.webkit.WebView is not available in the Suwayomi runtime")
        }
        System.setProperty("http.agent", Host.config.userAgent)
    }
}
