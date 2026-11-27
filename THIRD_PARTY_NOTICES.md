# Third-Party Notices

> Trano is released under the MIT License (`LICENSE`, Copyright (c) 2026 Trano contributors). The MIT license applies to Trano's own source code and does not alter the licenses of third-party dependencies.

## Included and Resolved Dependencies

| Component | Version | License | Scope and Preservation |
| --- | --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm/tree/2f573f73af5e768d90847dce20c97fa9535d7164) | Upstream 1.99.1; locally modified | MIT (with xterm.js, SourceLair, Christopher Jeffrey notices) | Vendored in `vendor/SwiftTerm`; preserved notices in its `LICENSE` and `licenses/SwiftTerm.txt` |
| [Sparkle](https://github.com/sparkle-project/Sparkle/tree/2.10.1) | 2.10.1 | MIT (plus bundled BSD/zlib notices) | Linked in macOS app; full license in `licenses/Sparkle.txt` |
| [Go runtime](https://github.com/golang/go/blob/go1.24.10/LICENSE) | 1.24.10 | BSD-3-Clause | Runtime in built Linux helpers (not a vendored Go source tree); `licenses/Go.txt` |
| swift-argument-parser | 1.8.2 | Apache-2.0 with Swift Runtime Library Exception | Resolved tool/doc graph only; `licenses/swift-argument-parser.txt` |
| swift-docc-plugin | 1.5.0 | Apache-2.0 with Swift Runtime Library Exception | Resolved tool/doc graph only; `licenses/swift-docc-plugin.txt` |
| swift-docc-symbolkit | 1.0.0 | Apache-2.0 with Swift Runtime Library Exception | Resolved tool/doc graph only; `licenses/swift-docc-symbolkit.txt` |
| swift-png & h | 4.5.2 / 1.0.1 | Apache-2.0 | Resolved non-Apple graphics graph, not linked into macOS target; `licenses/swift-png.txt`, `licenses/h.txt` |
| ordo-one/dollup ([source](https://github.com/rarestype/dollup/tree/1.3.0)) | 1.3.0 | Unverified in wrapper; upstream source is Apache-2.0 | Resolved formatter wrapper retained for deterministic resolution; no Dollup code/binary shipped; upstream in `licenses/Dollup-source.txt` & `licenses/Dollup-NOTICE.txt` |

SwiftTerm is a modified source fork of the pinned upstream release. `vendor/SwiftTerm/TranoVendor.json` records the upstream revision, original-file hashes and local changes. The upstream archive SHA-256 is `b7bd5d65ea4e2ad0a8776878ae9b873e80c25747e437df494e5d9fceba54affe`; the generated SBOM separately identifies the modified vendored tree and its digest.

## External Prerequisites, Platform Assets, and Marks

- **tmux**: External user-installed prerequisite, not shipped in the app. CI builds `tmux` 3.6a with `libevent` 2.1.13 and `utf8proc` 2.12.0 under `build/ci-tools` with verified release dates and hashes.
- **Apple Frameworks & Fonts**: System frameworks and SF Symbols are governed by the Apple SDK and platform terms; no font files are redistributed.
- **Provider Marks & Independence**: Native drawn provider symbols identify compatible providers without claiming official affiliation or trademark grants. Trano is independently implemented and copies no source from Rex, Tern, or private CCO projects.
