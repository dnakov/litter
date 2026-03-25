package com.litter.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream

private const val WALLPAPER_PREFS_NAME = "litter_wallpaper_prefs"
private const val CHAT_WALLPAPER_KEY = "chatWallpaper"
private const val CHAT_WALLPAPER_NONE = "none"
private const val CHAT_WALLPAPER_CUSTOM = "custom"
private const val CUSTOM_WALLPAPER_FILE = "custom_wallpaper.jpg"
private const val MAX_WALLPAPER_DIMENSION = 2048

object WallpaperManager {
    private const val TAG = "WallpaperManager"
    private var appContext: Context? = null
    private var initialized = false

    var wallpaperBitmap by mutableStateOf<Bitmap?>(null)
        private set

    var isWallpaperSet by mutableStateOf(false)
        private set

    fun initialize(context: Context) {
        if (initialized) {
            return
        }
        appContext = context.applicationContext
        loadCurrentWallpaper()
        initialized = true
    }

    suspend fun setCustomFromUri(uri: Uri): Boolean {
        val context = appContext ?: return false
        val bitmap = decodeBitmap(context, uri) ?: return false
        val wroteFile =
            withContext(Dispatchers.IO) {
                runCatching {
                    customWallpaperFile(context).parentFile?.mkdirs()
                    FileOutputStream(customWallpaperFile(context)).use { stream ->
                        check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, stream)) {
                            "Bitmap compression failed"
                        }
                        stream.fd.sync()
                    }
                }.onFailure { error ->
                    Log.e(TAG, "Failed to write wallpaper file for uri=$uri", error)
                }.isSuccess
            }
        if (!wroteFile) {
            return false
        }

        prefs(context)
            .edit()
            .putString(CHAT_WALLPAPER_KEY, CHAT_WALLPAPER_CUSTOM)
            .apply()
        wallpaperBitmap = bitmap
        isWallpaperSet = true
        return true
    }

    fun clear() {
        val context = appContext ?: return
        prefs(context)
            .edit()
            .putString(CHAT_WALLPAPER_KEY, CHAT_WALLPAPER_NONE)
            .apply()
        wallpaperBitmap = null
        isWallpaperSet = false
        customWallpaperFile(context).delete()
    }

    private fun loadCurrentWallpaper() {
        val context = appContext ?: return
        when (prefs(context).getString(CHAT_WALLPAPER_KEY, CHAT_WALLPAPER_NONE)) {
            CHAT_WALLPAPER_CUSTOM -> {
                wallpaperBitmap = BitmapFactory.decodeFile(customWallpaperFile(context).absolutePath)
                isWallpaperSet = wallpaperBitmap != null
            }
            else -> {
                wallpaperBitmap = null
                isWallpaperSet = false
            }
        }
    }

    private suspend fun decodeBitmap(
        context: Context,
        uri: Uri,
    ): Bitmap? =
        withContext(Dispatchers.IO) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                runCatching {
                    val source = ImageDecoder.createSource(context.contentResolver, uri)
                    ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                        val size = info.size
                        val largestDimension = maxOf(size.width, size.height)
                        if (largestDimension > MAX_WALLPAPER_DIMENSION) {
                            val scale = MAX_WALLPAPER_DIMENSION.toFloat() / largestDimension.toFloat()
                            val targetWidth = (size.width * scale).toInt().coerceAtLeast(1)
                            val targetHeight = (size.height * scale).toInt().coerceAtLeast(1)
                            decoder.setTargetSize(targetWidth, targetHeight)
                        }
                    }
                }.onFailure { error ->
                    Log.w(TAG, "ImageDecoder wallpaper decode failed for uri=$uri; falling back", error)
                }.getOrNull()?.let { decoded ->
                    return@withContext decoded
                }
            }

            val resolver = context.contentResolver
            val bounds =
                BitmapFactory.Options().apply {
                    inJustDecodeBounds = true
                }
            resolver.openInputStream(uri)?.use { stream ->
                BitmapFactory.decodeStream(stream, null, bounds)
            } ?: return@withContext null

            val options =
                BitmapFactory.Options().apply {
                    inSampleSize =
                        calculateInSampleSize(
                            width = bounds.outWidth,
                            height = bounds.outHeight,
                            maxWidth = MAX_WALLPAPER_DIMENSION,
                            maxHeight = MAX_WALLPAPER_DIMENSION,
                        )
                }
            resolver.openInputStream(uri)?.use { stream ->
                BitmapFactory.decodeStream(stream, null, options)
            }.also { decoded ->
                if (decoded == null) {
                    Log.e(TAG, "BitmapFactory wallpaper decode returned null for uri=$uri")
                }
            }
        }

    private fun calculateInSampleSize(
        width: Int,
        height: Int,
        maxWidth: Int,
        maxHeight: Int,
    ): Int {
        var sampleSize = 1
        if (width <= 0 || height <= 0) {
            return sampleSize
        }

        while ((width / sampleSize) > maxWidth || (height / sampleSize) > maxHeight) {
            sampleSize *= 2
        }
        return sampleSize
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(WALLPAPER_PREFS_NAME, Context.MODE_PRIVATE)

    private fun customWallpaperFile(context: Context): File =
        File(context.filesDir, CUSTOM_WALLPAPER_FILE)
}
