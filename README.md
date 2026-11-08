# Sapfire

A light browser for Mac. Spaces, previews, split view — and no ads.

- **Spaces** with their own tabs, pinned sites and folders. Work or personal: each space can have its own profile, with its own sign-ins.
- **VPN or direct, per site.** Send a profile — or incognito — through your VPN proxy; everything else goes direct.
- **Split view** up to four pages, **Peek** for links from pinned sites, **Little Window** for links from other apps.
- **Ads and trackers blocked** out of the box, YouTube too.
- **Safari's engine** (WebKit, already on your Mac), **Chrome's extensions** (Chrome Web Store and Firefox Add-ons, macOS 15.4+).
- **Coming from Arc?** Spaces, pinned tabs, folders, splits, history and passwords move over in one step.
- **Coming from somewhere else?** Bookmarks, history and passwords from Chrome, Dia, Brave, Edge, Vivaldi, Opera; bookmarks and history from Firefox and Safari.

No account, no telemetry: Sapfire has no server of its own.

## Download

[Latest release](https://github.com/sapfireapp/sapfire/releases/latest) — one build for Apple silicon, one for Intel. macOS 14 or later. Signed and notarized by Apple.

## Build from source

Needs Xcode 16 or later (only its command-line tools are used — there is no Xcode project).

```bash
./build.command
```

Builds `build/Sapfire.app` for this Mac and opens it.

To make release builds (both architectures, signed with a Developer ID, notarized, in DMGs), see the steps at the top of `tools/release.command`.

## License

Sapfire is free software under the [GNU General Public License v3.0](LICENSE).

The name “Sapfire” and the gem icon are not covered by the GPL: forks need their own name and icon.

The filter lists in `Filters/` are bundled so the first launch blocks ads without going online, and are refreshed from their sources afterwards. They belong to their authors: [EasyList and EasyPrivacy](https://easylist.to) (GPLv3 or CC BY-SA 3.0), [EasyList Cookie](https://easylist.to) (CC BY 3.0), [RU AdList](https://github.com/easylist/ruadlist) (CC BY-SA 3.0), and the YouTube lines of [uBlock Origin’s uAssets](https://github.com/uBlockOrigin/uAssets) (GPLv3). Update them with `tools/filters.sh`.
