# Android Play Internal Checklist

## One-time Setup
1. In Play Console, create app `com.sigkitten.litter.android`.
2. Create a Service Account in Google Cloud and grant it Play Console access to the app.
3. Download the service-account JSON key.
4. Create an upload keystore (or use your existing Play upload key).

## Required Environment Variables
- `LITTER_PLAY_SERVICE_ACCOUNT_JSON` = path to service-account JSON
- `LITTER_UPLOAD_STORE_FILE` = path to upload keystore (`.jks`)
- `LITTER_UPLOAD_STORE_PASSWORD` = keystore password
- `LITTER_UPLOAD_KEY_ALIAS` = key alias
- `LITTER_UPLOAD_KEY_PASSWORD` = key password
- Optional: `LITTER_PLAY_TRACK` (default: `internal`)

## Upload Command
```bash
./apps/android/scripts/play-upload.sh
```

## Variant Selection
- Default variant: `OnDeviceRelease`
- To upload remote-only:
```bash
VARIANT=RemoteOnlyRelease ./apps/android/scripts/play-upload.sh
```

## Build Only (No Upload)
```bash
UPLOAD=0 ./apps/android/scripts/play-upload.sh
```
