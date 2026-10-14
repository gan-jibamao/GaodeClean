#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""云端拼装：从草稿 release 拉分块 → 拼装 → sha256 校验 → 挂目标 release。
环境变量：GH_TOKEN / REPO / DRAFT_ID / TARGET_ID / EXPECTED_SHA / FILENAME
"""
import os, json, hashlib, urllib.request, urllib.parse, subprocess, sys
from concurrent.futures import ThreadPoolExecutor, as_completed

T = os.environ['GH_TOKEN']
REPO = os.environ['REPO']
DRAFT = os.environ['DRAFT_ID']
TARGET = os.environ['TARGET_ID']
EXPECTED = os.environ['EXPECTED_SHA'].lower()
FILENAME = os.environ['FILENAME']
HDR = {'Authorization': 'Bearer ' + T, 'Accept': 'application/vnd.github+json',
       'User-Agent': 'assemble'}


def api(url):
    req = urllib.request.Request(url, headers=HDR)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def main():
    assets = []
    page = 1
    while True:
        d = api('https://api.github.com/repos/%s/releases/%s/assets?per_page=100&page=%d'
                % (REPO, DRAFT, page))
        if not d:
            break
        assets += d
        page += 1
    chunks = sorted([a for a in assets if a['name'].startswith('c_')], key=lambda a: a['name'])
    print('chunks: %d' % len(chunks))
    assert chunks, 'no chunks found'

    os.makedirs('chunks', exist_ok=True)

    def fetch(a):
        p = 'chunks/' + a['name']
        url = 'https://api.github.com/repos/%s/releases/assets/%s' % (REPO, a['id'])
        for k in range(5):
            r = subprocess.run(['curl', '-sSL', '--max-time', '120', '-o', p,
                                '-H', 'Authorization: Bearer ' + T,
                                '-H', 'Accept: application/octet-stream',
                                url])
            if r.returncode == 0 and os.path.exists(p) and os.path.getsize(p) == a['size']:
                return None
        return 'fail %s' % a['name']

    fails = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(fetch, a): a for a in chunks}
        done = 0
        for f in as_completed(futs):
            err = f.result()
            if err:
                fails.append(err)
            done += 1
            if done % 100 == 0:
                print('  downloaded %d/%d' % (done, len(chunks)))
    assert not fails, 'download failures: %s' % fails[:5]
    print('all chunks downloaded')

    h = hashlib.sha256()
    with open('assembled.bin', 'wb') as out:
        for a in chunks:
            blob = open('chunks/' + a['name'], 'rb').read()
            out.write(blob)
            h.update(blob)
    got = h.hexdigest()
    print('assembled sha256 = %s' % got)
    print('expected  sha256 = %s' % EXPECTED)
    assert got == EXPECTED, 'SHA MISMATCH'
    print('SHA256 OK')

    data = open('assembled.bin', 'rb').read()
    name = urllib.parse.quote(FILENAME)
    url = 'https://uploads.github.com/repos/%s/releases/%s/assets?name=%s' % (REPO, TARGET, name)
    req = urllib.request.Request(url, data=data, method='POST',
        headers={'Authorization': 'Bearer ' + T,
                 'Content-Type': 'application/octet-stream',
                 'User-Agent': 'assemble'})
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.loads(r.read())
    print('uploaded: %s %d B state=%s' % (d['name'], d['size'], d['state']))

    req = urllib.request.Request(
        'https://api.github.com/repos/%s/releases/assets/%s' % (REPO, d['id']), headers=HDR)
    with urllib.request.urlopen(req, timeout=60) as r:
        a = json.loads(r.read())
    dig = (a.get('digest') or '').replace('sha256:', '')
    print('remote digest = %s' % dig)
    assert dig == EXPECTED, 'REMOTE DIGEST MISMATCH'
    print('REMOTE VERIFY OK')


if __name__ == '__main__':
    main()
