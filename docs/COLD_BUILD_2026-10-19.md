# Mac cold-build verification — 2026-10-19

The signed Mac workflow completed successfully for source
`82122cfdb3ec55de7d23dc4860823df23e532c46`:
[run 39145682172](https://github.com/MochiLog/MochiLog-Mac/actions/runs/39145682172).
The runner reported three CPUs and 7,168 MiB of physical memory. Resource selection used
three C compiler jobs and normal memory mode. Local defaults remain one job and reduced
memory mode.

This run deliberately skipped Actions compiler-cache restore/save and invoked Nuitka
with `--disable-cache=all`. Its successful result therefore does not depend on a second
build finding an existing compiler cache.

| Measurement | Previous signed run | Cold verification run | Difference |
| --- | ---: | ---: | ---: |
| Workflow creation to completion | 33m 32s | 29m 46s | 3m 46s shorter, about 11% |
| Nuitka first compilation message to native binary ready | 25m 54s | 22m 00s | 3m 54s shorter, about 15% |
| C backend start to native binary ready, including linking/assembly | 21m 59s | 16m 23s | 5m 36s shorter, about 26% |

The previous reference is [run 39141703965](https://github.com/MochiLog/MochiLog-Mac/actions/runs/39141703965).
It had 2,551 C compiler cache misses, but it did restore other Nuitka cache contents.
The new run disables those caches too. Separate hosted VMs also vary in performance.
The workflow totals additionally differ because this measurement does not prepare an
update feed or save a compiler cache. These are observed run comparisons, not a
controlled same-machine benchmark or a guaranteed duration for future runs.

The new machine-readable timer measures the entire compiler subprocess, including its
startup/report work: 1,350.721 seconds. Staging and standalone verification took another
20.394 seconds. This boundary is slightly wider than the common Nuitka message markers
used for comparison above.

Verification passed:

- All 15 Python tests and the complete native protocol regression suite.
- Standalone helper verification before and after Developer ID signing, with all seven
  required library/adapter modules compiled, no user Python, typed plist, TLS, schema
  and crypto checks.
- Release build, signature verification, accepted app and DMG notarization, both
  stapled tickets, and Gatekeeper acceptance as Notarized Developer ID.

Compiler optimization and included library modules were not reduced. No replacement
0.2.34 release or update feed was published from this measurement. The existing public
0.2.34 package and its verified update feed remain the distributed release.

Detailed logs, reports and comparison JSON stay in the ignored local
`Build/cold-build-2026-10-19/` directory. Developer notes contain no device data or keys.
