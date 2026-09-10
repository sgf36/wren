package com.spencerfields.littlebird

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
  private val shareInbox = ShareInboxPlugin()

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    // Registered explicitly rather than through reflection, so a rename of the
    // plugin is a compile error instead of a channel that silently answers
    // MissingPluginException at runtime.
    flutterEngine.plugins.add(ShareFilePlugin())
    flutterEngine.plugins.add(PickFilePlugin())
    flutterEngine.plugins.add(OcrPlugin(applicationContext))
    flutterEngine.plugins.add(PlacesPlugin(applicationContext))
    flutterEngine.plugins.add(IdentityPlugin(applicationContext))
    flutterEngine.plugins.add(shareInbox)
  }

  // Both halves are needed and each looks sufficient on its own. A share that
  // starts Wren cold arrives here; a share that reaches an instance already in
  // the background arrives at onNewIntent, because launchMode is singleTop.
  // Handling only onCreate works until the app has been opened once.
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    shareInbox.handleIntent(this, intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    // Replaced, not merely handled: getIntent() keeps returning the launching
    // Intent otherwise, and anything reading it later would see the wrong one.
    setIntent(intent)
    shareInbox.handleIntent(this, intent)
  }
}
