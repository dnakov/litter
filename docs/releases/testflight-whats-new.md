Summary

- Fixed image input: pasting and attaching images in conversations works correctly again.
- Fixed local OAuth login: ChatGPT sign-in now opens from a single stable presenter instead of flashing closed.
- Improved Live Activity UI: the lock screen card and Dynamic Island use a tighter, cleaner layout.
- Better new-session recents: recent directories are deduplicated and promoted more consistently when starting sessions.

What to test

- In a conversation, paste an image and use image input normally. Confirm the attachment appears and sends correctly.
- Trigger local ChatGPT login on the device and confirm the OAuth sheet stays open until you finish or cancel it.
- Start a turn that creates a Live Activity and check the lock screen card plus Dynamic Island layout for sizing and readability.
- Start a new session from a few different directories and confirm the recent-directory picker shows deduplicated entries in the expected order.
