# RainTweak

Tweak to inject Rain into Discord.

This is a fork of [raincord/RainTweak](https://codeberg.org/raincord/RainTweak) that keeps Rain working on newer
Discord builds (developed against Discord **348.0 / iOS build 113691**) and iOS 27, ships its own patched Rain
bundle, and adds a few plugins. See [Changes from upstream](#changes-from-upstream) below.

## Installation

The latest builds can be found in the [Releases](https://github.com/kurtxtb/RainTweak/releases) tab.
**iOS 27 is NOT officially supported by upstream Rain; this fork fixes the issues listed below, but you may still encounter bugs**

<details>
<summary>Issues & Workaround</summary>
<br/>
To resolve the fixable issue, you need to match the app's bundle ID with your provisioning profile's App ID (excluding the team ID prefix):
<table>
<tr>
    <th>Issue</th>
    <th>Fixable</th>
    <th>Example</th>
</tr>
<tr>
    <td>Cannot change app icons</td>
    <td>✓</td>
    <td rowspan="5"><img src="https://adriancastro.dev/e0hbonxknepw.jpg" width="300"></td>
</tr>
<tr>
    <td>Cannot share items to Discord</td>
    <td>✗</td>
</tr>
<tr>
    <td>Cannot use passkeys</td>
    <td>✗</td>
</tr>
</table>

## Doing this will break notifications if the app is backgrounded or closed

</details>

## Changes from upstream

### Tweak

- **Embedded Rain bundle** – a patched `Rain/rain.js` is copied into `BunnyResources.bundle` and loaded directly,
  so Rain no longer depends on downloading from Codeberg. Setting a custom bundle URL in the shake menu still
  overrides it.
- **Loads on newer Discord builds** – the Hermes bytecode version is read at runtime and the matching
  `rain.<version>.hbc` is used, falling back to `rain.js`. Cached bytecode that doesn't match the runtime, or a
  bundle that fails to evaluate, is discarded instead of failing silently every launch.
- **First install restart prompt** – Rain only runs from the cached bundle on the next launch, so the tweak now
  asks you to restart once the bundle is ready.
- **iOS 27 support**
  - Alerts, the settings sheet, safe-mode reload and the updater find the key window through `UIWindowScene`s
    (required by the iOS 27 scene lifecycle) and present on the top-most view controller.
  - App exit falls back to `exit(0)` when the private suspend/terminate selectors are gone.
  - With a theme applied, the keyboard no longer paints over its own keys; on iOS 27 only the light/dark keyboard
    appearance follows the theme.
- **External plugin support** – exposes `__RAIN_EVALUATE_JAVASCRIPT__` to the JS side so Rain can load plugins
  installed from a URL.

### Bundled Rain

Built from [raincord/rain](https://codeberg.org/raincord/rain) `4b091e1` plus the patches in
[`Rain/patches`](Rain/patches) (rebuild steps in [`Rain/README.md`](Rain/README.md)).

| Patch | Change |
| --- | --- |
| 0001 | Cloud Sync page no longer crashes with "Element type is invalid" (Card is resolved at render time) |
| 0002 | Rain settings pages open on Discord 348 by registering them as native route settings rows |
| 0003 | **External plugin manager** – install, update and uninstall Rain plugins from a URL on the Plugins page |
| 0004 | The patcher skips undefined targets instead of crashing the whole plugin |
| 0005 | The Add button on addon pages sits in the right place when there is no browse button |
| 0006 | No "incompatible Discord version" warning at startup |
| 0007 | PlatformIndicators: tidier icon placement and layout |
| 0008 | Badges (core and global) work again on Discord 348 by finding `useBadges` by file path |
| 0009, 0010 | **PlatformIndicators everywhere** – icons next to usernames in member lists, the DM list, DM and channel headers, profiles and the You tab; live updates on presence changes; "Hide mobile status" works again; a Diagnostics section in its settings shows which patches applied |
| 0011 | **New plugin: PlatformSpoof** – appear online as Desktop, Web, VR or Console instead of mobile (Rain rewrite of fshin's Revenge plugin) |
| 0012 | **Plugins fix for Discord 348+**: fix Translator, ViewRaw, Quoter, JumpToTop and other ActionSheet plugins for React Compiler builds |

Many of these exist because Discord 348 is a React Compiler build: most component functions are anonymous, so
Rain's name-based lookups fail and the affected code finds modules by their exports or file path instead.

Chat messages are rendered natively by Discord, so PlatformIndicators can't show icons there.

### Builds and releases

- Builds run on GitHub Actions (**Deploy Build**) from a decrypted IPA URL; upstream's apt-repo and app-repo
  publishing was removed.
- Release notes list the commits since the previous release instead of only a "Full Changelog" link.
- Each release keeps only the current `.deb`; older ones are removed when a release is updated.
