#!/usr/bin/env python3
"""Embed only public update configuration; never generate or read private keys."""
import argparse, base64, os, pathlib, plistlib, urllib.parse

SAFE_DEFAULTS = {'SUEnableAutomaticChecks': False, 'SUAutomaticallyUpdate': False,
                 'SUAllowsAutomaticUpdates': False, 'SUSendsSystemProfile': False,
                 'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True}


def configured(info, require=False):
    feed, public = info.get('SUFeedURL'), info.get('SUPublicEDKey')
    if feed is None and public is None:
        if require: raise ValueError('Release update feed and public Ed25519 key are required.')
        return False
    if not isinstance(feed, str) or not isinstance(public, str) or len(feed) > 2048:
        raise ValueError('Update feed and public key must both be present.')
    parts = urllib.parse.urlsplit(feed)
    if parts.scheme != 'https' or not parts.hostname or parts.username is not None or parts.password is not None or '#' in feed or (parts.port is not None and not 1 <= parts.port <= 65535):
        raise ValueError('Update feed must use HTTPS without credentials or a fragment.')
    try: key = base64.b64decode(public, validate=True)
    except (ValueError, TypeError) as error: raise ValueError('Invalid public Ed25519 key.') from error
    if len(key) != 32 or not any(key) or base64.b64encode(key).decode() != public:
        raise ValueError('Expected a canonical 32-byte public Ed25519 key.')
    if info.get('SURequireSignedFeed') is not True or info.get('SUVerifyUpdateBeforeExtraction') is not True:
        raise ValueError('Signed feed and pre-extraction archive verification are required.')
    return True


def prepare(info, environment):
    result = dict(info)
    for variable, key in [('DESKCAPTURE_UPDATE_FEED_URL', 'SUFeedURL'), ('DESKCAPTURE_UPDATE_PUBLIC_ED_KEY', 'SUPublicEDKey')]:
        if variable in environment: result[key] = environment[variable]
    result.update(SAFE_DEFAULTS)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('info', type=pathlib.Path); parser.add_argument('--check', action='store_true')
    parser.add_argument('--require-complete', action='store_true'); args = parser.parse_args()
    info = prepare(plistlib.loads(args.info.read_bytes()), os.environ)
    enabled = configured(info, require=args.require_complete)
    if not args.check: args.info.write_bytes(plistlib.dumps(info, sort_keys=False))
    print('Update configuration: ' + ('configured' if enabled else 'absent; no online updater starts'))

if __name__ == '__main__': main()
