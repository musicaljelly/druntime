// !!!
// This entire file was added for the game

module gc.impl.scrapheap.gc;

import gc.config;
import gc.gcinterface;

import rt.util.container.array;

import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
import core.stdc.string : memset, memcpy;
static import core.memory;
import core.atomic : atomicOp;

extern (C) void onOutOfMemoryError(void* pretend_sideffect = null) @trusted pure nothrow @nogc; /* dmd @@@BUG11461@@@ */

struct Heap
{
    void* base = null;
    void* top = null;
    size_t size = 0;

    void Init(size_t heapSize) nothrow
    {
        base = cstdlib.malloc(heapSize);
        top = base;
        size = heapSize;

        debug (GameDebug) memset(base, 0xba, heapSize);
    }

    void Destroy() nothrow
    {
        cstdlib.free(base);

        base = null;
        top = null;
        size = 0;
    }
}

import core.thread : ThreadID;
// Reimplementing std.process.thisThreadID() because it's in phobos and we don't have access to it
ThreadID GetCurrentThreadID() nothrow
{
    ThreadID threadID;
    version (Windows)
    {
        import core.sys.windows.windows;
        threadID = GetCurrentThreadId();
    }
    else version (Posix)
    {
        import core.sys.posix.pthread : pthread_self;
        threadID = pthread_self();
    }

    return threadID;
}

class ScrapheapGC : GC
{
    __gshared Array!Root roots;
    __gshared Array!Range ranges;

    __gshared bool isInitialized = false;

    immutable int NUM_TLS_HEAPS = 16;

    // Static so they can be thread-local
    static Heap[NUM_TLS_HEAPS] tls_heaps;
    static int tls_heapIndex = 0;
    static void* tls_tempRegionBottom = null;
    static size_t tls_highWatermark = 0;
    static size_t tls_highWatermarkThisFrame = 0;

    static void initialize(ref GC gc)
    {
        if (!isInitialized)
        {
            auto p = cstdlib.malloc(__traits(classInstanceSize, ScrapheapGC));
            if (!p)
                onOutOfMemoryError();

            auto init = typeid(ScrapheapGC).initializer();
            assert(init.length == __traits(classInstanceSize, ScrapheapGC));
            auto instance = cast(ScrapheapGC) memcpy(p, init.ptr, init.length);
            instance.__ctor();

            gc = instance;
            isInitialized = true;
        }
    }

    static void finalize(ref GC gc)
    {
        // When this runs we're killing the game anyway, no need to bother freeing scrapheap memory.
        auto instance = cast(ScrapheapGC) gc;
        instance.Dtor();
        cstdlib.free(cast(void*) instance);
    }

    void initializeScrapheapOnThisThread(size_t initScrapheapSize) nothrow
    {
        tls_heaps[0].Init(initScrapheapSize);
    }

    this()
    {
    }

    void Dtor()
    {
    }

    void enable()
    {
    }

    void disable()
    {
    }

    void collect() nothrow
    {
    }

    void collectNoStack() nothrow
    {
    }

    void minimize() nothrow
    {
    }

    uint getAttr(void* p) nothrow
    {
        return 0;
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        return 0;
    }

    uint clrAttr(void* p, uint mask) nothrow
    {
        return 0;
    }

    void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        import core.stdc.stdio : printf;

        version (none)
        {
            printf("------------------------------------\n");
            printf("Malloc on thread %u\n", GetCurrentThreadID());
            printf("Heap index: %d\n", tls_heapIndex);
            printf("Heap base: %zx\n", tls_heaps[tls_heapIndex].base);
            printf("Heap top: %zx\n", tls_heaps[tls_heapIndex].top);
            printf("Heap size: %zx\n", tls_heaps[tls_heapIndex].size);
        }

        // Round up to the nearest size_t.sizeof (4) bytes so that we're 4-bytes aligned and don't store pointers in a way that
        // might confuse the garbage collector.
        size_t sizeAligned = size + size_t.sizeof - 1 - ((size - 1) % size_t.sizeof);

        Heap* curHeap = &tls_heaps[tls_heapIndex];
        while ((curHeap.top - curHeap.base) + sizeAligned > curHeap.size)
        {
            // We're about to blow the heap. Log it, then do a poor man's assert if we're in debug.
            printf("We blew the scrapheap on thread %u. Now switching to heap index %d.\n", GetCurrentThreadID(), tls_heapIndex + 1);
            debug (GameDebug) asm nothrow {int 3;}

            if (tls_heapIndex + 1 >= NUM_TLS_HEAPS)
            {
                printf("We ran out of scrapheap heaps on thread %u. This is a fatal error.", GetCurrentThreadID());
                debug (GameDebug) asm nothrow {int 3;}
                return null;
            }

            // Create a new heap and allocate into that instead.
            // Next time we reset we'll conglomerate all the heaps.
            tls_heapIndex++;
            tls_heaps[tls_heapIndex].Init(curHeap.size * 2);
            curHeap = &tls_heaps[tls_heapIndex];

            // If we allocated a new heap, the temp region reset point gets bumped up to the start of the new heap
            tls_tempRegionBottom = tls_heaps[tls_heapIndex].base;
        }

        // Each scrapheap is thread-local, so no need for atomic ops or anything, plain old addition is fine.
        size_t finalSize = size_t.sizeof + sizeAligned;
        void* newHeapTop = cast(void*)curHeap.top += finalSize;
        tls_highWatermarkThisFrame += finalSize;

        // Inscribe the size of the allocation just before the start pointer, that way we can make informed decisions if someone
        // calls realloc.
        size_t* p = cast(size_t*)(newHeapTop - finalSize);
        *p = sizeAligned;

        return p + 1;
    }

    BlkInfo qalloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        BlkInfo retval;
        retval.base = malloc(size, bits, ti);
        retval.size = size;
        retval.attr = bits;
        return retval;
    }

    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        void* p = malloc(size, bits, ti);
        memset(p, 0, size);
        return p;
    }

    void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        size_t oldSize = *(cast(size_t*)p - 1);

        if (oldSize <= size)
        {
            return p;
        }

        void* newP = malloc(size, bits, ti);
        memcpy(newP, p, oldSize);
        return newP;
    }

    void reset() nothrow
    {
        if (tls_heapIndex > 0)
        {
            // We blew the heap this frame, so conglomerate all heaps into one
            size_t totalSize = 0;
            for (int i = 0; i <= tls_heapIndex; i++)
            {
                totalSize += tls_heaps[i].size;
                tls_heaps[i].Destroy();
            }

            tls_heaps[0].Init(totalSize);
            tls_heapIndex = 0;
        }
        else
        {
            // All is normal, just do a normal scrapheap reset.
            debug (GameDebug) memset(tls_heaps[0].base, 0xba, tls_heaps[0].top - tls_heaps[0].base);
            tls_heaps[0].top = tls_heaps[0].base;
        }

        if (tls_highWatermarkThisFrame > tls_highWatermark)
        {
            tls_highWatermark = tls_highWatermarkThisFrame;
        }
        tls_highWatermarkThisFrame = 0;
    }

    size_t getHighWatermark() nothrow
    {
        return tls_highWatermarkThisFrame > tls_highWatermark ? tls_highWatermarkThisFrame : tls_highWatermark;
    }

    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        return 0;
    }

    size_t reserve(size_t size) nothrow
    {
        return 0;
    }

    void free(void* p) nothrow
    {
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    void* addrOf(void* p) nothrow
    {
        return null;
    }

    /**
     * Determine the allocated size of pointer p.  If p is an interior pointer
     * or not a gc allocated pointer, return 0.
     */
    size_t sizeOf(void* p) nothrow
    {
        return 0;
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    BlkInfo query(void* p) nothrow
    {
        return BlkInfo.init;
    }

    core.memory.GC.Stats stats() nothrow
    {
        return typeof(return).init;
    }

    void addRoot(void* p) nothrow @nogc
    {
        assert(false);
    }

    void removeRoot(void* p) nothrow @nogc
    {
        assert(false);
    }

    @property RootIterator rootIter() @nogc
    {
        assert(false);
    }

    private int rootsApply(scope int delegate(ref Root) nothrow dg)
    {
        assert(false);
    }

    void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow @nogc
    {
        assert(false);
    }

    void removeRange(void* p) nothrow @nogc
    {
        assert(false);
    }

    @property RangeIterator rangeIter() @nogc
    {
        assert(false);
    }

    private int rangesApply(scope int delegate(ref Range) nothrow dg)
    {
        assert(false);
    }

    void runFinalizers(in void[] segment) nothrow
    {
    }

    bool inFinalizer() nothrow
    {
        return false;
    }

    void startTempRegion() nothrow
    {
        debug (GameDebug) if (tls_tempRegionBottom !is null)
        {
            import core.stdc.stdio : printf;
            printf("Tried to start a scrapheap temp region when one was already in progress");
            asm nothrow {int 3;}
        }

        tls_tempRegionBottom = tls_heaps[tls_heapIndex].top;
    }

    void endTempRegion() nothrow
    {
        debug (GameDebug) if (tls_tempRegionBottom is null)
        {
            import core.stdc.stdio : printf;
            printf("Tried to end a scrapheap temp region when one wasn't in progress");
            asm nothrow {int 3;}
        }

        tls_heaps[tls_heapIndex].top = tls_tempRegionBottom;
        tls_tempRegionBottom = null;
    }
}
// !!!
