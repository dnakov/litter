package com.litter.android.state

import android.content.Context
import uniffi.codex_mobile_client.AppStore
import uniffi.codex_mobile_client.ThreadKey
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Wraps the Rust AppStore recording API with local file persistence.
 * Recordings are stored as JSON files in the app's filesDir/recordings/ directory.
 */
object MessageRecorder {

    private const val DIR_NAME = "recordings"

    private fun recordingsDir(context: Context): File {
        return File(context.filesDir, DIR_NAME).also { it.mkdirs() }
    }

    fun startRecording(store: AppStore) {
        store.startRecording()
    }

    fun stopRecording(context: Context, store: AppStore): File? {
        val json = store.stopRecording()
        if (json.isBlank()) return null
        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val file = File(recordingsDir(context), "recording_$timestamp.json")
        file.writeText(json)
        return file
    }

    fun isRecording(store: AppStore): Boolean {
        return store.isRecording()
    }

    suspend fun startReplay(store: AppStore, file: File, targetKey: ThreadKey) {
        val data = file.readText()
        store.startReplay(data, targetKey)
    }

    fun listRecordings(context: Context): List<File> {
        return recordingsDir(context)
            .listFiles { f -> f.extension == "json" }
            ?.sortedByDescending { it.lastModified() }
            ?: emptyList()
    }

    fun deleteRecording(file: File): Boolean {
        return file.delete()
    }
}
