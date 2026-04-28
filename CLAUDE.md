# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
mix deps.get       # fetch dependencies
mix compile        # build
mix test           # run tests
mix test --cover   # run tests with coverage (output → /cover/)
mix format         # format code
```

## Project context

This is an Elixir client library for the [Teya API](https://docs.teya.com/apis/overview) (a payments/fintech API), published as the `teya` Hex package. The project is at early scaffold stage — no HTTP client, no API modules, and no authentication logic exist yet.

- Elixir `~> 1.19` required
- No linter configured (no Credo, no Dialyzer)
- The only quality tooling in place is `mix format`

## Architecture

The library lives under `lib/teya.ex` (and will expand to `lib/teya/` as features are added). There is no OTP supervision tree — this is a pure functional client library. When adding HTTP functionality, a client dependency (e.g. `req` or `finch`) and a JSON library (`jason`) will need to be added to `mix.exs`.
