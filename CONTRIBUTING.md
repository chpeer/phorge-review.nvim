# Contributing

This plugin is primarily maintained for Thought Machine's use case, but external
contributions are welcome.

## Making changes

Before opening a pull request, run the tests and the formatter:

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
stylua --check .
```

GitHub Actions runs both as well, with the tests on Neovim 0.10, stable and nightly, but
running them yourself gives faster feedback.

Tests live in `tests/*_spec.lua`. Each spec file returns a list of `{ name, fn }` pairs
and runs in its own headless Neovim. `tests/helpers.lua` has assertions, scratch git
repositories and a way to stub Conduit, so no Phabricator or Phorge server is needed.

When you change behaviour, update `README.md` and `doc/phorge-review.txt` too.
