# Swift synthetic A/B receive policy

`SyntheticABContract.swift` and `SyntheticABPolicy.swift` implement a serial, synthetic-only
A/B run and compile into the standalone iOS target. No UI action, real transport, clock,
credential store, retained-input-to-AB conversion, filesystem journal or baseline adapter
is connected. Types remain internal. The transport/environment/journal are concrete final
classes, not pluggable protocols or callbacks capable of sending a network request.

`SyntheticABExpected.fixture()` constructs new fixed synthetic rows and identities. The
runner requires a `synthetic-ab-<UUID>` run label and an explicitly supplied timing policy.
The environment's defaults and `SyntheticABTiming.fixture` are test values, not production
limits, a live session, or a conversion of an old Windows execution window.

Each run is exactly two sequential passes of seven allowlisted mock responses. HTTP quota
is 14 total including two Auth user checks, not 14 plus two. Requests use explicit project,
select/limit and count-exact headers. There is no refresh, retry, redirect follow, extra page
or write operation. A partial/error response stops before the next reservation.

Reservation state must serialize and read back before consuming a response. Attempt-start
is also persisted in the memory journal before consumption. Charges survive timeout,
response loss and cancellation. No-op/before-write/after-write failures poison the journal;
restored running/stopped/finished state is never resumed. This is not a disk WAL or rollback
protection, and copying snapshots is not process/power-loss durability validation.

All intervals are synthetic integer milliseconds. Equality with a time limit or expiry
blocks. The request interval includes reservation and evidence work; interpass/pre-apply
limits include the preceding response's evidence time. Session expiry is an independent
synthetic deadline. Session/boot labels and generations, plus the existing BoundaryLifecycle
lease generation, invalidate work even after values/activity return to their old state.
The claimed binding hashes the synthetic context as well as configuration and run ID.

The final local_policy_probe measures only a fake elapsed interval. It never calls storage.
Completion requires a live context again on checkedReport(), and requireApplyInput() always
throws. Reports keep baseline/execution/edit/send/automatic receive/current server flags false.

Native comparison retains unknown numeric spelling (1e0 versus 1.0), so that case is stricter
than Python's JSON numeric decoding. Tests document the difference rather than calling the
engines fully equivalent. Existing reader limitations and missing retained evidence remain.

Run the bundled host tests with swift test only under a separately authorized offline scope.
See Docs/ipad-swift-ab-offline-result-2026-09-14.md for final test counts and evidence.
