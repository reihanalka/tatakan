# Security

Tatakan runs locally and has no network features. It reads files you drop on the shelf, and it can read your calendar, use the camera (Mirror) and see Bluetooth connections only after you allow those in macOS.

The Now Playing feature runs `/usr/bin/perl` with a bundled dylib to read Apple's private MediaRemote framework.

If you find something that could harm users, please **don't open a public issue**. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repo.

Supported version: the latest release only.
