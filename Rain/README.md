# Embedded Rain bundle

`rain.js` is shipped inside `BunnyResources.bundle` and loaded by the tweak instead
of downloading Rain from Codeberg (unless a custom bundle URL is set in the shake menu).

- Upstream: https://codeberg.org/raincord/rain at `4b091e1`
- Patches applied: `patches/*.patch`

## Rebuilding

```sh
git clone https://codeberg.org/raincord/rain.git && cd rain
git checkout 4b091e1
git am ../NailongTweak/Rain/patches/*.patch
pnpm install
pnpm add -D @swc/core@1.16.2   # 1.16.13+ refuses to load on some Windows setups
node scripts/build.mjs --release-branch main
cp dist/rain.js ../NailongTweak/Rain/rain.js
```

Update the commit hash above when rebasing onto a newer Rain.
