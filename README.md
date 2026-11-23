# pakku

Pakku is a pacman wrapper with AUR support. It looks and behaves like pacman,
then adds the AUR handling: search, review, build and install.

Pakku is the creation of [kitsunyan](https://github.com/kitsunyan), now
maintained by Pakku users and the Nim community. Open issues here:
<https://github.com/zqqw/pakku/issues>. Pull requests for improvements and bug
fixes are welcome.

## Features

- Installing packages from the AUR and the official repositories
- Searching and querying AUR packages
- Viewing PKGBUILDs, `.SRCINFO`, files and changes before building
- Retrieving PKGBUILDs with `pakku -Sz`
- Reading AUR comments with `AurComments`
- Reusing built archives and keeping them under your own cleanup policy
- Removing make dependencies after building
- No PKGBUILD sourcing during builds. Version detection runs in a helper
  subprocess.

Pakku keeps most of the old habits:

- Pacman-like user interface, options and configuration
- Download everything, ask all the questions, and only then start building
- `sudo`, `doas` and `su` work out of the box

## Compared with other AUR helpers

✓ means built in. ✗ means absent. "manual" means the workflow allows it without
helper support.

| | pakku | paru | yay | makepkg by hand |
|---|---|---|---|---|
| Binary size[^₁] | **0.87 MiB** | 7.53 MiB | 11.30 MiB | n/a |
| Fetched libs[^₂] | **none** | 308 crates | 27 modules | PKGBUILD sources |
| Review before build | ✓ | ✓ | ✓ | manual |
| Skips rebuild when archive exists | ✓ exact match | ✓ `needs_build` | ✓ `ReBuild=no` | manual |
| Artifact policy | **✓ output, copy, cleanup** | partial | partial | manual |
| Removes make deps | ✓ | ✓ | ✓ | manual (`-r`) |
| AUR comments | first page | all with `-cc` | ✗ | ✗ |
| VCS rebuild on upgrade | ✗ | ✓ | ✓ | ✗ |
| AUR download-only | ✗ | ✗ | ✓ | source download with `-o` |
| Provider prompt | ✗ | ✓ | ✓ | ✗ |
| sudoloop | ✗ | ✓ | ✓ | ✗ |
| Arch news | ✗ | ✓ | ✓ | ✗ |
| Strict config errors | **✓** | warns | partial | n/a |
| Privileged install helper | **✓ bundled, fixed argv** | external sudo | external sudo | sudo |

[^₁]: Sizes, 2026-11-19: pakku 9feb327, 911,472 B; paru 2.2.0, 7,899,440 B; yay 3a25046, 11,837,664 B.

[^₂]: Pakku 9feb327 has no Nimble deps. Paru 2.2.1 `Cargo.lock`: 308 crates. Yay 3a25046 `go.mod`: 27 modules. Manual makepkg fetches PKGBUILD sources.

## Gaps

- AUR comments stop at the first page.
- Archive reuse is filename-based and silent. There is no `--rebuild` switch.
- No VCS rebuild on upgrade, multi-provider prompt, download-only mode, local PKGBUILD build, sudoloop or news integration.
- Search output is not column-aligned and descriptions are not truncated.
- On non-Arch-based distributions, `-Sz` works for AUR packages only and `-Sn` does not work.

## Installation

Stable release from the AUR:

```shell
git clone https://aur.archlinux.org/pakku.git
cd pakku
makepkg -si
```

Latest development code:

```shell
git clone https://aur.archlinux.org/pakku-git.git
cd pakku-git
makepkg -si
```

Prebuilt x86_64 binary, no compiler needed:

```shell
git clone https://aur.archlinux.org/pakku-bin.git
cd pakku-bin
makepkg -si
```

The binary is linked against the `pacman` and `curl` of the release date, so
use it on a current Arch system; `pakku` remains the package for aarch64 and
for systems that are behind. `pakku-bin` provides and conflicts with `pakku`,
so only one of them can be installed.

Current source needs `pacman`, `libcurl.so` and `git` at runtime, plus `nim`,
`git` and `asciidoc` to build.

For more build options, see the
[wiki](https://github.com/zqqw/pakku/wiki/Building-and-modifying-pakku).

## Examples

```shell
pakku -Syu                       # sysupgrade, including the AUR
pakku -S foo                     # install from repositories or the AUR
pakku -S --build linux linux-headers
pakku -Qdttt                     # all dependency islands
```


## Some tips

- Pakku has color! Enable [color for Pacman](https://wiki.archlinux.org/title/Color_output_in_console#pacman) and it carries over.
- Use `PreferredSudoCommand` to pick `sudo`, `doas` or `su`. `SudoExec` execs from root through that helper when needed, so you get one password prompt.
- Don't forget to read the `pakku(8)` and `pakku.conf(5)` man pages to read the
full list of features!

## Configuration

`/etc/pakku.conf` follows the `pacman.conf` format. `#` starts a comment at the
start of a line or after whitespace. Unknown options, bad enum values and invalid
flag values will produce errors.

Common switches:

- `AurComments`, `CheckIgnored`, `PrintAurNotFound`, `PrintLocalIsNewer` for
  comments and upgrade warnings.
- `ViewNoDefault` asks before showing PKGBUILDs and other files.
- `PreBuildCommand` runs in the package directory before the build. For example, `PreBuildCommand = customizepkg --modify` wires in customizepkg.

## Built archives and build policies

Pakku builds in `TmpDir` and deletes the workspace and the archive after a
successful install. That is cheap for a repository package and expensive for an
AUR one: the build takes minutes, and a reinstall, a downgrade or a build on
another machine repeats it.

Pakku can keep the archives and reuse them. They can stay on this machine, or
live in one directory that several machines can reach:

| Setting | Default | Why it is there |
|---|---|---|
| `PackageOutputDir` | `TmpDir` | Moves the archives out of the temporary workspace and becomes a reuse source. |
| `CleanupAfterInstall` | `Full` | `Full` removes the workspace and the archives, `Worktree` keeps the installed ones, `None` also keeps the workspace. Uninstalled split-package siblings are removed in the last two. |
| `KeepBuildDirOnFailure`, `KeepBuiltPackagesOnFailure` | off | Keep the workspace or already-written archives after a failed build, so a retry does not start from zero. |
| `PreserveBuilt` | `Disabled` | Copies installed archives somewhere that outlives the run: pacman's cache (`Internal`), pakku's user cache (`User`), makepkg's `PKGDEST` (`Pkgdest`). |
| `PAKKU_PRESERVE_DIR` | unset | Replaces that copy destination for one run. |

`User` is the usual local choice, because `${UserCacheDir}/packages` sits inside
pakku's own cache where pacman's cleanup cannot reach it. `Internal` copies into
pacman's cache, where packages are kept for later downgrades, and follows a single
`CacheDir` entry, the last one listed. `Pkgdest` follows `makepkg.conf`, where an
exported `PKGDEST` wins and an empty result means no copy.

For a directory shared between machines, mount it and name it for the run:

```sh
PAKKU_PRESERVE_DIR=/mnt/share/pakku pakku -Syu
```

The variable replaces the configured destination for that run only, and pakku
reports when it overrides a mode other than `Disabled`. The path is checked
before anything is built: absolute, existing, and outside the build output. Pakku
does not mount or clean the directory, and a failed copy costs the shared copy,
not the install.

Archives are matched by file name, so share only a directory you trust and delete
an archive to rebuild that version. Pacman's `CacheDir` is a poor choice for
sharing, because `pacman -Sc` and its downloads change it independently.

During a run:

1. makepkg writes to `PackageOutputDir` or `TmpDir`. Do not export `PKGDEST`,
   pakku writes its own value into the build configuration.
2. Before building a base, pakku looks in the output directory and then in the
   copy destination. Every expected archive must be present and non-empty.
3. After you confirm, pakku copies the archives to the copy destination, runs
   pacman, then applies `CleanupAfterInstall`. Destination archives are never
   removed.

## Building pakku

```shell
make                 # release binary, completions and man pages
make src/pakku       # local binary only
nim  test            # Nim test suites
make releasecheck    # clean checkout must sit on the exact v${RVERSION} tag
```

`Version` in `config.nims` is the only number to bump. Release builds use it as is.

## Contributing

Please, keep pull requests small and single-purpose.

## License

Pakku is licensed under GPL-3.0-only; see `COPYING`.
