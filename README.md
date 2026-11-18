# protonnyuu

A personal Proton build for one PC: [DW-Proton](https://dawn.wine/dawn-winery/dwproton) rebuilt for an Intel Core Ultra 9 285K (Arrow Lake) and kept on DW-Proton's newest release.

Built for: Intel Core Ultra 9 285K (Arrow Lake, 24 threads), NVIDIA RTX 5080, Steam on NixOS. The CPU is recorded in `hardware/profile.json`.

> **Unofficial.** This is not a Dawn Winery, Valve or CachyOS release, and they do not support it. Report problems here, never to them. The scripts were written with the help of an AI assistant; DW-Proton's own code and patches are unchanged.

## What it changes

| Part | Upstream DW-Proton | protonnyuu | Why |
|---|---|---|---|
| Source | release tag | the same tag, pinned by tag object and commit in `upstream.json` | identical fixes, including DW-Proton's Wuthering Waves launcher fixes |
| C/C++ flags | `-O2 -march=nocona -mtune=core-avx2` | `-O2 -march=arrowlake -mtune=arrowlake` | code tuned for this CPU |
| Rust flags | `-Ctarget-cpu=nocona` | `-Ctarget-cpu=alderlake` | same, for the Rust parts (GStreamer plugins). The SDK's Rust 1.68 does not know `arrowlake`; Alder Lake has the same core instruction set |
| AVX | turned off for GCC builds (`-mno-avx -mno-avx2 -mno-avx512f`) | **still off** | MinGW can't keep the 32-byte stack alignment that AVX needs, so AVX in Windows-side code can crash. Proton adds these flags after ours, and that is kept on purpose |
| Name | `dwproton-<version>` | `protonnyuu-<version>` | both can be installed side by side |

Expect a small CPU-side gain, not a big FPS change. Most game work already runs in DXVK and vkd3d-proton (built `-O3` upstream) and on the GPU.

**Only for this CPU or a newer Intel one.** `-march=arrowlake` code may stop with "illegal instruction" on other CPUs. Change `march` in `hardware/profile.json` to build for another CPU.

## Build and install

Needs Docker (the build runs in Valve's Proton SDK container), about 60 GB free, and 1–2 hours on 24 threads.

```sh
scripts/build.sh      # clones DW-Proton to ~/Projects/dwproton-src at the pinned tag, checks it, builds it
scripts/install.sh    # copies the last build to ~/.local/share/Steam/compatibilitytools.d/protonnyuu-<version>
```

Restart Steam, then pick `protonnyuu-<version>` under a game's **Properties → Compatibility**.

`build.sh` stops if the source checkout has local edits, so it never overwrites your changes. Builds go to `~/.cache/protonnyuu/build-<tag>-<hash>`; the hash covers the flags and SDK, so changing `hardware/profile.json` starts a clean build.

## What is checked before building

| Check | Against | Stops when |
|---|---|---|
| Tag signature | the DW-Proton maintainer's key in `keys/`, fingerprint `E6A977FC4B13F2FAD95BEF7F22281EA4F96740C8` (`upstream.json` `signingKey`) | the tag isn't validly signed by that key |
| Tag object and commit | `upstream.json` `tagObject` / `commit`; on update, also the [GitHub mirror](https://github.com/dawn-winery/dwproton-mirror) must carry the same tag object | either differs |
| Build container | Valve's Proton SDK image, run by digest (`sdkImage` + `sdkDigest`) | a release asks for a different SDK image |
| Submodules | pinned by the signed commit itself | — |

The key came from the maintainer's dawn.wine profile on 2026-11-18. It isn't on a public keyserver or a GitHub account, so it is trusted on first use, and the identical tag on the GitHub mirror is the second source. A release signed by a different key, or needing a new SDK image, stops for a manual check instead of building.

## Stay up to date

```sh
scripts/update.sh                           # report whether DW-Proton has a newer release
scripts/update.sh --install --push          # build it, install it, commit and push the new pin
```

The last output line is a JSON summary: `up-to-date`, `available`, `needs-review` (new SDK image, or the mirror doesn't match yet), `built`, `build-failed` or `error`. If the build or install fails, or the run is interrupted, `upstream.json` is restored and the old build stays installed. `--push` commits only `upstream.json`, only on branch `main`, and pushes to `origin main`.

## Credits

This project only adds build scripts. All of the work below belongs to the people who wrote it:

- **[Proton](https://github.com/ValveSoftware/Proton)** by Valve Software and contributors.
- **[Wine](https://www.winehq.org/)** by the Wine project and its contributors, licensed LGPL-2.1-or-later.
- **[DW-Proton](https://dawn.wine/dawn-winery/dwproton)** by the Dawn Winery team, who maintain the fixes for anime/gacha games, including the Wuthering Waves launcher fixes this build relies on.
- **[Proton-CachyOS](https://github.com/CachyOS/proton-cachyos)** by the CachyOS team, which DW-Proton is built on.
- **[Proton-EM](https://github.com/Etaash-mathamsetty/Proton)** by its authors and contributors, whose compatibility fixes DW-Proton includes.
- **[GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom)** by GloriousEggroll and contributors, for the game patches DW-Proton imports.
- **[DXVK](https://github.com/doitsujin/dxvk)**, **[vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton)**, **[dxvk-nvapi](https://github.com/jp7677/dxvk-nvapi)** and **[dxvk-gplasync](https://gitlab.com/Ph42oN/dxvk-gplasync)** and their authors.
- FFmpeg, GStreamer, and the other projects bundled in Proton, each under its own license.

If this build is useful to you, star [DW-Proton](https://dawn.wine/dawn-winery/dwproton), [Proton-CachyOS](https://github.com/CachyOS/proton-cachyos) and [Proton-EM](https://github.com/Etaash-mathamsetty/Proton).

## License

The scripts in this repository are under the BSD 3-Clause license (`LICENSE`), the same license as Proton's own top-level code. A built Proton contains Wine (LGPL-2.1-or-later) and many other components, each under its own license; see `LICENSE` and `LICENSE.proton` in the [DW-Proton source](https://dawn.wine/dawn-winery/dwproton) and the `LICENSE`/`COPYING` file in each component. This repository does not publish built binaries.
