# Contributing

Thanks for helping. The most useful things right now:

1. **Real recordings with ground truth.** Every result so far is from synthetic clips. A 60–90 s
   outdoor clip with a plane, train or ship passing, plus its track saved within the hour, is worth
   more than any code change. See "Verify against ground truth" in
   [harness/README.md](harness/README.md) (`bun run verify clip.mov --save-track`). Clips contain
   GPS metadata: never commit them or attach them to a public issue. Open an issue first and
   we'll arrange a private way to share.
2. **Bug reports from the web app.** Include the browser, the file type (codec if you know it),
   the clip length, and the status line text. Don't attach the clip.
3. **Defense ideas.** [IDEAS.md](IDEAS.md) and the gaps in [THREAT_MODEL.md](THREAT_MODEL.md)
   are the backlog. New defenses start as harness modules, with a benchmark row showing both
   attackers, then get ported to Swift.

## Development

```sh
swift build -c release && swift test -c release   # library + CLI
cd web && bun install && bun run dev              # web app (dev stand-in without the wasm build)
cd harness && bun install && bun test             # attackers, defenses, benchmarks
```

CI builds everything on every push, including the WebAssembly scrubber, and tests the web app
against it. Keep TypeScript strict, validate external data with Zod, and add a test that fails
without your change.

By contributing you agree that your contributions are licensed under the MIT license.
