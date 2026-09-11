#!/usr/bin/env python3
"""用公开数据运行参考差分与缓存消融；解码对照按组合并行分片，生成物位于临时目录"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import random
import re
import shutil
import statistics
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(args, **kwargs):
    return subprocess.run(
        [str(x) for x in args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        **kwargs,
    ).stdout


def prepare(path, reference, lua, reference_backend=False):
    path.mkdir()
    shutil.copytree(ROOT / 'lua', path / 'lua')
    shutil.copytree(ROOT / 'dicts', path / 'dicts')
    (path / 'models').symlink_to(ROOT / 'models', target_is_directory=True)
    shutil.copyfile(
        ROOT / 'tiger_sentence.full_code_whitelist.example.txt',
        path / 'tiger_sentence.full_code_whitelist.txt',
    )
    for name in ('codes', 'char_ranks'):
        shutil.copyfile(
            ROOT / f'dicts/tiger_sentence.{name}.txt',
            path / f'tiger_sentence.{name}.txt',
        )
    source = reference if reference_backend else ROOT
    shutil.copyfile(
        source / 'tiger_sentence.schema.yaml',
        path / 'tiger_sentence.schema.yaml',
    )
    if reference_backend:
        shutil.copyfile(
            reference / 'lua/tiger_sentence.lua',
            path / 'lua/tiger_sentence.lua',
        )
        (path / 'rime.lua').write_text(
            'local m = require("tiger_sentence")\n'
            'tiger_sentence_processor = m.processor\n'
            'tiger_sentence_translator = m.translator\n'
        )
        shutil.copyfile(reference / 'symbols.yaml', path / 'symbols.yaml')
    run([
        lua,
        ROOT / 'tools/build_data.lua',
        path / 'tiger_sentence.codes.txt',
        path / 'tiger_sentence.char_ranks.txt',
        path / 'lua/tiger_sentence/data/lexicon.bin',
        path / 'lua/tiger_sentence/data/ranks.lua',
    ])


def replace(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise RuntimeError(f'消融落点已变化：{path.name}：{old}')
    path.write_text(source.replace(old, new))


# 解码对照的四个组合互相独立，分片并行执行后再合并计数
DECODE_SHARDS = ('0,false', '0,true', '1500,false', '1500,true')


def decode_comparison(lua, current, reference_backend, corpus_file):
    command = [
        lua,
        ROOT / 'tests/comparison.lua',
        current,
        reference_backend,
        corpus_file,
    ]
    environment = dict(os.environ)
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=len(DECODE_SHARDS)
    ) as pool:

        def shard_result(shard):
            return json.loads(
                run(command, env={**environment, 'COMPARISON_SHARD': shard})
            )

        results = list(pool.map(shard_result, DECODE_SHARDS))
    return {
        'comparisons': sum(result['comparisons'] for result in results),
        'edit_steps': sum(result['edit_steps'] for result in results),
        'reference_backend_cache_mismatches': sum(
            result['reference_backend_cache_mismatches'] for result in results
        ),
        'edit_failures': [
            failure for result in results for failure in result['edit_failures']
        ],
    }


def corpus():
    codes = []
    by_text = {}
    for line in (
        (ROOT / 'dicts/tiger_sentence.codes.txt').read_text().splitlines()
    ):
        parts = line.split()
        if len(parts) == 2 and not line.startswith('#'):
            value, code = parts
            if code.isascii() and code.isalpha() and 2 <= len(code) <= 4:
                codes.append(code)
                by_text.setdefault(value, []).append(code)
    phrases = [
        '反刍',
        '汨罗江江水汩汩',
        '今天天气很好',
        '我们一起去吃饭',
        '中华人民共和国',
        '生活就像一盒巧克力',
        '输入法应该正确处理候选',
        '山重水复疑无路柳暗花明又一村',
        '床前明月光疑是地上霜',
        '学习知识需要时间',
        '这是一个测试',
        '过去现在和未来',
        '题目',
        '题目是目',
    ]
    result = [
        'xrxbj',
        'xrxbj;',
        'korylkugkugkskorkor',
        'kormylkugkugkskorgkorg',
        'awmenamcunta',
        'otqm',
        'otwqm',
        'otwqmqm',
        'a' * 28,
        'gyy' * 42 + 'ae',
        'gyy' * 60,
    ]
    for phrase in phrases:
        for longest in (False, True):
            result.append(
                ''.join(
                    sorted(
                        by_text[ch], key=lambda c: (len(c), c), reverse=longest
                    )[0]
                    for ch in phrase
                )
            )
    rng = random.Random(72631)
    codes = sorted(set(codes))
    for length in (8, 24, 48, 72):
        for _ in range(8):
            raw = ''
            while len(raw) < length:
                raw += rng.choice(codes)
            result.append(raw[:length])
    return list(dict.fromkeys(result))


def traces(binary, path, shared, cases):
    request = ''.join(
        f'{name} {early} {duplicate} ' + ' '.join(map(str, keys)) + '\n'
        for name, early, duplicate, keys in cases
    )
    rows = {}
    for line in run(
        [binary, path, shared, '--trace'], input=request
    ).splitlines():
        values = line.split('\t')
        name, step, handled = values[:3]
        decode = lambda value: bytes.fromhex(value).decode()
        rows[(name, int(step))] = {
            'handled': int(handled),
            'commit': decode(values[3]),
            'input': decode(values[4]),
            'preedit': decode(values[5]),
            'cpu_us': float(values[6]),
            'candidates': list(map(decode, values[7:])),
        }
    return rows


def observable(row):
    return {key: value for key, value in row.items() if key != 'cpu_us'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--lua', default=os.environ.get('LUA', 'lua'))
    parser.add_argument(
        '--shared',
        default=os.environ.get('RIME_SHARED_DATA_DIR', '/usr/share/rime-data'),
    )
    parser.add_argument(
        '--quick', action='store_true', help='仅执行原生逐键对照'
    )
    args = parser.parse_args()
    record = (ROOT / 'docs/UPSTREAM.md').read_text()
    identities = {}
    for name in (
        'lua/tiger_sentence.lua',
        'tiger_sentence.schema.yaml',
        'symbols.yaml',
    ):
        actual = hashlib.sha256(
            (args.reference / name).read_bytes()
        ).hexdigest()
        match = re.search(
            r'(?m)^([a-f0-9]{64})  ' + re.escape(name) + r'$',
            record,
        )
        if match is None:
            raise RuntimeError(f'参考基线中未找到记录：{name}')
        baseline = match.group(1)
        if actual != baseline:
            raise RuntimeError(f'参考基线已变化，需重新审查差异：{name}')
        identities[name] = actual
    data_hashes = {}
    for name in ('codes', 'char_ranks'):

        def entries(path):
            return [
                line.split()
                for line in path.read_text(encoding='utf-8-sig').splitlines()
                if line.strip() and not line.lstrip().startswith('#')
            ]

        source = ROOT / f'dicts/tiger_sentence.{name}.txt'
        if entries(source) != entries(
            args.reference / f'tiger_sentence.{name}.txt'
        ):
            raise RuntimeError(f'公开数据条目或顺序不同：{name}')
        data_hashes[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    for directory in (ROOT, args.reference):
        with (directory / 'models/sentence-ngram-mobile.bin').open(
            'rb'
        ) as model:
            digest = hashlib.file_digest(model, 'sha256').hexdigest()
        if 'model' in data_hashes and data_hashes['model'] != digest:
            raise RuntimeError('模型内容不同')
        data_hashes['model'] = digest
    with tempfile.TemporaryDirectory(prefix='tiger-reference-') as temporary:
        scratch = Path(temporary)
        current, reference_backend = [
            scratch / name for name in ('current', 'reference')
        ]
        prepare(current, args.reference, args.lua)
        prepare(reference_backend, args.reference, args.lua, True)
        inputs = corpus()
        corpus_file = scratch / 'corpus.txt'
        corpus_file.write_text('\n'.join(inputs) + '\n')
        decoded = (
            None
            if args.quick
            else decode_comparison(
                args.lua, current, reference_backend, corpus_file
            )
        )
        binary = scratch / 'trace'
        run([
            os.environ.get('CXX', 'c++'),
            '-std=c++17',
            '-Wall',
            '-Wextra',
            ROOT / 'tests/rime_symbols.cc',
            '-lrime',
            '-o',
            binary,
        ])
        cases = []
        for index, raw in enumerate(inputs):
            for early in (0, 1):
                for duplicate in (0, 1):
                    cases.append((
                        f'input-{index}-{early}-{duplicate}',
                        early,
                        duplicate,
                        list(raw.encode()) + [32, 0xFF1B],
                    ))
        for index, raw in enumerate(inputs[:20]):
            cases.append((
                f'edit-{index}',
                0,
                1,
                list(raw.encode())
                + [0xFF08] * min(4, len(raw) - 1)
                + list(b'xrxbj ')
                + [0xFF1B],
            ))
        for index, raw in enumerate(inputs[:20]):
            for early in (0, 1):
                cases.append((
                    f'lock-{index}-{early}',
                    early,
                    1,
                    list(raw.encode()) + [0xFF09, ord('a'), 32, 0xFF1B],
                ))
                cases.append((
                    f'unlock-{index}-{early}',
                    early,
                    1,
                    list(raw.encode())
                    + [0xFF09, ord('a'), 0xFF08, ord('b'), 32, 0xFF1B],
                ))
        # 无候选时空格只重置会话，不改写组合输入
        for index, raw in enumerate(('zzzzzzzz', 'qjqjqjqj', 'otwqmzz')):
            for early in (0, 1):
                cases.append((
                    f'empty-{index}-{early}',
                    early,
                    1,
                    list(raw.encode()) + [32],
                ))
        # 空码顶屏计入合法非首选重码单字：整段单边不再提前提交首选单字
        for index, raw in enumerate(('hxq', 'hpx', 'yca')):
            for early in (0, 1):
                cases.append((
                    f'pending-{index}-{early}',
                    early,
                    1,
                    list(raw.encode()) + [32],
                ))
        snapshots = {
            name: traces(binary, path, args.shared, cases)
            for name, path in (
                ('current', current),
                ('reference_backend', reference_backend),
            )
        }
        if snapshots['current'].keys() != snapshots['reference_backend'].keys():
            raise RuntimeError('逐键事件集合不同')
        differences = []
        categories = {}
        for key, row in snapshots['current'].items():
            reference = snapshots['reference_backend'][key]
            if observable(row) != observable(reference):
                category = 'unclassified'
                categories[category] = categories.get(category, 0) + 1
                differences.append({
                    'case': key[0],
                    'step': key[1],
                    'category': category,
                    'current': observable(row),
                    'reference_backend': observable(reference),
                })
        report = {
            'baseline': identities['lua/tiger_sentence.lua'],
            'data': data_hashes,
            'seed': 72631,
            'inputs': inputs,
            'decode': decoded,
            'native_cases': len(cases),
            'native_events': len(snapshots['current']),
            'difference_events': categories,
            'differences': differences,
        }
        report['native_metrics'] = {}
        for name, rows in snapshots.items():
            automatic = [
                (key, row)
                for key, row in rows.items()
                if key[0].startswith('input-')
                and key[0].split('-')[2] == '1'
                and key[1] < len(inputs[int(key[0].split('-')[1])])
            ]
            report['native_metrics'][name] = {
                'automatic_commits': sum(
                    bool(row['commit']) for _, row in automatic
                ),
                'automatic_characters': sum(
                    len(row['commit']) for _, row in automatic
                ),
                'input_key_cpu_p50_us': statistics.median(
                    row['cpu_us'] for _, row in automatic
                ),
            }
        if not args.quick:
            large_cache = scratch / 'large-cache'
            prepare(large_cache, args.reference, args.lua)
            replace(
                large_cache / 'lua/tiger_sentence/model/kn.lua',
                'local PAGE_CACHE_BYTES = 2 * 1024 * 1024',
                'local PAGE_CACHE_BYTES = 8 * 1024 * 1024',
            )
            no_path_cache = scratch / 'no-path-cache'
            prepare(no_path_cache, args.reference, args.lua)
            replace(
                no_path_cache / 'lua/tiger_sentence/decoder.lua',
                '    if item._isolation_penalty ~= nil then\n'
                '        return item._isolation_penalty\n'
                '    end\n'
                '    local characters = item.edge_chars\n',
                '    local characters = item.edge_chars\n',
            )
            samples = {
                'current': [],
                'reference_backend': [],
                'large_cache': [],
                'no_path_cache': [],
            }
            for repeat in range(3):
                order = [
                    ('current', current, 'current'),
                    (
                        'reference_backend',
                        reference_backend,
                        'reference_backend',
                    ),
                    ('large_cache', large_cache, 'current'),
                    ('no_path_cache', no_path_cache, 'current'),
                ]
                if repeat % 2:
                    order.reverse()
                for name, path, mode in order:
                    samples[name].append(
                        json.loads(
                            run([
                                args.lua,
                                ROOT / 'tests/comparison.lua',
                                path,
                                reference_backend,
                                corpus_file,
                                mode,
                            ])
                        )
                    )
            report['benchmark_samples'] = samples
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if categories.get('unclassified'):
            raise SystemExit(1)


if __name__ == '__main__':
    main()
