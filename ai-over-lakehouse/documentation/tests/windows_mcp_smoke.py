"""Native Windows MCP transport/process checks, explicitly without a database."""

import argparse
import json
from pathlib import Path
import queue
import subprocess
import threading
import time
import tomllib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--python', type=Path, required=True)
    parser.add_argument('--project-config', type=Path, required=True)
    args = parser.parse_args()
    original = args.project_config.read_text(encoding='utf-8')
    config = tomllib.loads(original)['mcp_servers']['LiveLab']
    manager = args.runtime / '02-peakgear-livelab-admin.ps1'
    unrelated = subprocess.Popen([str(args.python), '-c', 'import time; time.sleep(240)'])
    child = None
    stderr_file = args.runtime / 'qa-mcp-stderr.log'

    def manage(action):
        result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(manager), '-Action', action], capture_output=True, text=True, errors='replace', timeout=45)
        print(result.stdout)
        if result.returncode:
            print(result.stderr)
            raise AssertionError(f'Management {action} failed.')
        return result.stdout

    try:
        for stop_action in ('Stop', 'Restart'):
            with stderr_file.open('w', encoding='utf-8') as error_log:
                child = subprocess.Popen([config['command'], *config['args']], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=error_log, text=True, encoding='utf-8')
                replies = queue.Queue()

                def reader(stream):
                    for line in stream:
                        replies.put(line)
                    replies.put(None)

                threading.Thread(target=reader, args=(child.stdout,), daemon=True).start()

                def send(payload):
                    child.stdin.write(json.dumps(payload) + '\n')
                    child.stdin.flush()

                def receive(identifier):
                    deadline = time.monotonic() + 45
                    while time.monotonic() < deadline:
                        line = replies.get(timeout=max(0.01, deadline - time.monotonic()))
                        if line is None:
                            raise AssertionError('MCP closed before completing initialization; inspect sanitized stderr.')
                        payload = json.loads(line)
                        if payload.get('id') == identifier:
                            assert 'result' in payload, payload
                            return payload['result']
                    raise AssertionError('MCP reply timed out.')

                send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2024-11-05', 'capabilities': {}, 'clientInfo': {'name': 'peakgear-windows-qa', 'version': '1'}}})
                receive(1)
                send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
                send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list', 'params': {}})
                tools = {tool['name'] for tool in receive(2)['tools']}
                assert {'adp_get_connection_info', 'adp_run_query', 'adp_get_top_digital_interest'} <= tools
                print(f'PASS native stdio initialization and {len(tools)} registered tools; no database calls')
                status = manage('Status')
                assert 'sessions: 1' in status
                manage('Refresh')
                assert args.project_config.read_text(encoding='utf-8') == original
                manage(stop_action)
                child.wait(timeout=15)
                assert unrelated.poll() is None, 'Scoped cleanup killed the unrelated process.'
                assert args.project_config.read_text(encoding='utf-8') == original
                print(f'PASS real Windows {stop_action} and preservation of unrelated processes/config')
        assert 'sessions: 0' in manage('Status')
    finally:
        if child and child.poll() is None:
            child.terminate()
            child.wait(timeout=15)
        if unrelated.poll() is None:
            unrelated.terminate()
            unrelated.wait(timeout=15)
    print('Native Windows smoke checks passed. Database authentication and Codex GUI were not tested.')


if __name__ == '__main__':
    main()
