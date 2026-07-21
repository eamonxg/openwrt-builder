# openwrt-builder

Config-driven OpenWrt firmware pipeline: edit `firmware/` → Actions builds → grab firmware from Releases.

## Layout

```
firmware/                  # you describe the firmware here; everything else builds it
├── builds.ini             # ★ which builds exist: one section = one product line
├── packages.ini           # ★ where third-party code comes from
├── settings.ini           # personalization (base + per-build/device overrides)
├── release.md             # how the release page reads
├── config/                # ★ what each build ticks in menuconfig terms
│   ├── common.config      #   every build
│   ├── x86.config         #   only x86
│   └── tr3000.config      #   only tr3000
└── uci-defaults/          # first-boot scripts
scripts/ tests/ .github/   # the machine: build scripts, unit tests, workflows
```

The extension tells you what a file does: `*.ini` **declares** things (sections of `key = value`); `*.config` **enables** things (native OpenWrt fragments concatenated into `.config`); `release.md` **presents** things (the release page template). Plus `uci-defaults/` for first-boot shell scripts.

`firmware/config/` is one mechanism at two scopes: `common.config` applies to every build, `<build>.config` to that build alone, appended in that order.

`<build>.config` **must** be named after a section in `builds.ini` — the build job picks overlays up by filename, so a misnamed one would be skipped without a word. The plan stage rejects any `.config` that matches no section (`common.config` excepted), whichever build you are running. The reverse is fine: a section needs no overlay at all, and most have none.

## Add a device or a build (builds.ini)

```ini
[name]                       # your choice; used for release tags, job names and the overlay filename
target  = board/subtarget
devices = device1 device2    # optional; omit for a full-target generic image
source  = owner/repo         # optional; default openwrt/openwrt
ref     = branch|tag|SHA     # optional; default: default branch
```

All sections build in parallel, each its own `make` run producing its own release.

**One section can cover several devices** — they share one `.config` and one release, which is what you want for variants of the same product:

```ini
[tr3000]
target  = mediatek/filogic
devices = cudy_tr3000-v1 cudy_tr3000-256mb-v1
```

So: another variant of a product you already build = append a word to `devices`. A different architecture, a different source tree, or a different `ref` = add a section.

**When one section is not enough.** Devices in the same section share a single `.config`. Package differences between them are still expressible (see the third scope below), but anything build-global is not — a different `CONFIG_TARGET_ROOTFS_PARTSIZE`, a different kernel option. Those force a split:

```ini
[tr3000]
target  = mediatek/filogic
devices = cudy_tr3000-v1

[tr3000-256mb]                 # own .config, own release tag
target  = mediatek/filogic
devices = cudy_tr3000-256mb-v1
```

The cost is a second full build. Section names may prefix each other safely — release tags match exactly on `<name>-date-time`.

## Add a plugin/theme

Two steps, because the two questions are kept apart: **where the code comes from** and **who enables it**.

**1. Source — `packages.ini`** (two keys, and neither decides what ships):

```ini
[name]                       # also the clone dir: package/custom/<name>
repo = git url               # required
ref  = branch|tag|SHA        # optional; default: default branch
```

**2. Enable it — a `.config` fragment.** Three scopes, pick the narrowest that fits:

| Scope | Which package ships | Which value applies |
|---|---|---|
| every build | `common.config` | `[settings]` in `settings.ini` |
| one build, all its devices | `<build>.config` | `[<build>]` |
| one device inside a build | `<build>.config`, two lines (below) | `[<device-id>]` |

The same three scopes, twice. Packages carry the device in the Kconfig symbol
because OpenWrt's namespace requires it; settings carry it in the section name.
Either way the device is spelled exactly as `builds.ini`'s `devices =` spells it.

*Every build* — a theme you always want, in `common.config`:

```
CONFIG_PACKAGE_luci-theme-shadcn=y
```

*One build* — `nikki` is too big for the flash-constrained boards, so only `x86.config` enables it:

```
CONFIG_PACKAGE_luci-app-nikki=y
```

*One device* — `[tr3000]` builds two variants from one `.config`, and only the 256MB one has room. `=y` would hit both, so split it in `tr3000.config`:

```
CONFIG_PACKAGE_luci-app-nikki=m
CONFIG_TARGET_DEVICE_PACKAGES_mediatek_filogic_DEVICE_cudy_tr3000-256mb-v1="luci-app-nikki"
```

`=m` builds the `.ipk` without putting it in any rootfs; the second line installs it into that one device's rootfs — the result is preinstalled firmware, same as `=y`. The symbol mirrors the device line the pipeline already generates, so copy the device name verbatim. **Both lines are required**: that symbol carries no `select`, so on its own nothing would ever compile the package. Prefix a name with `-` to *remove* it from a device instead. Do not list dependencies (nikki's mihomo core, whose package name varies) — `=m` builds them and installation resolves them.

Every scope is guarded: a `=y`/`=m` line dropped by `defconfig`, a per-device list naming a device this build does not select, or a package nothing builds — each fails the build instead of silently shipping firmware without it.

- Dependencies outside the official tree: add their repo as another section (repo only, nothing to enable)
- Packages already in the official tree need no `packages.ini` section at all — just enable them in `common.config` or an overlay
- The release "Bundled packages" table and the Chinese language pack both follow what actually shipped — neither needs maintenance

## Release page (release.md)

`release.md` is the release body, and every value in it comes from the pipeline — you edit layout and wording, never data:

```markdown
## {{build}} · kernel {{kernel}}

| **Target** | {{target}} |
| **Source** | {{source}} |

### Bundled packages
| Package | Version |
|---|---|
{{packages}}

- Default Wi-Fi: SSID `{{wifi_ssid}}` / password `{{wifi_key}}` (encryption {{wifi_encryption}})
- Build tag: by {{build_by}}
```

**One rule covers every conditional: a line whose placeholder resolves to empty is dropped whole.** No Wi-Fi configured, no `BUILD_BY`, no `LAN_IP`, no previous release to compare against — each simply loses its line. A placeholder that is not recognised is fatal, so a typo cannot quietly blank a row.

| Placeholder | Value |
|---|---|
| `{{build}}` `{{target}}` | from that build's section in `builds.ini` |
| `{{source}}` | `owner/repo@sha (ref)`, with the SHA the plan stage pinned |
| `{{changes}}` | compare link against the previous release, empty when there is none |
| `{{kernel}}` `{{built_at}}` | from the finished build |
| `{{images}}` | the flashing table, discovered from the upload dir — see below |
| `{{packages}}` | the versions table, discovered — see below |
| `{{package_repos}}` | the third-party plugin repos table, with a compare link per one that changed |
| `{{wifi_ssid}}` `{{wifi_ssid_5g}}` `{{wifi_key}}` `{{wifi_country}}` `{{wifi_encryption}}` `{{lan_ip}}` `{{build_by}}` | from `settings.ini` |

`{{packages}}` needs no list: it reads the Makefiles of the repos `packages.ini` cloned, and prints a row for each of their packages the firmware actually contains. So a package that a build did not enable, or a `mihomo` variant that does not exist, simply has no row — and adding a plugin never means remembering to update a table. Rows are grouped by source repo, in directory order.

## Personalization (settings.ini)

A section name is what it applies to: `[settings]` is the base for everything,
any other section names a build or one device of a build. The narrower scope
wins, and every key can be overridden at every scope — there is no list of
"overridable" keys.

```ini
[settings]
WIFI_SSID = Rilakkuma        # everything, unless overridden

[tr3000]                     # one build, all its devices
WIFI_SSID = Rilakkuma_Cudy

[jdcloud_re-ss-01]           # one device inside a build
WIFI_SSID = Rilakkuma_Arthur
LAN_IP    = 192.168.6.1
```

An **empty value in a narrower scope is a real override**: it switches off what a
wider one turned on. Removing the key entirely inherits instead. A section
matching no build or device fails the plan stage, so a typo cannot quietly do
nothing.

Values that differ between the devices of one build are resolved on the device,
by a `board_name` case in the generated first-boot script — `files/` is shared
by the whole build, so it cannot hold two versions of a file. A build whose
devices agree gets no case at all. `board_name` returns the device's first
device-tree compatible, so a per-device section is only as precise as that
string: two devices that share a compatible would be indistinguishable at
boot, and a section written for just one of them would silently never apply.

- `BUILD_BY`: appends `built by <name>` to the firmware version — attributing the build, not OpenWrt itself. On first boot it rewrites two files, because two readers are live: `OPENWRT_RELEASE` in `/usr/lib/os-release`, which procd reports through `ubus call system board` and LuCI renders; and `DISTRIB_DESCRIPTION` in `/etc/openwrt_release`, which `luci-lua-runtime` `dofile()`s at runtime (passwall2 pulls it in via `luci-compat`). Patch `/usr/lib/os-release`, never the `/etc/os-release` symlink
- `WIFI_SSID` / `WIFI_KEY`: default wireless when both are set (skipped on devices without wireless)
- `WIFI_SSID_5G`: optional, empty by default. One SSID on both bands lets clients roam between them on their own, which is what you usually want; set this only to split the bands when you want to pin a client to 5 GHz by hand. Needs `WIFI_COUNTRY`, and the build fails if it is missing
- `WIFI_COUNTRY`: required for 5 GHz defaults; empty = 2.4 GHz only
- `WIFI_ENCRYPTION`: `psk2` / `sae` / `sae-mixed` (default)
- `LAN_IP`: default LAN address. Unset — the default — generates no script and leaves OpenWrt's `192.168.1.1`. The DHCP pool follows the address on its own
- Values must not contain single quotes, backslashes, slashes, `#` or `|`

**Editing this file does not trigger a scheduled build.** Change detection
fingerprints the source and package repos only, so after changing a value run
the pipeline by hand once.

## Trigger & artifacts

- Manual: Actions → Pipeline, with optional build filter (comma-separated names or all), test_only (validate config, no compile), clean_build (no caches), temporary source override
- Scheduled: daily at 02:00 Beijing time; builds with unchanged upstream are skipped
- Artifacts: one release per build (`<name>-date-time`), latest 3 kept; flashable firmware plus a regenerated `sha256sums` only, under original OpenWrt filenames
