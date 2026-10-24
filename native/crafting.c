/* Warden 1.2.0: material-only fabrication, TLC 0.10.0.653173 x64.
 * Loaded by UE4SS Lua package.loadlib. No BepInEx, injection into other processes,
 * disk executable changes, recipe asset changes, or Lua calls from native hooks.
 * See validation/crafting-native-1.1.1.md for the inspected native call graph.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include "third_party/minhook/include/MinHook.h"

typedef struct {
    void *data;
    int32_t num, capacity;
    uint32_t inline_bits[4];
    uint32_t *heap_bits;
    int32_t bit_count, bit_capacity, first_free, num_free;
    int32_t inline_hash, pad;
    void *hash;
    int32_t hash_size, pad2;
} ItemMap;
typedef struct { void *item; int32_t amount, padding, hash_next, hash_index; } ItemPair;
typedef struct {
    ItemMap required, materials, total, local;
    float total_time, time;
} Cost;
_Static_assert(sizeof(ItemMap) == 0x50, "Wrong TMap ABI");
_Static_assert(sizeof(ItemPair) == 24, "Wrong element ABI");
_Static_assert(offsetof(ItemMap, heap_bits) == 0x20, "Wrong bit-array ABI");
_Static_assert(offsetof(Cost, total_time) == 0x140, "Wrong cost result ABI");
_Static_assert(sizeof(Cost) == 0x148, "Wrong result size");

typedef bool (*CanFn)(void *fabricator, void *item, void *inventories, int32_t count, bool components);
typedef bool (*CostFn)(void *fabricator, void *item, Cost *result, void *inventories, int32_t count);
static CanFn original_can;
static CostFn original_cost;
static volatile LONG active = 0, fault = 0;
static bool initialized = false;
static uintptr_t image_base;
#ifdef WARDEN_TEST
static uintptr_t test_cost_caller = 0x54f7845;
#endif

static bool material_cost_caller(uintptr_t caller_rva) {
    // The SAME calculator is also used at production FINISH to settle already
    // reserved materials. Leave that caller (0x5506a13) fully vanilla, otherwise
    // paid reservations could survive completion and be refunded twice later.
    switch (caller_rva) {
        case 0x54f7845: // queue admission / initial reservation
        case 0x54ff9bc: // public calculation wrapper + production-start check
        case 0x550ea1b: // missing materials for queued entries
            return true;
        // 0x57d8e7b is the player's crafting LIST calculation, not a debit.
        // Its consumer divides by MaterialsRequired quantities at 0x57d90f0.
        // Preserve those positive divisors even while production is free.
        default: return false;
    }
}

static bool map_valid(const ItemMap *m) {
    return m->num >= 0 && m->num <= 1048576 && m->capacity >= m->num
        && m->bit_count == m->num && m->bit_capacity >= m->bit_count
        && m->num_free >= 0 && m->num_free <= m->num
        && (!m->num || m->data) && (m->bit_count <= 128 || m->heap_bits);
}
static void zero_map(ItemMap *m) {
    const uint32_t *bits = m->heap_bits ? m->heap_bits : m->inline_bits;
    ItemPair *pairs = (ItemPair *)m->data;
    for (int32_t i = 0; i < m->num; ++i)
        if (bits[i >> 5] & (1u << (i & 31))) pairs[i].amount = 0;
}
static bool zero_cost(Cost *cost) {
    // Validate BOTH maps before touching either one. No allocation/free/rehash.
    if (!cost || !map_valid(&cost->required) || !map_valid(&cost->materials)) return false;
    zero_map(&cost->required);
    zero_map(&cost->materials);
    // Time, local/total counts, recipe pointers, hash chains and keys stay intact.
    return true;
}
static bool can_hook(void *f, void *item, void *inventories, int32_t count, bool components) {
    // Preserve native unlock, inventory, null and empty-recipe checks.
    // No unconditional true, no global inventory-count spoofing.
    if (InterlockedCompareExchange(&active, 0, 0) && count > 0) count = 0;
    return original_can(f, item, inventories, count, components);
}
static bool cost_hook(void *f, void *item, Cost *result, void *inventories, int32_t count) {
#ifdef WARDEN_TEST
    const uintptr_t caller = test_cost_caller;
#else
    const uintptr_t caller = (uintptr_t)__builtin_return_address(0) - image_base;
#endif
    const bool free_materials = InterlockedCompareExchange(&active, 0, 0)
        && count > 0 && material_cost_caller(caller);
    const bool ok = original_cost(f, item, result, inventories, count);
    // This is a per-call FABRICATOR calculation result, never UVoyageItem.Components.
    // Both initial reservation and production-start rechecking use this function.
    if (ok && free_materials && !zero_cost(result)) {
        InterlockedExchange(&active, 0);
        InterlockedExchange(&fault, 1);
    }
    return ok;
}

#ifndef WARDEN_TEST
static const unsigned char expected_sha[32] = {
    0x08,0x22,0x8b,0x72,0xd4,0x59,0x0f,0x9b,0x00,0xe2,0x17,0x1f,0x25,0x2d,0x61,0x84,
    0x64,0xc2,0xe0,0x4b,0x78,0x52,0x37,0xfe,0x72,0x8d,0xdd,0xbf,0x27,0xd3,0xb7,0x34
};
static const unsigned char can_prefix[16] = {
    0x44,0x89,0x4c,0x24,0x20,0x55,0x53,0x41,0x54,0x41,0x56,0x48,0x8d,0x6c,0x24,0xc9
};
static const unsigned char cost_prefix[16] = {
    0x40,0x55,0x53,0x56,0x41,0x54,0x41,0x56,0x41,0x57,0x48,0x8d,0xac,0x24,0x68,0xfd
};
static bool supported_executable(void) {
    wchar_t path[32768];
    DWORD length = GetModuleFileNameW(NULL, path, 32768);
    if (!length || length >= 32768) return false;
    const wchar_t *name = wcsrchr(path, L'\\');
    if (!name || _wcsicmp(name + 1, L"VoyageSteam-Win64-Shipping.exe")) return false;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              NULL, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) return false;
    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    unsigned char digest[32], buffer[65536];
    bool ok = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) >= 0;
    if (ok) ok = BCryptCreateHash(alg, &hash, NULL, 0, NULL, 0, 0) >= 0;
    DWORD read = 0;
    while (ok) {
        if (!ReadFile(file, buffer, sizeof(buffer), &read, NULL)) { ok = false; break; }
        if (!read) break;
        ok = BCryptHashData(hash, buffer, read, 0) >= 0;
    }
    if (ok) ok = BCryptFinishHash(hash, digest, sizeof(digest), 0) >= 0 && !memcmp(digest, expected_sha, 32);
    if (hash) BCryptDestroyHash(hash);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    CloseHandle(file);
    return ok;
}
static bool initialize(void) {
    if (initialized) return true;
    if (!supported_executable()) return false;
    unsigned char *base = (unsigned char *)GetModuleHandleW(NULL);
    image_base = (uintptr_t)base;
    void *can = base + 0x55012a0, *cost = base + 0x54fee80;
    if (memcmp(can, can_prefix, 16) || memcmp(cost, cost_prefix, 16)) return false;
    // Lua unloading/reloading must never unload code still used by native hooks.
    HMODULE self;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                           (LPCWSTR)(uintptr_t)&initialize, &self)) return false;
    if (MH_Initialize() != MH_OK) return false;
    if (MH_CreateHook(can, (void *)&can_hook, (void **)&original_can) != MH_OK) return false;
    if (MH_CreateHook(cost, (void *)&cost_hook, (void **)&original_cost) != MH_OK) {
        MH_RemoveHook(can); return false;
    }
    if (MH_EnableHook(cost) != MH_OK) { MH_RemoveHook(can); MH_RemoveHook(cost); return false; }
    if (MH_EnableHook(can) != MH_OK) {
        MH_DisableHook(cost); MH_RemoveHook(can); MH_RemoveHook(cost); return false;
    }
    initialized = true;
    return true;
}

/* Lua C ABI without linking a SECOND Lua runtime: the wrapper passes exactly
 * one argument, true. Returning 1 returns that existing stack value, returning
 * 0 returns no values (nil in Lua). We never inspect/manipulate lua_State.
 * Public ABI details: https://www.lua.org/manual/5.4/manual.html#lua_CFunction
 * The DLL is pinned; disabling switches callbacks back to their originals.
 */
__declspec(dllexport) int warden_crafting_enable(void *lua_state) {
    (void)lua_state;
    if (fault || !initialize()) return 0;
    InterlockedExchange(&active, 1);
    return 1;
}
__declspec(dllexport) int warden_crafting_disable(void *lua_state) {
    (void)lua_state;
    InterlockedExchange(&active, 0);
    return 1;
}
__declspec(dllexport) int warden_crafting_status(void *lua_state) {
    (void)lua_state;
    return InterlockedCompareExchange(&active, 0, 0) ? 1 : 0;
}
BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)instance; (void)reason; (void)reserved;
    // No loader-lock work, file I/O, hook installation or Lua calls here.
    return TRUE;
}
#endif
