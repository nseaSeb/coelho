# The environment the browser checks run in, so that they can be run before
# pushing rather than discovered afterwards.
#
# Three CI failures in a row came from the gap between the browsers on a
# developer's machine and the ones on Linux: Firefox delivered Ctrl+I to the
# page on macOS and not on Linux, `Home` moved the caret to a different place,
# and a synthetic paste behaved differently again. None of it was reproducible
# where the code was written.
#
# The versions here track .github/workflows/ci.yml. When one moves, the other
# has to.
# OTP 28.1.1 is what setup-beam resolves `otp-version: "28.1"` to in CI.
FROM hexpm/elixir:1.19.5-erlang-28.1.1-debian-bookworm-20260803-slim

ENV DEBIAN_FRONTEND=noninteractive \
    MIX_ENV=dev \
    LANG=C.UTF-8

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl git build-essential \
  && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# `--with-deps` pulls the system libraries the engines need, which is the part
# that is tedious to get right by hand and the reason this image exists.
#
# The version has to match demo/package.json: Playwright downloads a browser
# build keyed to its own revision, and a mismatch sends the run looking for an
# executable that was never installed.
RUN npx --yes playwright@1.62.1 install --with-deps chromium firefox webkit

WORKDIR /coelho

# Nothing is copied in: the repository is mounted, so a check runs against the
# working tree rather than against whatever was last committed.
CMD ["docker/check.sh"]
