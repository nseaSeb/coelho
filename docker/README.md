# Running the checks the way CI runs them

Three CI failures in a row came from the gap between the browsers on the
machine the code was written on and the ones on Linux: Firefox delivered
`Ctrl+I` to the page on macOS and not on Linux, `Home` moved the caret to a
different place, and a synthetic paste behaved differently again. None of it
was reproducible where it mattered.

This image is that environment, so the browser checks can be run **before**
pushing:

```
docker compose -f docker/compose.yml run --rm --build browsers
```

Or one engine at a time:

```
docker compose -f docker/compose.yml run --rm browsers docker/check.sh firefox
```

The first build takes a few minutes — it installs Node and the three engines
with their system libraries — and is then cached.

The repository is mounted, so the run sees the working tree rather than the
last commit. `_build`, `deps` and `node_modules` are masked by anonymous
volumes: the host's hold macOS binaries, and `npm ci` inside the container
would otherwise replace them.

## What it does not cover

Everything Elixir. That runs the same everywhere and is faster on the host:

```
mix check          # format, compile, credo, dialyzer, test
cd demo && mix test
```

The image's Elixir, OTP and Playwright versions track
`.github/workflows/ci.yml`. When one moves, the other has to.
