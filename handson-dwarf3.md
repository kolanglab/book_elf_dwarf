# ハンズオン(6) `.debug_info` を歩いて変数の名前と値を読む

前章のバックトレースは、各フレームがどの関数のどの行かを教えてくれました。デバッガはもう一段踏み込みます。その場所で、ローカル変数が何という名前で、いまどんな値を持っているかを見せてくれるのです。本章では、`.debug_info`（DIE の木）を歩いて、各フレームの引数とローカル変数を、型と**実際の値**つきで取り出します。`gdb` の `print x` や「変数ペイン」の核心がここにあります。

対象はやはり**動いている自分自身**です。前章と同じく `/proc/self/exe` を開き、今度は `.debug_line` ではなく `.debug_info` と `.debug_abbrev` を読みます。

## `.debug_info` の木と、それを解く `.debug_abbrev`

[](dwarf-dies.md)で見たとおり、DWARF の中心は **DIE（Debugging Information Entry）** の木です。各 DIE は「タグ（`DW_TAG_subprogram` など、これが何の DIE か）」と「属性の並び（`DW_AT_name`、`DW_AT_type`、`DW_AT_location` など）」からなります。ただし `.debug_info` の中で、この属性の並びはそのままは書かれていません。同じ形の DIE が何度も出てくるので、属性の「並び方」を別表に括り出して圧縮してあるのです。その別表が **`.debug_abbrev`（略号表）** です。

読み方はこうです。`.debug_info` で 1 つの DIE を読むには、まず先頭の**略号コード**を読み、`.debug_abbrev` でそのコードを引きます。すると「この DIE のタグは何か」「子を持つか」「どの属性が、どの**フォーム**（符号化形式）で並ぶか」が分かります。あとはその指示どおりに、`.debug_info` から属性の値を順に読むだけです。つまり `.debug_abbrev` は `.debug_info` を解く鍵です。両方を読みます。

## 略号表を読む部品

`.debug_abbrev` を、略号コード →（タグ、子の有無、属性とフォームの並び）の表に展開します。`DW_FORM_implicit_const` というフォームだけは、値そのものが `.debug_info` ではなく略号表側に書かれているので、ここで読み取って覚えておきます。

まず、これ以降で使う定数とヘルパをまとめておきます。

```c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <elf.h>

#define DW_TAG_subprogram        0x2e
#define DW_TAG_formal_parameter  0x05
#define DW_TAG_variable          0x34
#define DW_TAG_pointer_type      0x0f
#define DW_AT_name      0x03
#define DW_AT_byte_size 0x0b
#define DW_AT_encoding  0x3e
#define DW_AT_low_pc    0x11
#define DW_AT_high_pc   0x12
#define DW_AT_type      0x49
#define DW_AT_location  0x02
#define DW_OP_fbreg     0x91
#define DW_ATE_signed       0x05
#define DW_ATE_signed_char  0x06
#define DW_ATE_unsigned     0x07
#define DW_ATE_unsigned_char 0x08
#define DW_FORM_addr        0x01
#define DW_FORM_data1       0x0b
#define DW_FORM_data2       0x05
#define DW_FORM_data4       0x06
#define DW_FORM_data8       0x07
#define DW_FORM_string      0x08
#define DW_FORM_strp        0x0e
#define DW_FORM_line_strp   0x1f
#define DW_FORM_ref4        0x13
#define DW_FORM_sec_offset  0x17
#define DW_FORM_exprloc     0x18
#define DW_FORM_flag_present 0x19
#define DW_FORM_implicit_const 0x21
#define DW_FORM_sdata       0x0d
#define DW_FORM_udata       0x0f
```

`read_section` は[](handson-dwarf.md)のもの、`uleb`/`sleb`（LEB128 復号）は[](handson-dwarf.md)のものと同じです。

```c
static void must_read(void *b, size_t s, size_t n, FILE *fp) {
    if (fread(b, s, n, fp) != n) { fprintf(stderr, "read error\n"); exit(1); }
}
static uint8_t *read_section(FILE *fp, const char *name, const Elf64_Ehdr *eh, uint64_t *size) {
    Elf64_Shdr *sh = malloc((size_t)eh->e_shnum * sizeof *sh);
    fseek(fp, (long)eh->e_shoff, SEEK_SET);
    must_read(sh, sizeof *sh, eh->e_shnum, fp);
    Elf64_Shdr *ss = &sh[eh->e_shstrndx];
    char *nm = malloc(ss->sh_size);
    fseek(fp, (long)ss->sh_offset, SEEK_SET);
    must_read(nm, 1, ss->sh_size, fp);
    uint8_t *body = NULL; *size = 0;
    for (unsigned i = 0; i < eh->e_shnum; i++) {
        if (strcmp(&nm[sh[i].sh_name], name) == 0) {
            body = malloc(sh[i].sh_size);
            fseek(fp, (long)sh[i].sh_offset, SEEK_SET);
            must_read(body, 1, sh[i].sh_size, fp);
            *size = sh[i].sh_size;
            break;
        }
    }
    free(nm); free(sh);
    return body;
}
static uint64_t uleb(uint8_t **p) {
    uint64_t r = 0; int s = 0; uint8_t b;
    do { b = *(*p)++; r |= (uint64_t)(b & 0x7f) << s; s += 7; } while (b & 0x80);
    return r;
}
static int64_t sleb(uint8_t **p) {
    int64_t r = 0; int s = 0; uint8_t b;
    do { b = *(*p)++; r |= (int64_t)(b & 0x7f) << s; s += 7; } while (b & 0x80);
    if (s < 64 && (b & 0x40)) r |= -((int64_t)1 << s);
    return r;
}
```

略号表の展開です。

```c
static uint8_t *g_str, *g_lstr;   /* .debug_str / .debug_line_str（名前の格納先） */

/* .debug_abbrev: code -> (tag, 子の有無, [(属性, フォーム, implicit_const)]) */
struct attr { uint64_t at, form; int64_t ic; };
struct abbrev { uint64_t code, tag; int children; struct attr a[40]; int na; };
static struct abbrev g_ab[512]; static int g_nab;

static void parse_abbrev(uint8_t *p) {
    for (;;) {
        uint64_t code = uleb(&p);
        if (code == 0) break;
        struct abbrev *ab = &g_ab[g_nab++];
        ab->code = code; ab->tag = uleb(&p); ab->children = *p++; ab->na = 0;
        for (;;) {
            uint64_t at = uleb(&p), form = uleb(&p);
            int64_t ic = 0;
            if (form == DW_FORM_implicit_const) ic = sleb(&p);
            if (at == 0 && form == 0) break;       /* (0,0) で属性リスト終端 */
            ab->a[ab->na++] = (struct attr){at, form, ic};
        }
    }
}
static struct abbrev *find_ab(uint64_t code) {
    for (int i = 0; i < g_nab; i++) if (g_ab[i].code == code) return &g_ab[i];
    return NULL;
}
```

## フォームに従って値を読む部品

属性の値は、フォームが「どう符号化されているか」を決めます（[](dwarf-dies.md)）。`DW_FORM_data1` なら 1 バイト、`DW_FORM_strp` なら `.debug_str` への 4 バイトのオフセット、`DW_FORM_exprloc` なら「長さ + バイト列」（場所式などに使う）、といった具合です。ここでは、**自分が使わない属性も含めて、すべてのフォームを正しく読み飛ばす**必要があります。1 つでもサイズを間違えると、以降の DIE がすべてずれてしまうからです。

幸い、`gcc -gdwarf-5 -O0` が実際に吐くフォームは限られていて、文字列は `.debug_str` への直接オフセット（`DW_FORM_strp`）か行内文字列（`DW_FORM_string`）、アドレスは直接（`DW_FORM_addr`）です（DWARF5 には索引方式の `DW_FORM_strx`/`addrx` もありますが、この構成では使われません）。

```c
struct val { uint64_t u; const char *str; uint8_t *blk; uint64_t blklen; };

static struct val read_form(uint8_t **p, uint64_t form, int64_t ic) {
    struct val v = {0, NULL, NULL, 0};
    switch (form) {
    case DW_FORM_addr: v.u = *(uint64_t *)*p; *p += 8; break;
    case DW_FORM_data1: v.u = **p; *p += 1; break;
    case DW_FORM_data2: v.u = *(uint16_t *)*p; *p += 2; break;
    case DW_FORM_data4: case DW_FORM_sec_offset: case DW_FORM_ref4:
    case DW_FORM_strp: case DW_FORM_line_strp:
        v.u = *(uint32_t *)*p; *p += 4; break;
    case DW_FORM_data8: v.u = *(uint64_t *)*p; *p += 8; break;
    case DW_FORM_udata: v.u = uleb(p); break;
    case DW_FORM_sdata: v.u = (uint64_t)sleb(p); break;
    case DW_FORM_string: v.str = (char *)*p; *p += strlen((char *)*p) + 1; break;
    case DW_FORM_flag_present: v.u = 1; break;
    case DW_FORM_implicit_const: v.u = (uint64_t)ic; break;
    case DW_FORM_exprloc: v.blklen = uleb(p); v.blk = *p; *p += v.blklen; break;
    default: fprintf(stderr, "unhandled form 0x%lx\n", form); exit(1);
    }
    if (form == DW_FORM_strp) v.str = (char *)(g_str + v.u);
    if (form == DW_FORM_line_strp) v.str = (char *)(g_lstr + v.u);
    return v;
}
```

`DW_FORM_ref4` は「同じ CU 内の別の DIE へのオフセット」で、`DW_AT_type`（型をどの DIE が定義しているか）に使われます。あとで型 DIE を引くのに、このオフセットを覚えておきます。

## DIE の木を平らに読む

`.debug_info` を頭から舐め、各 DIE を読んで配列に並べます。DIE は木構造ですが、「子を持つ DIE のあと、子が続き、`0` の略号コードで 1 段戻る」という規則で平坦に並んでいるので、**深さ (depth) を数えながら**一列に読めば木が復元できます。各 DIE について、必要な属性（名前、`low_pc`、`high_pc`、型参照、サイズ、符号化、場所式）だけ拾います。

```c
struct die {
    uint64_t off, tag, depth;
    const char *name;
    uint64_t low, high, type_off, byte_size, encoding;
    uint8_t *loc; uint64_t loclen;
};
static struct die g_die[8192]; static int g_ndie;

static void parse_info(uint8_t *info, uint64_t infosz) {
    uint8_t *p = info, *end = info + infosz;
    p += 4; p += 2; p += 1; p += 1; p += 4;   /* CU ヘッダ: 長さ, 版, 単位種別, アドレスサイズ, 略号オフセット */
    uint64_t depth = 0;
    while (p < end) {
        uint64_t off = (uint64_t)(p - info);
        uint64_t code = uleb(&p);
        if (code == 0) { if (depth) depth--; continue; }   /* 子の並びの終端 → 1 段戻る */
        struct abbrev *ab = find_ab(code);
        if (!ab) { fprintf(stderr, "bad abbrev\n"); exit(1); }
        struct die d = {off, ab->tag, depth, NULL, 0, 0, 0, 0, 0, NULL, 0};
        for (int i = 0; i < ab->na; i++) {
            struct val v = read_form(&p, ab->a[i].form, ab->a[i].ic);
            switch (ab->a[i].at) {
            case DW_AT_name: d.name = v.str; break;
            case DW_AT_low_pc: d.low = v.u; break;
            case DW_AT_high_pc: d.high = v.u; break;       /* オフセット形式: 関数のサイズ */
            case DW_AT_type: d.type_off = v.u; break;       /* CU 内オフセット (ref4) */
            case DW_AT_byte_size: d.byte_size = v.u; break;
            case DW_AT_encoding: d.encoding = v.u; break;
            case DW_AT_location: d.loc = v.blk; d.loclen = v.blklen; break;
            }
        }
        g_die[g_ndie++] = d;
        if (ab->children) depth++;
    }
}
static struct die *die_at(uint64_t off) {
    for (int i = 0; i < g_ndie; i++) if (g_die[i].off == off) return &g_die[i];
    return NULL;
}
```

## 値を型に従って表示する

変数の値は、ただのバイト列です。それを**何バイト読み、どう解釈するか**は、その変数の型 DIE が決めます。`DW_AT_type` をたどった先が `DW_TAG_base_type` なら、`DW_AT_byte_size`（バイト数）と `DW_AT_encoding`（符号付き／符号なし／文字など）が分かるので、それに従って読みます（[](dwarf-data.md)）。ポインタ型なら 8 バイトのアドレスとして 16 進で示します。

```c
static const char *type_name(struct die *t) {
    if (!t) return "void";
    if (t->tag == DW_TAG_pointer_type) return "pointer";
    return t->name ? t->name : "?";
}
static void print_value(struct die *t, void *addr) {
    if (!t) { printf("?"); return; }
    if (t->tag == DW_TAG_pointer_type) { printf("0x%lx", *(uintptr_t *)addr); return; }
    uint64_t sz = t->byte_size;
    if (t->encoding == DW_ATE_signed) {
        long long v = sz == 1 ? *(int8_t *)addr : sz == 2 ? *(int16_t *)addr
                    : sz == 4 ? *(int32_t *)addr : *(int64_t *)addr;
        printf("%lld", v);
    } else if (t->encoding == DW_ATE_signed_char || t->encoding == DW_ATE_unsigned_char) {
        unsigned char c = *(unsigned char *)addr;
        printf("'%c' (%u)", c >= 32 && c < 127 ? c : '.', c);
    } else {   /* 符号なし・真偽など */
        unsigned long long v = sz == 1 ? *(uint8_t *)addr : sz == 2 ? *(uint16_t *)addr
                             : sz == 4 ? *(uint32_t *)addr : *(uint64_t *)addr;
        printf("%llu", v);
    }
}
```

## 関数の中のローカル変数を見つける

いよいよ本丸です。あるフレーム（PC とフレームポインタ `rbp` の組）について、

1. その PC を本体に含む `DW_TAG_subprogram`（関数 DIE）を探す（`low_pc ≤ pc < low_pc + high_pc`）。
2. その**子**の `DW_TAG_formal_parameter`（引数）と `DW_TAG_variable`（局所変数）を順に見る。
3. 各変数の `DW_AT_location`（場所式）から、変数がスタックのどこにあるかを求め、値を読む。

場所式はたいてい `DW_OP_fbreg <offset>`、つまり「フレームベースから offset バイト」という意味です（[](dwarf-data.md)）。フレームベースは関数 DIE の `DW_AT_frame_base` で決まり、`gcc -O0` では `DW_OP_call_frame_cfa`（CFA = 呼び出し時の基準アドレス）になります。フレームポインタを省略しない `-O0` のコードでは、**CFA はちょうど `rbp + 16`**（保存された `rbp` と戻りアドレスの上）です。よって変数のアドレスは `rbp + 16 + offset` で求まります。

```c
/* pc を本体に含む関数のローカル変数を、frame_rbp のフレームから読んで表示する。
   その関数が main なら 1 を返す（呼び出し側が巻き戻しを止める）。 */
static int dump_locals(uint64_t pc, uintptr_t frame_rbp) {
    uintptr_t frame_base = frame_rbp + 16;    /* -O0 + フレームポインタなら CFA = rbp + 16 */
    for (int i = 0; i < g_ndie; i++) {
        struct die *s = &g_die[i];
        if (s->tag != DW_TAG_subprogram || s->low == 0) continue;
        if (!(pc >= s->low && pc < s->low + s->high)) continue;
        printf("%s():\n", s->name ? s->name : "?");
        for (int j = i + 1; j < g_ndie && g_die[j].depth > s->depth; j++) {
            struct die *v = &g_die[j];
            if (v->depth != s->depth + 1) continue;          /* 直接の子だけ */
            if (v->tag != DW_TAG_formal_parameter && v->tag != DW_TAG_variable) continue;
            struct die *t = v->type_off ? die_at(v->type_off) : NULL;
            const char *kind = v->tag == DW_TAG_formal_parameter ? "param" : "local";
            if (v->loc && v->loclen >= 1 && v->loc[0] == DW_OP_fbreg) {
                uint8_t *q = v->loc + 1;
                int64_t offs = sleb(&q);
                void *addr = (void *)(frame_base + offs);
                printf("    %-6s %-10s %-8s = ", kind, type_name(t), v->name ? v->name : "?");
                print_value(t, addr);
                printf("\n");
            }
        }
        return s->name && strcmp(s->name, "main") == 0;
    }
    return 0;
}
```

## フレームを巡る

あとは前章と同じフレームポインタの鎖をたどり、各フレームについて `dump_locals` を呼ぶだけです。鎖の各段で、「戻りアドレス `ret`（＝呼び出し元の中の PC）」と「呼び出し元のフレームポインタ `caller_fp`」が手に入るので、その組を `dump_locals` に渡します。

```c
/* フレームポインタの鎖をたどり、各フレームのローカル変数と値を出す */
static void backtrace_with_locals(void) {
    uintptr_t fp = (uintptr_t)__builtin_frame_address(0);
    for (int depth = 0; depth < 64 && fp; depth++) {
        uintptr_t ret       = *(uintptr_t *)(fp + 8);   /* 戻りアドレス: 呼び出し元の中の PC */
        uintptr_t caller_fp = *(uintptr_t *)fp;          /* 呼び出し元のフレームポインタ */
        if (ret == 0) break;
        printf("#%d  ", depth);
        if (dump_locals(ret, caller_fp)) break;          /* main まで出したら止める */
        fp = caller_fp;
    }
}
```

## 動かして確かめる

別々の引数とローカルを持つ関数を入れ子に呼び、いちばん奥から巻き戻します。`setup` で自分の `.debug_info` などを読み込んでから、`level1` を呼びます。

```c
int level3(int x) {
    int local3 = x + 100;
    char mark = 'Z';
    backtrace_with_locals();
    return local3 + (mark - mark);
}
int level2(int y) {
    int local2 = y * 3;
    return level3(local2);
}
int level1(int z) {
    long local1 = (long)z + 1;
    return level2((int)local1);
}
static void setup(void) {
    FILE *fp = fopen("/proc/self/exe", "rb");
    Elf64_Ehdr eh; must_read(&eh, sizeof eh, 1, fp);
    uint64_t z, infosz;
    uint8_t *info   = read_section(fp, ".debug_info", &eh, &infosz);
    uint8_t *abbrev = read_section(fp, ".debug_abbrev", &eh, &z);
    g_str  = read_section(fp, ".debug_str", &eh, &z);
    g_lstr = read_section(fp, ".debug_line_str", &eh, &z);
    fclose(fp);
    parse_abbrev(abbrev);
    parse_info(info, infosz);
}
int main(void) {
    setup();
    int seed = 5;
    return level1(seed) == 0;
}
```

ビルドには、行番号は使わないので `-g`（DWARF を出す）と、フレームポインタの鎖のための `-fno-omit-frame-pointer`、アドレスを直接引くための `-no-pie` を付けます。

```
$ gcc -g -gdwarf-5 -O0 -no-pie -fno-omit-frame-pointer -Wall -Wextra -o minivars minivars.c
$ ./minivars
#0  level3():
    param  int        x        = 18
    local  int        local3   = 118
    local  char       mark     = 'Z' (90)
#1  level2():
    param  int        y        = 6
    local  int        local2   = 18
#2  level1():
    param  int        z        = 5
    local  long int   local1   = 6
#3  main():
    local  int        seed     = 5
```

呼び出しの履歴が、各フレームの引数とローカル変数を、名前、型、いまの値つきで並びました。`main(seed=5)` が `level1(z=5)` を呼び、そこで `local1 = 6`、`level2(y=6)` で `local2 = 18`、`level3(x=18)` で `local3 = 118`、`mark = 'Z'` となり、ソースを追えば、すべての値が辻褄どおりだと確かめられます。`backtrace()` はおろか、`addr2line` でも出せない情報を、`.debug_info` を自分で歩いて取り出しました。これは小さいながら、まぎれもなく**デバッガが変数を表示する仕組みそのもの**です。

> [!NOTE]
> このツールは要点だけを取り出したおもちゃで、いくつもの仮定を置いています。**フレームベースを `rbp + 16` と決め打ち**しているのは `-O0` ＋フレームポインタありだからで、本来 `DW_OP_call_frame_cfa` を正しく計算するには `.eh_frame`/`.debug_frame` のコールフレーム情報（CFI）が要ります。**場所式も `DW_OP_fbreg` だけ**を扱っており、レジスタにある変数（`DW_OP_reg`）や、最適化で消えた変数は出せません（[](dwarf-limits.md)で見たとおり、最適化はこの対応を崩します）。型も `base_type` とポインタだけで、構造体や配列、`typedef` はたどっていません。それでも、「略号表で `.debug_info` を解き、関数 DIE から変数を見つけ、場所式で値の在処を求める」という骨格は、本物のデバッガと同じです。`.debug_info` のより本格的な歩き方は[](dwarf-dies.md)と[](dwarf-data.md)が地図になります。

## おわりに

本書は、ELF ヘッダの先頭 16 バイトから始めて、セクション、シンボル、ローディングと ELF を一巡し、続いて DWARF の DIE、型、場所式、行番号情報をたどりました。そして 6 つのハンズオンで、その知識を手で動かしました。ELF を読み（ミニ readelf）、メモリへロードして実行し（ミニローダ）、`.o` を再配置して関数を呼び（変なローダ）、DWARF でアドレスから行を引き（ミニ addr2line）、動いているプロセスの全スレッドを覗き（リッチなバックトレース）、最後に各フレームの変数とその値まで取り出しました（変数ビューア）。

振り返ると、一貫していたのは「**バイナリは、仕様という約束に従って切り分ければ読める**」という一点です。最初は意味不明に見えたバイト列が、`7f 45 4c 46` というマジックから始まり、オフセットをたどり、可変長整数を復号し、状態機械や DIE の木をたどることで、関数名、行番号、変数の値という人間の言葉に戻っていきます。その全過程を、あなたは自分の手で再現しました。

DWARF については、[](dwarf-limits.md)で「分かることと分からないこと」の境界も学びました。`-O0` のバイナリなら今回のように変数や行がきれいに引けますが、最適化された世界では変数が消え、行が飛びます。それは DWARF の限界というより、最適化がソースと機械語の対応そのものを崩すからでした。この勘所を持っていれば、デバッガの不可解な挙動にも臆さず向き合えるはずです。

ここから先は、`.eh_frame` を読んでフレームポインタなしでも巻き戻せるアンワインダ、構造体や配列まで展開する型ビューア、あるいは `ptrace` と組み合わせて他プロセスやコアダンプを覗く小さなデバッガと、どんな方向にも進めます。バイナリの中身は、もうあなたにとって「読めないもの」ではありません。
