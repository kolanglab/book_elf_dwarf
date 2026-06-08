# GitHub レビュー構成のセットアップ

このプロジェクトには `ligarb setup-github-review` によって、GitHub 上で本を
公開・レビューするための仕組みが生成されています。`ligarb` を更新したあとに同じコマンドを
再実行すると、足場ファイルが最新テンプレートに**上書き更新**されます（`book.yml` は対象外。
手を入れた箇所は `git diff` で確認してください）。

- 読者は公開された本を読み、気づいた点を **GitHub Issue** で送る。
- Issue をトリガーに GitHub Actions 上で Claude が確認し、修正なら **Pull Request** を、
  疑問なら issue コメントを返す。
- 人間が PR を merge して反映する。

生成されるファイルは「テンプレートのコピー」にすぎません。ligarb 自体は実行時に Claude や
GitHub を呼びません。以下を済ませると、これらのワークフローが動き始めます。

## 生成されるファイル

| ファイル | 役割 | Claude 依存 |
| --- | --- | --- |
| `.github/workflows/deploy-book.yml` | master への push で本をビルドし GitHub Pages に公開 | なし |
| `.github/workflows/build-check.yml` | PR で `ligarb build` が通るかを検証 | なし |
| `.github/ISSUE_TEMPLATE/book-feedback.yml` | 読者向けの構造化フィードバックフォーム | なし |
| `.github/ISSUE_TEMPLATE/config.yml` | Issue チューザの設定（Discussions リンク等） | なし |
| `.github/workflows/claude-feedback.yml` | Issue を Claude が処理し PR/コメントを返す | あり |
| `.github/workflows/claude-pr-mention.yml` | PR コメントに Claude が応答し追加修正をコミット | あり |
| `SETUP.sh` | 下記「C」を一括実行する gh CLI スクリプト | あり |
| `README.md` | 公開ページ（GitHub Pages）へのリンク入りの README（既存があれば保持） | なし |

---

## A. 本を書く（執筆）

1. `book.yml` を編集し、`title` と `author` を設定する。
2. 章を Markdown ファイルで書き、`chapters:` に列挙する（`images/` に画像を置ける）。

   ```yaml
   title: "My Book"
   author: "Your Name"
   chapters:
     - 01-introduction.md
     - 02-getting-started.md
   ```

3. Markdown の記法・`book.yml` の全オプションは `ligarb help` で確認できる
   （AI に読ませる仕様書も兼ねる）。
4. AI に下書きを書かせたい場合は `ligarb write --init` → `ligarb write` も使える。

> `repository:` の設定は次の「C」で GitHub リポジトリ名を決めてから行います
> （読者向け「Report as issue」UI もそこで有効になります）。

## B. ローカルでビルド・プレビュー

```bash
ligarb build                 # build/index.html を生成
```

`build/index.html` をブラウザで開けば確認できます。執筆中は live reload + レビュー UI 付きの
ローカルサーバも使えます（ローカル専用・公開しないこと）:

```bash
ligarb serve                 # http://localhost:3000
```

## C. GitHub に公開・連携する（SETUP.sh で一括）

[GitHub CLI](https://cli.github.com/) を使って、リポジトリ作成から Secret 設定までを
`SETUP.sh` が一括で行います。

```bash
# 前提（先に済ませる）
gh auth login            # gh を認証
claude setup-token       # sk-ant-oat01-... を生成（次のステップで貼る）

# book.yml の repository が正しいか確認（setup-github-review が推測値を入れています）

# 一括実行（プロジェクトのルートで）
bash SETUP.sh
```

`SETUP.sh` がやること:

1. コミットして `gh repo create` でリポジトリを作成 + push（ブランチは master 想定）。
2. `gh secret set CLAUDE_CODE_OAUTH_TOKEN`（プロンプトにトークンを貼る。履歴に残さない）。
3. GitHub Pages を「GitHub Actions」ソースで有効化。
4. Actions に PR 作成権限を付与（Claude が PR を作るのに必要）。
5. ラベルを作成（feedback / approved / needs-triage / needs-human / answered /
   claude-generated / strong-model）。

push すると `deploy-book.yml` が走って Pages に公開され（`https://OWNER.github.io/REPO/`）、
issue を立てると Claude が動き始めます。各コマンドの意味や Web UI での代替は下の「補足」を参照。

> **トークンの取り扱い**: `sk-ant-oat01-...` はパスワード相当のシークレットです。コードや
> コミット、issue、チャットなどに貼らないでください。`gh secret set` のプロンプトに貼るのが
> 安全です。約1年で失効するので、その際は `claude setup-token` で再生成して同じ手順で更新します。

---

## 補足・各設定の意味（Web UI での代替）

gh を使わない場合や、設定の意味を確認したいときの参照です。

### クレジットの扱い（重要）

- 2026/6/15 以降、GitHub Actions 上での Claude 利用は Agent SDK のクレジットから引かれる。
  クレジットは一度オプトインで請求が必要。
- 「追加使用 / usage credits」は **オフのまま**にしておくこと。枯渇時に停止し、
  青天井の課金を防げる。

### GitHub Pages（手順 C-4 の代替）

- 基本的には設定不要。`deploy-book.yml` が初回実行時に Pages を自動で有効化する
  （`configure-pages` の `enablement: true`）。
- 手動で設定する場合は Settings > Pages > Source を **"GitHub Actions"** にする。

### Actions の権限（手順 C-5 の代替）

- Settings > Actions > General で次を有効化する:
  - **Read and write permissions**
  - **Allow GitHub Actions to create and approve pull requests**
- これらが無いと Claude が PR を作成できない。

### ラベルの意味（手順 C-6）

- `feedback` — フィードバック issue
- `approved` — メンテナーが処理を承認した issue
- `needs-triage` — メンバー外の起票（自動処理せず記録のみ）
- `needs-human` — Claude が自信を持てず人手レビューが必要
- `answered` — 疑問に回答済み
- `claude-generated` — Claude が作成した PR（PR 上での自動応答の目印）
- `strong-model` — このラベルが付いた issue / PR では、Claude が強いモデル（opus）で処理する
  （無印は sonnet）。難しい回だけ品質を上げたいときに付ける。

### モデルの選択（strong-model ラベル）

既定では Claude は **sonnet** で動きます。issue や PR に **`strong-model`** ラベルを付けると、
その回だけ **opus** で処理します（教科書の編集には sonnet で十分なことが多く、コストを抑えつつ、
難しい回だけ強いモデルに上げるための仕組み）。

- **メンバー外の issue**: `approved` と一緒に `strong-model` を付ける（承認で起動するため）。
- **自分（メンバー）の issue**: 起票時に `strong-model` を付けておく（起票と同時に走るため）。
- **PR コメントへの応答**: その PR に `strong-model` を付けておく。
- 付け方は Web UI の Labels、または `gh issue edit <番号> --add-label strong-model` /
  `gh pr edit <番号> --add-label strong-model`。
- 将来 opus より強いモデルが出たら、両ワークフローの `'opus'` を新モデル名に差し替えるだけでよい。

### book.yml の `repository:`（手順 C-1）

- `repository: "https://github.com/OWNER/REPO"` を設定すると、公開ページの読者向け
  「Report as issue」UI が有効になる（`ligarb setup-github-review` が
  `github_review.enabled: true` を book.yml に書き込み済み。`repository` 未設定の間は
  build が警告を出して UI 注入をスキップする）。
- これを設定したうえで再度 `ligarb setup-github-review` を実行すると、Issue フォームや
  Discussions リンクのプレースホルダ（`kolanglab` / `book_elf_dwarf`）が実際の値に置換されます
  （足場ファイルは上書き更新されるので、手で直していた箇所は `git diff` で確認を）。

### merge 済みブランチの自動削除（SETUP.sh が設定）

- `gh api -X PATCH repos/OWNER/REPO -F delete_branch_on_merge=true`
  （Web UI なら Settings > General > Pull Requests >
  "Automatically delete head branches"）を有効にすると、PR を merge した時点で
  `fix/issue-N` ブランチが自動削除され、不要なブランチが溜まらない。SETUP.sh で設定済み。

### （任意・推奨）必須チェックの指定

- Settings > Branches で `build-check` を必須チェックに指定すると、
  ビルドが落ちる PR を merge できなくなる。

### claude-code-action の最新仕様の確認

- `anthropics/claude-code-action` はベータで入力仕様が変わりうる。
  初回コミット前に同 action の README で最新の入力名を確認すること。

## ブランチ名について

ワークフローは公開・PR の対象ブランチを `master` と仮定しています。`main` を使う場合は、
`deploy-book.yml` と `build-check.yml` の `branches:` を `main` に変更してください。
