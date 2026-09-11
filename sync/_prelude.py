# Shared identity helpers.
#
# This file is NOT imported. sync-repo.sh concatenates it with commit_callback.py
# and hands the result to `git filter-repo --commit-callback`, which wraps the text
# in a function body. So: keep everything at zero indentation, and remember that
# filter-repo hands callbacks *bytes*, never str.
#
# Configuration comes from the environment (see .github/workflows/sync.yml).

import os
import re
import hashlib


def _list(var):
    """'a, b ,c' -> [b'a', b'b', b'c'], lowercased."""
    return [p.strip().lower().encode('utf-8') for p in os.environ.get(var, '').split(',') if p.strip()]


_OLD_NAMES = set(_list('OLD_NAMES'))
_OLD_EMAILS = set(_list('OLD_EMAILS'))
_KEEP_EMAILS = set(_list('KEEP_EMAILS'))
_KEEP_PATTERNS = _list('KEEP_NAME_PATTERNS')
_ANON_DOMAINS = _list('ANON_EMAIL_DOMAINS')
_NEW_NAME = os.environ.get('NEW_NAME', '').encode('utf-8')
_NEW_EMAIL = os.environ.get('NEW_EMAIL', '').encode('utf-8')
_SALT = os.environ.get('ANON_SALT', '').encode('utf-8')
_ANON_OTHERS = os.environ.get('ANON_OTHERS', 'true').strip().lower() != 'false'

_TRAILERS = (b'Co-authored-by|Signed-off-by|Reviewed-by|Acked-by|Tested-by'
             b'|Reported-by|Suggested-by|Helped-by|Requested-by')


def map_identity(name, email):
    """(bytes, bytes) -> (bytes, bytes). Three rules, first match wins."""
    name = name or b''
    email = email or b''
    n = name.strip().lower()
    e = email.strip().lower()

    # 1. Mine: reattribute to the personal identity.
    if e in _OLD_EMAILS or (n and n in _OLD_NAMES):
        return _NEW_NAME, _NEW_EMAIL

    # 2. Bots and GitHub's own web-flow commits: pass through untouched.
    if e in _KEEP_EMAILS or any(p in n for p in _KEEP_PATTERNS):
        return name, email

    if not _ANON_OTHERS:
        return name, email

    # 3. Everyone else: stable salted pseudonym. .invalid is a reserved TLD,
    #    so the address can never route anywhere.
    digest = hashlib.sha256(_SALT + (e or n)).hexdigest()[:10].encode('ascii')
    return b'contributor-' + digest, b'contributor-' + digest + b'@anonymous.invalid'


def rewrite_message(message):
    """Apply the same mapping to identities embedded in a commit message."""
    if not message:
        return message

    def _trailer(m):
        name, email = map_identity(m.group(3), m.group(4))
        return m.group(1) + m.group(2) + name + b' <' + email + b'>'

    # Co-authored-by: Someone <someone@something.com>
    message = re.sub(br'^([ \t]*(?:' + _TRAILERS + br'))([ \t]*:[ \t]*)(.*?)[ \t]*<([^<>\s]+)>[ \t]*$',
                     _trailer, message, flags=re.IGNORECASE | re.MULTILINE)

    def _email(m):
        found = m.group(0)
        lowered = found.lower()
        if lowered in _OLD_EMAILS or any(lowered.endswith(b'@' + d) for d in _ANON_DOMAINS):
            return map_identity(b'', found)[1]
        return found

    # Bare addresses in prose, but only ones we actually own or want anonymised.
    # Unrelated addresses (docs, vendor support lines) are left alone.
    message = re.sub(br'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', _email, message)

    for old in _OLD_NAMES:
        message = re.sub(br'(?i)\b' + re.escape(old) + br'\b', _NEW_NAME, message)

    return message
