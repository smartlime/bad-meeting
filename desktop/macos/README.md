# macOS application

See the [project README](../../README.md) for setup, provider configuration, build requirements, data storage, and signing.

The application uses SwiftUI and AppKit for the interface, Core Audio and AVFoundation for capture and audio assembly, Security for Keychain storage, URLSession for provider requests, and EventKit for system calendars.

Settings has four sections: recording and processing, calendars, reminders, and advanced settings. Numeric controls combine a digits-only field with a stepper. Settings for inactive providers are retained and hidden. Reminder presentation modes are independent for advance, start, and end reminders.

`scripts/test.sh` runs synthetic audio, calendar, credential, provider, recording lifecycle, and transcription tests. `scripts/preview.sh` renders native views with fixture data and credential resolution disabled. Live recognition quality, provider permissions, and real calendar-account synchronization require separate checks with configured accounts.
