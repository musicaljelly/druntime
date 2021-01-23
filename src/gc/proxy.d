/**
 * Contains the external GC interface.
 *
 * Copyright: Copyright Digital Mars 2005 - 2016.
 * License:   $(WEB www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Walter Bright, Sean Kelly
 */

/*          Copyright Digital Mars 2005 - 2016.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module gc.proxy;

import gc.impl.conservative.gc;
import gc.impl.manual.gc;
// !!!
import gc.impl.scrapheap.gc;
// !!!
import gc.config;
import gc.gcinterface;

static import core.memory;

private
{
    static import core.memory;
    alias BlkInfo = core.memory.GC.BlkInfo;

    extern (C) void thread_init();
    extern (C) void thread_term();

    __gshared GC proxiedGC; // used to iterate roots of Windows DLLs
    __gshared GC proxiedScrapheap;

    // !!!
    // Stole the name "instance" to refer to the currently set instance. The actual GC instance here is now called "gcInstance"
    __gshared GC gcInstance;
    __gshared GC scrapheapInstance;

    // Used so we can set the proxy before we actually initialize
    __gshared GC pendingProxyGC;
    __gshared GC pendingProxyScrapheap;

    immutable int ALLOCATOR_STACK_SIZE = 128;

    // Note that these are NOT __gshared. This intentionally sits in TLS so that we get one copy per thread.
    // We use GC* here instead of GC so that we can statically initialize instance and allocatorStack.
    // If we weren't able to statically initialize them, we would have some Initialize() function that gets called
    // on each spawned thread to set this up. Which is doubly tricky, because the call has to come from Game.dll, which means
    // static this() won't cut it (since we spawn our threads from main, meaning the static this() call would come from main).
    int allocatorStackTop = 0;
    GC* instance = &gcInstance;
    GC*[ALLOCATOR_STACK_SIZE] allocatorStack = [0:&gcInstance];
    // !!!
}

// NOTE: This whole proxy conceit only works because of polymorphic dispatch.
// The only reason we end up jumping across the DLL boundary from Game -> main is because we look up our function
// in the jump table when trying to decide where our function address is based on the runtime type of 'instance'.
// If you add a call here that doesn't do polymorphic dispatch, it won't work!

extern (C)
{
    void gc_init()
    {
        // !!!
        config.initialize();
        ManualGC.initialize(gcInstance);
        ConservativeGC.initialize(gcInstance);
        ScrapheapGC.initialize(scrapheapInstance);
        if (gcInstance is null)
        {
            import core.stdc.stdio : fprintf, stderr;
            import core.stdc.stdlib : exit;

            fprintf(stderr, "No GC was initialized, please recheck the name of the selected GC ('%.*s').\n", cast(int)config.gc.length, config.gc.ptr);
            exit(1);
        }

        // Briefly set the instance to Game's GC so we can set up roots and ranges.
        // If we have a pending GC proxy, then we'll very quickly get updated to point properly at that
        instance = &gcInstance;

        import rt.memory;
        initStaticDataGC();

        if (pendingProxyGC !is null)
        {
            gc_setProxy(pendingProxyGC, pendingProxyScrapheap);
            pendingProxyGC = null;
            pendingProxyScrapheap = null;
        }

        // NOTE: The GC must initialize the thread library
        //       before its first collection.
        thread_init();
    }

    void gc_term()
    {
        // NOTE: There may be daemons threads still running when this routine is
        //       called.  If so, cleaning memory out from under then is a good
        //       way to make them crash horribly.  This probably doesn't matter
        //       much since the app is supposed to be shutting down anyway, but
        //       I'm disabling cleanup for now until I can think about it some
        //       more.
        //
        // NOTE: Due to popular demand, this has been re-enabled.  It still has
        //       the problems mentioned above though, so I guess we'll see.

        // !!!
        gcInstance.collectNoStack(); // not really a 'collect all' -- still scans
                                    // static data area, roots, and ranges.

        thread_term();

        ManualGC.finalize(gcInstance);
        ConservativeGC.finalize(gcInstance);
        ScrapheapGC.finalize(scrapheapInstance);
        // !!!
    }

    void gc_enable()
    {
        instance.enable();
    }

    void gc_disable()
    {
        instance.disable();
    }

    void gc_collect() nothrow
    {
        instance.collect();
    }

    void gc_minimize() nothrow
    {
        instance.minimize();
    }

    uint gc_getAttr( void* p ) nothrow
    {
        return instance.getAttr(p);
    }

    uint gc_setAttr( void* p, uint a ) nothrow
    {
        return instance.setAttr(p, a);
    }

    uint gc_clrAttr( void* p, uint a ) nothrow
    {
        return instance.clrAttr(p, a);
    }

    void* gc_malloc( size_t sz, uint ba = 0, const TypeInfo ti = null ) nothrow
    {
        return instance.malloc(sz, ba, ti);
    }

    BlkInfo gc_qalloc( size_t sz, uint ba = 0, const TypeInfo ti = null ) nothrow
    {
        return instance.qalloc( sz, ba, ti );
    }

    void* gc_calloc( size_t sz, uint ba = 0, const TypeInfo ti = null ) nothrow
    {
        return instance.calloc( sz, ba, ti );
    }

    void* gc_realloc( void* p, size_t sz, uint ba = 0, const TypeInfo ti = null ) nothrow
    {
        return instance.realloc( p, sz, ba, ti );
    }

    size_t gc_extend( void* p, size_t mx, size_t sz, const TypeInfo ti = null ) nothrow
    {
        return instance.extend( p, mx, sz,ti );
    }

    size_t gc_reserve( size_t sz ) nothrow
    {
        return instance.reserve( sz );
    }

    void gc_free( void* p ) nothrow @nogc
    {
        return instance.free( p );
    }

    void* gc_addrOf( void* p ) nothrow @nogc
    {
        return instance.addrOf( p );
    }

    size_t gc_sizeOf( void* p ) nothrow @nogc
    {
        return instance.sizeOf( p );
    }

    BlkInfo gc_query( void* p ) nothrow
    {
        return instance.query( p );
    }

    core.memory.GC.Stats gc_stats() nothrow
    {
        return instance.stats();
    }

    void gc_addRoot( void* p ) nothrow
    {
        // Always use GC instance for addRoot, addRange etc.
        // druntime/phobos code sometimes adds roots and ranges at unexpected times, for example, in the phobos Array implementation.
        // We want this to work even if we're inside a scrapheap section.
        return gcInstance.addRoot( p );
    }

    void gc_addRange( void* p, size_t sz, const TypeInfo ti = null ) nothrow
    {
        return gcInstance.addRange( p, sz, ti );
    }

    void gc_removeRoot( void* p ) nothrow
    {
        return gcInstance.removeRoot( p );
    }

    void gc_removeRange( void* p ) nothrow
    {
        return gcInstance.removeRange( p );
    }

    void gc_runFinalizers( in void[] segment ) nothrow
    {
        return instance.runFinalizers( segment );
    }

    bool gc_inFinalizer() nothrow
    {
        return instance.inFinalizer();
    }

    // !!!
    // gc_getProxy() should always return the GC, even if the GC is not the current allocator
    GC gc_getProxy() nothrow
    {
        return gcInstance;
    }

    GC gc_getScrapheap() nothrow
    {
        return scrapheapInstance;
    }
    // !!!

    export
    {
        // !!!
        void gc_setProxy(GC gcProxyToSet, GC scrapheapProxyToSet)
        {
            if (gcInstance is null)
            {
                // We haven't initialized yet. Just keep track of the proxies we'd like to use for now, then actually call
                // gc_setProxy() again from gc_init()
                pendingProxyGC = gcProxyToSet;
                pendingProxyScrapheap = scrapheapProxyToSet;
            }
            else
            {
                foreach(root; gcInstance.rootIter)
                {
                    gcProxyToSet.addRoot(root);
                }

                foreach(range; gcInstance.rangeIter)
                {
                    gcProxyToSet.addRange(range.pbot, range.ptop - range.pbot, range.ti);
                }

                proxiedGC = gcInstance; // remember initial GCs to later remove roots
                proxiedScrapheap = scrapheapInstance;

                gcInstance = gcProxyToSet;
                scrapheapInstance = scrapheapProxyToSet;
            }
        }
        // !!!

        void gc_clrProxy()
        {
            // !!!
            foreach(root; proxiedGC.rootIter)
            {
                gcInstance.removeRoot(root);
            }

            foreach(range; proxiedGC.rangeIter)
            {
                gcInstance.removeRange(range);
            }

            gcInstance = proxiedGC;
            scrapheapInstance = proxiedScrapheap;

            // At this point we should be all the way at the bottom of the allocator stack, and our current allocator should be
            // the GC. So update the instance to the stored GC so we don't collect from main's GC while we tear down the DLL.
            instance = &proxiedGC;

            proxiedGC = null;
            proxiedScrapheap = null;
            // !!!
        }
    }

    // !!!
    // Call this once on each thread you want a scrapheap for, including the main thread.
    void InitScrapheapOnThisThread(size_t scrapheapSize)
    {
        // Force polymorphic dispatch to happen so we look up the function address in the jump table and end up jumping across the
        // DLL boundary.
        (cast(GC)scrapheapInstance).initializeScrapheapOnThisThread(scrapheapSize);
    }

    void ResetScrapheap()
    {
        (cast(GC)scrapheapInstance).reset();
    }

    size_t GetScrapheapHighWatermark()
    {
        return (cast(GC)scrapheapInstance).getHighWatermark();
    }

    void PushScrapheap()
    {
        debug (GameDebug) if (scrapheapInstance is null)
        {
            import core.stdc.stdio : printf;
            printf("We tried to switch to the scrapheap allocator before we've initialized it");
            asm {int 3;}
        }

        PushAllocator(&scrapheapInstance);
    }

    void PushGC()
    {
        PushAllocator(&gcInstance);
    }

    void PopAllocator()
    {
        allocatorStackTop--;
        debug (GameDebug) if (allocatorStackTop < 0)
        {
            import core.stdc.stdio : printf;
            printf("We blew the allocator stack");
            asm {int 3;}
        }
        instance = allocatorStack[allocatorStackTop];
    }

    void StartScrapheapTempRegion()
    {
        (cast(GC)scrapheapInstance).startTempRegion();
    }

    void EndScrapheapTempRegion()
    {
        (cast(GC)scrapheapInstance).endTempRegion();
    }

    private
    {
        void PushAllocator(GC* gc)
        {
            allocatorStackTop++;
            debug (GameDebug) if (allocatorStackTop >= ALLOCATOR_STACK_SIZE)
            {
                import core.stdc.stdio : printf;
                printf("We popped more off the allocator stack than we pushed");
                asm {int 3;}
            }
            allocatorStack[allocatorStackTop] = gc;
            instance = gc;
        }
    }
    // !!!
}
