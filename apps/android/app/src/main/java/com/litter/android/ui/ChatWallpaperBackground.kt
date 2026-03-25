package com.litter.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale

@Composable
fun ChatWallpaperBackground(modifier: Modifier = Modifier) {
    WallpaperBackdrop(modifier = modifier.fillMaxSize())
}

@Composable
fun WallpaperBackdrop(modifier: Modifier = Modifier) {
    val wallpaperBitmap = WallpaperManager.wallpaperBitmap
    if (wallpaperBitmap != null) {
        Image(
            bitmap = wallpaperBitmap.asImageBitmap(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = modifier,
        )
    } else {
        Box(
            modifier = modifier.background(LitterTheme.backgroundBrush),
        )
    }
}
