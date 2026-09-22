# Litmus

Mutation testing for Swift, built on the documented parts of `xcodebuild`.

Line coverage tells you which lines ran. It does not tell you whether anything
would have noticed if those lines were wrong. Litmus answers the second question:
it changes your code on purpose and checks whether your tests fail.

```
$ litmus run

  ✔ killed    PlayerControlViewModel+Bookmark.swift:24  changed && to ||
  ✘ survived  PlayerControlViewModel+Bookmark.swift:56  changed && to ||

  Litmus score 50%  (killed 1 / survived 1)

  survived — nothing failed when this changed:
    PlayerControlViewModel+Bookmark.swift:56  changed && to ||
```

A surviving mutant is a hole. Something in your code can be wrong and every test
still passes.

## How it works

Litmus compiles every mutant into the binary at once, each one guarded by an
environment variable, and then runs the suite repeatedly with a different switch
turned on.

```
1. inject schemata      every mutant is written into the source, disabled
2. build-for-testing    one build, all mutants inside it
3. per mutant           TEST_RUNNER_<id>=YES xcodebuild test-without-building
4. score                killed / (killed + survived)
```

Step 3 uses `TEST_RUNNER_<VAR>`, which `man xcodebuild` defines as the supported
way to pass an environment variable into the test runner process. The generated
`.xctestrun` is read, never written, so mutants can run in parallel across
several simulators without stepping on each other.

## Status

Early. The execution layer works; the schemata and reporting layers are being
ported from Muter (see NOTICE).

## Not counted in the score

A mutant whose build fails is reported as `error`, not as `killed`. The compiler
rejecting a change is not evidence that your tests would have caught it.

## License

MIT. Includes code derived from [Muter](https://github.com/muter-mutation-testing/muter),
also MIT — see NOTICE.
