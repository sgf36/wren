package com.spencerfields.littlebird

import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Text shared to Wren from another app, held until Dart comes to collect it.
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
 * Only `text/plain` is claimed. Instagram, TikTok and YouTube all share a link
 * as text, and claiming images as well would put Wren in the share sheet of
 * every photo on the phone in exchange for a path the app already has a better
 * route to.
 */
class ShareInboxPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null

  /** The most recent share, or null once it has been collected. */
  private var pending: String? = null

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
   */
  fun handleIntent(intent: Intent?) {
    if (intent == null || intent.action != Intent.ACTION_SEND) return
    if (intent.type != "text/plain") return
    val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
    if (text.isNullOrEmpty()) return
    pending = text
    // Cleared on the Intent as well. The Activity keeps the Intent it was
    // started with, so a rotation re-delivers the same share to `onCreate` and
    // it would import a second time.
    intent.removeExtra(Intent.EXTRA_TEXT)
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
    val text = pending
    pending = null
    // The same shape the iOS side returns, so Dart has one parser rather than
    // one per platform. Images stay empty here: this channel claims no image
    // types, and an empty list is the honest answer rather than an omission.
    result.success(if (text == null) null else mapOf("link" to text))
  }
}
