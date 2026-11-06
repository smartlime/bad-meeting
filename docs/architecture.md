# Architecture

The Swift package builds one native executable. Domain models, recording, local storage, settings, and provider implementations share the same target. No external Swift packages are required.

`Edition.swift` is the composition root. It supplies ordered speech providers, text providers, and calendar sources. Settings is rendered from those registrations. Adding a connection does not require adding hidden switches or provider names to the shared interface.

A separate edition can compose a target from an exact foundation checkout, replace only the composition root, and add provider source files and resources. The foundation remains independently buildable. Such an edition must keep its implementation, settings defaults, and transport details in its own repository. Its build must verify the exact foundation revision and matching `X.Y` before compilation.

Speech requests capture provider settings and credentials when processing starts. Text requests capture their selected connection separately. Providers never substitute each other after a failure. Calendar events carry their source identity, and system-calendar occurrences use stable identifiers with the occurrence timestamp.

Build scripts default to ad-hoc signing so a source checkout does not require a personal certificate. Distribution signing is supplied through the environment. Build products, credentials, machine-specific paths, and local diagnostics are excluded from version control.
