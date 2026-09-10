#!/usr/bin/env python3
"""固定公开数据，仅比较词典存储方式；生成物随临时目录清理"""

import argparse
import json
import statistics
import struct
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
from compare import ROOT, corpus, prepare, replace, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lua', required=True, help='Lua 5.4 解释器')
    parser.add_argument(
        '--whitelist', action='store_true', help='仅比较白名单固化与运行时读取'
    )
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tiger-lexicon-') as directory:
        root = Path(directory) / 'current'
        prepare(root, ROOT, args.lua)
        corpus_path = Path(directory) / 'corpus.txt'
        corpus_path.write_text('\n'.join(corpus()) + '\n')
        alternate = None
        comparison = 'text'
        if args.whitelist:
            comparison = 'baked_whitelist'
            alternate = Path(directory) / 'baked-whitelist'
            prepare(alternate, ROOT, args.lua)
            path = alternate / 'lua/tiger_sentence/data/lexicon.bin'
            data = bytearray(path.read_bytes())
            whitelist = set()
            for line in (
                (alternate / 'tiger_sentence.full_code_whitelist.txt')
                .read_text()
                .splitlines()
            ):
                line = line.strip()
                if line and not line.startswith('#'):
                    whitelist.update(line)
            count = struct.unpack_from('<I', data, 20)[0]
            width = struct.unpack_from('<I', data, 28)[0]
            offset = 32 + count * (width + 6)
            while offset < len(data):
                length = struct.unpack_from('<H', data, offset + 2)[0]
                value = data[offset + 7 : offset + 7 + length].decode()
                if value in whitelist:
                    data[offset + 6] |= 1
                offset += 7 + length
            path.write_bytes(data)
            replace(
                alternate / 'lua/tiger_sentence/data/lexicon.lua',
                'local whitelist = load_whitelist()',
                'local whitelist = {}',
            )

        def measure(mode):
            command = [
                args.lua,
                ROOT / 'tools/benchmark_lexicon.lua',
                alternate if mode == 'baked_whitelist' else root,
                'binary' if mode == 'baked_whitelist' else mode,
                corpus_path,
            ]
            if mode == 'check' and alternate:
                command.append(alternate)
            elif args.whitelist:
                command.append('1500')
            return json.loads(run(command, cwd=ROOT))

        equality = measure('check')
        samples = {'binary': [], comparison: []}
        for repeat in range(3):
            for mode in (
                ('binary', comparison)
                if repeat % 2 == 0
                else (comparison, 'binary')
            ):
                samples[mode].append(measure(mode))
        medians = {}
        for mode, values in samples.items():
            medians[mode] = {
                key: statistics.median(value[key] for value in values)
                for key in ('load_ms', 'retained_heap_mib')
            }
            medians[mode]['peak_rss_mib'] = statistics.median(
                value['typing']['peak_rss_mib'] for value in values
            )
            for category in ('append', 'edit'):
                medians[mode][category] = {
                    key: statistics.median(
                        value['typing'][category][key] for value in values
                    )
                    for key in ('mean_us', 'p50_us', 'p95_us')
                }
        print(
            json.dumps(
                {'equality': equality, 'medians': medians, 'samples': samples},
                indent=2,
            )
        )


if __name__ == '__main__':
    main()
