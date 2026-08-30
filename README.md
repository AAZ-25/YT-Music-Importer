# YT Music Importer

Import a video's audio into the Music app from inside YouTube on jailbroken iOS.

## Requirements

- Jailbroken iOS 15 or later
- YouTube
- Sileo, Zebra, or another compatible package manager
- `YTVideoOverlay` (installed as a package dependency)

## Installation and use

1. Download the rootless DEB from the latest prerelease.
2. Open it with Sileo or Zebra and install it normally.
3. Respring if requested, then open YouTube.
4. Play a video and tap the music import button.
5. Review the title, artist, and optional album, then tap **Import**.
6. Keep YouTube open while the audio is prepared and imported.

The importer first uses a normal direct audio stream when YouTube exposes one. When YouTube uses segmented playback instead, the importer can use the current YouTube playback session to retrieve the selected audio without changing global playback settings.

## Privacy and diagnostics

Processing happens locally. The tweak does not operate a separate server and does not upload your Music library or account information.

Optional debug logging records only general processing stages. It does not record video URLs, video identifiers, titles, artist or album metadata, account data, tokens, cookies, request bodies, or other authentication material.

If an import fails, enable **Debug Logging** in the import form, repeat the attempt once, then use **Share Debug Log**.

## Notes

- Confirm normal YouTube playback before testing an import.
- Availability can depend on the selected video, network conditions, and YouTube changes.
- Use the tool only for content you are permitted to download and in accordance with applicable terms and law.
- Third-party components and pinned versions are documented in [THIRD_PARTY.md](THIRD_PARTY.md).
