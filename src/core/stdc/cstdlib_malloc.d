// !!!
// This file is added as part of The Tallest Tower.
// It exists so we can intercept calls to malloc in stdlib.d, and redirect them across the DLL boundary if needed.

module core.stdc.cstdlib_malloc;

extern(C):
nothrow:
static:
@nogc:

void* malloc(size_t size);
void* calloc(size_t nmemb, size_t size);
void* realloc(void* ptr, size_t size);
void free(void* ptr);
// !!!
