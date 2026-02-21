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
    val accent = Color(0xFFB0B0B0)
    val textPrimary = Color.White
    val textSecondary = Color(0xFF888888)
    val textMuted = Color(0xFF555555)
    val textBody = Color(0xFFE0E0E0)
    val textSystem = Color(0xFFC6D0CA)
    val surface = Color(0xFF1A1A1A)
    val surfaceLight = Color(0xFF2A2A2A)
    val border = Color(0xFF333333)
    val divider = Color(0xFF1E1E1E)
    val danger = Color(0xFFFF5555)

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
        onPrimary = Color(0xFF0D0D0D),
        secondary = LitterTheme.textSecondary,
        onSecondary = LitterTheme.textPrimary,
        background = Color.Black,
        onBackground = LitterTheme.textBody,
        surface = LitterTheme.surface,
        onSurface = LitterTheme.textBody,
        error = LitterTheme.danger,
        onError = Color(0xFF0D0D0D),
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
