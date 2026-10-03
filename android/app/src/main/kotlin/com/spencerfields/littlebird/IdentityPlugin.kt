package com.spencerfields.littlebird

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * A stable, meaningless identifier for this installation.
 *
 * The Android half of `littlebird/identity`. It exists so a complimentary code
 * can be issued against a device: the server records the pair, which is how a
 * code can be used once and not again, and how a code that also grants
 * administrative access can later be withdrawn.
 *
 * **Random, and derived from nothing.** Not `ANDROID_ID`, not the advertising
 * id, not anything about the hardware or the account. Two installations on the
 * same phone are two different identifiers, and the value says nothing about
 * the person, which is what lets the privacy page call it what it is.
 *
 * **Weaker than the iPhone version, and the difference matters.** On iOS this
 * lives in the Keychain, which survives deleting the app, so a friend who
 * reinstalls re-enters their code and is recognised as their own earlier
 * redemption rather than refused by it. Android has no equivalent store:
 * Keystore entries, `EncryptedSharedPreferences` and ordinary preferences are
 * all removed with the app. Auto Backup may restore this file on a reinstall,
 * and often does, but it is a best effort and not a guarantee.
 *
 * The consequence is worth stating rather than discovering: reinstalling on
 * Android can produce a new identifier, and a single-use code already spent
 * against the old one will then be refused. Issue Android codes with a
 * `maxUses` above one, or expect to reissue.
 */
class IdentityPlugin(private val context: Context) :
  FlutterPlugin, MethodChannel.MethodCallHandler {

  private lateinit var channel: MethodChannel

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "littlebird/identity")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method == "integrityToken") {
      integrityToken(call.argument<String>("nonce"), result)
      return
    }
    if (call.method != "deviceId") {
      result.notImplemented()
      return
    }
    try {
      result.success(deviceId())
    } catch (e: Exception) {
      // Deliberately an error rather than a fresh id each time. A caller that
      // received a different identifier on every launch would burn a use of a
      // code per launch, and the failure would look like a bad code.
      Log.w(TAG, "could not read or write the device identifier", e)
      result.error("identity", "could not store a device identifier", null)
    }
  }

  /**
   * Reads the identifier, minting one the first time.
   *
   * Synchronised because two isolates asking at once on a first run would
   * otherwise each mint and each commit, and the second would overwrite an
   * identifier the first had already handed to the server.
   */
  private fun deviceId(): String = synchronized(lock) {
    val prefs = prefs()
    prefs.getString(KEY, null)?.let { return it }
    val fresh = UUID.randomUUID().toString()
    // commit, not apply: the value has to be on disk before it is handed out,
    // or a crash between minting and redeeming spends a code against an
    // identifier this device will never present again.
    prefs.edit().putString(KEY, fresh).commit()
    return fresh
  }

  /**
   * A classic Play Integrity token for the given nonce, or null.
   *
   * The free sample on Android. The token means nothing to this app: it is
   * encrypted to Google, and the Worker has Google decode it and read device
   * recall -- whether this phone has already had its free read.
   *
   * Every failure answers null rather than an error. No Play Store, no
   * network, an emulator, an app not installed from Play: each simply means
   * no free read, and the caller opens the paywall it always did. No Cloud
   * project number is set, because an app distributed through Play is linked
   * to its project in Play Console.
   */
  private fun integrityToken(nonce: String?, result: MethodChannel.Result) {
    if (nonce.isNullOrEmpty()) {
      result.success(null)
      return
    }
    try {
      IntegrityManagerFactory.create(context.applicationContext)
        .requestIntegrityToken(
          IntegrityTokenRequest.builder().setNonce(nonce).build())
        .addOnSuccessListener { result.success(it.token()) }
        .addOnFailureListener { e ->
          Log.i(TAG, "no integrity token: ${e.message}")
          result.success(null)
        }
    } catch (e: Exception) {
      Log.i(TAG, "integrity request failed", e)
      result.success(null)
    }
  }

  private fun prefs(): SharedPreferences =
    context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

  private companion object {
    const val TAG = "IdentityPlugin"

    /** Its own file, so clearing anything else cannot take it with it. */
    const val FILE = "littlebird_identity"
    const val KEY = "device_id"
    val lock = Any()
  }
}
