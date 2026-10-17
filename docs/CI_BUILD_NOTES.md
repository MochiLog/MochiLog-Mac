# Compiled collector CI

The Windows investigation on October 17 found a restored compiler cache with zero C compiler hits, followed by an explicit post-job refusal to save refreshed outputs under an existing key. Actions caches are immutable. Both Mac workflows used the same key pattern and have been corrected too.

Each successful run now saves refreshed compiler outputs under a unique run/attempt key. Restore prefixes prefer identical build inputs and then the compatible platform/Python family. The compiler script participates in the input hash. Nuitka prints C backend commands with `--show-scons` so compilation is observable instead of silent.

Mac DMG artifacts are retained for seven days, while compilation reports retain their existing fourteen-day lifetime. GitHub Releases remain the distribution archive. The changes affect CI cache refresh, build logging and artifact retention; compiler choice, native compilation, standalone checks, signing and notarization remain unchanged.

A faster next build is not yet measured. Inspect actual C cache hits/misses before promising an improvement. A cold build still compiles the complete maintained library.

Reference: [GitHub cache matching and immutable entries](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).
