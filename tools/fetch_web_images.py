#!/usr/bin/env python3
"""Finds a photo URL for every web recipe from its source page (stdlib only).

For each web recipe's source.url it fetches the HTML and takes, in order: the JSON-LD Recipe "image" (string, list or
ImageObject.url), og:image, twitter:image. Writes data/web_images.json {recipe id: absolute image URL} and
data/web_images_failures.json {recipe id: reason}. Results are cached: re-runs skip ids already done
(use --retry-failed to try the failures again).

Run: python3 -I tools/fetch_web_images.py [--retry-failed] [--limit N]
8 workers, 15 s timeout, at most 2 concurrent requests per domain, a normal browser User-Agent.
"""
import concurrent.futures
import glob
import gzip
import html
import json
import os
import re
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
OK_PATH = os.path.join(DATA, "web_images.json")
FAIL_PATH = os.path.join(DATA, "web_images_failures.json")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
      "Version/17.4 Safari/605.1.15")
TIMEOUT = 15
MAX_BYTES = 3_000_000

_domain_locks = {}
_lock_guard = threading.Lock()


def domain_sem(host):
    with _lock_guard:
        return _domain_locks.setdefault(host, threading.Semaphore(2))


def load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def fetch_html(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,application/xhtml+xml",
                                               "Accept-Language": "en-US,en;q=0.9", "Accept-Encoding": "gzip"})
    with domain_sem(urllib.parse.urlsplit(url).netloc):
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read(MAX_BYTES)
            if resp.headers.get("Content-Encoding") == "gzip":
                try:
                    raw = gzip.decompress(raw)
                except OSError:
                    pass
            charset = resp.headers.get_content_charset() or "utf-8"
            return raw.decode(charset, errors="replace"), resp.geturl()


def _image_from(node):
    if isinstance(node, str):
        return node
    if isinstance(node, list):
        for n in node:
            v = _image_from(n)
            if v:
                return v
    if isinstance(node, dict):
        return _image_from(node.get("url") or node.get("contentUrl"))
    return None


def _walk_recipes(node):
    if isinstance(node, list):
        for n in node:
            yield from _walk_recipes(n)
    elif isinstance(node, dict):
        t = node.get("@type")
        if t == "Recipe" or (isinstance(t, list) and "Recipe" in t):
            yield node
        for v in node.values():
            if isinstance(v, (list, dict)):
                yield from _walk_recipes(v)


def extract_image(page, base_url):
    for m in re.finditer(r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>', page, re.S | re.I):
        try:
            data = json.loads(html.unescape(m.group(1)).strip())
        except ValueError:
            try:
                data = json.loads(m.group(1).strip())
            except ValueError:
                continue
        for rec in _walk_recipes(data):
            img = _image_from(rec.get("image"))
            if img:
                return urllib.parse.urljoin(base_url, img.strip())
    for prop in ("og:image", "og:image:secure_url", "twitter:image", "twitter:image:src"):
        for tag in re.finditer(r"<meta\s[^>]*>", page, re.I):
            t = tag.group(0)
            if re.search(r'(?:property|name)=["\']%s["\']' % re.escape(prop), t, re.I):
                c = re.search(r'content=["\']([^"\']+)["\']', t, re.I)
                if c:
                    return urllib.parse.urljoin(base_url, html.unescape(c.group(1)).strip())
    return None


def fetch_one(url):
    """Returns (image_url, None) or (None, reason)."""
    try:
        page, final = fetch_html(url)
    except urllib.error.HTTPError as e:
        return None, "http %d" % e.code
    except urllib.error.URLError as e:
        return None, "timeout" if "timed out" in str(e.reason) else "network error"
    except TimeoutError:
        return None, "timeout"
    except Exception as e:                                # noqa: BLE001 - report anything unexpected as a reason
        return None, "error: %s" % type(e).__name__
    img = extract_image(page, final)
    return (img, None) if img else (None, "no image in page")


def main():
    retry = "--retry-failed" in sys.argv
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
    ok, fails = load(OK_PATH, {}), load(FAIL_PATH, {})
    by_url = {}                                         # url -> [recipe ids]
    total = 0
    for fp in sorted(glob.glob(os.path.join(DATA, "web", "*.json"))):
        items = load(fp, [])
        for r in items.get("recipes", []) if isinstance(items, dict) else items:
            u = (r.get("source") or {}).get("url")
            if not (r.get("id") and u):
                continue
            total += 1
            if r["id"] in ok or (r["id"] in fails and not retry):
                continue
            by_url.setdefault(u, []).append(r["id"])
    todo = list(by_url.items())[:limit]
    print("recipes with a source URL: %d; to fetch: %d unique pages" % (total, len(todo)), flush=True)

    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(fetch_one, u): (u, ids) for u, ids in todo}
        for fut in concurrent.futures.as_completed(futs):
            u, ids = futs[fut]
            img, reason = fut.result()
            for i in ids:
                if img:
                    ok[i] = img
                    fails.pop(i, None)
                else:
                    fails[i] = reason
            done += 1
            if done % 25 == 0 or done == len(todo):
                with open(OK_PATH, "w", encoding="utf-8") as f:
                    json.dump(ok, f, indent=1, ensure_ascii=False)
                with open(FAIL_PATH, "w", encoding="utf-8") as f:
                    json.dump(fails, f, indent=1, ensure_ascii=False)
                print("  %d / %d pages" % (done, len(todo)), flush=True)

    reasons = {}
    for r in fails.values():
        reasons[r] = reasons.get(r, 0) + 1
    print("found %d of %d recipes" % (sum(1 for _ in ok), total))
    print("failures by reason: %s" % (", ".join("%s %d" % kv for kv in sorted(reasons.items(), key=lambda x: -x[1])) or "none"))


if __name__ == "__main__":
    main()
