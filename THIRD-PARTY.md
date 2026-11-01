# Third-party components

Our Swift launcher, mouse bridge and integration scripts are MIT-licensed.
Third-party game code and assets are not part of the repository or release.

| Component | Pinned source | License | Distribution |
|---|---|---|---|
| Wine CX26 / Wine11 | [mach9 cx-26.3.0-9](https://github.com/athei/mach9/releases/tag/cx-26.3.0-9), Wine source at `athei/wine`, branch/commit identified by that release | LGPL-2.1-or-later; bundled libraries retain their own terms | Downloaded by the user from upstream, not bundled in our ZIP |
| x87sidecar | [499e0f7e60d2961d379df459dd96bc79ecfe59fd](https://github.com/athei/x87sidecar/tree/499e0f7e60d2961d379df459dd96bc79ecfe59fd) | MIT, copyright Lifeisawful and upstream contributors | Built from pinned source, bundled; notice in `licenses/` |
| mtld3d | [v0.15.1](https://github.com/athei/mtld3d/releases/tag/v0.15.1) | zlib, copyright Alexander Theissen | Bundled with clearly marked NNG-specific compatibility patch |
| Rosetta 2 / macOS frameworks | Installed system components | Apple terms | Not redistributed; Easy installer offers installation by Apple after explicit license acceptance |

The modified i386 `d3d9.dll` is **not** the original upstream binary. Nine bytes
are changed to avoid two reproduced Lineage II resize failures. The script
checks the exact original hash and PE relocations. See `patches/` for the
binary recipe and source-equivalent patch. Other mtld3d binaries are unmodified.
The mtld3d diagnostic capture hotkey is disabled by this patch.

Upstream archive URLs and SHA-256 are in `resources/dependencies.json`.
The generated app's `acceleration/runtime.json` additionally pins every loaded
Wine/renderer executable and the locally built sidecar.

Lineage II executables, game data, server modules/updaters, fonts, game account
files and Wine prefixes are excluded. Any macOS fonts used by Wine remain
local system resources. Users obtain their compatible client independently.
This project makes no claim to authorship of Wine, Rosetta, x87sidecar or mtld3d.

## Automatic NNG installation variant

`NNG Mac Easy` additionally downloads the original NNG updater and game files
from the original NNG server, and selected compatible modules from the public
L2Craft launcher archive. These binaries are not included in our repository or
release and are not covered by our MIT license. Their SHA-256 and source archive
entries are recorded in `resources/easy-install.json`. Configuration-only binary
deltas are in `resources/settings-patches.json`; no account or owner prefix is
copied. Obtaining these components remains subject to their owners' terms.
