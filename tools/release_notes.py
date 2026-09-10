#!/usr/bin/env python3
"""生成包含变更日志和模型身份的 Release 说明"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


VERSION = re.compile(r'v\d+\.\d+\.\d+')
HEADING = re.compile(r'^(#{1,6}) ')


def heading_version(line):
    """返回标题行中的版本号，没有时返回 None"""
    match = VERSION.search(line)
    return match.group() if match else None


def changelog_section(changelog, release_version):
    """提取从 release_version 到上一个版本之间的全部条目"""
    lines = changelog.splitlines()
    start = next(
        (
            i
            for i, line in enumerate(lines)
            if line.startswith('## ')
            and heading_version(line) == release_version
        ),
        None,
    )
    if start is None:
        raise ValueError(f'CHANGELOG 缺少版本 {release_version}')
    end = next(
        (
            j
            for j in range(start + 1, len(lines))
            if lines[j].startswith('## ') and heading_version(lines[j])
        ),
        len(lines),
    )
    section = []
    for offset, line in enumerate(lines[start:end]):
        if offset == 0:
            remainder = VERSION.sub('', line).lstrip('#').strip(' -')
            if remainder:
                section.append(f'### {remainder}')
            continue
        heading = HEADING.match(line)
        if heading is not None:
            depth = len(heading.group(1)) + 1
            section.append('#' * depth + line[heading.end() - 1 :])
        else:
            section.append(line)
    return '\n'.join(section).strip()


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit('用法：tools/release_notes.py 发布版本 [输出文件]')
    release_version = sys.argv[1]
    changelog = (ROOT / 'CHANGELOG.md').read_text()
    schema = (ROOT / 'tiger_sentence.schema.yaml').read_text()
    dictionary = (ROOT / 'dicts/tiger_sentence.codes.txt').read_text()
    metadata = (ROOT / 'models/sentence-ngram-mobile.meta.yaml').read_text()
    try:
        changes = changelog_section(changelog, release_version)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    schema_version = re.search(r'^  version: "(\d{8})"$', schema, re.MULTILINE)
    dict_version = re.search(
        r'^# version: "(\d{8})"$', dictionary, re.MULTILINE
    )
    model_version = re.search(r'^version: "(\d{8})"$', metadata, re.MULTILINE)
    filename = re.search(r'^file: "([A-Za-z0-9._-]+)"$', metadata, re.MULTILINE)
    digest = re.search(r'^sha256: "([0-9a-f]{64})"$', metadata, re.MULTILINE)
    if not schema_version or not dict_version or not model_version:
        raise SystemExit('版本信息格式错误')
    if not filename or not digest:
        raise SystemExit('模型元数据格式错误')
    output = (
        '## 版本\n\n'
        f'- Schema：`{schema_version.group(1)}`\n'
        f'- Dict：`{dict_version.group(1)}`\n'
        f'- Model：`{model_version.group(1)}`\n'
        f'- 模型 SHA-256：`{digest.group(1)}`\n\n'
        '## 变更\n\n'
        f'{changes}\n'
    )
    output += (
        '\n## 模型\n\n'
        f'- 文件：`{filename.group(1)}`\n'
        '- 模型二进制需单独上传到此 Release\n'
    )
    if len(sys.argv) == 3:
        Path(sys.argv[2]).write_text(output)
    else:
        sys.stdout.write(output)


if __name__ == '__main__':
    main()
