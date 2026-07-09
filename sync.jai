BARRIER_SPIN_COUNT :: 8 * 1024;

#if !USE_OS_BARRIER {
    Barrier :: struct {
        num_threads:   s32;
        count:         s32 #align 64;
        generation_id: s32 #align 64;
        mutex:         Mutex;
        cvar:          Condition_Variable;
    }

    barrier_init :: (barrier: *Barrier, count: s32) {
        barrier.num_threads   = count;
        barrier.count         = 0;
        barrier.generation_id = 0;
        init(*barrier.mutex);
        init(*barrier.cvar);
    }

    barrier_release :: (barrier: *Barrier) {
        destroy(*barrier.cvar);
        destroy(*barrier.mutex);
    }

    barrier_wait :: (barrier: *Barrier) {
        if barrier.num_threads <= 1 then return;

        #if CPU == .X64 {
            #asm { mfence; }
        } else #if CPU == .ARM64 {
            // The data memory barrier ensures that all preceding writes are issued before any subsequent memory
            // operations (including speculative memory access). In acquire/release terms, it is a full barrier. The
            // instruction does not stall execution; it just tells the memory controller to preserve externally-visible
            // ordering. - https://devblogs.microsoft.com/oldnewthing/20220812-00/?p=106968
            #bytes .[0xBF, 0x3B, 0x03, 0xD5]; // dmb ish; data memory barrier
        } else {
            #assert("Unsupported CPU");
        }

        local_gen := atomic_read(*barrier.generation_id);
        if atomic_add(*barrier.count, 1) + 1 < barrier.num_threads {
            for 0..BARRIER_SPIN_COUNT-1 {
                if atomic_read(*barrier.generation_id) != local_gen return;

                #if CPU == .X64 {
                    #asm { pause; }
                } else #if CPU == .ARM64 {
                    // arm64 equivlent of x86's pause
                    #bytes .[0x3F, 0x20, 0x03, 0xD5]; // YIELD
                } else {
                    #assert("Unsupported CPU");
                }
            }
            lock(*barrier.mutex);
            while atomic_read(*barrier.generation_id) == local_gen {
                wait(*barrier.cvar, *barrier.mutex);
            }
            unlock(*barrier.mutex);
        } else {
            lock(*barrier.mutex);
            atomic_write(*barrier.count, 0);
            atomic_add(*barrier.generation_id, 1);
            wake_all(*barrier.cvar);
            unlock(*barrier.mutex);
        }
    }
} else {
    #if OS == .WINDOWS {
        Barrier :: struct {
            platform_specific: SYNCHRONIZATION_BARRIER;
            num_threads: s32;
        }

        barrier_init :: (barrier: *Barrier, count: s32) {
            v := InitializeSynchronizationBarrier(*barrier.platform_specific, count, BARRIER_SPIN_COUNT);
            barrier.num_threads = count;
        }

        barrier_release :: (barrier: *Barrier) {
            if barrier.num_threads <= 1 then return;
            v := DeleteSynchronizationBarrier(*barrier.platform_specific);
        }

        barrier_wait :: (barrier: *Barrier) {
            NO_DELETE_FLAG : u32 : 0x4;
            v := EnterSynchronizationBarrier(*barrier.platform_specific, NO_DELETE_FLAG);
        }

        ULONG_PTR :: u64;
        LONG :: s32;

        SYNCHRONIZATION_BARRIER :: struct {
            Reserved1: Windows.DWORD;
            Reserved2: Windows.DWORD;
            Reserved3: [2] ULONG_PTR;
            Reserved4: Windows.DWORD;
            Reserved5: Windows.DWORD;
        }


        #scope_file
        Windows :: #import "Windows";
        kernel32 :: #library,system "kernel32";

        InitializeSynchronizationBarrier :: (lpBarrier: *SYNCHRONIZATION_BARRIER, lTotalThreads: LONG, lSpinCount: LONG) -> Windows.BOOL #foreign kernel32;
        DeleteSynchronizationBarrier :: (lpBarrier: *SYNCHRONIZATION_BARRIER) -> Windows.BOOL #foreign kernel32;
        EnterSynchronizationBarrier :: (lpBarrier: *SYNCHRONIZATION_BARRIER, dwFlags: Windows.DWORD) -> Windows.BOOL #foreign kernel32;
    } else #if OS == .MACOS {
        #assert(false, "macos doesn't support OS barriers, consider setting jai-wavefront's module parameter USE_OS_BARRIER to false");
    } else {
        #import "POSIX";

        Barrier :: pthread_barrier_t;

        barrier_init :: (barrier: *Barrier, count: s32) {
            pthread_barrier_init(barrier, null, cast(u32) count);
        }

        barrier_release :: (barrier: *Barrier) {
            if barrier != null {
                pthread_barrier_destroy(barrier);
            }
        }

        barrier_wait :: (barrier: *Barrier) {
            if barrier != null {
                pthread_barrier_wait(barrier);
            }
        }
    }
}

