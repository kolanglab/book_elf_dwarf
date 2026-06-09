# ハンズオン(1) ミニ readelf を作る

最初のハンズオンは、ELF ファイルを開いて、ヘッダとセクション一覧を表示する小さなプログラムです。`readelf -h -S` の核心部分にあたります。第 I 部で学んだ「ELF ヘッダを読めば 2 つのテーブルの場所が分かり、セクションヘッダを配列として読めばセクション一覧が得られる」という流れを、そのままコードにします。完成すると、第 3 章・第 4 章の内容が確かに正しかったことを、自分のマシンで確認できます。

## elf.h を使う

Linux には、ELF の構造体定義をまとめた標準ヘッダ `<elf.h>` があります。第 3 章・第 4 章で C の構造体として示した `Elf64_Ehdr` や `Elf64_Shdr`、そして `ELFMAG`・`ELFCLASS64`・`EI_CLASS` といった定数は、すべてこのヘッダで定義されています。自分で構造体を書き写してもよいのですが、せっかく標準で用意されているので、これを使います。本書でフィールド名として説明してきたものが、そのまま実在のコードで使えることを確かめる意味もあります。

> [!NOTE]
> `<elf.h>` を使うと、本書で学んだ名前 ―― `e_shoff`、`sh_name`、`e_shstrndx` など ―― が、コンパイラの型チェックを受けながらそのまま書けます。フィールドのバイト位置やサイズは構造体定義に織り込まれているので、自分でオフセット計算をする必要はありません。「仕様書の構造体」と「実際のヘッダ」が一致していることが、コードが動くことで裏付けられます。

## 入出力の安全な部品

本題に入る前に、小さな部品を 1 つ用意します。ファイルからの読み込みに使う `fread` は、読めたデータの個数を返します。要求した個数が読めなかった場合（ファイルが壊れている・途中で切れているなど）を見逃すとバグの温床になるので、必ず確認するヘルパにまとめておきます。

```c
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <elf.h>

/* fread の戻り値を必ず確認する小さなヘルパ */
static void must_read(void *buf, size_t size, size_t n, FILE *fp) {
    if (fread(buf, size, n, fp) != n) { fprintf(stderr, "read error\n"); exit(1); }
}
```

以降、ファイルからの読み込みはすべてこの `must_read` を通します。これで「読めたつもりで実は読めていなかった」という事故を防げます。

## ステップ1: ELF ヘッダを読んで検証する

`main` の最初の仕事は、ファイルを開き、先頭 64 バイトを `Elf64_Ehdr` として読み込み、それが本当に 64 ビット ELF かを確かめることです。

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
    if (eh.e_ident[EI_CLASS] != ELFCLASS64) {
        fprintf(stderr, "only ELF64 is supported here\n"); return 1;
    }
```

`memcmp(eh.e_ident, ELFMAG, SELFMAG)` が、第 3 章のマジックナンバー検査です。`ELFMAG` は `"\x7fELF"`、`SELFMAG` はその長さ 4 です。先頭 4 バイトが一致しなければ ELF ではないと判断します。続いて `eh.e_ident[EI_CLASS]` を見て、64 ビット (`ELFCLASS64`) でなければ、ここでは扱わないことにします。これらは第 3 章の `e_ident` の説明そのものです。

ヘッダが読めれば、主要フィールドはもう手に入っています。表示してみましょう。

```c
    printf("Type:           %u\n", eh.e_type);
    printf("Machine:        %u\n", eh.e_machine);
    printf("Entry point:    0x%lx\n", (unsigned long)eh.e_entry);
    printf("Section count:  %u (table at offset %lu)\n",
           eh.e_shnum, (unsigned long)eh.e_shoff);
```

`e_type`・`e_machine`・`e_entry`・`e_shnum`・`e_shoff` は、いずれも第 3 章で意味を説明したフィールドです。とりわけ `e_shoff`（セクションヘッダテーブルのオフセット）と `e_shnum`（その個数）が、次のステップへの鍵になります。

## ステップ2: セクションヘッダテーブルを配列として読む

ELF ヘッダから `e_shoff` と `e_shnum` が分かったので、第 4 章で述べたとおり、その位置からセクションヘッダを「`Elf64_Shdr` の配列」として読めます。

```c
    /* セクションヘッダテーブルをまるごと読む */
    Elf64_Shdr *sh = malloc((size_t)eh.e_shnum * sizeof *sh);
    fseek(fp, (long)eh.e_shoff, SEEK_SET);
    must_read(sh, sizeof *sh, eh.e_shnum, fp);
```

`fseek` でファイル位置を `e_shoff` へ移動し、そこから `e_shnum` 個分の `Elf64_Shdr` を一気に読み込みます。これで `sh[i]` が i 番目のセクションのヘッダになりました。第 3 章で「i 番目のセクションヘッダは `e_shoff + i * e_shentsize` から」と式で説明したことを、配列読み込みという形で実現しているわけです。

## ステップ3: セクション名を解決する

セクションヘッダの `sh_name` は文字列そのものではなく、`.shstrtab`（セクション名文字列表）へのオフセットでした。`.shstrtab` が何番セクションかは、ELF ヘッダの `e_shstrndx` に書かれています。そこで、その番号のセクション本体を読み込んでおきます。

```c
    /* セクション名の文字列表 .shstrtab を読む */
    Elf64_Shdr *shstr = &sh[eh.e_shstrndx];
    char *names = malloc(shstr->sh_size);
    fseek(fp, (long)shstr->sh_offset, SEEK_SET);
    must_read(names, 1, shstr->sh_size, fp);
```

`sh[eh.e_shstrndx]` が `.shstrtab` のヘッダで、その `sh_offset` から `sh_size` バイトを読めば、ヌル終端文字列が連結された文字列表の本体が `names` に入ります。ここまでが、第 4 章「文字列テーブルとセクション名の解決」で説明した 3 ステップの手順そのものです。

あとは各セクションについて、`sh[i].sh_name` を `names` のインデックスとして使えば、名前文字列が `&names[sh[i].sh_name]` で得られます。これが「オフセットから始めてヌル文字までを読む」文字列表の使い方です。

```c
    printf("\n[Nr] %-18s %-10s %-18s %-8s\n",
           "Name", "Type", "Address", "Size");
    for (unsigned i = 0; i < eh.e_shnum; i++) {
        printf("[%2u] %-18s %-10u 0x%016lx %lu\n",
               i, &names[sh[i].sh_name], sh[i].sh_type,
               (unsigned long)sh[i].sh_addr,
               (unsigned long)sh[i].sh_size);
    }

    free(names); free(sh); fclose(fp);
    return 0;
}
```

これで完成です。全体でも 50 行ほど。第 I 部の知識だけで、ELF の骨格を読み出すツールが書けました。

## 動かして確かめる

コンパイルして、適当な実行ファイルに対して動かしてみましょう。ここでは、小さな `sample`（`gcc -g -gdwarf-5 -O0 -no-pie -o sample sample.c` でビルドしたもの）を対象にします。

```
$ gcc -Wall -Wextra -o minireadelf minireadelf.c
$ ./minireadelf sample
Type:           2
Machine:        62
Entry point:    0x401050
Section count:  37 (table at offset 14872)

[Nr] Name               Type       Address            Size
[ 0]                    0          0x0000000000000000 0
[12] .init              1          0x0000000000401000 27
[15] .text              1          0x0000000000401050 322
[25] .data              1          0x0000000000404008 16
[26] .bss               8          0x0000000000404018 8
[29] .debug_info        1          0x0000000000000000 257
[31] .debug_line        1          0x0000000000000000 108
[36] .shstrtab          3          0x0000000000000000 367
```

この出力には、本書でこれまで説明してきたことが、すべて具体的な数値として現れています。確認してみましょう。

- `Type: 2` は `ET_EXEC`。`-no-pie` でビルドしたので、PIE ではなく固定アドレスの実行ファイルです（第 3 章）。
- `Machine: 62` は `EM_X86_64`、つまり x86-64 です（第 3 章）。
- `[ 0]` 番セクションは名前も中身も空。常に `SHT_NULL` でした（第 4 章）。
- `.text` の `Type: 1` は `SHT_PROGBITS`、`.bss` の `Type: 8` は `SHT_NOBITS` です。`.bss` はファイル上に実体を持たないのに `Size` が 8 ある ―― まさに第 4 章で説明した「サイズだけ記録される」セクションです。
- `.debug_info` や `.debug_line` の `Address` が 0 になっています。これらは DWARF のセクションで、`SHF_ALLOC` が立たず実行時メモリに置かれないので、仮想アドレスを持ちません（第 8 章）。第 II 部で予告したとおりです。

> [!TIP]
> 自分のマシンの `/bin/ls` や、`-no-pie` を付けずにビルドした実行ファイルにも試してみてください。後者は `Type: 3`（`ET_DYN` = PIE）になり、`.text` などの `Address` が 0 から始まる相対的な値になっているはずです。第 3 章の PIE の話が、目の前のバイナリで再現されます。`readelf -h -S` の出力と見比べれば、自作ツールが同じ情報を取り出せていることも確認できます。

ELF を読むツールが書けました。ここで書いた「ELF ヘッダとプログラム／セクションヘッダを配列として読む」骨格は、続くハンズオンでそのまま土台になります。次章ではまず、いま読み取った**プログラムヘッダ**を使って、ELF を実際にメモリへ展開し実行する ―― つまり OS のローダがやっていることを自分の手で再現します。いよいよ ELF を「動かし」ます。
