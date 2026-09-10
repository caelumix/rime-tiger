#!/usr/bin/env python3
"""检查运行包目录、公开示例、生成物及重复打包结果"""

import argparse
import os
import runpy
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lua', required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tiger-package-test-') as directory:
        root = Path(directory)
        scratch = root / 'scratch'
        scratch.mkdir()
        environment = dict(os.environ, TMPDIR=str(scratch))
        output = root / 'rime.zip'
        command = [
            'python3',
            str(ROOT / 'tools/package.py'),
            str(output),
            '--lua',
            args.lua,
        ]
        subprocess.run(command, env=environment, check=True)
        first = output.read_bytes()
        with zipfile.ZipFile(output) as archive:
            names = set(archive.namelist())
            expected = {
                'rime/' + str(path.relative_to(ROOT))
                for name in ('dicts', 'lua')
                for path in (ROOT / name).rglob('*')
                if path.is_file()
                and path.suffix != '.bin'
                and path.name != 'ranks.lua'
            }
            expected.update(
                'rime/' + name
                for name in (
                    'default.custom.yaml',
                    'tiger_sentence.schema.yaml',
                    'sentence-ngram-mobile.meta.yaml',
                    'LICENSE',
                    'tiger_sentence.supplement.txt',
                    'tiger_sentence.full_code_whitelist.txt',
                    'lua/tiger_sentence/data/lexicon.bin',
                    'lua/tiger_sentence/data/ranks.lua',
                )
            )
            assert not any(name.startswith('rime/models/') for name in names)
            assert names == expected, names ^ expected
            assert (
                archive.read('rime/lua/tiger_sentence/data/lexicon.bin')[:8]
                == b'TCSLEX04'
            )
            for name in ('supplement', 'full_code_whitelist'):
                assert (
                    archive.read(f'rime/tiger_sentence.{name}.txt')
                    == (
                        ROOT / f'tiger_sentence.{name}.example.txt'
                    ).read_bytes()
                )
        subprocess.run(command, env=environment, check=True)
        assert output.read_bytes() == first, '重复打包结果不同'
        failed = subprocess.run(
            command[:-1] + [str(root / 'missing-lua')],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert failed.returncode != 0 and output.read_bytes() == first
        before = set(root.iterdir())
        with (
            patch.object(sys, 'argv', command[1:]),
            patch.dict(os.environ, environment),
            patch('os.replace', side_effect=OSError('注入的压缩包替换故障')),
        ):
            try:
                runpy.run_path(
                    str(ROOT / 'tools/package.py'), run_name='__main__'
                )
            except OSError as error:
                assert '压缩包替换故障' in str(error)
            else:
                raise AssertionError('替换失败没有传播')
        assert output.read_bytes() == first and set(root.iterdir()) == before
        assert not list(scratch.iterdir()), '打包退出后残留临时文件'
        notes = root / 'release-notes.md'
        subprocess.run(
            [
                'python3',
                str(ROOT / 'tools/release_notes.py'),
                'v1.0.0',
                str(notes),
            ],
            check=True,
        )
        content = notes.read_text()
        assert (
            'v1.0.0' not in content
            and '## 模型' not in content
            and '- Schema：`20260910`' in content
            and '- Dict：`20260904`' in content
            and '- Model：`20260822`' in content
            and 'e3953f8f1526b871eb81fe887a8ae4a6edf79edffd33e388b95e2915adadb2d3'
            in content
        )
        subprocess.run(
            [
                'python3',
                str(ROOT / 'tools/release_notes.py'),
                'v1.0.0',
                str(notes),
                '--model-changed',
            ],
            check=True,
        )
        content = notes.read_text()
        assert (
            '## 模型' in content
            and '- 文件：`sentence-ngram-mobile.bin`' in content
        )
        release_notes = runpy.run_path(str(ROOT / 'tools/release_notes.py'))
        section = release_notes['changelog_section'](
            '# 变更日志\n\n'
            '## 2026-09-13 - v1.1.0\n\n### 新增\n\n- 甲\n\n'
            '## 2026-09-12\n\n### 修复\n\n- 乙\n\n'
            '## 2026-09-10 - v1.0.0\n\n旧版\n',
            'v1.1.0',
        )
        assert section == (
            '### 2026-09-13\n\n#### 新增\n\n- 甲\n\n'
            '### 2026-09-12\n\n#### 修复\n\n- 乙'
        )


if __name__ == '__main__':
    main()
