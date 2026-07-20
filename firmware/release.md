## {{build}} · kernel {{kernel}}

| | |
|---|---|
| **Devices** | {{devices}} |
| **Target** | {{generic}} generic image |
| **Source** | {{source}} |
| **Changes** | {{changes}} |

### Bundled packages
| Package | Version |
|---|---|
{{packages}}

<details>
<summary>Flashing & first boot</summary>

- `factory` image for first install; `sysupgrade` keeps settings; verify downloads against `sha256sums`
- Default Wi-Fi: SSID `{{wifi_ssid}}` / password `{{wifi_key}}` (encryption {{wifi_encryption}}; skipped on devices without wireless)
- Default theme: shadcn (aurora included); UI language follows the browser
- Build tag: by {{build_by}}
</details>
