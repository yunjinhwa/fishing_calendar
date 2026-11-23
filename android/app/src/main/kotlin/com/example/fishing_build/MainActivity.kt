package com.example.fishing_build

import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private data class GalleryRequest(
        val limit: Int,
        val maxBytes: Int,
        val result: MethodChannel.Result,
    )

    private class PhotoTooLargeException : IOException()

    private var galleryChannel: MethodChannel? = null
    private var galleryRequest: GalleryRequest? = null
    private val selectedUris = mutableSetOf<Uri>()
    private var selectedMaxBytes = 0
    private var readingPhoto = false
    private val galleryReads = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        galleryChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GALLERY_CHANNEL)
        galleryChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> pickGalleryPhotos(call, result)
                "read" -> readGalleryPhoto(call, result)
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        galleryChannel?.setMethodCallHandler(null)
        galleryChannel = null
        galleryRequest?.result?.success(emptyList<String>())
        galleryRequest = null
        selectedUris.clear()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        galleryReads.shutdownNow()
        super.onDestroy()
    }

    private fun pickGalleryPhotos(call: MethodCall, result: MethodChannel.Result) {
        val limit = call.argument<Int>("limit") ?: 0
        val maxBytes = call.argument<Int>("maxBytes") ?: 0
        if (limit !in 1..MAX_PHOTO_COUNT || maxBytes < 1) {
            result.error("invalid-gallery-request", null, null)
            return
        }
        if (galleryRequest != null || readingPhoto) {
            result.error("gallery-busy", null, null)
            return
        }

        selectedUris.clear()
        galleryRequest = GalleryRequest(limit, minOf(maxBytes, MAX_PHOTO_BYTES), result)

        val galleryPackage = packageManager.resolveActivity(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_GALLERY),
            0,
        )?.activityInfo?.packageName
        if (galleryPackage != null && galleryPackage != "android") {
            val galleryIntent = Intent(Intent.ACTION_GET_CONTENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "image/*"
                setPackage(galleryPackage)
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, limit > 1)
            }
            if (launchGallery(galleryIntent)) return
        }

        val pickIntent = Intent(Intent.ACTION_PICK).apply {
            setDataAndType(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "image/*")
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, limit > 1)
        }
        if (launchGallery(pickIntent)) return

        galleryRequest = null
        result.success(null)
    }

    private fun launchGallery(intent: Intent): Boolean = try {
        startActivityForResult(intent, GALLERY_REQUEST_CODE)
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != GALLERY_REQUEST_CODE) return
        val request = galleryRequest ?: return
        galleryRequest = null
        if (resultCode != RESULT_OK) {
            request.result.success(emptyList<String>())
            return
        }

        val uris = linkedSetOf<Uri>()
        data?.clipData?.let { clip ->
            // Keep at most one extra item so Flutter can report its attachment limit.
            for (index in 0 until minOf(clip.itemCount, request.limit + 1)) {
                clip.getItemAt(index).uri?.let(uris::add)
            }
        }
        if (uris.size <= request.limit) {
            data?.data?.let(uris::add)
        }
        val contentUris = uris.filter { uri ->
            val authority = uri.authority?.substringAfter('@')
            uri.scheme == ContentResolver.SCHEME_CONTENT &&
                !authority.isNullOrEmpty() &&
                packageManager.resolveContentProvider(authority, 0)?.packageName != packageName
        }
        if (contentUris.isEmpty()) {
            request.result.error("photo-read-failed", null, null)
            return
        }
        selectedUris.addAll(contentUris)
        selectedMaxBytes = request.maxBytes
        request.result.success(contentUris.map(Uri::toString))
    }

    private fun readGalleryPhoto(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val maxBytes = minOf(call.argument<Int>("maxBytes") ?: 0, selectedMaxBytes)
        if (readingPhoto || galleryRequest != null) {
            result.error("gallery-busy", null, null)
            return
        }
        if (uri == null || maxBytes < 1 || !selectedUris.remove(uri)) {
            result.error("photo-read-failed", null, null)
            return
        }

        readingPhoto = true
        galleryReads.execute {
            val bytes = try {
                readSelectedPhoto(uri, maxBytes)
            } catch (_: PhotoTooLargeException) {
                finishPhotoRead { result.error("photo-too-large", null, maxBytes + 1) }
                return@execute
            } catch (_: Exception) {
                finishPhotoRead { result.error("photo-read-failed", null, null) }
                return@execute
            }
            finishPhotoRead { result.success(bytes) }
        }
    }

    private fun finishPhotoRead(reply: () -> Unit) {
        runOnUiThread {
            readingPhoto = false
            reply()
        }
    }

    private fun readSelectedPhoto(uri: Uri, maxBytes: Int): ByteArray {
        val stream = contentResolver.openInputStream(uri) ?: throw IOException()
        return stream.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer, 0, minOf(buffer.size, maxBytes + 1 - output.size()))
                if (count < 0) break
                if (output.size() + count > maxBytes) throw PhotoTooLargeException()
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }

    private companion object {
        const val GALLERY_CHANNEL = "fishing_build/external_gallery"
        const val GALLERY_REQUEST_CODE = 4201
        const val MAX_PHOTO_COUNT = 10
        const val MAX_PHOTO_BYTES = 10 * 1024 * 1024
    }
}
