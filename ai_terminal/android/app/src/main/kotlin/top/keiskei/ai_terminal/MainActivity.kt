package top.keiskei.ai_terminal

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.StatFs
import android.os.SystemClock
import android.net.TrafficStats
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.View
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "com.keiskei.aiterminal/security"
        const val PATHS_CHANNEL = "com.keiskei.aiterminal/paths"
        const val STATS_CHANNEL = "com.keiskei.aiterminal/stats"
        const val PREFS = "ai_terminal_security"
        const val WRAP_KEY_ALIAS = "ai_terminal.db_wrap.v1"
        const val GCM_TAG_BITS = 128
        const val DB_KEY_BYTES = 32
        val SLOTS = setOf("active", "pending")
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // targetSdk 34 下 Flutter 不会自动开 edge-to-edge，窗口只把导航栏 inset
        // 让给内容、状态栏 inset 却没让：surface 比 Flutter 的视口矮整整一个状态栏，
        // 底部 90px 画到屏幕外（真机实测视口 2296px / surface 2206px）。
        // 显式接管系统栏，让 surface、视口、inset 三者一致，inset 由 Dart 侧消费。
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 终端的 busybox/bash 随 jniLibs 打进 APK，只有 nativeLibraryDir 里的
        // 文件带 apk_data_file 标签、能被 execve；Dart 侧拿不到这个路径。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PATHS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    else -> result.notImplemented()
                }
            }
        // 监控面板的 Android 数据源。/proc/stat 与 /proc/net/dev 对应用进程是
        // SELinux 拒绝的（真机 EACCES），top/free/vmstat 都要读 /proc/stat，
        // dumpsys 又需要只有 shell uid 才有的 DUMP 权限 —— 所以本机的 CPU/负载
        // 在这台设备上根本读不到，只能取公开 SDK 能给的这几项。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STATS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "collectStats" -> result.success(collectStats())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        // 凭据存储仍走原有降级策略；数据库密钥不共用该通道返回值。
                        "getMasterKey" -> result.success(null)
                        "readDatabaseKey" -> {
                            val slot = requireSlot(call.argument<String>("slot"))
                            result.success(readKey(slot))
                        }
                        "createDatabaseKey" -> {
                            val slot = requireSlot(call.argument<String>("slot"))
                            result.success(createKey(slot))
                        }
                        "promotePendingDatabaseKey" -> {
                            promotePending()
                            result.success(null)
                        }
                        "discardPendingDatabaseKey" -> {
                            discardPending()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: KeyUnavailableException) {
                    result.error("KEY_UNAVAILABLE", e.message, null)
                } catch (e: Exception) {
                    result.error("KEY_ERROR", e.message ?: e.javaClass.simpleName, null)
                }
            }
    }

    private fun requireSlot(slot: String?): String {
        val value = slot ?: "active"
        if (value !in SLOTS) {
            throw KeyUnavailableException("未知密钥槽: $value")
        }
        return value
    }

    /// 监控面板要的几个指标，全部走公开 SDK：拿不到的一律不放键，
    /// Dart 侧按「未知」渲染成 -，不拿 0 冒充测量结果。
    private fun collectStats(): Map<String, Any> {
        val out = mutableMapOf<String, Any>()
        runCatching {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
            out["memTotalBytes"] = mi.totalMem
            out["memAvailBytes"] = mi.availMem
        }
        runCatching { out["uptimeMs"] = SystemClock.elapsedRealtime() }
        runCatching {
            val stat = StatFs(dataDir.path)
            val total = stat.blockCountLong * stat.blockSizeLong
            val free = stat.availableBlocksLong * stat.blockSizeLong
            out["diskTotalBytes"] = total
            // 应用可见的可用空间：DataKeeper 预留的量普通进程用不了，
            // 用 free 而不是 availableBytesOfData 更接近用户点的「还剩多少」。
            out["diskFreeBytes"] = free
        }
        // TrafficStats 在 Android 10+ 对非系统应用可能返回 -1（不支持），
        // 原样透传，由 Dart 侧当作未知处理。
        runCatching {
            val uid = android.os.Process.myUid()
            out["rxBytes"] = TrafficStats.getUidRxBytes(uid)
            out["txBytes"] = TrafficStats.getUidTxBytes(uid)
        }
        runCatching { out["model"] = Build.MODEL }
        runCatching {
            out["kernel"] = System.getProperty("os.version") ?: ""
        }
        return out
    }

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun readKey(slot: String): Map<String, String>? {
        val prefs = prefs()
        val wrapped = prefs.getString("wrapped_$slot", null) ?: return null
        val iv = prefs.getString("iv_$slot", null)
            ?: throw KeyUnavailableException("$slot 密钥 IV 缺失")
        val keyId = prefs.getString("kid_$slot", null)
            ?: throw KeyUnavailableException("$slot 密钥 id 缺失")
        val wrapKey = loadWrappingKey()
            ?: throw KeyUnavailableException("Keystore 包装密钥丢失，拒绝重新生成")
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                wrapKey,
                GCMParameterSpec(GCM_TAG_BITS, Base64.decode(iv, Base64.NO_WRAP))
            )
            val plain = cipher.doFinal(Base64.decode(wrapped, Base64.NO_WRAP))
            if (plain.size != DB_KEY_BYTES) {
                throw KeyUnavailableException("数据库密钥长度异常")
            }
            val secret = Base64.encodeToString(plain, Base64.NO_WRAP)
            return mapOf("id" to keyId, "secret" to secret)
        } catch (e: KeyPermanentlyInvalidatedException) {
            throw KeyUnavailableException("Keystore 包装密钥已失效", e)
        } catch (e: AEADBadTagException) {
            throw KeyUnavailableException("数据库密钥认证失败", e)
        }
    }

    private fun createKey(slot: String): Map<String, String> {
        val prefs = prefs()
        if (prefs.contains("wrapped_$slot")) {
            throw KeyUnavailableException("$slot 密钥槽已存在，拒绝覆盖")
        }
        val wrapKey = getOrCreateWrappingKey()
        val random = SecureRandom()
        val plain = ByteArray(DB_KEY_BYTES)
        random.nextBytes(plain)
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, wrapKey)
            val ciphertext = cipher.doFinal(plain)
            val iv = cipher.iv
            val keyId = ByteArray(8).also(random::nextBytes).joinToString("") {
                "%02x".format(it.toInt() and 0xff)
            }
            val committed = prefs.edit()
                .putString("wrapped_$slot", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                .putString("iv_$slot", Base64.encodeToString(iv, Base64.NO_WRAP))
                .putString("kid_$slot", keyId)
                .commit()
            if (!committed) {
                throw KeyUnavailableException("写入密钥元数据失败")
            }
            return mapOf(
                "id" to keyId,
                "secret" to Base64.encodeToString(plain, Base64.NO_WRAP)
            )
        } finally {
            plain.fill(0)
        }
    }

    private fun promotePending() {
        val prefs = prefs()
        val wrapped = prefs.getString("wrapped_pending", null)
            ?: throw KeyUnavailableException("pending 密钥不存在")
        val iv = prefs.getString("iv_pending", null)
            ?: throw KeyUnavailableException("pending 密钥 IV 缺失")
        val keyId = prefs.getString("kid_pending", null)
            ?: throw KeyUnavailableException("pending 密钥 id 缺失")
        val committed = prefs.edit()
            .putString("wrapped_active", wrapped)
            .putString("iv_active", iv)
            .putString("kid_active", keyId)
            .remove("wrapped_pending")
            .remove("iv_pending")
            .remove("kid_pending")
            .commit()
        if (!committed) {
            throw KeyUnavailableException("提升 pending 密钥失败")
        }
    }

    private fun discardPending() {
        val committed = prefs().edit()
            .remove("wrapped_pending")
            .remove("iv_pending")
            .remove("kid_pending")
            .commit()
        if (!committed) {
            throw KeyUnavailableException("删除 pending 密钥失败")
        }
    }

    private fun loadWrappingKey(): SecretKey? {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return keyStore.getKey(WRAP_KEY_ALIAS, null) as? SecretKey
    }

    private fun getOrCreateWrappingKey(): SecretKey {
        loadWrappingKey()?.let { return it }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        )
        val spec = KeyGenParameterSpec.Builder(
            WRAP_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private class KeyUnavailableException(message: String, cause: Throwable? = null) :
        Exception(message, cause)
}