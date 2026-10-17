#!/usr/bin/env python3
"""Run mobile/native virtual integration and existing regressions without hardware."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def resolve_firmware(explicit=None):
    """Use an explicit override or the documented sibling checkout; never search branches."""
    selected = explicit or os.environ.get('SCRBRD_FIRMWARE')
    if selected:
        return Path(selected).expanduser().resolve()
    sibling = 'scrbrd-virtual-firmware' if ROOT.name == 'scrbrd-virtual-mobile' else 'scrbrd'
    return (ROOT.parent / sibling).resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--firmware', type=Path,
                        help='Override SCRBRD_FIRMWARE or the sibling scrbrd checkout')
    parser.add_argument('--quick', action='store_true',
                        help='Virtual scenarios + cross-repository compatibility only')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/virtual-testing')
    args = parser.parse_args()
    firmware, output = resolve_firmware(args.firmware), args.output.expanduser().resolve()
    if not (firmware / 'test/virtual/build_bridge.py').is_file():
        parser.error(f'Virtual firmware bridge not found in {firmware}. '
                     'Use sibling scrbrd (or paired scrbrd-virtual-firmware), '
                     '--firmware PATH, or SCRBRD_FIRMWARE. Check out the virtual '
                     'infrastructure in both repositories; no branch will be changed automatically.')
    output.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1',
           'SCRBRD_VIRTUAL_DEVICE': str(output / 'virtual-device'),
           'SCRBRD_VIRTUAL_REPORT_DIR': str(output),
           'SCRBRD_PROTOCOL_FIXTURE': str(output / 'protocol-fixture.json')}
    results = []

    def run(name, command, cwd=ROOT, requires=()):
        started = time.monotonic()
        log = output / f'{name}.log'
        skipped = [step for step in requires if not any(r['name'] == step and r['status'] == 'PASS' for r in results)]
        if skipped:
            code, status = None, 'BLOCKED'
            log.write_text('Required step failed: ' + ', '.join(skipped) + '\n')
        else:
            try:
                with log.open('w') as stream:
                    process = subprocess.run(command, cwd=cwd, env=env, stdout=stream,
                                             stderr=subprocess.STDOUT, timeout=1200)
                code = process.returncode
                status = 'PASS' if code == 0 else 'FAIL'
            except (OSError, subprocess.TimeoutExpired) as error:
                with log.open('a') as stream:
                    stream.write(f'\n{error}\n')
                code, status = None, 'FAIL'
        results.append({'name': name, 'status': status, 'exitCode': code,
                        'seconds': round(time.monotonic() - started, 2), 'log': str(log)})
        print(f'{status:7} {name}', flush=True)

    def provenance(path):
        def git(*arguments):
            result = subprocess.run(['git', '-C', str(path), *arguments], capture_output=True, text=True)
            return result.stdout.strip() if result.returncode == 0 else 'unavailable'
        return {'path': str(path), 'revision': git('rev-parse', 'HEAD'),
                'branch': git('branch', '--show-current'), 'status': git('status', '--short')}

    flutter = shutil.which('flutter') or 'flutter'
    compiler = shutil.which('c++') or 'c++'
    print(f'Report directory: {output}', flush=True)
    run('dependencies', [flutter, 'pub', 'get', '--offline', '--enforce-lockfile'])
    run('native-bridge', [sys.executable, str(firmware / 'test/virtual/build_bridge.py'),
                          '--output', env['SCRBRD_VIRTUAL_DEVICE']])
    run('virtual-integration', [flutter, 'test', '--no-pub', '--concurrency=1',
                                '--reporter=expanded', 'test/virtual/virtual_integration_test.dart'],
        requires=('dependencies', 'native-bridge'))
    run('mobile-protocol-fixture', [flutter, 'test', '--no-pub', '--reporter=expanded',
                                    'test/firmware_protocol_compatibility_test.dart'], requires=('dependencies',))
    run('native-protocol-compatibility', [sys.executable,
          str(firmware / 'test/mobile_protocol_compatibility_test.py'), env['SCRBRD_PROTOCOL_FIXTURE']],
        requires=('mobile-protocol-fixture',))
    if not args.quick:
        # The full suite also runs the virtual tests because the native bridge env is set.
        run('flutter-suite', [flutter, 'test', '--no-pub', '--reporter=expanded'],
            requires=('dependencies', 'native-bridge'))
        run('flutter-analysis', [flutter, 'analyze', '--no-pub'], requires=('dependencies',))
        for name in ('bluetooth_session_queue', 'cached_content_verification', 'fantasy_alert_queue',
                     'fantasy_slate_transfer', 'responsiveness', 'scoreboard_render', 'test_sketch_test_runner'):
            script = name + ('_test.py' if name != 'test_sketch_test_runner' else '.py')
            run('native-' + name, [sys.executable, str(firmware / 'test' / script)], cwd=firmware)
        for name in ('game_manager_storage', 'fantasy_projection'):
            command = [compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                       '-Wno-missing-field-initializers',
                       '-I' + str(firmware / 'test/native'), '-I' + str(firmware),
                       '-I' + env.get('ARDUINOJSON_INCLUDE', str(Path.home() / 'Documents/Arduino/libraries/ArduinoJson/src')),
                       str(firmware / 'test' / (name + '_test.cpp'))]
            if name == 'game_manager_storage':
                command.append(str(firmware / 'GameManager.cpp'))
            command.extend(['-o', str(output / name)])
            run('build-' + name, command)
            run('native-' + name, [str(output / name)], requires=('build-' + name,))
    passed = all(result['status'] == 'PASS' for result in results)
    report = {'status': 'PASS' if passed else 'FAIL', 'quick': args.quick,
              'mobile': provenance(ROOT), 'firmware': provenance(firmware), 'steps': results,
              'limitations': ['Radio, ATT/MTU, native iOS plugins/restoration and display hardware are stubbed.',
                              'Main baseline has no F13 auto-reconnect policy; reconnects are scripted.',
                              'Fixtures are normalized data, not live provider API or projection verification.']}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    summary = '\n'.join([f"SCRBRD virtual testing: {report['status']}",
        *[f"{r['status']:7} {r['name']} ({r['seconds']}s)" for r in results],
        f"Mobile: {report['mobile']['revision']}", f"Firmware: {report['firmware']['revision']}"])
    (output / 'report.txt').write_text(summary + '\n')
    print(f"{report['status']}: {sum(r['status'] == 'PASS' for r in results)}/{len(results)} steps passed. See {output / 'report.txt'}")
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
