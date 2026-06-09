# ハンズオン(2) ELF をロードして実行する

前のハンズオンでは ELF を**読む**ツールを書きました。今度はもう一歩進んで、ELF を**ロードして実行する**ツールを書きます。つまり、ふだん OS のローダ（とカーネル）がやっている「実行ファイルをメモリに展開し、エントリポイントへ飛ぶ」処理を、自分の手で実装します。[](elf-loading.md)で見た**実行ビュー** ―― プログラムヘッダと `PT_LOAD` セグメント ―― が、ここで実際に動き出します。完成すれば、私たちのプログラムが別の ELF のセグメントを配置し、そのエントリポイントへ制御を渡せるようになります。

## 何をロードするか ―― 自立した実行ファイル

いきなり `/bin/ls` のような普通の実行ファイルをロードしようとすると、話が一気に難しくなります。普通の実行ファイルは**動的リンク**されていて、まず動的リンカ (`ld-linux`) を起動し、共有ライブラリ（libc など）を集め、再配置を解決し、さらに `argc`/`argv`/環境変数/補助ベクタ (auxv) を積んだスタックを用意してやらないと動きません（[](elf-loading.md)で見たとおりです）。

そこで本章では、それらをすべて省ける**自立した（freestanding）**実行ファイルを題材にします。条件は 3 つです。

- **libc を使わない**（`-nostdlib`）。カーネルに直接システムコールで話しかけるので、ライブラリの初期化が要りません。
- **静的リンク**（`-static`）。動的リンカも共有ライブラリも要りません。
- **PIE でない**（`-no-pie`、つまり `ET_EXEC`）。配置先アドレスがファイルに固定で書かれている（典型的には `0x400000` から）ので、その場所へそのまま置くだけで済みます。

ロードされる側の `hello.c` は、`write` と `exit` をシステムコールで直接呼ぶだけの小さなプログラムです。エントリポイント `_start` も自分で書きます。

```c
/* 自立した実行ファイル：libc なし。write と exit をシステムコールで直接呼ぶ。
   ビルド: gcc -nostdlib -static -no-pie -o hello hello.c */
static long sys3(long n, long a, long b, long c) {
    long r;
    __asm__ volatile("syscall" : "=a"(r)
                     : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return r;
}

void _start(void) {
    static const char msg[] = "Hello from a hand-loaded ELF.\n";
    sys3(1, 1, (long)msg, sizeof msg - 1);  /* write(1, msg, len) */
    sys3(60, 42, 0, 0);                      /* exit(42)          */
}
```

`sys3` は、システムコール番号 `n` と 3 つの引数を `syscall` 命令に渡すだけのインラインアセンブリです。x86-64 では番号を `rax`、引数を `rdi`・`rsi`・`rdx` に置く規約なので、それぞれ `"a"`・`"D"`・`"S"`・`"d"` で割り当てています。`_start` は「標準出力へ文字列を書き」「終了コード 42 で終わる」だけ。まずは普通にビルドして、単体で動くことを確かめておきましょう。

```
$ gcc -nostdlib -static -no-pie -o hello hello.c
$ ./hello
Hello from a hand-loaded ELF.
$ echo $?
42
```

この `hello` を、カーネルに頼らず**自分のプログラムから**メモリに展開して走らせる、というのが本章のゴールです。

## ローダの方針

[](elf-loading.md)で、プログラムヘッダはローダへの指示だと述べました。各 `PT_LOAD` セグメントについて、

> ファイルの `p_offset` から `p_filesz` バイトを、メモリの `p_vaddr` に写し取り、`p_memsz` バイト分の領域として `p_flags` の保護属性を付けよ

というものでした。私たちのローダがやることは、まさにこの一文をコードにするだけです。手順は次の 3 ステップになります。

1. ELF ヘッダを読み、本当にロードできる ELF（64 ビットの `ET_EXEC`）かを確かめる。
2. プログラムヘッダテーブルを読み、`PT_LOAD` セグメントを 1 つずつメモリへ配置する。
3. エントリポイント `e_entry` へジャンプする。

ファイル読み込みのヘルパ `must_read` は、前章のミニ readelf と同じものを使います。

```c
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <elf.h>
#include <sys/mman.h>

/* fread の戻り値を必ず確認する小さなヘルパ（前章と同じ） */
static void must_read(void *buf, size_t size, size_t n, FILE *fp) {
    if (fread(buf, size, n, fp) != n) { fprintf(stderr, "read error\n"); exit(1); }
}

/* ページ境界へ切り下げ／切り上げするマクロ */
#define PAGE 4096
#define DOWN(x) ((x) & ~(uintptr_t)(PAGE - 1))
#define UP(x)   DOWN((x) + PAGE - 1)
```

## ステップ1: ELF ヘッダを読んで確かめる

`main` の最初の仕事は、前章とほぼ同じです。ファイルを開き、ELF ヘッダを読み、マジックナンバーとクラスを確認します。ロードするには加えて、これが **`ET_EXEC`（PIE でない実行ファイル）**であることも確かめます。PIE (`ET_DYN`) だと配置先を自分で決める必要があり、話が複雑になるからです。

```c
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s ELF\n", argv[0]); return 1; }
    FILE *fp = fopen(argv[1], "rb");
    if (!fp) { perror("fopen"); return 1; }

    Elf64_Ehdr eh;
    must_read(&eh, sizeof eh, 1, fp);
    if (memcmp(eh.e_ident, ELFMAG, SELFMAG) != 0) {
        fprintf(stderr, "not an ELF file\n"); return 1;
    }
    if (eh.e_type != ET_EXEC) {
        fprintf(stderr, "this loader only handles non-PIE ET_EXEC\n"); return 1;
    }
```

`e_entry`（エントリポイント）と `e_phoff`（プログラムヘッダテーブルの位置）・`e_phnum`（その個数）が、ここから先で使う鍵です。いずれも[](elf-header.md)で説明したフィールドです。

## ステップ2: PT_LOAD セグメントを配置する

プログラムヘッダテーブルを `Elf64_Phdr` の配列として読み込み、`PT_LOAD` のセグメントだけを順に処理します。1 つのセグメントを置くのに必要なのは、`mmap` で領域を確保し、ファイルの中身を写し、保護属性を付ける、という 3 つの操作です。

```c
    /* プログラムヘッダテーブルを読む */
    Elf64_Phdr *ph = malloc((size_t)eh.e_phnum * sizeof *ph);
    fseek(fp, (long)eh.e_phoff, SEEK_SET);
    must_read(ph, sizeof *ph, eh.e_phnum, fp);

    for (unsigned i = 0; i < eh.e_phnum; i++) {
        if (ph[i].p_type != PT_LOAD) continue;       /* 読み込むのは PT_LOAD だけ */

        uintptr_t start = DOWN(ph[i].p_vaddr);                  /* ページ境界に揃える */
        uintptr_t end   = UP(ph[i].p_vaddr + ph[i].p_memsz);

        /* まず書き込み可能で領域を予約する（中身をこれから埋めるため） */
        void *m = mmap((void *)start, end - start, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
        if (m == MAP_FAILED) { perror("mmap"); return 1; }

        /* ファイルの p_filesz バイトを p_vaddr へ写す。
           p_memsz との差（.bss）は、無名ページが初めからゼロなので何もしなくてよい */
        fseek(fp, (long)ph[i].p_offset, SEEK_SET);
        must_read((void *)ph[i].p_vaddr, 1, ph[i].p_filesz, fp);

        /* p_flags から本来の保護属性を決めて付け直す */
        int prot = ((ph[i].p_flags & PF_R) ? PROT_READ  : 0)
                 | ((ph[i].p_flags & PF_W) ? PROT_WRITE : 0)
                 | ((ph[i].p_flags & PF_X) ? PROT_EXEC  : 0);
        if (mprotect((void *)start, end - start, prot) != 0) {
            perror("mprotect"); return 1;
        }
    }
    fclose(fp);
```

ポイントが 3 つあります。

- **`MAP_FIXED` で `p_vaddr` ちょうどに置く。** `ET_EXEC` なのでセグメントの行き先アドレスは固定です。`mmap` に「ここに置け」と指示するのが `MAP_FIXED` です。アドレスはページ境界に揃っている必要があるので、`DOWN`／`UP` で切り下げ・切り上げしています。
- **`.bss` はゼロ埋めしなくてよい。** `p_memsz > p_filesz` の差分が `.bss`（[](elf-sections.md)で見た `SHT_NOBITS`）でした。`MAP_ANONYMOUS` の無名ページは最初からゼロで埋まっているので、`p_filesz` バイトを写すだけで、残りは自動的にゼロになります。
- **保護属性は最後に付け直す。** コードセグメント (`R-X`) は書き込み禁止にしたいのですが、中身を書き込む間は書き込み可能でなければなりません。そこで、いったん `PROT_READ|PROT_WRITE` で確保して中身を写し、そのあと `mprotect` で `p_flags` どおりの権限（コードなら `R-X`）に締め直します。

> [!NOTE]
> 本物のローダは、ここで `mmap` をファイルに直接結びつけ（ファイルバッキング）、ページが初めて触られたときに読み込む**デマンドページング**を使います（[](elf-loading.md)のコラム参照）。本章では仕組みを見えやすくするため、無名ページを確保してから中身を `must_read` で明示的に写しました。やっていることは同じ ―― 「`p_offset` から `p_filesz` を `p_vaddr` へ」です。

## ステップ3: エントリポイントへジャンプする

セグメントがすべて配置できたら、あとは `e_entry` のアドレスを関数ポインタとみなして呼ぶだけです。ロードした `hello` は `exit` システムコールで自分から終了するので、この呼び出しから戻ってくることはありません。

```c
    /* エントリポイントへ制御を渡す */
    void (*entry)(void) = (void (*)(void))eh.e_entry;
    entry();
    return 0;   /* 自立したプログラムは自分で exit するので、ここには戻らない */
}
```

> [!IMPORTANT]
> ローダ自身は **PIE でビルドする**必要があります（最近の gcc は既定で PIE です）。ローダが PIE なら、OS はそれを高位のアドレスへ配置するので、`0x400000` 付近 ―― ロードする `hello` が使いたい番地 ―― が空いたままになります。もしローダも `-no-pie` でビルドすると、ローダ自身が `0x400000` に載ってしまい、`MAP_FIXED` でそこを上書きした瞬間に自分のコードを壊して落ちます。

## 動かして確かめる

ローダをコンパイルして、先ほどの `hello` を食わせてみましょう。

```
$ gcc -Wall -Wextra -o miniloader miniloader.c
$ ./miniloader hello
Hello from a hand-loaded ELF.
$ echo $?
42
```

`hello` を直接実行したときと同じ出力・同じ終了コードが得られました。私たちのプログラムが、ELF のプログラムヘッダを読み、`PT_LOAD` セグメントをメモリに配置し、エントリポイントへ飛んだ ―― カーネルのローダがやっていることの核心を、自分の手で再現できたわけです。

> [!TIP]
> `strace ./miniloader hello` を眺めると、自分が出した `mmap`・`mprotect` のシステムコールが、`p_vaddr` と保護属性どおりに並んでいるのが見えます。`readelf -l hello` のセグメント一覧と見比べると、「プログラムヘッダ 1 行」と「`mmap` 1 回」がきれいに対応していることが確認できます。

## ここで省いたこと

このミニローダは、ロードの**核心**だけを取り出したものです。本物のローダ（とカーネル、動的リンカ）は、さらに次のことをやっています。いずれも[](elf-loading.md)で触れた話です。

- **動的リンク。** 普通の実行ファイルは `PT_INTERP` で動的リンカを指名し、共有ライブラリを集めて、PLT/GOT を通じて外部関数のアドレスを解決します。
- **スタックの準備。** カーネルは制御を渡す前に、`argc`・`argv`・環境変数・補助ベクタ (auxv) をスタックに積みます。libc の `_start` はそこから情報を取り出して `main` を呼びます。だから本章の `hello` は、スタックの中身に依存しない自立したコードにしておく必要がありました。
- **PIE と ASLR。** PIE 実行ファイルは配置先が固定でないので、ローダが基準アドレスを（しばしば乱数で）決め、その分だけずらして配置します。

つまり本章で作ったのは「動的リンクなし・固定アドレス・スタック設定なし」という、ロードのもっとも素朴な形です。その素朴な形の中に、`PT_LOAD` を写してエントリへ飛ぶという、すべてのローダに共通する骨格がありました。

次のハンズオンでは、視点をふたたび DWARF に戻します。`.debug_line` を実際に解釈し、機械語アドレスからソースの行番号を求める ―― `addr2line` の核心を実装します。
