# Third-party components

YT Music Importer uses or adapts the following open-source components:

- `YTVideoOverlay` commit `0f7dbc4387a0e38aad3180744e484fef6cbb9094` — MIT License. Provides the YouTube overlay integration.
- `YouTubeHeader` commit `1b50d755dab2c79b8f5af45fc89719c812571ae0` — MIT License. Provides public YouTube interface declarations used at build time.
- `YTKACE` commit `7e562661a68116949ee5f12addc412d074b859ef` — MIT License. Its stream-resolution and segmented-download implementation is used with local privacy modifications.
- `YTKACE` commit `98307a7a805969c5153b5143db5bb7680354e661` — MIT License. Its pivot-renderer integration pattern was adapted for the Downloads tab.
- `ByeTunes` commit `54491b21c9949fd0410f760cfca9e8cf11f06f1d` — MIT License. Its local MediaLibrary record and staged-database transaction patterns were adapted for the Music bridge.
- `TubePod` commit `7df3de91366fc47c1322d88103900b3e916607a3` — GPL-3.0. Used as an architectural reference for Music-owned import and playable-audio validation; no TubePod source is linked into the tweak.

Required license notices are included in the source tree and installed package.

## Platform interface research

Public iOS SDK headers, public runtime headers, and publicly available reverse-engineered interface descriptions were used to understand compatible MusicLibrary, MediaPlayer, and StoreServices contracts across iOS versions. The importer dynamically checks the interfaces available on the device and implements its own local-file import and verification flow. No Apple implementation source is redistributed.

The project is independent and is not affiliated with or endorsed by YouTube, Apple, or the projects listed above.
