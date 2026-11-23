package com.dpsk.harness

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import com.dpsk.harness.files.FilesPlugin
import com.dpsk.harness.links.LinksPlugin
import com.dpsk.harness.notify.NotifyPlugin
import com.dpsk.harness.phone.PhonePlugin
import com.dpsk.harness.runtime.RuntimePlugin
import com.dpsk.harness.share.SharePlugin
import com.dpsk.harness.shortcuts.ShortcutsPlugin
import com.dpsk.harness.update.UpdatePlugin
import com.dpsk.harness.voice.VoicePlugin

/** Activity and the companion service own leases on this same process engine. */
object DshFlutterEngine {
    const val ENGINE_ID = "dsh-main"

    @Synchronized
    fun getOrCreate(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        return FlutterEngine(context.applicationContext).also { engine ->
            engine.plugins.add(RuntimePlugin())
            engine.plugins.add(PhonePlugin())
            engine.plugins.add(NotifyPlugin())
            engine.plugins.add(FilesPlugin())
            engine.plugins.add(LinksPlugin())
            engine.plugins.add(UpdatePlugin())
            engine.plugins.add(VoicePlugin())
            engine.plugins.add(SharePlugin())
            engine.plugins.add(ShortcutsPlugin())
            engine.plugins.add(com.dpsk.harness.diagnostics.DiagnosticsPlugin())
            engine.plugins.add(com.dpsk.harness.media.MediaPlugin())
            engine.plugins.add(com.dpsk.harness.media.MediaVideoPlugin())
            engine.plugins.add(com.dpsk.harness.icons.LauncherIconPlugin())
            engine.plugins.add(com.dpsk.harness.theme.DynamicColorPlugin())
            engine.plugins.add(com.dpsk.harness.performance.PerformancePlugin())
            engine.plugins.add(com.dpsk.harness.pet.PetOverlayPlugin())
            engine.plugins.add(com.dpsk.harness.islands.IslandsPlugin())
            engine.plugins.add(com.dpsk.harness.nativemedia.NativeMediaPlugin())
            engine.plugins.add(com.dpsk.harness.nativefiles.NativeFilesPlugin())
            engine.plugins.add(com.dpsk.harness.web.WebFilesPlugin())
            engine.plugins.add(com.dpsk.harness.launch.LaunchPlugin())
            engine.plugins.add(com.dpsk.harness.launch.LaunchClipPlugin())
            engine.plugins.add(com.dpsk.harness.icons.PictureShortcutPlugin())
            engine.plugins.add(com.dpsk.harness.usage.UsagePlugin())
            engine.plugins.add(com.dpsk.harness.companion.CompanionVoicePlugin())
            engine.plugins.add(com.dpsk.harness.speech.SpeechPlugin())
            engine.plugins.add(com.dpsk.harness.companion.CompanionWidgetPlugin())
            engine.plugins.add(com.dpsk.harness.companion.CompanionReminderPlugin())
            engine.plugins.add(com.dpsk.harness.companion.CompanionMapPlugin())
            engine.plugins.add(com.dpsk.harness.companion.CompanionEmbeddingPlugin())
            engine.plugins.add(com.dpsk.harness.companion.CompanionAlwaysOnPlugin())
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            cache.put(ENGINE_ID, engine)
        }
    }

}
