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

- Public `ML3MusicLibrary` and `ML3Track` runtime headers, plus public reverse-engineered interface output, were used to identify the library-owned record/location transaction contract used by the local-library importer.
- No Apple implementation source is redistributed. The importer is an independent implementation that resolves available runtime selectors dynamically and verifies the resulting local file-backed record.

### MediaPlayer local-song contract research

- Sources: public iOS 18.1 MediaPlayer SDK headers and public reverse-engineered iOS 17.6.1 and iOS 18.2 MusicLibrary/MediaPlayer interfaces and implementations, including `MPMediaItem`, `MPMediaQuery`, `MPMediaPropertyPredicate`, `MPModelLibraryRequest`, `MPMediaLibrary`, `ML3ComparisonPredicate`, `ML3Collection`, `ML3Track`, `ML3Entity`, and `MPMediaLibraryDataProviderML3`.
- Cross-version interface source: public `nst/iOS-Runtime-Headers` MediaPlayer headers for `MPModelLibraryRequest`, `MPModelRequest`, `MPModelSong`, and `MPPropertySet`.
- Reference commits: `95df6b804bee0e01538eb2ddad0413609938d063` and `e26ed4563f78871c59d2d96856756a65d62517e5`.
- SDK reference commits: `1b92ff4a8928f582876e1d388d1381c6a0c59eb9` from `xybp888/iOS-SDKs` and `0222fd5413cf4b9af096f37b4621afa2688572f7` from `theos/sdks`.
- Use: verify the public-to-internal media-type conversion, MediaPlayer cache-reload contract, exact album membership, the Music-facing `MPModelLibraryRequest` acceptance boundary, and the older one-argument `setLegacyMediaQuery:` contract used before the newer optional transport-specific variant.
- No Apple implementation source is copied or redistributed; the importer independently invokes the available Objective-C predicate interfaces and does not directly resolve or copy the conversion function.

### MusicLibrary artist and album relationship research

- Source: public reverse-engineered iOS 18.2 `ML3Track`, `ML3Artist`, `ML3Album`, `ML3Collection`, and `ML3Entity` interfaces and implementations.
- Reference commit: `e26ed4563f78871c59d2d96856756a65d62517e5`.
- Use: verify that track artist and album names are joined collection values backed by `item_artist_pid` and `album_pid`, and that each collection's `updateTrackValues:` transaction normalizes the foreign keys and representative track.
- No Apple implementation source is copied or redistributed; The importer independently creates and verifies the required runtime relationships.


### Music library filter research

- Source: public reverse-engineered iOS 17.6.1 and iOS 18.2 `ML3Entity`, `ML3Track`, and `MPMediaLibraryDataProviderML3` implementations.
- Reference commits: `95df6b804bee0e01538eb2ddad0413609938d063` and `e26ed4563f78871c59d2d96856756a65d62517e5`.
- Use: distinguish the generic `visibleInLibrary:` query and its mutable system filters from the explicit MediaPlayer `songsQuery` acceptance boundary, and classify only fixed privacy-safe failure stages.
- No Apple implementation source is copied or redistributed.

### Music client-import transaction research

- Source: public reverse-engineered iOS 18.2 `ML3ClientImportSession`, `ML3ClientImportSessionConfiguration`, `ML3ClientImportItem`, `ML3ClientImportResult`, `MIPMediaItem`, `MIPSong`, `MIPArtist`, `MIPAlbum`, `MIPPlaybackInfo`, `MIPMultiverseIdentifier`, `IPodLibrary`, and `IPodLibraryML3TrackImporter` interfaces and implementations.
- Reference commit: `e26ed4563f78871c59d2d96856756a65d62517e5`.
- Use: distinguish daemon-only `IPodLibrary` helpers from the MusicLibrary client API that is callable from Music, then verify the supported XPC session lifecycle, MIP local-file payload, transaction-returned persistent-ID result, and exact final ownership states.
- No Apple implementation source is copied or redistributed. Beta 60 independently constructs a minimal MIP payload, submits it through the runtime-checked client-import session, verifies the returned Music record, and retains its exact local ownership ID for safe cleanup.
