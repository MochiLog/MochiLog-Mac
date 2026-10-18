# Compiled collector CI

The Windows investigation on October 17 found a restored compiler cache with zero C compiler hits, followed by an explicit post-job refusal to save refreshed outputs under an existing key. Actions caches are immutable. Both Mac workflows used the same key pattern and have been corrected too.

Each successful run now saves refreshed compiler outputs under a unique run/attempt key. Restore prefixes prefer identical build inputs and then the compatible platform/Python family. The compiler script participates in the input hash. Nuitka prints C backend commands with `--show-scons` so compilation is observable instead of silent.

Mac DMG artifacts are retained for seven days, while compilation reports retain their existing fourteen-day lifetime. GitHub Releases remain the distribution archive. The changes affect CI cache refresh, build logging and artifact retention; compiler choice, native compilation, standalone checks, signing and notarization remain unchanged.

A faster next build is not yet measured. Inspect actual C cache hits/misses before promising an improvement. A cold build still compiles the complete maintained library.

Reference: [GitHub cache matching and immutable entries](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).

## Cold-build parallelism, October 19

The 0.2.34 signed build took 33 minutes 32 seconds including runner startup and artifact
storage. Nuitka compiled 2,551 C files with no cache hits. Its native compilation took
about 25 minutes 54 seconds, including roughly 21 minutes 39 seconds in the C backend.
Both Mac workflows had fixed compiler parallelism at two, and always enabled reduced-memory
compilation. This work targets the first build as well as subsequent builds.

`scripts/compiler-resources.py` now records the runner's actual CPU count and physical
memory, leaves 2 GiB for the system/build driver, budgets 1.5 GiB per compiler, and caps
the selection at eight jobs. Unrecognized hardware uses one job. Standard 3-CPU/7-GiB
Apple Silicon runners select three jobs; the Windows companion's 4-CPU/16-GiB runners
select four. CI disables Nuitka's reduced-memory mode when at least 6 GiB is available.
This is a conservative selection policy, not a guarantee of a specific peak-memory value.

The local build defaults remain one compiler job and reduced-memory compilation. CI
exports its selection through `GITHUB_ENV`; a local developer may explicitly set
`MOCHILOG_COMPILER_JOBS` and `MOCHILOG_COMPILER_LOW_MEMORY=0` on a suitable build machine.
Neither the included modules nor compiler optimization level, standalone verification,
signing, notarization or the shipped protocol is reduced to obtain the speedup.

Both Mac workflows have a `cold_compile` dispatch option. It skips Actions compiler-cache
restore/save and passes `--disable-cache=all` to Nuitka. This demonstrates a real cold build,
rather than attributing a warm-cache result to extra parallelism. Resource selection and
successful compile/staging/verification durations are stored beside compilation reports.
The signed workflow can be measured without preparing or publishing an update feed.

Check the new run's measurements before promising a percentage reduction. The runner is
a separate VM, so the previous run is a practical baseline rather than a controlled
same-machine benchmark.

Sources: [GitHub runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[Nuitka compiler and cache documentation](https://nuitka.net/user-documentation/tips.html).
