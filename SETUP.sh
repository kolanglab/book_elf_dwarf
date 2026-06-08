#!/usr/bin/env bash
#
# GitHub レビュー構成を一括セットアップするスクリプト（初回用）。
# プロジェクトのルート（book.yml のある場所）で実行してください。
#
# 前提:
#   - gh CLI が認証済み:           gh auth login
#   - Claude 用トークンを生成済み:  claude setup-token   (sk-ant-oat01-... を控える)
#
# OWNER / REPO は book.yml の repository から `ligarb setup-github-review` が
# 埋め込みます。値が違う場合は book.yml を直して再度 setup-github-review するか、
# 下の2行を手で書き換えてください。

set -euo pipefail

OWNER="kolanglab"
REPO="book_elf_dwarf"

echo "==> リポジトリ作成 + push（ブランチは master 想定）"
git add -A
git commit -m "Initial book" || true   # 変更が無ければスキップ
gh repo create "$OWNER/$REPO" --public --source=. --remote=origin --push

echo "==> Claude トークンを Secret 登録（プロンプトに sk-ant-oat01-... を貼る）"
gh secret set CLAUDE_CODE_OAUTH_TOKEN

echo "==> GitHub Pages を「GitHub Actions」ソースで有効化"
gh api -X POST "repos/$OWNER/$REPO/pages" -f build_type=workflow \
  || gh api -X PUT "repos/$OWNER/$REPO/pages" -f build_type=workflow

echo "==> Actions に PR 作成権限を付与（Claude が PR を作るのに必要）"
gh api -X PUT "repos/$OWNER/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=true

echo "==> merge 済み PR の head ブランチを自動削除（fix/issue-N が残らないように）"
gh api -X PATCH "repos/$OWNER/$REPO" -F delete_branch_on_merge=true >/dev/null

echo "==> ワークフローが使うラベルを作成（既存なら更新）"
for L in feedback approved needs-triage needs-human answered claude-generated strong-model; do
  gh label create "$L" --force
done

echo
echo "完了。公開先: https://$OWNER.github.io/$REPO/"
echo "クレジット設定などの注意は SETUP.md を確認してください。"