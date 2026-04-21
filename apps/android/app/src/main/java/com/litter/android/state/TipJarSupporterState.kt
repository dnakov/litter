package com.litter.android.state

import android.content.Context
import android.util.Log
import androidx.compose.runtime.mutableStateOf
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryPurchasesParams

/**
 * Shared, lightweight view of the user's tip-jar purchases so surfaces like
 * the home screen can show the purchased kitty without embedding BillingClient
 * plumbing themselves.
 *
 * The full purchase / list flow still lives in `TipJarScreen`.
 */
object TipJarSupporterState {
    private const val TAG = "TipJarSupporter"

    /**
     * Ordered by tier (smallest → largest) so we pick the highest purchased.
     * The product id list stays in sync with `TipJarScreen.TIP_PRODUCTS`.
     */
    private val tiers: List<Tier> = listOf(
        Tier(
            iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_10,
            productIds = listOf("tip_10", "com.sigkitten.litter.tip.10", "com.sigkitten.litter.android.tip.10"),
        ),
        Tier(
            iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_25,
            productIds = listOf("tip_25", "com.sigkitten.litter.tip.25", "com.sigkitten.litter.android.tip.25"),
        ),
        Tier(
            iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_50,
            productIds = listOf("tip_50", "com.sigkitten.litter.tip.50", "com.sigkitten.litter.android.tip.50"),
        ),
        Tier(
            iconRes = com.sigkitten.litter.android.R.drawable.tip_cat_100,
            productIds = listOf("tip_100", "com.sigkitten.litter.tip.100", "com.sigkitten.litter.android.tip.100"),
        ),
    )

    /** Highest purchased tier's icon drawable, or null if the user isn't a supporter yet. */
    val supporterIconRes = mutableStateOf<Int?>(null)

    /**
     * Positional tier-ordered list of 4 slots (smallest → largest). Each slot
     * is the icon drawable if purchased, or null otherwise. Hosts slice this
     * to show e.g. left (tiers 0..1) and right (tiers 2..3) of the logo.
     */
    val tierIcons = mutableStateOf<List<Int?>>(List(4) { null })

    fun refresh(context: Context) {
        val app = context.applicationContext
        val client = BillingClient.newBuilder(app)
            .setListener(PurchasesUpdatedListener { _, _ -> })
            .enablePendingPurchases()
            .build()
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                    Log.w(TAG, "billing setup failed: ${result.debugMessage}")
                    client.endConnection()
                    return
                }
                client.queryPurchasesAsync(
                    QueryPurchasesParams.newBuilder()
                        .setProductType(BillingClient.ProductType.INAPP)
                        .build(),
                ) { _, purchases ->
                    val owned = purchases
                        .filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
                        .flatMap { it.products }
                        .toSet()
                    val highest = tiers.lastOrNull { tier ->
                        tier.productIds.any(owned::contains)
                    }
                    supporterIconRes.value = highest?.iconRes
                    tierIcons.value = tiers.map { tier ->
                        if (tier.productIds.any(owned::contains)) tier.iconRes else null
                    }
                    client.endConnection()
                }
            }

            override fun onBillingServiceDisconnected() {
                client.endConnection()
            }
        })
    }

    private data class Tier(val iconRes: Int, val productIds: List<String>)
}
