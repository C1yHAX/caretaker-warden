// Standalone tests of OUR callbacks/maps only. Never loads or starts the game.
#define WARDEN_TEST
#include "crafting.c"
#include <stdio.h>
#include <stdlib.h>
static int assertions;
#define CHECK(x) do { ++assertions; if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static int32_t seen_count;
static bool original_result = true, seen_components;
static void *seen_item, *seen_inventories, *seen_fabricator;
static bool fake_can(void *f, void *i, void *inv, int32_t n, bool components) {
    seen_count = n; seen_components = components; seen_item = i;
    seen_inventories = inv; seen_fabricator = f; return original_result;
}
static bool fake_cost(void *f, void *i, Cost *c, void *inv, int32_t n) {
    (void)c; seen_count = n; seen_item = i; seen_inventories = inv; seen_fabricator = f;
    return original_result;
}
static void make_map(ItemMap *m, ItemPair *data, int32_t n, uint32_t *heap) {
    memset(m, 0, sizeof(*m)); m->data = data; m->num = m->capacity = m->bit_count = n;
    m->bit_capacity = heap ? 160 : 128; m->heap_bits = heap;
    m->first_free = -1; m->hash_size = 1; m->inline_hash = 23;
    uint32_t *bits = heap ? heap : m->inline_bits;
    memset(bits, 0, heap ? 20 : 16);
    for (int i = 0; i < n; ++i) {
        bits[i >> 5] |= 1u << (i & 31);
        data[i] = (ItemPair){(void *)(uintptr_t)(i+1), i+7, 91, i+12, i+13};
    }
}
__attribute__((noinline,optnone)) static int hook_target(int n) { volatile int a=n+3; return a*5+1; }
static int (*original_target)(int);
static int target_hook(int n) { return original_target(n)+100; }

int main(void) {
    original_can = fake_can; original_cost = fake_cost;
    void *f=(void *)1, *item=(void *)2, *inv=(void *)3;
    active=0;
    CHECK(can_hook(f,item,inv,7,true) && seen_count==7 && seen_components);
    active=1;
    CHECK(can_hook(f,item,inv,7,true) && seen_count==0 && seen_components);
    CHECK(seen_item==item && seen_inventories==inv && seen_fabricator==f);
    original_result=false;
    CHECK(!can_hook(f,item,inv,7,false)); // retain native locked/missing inventory rejection
    original_result=true;
    CHECK(can_hook(f,item,inv,-2,false) && seen_count==-2);

    Cost c={0}; ItemPair items[3], mats[2];
    make_map(&c.required,items,3,NULL); make_map(&c.materials,mats,2,NULL);
    c.required.inline_bits[0] &= ~(1u<<1); c.required.num_free=1;
    c.time=17.5f; c.total_time=52.5f;
    // Sentinel bytes in unrelated maps: no reads or writes permitted there.
    memset(&c.total,0x5a,sizeof(c.total)); memset(&c.local,0x6b,sizeof(c.local));
    Cost before=c; ItemPair item_before[3]; memcpy(item_before,items,sizeof(items));
    CHECK(cost_hook(f,item,&c,inv,3) && seen_count==3);
    CHECK(items[0].amount==0 && items[2].amount==0 && items[1].amount==8);
    CHECK(mats[0].amount==0 && mats[1].amount==0);
    CHECK(memcmp(&c,&before,sizeof(c))==0); // pointers, keys, hashes, time all preserved
    for(int i=0;i<3;++i) { item_before[i].amount=items[i].amount; CHECK(!memcmp(&item_before[i],&items[i],sizeof(ItemPair))); }
    // A recipe is not passed to zero_cost: original item pointer survives unchanged.
    CHECK(seen_item==item && seen_fabricator==f && seen_inventories==inv);

    ItemPair many[150]; uint32_t bits[5];
    make_map(&c.required,many,150,bits); make_map(&c.materials,mats,0,NULL);
    c.required.heap_bits[4]&=~(1u<<3); c.required.num_free=1;
    CHECK(zero_cost(&c));
    for(int i=0;i<150;++i) CHECK(many[i].amount==(i==131 ? i+7:0));

    // Validate the second map before touching the first.
    make_map(&c.required,items,3,NULL); make_map(&c.materials,mats,2,NULL);
    c.materials.bit_count=3;
    CHECK(!zero_cost(&c) && items[0].amount==7);
    CHECK(cost_hook(f,item,&c,inv,5) && active==0 && fault==1 && items[0].amount==7);
    CHECK(cost_hook(f,item,&c,inv,5) && items[0].amount==7); // disabled = original behavior
    active=1; fault=0; original_result=false;
    CHECK(!cost_hook(f,item,NULL,inv,5) && !fault); // failed native call can have no result
    original_result=true;
    CHECK(cost_hook(f,item,&c,inv,0) && !fault && items[0].amount==7);

    // Paid reservation settlement at completion must use ORIGINAL costs, even
    // while Free Crafting is on. Unknown callers also retain normal semantics.
    make_map(&c.materials,mats,2,NULL);
    test_cost_caller=0x5506a13;
    CHECK(cost_hook(f,item,&c,inv,1) && items[0].amount==7 && mats[0].amount==7);
    test_cost_caller=0x12345678;
    CHECK(cost_hook(f,item,&c,inv,1) && items[0].amount==7 && mats[0].amount==7);
    CHECK(material_cost_caller(0x54f7845));
    CHECK(material_cost_caller(0x54ff9bc));
    CHECK(material_cost_caller(0x550ea1b));
    CHECK(!material_cost_caller(0x57d8e7b));
    test_cost_caller=0x57d8e7b;
    CHECK(cost_hook(f,item,&c,inv,1) && mats[0].amount==7);
    CHECK((140 / mats[0].amount)==20); // real UI consumer divides by this value
    CHECK(!material_cost_caller(0x5506a13));
    CHECK(!material_cost_caller(0));

    // Exercise actual x64 MinHook trampolines in this standalone process.
    int (*volatile call_target)(int)=hook_target;
    CHECK(call_target(4)==36);
    CHECK(MH_Initialize()==MH_OK);
    CHECK(MH_CreateHook((void *)hook_target,(void *)target_hook,(void **)&original_target)==MH_OK);
    CHECK(MH_EnableHook((void *)hook_target)==MH_OK);
    CHECK(call_target(4)==136);
    CHECK(MH_DisableHook((void *)hook_target)==MH_OK);
    CHECK(call_target(4)==36);
    CHECK(MH_RemoveHook((void *)hook_target)==MH_OK);
    CHECK(MH_Uninitialize()==MH_OK);
    printf("PASS: %d native helper assertions; no game loaded or launched\n",assertions);
    return 0;
}
