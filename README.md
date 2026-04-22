# Wavefront

SPMD-style wavefront/lane threading module. All threads in a wavefront execute the same entry function, differentiated by a lane index. No task queue, no work stealing scheduler — just a shared barrier and broadcast primitives.

Design originally by Ryan Fleury. This repo is simply an implementation of that design in Jai. 
See his great blog post about it: https://www.dgtlgrove.com/p/multi-core-by-default

## Usage

`context.wave_info` is injected automatically via `#add_context`.

## Lifecycle

```jai
wf: Wavefront;
threads := wavefront_init(*wf, my_lane_entry, num_lanes);
for * threads { thread_start(it); }

// ... later ...
wavefront_stop(*wf, threads);
```

Each thread's `context.wave_info.lane_index` is set to `0..num_lanes-1`.

## Lane Primitives

| Procedure | Description |
|---|---|
| `lane_index() -> s64` | This thread's lane `[0, N)` |
| `lane_leader() -> bool` | `true` for lane 0 |
| `lane_count() -> s64` | Total lanes in wavefront |
| `lane_sync()` | Barrier — all lanes must arrive before any proceed |
| `lane_sync_broadcast(ptr, src_lane)` | Barrier + copy up to 8 bytes from `src_lane` to all others |
| `lane_sync_load(ptr, lane) -> bool` | Convenience: broadcast + load |
| `lane_range(count) -> (start, end)` | Contiguous `[start, end]` range for this lane's portion of `count` items |

## Work Distribution

**Static partitioning** — split N items across lanes:
```jai
lo, hi := lane_range(items.count);
for lo..hi { process(items[it]); }
```

**Leader-gate** — run once, broadcast result:
```jai
value: My_Struct;
if lane_leader() { value = compute_once(); }
lane_sync_broadcast(*value, 0);
// all lanes now have value
```

**Lane splitting** — split wavefront into two independent sub-wavefronts.
Note that while operating a sub-wavefronts, all lane_sync/lane_leader functions will continue to work within their individual contexts. Both branches have independent execution until they complete the block.
```jai
for lane_split.(num = 2) {
    if it == 0 {
        // first set of lanes (0..1) run this block
    }
    if it == 1 { 
        // the rest of the lanes run this block
    }
}
// back to full wavefront, auto-synced.
```

**Leader scope** — execute block on lane 0 only:
```jai
for leader.{sync = true} {
    // lane 0 only
}
// optional sync controls whether lane_sync() runs on scope exit
```

## Synchronization Primitives (sync.jai)

| Type | API |
|---|---|
| `Barrier` | `barrier_init`, `barrier_release`, `barrier_wait` |

`Barrier` uses a spin-then-fallback strategy with configurable spin counter (custom Mutex + Condition Variable) by default. Set `USE_OS_BARRIER` to use platform-native barriers instead. 


## Module Parameters

| Parameter        | Default | Description |
|------------------|---------|-------------|
| CHECK_DIVERGENCE | false   | Validate all lanes hit the same sync point. Very useful for debugging things like non-uniform branching. Adds a large overhead to each sync so only use for debugging. |
| USE_OS_BARRIER   | false   | Use OS-native barriers instead of custom barrier implementation |


## File Structure

```
modules/wavefront/
- module.jai   # Types, lane primitives, lifecycle, loads, imports
- sync.jai     # Barrier + platform-specific imports
```
