package com.spencerfields.littlebird

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * What was shared to Wren from another app, held until Dart comes to collect it.
 *
 * The iOS half of this channel is a share extension writing into an App Group,
 * because an extension is a separate process that is gone before the app opens.
 * Android has no such indirection: a share is an Intent delivered straight to
 * this Activity. So all that is needed is somewhere to put it in between, and
 * this is that.
 *
 * Held rather than pushed, and for the same reason as on iOS: on a cold start
 * the Intent arrives in `onCreate`, long before Dart is running, and anything
 * sent at that moment would go nowhere. Dart asks on first frame and on every
 * resume, and gets whatever is waiting.
 *
 * Taken, not read. The value is cleared as it is handed over, so a share that
 * fails to import cannot re-import itself on every launch afterwards — which is
 * the failure the iOS side was written to avoid and would be worse here, where
 * reading a post costs money each time.
 *
 * **Links and pictures, since 2026-09-10.** This used to claim `text/plain`
 * only, arguing that images were already reachable through the picker. That was
 * decided before Android could read a reel at all, and it left a real gap: the
 * iOS share extension takes up to twenty images
 * (`NSExtensionActivationSupportsImageWithMaxCount`), so an iPhone user shares
 * screenshots straight into Wren and an Android user could not. A tester found
 * the sharp edge of it on 2026-09-07 — they had a screenshot, chose "From a
 * file", and were told Wren could not read the file.
 *
 * Twenty is iOS's number, matched here on purpose rather than invented.
 */
class ShareInboxPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null

  /** The most recent shared text, or null once collected. */
  private var pendingLink: String? = null

  /** Paths to the most recently shared pictures, empty once collected. */
  private var pendingImages: List<String> = emptyList()

  companion object {
    private const val TAG = "WrenShare"

    /** iOS takes twenty. Matching it keeps one answer to "how many can I send?" */
    private const val MAX_IMAGES = 20

    /** Where copies live. Cleared at the start of every share, see [copyIn]. */
    private const val CACHE_DIR = "shared-images"
  }

  /**
   * Records a share, if that is what this Intent is.
   *
   * Called from both `onCreate` and `onNewIntent`, because `singleTop` means a
   * share arriving while Wren is already in the background goes to the second
   * and never the first. Handling only one of them works perfectly right up
   * until the app has been opened once.
   *
   * A newer share replaces an uncollected older one. Two shares with no visit
   * to the app in between is somebody who changed their mind, and importing the
   * one they abandoned would be the wrong answer twice over.
   *
   * Takes the Context explicitly rather than reading one from the engine
   * binding: copying a picture needs a ContentResolver, and this is called from
   * the Activity, which has one to give.
   */
  fun handleIntent(context: Context, intent: Intent?) {
    if (intent == null) return
    when (intent.action) {
      Intent.ACTION_SEND -> {
        val type = intent.type ?: return
        if (type == "text/plain") {
          val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
          if (text.isNullOrEmpty()) return
          pendingLink = text
          pendingImages = emptyList()
          // Cleared on the Intent as well. The Activity keeps the Intent it was
          // started with, so a rotation re-delivers the same share to `onCreate`
          // and it would import a second time.
          intent.removeExtra(Intent.EXTRA_TEXT)
        } else if (type.startsWith("image/")) {
          val uri = intent.parcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: return
          accept(context, listOf(uri), intent)
        }
      }
      Intent.ACTION_SEND_MULTIPLE -> {
        val type = intent.type ?: return
        if (!type.startsWith("image/")) return
        val uris = intent.parcelableExtraList(Intent.EXTRA_STREAM, Uri::class.java)
        if (uris.isNullOrEmpty()) return
        accept(context, uris, intent)
      }
      else -> return
    }
  }

  /** Copies what was shared and records it, replacing anything uncollected. */
  private fun accept(context: Context, uris: List<Uri>, intent: Intent) {
    val paths = copyIn(context, uris)
    if (paths.isEmpty()) {
      // Nothing readable. Deliberately not recorded as an empty share: Dart
      // would then be handed something that looks like a share and imports
      // nothing, which reads to the user as the app ignoring them.
      Log.w(TAG, "image share had ${uris.size} item(s) and none could be read")
      return
    }
    pendingImages = paths
    pendingLink = null
    intent.removeExtra(Intent.EXTRA_STREAM)
  }

  /**
   * Copies shared pictures somewhere Wren can still read them later.
   *
   * A `content://` URI is granted to this Activity for the life of the Intent.
   * The reader takes a path and runs well after that, so the bytes have to be
   * copied rather than the URI held — a held URI throws SecurityException at
   * exactly the moment it is needed, which looks like a broken reader.
   *
   * The directory is emptied first. These are copies of pictures the user
   * already has, so keeping them past the import is duplicated storage nobody
   * asked for, and clearing on the way in is simpler to reason about than
   * deleting on the way out — which has to survive the import failing.
   */
  private fun copyIn(context: Context, uris: List<Uri>): List<String> {
    val dir = File(context.cacheDir, CACHE_DIR)
    if (dir.isDirectory) dir.listFiles()?.forEach { it.delete() }
    if (!dir.isDirectory && !dir.mkdirs()) {
      Log.w(TAG, "could not create $CACHE_DIR in the cache")
      return emptyList()
    }

    val out = mutableListOf<String>()
    for ((index, uri) in uris.take(MAX_IMAGES).withIndex()) {
      val suffix = when (context.contentResolver.getType(uri)) {
        "image/png" -> "png"
        "image/webp" -> "webp"
        "image/heic", "image/heif" -> "heic"
        else -> "jpg"
      }
      val file = File(dir, "shared-$index.$suffix")
      try {
        context.contentResolver.openInputStream(uri).use { input ->
          if (input == null) {
            Log.w(TAG, "no stream for shared image $index")
            return@use
          }
          file.outputStream().use { input.copyTo(it) }
          out.add(file.absolutePath)
        }
      } catch (e: Exception) {
        // One unreadable picture must not lose the rest of the share.
        Log.w(TAG, "shared image $index could not be copied: ${e.message}")
      }
    }
    if (uris.size > MAX_IMAGES) {
      Log.i(TAG, "share held ${uris.size} images, taking the first $MAX_IMAGES")
    }
    return out
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "littlebird/share").also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "take") {
      result.notImplemented()
      return
    }
    val link = pendingLink
    val images = pendingImages
    pendingLink = null
    pendingImages = emptyList()
    // The same shape the iOS side returns, so Dart has one parser rather than
    // one per platform. Null when there is nothing, which is almost always.
    result.success(
      if (link == null && images.isEmpty()) {
        null
      } else {
        mapOf("link" to link, "images" to images)
      }
    )
  }
}

/**
 * `getParcelableExtra` without the deprecation warning on API 33 and later.
 *
 * The typed overload arrived in Tiramisu and the untyped one was deprecated in
 * the same release, so both spellings are needed to compile cleanly against a
 * modern SDK while still running on the minimum.
 */
private fun <T : Any> Intent.parcelableExtra(name: String, type: Class<T>): T? =
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
    getParcelableExtra(name, type)
  } else {
    @Suppress("DEPRECATION")
    getParcelableExtra(name)
  }

private fun <T : Any> Intent.parcelableExtraList(name: String, type: Class<T>): List<T>? =
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
    getParcelableArrayListExtra(name, type)
  } else {
    @Suppress("DEPRECATION")
    getParcelableArrayListExtra(name)
  }
