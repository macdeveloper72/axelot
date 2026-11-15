# Block insertion and removal investigation

Status: block and cable tools implemented in source; live acceptance INCOMPLETE. The cable update has not been installed.

## Artifact

Installed Axe-Edit III 1.15.04 arm64 slice:

- Universal executable SHA-256: 1522a40d8d784dbfc83649b494d016c4c816d32df90f48ca42cf4e5814799483
- arm64 __text SHA-256: 55c91db6d06c1d8df8249de58beac91bf760a6e55aefba92c98d60fc90e64818
- Local disassembly: `.local/grid-tools/disassembly.txt` (ignored).

## Static observations

- Gen3CommandTarget primary vtable: 0x1013dd668; perform slot +0x28: 0x1000b6810.
- Dispatcher masks command record word 0 to low 16 bits; high 16 bits carry an argument.
- Command 2000 invokes 0x1001a2ab8(grid manager, high-word argument).
- That routine finds a focused grid cell, encodes column * 6 + row in the low byte and effect instance in the high word, then calls 0x1000e7b24 through the editor object at grid-manager +0x148.
- Command 1203 invokes 0x10019d64c(grid manager), also using focused grid-cell state. Deletion semantics and Undo behavior still need confirmation.
- Command 1209 (Insert Shunt) passes 0x400 to 0x1000c37e8, which resolves a free shunt instance and dispatches 2000.
- A3BlockComponent primary vtable 0x1013e9238; row/column at +0x210/+0x214; effect ID at +0x340; command target at +0x388. These offsets are specific to this artifact.
- Accessibility labels originate at 0x1000a3050 and use `Grid row %d column %d: `.

These are static observations, not proof of live edits. The Hopper REA provider timed out during bridge readiness; local llvm-objdump and the existing Mach-O discovery parser supplied these observations.

## Required implementation and acceptance

1. Confirm native single-cell selection without relying on keyboard focus or guessed UI coordinates.
2. Confirm deletion command and Undo behavior on a disposable edit buffer.
3. Add guarded bridge methods and tool schemas for insertion/removal. Require latest context and operation IDs; refuse occupied insertion targets and missing deletion targets.
4. Include all grid cells in inspection and context tokens so topology changes invalidate old requests.
5. Verify the target cell and all unrelated cells after writes. Retain uncertain writes in the operation ledger to prevent replay.
6. Test stale context, invalid IDs, occupied cells, changed preset/scene, Stop, unsupported builds, and idempotent retries.
7. Demonstrate insert -> inspect -> remove -> inspect on the real editor. Never infer device persistence from UI readback.

Adding/removing blocks alone does not establish cable routing or model selection support.

## Implemented candidate

`axefx_add_block` and `axefx_remove_block` use the 1.15.04 dispatcher with executable identity and RTTI checks. Empty cells are inspectable/selectable, topology participates in context tokens, duplicate instances are refused, and readback requires the exact resulting instance ID with unchanged unrelated grid labels. Focus targeting, Undo, and real-device insert/remove restoration remain unverified. No app installation or preset write was performed during implementation.

## Earlier cable routing investigation (superseded)

Historical status before the implementation below: NOT IMPLEMENTED; `routing_edits` remained false.

The 1.15.04 artifact contains distinct CableComponent and JackComponent types. The command dispatcher sends commands 1212/1213 to 0x1000bc928 with operation selectors 4/5. That routine obtains a selected cell through 0x1001a25b4, presents an editor confirmation, and queues a native operation on the editor at +0x6408 (cell at operation +0x104, selector at +0x190). This is insufficient evidence to identify an arbitrary source/destination cable write. It must not be exposed as a connect tool yet.

At that investigation stage, read-side candidate 0x1000e8644 was called by the grid manager with a cell index and two output arrays. Endpoint decoding, ownership, duplicate handling, and the corresponding editor write path were unresolved at that stage; the implementation below resolves the static path. Block labels alone do not verify cables, so routing acceptance needs explicit source/destination readback.

## Cable tools implemented (source, live acceptance pending)

`axefx_connect_blocks` and `axefx_disconnect_blocks` now accept exact inspected occupied source/destination cell labels. They support left-to-right adjacent columns, including different rows; gaps require separate shunts. They do not silently insert blocks, load models, or save presets.

Static evidence for 1.15.04:

- The grid drag code at 0x10019c6e8..0x10019c71c packs an 8-byte record: source cell in byte 0, destination cell in byte 1, operation 1 in upper 32 bits. Cell = column * 6 + row.
- Delete cable 0x10019b998..0x10019ba84 uses the same layout with operation 2.
- Native enqueue at 0x10019ba24 and 0x10019c898 schedules editor operation +0x6918 via 0x1000de450, checks pending at +0x6920, and installs an owned malloc buffer at +0x6a68 with capacity/count at +0x6a70/+0x6a74. Constant 0x10089e030 decodes to capacity 8, count 1.
- Readback matches 0x1000e8644: 84 records at editor +0x3ac, each u16 effect/u16 incoming mask. Mask bits name source rows in the previous column. Snapshot locking uses the native model mutex +0x500 as at 0x1000e839c.

The bridge verifies executable hash, block/command-target/grid RTTI and vtables, a common editor model, occupied adjacent endpoints, and no pending native cable operation. The tool includes the complete cable graph in context tokens and verifies the complete expected graph plus unchanged block grid/preset/scene after each operation. No-op and uncertain results use the same operation ledger. Provider session contract version 5 forces registration of the new tools while retaining the visible transcript.

Authored fixture checks cover connect/disconnect/no-op, gaps, stale routing, replay, dropped writes, unrelated cable changes, Stop after send and preset switches. These checks establish tool behavior, not real editor/device behavior. Hardware persistence, real cable write/readback, Undo and live round-trip restoration remain UNVERIFIED. No updated app installation or live preset mutation was performed for this routing change.
