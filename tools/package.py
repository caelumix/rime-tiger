#!/usr/bin/env python3
"""用公开源数据构建 rime 运行包，临时文件在退出时清理"""

import argparse
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='输出 ZIP 文件')
    parser.add_argument('--lua', default='lua5.4', help='Lua 5.4 解释器')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tiger-package-') as directory:
        staging = Path(directory) / 'rime'
        staging.mkdir()
        for name in ('dicts', 'lua'):
            shutil.copytree(
                ROOT / name,
                staging / name,
                ignore=shutil.ignore_patterns(
                    '*.bin', 'ranks.lua', '__pycache__'
                ),
            )
        for name in (
            'default.custom.yaml',
            'tiger_sentence.schema.yaml',
            'LICENSE',
        ):
            shutil.copyfile(ROOT / name, staging / name)
        (staging / 'models').mkdir()
        shutil.copyfile(
            ROOT / 'models/sentence-ngram-mobile.meta.yaml',
            staging / 'models/sentence-ngram-mobile.meta.yaml',
        )
        for name in ('supplement', 'full_code_whitelist'):
            shutil.copyfile(
                ROOT / f'tiger_sentence.{name}.example.txt',
                staging / f'tiger_sentence.{name}.txt',
            )
        subprocess.run(
            [
                args.lua,
                ROOT / 'tools/build_data.lua',
                ROOT / 'dicts/tiger_sentence.codes.txt',
                ROOT / 'dicts/tiger_sentence.char_ranks.txt',
                staging / 'lua/tiger_sentence/data/lexicon.bin',
                staging / 'lua/tiger_sentence/data/ranks.lua',
            ],
            check=True,
        )
        archive_path = Path(directory) / 'rime.zip'
        with zipfile.ZipFile(
            archive_path, 'w', compression=zipfile.ZIP_DEFLATED
        ) as archive:
            for path in sorted(staging.rglob('*')):
                if path.is_file():
                    entry = zipfile.ZipInfo(
                        path.relative_to(staging.parent).as_posix()
                    )
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    entry.external_attr = 0o100644 << 16
                    archive.writestr(entry, path.read_bytes())
        args.output.parent.mkdir(parents=True, exist_ok=True)
        # 输出替换使用同目录临时文件，失败时保留已有压缩包
        with tempfile.NamedTemporaryFile(
            dir=args.output.parent, delete=False
        ) as output:
            temporary = Path(output.name)
        try:
            shutil.copyfile(archive_path, temporary)
            os.replace(temporary, args.output)
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
