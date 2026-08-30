# Third-party components

YT Music Importer uses the following open-source components during build or runtime integration:

- `YTVideoOverlay` commit `0f7dbc4387a0e38aad3180744e484fef6cbb9094` — MIT License.
- `YouTubeHeader` commit `1b50d755dab2c79b8f5af45fc89719c812571ae0` — MIT License.
- `YTKACE` commit `7e562661a68116949ee5f12addc412d074b859ef` — MIT License. The stream resolver and segmented-download implementation are used with local modifications.

Applicable license notices are preserved with the project and package.

## Research references

### MImport
- Source: https://github.com/julioverne/MImport
- Use: reference for the supported Music-process injection target and observable import architecture.
- No source code copied into this project.

### ByeTunes
- Source: https://github.com/EduAlexxis/ByeTunes
- License: MIT
- Use: reference for local Music-library storage, SQLite/WAL safety, backup, atomic replacement, and post-sync verification patterns.
- Any code incorporated from this project must retain the applicable MIT notice and be independently reviewed for compatibility with this project's target environment.
