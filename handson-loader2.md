# ハンズオン(3) `.o` を直接ロードして関数を呼ぶ変なローダ

前のハンズオンでロードしたのは、完成した実行ファイル（`ET_EXEC`）でした。アドレスはすべて確定し、埋めるべき空欄は残っていません。今度はもっと奇妙なものをロードします。**再配置可能オブジェクトファイル**（`.o`、`ET_REL`）です。`.o` は、本来リンカが食べる「半完成品」で、普通はそのまま実行されることはありません。プログラムヘッダを持たず、配置先アドレスも未定で、[](elf-symbols.md)で見た**再配置**（埋めるべき空欄）が残っています。

本章では、私たちがリンカ兼ローダになって、`.o` のセクションをメモリに置き、再配置の空欄を `S + A - P` で埋め、その中の関数を実行時に呼び出します。これは近年話題の **copy-and-patch** というコンパイル手法の核心そのものです。さらに遊び心として、変数名に数が入っていたら、その数で初期化するという変なローダにしてみます。

## 名前に数を仕込んだ題材の `.o`

ロードされる `stencil.c` は、未初期化のグローバル変数 `g42` と `g100`、その和を返す関数 `get_value` だけの小さなコードです。

```c
/* 再配置可能オブジェクトに変換して使う。g42・g100 は未初期化グローバル（.bss 行き）。
   ビルド: gcc -c -O0 -fno-pic stencil.c -o stencil.o */
int g42;
int g100;
int get_value(void) { return g42 + g100; }
```

未初期化のグローバルなので、本来 `g42` と `g100` は `.bss` に置かれ、値は 0 になるはずです。`get_value` は素直にその和（つまり 0）を返すコードになります。`-fno-pic` を付けるのは、`g42` への参照を GOT 経由ではなく**直接の PC 相対参照**（`R_X86_64_PC32`）にして、再配置を素朴な形にするためです。

ビルドして、シンボルと再配置を覗いてみましょう。

```
$ gcc -c -O0 -fno-pic stencil.c -o stencil.o
$ readelf -s stencil.o | grep -E 'g42|g100|get_value'
     3: 0000000000000000     4 OBJECT  GLOBAL DEFAULT    4 g42
     5: 0000000000000004     4 OBJECT  GLOBAL DEFAULT    4 g100
     6: 0000000000000000    21 FUNC    GLOBAL DEFAULT    1 get_value
$ readelf -r stencil.o
Relocation section '.rela.text' ... contains 2 entries:
  Offset          Info           Type           Sym. Name + Addend
00000000000a  000300000002 R_X86_64_PC32     g42 - 4
000000000015  000500000002 R_X86_64_PC32     g100 - 4
```

`g42` と `g100` は `.bss`（4 番セクション）の `OBJECT` シンボル、`get_value` は `.text`（1 番セクション）の `FUNC` シンボルです。そして `.rela.text` に、「`get_value` のコード中のこの位置に、`g42`（`g100`）のアドレスを `R_X86_64_PC32`（= `S + A - P`）で埋めよ」という再配置が 2 つ並んでいます。まさに[](elf-symbols.md)で見た「数式付きの空欄」です。これを私たちが埋めます。

## 方針

`.o` を実行できる形にするには、次のことが必要です。いずれも ELF 部で学んだ部品の組み合わせです。

1. セクションを置く。`SHF_ALLOC` の付いたセクション（`.text` と `.bss`）をメモリのどこかに配置する（[](elf-sections.md)）。
2. シンボルの実行時アドレスを決める。各シンボルのアドレスは「定義先セクションの配置先 + `st_value`」になる（[](elf-symbols.md)）。
3. 変な初期化。`.bss` のグローバルのうち、名前に数を含むものをその数で埋める。
4. 再配置を解く。`.rela.text` の各エントリを `S + A - P` で埋める（[](elf-symbols.md)）。
5. 関数を呼ぶ。`get_value` の実行時アドレスを求めて呼び出す。

ファイル読み込みのヘルパは前章までと同じ `must_read` に、オフセットとサイズを渡すと `malloc` して読む `xread` を足しておきます。

```c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <elf.h>
#include <sys/mman.h>

static void must_read(void *b, size_t s, size_t n, FILE *fp) {
    if (fread(b, s, n, fp) != n) { fprintf(stderr, "read error\n"); exit(1); }
}
static void *xread(FILE *fp, long off, size_t sz) {
    void *p = malloc(sz);
    fseek(fp, off, SEEK_SET);
    must_read(p, 1, sz, fp);
    return p;
}
```

## ステップ1: `.o` を開いて表を読む

ELF ヘッダを読み、`ET_REL`（再配置可能）であることを確かめ、セクションヘッダテーブルと、シンボルテーブル `.symtab`、その文字列表 `.strtab` を読み込みます。`.symtab` は `SHT_SYMTAB` 型のセクションで、その `sh_link` が対応する文字列表を指しています。

```c
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s OBJ.o\n", argv[0]); return 1; }
    FILE *fp = fopen(argv[1], "rb");
    if (!fp) { perror("fopen"); return 1; }

    Elf64_Ehdr eh;
    must_read(&eh, sizeof eh, 1, fp);
    if (memcmp(eh.e_ident, ELFMAG, SELFMAG) != 0 || eh.e_type != ET_REL) {
        fprintf(stderr, "not a relocatable ELF (.o)\n"); return 1;
    }

    /* セクションヘッダテーブル */
    Elf64_Shdr *sh = xread(fp, (long)eh.e_shoff, (size_t)eh.e_shnum * sizeof *sh);

    /* .symtab とその文字列表 .strtab を探す */
    Elf64_Sym *sym = NULL; size_t nsym = 0; char *str = NULL;
    for (unsigned i = 0; i < eh.e_shnum; i++)
        if (sh[i].sh_type == SHT_SYMTAB) {
            sym  = xread(fp, (long)sh[i].sh_offset, sh[i].sh_size);
            nsym = sh[i].sh_size / sizeof *sym;
            str  = xread(fp, (long)sh[sh[i].sh_link].sh_offset, sh[sh[i].sh_link].sh_size);
        }
```

## ステップ2: セクションをメモリに置く

実行・読み書きできる大きな領域（アリーナ）を 1 つ `mmap` し、`SHF_ALLOC` の付いたセクションを、整列条件 `sh_addralign` を守りながら先頭から詰めていきます。各セクションの配置先を `base[]` に覚えておきます。`SHT_PROGBITS`（`.text` など）は中身をファイルから写し、`SHT_NOBITS`（`.bss`）はゼロのままにします。

```c
    /* 実行可能な作業領域を 1 つ確保し、セクションを順に詰める */
    uint8_t *arena = mmap(NULL, 1 << 20, PROT_READ | PROT_WRITE | PROT_EXEC,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (arena == MAP_FAILED) { perror("mmap"); return 1; }
    uint8_t **base = calloc(eh.e_shnum, sizeof *base);
    size_t cur = 0;
    for (unsigned i = 0; i < eh.e_shnum; i++) {
        if (!(sh[i].sh_flags & SHF_ALLOC)) continue;
        size_t al = sh[i].sh_addralign ? sh[i].sh_addralign : 1;
        cur = (cur + al - 1) & ~(al - 1);             /* 整列 */
        base[i] = arena + cur;
        if (sh[i].sh_type == SHT_NOBITS) {
            memset(base[i], 0, sh[i].sh_size);         /* .bss はゼロ */
        } else {
            fseek(fp, (long)sh[i].sh_offset, SEEK_SET);
            must_read(base[i], 1, sh[i].sh_size, fp);  /* セクション本体を写す */
        }
        cur += sh[i].sh_size;
    }
```

これで、あるシンボルの実行時アドレスは `base[sym.st_shndx] + sym.st_value` で求められるようになりました。「どのセクションの、何バイト目か」が、そのまま「メモリのどこか」へ翻訳されるわけです。

## ステップ3: 名前から値を入れる変な初期化

ここが本章の遊びです。ふつう `.bss` のグローバルは 0 で始まります。が、このローダは**シンボル名に数字が含まれていたら、その数でそのグローバルを初期化**します。`g42` なら 42、`g100` なら 100 を、その置き場所に書き込みます。

```c
    /* 変なパッチ: 名前に数 N を含むグローバル変数を、その N で初期化する */
    for (size_t i = 0; i < nsym; i++) {
        if (ELF64_ST_TYPE(sym[i].st_info) != STT_OBJECT) continue;
        if (sym[i].st_shndx >= eh.e_shnum || !base[sym[i].st_shndx]) continue;
        const char *name = &str[sym[i].st_name];
        const char *d = name; while (*d && !isdigit((unsigned char)*d)) d++;
        if (!*d) continue;                                  /* 数字が無ければ素通り */
        int val = atoi(d);
        memcpy(base[sym[i].st_shndx] + sym[i].st_value, &val, sizeof val);
        printf("patch: %s = %d (from its name)\n", name, val);
    }
```

## ステップ4: 再配置を解く

`SHT_RELA` 型のセクション（`.rela.text` など）を順に見ます。その `sh_info` が「どのセクションへの再配置か」を指すので、配置済みのセクションが対象のものだけを処理します（`.rela.eh_frame` のような未配置セクション向けは飛ばします）。各エントリで、シンボルの実行時アドレス `S`、書き換え位置 `P`、加数 `A` を求め、[](elf-symbols.md)の表のとおりに計算して埋め込みます。

```c
    /* 配置済みセクション向けの再配置をすべて適用する */
    for (unsigned i = 0; i < eh.e_shnum; i++) {
        if (sh[i].sh_type != SHT_RELA) continue;
        unsigned tgt = sh[i].sh_info;
        if (tgt >= eh.e_shnum || !base[tgt]) continue;       /* .eh_frame 等は対象外 */
        Elf64_Rela *rel = xread(fp, (long)sh[i].sh_offset, sh[i].sh_size);
        size_t nrel = sh[i].sh_size / sizeof *rel;
        for (size_t r = 0; r < nrel; r++) {
            Elf64_Sym *s = &sym[ELF64_R_SYM(rel[r].r_info)];
            uint8_t *S = base[s->st_shndx] + s->st_value;     /* シンボルの実行時アドレス */
            uint8_t *P = base[tgt] + rel[r].r_offset;         /* 書き換え位置 */
            int64_t  A = rel[r].r_addend;
            switch (ELF64_R_TYPE(rel[r].r_info)) {
            case R_X86_64_PC32:
            case R_X86_64_PLT32: { int32_t v = (int32_t)((intptr_t)S + A - (intptr_t)P);
                                   memcpy(P, &v, 4); break; }
            case R_X86_64_64:    { int64_t v = (int64_t)((intptr_t)S + A);
                                   memcpy(P, &v, 8); break; }
            default: fprintf(stderr, "unhandled reloc type %lu\n",
                             ELF64_R_TYPE(rel[r].r_info)); return 1;
            }
        }
        free(rel);
    }
    fclose(fp);
```

`R_X86_64_PC32` の `S + A - P` が、まさに「`get_value` のコードの空欄に、そこから `g42` までの距離を書き込む」操作です。これでコードは、メモリに置いた `g42` と `g100` を正しく指すようになりました。

## ステップ5: 関数を呼ぶ

最後に、`get_value` シンボルの実行時アドレスを `base[st_shndx] + st_value` で求め、関数ポインタにして呼び出します。

```c
    /* get_value を探して呼ぶ */
    for (size_t i = 0; i < nsym; i++) {
        if (ELF64_ST_TYPE(sym[i].st_info) == STT_FUNC &&
            strcmp(&str[sym[i].st_name], "get_value") == 0) {
            int (*f)(void) = (int (*)(void))(base[sym[i].st_shndx] + sym[i].st_value);
            printf("get_value() = %d\n", f());
            return 0;
        }
    }
    fprintf(stderr, "get_value not found\n");
    return 1;
}
```

## 動かして確かめる

ローダをコンパイルして、`stencil.o` を食わせます。

```
$ gcc -Wall -Wextra -o loadobj loadobj.c
$ ./loadobj stencil.o
patch: g42 = 42 (from its name)
patch: g100 = 100 (from its name)
get_value() = 142
```

`get_value()` が **142** を返しました。ソースには `g42` と `g100` を初期化するコードなど一行もないのに、です。142 = 42 + 100 です。この 2 つの数は、変数の名前からローダが取り出して `.bss` に書き込んだものです。私たちは `.o` のセクションを配置し、再配置を解いて関数を実行可能にし、さらにシンボルの値を実行時に決めて差し込みました。

## copy-and-patch コンパイル

「あらかじめコンパイルした `.o` を、実行時にメモリへ写し、空欄（再配置）を具体的な値で埋めて、その場で実行する」。この章でやったことは、copy-and-patch コンパイルと呼ばれる手法の骨格そのものです。あらかじめ用意した機械語の断片（**ステンシル**）には、定数やアドレスを後から差し込むための穴（再配置）が空いていて、実行時にコードを複製し、穴を埋めるだけで高速にコードを生成します。コンパイラを実行時に走らせるより桁違いに速く、CPython 3.13 以降の実験的 JIT などが採用しています。本章の「名前から値を差し込む」変なパッチは、その「穴を実行時の具体値で埋める」操作の、ささやかな見立てです。

> [!NOTE]
> もちろんこのローダは教材用のおもちゃで、本物のリンカ／ローダがやることのごく一部しか扱っていません。外部シンボルの解決（別の `.o` やライブラリとの結合）、PLT/GOT を要する再配置、共通シンボル (`SHN_COMMON`)、`R_X86_64_PC32` 以外の多くのタイプ、`W^X`（書き込みと実行の分離）などはすべて省いています。それでも、「セクションを置く、シンボルのアドレスを決める、再配置を `S + A - P` で埋める」という、リンクの心臓部は本物と同じです。詳しくは[](elf-symbols.md)と[](elf-loading.md)が地図になります。

ここまで 3 つのハンズオンで、ELF を読み、ロードし、再配置して実行するところまで来ました。次のハンズオンからは DWARF に移ります。まずは静的解析として、`.debug_line` を解釈して機械語アドレスからソース行を求める `addr2line` を作ります。
