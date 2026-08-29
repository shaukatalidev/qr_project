#!/usr/bin/env python3
"""Find live Reddit threads worth answering for Qravio.

Reddit blocks curl, old.reddit, and /search for datacenter IPs — but the feed
endpoint the web app itself calls (`/svc/shreddit/community-more-posts`) still
answers a plain GET with a browser User-Agent. This script reads that, so it is
the only reliable way to enumerate threads from a script here. It is read-only:
it never posts, votes, or logs in.

Usage:
    python3 scripts/reddit-thread-finder.py                 # keyword hits, last 45 days
    python3 scripts/reddit-thread-finder.py --days 90
    python3 scripts/reddit-thread-finder.py --sub qrcode --all   # whole sub, unfiltered
"""

import argparse
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36")

FEED = "https://www.reddit.com/svc/shreddit/community-more-posts/{sort}/?name={sub}"
# The feed returns 25 posts per request; a busy sub is only a few hours deep at
# that size, so anything but r/qrcode needs paging before "no QR threads" means
# anything. The cursor is the `after=` on the load-after partial in the markup.
NEXT = re.compile(r'slot="load-after"[^>]*src="(/svc/shreddit/community-more-posts/[^"]+)"')

# Subs where a QR question can plausibly appear. r/qrcode is unfiltered by
# default (the whole sub is on-topic); everywhere else needs a keyword hit.
SUBS = [
    "qrcode", "smallbusiness", "Entrepreneur", "marketing", "restaurateur",
    "nonprofit", "SideProject", "SaaS", "webdev", "Etsy", "EtsySellers",
    "weddingplanning", "realtors", "IndianStartups", "StartUpIndia",
]

ALWAYS_ON_TOPIC = {"qrcode"}

KEYWORDS = re.compile(
    r"\bqr[\s\-]?codes?\b|\bqr\b|dynamic qr|static qr|qr generator|scan(?:nable)? code",
    re.I,
)

ATTR = re.compile(r'(\w[\w-]*)="([^"]*)"')


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html"})
    with urllib.request.urlopen(req, timeout=25) as resp:
        return resp.read().decode("utf-8", "ignore")


def feed_pages(sub: str, sort: str, pages: int):
    """Yield successive feed HTML pages, following the load-after cursor."""
    url = FEED.format(sort=sort, sub=sub)
    for _ in range(pages):
        html = fetch(url)
        yield html
        nxt = NEXT.search(html)
        if not nxt:
            return
        url = "https://www.reddit.com" + nxt.group(1).replace("&amp;", "&")


def posts_from(html: str):
    for block in re.split(r"<shreddit-post\b", html)[1:]:
        head = block.split(">", 1)[0]
        attrs = dict(ATTR.findall(head))
        if not attrs.get("permalink"):
            continue
        yield attrs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=45, help="ignore posts older than this")
    ap.add_argument("--sub", action="append", help="override the sub list (repeatable)")
    ap.add_argument("--all", action="store_true", help="skip the keyword filter")
    ap.add_argument("--pages", type=int, default=4,
                    help="feed pages per sort (25 posts each); raise for busy subs")
    args = ap.parse_args()

    subs = args.sub or SUBS
    cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)
    rows, seen, failed = [], set(), []

    for sub in subs:
        for sort in ("hot", "new"):
            try:
                pages = list(feed_pages(sub, sort, args.pages))
            except (urllib.error.URLError, OSError) as exc:
                failed.append(f"{sub}/{sort}: {exc}")
                continue
            for p in (post for page in pages for post in posts_from(page)):
                pid = p.get("id")
                # The feed splices in promoted posts from other subs; drop them.
                if p.get("subreddit-name", "").lower() != sub.lower() or pid in seen:
                    continue
                title = p.get("post-title", "")
                on_topic = args.all or sub.lower() in ALWAYS_ON_TOPIC or KEYWORDS.search(title)
                if not on_topic:
                    continue
                try:
                    ts = datetime.fromisoformat(p["created-timestamp"])
                except (KeyError, ValueError):
                    continue
                if ts < cutoff:
                    continue
                seen.add(pid)
                rows.append((ts, sub, int(p.get("comment-count", 0) or 0),
                             int(p.get("score", 0) or 0), title,
                             "https://www.reddit.com" + p["permalink"]))

    rows.sort(reverse=True)
    print(f"| Date | Sub | Cmts | Score | Thread |")
    print(f"|---|---|---|---|---|")
    for ts, sub, cmts, score, title, url in rows:
        safe = title.replace("|", "\\|")
        print(f"| {ts:%Y-%m-%d} | r/{sub} | {cmts} | {score} | [{safe}]({url}) |")
    print(f"\n{len(rows)} threads from {len(subs)} subs, last {args.days} days.",
          file=sys.stderr)
    for f in failed:
        print(f"  unreachable: {f}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
