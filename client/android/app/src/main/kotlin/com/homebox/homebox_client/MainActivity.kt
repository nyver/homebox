package com.homebox.homebox_client

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/// Backs [MethodChannelAndroidFileSaver] (lib/core/platform/android_file_saver.dart).
/// `file_selector_android` never implemented a save dialog, so decrypted
/// downloads are handed to the OS "Save As" picker (`ACTION_CREATE_DOCUMENT`)
/// directly here, hinted to open in Downloads. This activity only copies
/// already-decrypted bytes from a local temp file to the user's chosen
/// destination — it never touches the E2EE layer.
class MainActivity : FlutterFragmentActivity() {
    private val fileSaveChannel = "homebox/file_save"
    private val saveFileRequestCode = 4173

    private var pendingResult: MethodChannel.Result? = null
    private var pendingSourcePath: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Excludes HomeBox from the OS recent-apps thumbnail and blocks
        // screenshots/screen recording, so decrypted file names and content
        // can never leak outside the app-level biometric lock (main.dart's
        // `_BiometricLockScreen`) — otherwise the last frame rendered before
        // backgrounding (which Android keeps for the task switcher) could
        // still show unlocked content even while the in-app lock is engaged.
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileSaveChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "saveFile") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val sourcePath = call.argument<String>("sourcePath")
                val suggestedName = call.argument<String>("suggestedName")
                val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                if (sourcePath.isNullOrEmpty() || suggestedName.isNullOrEmpty()) {
                    result.error("invalid_arguments", "sourcePath and suggestedName are required.", null)
                    return@setMethodCallHandler
                }
                if (pendingResult != null) {
                    result.error("busy", "A save is already in progress.", null)
                    return@setMethodCallHandler
                }
                pendingResult = result
                pendingSourcePath = sourcePath
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mimeType
                    putExtra(Intent.EXTRA_TITLE, suggestedName)
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, downloadsTreeUri())
                }
                try {
                    startActivityForResult(intent, saveFileRequestCode)
                } catch (e: Exception) {
                    pendingResult = null
                    pendingSourcePath = null
                    result.error("save_failed", e.message, null)
                }
            }
    }

    /// A best-effort hint for the SAF picker to open in the public Downloads
    /// folder; the OS falls back to its own default if this URI form isn't
    /// recognized on a given device.
    private fun downloadsTreeUri(): Uri =
        Uri.parse("content://com.android.externalstorage.documents/document/primary:Download")

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != saveFileRequestCode) return
        val result = pendingResult ?: return
        val sourcePath = pendingSourcePath
        pendingResult = null
        pendingSourcePath = null

        val destinationUri = data?.data
        if (resultCode != Activity.RESULT_OK || destinationUri == null || sourcePath == null) {
            result.success(null)
            return
        }
        // Copies off the main thread: a downloaded file can be up to 500 MiB
        // (homeBoxMaxPlaintextFileSize), and copying that synchronously here
        // would risk an ANR. MethodChannel.Result must still be completed on
        // the platform thread, hence the runOnUiThread hop back.
        Thread {
            try {
                val output = contentResolver.openOutputStream(destinationUri)
                    ?: throw IllegalStateException("Could not open the selected destination.")
                output.use { destination ->
                    FileInputStream(File(sourcePath)).use { source -> source.copyTo(destination) }
                }
                runOnUiThread { result.success(destinationUri.toString()) }
            } catch (e: Exception) {
                runOnUiThread { result.error("save_failed", e.message, null) }
            }
        }.start()
    }
}
