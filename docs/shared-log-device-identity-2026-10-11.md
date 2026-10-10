# Shared source identity validation (2026-10-11)

The mobile October 10 defect used the receiving model when a foreign Analytics file omitted hardwareModel. Source UUIDs were preserved. TransferServer now includes the model of the paired source UUID inside authenticated v3 encrypted preflight controls. Foreign sharing and file decisions require logSourceIdentityVersion=1; old clients keep own-device transfer support. Existing pairings and keys are preserved.

The Mac transfer protocol suite passed with four peers, model metadata, old-client capability gating, cloud scope revocation, encrypted transfer/ACK and replay protections.

Only native Swift metadata changed. An incremental Release build reused the compiled collector and dependency licenses from verified 0.2.24: git diff against its source commit confirmed no collector entry, requirements or compilation script changes. The standard local/CI script remains a complete Nuitka compilation. The completed signed helper passed the no-user-Python smoke test again.
