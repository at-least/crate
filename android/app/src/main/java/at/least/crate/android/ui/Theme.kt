package at.least.crate.android.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/**
 * Material 3 佈景：Android 12+ 用系統動態色（跟著使用者桌布），舊版退回內建色票。
 * 顏色一律取自 `MaterialTheme.colorScheme`，畫面裡不寫死色碼；深淺兩套一起定義。
 */
@Composable
fun CrateTheme(
    dark: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

/** 版面節奏：4/8dp 級距的單一來源。 */
object MuDimens {
    val pageInset = 16.dp
    val gridSpacing = 12.dp
    val artCornerSmall = 8.dp
    val artCorner = 12.dp
    val artCornerLarge = 16.dp
    /** Material 最小可點區。 */
    val hitTarget = 48.dp
}
