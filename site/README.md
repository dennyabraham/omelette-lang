# The Omelette site

Landing page, guide, and a browser playground that runs the real compiler
client-side (via Fengari). No build tooling — the pages are plain HTML/CSS/JS
with vendored single-file dependencies.

## Build

```
lua site/build.lua
```

Assembles `site/dist/` from `site/src/` and `site/vendor/`.

## Build and serve locally

```
lua site/build.lua --serve         # http://localhost:8000
lua site/build.lua --serve 9000    # pick another port
```

The dev server runs through [uv](https://docs.astral.sh/uv/), which provisions
a pinned, managed Python (3.13) and serves `site/dist/` with the stdlib
`http.server`. It doesn't touch whatever `python3` is on your `PATH`, so a
broken or bleeding-edge system Python won't break local review. Serving over
`http://` matters — the playground fetches files, which `file://` blocks. Pass
a port argument if 8000 is already taken.

`uv` is the only prerequisite: `brew install uv` (or see the uv docs).
