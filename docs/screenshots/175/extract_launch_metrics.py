#!/usr/bin/env python3
"""Export redacted launch measurements from an App Launch + os_signpost trace.

Keeps only lifecycle timestamps, this app's launch intervals and aggregate context.
Does not export call stacks, device identifiers, journal entries or image data.
"""
import argparse
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


def table(trace, schema):
    result = subprocess.run([
        'xcrun', 'xctrace', 'export', '--input', str(trace), '--xpath',
        f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
    ], check=True, capture_output=True, text=True)
    root = ET.fromstring(result.stdout)
    ids = {element.attrib['id']: element for element in root.iter() if 'id' in element.attrib}

    def resolve(element):
        while 'ref' in element.attrib:
            element = ids[element.attrib['ref']]
        return element

    rows = []
    for node in root.findall('.//node'):
        columns = [column.findtext('mnemonic') for column in node.find('schema').findall('col')]
        for row in node.findall('row'):
            rows.append({name: resolve(value) for name, value in zip(columns, row)})
    return rows


def text(element):
    return element.attrib.get('fmt', element.text)


def milliseconds(element):
    return int(element.text) / 1_000_000


def extract(trace):
    lifecycle = table(trace, 'life-cycle-period')
    if not lifecycle:
        raise ValueError('No lifecycle run data; wait until xctrace has saved the trace.')
    origin = min(milliseconds(row['start']) for row in lifecycle)
    initial = next(row for row in lifecycle if text(row['period']) == 'Launching - Initial Frame Rendering')
    result = {
        'time_origin': 'first recorded lifecycle initialization event; not a home-screen tap',
        'first_frame_ms': milliseconds(initial['start']) + milliseconds(initial['duration']) - origin,
        'phases': [], 'markers': [], 'context': {},
    }
    for row in table(trace, 'OSSignpostIntervals'):
        if text(row['subsystem']) != 'com.matthewcelia.mybirdjournal' or text(row['category']) != 'launch':
            continue
        result['phases'].append({
            'name': text(row['name']), 'start_ms': milliseconds(row['start']) - origin,
            'duration_ms': milliseconds(row['duration']),
            'began_on_main_thread': 'Main Thread' in text(row['start-thread']),
        })
    for row in table(trace, 'os-signpost'):
        if text(row['subsystem']) != 'com.matthewcelia.mybirdjournal' or text(row['category']) != 'launch' or text(row['event-type']) != 'Event':
            continue
        name = text(row['name'])
        at = milliseconds(row['time']) - origin
        result['markers'].append({'name': name, 'at_ms': at})
        if name == 'Journal interactive':
            result['listen_appearance_ms'] = at
        elif name == 'Launch context':
            message = text(row['message']) or ''
            match = re.fullmatch(r'sightings: (\d+); packs: ([a-z0-9:, -]+)', message)
            if match:
                result['context']['sightings'] = int(match[1])
                result['context']['packs'] = dict((key.strip(), int(value)) for key, value in (item.rsplit(':', 1) for item in match[2].split(',')))
        elif name == 'Widget probe input':
            result['context']['widget_has_approved_painting'] = text(row['message']) == 'approved painting: 1'
    if 'listen_appearance_ms' not in result:
        raise ValueError('No Journal interactive signpost in this trace.')
    result['readiness_proxy_ms'] = max(result['first_frame_ms'], result['listen_appearance_ms'])
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps(extract(args.trace), indent=2) + '\n')
