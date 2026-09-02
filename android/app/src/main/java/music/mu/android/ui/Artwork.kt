package music.mu.android.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * 專輯封面（≈ Apple 的 ArtworkLoader/ArtworkImage）：
 * 1. 音軌內嵌圖（MediaMetadataRetriever）
 * 2. 同資料夾封面檔（cover/folder/front/album.{jpg,jpeg,png}）
 * 都沒有 → 由 albumId 穩定雜湊出的雙色漸層（與 Apple 端同一個 djb2，兩平台同專輯同色）。
 */
object Artwork {

    private const val MAX_PIXEL = 640
    private val preferredNames = listOf("cover", "folder", "front", "album", "albumart")
    private val extensions = setOf("jpg", "jpeg", "png", "webp")

    /** 快取一則結果；bitmap 為 null 代表「查過了，沒有封面」（LruCache 本身不接受 null 值）。 */
    private class Entry(val bitmap: Bitmap?)

    /**
     * 依可用記憶體的 1/8 設定位元組上限（而非固定筆數）：640px 解碼後單張約 1.6MB，
     * 固定 96 筆在大庫捲動時很快就把畫面外的封面清光、逼著重新解碼；按位元組計算才跟裝置成比例。
     * `android.util.LruCache` 內部已用 `synchronized`，呼叫端不必再自己上鎖。
     */
    private val cache = object : LruCache<String, Entry>(
        (Runtime.getRuntime().maxMemory() / 8).toInt().coerceAtMost(64 * 1024 * 1024),
    ) {
        override fun sizeOf(key: String, value: Entry): Int = value.bitmap?.byteCount ?: 1
    }

    /** 已快取結果（同步；未載入回 null——與「查過但沒封面」無法區分，僅供畫面先顯示已知結果用）。 */
    fun cached(key: String): Bitmap? = cache.get(key)?.bitmap

    /** 快取命中就同步回傳，不必為此跳一次 IO 分派；沒命中才做真正的檔案 I/O 與解碼。 */
    suspend fun load(key: String, file: File?): Bitmap? {
        cache.get(key)?.let { return it.bitmap }
        return withContext(Dispatchers.IO) {
            val bytes = file?.let { embedded(it) ?: folderCover(it) }
            val bitmap = bytes?.let(::decode)
            cache.put(key, Entry(bitmap))
            bitmap
        }
    }

    private fun embedded(file: File): ByteArray? = try {
        MediaMetadataRetriever().use { r ->
            r.setDataSource(file.absolutePath)
            r.embeddedPicture
        }
    } catch (e: Exception) {
        null
    }

    // MediaMetadataRetriever 只在 API 29+ 才是 AutoCloseable（minSdk 26），不能用 kotlin.io.use。
    private inline fun <T> MediaMetadataRetriever.use(block: (MediaMetadataRetriever) -> T): T =
        try {
            block(this)
        } finally {
            try { release() } catch (e: Exception) { }
        }

    private fun folderCover(track: File): ByteArray? {
        val dir = track.parentFile ?: return null
        val images = dir.listFiles { f: File ->
            f.isFile && f.extension.lowercase() in extensions
        }.orEmpty()
        if (images.isEmpty()) return null
        val pick = preferredNames.firstNotNullOfOrNull { name ->
            images.firstOrNull { it.nameWithoutExtension.lowercase() == name }
        } ?: images.minByOrNull { it.name }
        return try {
            pick?.readBytes()
        } catch (e: Exception) {
            null
        }
    }

    /** 降取樣到 MAX_PIXEL 以內，避免整格網格吃滿記憶體。 */
    private fun decode(bytes: ByteArray): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_PIXEL) sample *= 2
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample })
    } catch (e: Exception) {
        null
    }

    /** djb2（與 Apple 端 PlaceholderArt.hue 同式）→ 每張專輯固定色相。 */
    fun hue(key: String): Float {
        var h = 5381u
        for (b in key.toByteArray()) h = h * 33u + (b.toInt() and 0xFF).toUInt()
        h = h xor (h shr 16)
        h *= 0x45d9f3bu
        h = h xor (h shr 16)
        return (h % 360u).toFloat() / 360f
    }

    fun placeholderBrush(key: String): Brush {
        val h = hue(key)
        return Brush.linearGradient(
            listOf(
                Color.hsv(h * 360f, 0.42f, 0.62f),
                Color.hsv(((h + 0.09f) % 1f) * 360f, 0.55f, 0.34f),
            ),
            start = Offset.Zero,
            end = Offset.Infinite,
        )
    }
}

/**
 * 正方形封面。`file` 為該專輯任一音軌（用來找內嵌圖／同資料夾封面）；
 * 沒有封面時畫穩定漸層 + 音符，載入是非同步的，捲動時不會卡住清單。
 */
@Composable
fun AlbumArt(
    key: String,
    file: File?,
    modifier: Modifier = Modifier,
    corner: Dp = MuDimens.artCorner,
    playlist: Boolean = false,
) {
    val bitmap by produceState<Bitmap?>(initialValue = Artwork.cached(key), key, file?.path) {
        value = Artwork.load(key, file)
    }
    // key 不變就不必重算漸層 Brush、也不必每次重組都重包一次 ImageBitmap。
    val brush = remember(key) { Artwork.placeholderBrush(key) }
    val imageBitmap = remember(bitmap) { bitmap?.asImageBitmap() }
    Box(
        modifier
            .clip(RoundedCornerShape(corner))
            .background(brush),
        contentAlignment = Alignment.Center,
    ) {
        if (imageBitmap != null) {
            Image(
                imageBitmap,
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        } else {
            Icon(
                if (playlist) Icons.AutoMirrored.Filled.QueueMusic else Icons.Default.MusicNote,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.82f),
                modifier = Modifier.fillMaxSize(0.34f),
            )
        }
    }
}
