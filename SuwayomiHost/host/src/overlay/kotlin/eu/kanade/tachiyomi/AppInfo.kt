package eu.kanade.tachiyomi

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Modified for MoeReader: overlay of server/src/main/kotlin/eu/kanade/tachiyomi/AppInfo.kt.
 * The version comes from the host instead of the server's generated BuildConfig,
 * and the image types are the ones the app's ImageIO decoder reads.
 */

import moe.reader.suwayomi.HostVersion

object AppInfo {
    /** @since extension-lib 1.3 */
    fun getVersionCode(): Int = HostVersion.CODE

    /** @since extension-lib 1.3 */
    fun getVersionName(): String = HostVersion.NAME

    /**
     * MIME types the reader decodes.
     *
     * @since extension-lib 1.5
     */
    fun getSupportedImageMimeTypes(): List<String> =
        listOf("image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heif", "image/jxl")
}
