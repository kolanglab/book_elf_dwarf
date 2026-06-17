# Apple の実行ファイル形式 Mach-O

[](introduction.md)で見たとおり、Apple（macOS、iOS など）は「Unix なのに ELF でない」例外で、**Mach-O（Mach Object）** という形式を使います。前のおまけで読んだ Windows の PE と並ぶ、もう一つの「ELF でない世界」です。ただし Apple のデバッグ情報は（ここが面白いところで）**DWARF** です（後述の `.dSYM` に収めます）。だから本書で学んだ DWARF の読み方は、海を渡った Apple のバイナリにもそのまま効きます。

PE のときと同じく、ELF の言葉で Mach-O を読み解き、最後に本物の Mach-O ファイルを自作のツールで覗きます。

## ELF と Mach-O の対応

まず対応表です。多くは ELF と素直に対応しますが、ひとつだけ**発想が違う**ところがあります（太字）。

| はたらき | ELF | Mach-O |
|---|---|---|
| 入口のマジック | `7f 45 4c 46` | `feedfacf`（64 ビット） |
| ファイル全体の素性 | ELF ヘッダ（[](elf-header.md)） | mach header |
| **構造の並べ方** | **固定のヘッダ表**（`e_phoff`/`e_shoff`） | **ロードコマンドの列** |
| 実行時の配置単位 | セグメント（[](elf-loading.md)） | `LC_SEGMENT_64`（`__TEXT`/`__DATA`/`__LINKEDIT`） |
| リンク時の区分け | セクション（[](elf-sections.md)） | セクション（二段名 `__TEXT,__text`） |
| シンボル表 | `.symtab`（[](elf-symbols.md)） | `LC_SYMTAB` |
| エントリ | `e_entry` | `LC_MAIN` の `entryoff` |
| 依存ライブラリ | `.dynamic` の `DT_NEEDED` | `LC_LOAD_DYLIB` |
| ビルド ID | `.note.gnu.build-id`（[](elf-beyond.md)） | `LC_UUID` |
| デバッグ情報 | DWARF（本体に同梱） | DWARF（`.dSYM` に別置き） |

## ロードコマンドという発想

ELF は、ヘッダの決まった位置に「プログラムヘッダ表はここ（`e_phoff`）」「セクションヘッダ表はここ（`e_shoff`）」と**固定のオフセット表**を持っていました。Mach-O はこれを、**ロードコマンドの列**という別の形で表します。mach header の直後に、`(コマンド種別 cmd, このコマンドのバイト数 cmdsize)` で始まる可変長のコマンドが `ncmds` 個ずらりと並ぶのです。`LC_SEGMENT_64`（セグメントを 1 つ載せよ）、`LC_SYMTAB`（シンボル表はここ）、`LC_LOAD_DYLIB`（この dylib を読め）、`LC_MAIN`（ここから実行を始めよ）…… ローダはこの列を上から順に実行していきます。

この設計の利点は**拡張性**です。新しい種類の情報を足したくなったら、新しいコマンド種別を 1 つ増やすだけ。古いツールは、知らないコマンドに出会っても **`cmdsize` の分だけ読み飛ばせばよい**ので壊れません。ELF が「表の種類が増えるたびにヘッダの取り決めを増やす」のに対し、Mach-O は「自己記述的なコマンドの列」で同じことを柔軟にこなす、というわけです。

## ミニ Mach-O リーダのハンズオン

[](handson-elf.md)のミニ readelf の Mach-O 版を作ります。やることは、mach header を読み、ロードコマンドの列を `cmdsize` をたどって歩き、セグメントとセクション、シンボル表を表示するだけです。いわば「ミニ `otool -hl`」です。

```c
/* mini Mach-O reader: ミニ readelf の Apple 版。mach header とロードコマンド列を読む。
   ビルド: gcc -Wall -Wextra -o minimacho minimacho.c */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define MH_MAGIC_64   0xfeedfacf
#define LC_SEGMENT_64 0x19
#define LC_SYMTAB     0x02
#define LC_LOAD_DYLIB 0x0c
#define LC_UUID       0x1b
#define LC_MAIN       0x80000028

struct mach_header_64 {
    uint32_t magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved;
};
struct segment_command_64 {
    uint32_t cmd, cmdsize; char segname[16];
    uint64_t vmaddr, vmsize, fileoff, filesize;
    uint32_t maxprot, initprot, nsects, flags;
};
struct section_64 {
    char sectname[16], segname[16];
    uint64_t addr, size;
    uint32_t offset, align, reloff, nreloc, flags, reserved1, reserved2, reserved3;
};
struct symtab_command { uint32_t cmd, cmdsize, symoff, nsyms, stroff, strsize; };

static const char *filetype_name(uint32_t t) {
    switch (t) { case 1: return "MH_OBJECT"; case 2: return "MH_EXECUTE";
                 case 6: return "MH_DYLIB"; default: return "?"; }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s MACHO\n", argv[0]); return 1; }
    FILE *fp = fopen(argv[1], "rb");
    if (!fp) { perror("fopen"); return 1; }
    fseek(fp, 0, SEEK_END); long sz = ftell(fp); fseek(fp, 0, SEEK_SET);
    uint8_t *buf = malloc(sz);
    if (fread(buf, 1, sz, fp) != (size_t)sz) { fprintf(stderr, "read error\n"); return 1; }
    fclose(fp);

    struct mach_header_64 *mh = (void *)buf;
    if (mh->magic != MH_MAGIC_64) {
        fprintf(stderr, "not a 64-bit Mach-O (magic 0x%x)\n", mh->magic); return 1;
    }
    printf("magic:    0x%x (64-bit Mach-O)\n", mh->magic);
    printf("cputype:  0x%x %s\n", mh->cputype,
           mh->cputype == 0x01000007 ? "(x86-64)" :
           mh->cputype == 0x0100000c ? "(arm64)" : "");
    printf("filetype: %u (%s)\n", mh->filetype, filetype_name(mh->filetype));
    printf("ncmds:    %u\n\n", mh->ncmds);

    /* mach header（32 バイト）の直後から、ロードコマンドを順にたどる */
    uint8_t *p = buf + sizeof *mh;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command { uint32_t cmd, cmdsize; } *lc = (void *)p;
        switch (lc->cmd) {
        case LC_SEGMENT_64: {
            struct segment_command_64 *sg = (void *)p;
            char seg[17]; memcpy(seg, sg->segname, 16); seg[16] = 0;
            printf("LC_SEGMENT_64  \"%s\"  (%u sections)\n", seg, sg->nsects);
            struct section_64 *sec = (void *)(sg + 1);   /* セクションはセグメントコマンドの直後 */
            for (uint32_t s = 0; s < sg->nsects; s++) {
                char sn[17], sgn[17];
                memcpy(sn, sec[s].sectname, 16); sn[16] = 0;
                memcpy(sgn, sec[s].segname, 16); sgn[16] = 0;
                printf("    %-10s,%-10s addr=0x%lx size=%lu offset=%u\n",
                       sgn, sn, (unsigned long)sec[s].addr,
                       (unsigned long)sec[s].size, sec[s].offset);
            }
            break;
        }
        case LC_SYMTAB: {
            struct symtab_command *st = (void *)p;
            printf("LC_SYMTAB      (%u symbols)\n", st->nsyms);
            break;
        }
        case LC_LOAD_DYLIB: printf("LC_LOAD_DYLIB\n"); break;
        case LC_UUID:       printf("LC_UUID\n"); break;
        case LC_MAIN:       printf("LC_MAIN\n"); break;
        default:            printf("(load command 0x%x)\n", lc->cmd); break;   /* 知らないものは飛ばす */
        }
        p += lc->cmdsize;
    }
    printf("\nwalked %ld bytes of load commands (sizeofcmds=%u)\n",
           (long)(p - (buf + sizeof *mh)), mh->sizeofcmds);
    free(buf);
    return 0;
}
```

試す Mach-O は、Linux 上でも **clang** で作れます。実行ファイルにするには Apple のリンカが要りますが、**オブジェクトファイル（`.o`）**なら `-c` で生成できます。次の小さなソースを Mach-O オブジェクトにして読ませてみます。

```c
const char *greeting = "hi from Mach-O";
int counter;
int answer(void) { return counter + 42; }
```

```
$ clang -c -target x86_64-apple-macos11 -o sample.o sample.c
$ gcc -Wall -Wextra -o minimacho minimacho.c
$ ./minimacho sample.o
magic:    0xfeedfacf (64-bit Mach-O)
cputype:  0x1000007 (x86-64)
filetype: 1 (MH_OBJECT)
ncmds:    4

LC_SEGMENT_64  ""  (6 sections)
    __TEXT    ,__text     addr=0x0 size=15 offset=712
    __TEXT    ,__cstring  addr=0xf size=15 offset=727
    __DATA    ,__data     addr=0x20 size=8 offset=744
    __DATA    ,__common   addr=0x88 size=4 offset=0
    __LD      ,__compact_unwind addr=0x28 size=32 offset=752
    __TEXT    ,__eh_frame addr=0x48 size=64 offset=784
(load command 0x32)
LC_SYMTAB      (3 symbols)
(load command 0xb)

walked 680 bytes of load commands (sizeofcmds=680)
```

読み取れたことを確かめましょう。`__text` は `answer` のコード（15 バイト）、`__cstring` は文字列 `"hi from Mach-O"`（14 文字 ＋ ヌル終端 ＝ 15 バイト）、`__data` は `greeting` ポインタ（8 バイト）、`__common` は `counter`（4 バイト、`offset=0` で、ELF の `.bss`（[](elf-sections.md)）と同じくファイルに実体を持ちません）。`LC_SYMTAB` は 3 シンボル（`greeting`、`counter`、`answer`）。知らないコマンド `0x32`（`LC_BUILD_VERSION`）や `0xb`（`LC_DYSYMTAB`）は `cmdsize` ぶん読み飛ばしています。

最後の一行に注目してください。**歩いたバイト数が `sizeofcmds` とぴったり一致**しています。これは「すべてのロードコマンドを `cmdsize` どおりに正しくたどれた」という何よりの証拠です。`(cmd, cmdsize)` という自己記述の列だからこそ、知らないコマンドがあっても列の途中で迷子になりません。これがロードコマンド方式の強みです。

> [!NOTE]
> ここで読んだのは**オブジェクトファイル**（`MH_OBJECT`）です。実行ファイル（`MH_EXECUTE`）では、`LC_MAIN`（エントリ）や、`__TEXT`、`__DATA`、`__LINKEDIT` という**名前付きセグメント**、依存 dylib を挙げる `LC_LOAD_DYLIB` などが加わりますが、読み方は同じで、ロードコマンドの列をたどるだけです。`__LINKEDIT` セグメントには、シンボル表、文字列表、dyld 用の情報（動的リンクの実体）がまとめて置かれます。

## 一つのファイルに複数の CPU を収めるファットバイナリ

Mach-O 独特の仕掛けに**ファットバイナリ**（universal binary、Apple の言葉では「ユニバーサル」）があります。これは、x86-64 用と arm64 用など、**複数アーキテクチャの Mach-O を 1 つのファイルに束ねた**もので、先頭に `0xcafebabe` で始まる fat header が「どの CPU 版がファイルのどこにあるか」を示します。OS は実行時に自分の CPU に合う版を選びます。Intel から Apple Silicon への移行を、利用者に意識させず進められたのはこの仕組みのおかげです。ELF には標準では相当物がなく、「1 ファイル 1 アーキテクチャ」が原則です。ここは Mach-O の個性です。

## デバッグ情報は `.dSYM` に

Apple も Windows と同じく、デバッグ情報を**本体から切り離す**流儀です。ただし中身は **DWARF**（本書で読んできたもの）です。コンパイル時、DWARF は各 `.o` に入りますが、リンク時に実行ファイルへは取り込まれず、実行ファイルのシンボル表に「どの `.o` を見ればよいか」の地図（デバッグマップ）だけが残ります。`dsymutil` がその地図をたどって DWARF を集め、`.dSYM` バンドル（中身は `__DWARF` セグメントを持つ Mach-O）にまとめます。実行ファイルとは `LC_UUID` で対応づけられ、デバッガは UUID を鍵に一致する `.dSYM` を探します。

これは [](introduction.md)で触れたとおり、ELF/DWARF 側の `.note.gnu.build-id`（[](elf-beyond.md)）や Split DWARF（[](dwarf-limits.md)）と**まったく同じ発想**です。容れ物が ELF、PE、Mach-O のどれであっても、「本体は軽く、重いデバッグ情報は ID で外から引き当てる」という知恵は共通しています。そして Apple の場合、その外に置かれた中身は DWARF そのものであり、本書の読み方がそっくり通用します。

三つの容れ物（ELF、PE、Mach-O）を見比べてきました。名前も細部も違いますが、「マジックから入り、ヘッダで素性を知り、セグメントやセクションをたどり、シンボルと再配置で名前をアドレスに結ぶ」という骨格は、どれも同じでした。バイナリの世界は、国境を越えても「仕様という約束に従って切り分ければ読める」のです。
