# Dormant user outreach — 2026-08-05

6 real users signed up and never created a QR. Send these **manually from your
personal Gmail**, one at a time, not through Resend. Reasons: better inbox
placement, replies thread naturally into your inbox, and at n=6 a bulk send is
strictly worse than 6 individual sends.

**Rules for all of them:**
- Plain text. No logo, no HTML, no button, no footer, no unsubscribe design.
- From your real name and address, not `noreply@`.
- One question only. Not a survey, not a Typeform link.
- Name the actual day they signed up — it proves a human looked.
- Explicitly kill the fear of a sales sequence, or they won't reply.
- Give them permission to give the boring answer ("got distracted"). This is the
  single biggest lever on reply rate — most people don't reply because they
  assume you want a *good* reason.
- Send Tue–Thu, ~10–11am IST (most of these are Indian Gmail accounts).
- Do NOT ask them to come back in the first email. Asking for 30 seconds of
  opinion converts far better than asking them to do work.

Expect 2–3 replies out of 6. That is a good outcome, not a bad one.

---

## 1. rasheedaibrahim136@gmail.com — signed up Tue Aug 4 (yesterday)

Highest-value email of the six. Send today.

**Subject:** quick question about your qravio signup

```
Hi Rasheeda,

I'm Shaukat — I built Qravio. It's just me, no team.

I saw you signed up yesterday but didn't get as far as making a QR code.
I'm not selling you anything and this isn't an automated sequence — I'm
genuinely just trying to work out where the product loses people.

If you have 30 seconds: what were you trying to make, and what stopped you?

"I got distracted and forgot" is a completely valid answer and still useful
to me.

Thanks either way,
Shaukat
qravio.app
```

---

## 2. builder97083@gmail.com — signed up Sun Aug 2

Their workspace is named "Fan Syed Hamza mallik's Workspace", so the real first
name is unclear. Don't guess — open with "Hi there".

**Subject:** you signed up for qravio on saturday — what happened?

```
Hi there,

I'm Shaukat, the person who built Qravio (solo project).

You created an account on Saturday but never made a QR code, and I'd really
like to know why. No pitch, no follow-up sequence — I just want the honest
answer.

What were you hoping to do with it?

If the answer is "I was just poking around", that's fine and worth knowing too.

Thanks,
Shaukat
qravio.app
```

---

## 3. shaswatasengupta@gmail.com — signed up Thu Jul 31

**Subject:** quick q about qravio

```
Hi Shaswata,

I'm Shaukat — I built Qravio on my own.

You signed up last Thursday and didn't end up creating a QR code. I'm trying
to understand where people get stuck, so: what brought you to the site, and
what made you stop?

Genuinely just after the honest answer — I'm not going to add you to a drip
campaign.

Thanks,
Shaukat
qravio.app
```

---

## 4. sam.bodkin2011@gmail.com — signed up Jul 23 (~2 weeks)

Far enough back that they may not remember. Lower the bar accordingly.

**Subject:** you tried qravio a couple weeks ago

```
Hi Sam,

I'm Shaukat — I built Qravio.

You made an account about two weeks ago and never created a QR code. Long
enough that you might not remember, which is fine.

If anything does come back to you — what you were trying to do, or what put
you off — I'd really like to hear it. I'm a one-person shop and this kind of
feedback is basically my only signal.

No reply needed if nothing springs to mind.

Shaukat
qravio.app
```

---

## 5. kushallunkad201@gmail.com — signed up Jul 11 (~3.5 weeks)

Same shape as Sam's. Lowest priority of the recent group.

**Subject:** feedback on qravio?

```
Hi Kushal,

I'm Shaukat — I built Qravio by myself.

You signed up in mid-July but never made a QR code. I'm going through everyone
who did that and asking the same question: what were you trying to do, and
where did it fall down?

Even a one-line answer helps. If you don't remember, no worries at all.

Thanks,
Shaukat
qravio.app
```

---

## 6. edtechteacheriit@gmail.com — signed up May 19

**Different situation.** This address is almost certainly the same organisation
as `edtechcoordinatoriit@gmail.com`, who is your single best user (16 QRs).
So this isn't a stranger who bounced — it's a colleague of an active customer
who didn't take.

That makes the coordinator the better person to ask. Two options:

**Option A (recommended) — ask the active user instead:**

**Subject:** quick favour — a colleague of yours didn't stick with qravio

```
Hi,

Shaukat here — I built Qravio (solo).

You've made good use of it, which I really appreciate. I noticed someone else
from your side signed up back in May (edtechteacheriit@) and never made a
single QR.

Do you know why? Was it not relevant to their role, did they not know it was
available, or did they try and hit a wall?

You're my most active user so your read on this is worth more than anyone's.

Thanks,
Shaukat
```

This gets you an honest answer with no politeness filter, and it strengthens
your relationship with the user you can least afford to lose.

**Option B** — email the teacher directly, same template as #5. Weaker: three
months cold, and they may feel put on the spot about a tool their coordinator
chose.

---

## 7 & 8. pritamkunar13@gmail.com, pguru7079@gmail.com — Feb/Mar, no workspace

**Investigate before emailing.** Both have *zero* workspace rows. Every single
user since May 17 has one. So either:

- workspace auto-creation on signup didn't exist yet in Feb/March, or
- both of these accounts hit a signup failure and landed in a dead state

If it's the second, these two saw a broken product and there's a bug still
worth finding. If it's the first, it's ancient history — skip both emails, the
ROI on a 5-month-cold outreach is near zero.

Check the git history on the signup/workspace-creation path around Feb–May 2026
before spending an email on them.

---

## What to do with the answers

Sort every reply into one of three buckets. They need completely different fixes:

| Bucket | What it sounds like | Fix |
|---|---|---|
| **Wrong person** | "I only needed one QR for a wedding" | Nothing. SEO is pulling one-off consumer intent. Adjust which keywords you chase. |
| **Wrong expectation** | "I thought it was free / I didn't want an account" | Landing page or signup gate problem. Cheapest fix, biggest win. |
| **Product friction** | "I couldn't work out how to..." | Builder UX. Watch for the same step named twice — that's your bug. |

If 3+ replies land in the same bucket, that's your next sprint. If they scatter
across all three, you don't have a product problem — you have a traffic-quality
problem, and the fix is upstream in SEO, not in the app.

---

## The systemic gap this exposed

You described these as SEO users, but nothing in the database records that.
`users` is `id, email, full_name, avatar_url, role, created_at` — no referrer,
no landing page, no UTM, no "what are you here to make".

So you can't answer the question that actually matters: *which page is sending
you people who don't activate?* Right now you're inferring it.

Two cheap fixes, in priority order:

1. **Capture first-touch attribution at signup** — stash referrer + landing path
   + UTMs in a cookie on first visit, write them onto the user row at signup.
   Small change, and it compounds: every future cohort answers this question
   for itself instead of needing a manual email round.
2. **One question in onboarding** — a single "what are you making a QR for?"
   step with 5 preset chips. Gives you intent data on 100% of signups instead
   of a 30% reply rate on manual outreach, and it doubles as a way to skip
   people straight to the right QR type.

The emails above buy you one round of qualitative signal from 6 people. These
two changes buy you the same signal from everyone, forever.
