# おまけ：PE ―― Windows の実行ファイル形式

本書はここまで、Unix/Linux の世界の **ELF** と **DWARF** を読んできました。では Windows はどうなっているのでしょうか。Windows の実行ファイル（`.exe`）と DLL は **PE（Portable Executable）** という形式で、デバッグ情報は **PDB（Program Database、CodeView 形式）** に入ります。ちょうど ELF と DWARF に対応する一対です。

うれしいことに、あなたはもう ELF を読めます。そして **PE は、ELF と「名前は違うが考えは同じ」**な部分がとても多いのです。このおまけでは、ELF の言葉で PE を読み解き、最後に本物の `.exe` のヘッダを自作のツールで覗きます。

## ELF と PE ―― 名前は違うが、考えは同じ

まず全体像を対応表で押さえましょう。左が本書で学んだ ELF、右がその PE での相当物です。

| はたらき | ELF | PE |
|---|---|---|
| 入口のマジック | `7f 45 4c 46`（`\x7fELF`） | `MZ`（DOS）→ `PE\0\0` |
| ファイル全体の素性 | ELF ヘッダ（[](elf-header.md)） | COFF ファイルヘッダ ＋ オプショナルヘッダ |
| 実行時の配置単位 | セグメント（プログラムヘッダ、[](elf-loading.md)） | セクション ＋ `ImageBase` |
| リンク時の区分け | セクション（[](elf-sections.md)） | セクション（`.text`/`.data`/`.rdata`/`.reloc` …） |
| 配置先アドレスの数え方 | 仮想アドレス（絶対） | **RVA**（`ImageBase` からの相対） |
| 動的リンク | `.dynamic`／PLT／GOT（[](elf-loading.md)） | Import Directory／IAT |
| 再配置 | `.rela.*`（[](elf-symbols.md)） | Base Relocation（`.reloc`） |
| デバッグ情報 | DWARF（本体に同梱） | **PDB**（別ファイル）＋ CodeView |

要するに、「先頭のマジックから入り、ヘッダで 2 つの見方（リンク用とロード用）を得て、セクションをたどり、シンボルと再配置で名前をアドレスに結ぶ」という骨格は、ELF も PE もまったく同じです。違いは名前と、いくつかの設計判断（とくに後述の **RVA** と、**デバッグ情報を別ファイルに出す**点）にあります。

## PE の骨格を歩く

PE ファイルの先頭は、歴史的事情で **DOS ヘッダ**から始まります。`MZ`（開発者 Mark Zbikowski のイニシャル）で始まり、「このプログラムは DOS では動きません」と表示する小さな DOS スタブが続きます。その DOS ヘッダの**オフセット `0x3C`** に、本物の PE ヘッダの位置 `e_lfanew` が書かれています。そこへ飛ぶと `PE\0\0` という署名があり、その直後から、

1. **COFF ファイルヘッダ** ―― `Machine`（CPU 種別）、`NumberOfSections`、オプショナルヘッダのサイズなど。ELF ヘッダに相当する素性情報です。実は `.o` の COFF ヘッダと同じ形で、PE は「COFF を実行ファイル用に拡張したもの」なのです。
2. **オプショナルヘッダ** ―― 名前に反して必須で、`AddressOfEntryPoint`（エントリ、ただし RVA）、`ImageBase`（希望する配置先）、サブシステム、そして後述のデータディレクトリが並びます。64 ビットの PE は **PE32+** と呼ばれ、先頭の `Magic` が `0x20b` です（32 ビットは `0x10b`）。
3. **セクションテーブル** ―― 各セクションの名前・RVA・サイズ・ファイル上の位置。ELF のセクションヘッダ表に相当します。

と続きます。これだけ分かれば、ELF のときと同じ要領でツールが書けます。

## ハンズオン：ミニ PE リーダ

[](handson-elf.md)で書いたミニ readelf の PE 版を作りましょう。やることは同じ ―― 先頭のヘッダ群を構造体として読み、セクション一覧を表示するだけです。PE の構造体は Windows のものですが、私たちは Linux 上で**バイト列として**読むだけなので、必要なフィールドを自分で定義します。フィールドが自然境界に揃っていないので、`#pragma pack(push, 1)` で詰めて宣言するのがコツです。

```c
/* mini PE reader: ミニ readelf の Windows 版。.exe/.dll のヘッダとセクション表を読む。
   ビルド: gcc -Wall -Wextra -o minipe minipe.c */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static void must_read(void *buf, size_t size, size_t n, FILE *fp) {
    if (fread(buf, size, n, fp) != n) { fprintf(stderr, "read error\n"); exit(1); }
}

#pragma pack(push, 1)
/* COFF ファイルヘッダ（.o と同じ形）。"PE\0\0" 署名の直後にある */
typedef struct {
    uint16_t Machine;
    uint16_t NumberOfSections;
    uint32_t TimeDateStamp;
    uint32_t PointerToSymbolTable;
    uint32_t NumberOfSymbols;
    uint16_t SizeOfOptionalHeader;
    uint16_t Characteristics;
} FileHeader;

/* 64 ビット（PE32+）オプショナルヘッダの先頭。必要な前半だけ定義する */
typedef struct {
    uint16_t Magic;                 /* 0x20b = PE32+ */
    uint8_t  MajorLinkerVersion, MinorLinkerVersion;
    uint32_t SizeOfCode, SizeOfInitializedData, SizeOfUninitializedData;
    uint32_t AddressOfEntryPoint;   /* RVA */
    uint32_t BaseOfCode;
    uint64_t ImageBase;             /* 希望する配置先アドレス */
} OptHeader64;

typedef struct {
    char     Name[8];
    uint32_t VirtualSize;
    uint32_t VirtualAddress;        /* RVA */
    uint32_t SizeOfRawData;
    uint32_t PointerToRawData;      /* 中身のファイル内オフセット */
    uint32_t PointerToRelocations, PointerToLinenumbers;
    uint16_t NumberOfRelocations, NumberOfLinenumbers;
    uint32_t Characteristics;
} SectionHeader;
#pragma pack(pop)
```

`main` は、DOS ヘッダ → `PE\0\0` → COFF ヘッダ → オプショナルヘッダ → セクション表、と順にたどります。

```c
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s PE\n", argv[0]); return 1; }
    FILE *fp = fopen(argv[1], "rb");
    if (!fp) { perror("fopen"); return 1; }

    /* 1. DOS ヘッダ: "MZ"、そしてオフセット 0x3C の e_lfanew が PE ヘッダを指す */
    uint16_t mz; must_read(&mz, 2, 1, fp);
    if (mz != 0x5A4D) { fprintf(stderr, "not MZ (not a PE)\n"); return 1; }
    uint32_t e_lfanew;
    fseek(fp, 0x3C, SEEK_SET);
    must_read(&e_lfanew, 4, 1, fp);

    /* 2. "PE\0\0" 署名 */
    fseek(fp, e_lfanew, SEEK_SET);
    char sig[4]; must_read(sig, 1, 4, fp);
    if (memcmp(sig, "PE\0\0", 4) != 0) { fprintf(stderr, "no PE signature\n"); return 1; }

    /* 3. COFF ファイルヘッダ */
    FileHeader fh; must_read(&fh, sizeof fh, 1, fp);
    printf("Machine:          0x%04x\n", fh.Machine);   /* 0x8664 = x86-64 */
    printf("Sections:         %u\n", fh.NumberOfSections);

    /* 4. オプショナルヘッダ（PE32+ の先頭） */
    OptHeader64 oh; must_read(&oh, sizeof oh, 1, fp);
    printf("Magic:            0x%03x %s\n", oh.Magic, oh.Magic == 0x20b ? "(PE32+)" : "");
    printf("ImageBase:        0x%lx\n", (unsigned long)oh.ImageBase);
    printf("EntryPoint (RVA): 0x%x  -> VA 0x%lx\n",
           oh.AddressOfEntryPoint, (unsigned long)(oh.ImageBase + oh.AddressOfEntryPoint));

    /* 5. セクション表: オプショナルヘッダの直後から始まる */
    long sect_off = (long)e_lfanew + 4 + (long)sizeof fh + fh.SizeOfOptionalHeader;
    fseek(fp, sect_off, SEEK_SET);
    printf("\n[Nr] %-9s %-10s %-10s %-10s\n", "Name", "RVA", "VirtSize", "FileOff");
    for (unsigned i = 0; i < fh.NumberOfSections; i++) {
        SectionHeader sh; must_read(&sh, sizeof sh, 1, fp);
        char name[9]; memcpy(name, sh.Name, 8); name[8] = 0;
        printf("[%2u] %-9s 0x%08x 0x%08x 0x%08x\n",
               i, name, sh.VirtualAddress, sh.VirtualSize, sh.PointerToRawData);
    }
    fclose(fp);
    return 0;
}
```

セクション表の開始位置 `sect_off` に注目してください。「`PE\0\0`（4 バイト）＋ COFF ヘッダ＋オプショナルヘッダ」の直後です。オプショナルヘッダのサイズは COFF ヘッダの `SizeOfOptionalHeader` に書いてあるので、自分の構造体の大きさではなくその値を足します ―― こうしておけば、PE32 でも PE32+ でも、ヘッダの版が変わっても正しく次へ進めます。

試す `.exe` は、Linux 上でも **MinGW** クロスコンパイラで作れます。

```
$ x86_64-w64-mingw32-gcc -O0 -o hello.exe hello.c
$ gcc -Wall -Wextra -o minipe minipe.c
$ ./minipe hello.exe
Machine:          0x8664
Sections:         19
Magic:            0x20b (PE32+)
ImageBase:        0x140000000
EntryPoint (RVA): 0x1410  -> VA 0x140001410

[Nr] Name      RVA        VirtSize   FileOff
[ 0] .text     0x00001000 0x00006b78 0x00000600
[ 1] .data     0x00008000 0x000000c0 0x00007200
[ 2] .rdata    0x00009000 0x00000da0 0x00007400
[ 3] .pdata    0x0000a000 0x00000468 0x00008200
[ 4] .xdata    0x0000b000 0x00000514 0x00008800
[ 5] .bss      0x0000c000 0x00000b80 0x00000000
[ 6] .idata    0x0000d000 0x000006d0 0x00008e00
 ...
```

`x86_64-w64-mingw32-objdump -h hello.exe`（Linux で動きます）と見比べれば、値が一致するのが確かめられます。`Machine: 0x8664` は x86-64、`.bss` の `FileOff` が 0 なのは、ELF の `SHT_NOBITS`（[](elf-sections.md)）と同じく「ファイルに実体を持たない」セクションだからです。ELF で書いたツールと、ほとんど同じ形で PE が読めました。

## RVA ―― PE 独特の「相対アドレス」

PE で一番の「考え方の違い」が **RVA（Relative Virtual Address、相対仮想アドレス）** です。ELF のセクションやシンボルは**絶対の仮想アドレス**を持っていました。PE はそうではなく、ほとんどのアドレスを **`ImageBase` からの相対オフセット**で表します。エントリポイントもセクションの位置も、ファイルには「`ImageBase` から何バイト先か」という RVA で書かれていて、実際の仮想アドレスは `ImageBase + RVA` で求めます。

なぜわざわざ相対にするのか。実行ファイルが希望どおりの `ImageBase` に置けるとは限らないからです。ASLR（アドレス空間配置のランダム化）で別の番地に載ったときも、RVA は**そのまま**で、基準アドレスだけがずれます。ELF の PIE が「全体を丸ごとずらす」のと同じ発想を、PE は最初から RVA という形で組み込んでいるわけです。

RVA からファイル内のバイトを取り出すには、ひと手間要ります。「その RVA を含むセクションを探し、`PointerToRawData + (RVA - VirtualAddress)` でファイル位置に直す」のです。セクションの仮想配置（`SectionAlignment`、ふつう 0x1000）とファイル上の配置（`FileAlignment`、ふつう 0x200）が違うため、この変換が必要になります ―― [](handson-loader.md)でローダが `p_offset` と `p_vaddr` を行き来したのと、同じ事情です。

## import と export ―― 動的リンクの PE 流

外部関数（`printf` など）の解決も、考え方は ELF と同じで、表現が違うだけです。PE は **Import Directory** に「どの DLL から、どの関数を借りるか」の一覧を持ち、各関数ぶんの「アドレスを入れる箱」を **IAT（Import Address Table）** に並べます。ローダは起動時に、借りる関数の実アドレスを IAT に書き込みます。コードは関数を直接呼ばず IAT を経由して呼ぶ ―― これは [](elf-loading.md)で見た **GOT** とまったく同じ間接参照の仕組みです。逆に、DLL が「外へ公開する関数」の一覧は **Export Directory**（EAT）に入り、ELF の `.dynsym` に相当します。

## デバッグ情報は外にある ―― PDB と CodeView

最大の違いはデバッグ情報の置き場所です。DWARF は基本的に ELF 本体の `.debug_*` セクションに**同梱**されていました（[](dwarf-overview.md)）。Windows の主流は逆で、デバッグ情報を **PDB という別ファイル**に切り出します。`.exe` 本体には、データディレクトリの **Debug Directory** に「対応する PDB はこれだ」という小さな目印 ―― CodeView の `RSDS` レコード（PDB の GUID と経年番号、ファイル名）―― だけが残ります。デバッガは GUID を鍵に、ローカルや**シンボルサーバ**から一致する PDB を取り寄せ、はじめて関数名や行番号、型を得ます。

これは [](dwarf-limits.md)で触れた **Split DWARF**（`.dwo` に切り出す方式）や、[](elf-beyond.md)の `.note.gnu.build-id`（ビルド ID で別ファイルの debuginfo を引く仕組み）と、まったく同じ発想です。「本体は軽く、重いデバッグ情報は ID で外から引き当てる」 ―― ELF/DWARF の世界にも、PE/PDB の世界にも、同じ知恵が流れています。

PDB の中身（CodeView の型・シンボル・行番号）は DWARF とは別の符号化ですが、表していること ―― アドレスと、関数・型・変数・行を結ぶ ―― は同じです。本書で身につけた「仕様に従ってバイト列を切り分ける」読み方は、海を渡った Windows のバイナリにも、そのまま通用します。
