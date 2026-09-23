# Litmus

Mutation testing for Swift.

Line coverage tells you which lines ran. It does not tell you whether anything
would have noticed if those lines were wrong. Litmus answers the second
question: it changes your code on purpose and checks whether your tests fail.

```
$ litmus

  ✔ killed   TestSuiteOutcome.swift:14  swapped the branches of a ternary
  ✘ survived PlayerControlViewModel.swift:479  removed a call whose result is unused

Litmus score 50%
killed 1 / survived 1 / error 0

survived — nothing failed when this changed:
  PlayerControlViewModel.swift:479  removed a call whose result is unused
```

A surviving mutant is a hole. Something in your code can be wrong and every
test still passes.

## Installing

```
brew install debugholic/tap/litmus
```

A universal binary for Apple silicon and Intel, from the latest release.
`litmus --version` says which one you have.

## Using it

```
$ litmus
```

In a project directory, that is the whole command. Litmus works out the rest:
whether the tests need a simulator, which scheme to build, which simulator to
use, and what this branch changed.

```
changes since origin/develop
measuring coverage…
  scheme MyApp

16 mutants across 2 file(s), skipping 1391 outside the change and 85 unreachable
  checking the baseline first…

  ✔ killed   PlayerControlViewModel+Bookmark.swift:26  removed a call whose result is unused
  ✘ survived PlayerControlViewModel.swift:479  removed a call whose result is unused

Litmus score 50%
killed 1 / survived 1 / error 0
```

Where a guess would be wrong, pass it: `--scheme`, `--harness xcode|swiftpm`,
`--simulators <UDID>…`, `--destination`. Where the project is ambiguous —
several schemes, say — Litmus stops and lists them rather than picking one,
because the wrong choice takes hours to disprove.

`--workers N` runs N mutants at once, each on its own simulator. It defaults to
one: a simulator is not cheap, and past a point they contend for the machine
rather than share it.

`--format plain|json|html|xcode` and `--output <path>` control the report;
`xcode` emits `warning:` lines Xcode shows beside the mutated line. With more
than one file, the plain report scores each, weakest first:

```
Litmus score 80%
killed 3 / survived 1 / timeout 1 / unviable 1 / error 0

by file, weakest first:
    0%  More/Zero.swift  killed 0 / survived 1 / error 0
  100%  Ver.swift        killed 3 / survived 0 / timeout 1 / unviable 1 / error 0
```

### The score

```
score = (killed + timeout) / (killed + timeout + survived)
```

| | | in the score |
|---|---|---|
| `killed` | a test failed, or the process crashed | caught |
| `timeout` | the suite ran ten times longer than the baseline, at least a minute, and was stopped | caught |
| `survived` | every test passed | missed |
| `unviable` | the compiler rejected the change | left out |
| `error` | the suite could not run | left out |

A change the compiler rejects is not evidence that your tests would have
caught it, and counting it as a kill is how a broken tool reports a flattering
score. The build is not abandoned for it either: Litmus takes out the switches
on the line the compiler named, writes that file again from the original, and
builds the rest.

Mutants filtered out before the run — outside the change, unreached by any
test, or in code the tests are not aimed at — are not in the score at all. It
measures the tests against the code they run, not the project.

### What it mutates, by default

Two filters are on unless you turn them off, because a run that takes hours is
a run nobody does.

**What this branch changed.** The whole tree is the right scope for a nightly
job; for a review it is thousands of mutants on code nobody touched, and their
verdicts were settled on the last run. The base is `origin/HEAD` — what a
review diffs against — and the diff is taken line by line, against the merge
base, and reaches the working tree so uncommitted work counts. On the default
branch, or outside a repository with a remote, there is nothing to compare
against and the whole tree is the honest scope.

**What the tests are aimed at.** A scheme's tests build a test target, and
that target names the modules it tests — by name, `FeatureSettingTests` for
`FeatureSetting`, and by `@testable import`. On one Tuist project a scheme
whose seven tests cover one feature reached over 1,200 files; it is mutated in that
feature's two, because the rest would survive whatever they said. This one is
not a switch; it is what the scheme means.

**What no test reaches.** A mutant on a line no test runs cannot be killed. It
will survive whatever the code says, and the only thing running it buys is the
minute it took. Litmus runs the suite once with coverage on and filters before
writing, so a skipped mutant costs neither a run nor the file growth.

```
litmus --all           # the whole tree
litmus --since main    # a different base
litmus --no-coverage   # keep what no test reaches
litmus --only Bookmark # only paths containing this
```

On one iOS project — 1,492 mutants across 105 files:

| | mutants | on one simulator |
|---|---|---|
| `--all --no-coverage` | 1,492 | a day |
| `--all` | 203 | hours |
| the default | 16 | minutes |

The last row is a run that fits inside a pull request. Litmus says what it left
out before it starts, because a narrow run that scores well is not a clean bill
of health for the project.

Coverage is measured on the project as written: injecting moves every line
below the first mutant, and a plan's positions are positions in the original.
The `swiftpm` harness filters line by line, through `llvm-cov export -format=lcov`.
The `xcode` harness filters whole files, through `xccov view --report`, which
gives line detail only one file per invocation.

### Looking at the mutants

`litmus` injects into a copy and runs it. To keep the copy and read it:

```
$ litmus inject --output /tmp/mutated
$ litmus run --project /tmp/mutated --plan /tmp/mutated/litmus-plan.json
```

The original is never modified, by either command.

### Two ways to run the tests

`--harness xcode` builds a scheme and runs it on a simulator.

`--harness swiftpm` runs the package's own tests on this machine. A package
that never reaches for UIKit does not need a simulator, and the simulator is
what a mutation run actually costs — on one project, narrowing the suite with
`-only-testing` cut test time from 24.6s to 0.236s without moving the wall
clock at all. The minute per mutant was the round trip, not the tests. Litmus
run against itself this way costs about 6 seconds per mutant.

Litmus picks between them by looking for an `.xcodeproj` or `.xcworkspace`, and
failing that, for an `import UIKit`: a project that reaches for UIKit cannot
build for this machine whatever else is true of it.

## How it works

Every mutant is compiled into the binary at once, each behind an environment
flag, and the suite is then run repeatedly with a different flag set.

```
1. inject      every mutant is written into a copy of the source, switched off
2. build       one build, every mutant inside it
3. per mutant  switch that mutant on, run the tests again
4. score       (killed + timeout) / (killed + timeout + survived)
```

The switch goes where the change happens rather than around the block holding
it:

```swift
let isOffline = (__litmus_Bookmark_ChangeLogicalConnector_24_49_832
    ? (!connection.isAvailable || info.playType == .download)
    : (!connection.isAvailable && info.playType == .download))

private var __litmus_Bookmark_ChangeLogicalConnector_24_49_832: Bool {
    __litmus_on("Bookmark_ChangeLogicalConnector_24_49_832")
}
```

`__litmus_on` compares the id with `LITMUS_ACTIVE`, read with `getenv` every
time the flag is evaluated, so the active mutant can change inside a running
process.

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

### Many mutants in one process

On a simulator, launching is most of what a mutant costs: installing the app
and starting the runner took 85 of every 115 seconds. So when a scheme's
tests are all Swift Testing, in one test bundle, Litmus adds a small driver to
the working copy's tests. It is launched once, and switches from one mutant to
the next, running the suite again each time. On one project 34 mutants took 99
seconds this way against 65 minutes one launch at a time, and every verdict
checked against a fresh process agreed.

A mutant that crashes takes the process with it; Litmus records it as killed
and launches again from the next one. One that hangs is stopped and recorded
as a timeout.

Two kinds of mutant still get a process of their own:

- **XCTest cases, or a second test bundle.** The driver cannot rerun either,
  so a scheme that has them runs every mutant in a fresh process.
- **Values Swift computes once.** A global's or a static property's initial
  value is kept from the first time it is read, with whichever mutant was on
  then. Those mutants run after the batch, one launch each.

`--isolate` gives every mutant a fresh process regardless.

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

## Status

Injection is solid: 1,492 mutants across 105 files of a real project compile
and run. Execution has been run end to end on both harnesses, and on a Tuist
project with several schemes, in one process and one per mutant.

Litmus is run against itself.

Not there yet: line-level coverage on the `xcode` harness, and more than one
worker on the `swiftpm` harness. Two `swift test` processes in one package
directory contend over `.build` and report verdicts that disagree with a
sequential run, so that is refused rather than warned about.

## License

MIT. Includes code derived from [Muter](https://github.com/muter-mutation-testing/muter),
also MIT — see NOTICE.
