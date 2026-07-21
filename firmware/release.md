## {{build}} · kernel {{kernel}}

- **Target** `{{target}}`
- **Source** {{source}}
- **Upstream changes** {{changes}}
- **Built** {{built_at}}
- **Built by** {{build_by}}

{{images}}

{{packages}}

{{package_repos}}

<details>
<summary>Notes</summary>

- Verify downloads against `sha256sums`
- A first install on a router follows the Purpose column in order: tftp-boot the initramfs image from U-Boot, then flash the sysupgrade image from the system it brings up
- Default Wi-Fi: SSID `{{wifi_ssid}}` / password `{{wifi_key}}` (encryption {{wifi_encryption}}; skipped on devices without wireless)
- Separate 5 GHz SSID: `{{wifi_ssid_5g}}`
- Default theme: shadcn (aurora included); UI language follows the browser
</details>
