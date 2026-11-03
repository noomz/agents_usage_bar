#!/usr/bin/env python3
"""Writes synthetic home directories for scripts/parity-cli.sh.

Both CLIs run against these through HOME and CFFIXED_USER_HOME, which reach states the real
data rarely holds: stale and error rows, multi-login Codex, Grok variants, budgets, and
malformed files. Preferences and locale still come from the real user: cfprefsd ignores those
variables, and both CLIs only read them. Fake names and round numbers only.
"""
import json
import os
import sys

REF = 978307200
ASOF = 815000000.5


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(data)


def snap(pid, raw=None, **fields):
    s = {"providerID": pid, "asOf": ASOF, "raw": raw or {}}
    s.update(fields)
    return s


def state(pid, name, status, snapshot=None, **fields):
    s = {"id": pid, "displayName": name, "status": status}
    if snapshot:
        s["snapshot"] = snapshot
    s.update(fields)
    return s


class RawNumber(float):
    """Keeps a decimal literal's exact digits through json.dumps."""

    def __new__(cls, text):
        value = super().__new__(cls, text)
        value.text = text
        return value

    def __repr__(self):
        return self.text


OK = {"ok": {"lastSuccess": ASOF}}
UNAUTH = {"unauthenticated": {}}
STOPPED = {"notRunning": {}}
ERROR = {"error": {"_0": {"kind": "http", "message": "HTTP 503"}}}
STALE = {"stale": {"lastSuccess": ASOF, "error": {"kind": "network", "message": "offline"}}}
FAR = 900000000.0


def window(name, used=None, reset=None, duration=None):
    w = {"name": name}
    if used is not None:
        w["utilization"] = used
    if reset is not None:
        w["resetsAt"] = reset
    if duration is not None:
        w["duration"] = duration
    return w


def quota(used, limit=1, remaining=None):
    return {"used": used, "limit": limit, "remaining": max(0, limit - used) if remaining is None else remaining}


def rows_full():
    return [
        state("openrouter", "OpenRouter", OK, snap("openrouter", costTodayUSD=RawNumber("1.2345678901234567"), balanceUSD=RawNumber("9.405"),
              quota=quota(47.5, 50), periodSpendUSD={"day": RawNumber("1.25"), "week": RawNumber("8.1"), "month": RawNumber("31.4")})),
        state("claude", "Claude", STALE, snap("claude", tokensToday=232400512, costTodayUSD=RawNumber("273.86034999999999"), quota=quota(0.47),
              quotaWindows=[window("alpha 5h", 0.12, FAR), window("alpha 7d", 0.17, FAR + 5), window("beta 5h", 0.31, FAR + 9), window("beta 7d", 0.47, FAR + 2)],
              accounts=[
                  {"name": "beta", "costTodayUSD": RawNumber("220.23"), "tokensToday": 5, "quota": quota(0.47), "quotaWindows": [window("5h", 0.31, FAR), window("7d", 0.47, FAR + 99)]},
                  {"name": "alpha", "costTodayUSD": RawNumber("53.63"), "quota": quota(0.17), "quotaWindows": [window("5h", 0.12, FAR), window("7d", 0.17)]},
                  {"name": "gamma-日本語-long-account-name"},
              ]), lastSuccess=ASOF),
        state("codex", "Codex", OK, snap("codex", tokensToday=18404, costTodayUSD=RawNumber("0.07000000000000001024"), quota=quota(0.8),
              accounts=[
                  {"name": "team", "quota": quota(0.8), "quotaWindows": [window("primary", 0.8, FAR, 18000), window("secondary", 0.1, FAR + 3600, 604800)]},
                  {"name": "plus", "quota": quota(0.2), "quotaWindows": [window("primary", 0.2, FAR + 5, 18000), window("secondary", 0.9, FAR + 7200, 604800)]},
                  {"name": "guest"},
                  {"name": "named", "quotaWindows": [window("primary", None, None, 300), window("secondary", 0.00001, None, 90)]},
              ])),
        state("gemini", "Gemini", ERROR, snap("gemini", {"note": "usage-temporarily-unavailable"}, quota=quota(0.19),
              quotaWindows=[window("gemini-2.5-pro", 0.19, FAR), window("gemini-2.5-flash-lite", 0.5, FAR), window("gemini-x", None)])),
        state("grok", "Grok", OK, snap("grok", {"period": "May 2026"}, quota=quota(0.6, 1), quotaWindows=[window("credits", 0.6, FAR)])),
        state("pi-local", "Local Llama", OK, snap("pi-local", tokensToday=999950, costTodayUSD=0)),
        state("ollama", "Ollama", OK, snap("ollama", {"modelCount": "3", "modelName": "m:1", "installedCount": "5"})),
        state("ollama-cloud", "Ollama Cloud", OK, snap("ollama-cloud", {"plan": "pro"}, quota=quota(0.62), quotaWindows=[window("mo", 0.62, FAR)])),
        state("lmstudio", "LM Studio", OK, snap("lmstudio", {"loadingModel": "true"})),
        state("lms-llamacpp", "LM Studio llama.cpp", STOPPED, placeholderMessage="Start the server"),
        state("llamacpp", "llama.cpp", OK, snap("llamacpp", {"modelCount": "1", "modelName": "Q", "vramBytes": "3221225472"})),
        state("engine.GPU-box", "A very long engine display name indeed", OK, snap("engine.GPU-box", {"modelCount": "0", "installedCount": "0"})),
        state("engine.off", "Off", {"disabled": {}}),
        state("engine.idle", "Idle", OK, snap("engine.idle", {"modelCount": "0"})),
    ]


def rows_variants():
    return [
        state("openrouter", "OpenRouter", OK, snap("openrouter", balanceUSD=RawNumber("-3.5"))),
        state("claude", "Claude", OK, snap("claude", tokensToday=0, quotaWindows=[window("5h", 0.5, FAR, None), window("7d", 0.5, FAR - 9), window("7d-opus", 0.99, FAR)])),
        state("codex", "Codex", OK, snap("codex", tokensToday=1, quotaWindows=[window("primary", 0.494999, 815000000.0), window("secondary", 0.7996, 800000000.0)])),
        state("gemini", "Gemini", UNAUTH),
        state("grok", "Grok", OK, snap("grok", costTodayUSD=RawNumber("1.005"), balanceUSD=RawNumber("12.5"), tokensToday=1000000000)),
    ]


def rows_grok_balance():
    return [
        state("grok", "Grok", OK, snap("grok", balanceUSD=RawNumber("7"))),
        state("codex", "Codex", OK, snap("codex", tokensToday=1, costTodayUSD=RawNumber("2.5"), accounts=[{"name": "solo", "quota": quota(0.1)}])),
        state("gemini", "Gemini", OK, snap("gemini", quota=quota(0.3, 1))),
        state("openrouter", "OpenRouter", OK, snap("openrouter")),
    ]


def rows_grok_nothing():
    return [
        state("grok", "Grok", OK, snap("grok", quota=quota(0.3, 1), balanceUSD=RawNumber("1"))),
        state("codex", "Codex", OK, snap("codex", quota=quota(5, 0))),
    ]


def cache(rows, schema=3):
    flat = []
    for r in rows:
        flat += [r["id"], r]
    doc = {"schemaVersion": schema, "providers": flat, "baselines": []}
    if schema >= 2:
        doc["transcripts"] = {}
    if schema >= 3:
        doc["dailyUsage"] = []
    return json.dumps(doc, ensure_ascii=False)


def iso(day, hour):
    return "%sT%02d:00:00Z" % (day, hour)


def day_account(key, model, plan=None, cost=None, tokens=None, quota=None):
    a = {"key": key, "label": key, "billingModel": model, "billingModelAssumed": False, "quota": quota or {}}
    if plan:
        a["plan"] = plan
    if cost is not None:
        a["costUSD"] = cost
    if tokens is not None:
        a["tokens"] = tokens
    return a


def record(provider, accounts, origin="observed", **fields):
    r = {"provider": provider, "costEstimated": False, "quota": {}, "accounts": accounts, "origin": origin}
    r.update(fields)
    return r


def history_day(key, n):
    q = {"5h": {"peak": [0.25, 0.5, 0.85, 1.0, 0.00001][n % 5], "peakResetsAt": iso(key, 14), "endOfDay": 0.125},
         "quota": {"peak": 0.3, "endOfDay": 0.3}, "7d": {"peak": 0.1, "endOfDay": 0.1}}
    records = [
        record("openrouter", [day_account("default", "metered")], tokens=1000 * n, costUSD="%d.1234567" % n, balanceUSD="20.5"),
        record("codex", [day_account("a,b", "metered"), day_account('q"x', "subscription", "plus")], "backfilled" if n % 5 == 4 else "observed", tokens=50000, costUSD="3", costEstimated=True, quota={} if n % 5 == 4 else q),
        record("ollama", [day_account("default", "local")]),
        record("engine.box", [day_account("default", "local")]),
        record("mystery", [day_account("m", "metered", cost="1.5"), day_account("n", "subscription", "z", cost="2.5", tokens=7, quota={"5h": {"peak": 0.5, "endOfDay": 0.5}})], tokens=8, timeZone="UTC"),
    ]
    if n % 7 != 6:
        records.append(record("claude", [day_account("work", "subscription", "max", cost="4", quota=q), day_account("home", "subscription", "pro", cost="1")], tokens=100000, costUSD="5.5", costEstimated=True, quota=q, firstSeen=iso(key, 9), lastSeen=iso(key, 18)))
    events = [
        {"time": iso(key, 12), "provider": "claude", "kind": k, "window": "5h", "account": "work", "fraction": 0.81, "notified": True, "carriedOver": False}
        for k in ["band80", "band95", "band100", "pace", "reset", "authLost", "authRecovered"][: n % 8]
    ] + [{"time": iso(key, 13), "kind": "budgetWarning", "fraction": 1.0, "notified": False, "carriedOver": True},
         {"time": iso(key, 14), "provider": "openrouter", "kind": "budgetLimit", "fraction": 0.5, "notified": True, "carriedOver": False}]
    return json.dumps({"schemaVersion": 1, "date": key, "timeZone": "Asia/Bangkok", "records": records, "events": events, "backfillChecked": ["codex"]}, ensure_ascii=False)


def main(root):
    support = "Library/Application Support/AgentsUsageBar"

    def home(name, rows=None, schema=3, raw_cache=None, history=False, config=None):
        h = os.path.join(root, name)
        os.makedirs(os.path.join(h, support), exist_ok=True)
        if rows is not None:
            write(os.path.join(h, support, "today.json"), cache(rows, schema))
        if raw_cache is not None:
            write(os.path.join(h, support, "today.json"), raw_cache)
        if history:
            for n in range(1, 31):
                key = "2026-09-%02d" % n
                write(os.path.join(h, support, "history", key + ".json"), history_day(key, n))
            write(os.path.join(h, support, "history", ".account-salt"), "x")
            write(os.path.join(h, support, "history", "notes.txt"), "x")
            write(os.path.join(h, support, "history", "2026-08-01.json"), '{"schemaVersion":2}')
            write(os.path.join(h, support, "history", "2026-08-02.json"), "garbage")
            write(os.path.join(h, support, "history", "2026-08-03.json"), history_day("2026-08-09", 1))
        if config is not None:
            write(os.path.join(h, ".config/agents-usage-bar/config.toml"), config)

    budgets = "[budgets]\ntotal_usd = 50\nclaude_usd = 20.5\ncodex_usd = 0\nopenrouter_usd = 1.005\ngrok_usd = 5\n[engine.GPU-box]\nport = 9\n"
    home("full", rows_full(), history=True, config=budgets)
    home("variants", rows_variants())
    home("grok-balance", rows_grok_balance())
    home("grok-nothing", rows_grok_nothing())
    home("schema1", rows_variants(), schema=1)
    home("schema2", rows_variants(), schema=2)
    home("schema9", rows_variants(), schema=9)
    home("corrupt", raw_cache="{not json")
    home("bad-row", raw_cache='{"schemaVersion":3,"providers":["x",{"id":"x"}],"baselines":[],"transcripts":{},"dailyUsage":[]}')
    home("empty")
    h = os.path.join(root, "history-file")
    os.makedirs(os.path.join(h, support), exist_ok=True)
    write(os.path.join(h, support, "history"), "not a directory")
    h = os.path.join(root, "history-noperm")
    os.makedirs(os.path.join(h, support, "history"), exist_ok=True)
    os.chmod(os.path.join(h, support, "history"), 0)


if __name__ == "__main__":
    main(sys.argv[1])
