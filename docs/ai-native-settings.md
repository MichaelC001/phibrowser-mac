# AI native settings

Extensions receive the JSON produced by `PhiPreferences.AISettings.buildConfig()`
through `getNativeSettings`. Changes made in AI settings are also sent through
`nativeSettingsChanged` using the same payload.

`enableEmailProtection` is a Boolean preference, enabled by default, for
AI-powered phishing and scam email detection. Its value persists across launches.
The Email Protection section in AI settings updates this preference.

Like the other AI feature preferences, this field retains the user's choice when
the AI master switch is off. Consumers must also respect `phiAIEnabled` and the
existing authentication requirements before running detection.
