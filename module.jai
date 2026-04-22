#module_parameters(
    CHECK_DIVERGENCE := false,
    USE_OS_BARRIER   := false
);

Wavefront :: struct {
    barrier: Barrier;
    count: s64;
    broadcast_data: [8] u8;

    #if CHECK_DIVERGENCE {
        sync_locations: [] Source_Code_Location;
    }
}

Wave_Info :: struct {
    wavefront: *Wavefront;
    lane_index: s32;
}

#add_context wave_info: Wave_Info;

lane_index :: () -> s64 {
    return context.wave_info.lane_index;
}

lane_leader :: () -> bool {
    return lane_index() == 0;
}

lane_count :: () -> s64 {
    return cast(s64) context.wave_info.wavefront.count;
}

lane_sync :: (caller_loc := #caller_location) #expand {
    lane_sync_broadcast(ptr = null, src_lane_index = 0, caller_loc = caller_loc);
}

lane_sync_load :: (value_ptr: *$T, lane: s32 = 0, caller_loc := #caller_location) -> bool #expand {
    value := value_ptr.*;
    lane_sync_broadcast(*value, lane, caller_loc);
    return value;
}

lane_sync_broadcast :: (ptr: *$T, src_lane_index: s32, caller_loc := #caller_location) #expand #no_debug {
    #assert(size_of(T) <= 8 && "Cannot broadcast values larger than 8 bytes");

    if ptr != null && lane_index() == src_lane_index {
        memcpy(*context.wave_info.wavefront.broadcast_data, ptr, size_of(T));
    }

    #if CHECK_DIVERGENCE {
        context.wave_info.wavefront.sync_locations[lane_index()] = caller_loc;
    }

    barrier_wait(*context.wave_info.wavefront.barrier);

    #if CHECK_DIVERGENCE {
        for context.wave_info.wavefront.sync_locations {
            if caller_loc.fully_pathed_filename != it.fully_pathed_filename
                || caller_loc.line_number != it.line_number {

                ensure(false, "Threads diverged\n Lane %: %:%\n Lane %: %:%",
                    lane_index(), caller_loc.fully_pathed_filename, caller_loc.line_number,
                    it_index, it.fully_pathed_filename, it.line_number
                );
            }
        }

        barrier_wait(*context.wave_info.wavefront.barrier);
    }


    if ptr != null && lane_index() != src_lane_index {
        memcpy(ptr, *context.wave_info.wavefront.broadcast_data, size_of(T));
    }

    if ptr {
        barrier_wait(*context.wave_info.wavefront.barrier);
    }
}

lane_range :: (count: s64) -> (start: s64, end: s64) {
    n_idx   := lane_index();
    n_count := lane_count();
    m_count := count;

    main_idxes_per_lane                   := m_count / n_count;
    leftover_idxes_count                  := m_count - main_idxes_per_lane * n_count;
    leftover_idxes_before_this_lane_count := min(n_idx, leftover_idxes_count);
    lane_base_idx                         := n_idx * main_idxes_per_lane + leftover_idxes_before_this_lane_count;
    lane_base_idx_clamped                 := min(lane_base_idx, m_count);
    lane_opl_idx                          := lane_base_idx_clamped + main_idxes_per_lane + (ifx n_idx < leftover_idxes_count then 1 else 0);
    lane_opl_idx_clamped                  := min(lane_opl_idx, m_count);

    lo := lane_base_idx_clamped;
    hi := lane_opl_idx_clamped - 1;

    return lo, hi;
}

lane_split :: struct {
    num: s32;
}

for_expansion :: (split: lane_split, body: Code, flags: For_Flags) #expand {
    num := split.num;
    second_count := cast(s32) lane_count() - num;

    `it: s32 = ---;
    `it_index: s32 = ---;
    sub_lane_index: s32;
    if lane_index() < num {
        `it = 0;
        sub_lane_index = cast(s32) lane_index();
    } else {
        `it = 1;
        sub_lane_index = cast(s32) (lane_index() - num);
    }

    sub_wavefronts: [2] Wavefront;
    if lane_leader() {
        sub_wavefronts[0].count = num;
        barrier_init(*sub_wavefronts[0].barrier, num);
        sub_wavefronts[1].count = second_count;
        barrier_init(*sub_wavefronts[1].barrier, second_count);

        #if CHECK_DIVERGENCE {
            sub_wavefronts[0].sync_locations = NewArray(num, Source_Code_Location,, temp);
            sub_wavefronts[1].sync_locations = NewArray(second_count, Source_Code_Location,, temp);
        }
    }

    sub_wf_ptr: *[2] Wavefront;
    if lane_leader() { sub_wf_ptr = *sub_wavefronts; }
    lane_sync_broadcast(*sub_wf_ptr, 0);

    old_wave_info := context.wave_info;
    context.wave_info.wavefront = *(sub_wf_ptr.*)[`it];
    context.wave_info.lane_index = sub_lane_index;

    #insert body;

    context.wave_info = old_wave_info;
    lane_sync();

    if lane_leader() {
        barrier_release(*(sub_wf_ptr.*)[0].barrier);
        barrier_release(*(sub_wf_ptr.*)[1].barrier);
    }
}

leader :: struct($sync: bool = true) { };

for_expansion :: (info: leader, body: Code, flags: For_Flags) #expand {
    `it: s32 = ---;
    `it_index: s32 = ---;

    if lane_leader () {
        old_wavefront := context.wave_info.wavefront;

        wavefront := Wavefront.{count = 1};

        #if CHECK_DIVERGENCE {
            wavefront.sync_locations = NewArray(1, Source_Code_Location,, temp);
        }

        context.wave_info.wavefront = *wavefront;

        #insert body;

        context.wave_info.wavefront = old_wavefront;
    }
    #if info.sync lane_sync();
}

wavefront_init :: (wavefront: *Wavefront, lane_proc: Thread_Proc, num_lanes: s32) -> [..] Thread {
    wavefront.count = num_lanes;
    barrier_init(*wavefront.barrier, num_lanes);

    threads: [..] Thread;
    array_resize(*threads, num_lanes);

    #if CHECK_DIVERGENCE {
        wavefront.sync_locations = NewArray(num_lanes, Source_Code_Location);
    }

    wave_info: Wave_Info;
    wave_info.wavefront = wavefront;

    for * thread : threads {
        thread_init(thread, lane_proc);
        thread.starting_context.wave_info = wave_info;
        thread.starting_context.wave_info.lane_index = cast(s32) it_index;
    }
    return threads;
}

wavefront_stop :: (using wavefront: *Wavefront, threads: [] Thread, force: bool = false) {
    for * threads {
        if force then thread_is_done(it, -1);
        thread_deinit(it);
    }
    barrier_release(*wavefront.barrier);
    array_free(threads);
}

#load "sync.jai";

#import "Thread";
#import "Basic";
#import "Atomics";
