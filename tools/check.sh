#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
lua_command="${LUA:-}"
luac_command="${LUAC:-}"
lua_ready=false
model_metadata=models/sentence-ngram-mobile.meta.yaml

resolve_command() {
  local value="$1"
  if [[ "$value" == */* ]]; then
    if [[ -x "$value" ]]; then
      printf '%s\n' "$value"
    fi
    return 0
  fi
  command -v "$value" || true
}

resolve_lua54() {
  if [[ "$lua_ready" == true ]]; then
    return
  fi

  if [[ -n "$lua_command" ]]; then
    lua_command="$(resolve_command "$lua_command")"
  else
    local candidate
    for candidate in lua5.4 lua54; do
      lua_command="$(resolve_command "$candidate")"
      if [[ -n "$lua_command" ]]; then
        break
      fi
    done
    if [[ -z "$lua_command" ]] && command -v brew > /dev/null; then
      local formula_prefix
      formula_prefix="$(brew --prefix lua@5.4 2> /dev/null || true)"
      if [[ -x "$formula_prefix/bin/lua" ]]; then
        lua_command="$formula_prefix/bin/lua"
      fi
    fi
    if [[ -z "$lua_command" ]]; then
      lua_command="$(resolve_command lua)"
    fi
  fi

  if [[ -z "$lua_command" ]] || [[ "$("$lua_command" -e 'io.write(_VERSION)')" != "Lua 5.4" ]]; then
    echo "需要 Lua 5.4；可通过 LUA 指定解释器" >&2
    return 1
  fi

  if [[ -n "$luac_command" ]]; then
    luac_command="$(resolve_command "$luac_command")"
  else
    luac_command="${lua_command%/*}/luac"
  fi
  if [[ -z "$luac_command" ]] || [[ ! -x "$luac_command" ]]; then
    echo "缺少与 Lua 5.4 配套的 luac；可通过 LUAC 指定" >&2
    return 1
  fi
  if [[ "$("$luac_command" -v 2>&1)" != Lua\ 5.4.* ]]; then
    echo "LUAC 不是 Lua 5.4：$luac_command" >&2
    return 1
  fi
  lua_ready=true
}

run_format_check() {
  command -v stylua > /dev/null || {
    echo "缺少 stylua" >&2
    return 1
  }
  command -v shfmt > /dev/null || {
    echo "缺少 shfmt" >&2
    return 1
  }
  stylua --check lua tests tools types
  shfmt -d tools/check.sh
}

run_shellcheck() {
  command -v shellcheck > /dev/null || {
    echo "缺少 shellcheck" >&2
    return 1
  }
  shellcheck tools/check.sh
}

run_typecheck() (
  local server="${LUA_LANGUAGE_SERVER:-}"
  if [[ -z "$server" ]]; then
    server="$(command -v lua-language-server || true)"
  fi
  if [[ -z "$server" ]]; then
    echo "缺少 lua-language-server，也可通过 LUA_LANGUAGE_SERVER 指定" >&2
    return 1
  fi

  local check_dir
  check_dir="$(mktemp -d "${TMPDIR:-/tmp}/rime-tiger-luals.XXXXXX")"
  trap 'rm -rf -- "$check_dir"' EXIT
  mkdir "$check_dir/workspace"
  local path
  for path in .luarc.json tests tools types; do
    ln -s "$project_dir/$path" "$check_dir/workspace/$path"
  done
  cp -R lua "$check_dir/workspace/lua"
  resolve_lua54
  "$lua_command" tools/build_data.lua \
    dicts/tiger_sentence.codes.txt dicts/tiger_sentence.char_ranks.txt \
    "$check_dir/workspace/lua/tiger_sentence/data/lexicon.bin" \
    "$check_dir/workspace/lua/tiger_sentence/data/ranks.lua"
  local status=0
  "$server" \
    --check="$check_dir/workspace" \
    --checklevel=Hint \
    --check_format=pretty \
    --logpath="$check_dir/log" \
    --metapath="$check_dir/meta" || status=$?
  return "$status"
)

run_syntax() {
  resolve_lua54
  while IFS= read -r -d '' file; do
    "$luac_command" -p "$file"
  done < <(find lua tests tools types -name '*.lua' -type f -print0)
}

run_model_identity() {
  if [[ ! -f "$model_metadata" ]]; then
    echo "缺少模型元数据：$model_metadata" >&2
    return 1
  fi
  local model_version model_file model_sha256 model_path
  model_version="$(sed -n 's/^version: "\([0-9]\{8\}\)"$/\1/p' "$model_metadata")"
  model_file="$(sed -n 's/^file: "\([A-Za-z0-9._-]*\)"$/\1/p' "$model_metadata")"
  model_sha256="$(sed -n 's/^sha256: "\([0-9a-f]\{64\}\)"$/\1/p' "$model_metadata")"
  if [[ ! "$model_version" =~ ^[0-9]{8}$ ]] || [[ -z "$model_file" ]] \
    || [[ ! "$model_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "模型元数据格式错误：$model_metadata" >&2
    return 1
  fi
  model_path="models/$model_file"
  if [[ ! -f "$model_path" ]]; then
    echo "缺少整句模型：$model_path" >&2
    return 1
  fi
  local actual
  if command -v sha256sum > /dev/null; then
    actual="$(sha256sum "$model_path")"
  elif command -v shasum > /dev/null; then
    actual="$(shasum -a 256 "$model_path")"
  else
    echo "缺少 SHA-256 校验工具" >&2
    return 1
  fi
  actual="${actual%% *}"
  if [[ "$actual" != "$model_sha256" ]]; then
    echo "整句模型 SHA-256 与元数据不一致：$model_path（版本 $model_version）" >&2
    return 1
  fi
}

run_test() (
  resolve_lua54
  # 运行数据仅由公开示例生成，不读取用户白名单、补充文件或部署生成物
  local check_dir path
  check_dir="$(mktemp -d "${TMPDIR:-/tmp}/rime-tiger-test.XXXXXX")"
  trap 'rm -rf -- "$check_dir"' EXIT
  mkdir -p "$check_dir/lua/tiger_sentence/data"
  for path in lua/tiger_sentence/*; do
    if [[ "$path" != lua/tiger_sentence/data ]]; then
      ln -s "$project_dir/$path" "$check_dir/$path"
    fi
  done
  for path in lua/tiger_sentence/data/lexicon.lua dicts models tools \
    tiger_sentence.schema.yaml tiger_sentence.supplement.example.txt \
    tiger_sentence.full_code_whitelist.example.txt; do
    ln -s "$project_dir/$path" "$check_dir/$path"
  done
  ln -s "$project_dir/tiger_sentence.full_code_whitelist.example.txt" "$check_dir/tiger_sentence.full_code_whitelist.txt"
  "$lua_command" tools/build_data.lua \
    dicts/tiger_sentence.codes.txt dicts/tiger_sentence.char_ranks.txt \
    "$check_dir/lua/tiger_sentence/data/lexicon.bin" \
    "$check_dir/lua/tiger_sentence/data/ranks.lua"
  if [[ "${1:-}" == native ]]; then
    "${CXX:-c++}" -std=c++17 -Wall -Wextra tests/rime_symbols.cc -lrime -o "$check_dir/rime_symbols"
    "$check_dir/rime_symbols" "$check_dir" "${RIME_SHARED_DATA_DIR:-/usr/share/rime-data}"
    return
  fi
  if [[ "${1:-}" == benchmark ]]; then
    shift
    "$lua_command" tools/benchmark_mobile_memory.lua "$check_dir" "$@"
    return
  fi
  "$lua_command" tools/benchmark_mobile_memory.lua --self-test
  local suites="quick_symbol symbols no_model supplement whitelist"
  if [[ "${1:-}" != portable ]]; then
    suites="$suites boundaries faults decoder_fast_paths decoder"
  fi
  for path in $suites; do
    "$lua_command" tests/run.lua "tests/$path.lua" "$check_dir"
  done
  if [[ "${1:-}" == portable ]]; then
    return
  fi
  python3 - "$check_dir/errors.tsv" << 'PY'
import re
import sys
from pathlib import Path
covered = {line.split("\t")[0] for line in Path(sys.argv[1]).read_text().splitlines()}
missing = []
for path in [*Path("lua/tiger_sentence").rglob("*.lua"), Path("tools/build_data.lua")]:
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if re.search(r"(?<![\w.:])(?:assert|error)\(", line):
            location = f"{path}:{number}"
            if location not in covered:
                missing.append(location)
if missing:
    sys.exit("缺少错误分支用例：\n" + "\n".join(missing))
PY
  if [[ -n "${ERROR_COVERAGE_FILE:-}" ]]; then
    cp "$check_dir/errors.tsv" "$ERROR_COVERAGE_FILE"
  fi
)

case "${1:-all}" in
  all)
    run_format_check
    run_shellcheck
    run_typecheck
    run_syntax
    run_model_identity
    run_test
    ;;
  format)
    command -v stylua > /dev/null || {
      echo "缺少 stylua" >&2
      exit 1
    }
    command -v shfmt > /dev/null || {
      echo "缺少 shfmt" >&2
      exit 1
    }
    stylua lua tests tools types
    shfmt -w tools/check.sh
    ;;
  format-check)
    run_format_check
    ;;
  typecheck)
    run_typecheck
    ;;
  syntax)
    run_syntax
    ;;
  portable)
    run_syntax
    run_test portable
    ;;
  test)
    run_test
    ;;
  model)
    run_model_identity
    ;;
  benchmark)
    run_test "$@"
    ;;
  native)
    run_test native
    ;;
  comparison)
    resolve_lua54
    shift
    python3 tools/compare.py --lua "$lua_command" "$@"
    ;;
  *)
    echo "用法：tools/check.sh [all|format|format-check|typecheck|syntax|test|portable|native|comparison|model|benchmark 参数…]" >&2
    exit 2
    ;;
esac
