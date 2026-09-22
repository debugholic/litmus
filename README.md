# Litmus

Mutation testing for Swift.

Line coverage tells you which lines ran. It does not tell you whether anything
would have noticed if those lines were wrong. Litmus answers the second
question: it changes your code on purpose and checks whether your tests fail.

```
$ litmus run --project . --plan litmus-plan.json --harness swiftpm

2 mutants, 1 process(s)
  checking the baseline first…

  ✔ killed   TestSuiteOutcome.swift:14  swapped the branches of a ternary
  ✘ survived MutationOperator.swift:24  changed == to !=

Litmus score 50%
killed 1 / survived 1 / error 0

survived — nothing failed when this changed:
  MutationOperator.swift:24  changed == to !=
```

A surviving mutant is a hole. Something in your code can be wrong and every
test still passes.

## Using it

Injection and running are separate commands, because injection rewrites a copy
of your project and you may want to look at it.

```
$ litmus inject --project . --output /tmp/mutated
  PlayerControlViewModel+Bookmark.swift: 14
  14 mutants across 1 file(s)
  plan written to /tmp/mutated/litmus-plan.json

$ cd /tmp/mutated
$ litmus run --project . --plan litmus-plan.json \
             --scheme MyApp --simulators <UDID> <UDID>
```

`--only <text>` narrows either command to paths containing that text.
`--format plain|json|html|xcode` and `--output <path>` control the report;
`xcode` emits `warning:` lines Xcode shows beside the mutated line.

### Skipping what no test reaches

A mutant on a line no test runs cannot be killed. It will survive whatever the
code says, and the only thing running it buys is the minute it took.

```
$ litmus inject --project . --output /tmp/mutated \
                --skip-coverage --harness swiftpm

measuring coverage first…
  89 file(s) with nothing running in them

  75 mutants across 12 file(s)
  12 skipped — no test reaches them
```

Litmus runs the suite once with coverage on and filters before writing, so a
skipped mutant costs neither a run nor the file growth. Coverage is measured on
the project as written: injecting moves every line below the first mutant, and
a plan's positions are positions in the original.

The `swiftpm` harness filters line by line, through `llvm-cov export -format=lcov`.
The `xcode` harness filters whole files, through `xccov view --report`, which
gives line detail only one file per invocation.

Anything the report is silent about is kept. Dropping a mutant that could have
been killed hides a hole, which is the one failure this tool exists to prevent;
keeping one that cannot costs a single run.

### Two ways to run the tests

`--harness xcode` builds a scheme and runs it on a simulator. Pass
`--simulators` more than once to spread mutants across several; each one is a
worker, and they only read what the build produced.

`--harness swiftpm` runs the package's own tests on this machine. A package
that never reaches for UIKit does not need a simulator, and the simulator is
what a mutation run actually costs — on one project, narrowing the suite with
`-only-testing` cut test time from 24.6s to 0.236s without moving the wall
clock at all. The minute per mutant was the round trip, not the tests. Litmus
run against itself this way costs about 6 seconds per mutant.

## How it works

Every mutant is compiled into the binary at once, each behind an environment
flag, and the suite is then run repeatedly with a different flag set.

```
1. inject      every mutant is written into a copy of the source, switched off
2. build       one build, every mutant inside it
3. per mutant  set that mutant's variable, run the tests again
4. score       killed / (killed + survived)
```

The switch goes where the change happens rather than around the block holding
it:

```swift
private let __litmus_Bookmark_ChangeLogicalConnector_24_49_832 =
    ProcessInfo.processInfo.environment["Bookmark_ChangeLogicalConnector_24_49_832"] != nil

let isOffline = (__litmus_Bookmark_ChangeLogicalConnector_24_49_832
    ? (!connection.isAvailable || info.playType == .download)
    : (!connection.isAvailable && info.playType == .download))
```

Wrapping the enclosing block instead would copy it once per mutant, and the
cost multiplies through nesting: on one project that turned an 877-line file
into 9,378 lines, and the whole source tree into 2.76× its size. Switching the
expression keeps it additive — the same tree grows by 12%.

Mutations are applied through the syntax tree, never by editing text at an
offset. Offsets are UTF-8 byte counts and string indices are characters; the
two agree only for ASCII, so a file with a non-English comment in it silently
takes the edit in the wrong place.

With `--harness xcode`, step 3 uses `TEST_RUNNER_<VAR>`, which `man xcodebuild`
documents as the supported way to pass a variable into the test runner process.
The generated `.xctestrun` is read, never written, so mutants can run on
several simulators at once without stepping on each other.

## Operators

| | |
|---|---|
| `ChangeLogicalConnector` | `&&` ↔ `\|\|` |
| `RelationalOperatorReplacement` | `==` ↔ `!=`, `<` ↔ `>=`, `<=` ↔ `>` |
| `SwapTernary` | `a ? b : c` → `a ? c : b` |
| `RemoveSideEffects` | drops a call whose result is unused |

`RemoveSideEffects` leaves alone anything that would stop the file compiling:
an initializer's `super.init`, a call that never returns, and a block whose
only statement is an expression, which is an implicit return.

## Not counted in the score

A mutant whose build fails is reported as `error`, not as `killed`. The
compiler rejecting a change is not evidence that your tests would have caught
it, and counting it as a kill is how a broken tool reports a flattering score.

## Status

Injection is solid: 1,492 mutants across 105 files of a real project compile
and run. The execution layer is newer and has been run end to end on both
harnesses, on runs of tens of mutants rather than thousands.

Litmus is run against itself. Its own score is 61%, and the survivors are in
the parts that touch the filesystem and spawn processes.

Not there yet: a Homebrew tap, prebuilt binaries, line-level coverage on the
`xcode` harness, and more than one worker on the `swiftpm` harness. Two
`swift test` processes in one package directory contend over `.build` and
report verdicts that disagree with a sequential run, so that is refused rather
than warned about.

## License

MIT. Includes code derived from [Muter](https://github.com/muter-mutation-testing/muter),
also MIT — see NOTICE.
