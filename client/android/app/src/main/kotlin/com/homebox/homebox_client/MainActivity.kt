package com.homebox.homebox_client

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.view.WindowManager
import androidx.core.content.FileProvider
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
    private val fileShareChannel = "homebox/file_share"
    private val syncFolderChannel = "homebox/sync_folder"
    private val saveFileRequestCode = 4173
    private val selectSyncFolderRequestCode = 4174

    private var pendingResult: MethodChannel.Result? = null
    private var pendingSourcePath: String? = null
    private var pendingSyncFolderResult: MethodChannel.Result? = null

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileShareChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "shareFile") {
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
                val sourceFile = File(sourcePath)
                if (!isShareableCacheFile(sourceFile)) {
                    result.error("invalid_source", "The shared file must be in HomeBox's temporary cache.", null)
                    return@setMethodCallHandler
                }
                try {
                    val fileUri = FileProvider.getUriForFile(
                        this,
                        "$packageName.shared_files",
                        sourceFile,
                    )
                    val shareIntent = Intent(Intent.ACTION_SEND).apply {
                        type = mimeType
                        putExtra(Intent.EXTRA_STREAM, fileUri)
                        putExtra(Intent.EXTRA_TITLE, suggestedName)
                        clipData = ClipData.newRawUri(suggestedName, fileUri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(Intent.createChooser(shareIntent, "Share file"))
                    result.success(null)
                } catch (e: Exception) {
                    result.error("share_failed", e.message, null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, syncFolderChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "selectFolder" -> selectSyncFolder(result)
                    "createDirectory" -> withTreeAndPath(call, result) { treeUri, relativePath ->
                        runSyncFolderOperation(result) {
                            ensureDirectory(treeUri, relativePath)
                            null
                        }
                    }
                    "writeFile" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        if (sourcePath.isNullOrEmpty()) {
                            result.error("invalid_arguments", "sourcePath is required.", null)
                            return@setMethodCallHandler
                        }
                        withTreeAndPath(call, result) { treeUri, relativePath ->
                            runSyncFolderOperation(result) {
                                val destination = findOrCreateFile(treeUri, relativePath)
                                contentResolver.openOutputStream(destination, "wt")?.use { output ->
                                    FileInputStream(File(sourcePath)).use { input -> input.copyTo(output) }
                                } ?: throw IllegalStateException("Could not open the sync-folder destination.")
                                null
                            }
                        }
                    }
                    "fileExists" -> withTreeAndPath(call, result) { treeUri, relativePath ->
                        runSyncFolderOperation(result) {
                            findDocument(treeUri, relativePath) != null
                        }
                    }
                    "deleteFile" -> withTreeAndPath(call, result) { treeUri, relativePath ->
                        runSyncFolderOperation(result) {
                            findDocument(treeUri, relativePath)?.let { document ->
                                DocumentsContract.deleteDocument(contentResolver, document)
                            }
                            null
                        }
                    }
                    "openFile" -> {
                        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                        withTreeAndPath(call, result) { treeUri, relativePath ->
                            Thread {
                                try {
                                    val document = findDocument(treeUri, relativePath)
                                    runOnUiThread {
                                        if (document == null) {
                                            result.success(false)
                                            return@runOnUiThread
                                        }
                                        val intent = Intent(Intent.ACTION_VIEW).apply {
                                            setDataAndType(document, mimeType)
                                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                        }
                                        try {
                                            startActivity(Intent.createChooser(intent, "Open file"))
                                            result.success(true)
                                        } catch (e: Exception) {
                                            result.error("open_failed", e.message, null)
                                        }
                                    }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("open_failed", e.message, null) }
                                }
                            }
                            .start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun selectSyncFolder(result: MethodChannel.Result) {
        if (pendingSyncFolderResult != null) {
            result.error("busy", "A folder selection is already in progress.", null)
            return
        }
        pendingSyncFolderResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        try {
            startActivityForResult(intent, selectSyncFolderRequestCode)
        } catch (e: Exception) {
            pendingSyncFolderResult = null
            result.error("folder_selection_failed", e.message, null)
        }
    }

    /// A Flutter caller must not be able to turn this channel into a general
    /// file-read grant. Only files created under the dedicated cache root can
    /// be exposed to another application.
    private fun isShareableCacheFile(file: File): Boolean = try {
        val shareRoot = File(cacheDir, "homebox_shared").canonicalFile
        val candidate = file.canonicalFile
        candidate.isFile && candidate.path.startsWith("${shareRoot.path}${File.separator}")
    } catch (_: Exception) {
        false
    }

    private fun withTreeAndPath(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
        action: (Uri, String) -> Unit,
    ) {
        val rawTreeUri = call.argument<String>("treeUri")
        val relativePath = call.argument<String>("relativePath")
        if (rawTreeUri.isNullOrEmpty() || relativePath.isNullOrEmpty() || !isSafeRelativePath(relativePath)) {
            result.error("invalid_arguments", "treeUri and a safe relativePath are required.", null)
            return
        }
        try {
            action(Uri.parse(rawTreeUri), relativePath)
        } catch (e: Exception) {
            result.error("sync_folder_failed", e.message, null)
        }
    }

    private fun runSyncFolderOperation(result: MethodChannel.Result, operation: () -> Any?) {
        Thread {
            try {
                val value = operation()
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread { result.error("sync_folder_failed", e.message, null) }
            }
        }.start()
    }

    private fun isSafeRelativePath(path: String): Boolean =
        path.split('/').all { it.isNotEmpty() && it != "." && it != ".." && !it.contains('\\') }

    private fun ensureDirectory(treeUri: Uri, relativePath: String): Uri {
        var current = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        for (part in relativePath.split('/')) {
            val existing = findChild(current, part)
            current = existing ?: DocumentsContract.createDocument(
                contentResolver,
                current,
                DocumentsContract.Document.MIME_TYPE_DIR,
                part,
            ) ?: throw IllegalStateException("Could not create sync-folder directory.")
        }
        return current
    }

    private fun findOrCreateFile(treeUri: Uri, relativePath: String): Uri {
        val parts = relativePath.split('/')
        val parent = if (parts.size == 1) {
            DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
        } else {
            ensureDirectory(treeUri, parts.dropLast(1).joinToString("/"))
        }
        val existing = findChild(parent, parts.last())
        if (existing != null) return existing
        return DocumentsContract.createDocument(
            contentResolver,
            parent,
            "application/octet-stream",
            parts.last(),
        ) ?: throw IllegalStateException("Could not create sync-folder file.")
    }

    private fun findDocument(treeUri: Uri, relativePath: String): Uri? {
        var current = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        for (part in relativePath.split('/')) {
            current = findChild(current, part) ?: return null
        }
        return current
    }

    private fun findChild(parent: Uri, name: String): Uri? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            parent,
            DocumentsContract.getDocumentId(parent),
        )
        contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            while (cursor.moveToNext()) {
                if (name == cursor.getString(nameIndex)) {
                    return DocumentsContract.buildDocumentUriUsingTree(parent, cursor.getString(idIndex))
                }
            }
        }
        return null
    }

    /// A best-effort hint for the SAF picker to open in the public Downloads
    /// folder; the OS falls back to its own default if this URI form isn't
    /// recognized on a given device.
    private fun downloadsTreeUri(): Uri =
        Uri.parse("content://com.android.externalstorage.documents/document/primary:Download")

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == selectSyncFolderRequestCode) {
            val result = pendingSyncFolderResult ?: return
            pendingSyncFolderResult = null
            val treeUri = data?.data
            if (resultCode != Activity.RESULT_OK || treeUri == null) {
                result.success(null)
                return
            }
            try {
                val granted = (data?.flags ?: 0) and (
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
                contentResolver.takePersistableUriPermission(treeUri, granted)
                result.success(treeUri.toString())
            } catch (e: Exception) {
                result.error("folder_permission_failed", e.message, null)
            }
            return
        }
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
