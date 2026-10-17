# Daily log review — 2026-10-17

## Evidence

Reviewed existing native snapshots and daily logs for October 16 and 17. Raw archives, addresses, device identifiers and keys stay outside Git in ignored Build folders.

Mac 0.2.32 stored the October 17 iPhone report at 09:04:40 JST and its Watch report at 09:19:39; automatic collection stopped at 09:24:19. The 09:09 collection recorded inaccessible accessory directories and took 39 seconds. The code grouped current and archived Watch directory reads in one catch block, so an archive failure could prevent checking current reports. This is a reproduced code path; the logs do not prove a Watch report already existed during that earlier attempt.

Both native implementations could report acquisitionComplete=true after ignoring an inaccessible accessory directory. The direct-IP bridge also swallowed accessory-listing failures. A successful listing of another directory is not proof that all report sources were checked.

At the initial 10:23 sample, Mac resident memory was 66,289,664 bytes with a peak of 160,710,656. Windows private memory was 227,856,384 bytes and managed memory was 6,933,640. Windows cumulative allocations are not retained memory. These samples do not show another runaway diagnostic reader.

The iPad still exposed zero current-day candidates in successful listings. Mac later lost its OS diagnostic route while Windows continued reading through an explicitly identified USB route. Windows' discovery status came from an earlier search, not a fresh determination that the device was locked; its eight-language empty-search message now makes that scope explicit. A restore-mode service response was recorded once on October 16; the exact reason for that temporary device state is not established.

## Changes and checks

Current and archived directories are independent. Only advertised archive directories are requested after a successful current-directory read; if that read fails, the archive remains an independent fallback. Available host/Watch reports continue to be saved. Duplicate current/archive paths still prefer the archived copy.

The compiled transport returns bounded listingFailures metadata. Swift and C# preserve a separate listing-failure count in collection results, activity logs and native snapshots, display a translated partial-result explanation, and do not report complete acquisition while a listing remains unknown. The next ordinary collection retries it. No extra cooldown or retry-frequency reduction was added.

The new helper field is additive; native readers accept older helper output without that field. Existing pairing identities, request encryption, replay rejection, preflight deduplication, ACK, daily completion and mobile transfer formats are unchanged. Python remains only the maintained transport adapter; report selection and application policy remain native.

Regression checks reproduce an inaccessible archive with readable current Watch data, an unavailable current directory with an independent archived listing, omitted optional archive folders, a partial result with no pending downloads, and recovery on the next collection. The complete native Mac suite and complete Release suite on the physical Windows PC passed, along with all ten Python tests in each repository. Physical installed-build verification and release artifact results are recorded below after packaging.

## Mac packaging and physical verification

Mac 0.2.33 (36) passed the final native suite, including older-summary decoding. The fully recompiled helper passed standalone checks both before and after Developer ID signing, with Python paths deliberately unavailable. Apple accepted and stapled both the app and DMG. The physical Mac was updated with graceful termination and an atomic app swap; both paired identities were preserved. The new helper successfully read the iPhone's OS diagnostic root, and daily suspension after the stored host/Watch reports remained active. The iPad's Mac route remained unavailable, so no claim of new physical iPad acquisition is made. Its partial-directory failure cases were verified with controlled regression fixtures.

DMG: 124023853 bytes; SHA-256 0dab07a6ab582acab061d1a5de3b3c95f6d81493b35cb950bdd263572a9c4f48.

The independent [GitHub Actions collector check](https://github.com/MochiLog/MochiLog-Mac/actions/runs/38991531318) also passed compilation and verification without a user Python environment. A later 11:36 JST native snapshot reported 47,529,984 resident bytes, no active helpers and both paired identities retained.
