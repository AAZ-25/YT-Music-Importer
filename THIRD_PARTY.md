# Third-party components

YT Music Importer uses the following open-source components during build or runtime integration:

- `YTVideoOverlay` commit `0f7dbc4387a0e38aad3180744e484fef6cbb9094` — MIT License.
- `YouTubeHeader` commit `1b50d755dab2c79b8f5af45fc89719c812571ae0` — MIT License.
- `YTKACE` commit `7e562661a68116949ee5f12addc412d074b859ef` — MIT License. The stream resolver and segmented-download implementation are used with local modifications.
- `ByeTunes` commit `54491b21c9949fd0410f760cfca9e8cf11f06f1d` — MIT License. The complete local MediaLibrary relational-record layout and staged SQLite backup/checkpoint/replacement pattern were adapted for the rootless SpringBoard bridge. Its license notice is included in the package.

Applicable license notices are preserved with the project and package.

## Research references

### MImport
- Source: https://github.com/julioverne/MImport
- Use: architectural research reference for Music import behavior.
- No source code copied into this project.

### idevice
- Source: https://github.com/jkcoxson/idevice
- License: MIT
- Use: build-feasibility research for a device-sync transport boundary. It is not shipped in Beta 40.

### TubePod
- Source: https://github.com/pruefsumme/TubePod
- Pinned commit: `7df3de91366fc47c1322d88103900b3e916607a3`
- License: GPL-3.0
- Use: architectural research reference for a Music-owned StoreServices import queue and post-import playable-audio validation. The project implements its runtime-checked importer independently; no TubePod source code is copied or linked.


### Apple StoreServices runtime interfaces
- Sources: public iOS 10, iOS 14, iOS 15.5, and iOS 17 runtime headers, plus public iOS 17.6 reverse-engineered interface output.
- Use: verify the cross-version selector and callback contract of `SSImportDownloadToIPodLibraryRequest`.
- No Apple implementation source is copied; the project invokes the runtime interface independently.


## MusicLibrary runtime interface research

- Public `ML3MusicLibrary` and `ML3Track` runtime headers, plus public reverse-engineered interface output, were used to identify the library-owned record/location transaction contract used by Beta 48.
- No Apple implementation source is redistributed. The importer is an independent implementation that resolves available runtime selectors dynamically and verifies the resulting local file-backed record.
