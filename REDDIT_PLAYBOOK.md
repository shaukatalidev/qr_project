# Reddit Playbook — Qravio

Execution detail for [`OFFSITE_GEO_CHECKLIST.md`](./OFFSITE_GEO_CHECKLIST.md) **§4**. The
answer copy already exists in [`GEO_CONTENT_PACK.md` §C](./GEO_CONTENT_PACK.md) — that part is
good and this doc does not repeat it. What §4 is missing is everything *around* the copy:
which subs actually have demand, what stops a new account from posting at all, and which
threads to answer.

Researched 2026-08-25 against live Reddit feeds (`scripts/reddit-thread-finder.py`).

---

## ⚠️ First, what this is and is not worth

**Reddit will not move DA 1.** Every outbound link on Reddit is `rel="nofollow ugc"`. If the
goal is closing the authority gap — one referring domain, and that one a link-selling vendor —
this is the wrong tool. The 6 pre-written listicle emails in
[`OUTREACH_TARGETS.md`](./OUTREACH_TARGETS.md), still unsent, are worth more per hour than
anything below, because a followed editorial link is the only thing that moves the number that
is stuck.

Reddit is worth doing anyway, for three things that are **not** backlinks:

1. **Page-one presence on terms your own domain cannot reach this year.** `qravio.app` sits at
   **position 81** for the `dynamic qr code` family — 2,993 impressions, 0 clicks. You are not
   ranking that page in 2026. But Google's *Discussions and forums* block puts Reddit threads
   on page one for exactly these "best free / is X free" queries, and a well-upvoted comment in
   one of those threads is page-one real estate you can occupy this week.
2. **The LLM consensus corpus** — the original §4 rationale, and it is correct. "Which free QR
   generator should I use" answers in ChatGPT/Perplexity/AI Overviews are disproportionately
   assembled from Reddit. This is the §9 *AI share-of-voice* KPI.
3. **Actual conversations with the people who have the problem.** At 12 users, with no
   attribution data in the `users` table at all, a comment thread is currently the cheapest
   qualitative signal available — cheaper than the dormant-user emails, and from strangers who
   owe you no politeness.

**Calibrate:** expect tens of clicks a month and low single-digit signups, ramping. The
compounding part is (1) and (2), and those take months to show up.

---

## Step 0 — the gate nobody wrote down 🔒

**A new account cannot do any of this.** Most relevant subs enforce a karma/age minimum through
AutoMod, and removal is silent — your comment looks fine to you while logged in and is invisible
to everyone else. Reported gates (third-party database, 2026 — **re-read each sub's own rules
before posting, they change**):

| Sub | Gate | Promotion lane |
|---|---|---|
| r/smallbusiness | 100+ comment karma, 30+ day account | weekly "Promote Your Business" thread only |
| r/marketing | 60+ days, 100+ karma | "Marketing Monday" only |
| r/Entrepreneur | 10+ comment karma earned in-sub | banned in posts, tolerated in comments |
| r/SaaS | — | 1 promo post per 60 days; "Share Your SaaS Saturday" |
| r/webdev | 100+ karma, 30+ days | "Showoff Saturday" only |
| r/SideProject | low | any day, if you built it |

So the first two to four weeks are **account eligibility**, not promotion:

- [ ] **Use one real, named, human account.** Your own, with your face and history if you have
      one — check first, an existing account with age and karma skips most of this step. A
      `u/QravioApp` brand account gets filtered harder and reads as an ad even when the answer
      is good.
- [ ] **Never a second account.** Two accounts on the same product is vote manipulation /
      ban evasion — sitewide ban, and it poisons the brand inside the exact corpus §4 exists to
      win. This is the one line where the downside is unrecoverable.
- [ ] **Earn the karma in r/qrcode** (below). It is on-topic, it is where you are actually
      useful, and the karma you build there is the karma the gated subs check.
- [ ] **Hold the 90/10 rule** — nine genuinely useful comments for every one that names Qravio.
      Sitewide spam detection is per-account behavioural, not per-post.

---

## Where — corrected from §4's list

§4 lists r/QRcode, r/smallbusiness, r/marketing, r/restaurateur, r/Entrepreneur, r/web_design,
r/nonprofit as equals. **They are not equals.** Measured post flow and QR-question density:

### Tier 1 — r/qrcode. This is the whole game.

The only sub with a steady supply of the exact question Qravio answers. ~1–2 posts a day, so
you can read **every** thread; low enough traffic that a good answer stays visible for days
instead of minutes; and the crowd is technical enough to reward a precise static-vs-dynamic
answer (the §C "per-sub angle" note already had this right).

It is also where the free tier is the honest answer rather than a pitch — a recurring genre
there is *"is this free tool actually free"*, which is your positioning verbatim.

**Read the sub's own rules before the first comment.** Small subs usually have a blunt
self-promo rule and a mod who enforces it personally.

### Tier 2 — the "show what you built" lanes

Posts, not comments, and each is a one-shot: r/SideProject (lowest gate), r/SaaS *Share Your
SaaS Saturday*, r/Entrepreneur *Share Your Business*, r/smallbusiness *Promote Your Business*.

What works there is **not** "I built a QR generator" — that gets ignored. It is a specific
number attached to a real customer. A live example from r/SaaS this week: *"Built a QR
room-service portal for a boutique hotel. 209 orders, €4,941 through it this month"* — **115
upvotes, 26 comments**. Same product category, opposite framing. Your equivalent is the
`edtechcoordinatoriit` user with 16 QRs, or real scan totals from your own dataset — the same
data the §6 stats hub wants. Do not fabricate a number to fit the format.

### Tier 3 — the big subs, downgraded

r/smallbusiness (2M), r/Entrepreneur (4.5M), r/marketing (1.5M) have the **hardest** promo gates
and very little QR question flow. They are the worst ratio on the list — hardest to post in,
least demand. Do not "target" them and do not post there on a schedule. Answer only if a thread
happens to surface; the finder script will tell you when.

> **What was actually measured**, so you can judge it rather than take it:
>
> | Sub | Swept | Depth | QR threads found |
> |---|---|---|---|
> | r/Entrepreneur | 288 posts | **74 days** | **0** |
> | r/marketing | 25 posts | 12 days | **0** |
> | r/restaurateur | 24 posts | 23 days | **0** |
> | r/smallbusiness | 300 posts | 4.8 days | **0** |
>
> r/Entrepreneur is settled: 74 days, not one QR question. r/smallbusiness posts ~60 times a
> day, so even 300 posts is under five days — that one is *shallow*, not disproven, though five
> days of a 2M-member sub with zero QR mentions is not encouraging. Settle it if you want with
> `--sub smallbusiness --pages 40`.

r/restaurateur is the one Tier-3 sub worth a standing subscription despite the low flow: when a
QR-menu thread does appear, the `menu` QR type is a genuinely better answer than anything else
in the thread.

---

## Live thread list — captured 2026-08-25

Not a raw dump; these are the open r/qrcode threads where a §C answer is genuinely the best
comment in the thread. **Check each is still open before answering** — this list ages in days.

| Thread | Cmts | Which answer | Why it fits |
|---|---|---|---|
| [Is QR Code Monkey really 100% free?](https://www.reddit.com/r/qrcode/comments/1vwjd2i/is_qr_code_monkey_really_100_free/) | 21 | **§C Q1** | The best thread on the board for you: someone asking the watermark/static question about a named competitor. **Open QRCode Monkey's current pricing and check what its free tier actually does before you answer** — this repo has no verified note on it, and a wrong claim about a competitor in a technical sub is what gets a founder torched. Answer their question straight, then the static/dynamic distinction follows on its own. |
| [Free Multi Qr code generator recommendations](https://www.reddit.com/r/qrcode/comments/1vxudbn/free_multi_qr_code_generator_recommendations/) | 8 | **§C Q1** | Bulk generation, explicitly free. Posted today. |
| [QR code menus?](https://www.reddit.com/r/qrcode/comments/1vqx2j4/qr_code_menus/) | 16 | menu type | The `menu` QR type is a real answer here, not a stretch. |
| [Suggestions: QR code app that can plug into an API?](https://www.reddit.com/r/qrcode/comments/1vw2lmn/suggestions_qr_code_app_that_can_plug_into_an_api/) | 0 | — | `/api/public/v1` is a direct fit and almost nobody in this niche has a public API. Unanswered, so the first good comment owns it. |
| [Need to create a QR code for free?](https://www.reddit.com/r/qrcode/comments/1vuin8p/need_to_create_a_qr_code_for_free/) | 1 | **§C Q1** | Low engagement, but on the money term. |
| [What are all the vCard parameters for a static QR code?](https://www.reddit.com/r/qrcode/comments/1vmih90/what_are_all_the_vcard_parameters_for_a_static_qr/) | 1 | none — pure help | You have shipped vCard/vCard-plus with templates; you know this cold. **Mention nothing.** This is Step-0 karma. |
| [Can anyone help me recover/restore this QR code?](https://www.reddit.com/r/qrcode/comments/1vp45sb/can_anyone_help_me_recoverrestore_this_qr_code/) | 40 | none — pure help | The busiest thread in the sub. Recovery/decipher threads are the sub's core genre and the fastest karma available. |
| [Any Barcode & QR Code ideas that could inspire something new to build?](https://www.reddit.com/r/qrcode/comments/1vk3pky/any_barcode_qr_code_ideas_that_could_inspire/) | 2 | free `/scan` tool | The free scanner is a give-away, not a pitch — the right kind of thing to surface in an ideas thread. |

Re-run `scripts/reddit-thread-finder.py` for a current list.

---

## How — the part that decides whether this works

### The highest-value move: answer the *old* threads, not the new ones

A comment on a thread posted today gets ~72 hours of Reddit traffic and then dies. A comment on
a two-year-old thread that **already ranks on Google** for "best free qr code generator" gets
search traffic for as long as that thread ranks — and is the version an LLM is most likely to
have ingested.

So the search is not "what's new in r/qrcode". It is: **which Reddit threads already rank for
the terms you cannot rank for.** Find them by running your own money keywords with a
`site:reddit.com` restriction, and sort the results by *what ranks*, not by *what's recent*:

```
site:reddit.com best free qr code generator
site:reddit.com dynamic qr code free
site:reddit.com edit qr code after printing
site:reddit.com qr code menu restaurant
site:reddit.com "qr tiger" OR "flowcode" OR "uniqode" alternative
```

Do this in a normal browser — Reddit blocks scripted search, and Google needs to be the one
answering anyway, since you want *its* ranking, not Reddit's. Old threads are often archived
(locked after 6 months) — if it is locked, it is not an opportunity, move on.

Answering the recent threads still matters, but for a different reason: it is how you earn the
karma from Step 0 and how the sub learns your name. The finder script covers that half.

### Anatomy of a comment that survives

The §C answer bank is already the right shape. The rules that make it work:

- **Answer completely before you mention anything.** The test: delete every reference to Qravio
  and the comment must still be the best answer in the thread. If it collapses, don't post it.
- **Disclose in the same comment, not a reply.** `Full disclosure: I work on Qravio.` Late
  disclosure after someone asks is the thing that gets a brand torched.
- **Usually name it without a link.** A bare domain in a first comment is what most AutoMods
  key on, and a name is enough for someone who wants it. Link only when a sub allows it *and*
  someone asked. Counter-intuitively this also serves goal (2) — LLMs harvest the *text*, and
  the brand name in prose is what gets quoted.
- **Lead with the criterion, not the product.** *"Check two things on any free generator:
  does it watermark, and is it static or dynamic"* is the sentence that gets quoted back by
  other commenters and by models. "Use Qravio" is the sentence that gets downvoted.
- **Never paste the same text twice.** Reddit's sitewide filter catches duplicated comment
  bodies across threads faster than any human mod. Rewrite every time — §C is a source of
  *arguments*, not copy-paste text.
- **Recommend a competitor when it's the honest answer.** A thread where the person needs a
  static code for a one-off link does not need you. Being the person who says so is what makes
  the other 9 comments land.

### When it goes wrong

Comment silently removed → you tripped a karma gate or a link rule; check by opening the thread
in a logged-out private window. Downvoted → the answer was a pitch, not an answer; do not
re-post it elsewhere. Mod message → reply once, politely, and take the correction. A public
argument with a mod is permanently indexed next to your brand name.

---

## Tooling: `scripts/reddit-thread-finder.py`

Reddit blocks `curl`, `old.reddit`, and `/search` from this machine — but the feed endpoint the
web app itself calls still answers a plain GET. The script reads that, filters for QR-relevant
titles across the target subs and prints a dated markdown table. It is read-only: it never
posts, votes, or logs in.

```bash
python3 scripts/reddit-thread-finder.py                       # last 45 days, keyword hits
python3 scripts/reddit-thread-finder.py --days 90 --pages 8   # deeper crawl of busy subs
python3 scripts/reddit-thread-finder.py --sub qrcode --all    # every r/qrcode thread
```

Run it once a week. It replaces the §4 "build a watch-list of threads" checkbox, which was
never going to survive as a manual habit.

**What it cannot do:** find the *old ranking* threads above (Reddit blocks scripted search — use
Google), and read sub rules (also blocked — read them logged in, once, per sub).

---

## First 30 days

| Week | Do |
|---|---|
| 1 | Check whether you already have a seasoned account. Read the r/qrcode rules. Subscribe to the Tier-1/2/3 subs. Answer 3–5 r/qrcode threads with **no mention of Qravio at all** — pure karma and pattern-learning. |
| 2 | Run the Google `site:reddit.com` searches; save the ranking, unlocked threads. Keep answering r/qrcode. First disclosed mentions, only where the free dynamic tier is genuinely the answer. |
| 3 | Work the saved old-thread list — one good answer per thread, spaced out. One Tier-2 post if you have a real number to lead with. |
| 4 | Weekly finder run. Review which comments got upvoted — that is your signal for what to say next. |

Sustainable cadence after that: **3–5 comments a week, one post a month.** More than that and
the account starts reading as a marketing account, which costs you the thing you were building.

---

## Measurement

Reddit-specific, feeding §9:

- **Referral sessions from reddit.com** in GA4 — the direct half. Expect it to be small.
- **Which comments hold upvotes** after a week — the ones that do are the ones models quote.
- **AI share-of-voice** (§9's north star): monthly, ask ChatGPT / Perplexity / Google AI mode
  *"best free dynamic QR code generator"* and *"alternative to QR Tiger"*, and record whether
  Qravio appears. This is the KPI Reddit is actually for; it will not move for months.
- **Do not** track karma. It is a gate to clear, not a goal.

---

## Hard no's

- No second account, no friends upvoting, no "comment for the link" DM bait.
- No paid Reddit-marketing service. They run account farms; a sitewide ban follows the brand,
  not the account.
- No undisclosed mention, ever — including from a friend's account. In a corpus you are trying
  to win on trust, one exposed astroturf comment is worth more damage than a hundred good ones.
- No fabricated numbers in a Tier-2 post. Same rule as the §6 stats hub and §8b
  `aggregateRating`: real data or no data.

---

## Related

- [`OFFSITE_GEO_CHECKLIST.md`](./OFFSITE_GEO_CHECKLIST.md) §4 — the parent checklist item.
- [`GEO_CONTENT_PACK.md`](./GEO_CONTENT_PACK.md) §C — the four answer drafts and per-sub angles.
- [`OUTREACH_TARGETS.md`](./OUTREACH_TARGETS.md) — the 6 unsent listicle emails. **Higher value
  per hour than this document.** Send those first.
