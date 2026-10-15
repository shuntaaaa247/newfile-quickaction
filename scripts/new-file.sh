#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/config.sh"

# 作成するファイルのテンプレート名を取得
TEMPLATE_NAME="${1:-}"
[ -n "$TEMPLATE_NAME" ] || exit 0
shift
[ "$#" -gt 0 ] || exit 0

# Finder で選択されたファイル・フォルダがパッケージ(xxx.app)か判定
is_package() {
  local tree
  tree="$(/usr/bin/mdls -raw -name kMDItemContentTypeTree "$1" 2>/dev/null)" || return 1
  case "$tree" in
    *'"com.apple.package"'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Finder で選択されたファイル・フォルダの情報から、ファイルの作成先を決定
if [ "$#" -eq 1 ]; then
  if [ -d "$1" ] && ! is_package "$1"; then
    dest="$1"               # フォルダ1つ → その中
  else
    dest="$(dirname "$1")"  # ファイル / パッケージ　→ 同じ階層
  fi
else
  dest="$(dirname "$1")"
  shift
  # 複数のファイル・フォルダが選択された時に共通の祖先のディレクトリを探す
  for item in "$@"; do
    p="$(dirname "$item")"
    while [ "$dest" != "/" ] && [ "$p" != "$dest" ] && [ "${p#"$dest"/}" = "$p" ]; do
      dest="$(dirname "$dest")" # $dest は while のループごとに /path/to/dest → /path/to → /path → / と変化する
    done
  done
fi

[ -d "$dest" ] || exit 1

# テンプレート名をベース名と拡張子に分ける(連番を挟む位置を決めるため)
# 最後のドットで切る。先頭のドットは区切りとして扱わない(.gitignore のベース名が空になるため)
base="$TEMPLATE_NAME"
ext=""
case "${TEMPLATE_NAME#.}" in
  *.*) ext=".${TEMPLATE_NAME##*.}"; base="${TEMPLATE_NAME%"$ext"}" ;;
esac

# 同名のファイルがあれば Finder 流に半角スペース + 数字を付ける(2 から始める)。
# 判定は名前の文字列比較ではなくファイルシステムに問い合わせる(日本語が NFD で届くため)。
# -L も見るのは、リンク先が無い symlink を cp の宛先にするとリンク先に書いてしまうため。
# 波括弧で囲むのは、UTF-8 ロケールで変数の直後に全角文字が続くと unbound variable になるため
target="$dest/$TEMPLATE_NAME"
n=2
while [ -e "$target" ] || [ -L "$target" ]; do
  target="$dest/${base} ${n}${ext}"
  n=$((n + 1))
done

# ファイルを作成
/bin/cp "$TEMPLATES_DIR/$TEMPLATE_NAME" "$target"
# 継承したいのはモードだけなので、cp -p ではなく自分で写す。
# -p は作成日(birthtime)まで継承し、それを現在時刻に戻す標準コマンドが存在しないため
# （SetFile は Xcode Command Line Tools が必要）。-p なしなら作成日・変更日は現在になり、
# ロック(uchg)も付かない。cp は umask の影響を受けるが、ここで上書きするので結果は変わらない。
/bin/chmod "$(/usr/bin/stat -f %Lp "$TEMPLATES_DIR/$TEMPLATE_NAME")" "$target"
