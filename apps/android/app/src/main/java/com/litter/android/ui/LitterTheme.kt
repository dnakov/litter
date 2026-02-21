package com.litter.android.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

object LitterTheme {
    val accent = Color(0xFF00FF9C)
    val textPrimary = Color.White
    val textSecondary = Color(0xFF888888)
    val textMuted = Color(0xFF555555)
    val border = Color(0xFF333333)

    val backgroundBrush: Brush =
        Brush.linearGradient(
            colors =
                listOf(
                    Color(0xFF0A0A0A),
                    Color(0xFF0F0F0F),
                    Color(0xFF080808),
                ),
        )
}

private val LitterColorScheme =
    darkColorScheme(
        primary = LitterTheme.accent,
        onPrimary = Color.Black,
        secondary = Color(0xFF8A8A8A),
        onSecondary = Color.Black,
        background = Color.Black,
        onBackground = Color(0xFFE0E0E0),
        surface = Color(0xFF111111),
        onSurface = Color(0xFFE0E0E0),
        error = Color(0xFFFF5B5B),
        onError = Color.Black,
        outline = LitterTheme.border,
    )

private val LitterTypography =
    Typography(
        headlineSmall =
            TextStyle(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                fontSize = 20.sp,
            ),
        titleMedium =
            TextStyle(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Medium,
                fontSize = 16.sp,
            ),
        bodyMedium =
            TextStyle(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Normal,
                fontSize = 14.sp,
            ),
        labelLarge =
            TextStyle(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Medium,
                fontSize = 12.sp,
            ),
    )

@Composable
fun LitterAppTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = LitterColorScheme,
        typography = LitterTypography,
        content = content,
    )
}
