package cc.tic.einz

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val STORE_CHANNEL = "einz/store"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // MethodChannel：Dart 侧取「附件明文长期存放目录」（stored 模式）。
        // 用 noBackupFilesDir —— 这里的明文不进 Auto Backup、也不随换机传输
        // （否则 Google 备份/换机还原就能读到旧附件）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getStoredDir") {
                    val dir = java.io.File(noBackupFilesDir, "einz_media")
                    if (!dir.exists()) dir.mkdirs()
                    result.success(dir.absolutePath)
                } else {
                    result.notImplemented()
                }
            }
    }
}
