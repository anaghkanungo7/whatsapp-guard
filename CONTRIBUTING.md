# Contributing

Build and test on macOS before submitting a pull request:

```sh
./scripts/build.sh
./scripts/test.sh
```

Describe the change and the behavior you tested. Window-handling changes need manual tests with native WhatsApp, including switching apps, reopening while locked, fullscreen, and multiple displays.

Do not attach chat screenshots, credentials, Keychain data, local activity records, or files with personal paths. Use generic examples in bug reports.

Keep the app local. Changes that introduce telemetry, networking, chat inspection, or additional system permissions need an explicit design discussion.
