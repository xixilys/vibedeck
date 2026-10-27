#!/usr/bin/env python3
# VibeDeck 远程采集器：在远端主机上只读 opencode 的 SQLite，把每条 assistant 消息的 token
# 用量按 JSON Lines 打到 stdout，最后一行固定为哨兵。仅用标准库，兼容 Python 3.6+。
# 用法：python3 vibedeck-collector.py [--db PATH] [--since MS]
#       python3 vibedeck-collector.py --summary                 # 今日各 CLI 用量汇总（单行 JSON）
#       python3 vibedeck-collector.py --records --since MS [--gz] # Claude / Codex 逐条请求用量（WSL / Linux 远程日统计）
#       python3 vibedeck-collector.py --selftest
#       cat vibedeck-collector.py | python3 - [--db PATH] [--since MS | --summary]
import argparse, json, os, sys
import calendar, datetime, re, time
import base64, collections, zlib
import math, shlex, subprocess, stat, uuid, selectors, shutil

try:
    import sqlite3
except ImportError:  # 模块缺失时也要给出失败哨兵
    sqlite3 = None

# 只取 assistant 且带 tokens 的行；字段用 json_extract 在 SQL 里取，便于筛选
_FIELDS = (("model", "$.modelID"), ("provider", "$.providerID"), ("inp", "$.tokens.input"),
           ("outp", "$.tokens.output"), ("reasoning", "$.tokens.reasoning"),
           ("cache_read", "$.tokens.cache.read"), ("cache_write", "$.tokens.cache.write"))
SQL_COLS = ("id, session_id, time_created, time_updated, "
            + ", ".join("json_extract(data,'%s') AS %s" % (p, n) for n, p in _FIELDS) + ", data AS raw")
WHERE = "json_extract(data,'$.role')='assistant' AND json_extract(data,'$.tokens') IS NOT NULL"
_FIELDS_V2 = (("model", "$.model.id"), ("provider", "$.model.providerID")) + _FIELDS[2:]
SQL_COLS_V2 = ("id, session_id, time_created, time_updated, "
               + ", ".join("json_extract(data,'%s') AS %s" % (p, n) for n, p in _FIELDS_V2) + ", data AS raw")
WHERE_V2 = "type='assistant' AND json_extract(data,'$.tokens') IS NOT NULL"

def resolve_db(explicit):
    # 默认：$XDG_DATA_HOME/opencode/opencode.db，否则 ~/.local/share/opencode/opencode.db
    base = explicit if explicit else os.environ.get("XDG_DATA_HOME")
    return os.path.join(base if base else os.path.expanduser("~/.local/share"), "opencode", "opencode.db")

def to_num(v):
    # 缺失/null/非法 → 0；负数一律归 0
    try:
        n = int(v)
    except (TypeError, ValueError):
        return 0
    return n if n > 0 else 0

def to_str(v):
    return v if isinstance(v, str) else ""

def emit_fail(reason):
    # 失败哨兵只写 stdout，其余诊断走 stderr
    sys.stdout.write(json.dumps({"__ok__": False, "error": reason[:200]}, separators=(",", ":")) + "\n")
    sys.stderr.write("vibedeck-collector: %s\n" % reason)
    sys.stdout.flush()

def run(db_path, since):
    if sqlite3 is None:
        emit_fail("python sqlite3 module unavailable")
        return 1
    if not os.path.exists(db_path):
        emit_fail("db not found: %s" % db_path)
        return 1
    conn = None
    try:
        # 只读打开 + busy_timeout，绝不写库
        conn = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
        conn.execute("PRAGMA busy_timeout=4000")
        conn.execute("PRAGMA query_only=1")
        cur = conn.cursor()
        tables = set(r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'"))
        # opencode v1.2x moved assistant rows from `message` to `session_message` (model under data.model).
        queries = []
        if "message" in tables:
            queries.append("SELECT " + SQL_COLS + " FROM message WHERE " + WHERE)
        if "session_message" in tables:
            queries.append("SELECT " + SQL_COLS_V2 + " FROM session_message WHERE " + WHERE_V2)
        rows = []
        for sql in queries:
            params = ()
            if since and since > 0:
                sql += " AND time_updated > ? ORDER BY time_updated"
                params = (since,)
            rows.extend(cur.execute(sql, params).fetchall())
        out = sys.stdout
        count = 0
        max_u = 0
        for row in rows:
            # 防御：data 解析失败就静默跳过，绝不崩溃、绝不输出
            try:
                data = json.loads(row[11])
            except (TypeError, ValueError):
                continue
            u = to_num(row[3])
            rec = {"id": to_str(row[0]), "t": to_num(row[2]) // 1000, "u": u, "s": to_str(row[1]),
                   "m": to_str(row[4]), "p": to_str(row[5]), "in": to_num(row[6]), "out": to_num(row[7]),
                   "r": to_num(row[8]), "cr": to_num(row[9]), "cw": to_num(row[10])}
            timing = data.get("time") if isinstance(data, dict) else None
            if isinstance(timing, dict):
                created, completed = _finite_number(timing.get("created")), _finite_number(timing.get("completed"))
                if created is not None and completed is not None:
                    _add_seconds(rec, (completed - created) / 1000.0, rec["out"] + rec["r"])
            out.write(json.dumps(rec, separators=(",", ":")) + "\n")
            count += 1
            if u > max_u:
                max_u = u
        out.write(json.dumps({"__ok__": True, "count": count, "max_u": max_u}, separators=(",", ":")) + "\n")
        out.flush()
        return 0
    except Exception as exc:  # 任何查询/连接错误都转成失败哨兵
        emit_fail("%s: %s" % (type(exc).__name__, exc))
        return 1
    finally:
        if conn is not None:
            conn.close()

# ---- 汇总模式：今日各 CLI 用量（只读；单代理失败即省略该键）----
_ISO_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|z|[+-]\d{2}:?\d{2})?")

def _today_start_ms():
    # 远端本地日历日 0 点（毫秒），与 sqlite date('now','localtime') 对齐
    lt = time.localtime()
    return int(time.mktime(tuple(lt[:3]) + (0, 0, 0, 0, 0, -1))) * 1000

def _iso_epoch(s):
    # ISO8601 → UTC epoch；保留小数秒，Z / ±HH:MM 都支持，坏值返回 None
    m = _ISO_RE.match(s.strip()) if isinstance(s, str) else None
    if not m:
        return None
    y, mo, d, h, mi, sec = (int(m.group(i)) for i in range(1, 7))
    dg = (m.group(7) or "Z")[1:].replace(":", "")
    off = 0 if not dg else (-1 if m.group(7)[0] == "-" else 1) * (int(dg[:2]) * 3600 + (int(dg[2:4]) if len(dg) >= 4 else 0) * 60)
    try:
        fractional = re.search(r"\.(\d+)", m.group(0))
        return calendar.timegm((y, mo, d, h, mi, sec, 0, 0, 0)) - off + (float("0." + fractional.group(1)) if fractional else 0)
    except (ValueError, OverflowError):
        return None

def _files(root, cutoff, suffix=".jsonl"):
    # 遍历 root，产出 (path, 行列表)；mtime < cutoff 或读失败则跳过
    for dp, _d, names in os.walk(root, onerror=lambda _e: None):
        for nm in names:
            p = os.path.join(dp, nm)
            try:
                if not nm.endswith(suffix) or os.path.getmtime(p) < cutoff:
                    continue
                yield p, open(p, encoding="utf-8", errors="replace").read().splitlines()
            except OSError:
                pass

def _collect_opencode(start_ms):
    # opencode：一次 SQL 聚合；口径 = input+cache.read+cache.write / output+reasoning
    if sqlite3 is None:
        return None
    try:
        conn = sqlite3.connect("file:" + resolve_db(None) + "?mode=ro", uri=True)
        conn.execute("PRAGMA busy_timeout=4000"); conn.execute("PRAGMA query_only=1")
        sums = ",".join("COALESCE(SUM(json_extract(data,'$.tokens.%s')),0)" % c
                        for c in ("input", "cache.read", "cache.write", "output", "reasoning"))
        row = conn.execute("SELECT " + sums + ",COUNT(*) FROM message WHERE " + WHERE
                           + " AND time_created >= ?", (start_ms,)).fetchone()
        conn.close()
    except Exception:
        return None
    if not row or to_num(row[5]) <= 0:
        return None
    return {"ctx": to_num(row[0]) + to_num(row[1]) + to_num(row[2]), "cache_read": to_num(row[1]), "cache_write": to_num(row[2]),
            "out": to_num(row[3]) + to_num(row[4]), "think": to_num(row[4]), "requests": to_num(row[5])}

def _read_claude_usage(home):
    # The statusline file remains preferred when it is newer; Claude's own cached
    # utilization is a bounded fallback and is normalized without account metadata.
    candidates = []
    for order, path in enumerate(_claude_usage_paths(home)):
        obj = _read_json_bounded([path], 256 * 1024)
        normalized = _normalize_claude_usage(obj)
        if normalized is not None:
            candidates.append((normalized.get("_captured_at"), -order, normalized))
    cache = _read_json_bounded([os.path.join(home, ".claude.json")], 2 * 1024 * 1024)
    cached = cache.get("cachedUsageUtilization") if isinstance(cache, dict) else None
    if isinstance(cached, dict):
        fetched_ms = _finite_number(cached.get("fetchedAtMs"))
        utilization = cached.get("utilization")
        if fetched_ms is not None and fetched_ms > 0 and isinstance(utilization, dict):
            raw = {"_captured_at": fetched_ms / 1000.0}
            for key in ("five_hour", "seven_day"):
                window = utilization.get(key)
                if isinstance(window, dict):
                    raw[key] = {"used_percentage": window.get("utilization"),
                                "resets_at": _iso_epoch(window.get("resets_at"))}
            normalized = _normalize_claude_usage(raw)
            if normalized is not None:
                candidates.append((normalized.get("_captured_at"), 0, normalized))
    if not candidates:
        return None
    # Known capture times outrank legacy snapshots without one; among known times,
    # take the newest valid snapshot. Ties retain the first standard source.
    return max(candidates, key=lambda item: (item[0] is not None,
                                              item[0] if item[0] is not None else 0,
                                              item[1]))[2]

def _normalize_claude_usage(obj):
    if not isinstance(obj, dict):
        return None
    out = {}
    captured = _finite_number(obj.get("_captured_at"))
    if captured is not None:
        out["_captured_at"] = captured
    for key, value in obj.items():
        if key == "_captured_at" or not isinstance(value, dict):
            continue
        if key not in ("five_hour", "seven_day") and not key.startswith(("five_hour_", "seven_day_")):
            continue
        used = _pct(value.get("used_percentage"))
        if used is None:
            continue
        win = {"used_percentage": used}
        reset = _finite_number(value.get("resets_at"))
        if reset is not None:
            win["resets_at"] = reset
        out[key] = win
    return out if any(key != "_captured_at" for key in out) else None

def _finite_number(value):
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
        return number if math.isfinite(number) else None
    except (TypeError, ValueError, OverflowError):
        return None

def _pct(value):
    number = _finite_number(value)
    return max(0.0, min(100.0, number)) if number is not None else None

def _claude_usage_paths(home):
    paths = []
    config = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    if config:
        paths.append(os.path.join(os.path.expanduser(config), "claude-usage.json"))
    paths.extend((os.path.join(home, ".claude", "claude-usage.json"),
                  os.path.join(home, ".config", "claude", "claude-usage.json")))
    return paths

def _read_json_bounded(paths, max_bytes):
    for path in paths:
        try:
            with open(path, "rb") as fh:
                raw = fh.read(max_bytes + 1)
            if len(raw) > max_bytes:
                continue
            value = json.loads(raw.decode("utf-8", "replace"))
            if isinstance(value, dict):
                return value
        except (OSError, ValueError, UnicodeError):
            continue
    return None

def _identity(provider, account_id, workspace=None):
    import uuid, unicodedata
    def identifier(value):
        if not isinstance(value, str): return None
        value = value.strip()
        if not value or any(unicodedata.category(c) in ("Cc", "Cf") for c in value): return None
        try: return str(uuid.UUID(value))
        except ValueError: return value
    subject, provider = identifier(account_id), identifier(provider)
    if not subject or not provider: return {}
    provider = {"codex": "openai", "claude": "anthropic"}.get(provider.lower(), provider.lower())
    result = {"account_provider": provider, "account_id": subject}
    org = identifier(workspace)
    if org: result["account_workspace"] = org
    return result

def _codex_session_identity(path):
    # Session creator provenance, not a claim about a mid-session login change.
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            remaining = 256 * 1024
            for _ in range(64):
                line = fh.readline(remaining + 1)
                remaining -= len(line)
                if not line or remaining < 0: break
                try: row = json.loads(line)
                except ValueError: continue
                if isinstance(row, dict) and row.get("type") == "session_meta":
                    meta = row.get("payload")
                    if isinstance(meta, dict):
                        return _identity(meta.get("model_provider"), meta.get("creator_account_id"))
                    return {}
    except OSError: pass
    return {}

def _claude_quota_identity(home, usage):
    # Cached quota has no historical owner. Only bind after the current metadata
    # file existed, and only for the same default profile and direct route.
    custom = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    if custom and os.path.realpath(os.path.expanduser(custom)) != os.path.realpath(os.path.join(home, ".claude")): return {}
    settings = _read_json_bounded([os.path.join(home, ".claude", "settings.json")], 2 * 1024 * 1024) or {}
    route = (settings.get("env") or {}).get("ANTHROPIC_BASE_URL") if isinstance(settings.get("env"), dict) else None
    route = route or os.environ.get("ANTHROPIC_BASE_URL", "")
    if route and not isinstance(route, str): return {}
    if route:
        from urllib.parse import urlparse
        host = urlparse(route).hostname or ""
        if host != "anthropic.com" and not host.endswith(".anthropic.com"): return {}
    path = os.path.join(home, ".claude.json")
    state = _read_json_bounded([path], 2 * 1024 * 1024) or {}
    account = state.get("oauthAccount")
    if not isinstance(account, dict): return {}
    captured = _finite_number((usage or {}).get("_captured_at"))
    try: identity_at = os.path.getmtime(path)
    except OSError: return {}
    if usage and (captured is None or captured < identity_at): return {}
    return _identity("anthropic", account.get("accountUuid"), account.get("organizationUuid"))

def _window(used, resets_at=None, captured_at=None, seconds=None):
    pct = _pct(used)
    if pct is None:
        return None
    result = {"used_percentage": pct}
    if resets_at is not None:
        result["resets_at"] = resets_at
    if captured_at is not None:
        result["captured_at"] = captured_at
    if seconds is not None and _finite_number(seconds) is not None:
        result["window_seconds"] = max(0.0, float(seconds))
    return result

def _codex_rate_limits(value, depth=0):
    if depth > 8 or not isinstance(value, dict):
        return None
    if "primary" in value or "secondary" in value:
        return value
    for child in value.values():
        found = _codex_rate_limits(child, depth + 1)
        if found is not None:
            return found
    return None

def _codex_recent_files(home, now):
    base = os.environ.get("CODEX_HOME") or os.path.join(home, ".codex")
    found = []
    # Date-addressed directories keep traversal bounded to the last eight local days.
    lt = time.localtime(now)
    today = datetime.date(lt.tm_year, lt.tm_mon, lt.tm_mday)
    for back in range(8):
        day = (today - datetime.timedelta(days=back)).strftime("%Y/%m/%d")
        for sub in ("sessions", "archived_sessions"):
            directory = os.path.join(base, sub, day)
            try:
                names = os.listdir(directory)
            except OSError:
                continue
            for name in names:
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(directory, name)
                try:
                    mt = os.path.getmtime(path)
                    if now - mt <= 8 * 86400:
                        found.append((mt, path))
                except OSError:
                    pass
    return [p for _mt, p in sorted(found, reverse=True)[:48]]

def _read_tail(path, max_bytes):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - max_bytes))
            data = fh.read(max_bytes)
        if size > max_bytes:
            data = data[data.find(b"\n") + 1:] if b"\n" in data else b""
        return data.decode("utf-8", "replace").splitlines()
    except OSError:
        return []

def _codex_quotas(home, now, include_identity=False):
    best, plan, best_captured, account = None, "", -1, {}
    for path in _codex_recent_files(home, now):
        for line in _read_tail(path, 256 * 1024):
            if "used_percent" not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            limits = _codex_rate_limits(row)
            if limits is None:
                continue
            # Spark and other named buckets are separate limits. Only the main Codex
            # bucket belongs in this platform row; old logs omitted limit_id entirely.
            if "limit_id" in limits and limits.get("limit_id") != "codex":
                continue
            captured = _iso_epoch(row.get("timestamp")) or _finite_number(row.get("timestamp"))
            if captured is None:
                captured = os.path.getmtime(path)
            if captured <= best_captured:
                continue
            bucket, priority = {}, {}
            for field in ("primary", "secondary"):
                window = limits.get(field)
                if not isinstance(window, dict):
                    continue
                mins = _finite_number(window.get("window_minutes"))
                if mins is None or mins <= 0:
                    continue
                weekly = mins >= 1440
                slot = "seven_day" if weekly else "five_hour"
                seconds = mins * 60
                parsed = _window(window.get("used_percent"), _finite_number(window.get("resets_at")), captured, seconds)
                source_priority = 0 if field == "primary" else 1
                if parsed is not None and source_priority < priority.get(slot, 2):
                    bucket[slot] = parsed
                    priority[slot] = source_priority
            if bucket:
                best, best_captured = bucket, captured
                account = _codex_session_identity(path)
                plan = limits.get("plan_type") if isinstance(limits.get("plan_type"), str) else ""
    if best is None:
        return ({}, "", None, {}) if include_identity else ({}, "", None)
    return (best, plan, best_captured, account) if include_identity else (best, plan, best_captured)

def _grok_quota(home):
    """Newest "fetched credits config" line. Grok ≥1.0.67 no longer logs it, so the newest one can sit well before
    the log tail; widen once before giving up. The tier comes from the newest line that names it."""
    path = os.path.join(home, ".grok", "logs", "unified.jsonl")
    tier, best = "", None
    for limit in (512 * 1024, 8 * 1024 * 1024):
        lines = _read_tail(path, limit)
        for line in reversed(lines):
            if "fetched credits config" not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            ctx = row.get("ctx") if isinstance(row.get("ctx"), dict) else {}
            cfg = ctx.get("config") if isinstance(ctx.get("config"), dict) else {}
            if not tier and isinstance(ctx.get("subscriptionTier"), str):
                tier = ctx["subscriptionTier"]
            if best is not None:
                if tier: break
                continue
            period = cfg.get("currentPeriod") if isinstance(cfg.get("currentPeriod"), dict) else {}
            # Grok omits creditUsagePercent while it is 0 (protobuf default); a period without it means unused.
            used = _pct(cfg.get("creditUsagePercent", 0 if period else None))
            if used is None:
                continue
            start, end = _iso_epoch(period.get("start")), _iso_epoch(period.get("end"))
            captured = _iso_epoch(row.get("ts"))
            best = _window(used, end, captured, max(0, end - start) if start is not None and end is not None else None)
        try:
            whole = os.path.getsize(path) <= limit
        except OSError:
            whole = True
        if best is not None or whole:
            break
    return best, tier

# Antigravity's quota: written by the statusline hook (VibeDeck's, or VibeGauge's before the rename) or agy-hud.
_AGY_QUOTA_FILES = ((".config", "vibedeck", "agy-quota.json"), (".config", "vibegauge", "agy-quota.json"),
                    (".cache", "agy-hud", "quota_cache.json"))

def _agy_quota_file(home):
    best, best_at = None, -1.0
    for parts in _AGY_QUOTA_FILES:
        obj = _read_json_bounded([os.path.join(home, *parts)], 1024 * 1024)
        if isinstance(obj, dict) and isinstance(obj.get("pools"), dict):
            at = _finite_number(obj.get("updated_at")) or 0.0
            if at > best_at:
                best, best_at = obj, at
    return best

def _agy_quotas(home):
    obj = _agy_quota_file(home)
    if obj is None:
        return None, None
    pools = obj["pools"]
    captured_default = _finite_number(obj.get("updated_at"))
    def parse(pool_name, field, default_seconds):
        pool = pools.get(pool_name)
        value = pool.get(field) if isinstance(pool, dict) else None
        if not isinstance(value, dict):
            return None
        remaining = _finite_number(value.get("remaining_fraction"))
        if remaining is None:
            return None
        used = max(0.0, min(100.0, (1.0 - remaining) * 100.0))
        seconds = default_seconds
        return _window(used, _finite_number(value.get("reset_at")),
                       _finite_number(value.get("recorded_at")) or captured_default, seconds)
    return {"five_hour": parse("gemini", "5h", 5 * 3600),
            "seven_day": parse("gemini", "weekly", 7 * 86400),
            "secondary_name": "3p",
            "secondary_five_hour": parse("3p", "5h", 5 * 3600),
            "secondary_seven_day": parse("3p", "weekly", 7 * 86400)}, captured_default

def _glm_keys(home):
    """(host, key) pairs for GLM Coding Plan keys opencode already uses; env vars as fallback."""
    out = []
    def add(host, key):
        if isinstance(key, str) and key.strip() and (host, key.strip()) not in out:
            out.append((host, key.strip()))
    try:
        with open(os.path.join(home, ".config", "opencode", "opencode.json"), encoding="utf-8") as fh:
            providers = json.load(fh).get("provider") or {}
    except (OSError, ValueError, AttributeError):
        providers = {}
    for name, cfg in providers.items() if isinstance(providers, dict) else []:
        opts = cfg.get("options") if isinstance(cfg, dict) and isinstance(cfg.get("options"), dict) else {}
        base = str(opts.get("baseURL") or "")
        if "bigmodel.cn" in base or "api.z.ai" in base or name in ("zhipuai-coding-plan", "zai-coding-plan"):
            key = opts.get("apiKey")
            m = re.match(r"^\{env:(\w+)\}$", key or "") if isinstance(key, str) else None
            if m: key = os.environ.get(m.group(1), "")
            add("api.z.ai" if "z.ai" in base or name.startswith("zai") else "open.bigmodel.cn", key)
    for env, host in (("ZHIPU_API_KEY", "open.bigmodel.cn"), ("ZAI_API_KEY", "api.z.ai")):
        add(host, os.environ.get(env, ""))
    return out

def _glm_quota(home, now=None):
    """GLM Coding Plan windows from /api/monitor/usage/quota/limit, cached 5 min so every pull does not call it.
    Returns a platform row or None. The key never leaves this host; only its 8-char fingerprint is reported."""
    import hashlib
    now = time.time() if now is None else now
    cache_path = os.path.join(home, ".cache", "vibedeck", "glm-quota.json")
    try:
        with open(cache_path, encoding="utf-8") as fh:
            cached = json.load(fh)
        if isinstance(cached, dict) and now - float(cached.get("at", 0)) < 300:
            return cached.get("row")
    except (OSError, ValueError, TypeError):
        pass
    row = None
    for host, key in _glm_keys(home)[:2]:
        try:
            import urllib.request
            req = urllib.request.Request("https://%s/api/monitor/usage/quota/limit" % host,
                                         headers={"Authorization": "Bearer " + key, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=6) as resp:
                body = json.loads(resp.read(256 * 1024).decode("utf-8", "replace"))
        except Exception:
            continue
        data = body.get("data") if isinstance(body, dict) else None
        if body.get("code") != 200 or not isinstance(data, dict):
            continue
        limits = [l for l in (data.get("limits") or []) if isinstance(l, dict) and _finite_number(l.get("percentage")) is not None]
        def seconds(l):
            unit, number = l.get("unit"), _finite_number(l.get("number")) or 1
            return {3: 3600, 4: 86400, 5: 86400, 6: 7 * 86400, 7: 30 * 86400}.get(unit, 0) * number
        limits.sort(key=lambda l: seconds(l) or _finite_number(l.get("nextResetTime")) or 0)
        quota = {}
        for l in limits:
            span = seconds(l)
            slot = "five_hour" if 0 < span <= 6 * 3600 else "seven_day"
            if slot in quota:
                continue
            reset = _finite_number(l.get("nextResetTime"))
            quota[slot] = _window(_finite_number(l.get("percentage")), reset / 1000.0 if reset else None, now, span or None)
        level = str(data.get("level") or "")
        row = {"tier": ("Coding " + level.capitalize()) if level else "Coding Plan", "sessions": 0, "quota": quota,
               "captured_at": now, "plan_key": hashlib.sha256(key.encode("utf-8")).hexdigest()[:8]}
        break
    try:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        tmp = cache_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"at": now, "row": row}, fh)
        os.chmod(tmp, 0o600); os.replace(tmp, cache_path)
    except OSError:
        pass
    return row

def _session_counts():
    names = ("claude", "codex", "grok", "agy")
    result = dict((name, 0) for name in names)
    try:
        proc = subprocess.Popen(["/bin/ps", "-axo", "pid=,ppid=,command="], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        raw = proc.stdout.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            proc.terminate(); proc.wait(timeout=1)
            return result, False
        proc.stdout.close()
        if proc.wait(timeout=2) != 0:
            return result, False
    except (OSError, subprocess.SubprocessError):
        return result, False
    procs, matched = {}, {}
    for line in raw.decode("utf-8", "replace").splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        procs[pid] = (ppid, parts[2])
        try:
            argv = shlex.split(parts[2])
        except ValueError:
            continue
        if not argv:
            continue
        base = os.path.basename(argv[0]).lower()
        kind = None
        if base == "claude": kind = "claude"
        elif base in ("codex", "codex.js") or ("node" in base and len(argv) > 1 and os.path.basename(argv[1]).lower() in ("codex", "codex.js")): kind = "codex"
        elif base == "grok": kind = "grok"
        elif base == "agy": kind = "agy"
        if kind and ppid != 1 and not any(term in parts[2].lower() for term in ("mcp-server", "grep", "codex-darwin", "/vendor/", "/plugins/cache/", "cua_node", "agy-routed", "agy-batch", "agy-review", "agy-video")):
            matched[pid] = kind
    roots = set()
    for pid, kind in matched.items():
        parent, hops = procs[pid][0], 0
        nested = False
        while parent > 1 and hops < 30:
            if parent in matched:
                nested = True; break
            parent = procs.get(parent, (1, ""))[0]
            hops += 1
        if not nested:
            roots.add((pid, kind))
    for _pid, kind in roots:
        result[kind] += 1
    return result, True

def collect_platform_quotas(home, now=None):
    now = time.time() if now is None else now
    sessions, sessions_ok = _session_counts()
    claude = _read_claude_usage(home) or {}
    claude_capture = _finite_number(claude.get("_captured_at"))
    def claude_window(key, seconds):
        obj = claude.get(key)
        if not isinstance(obj, dict): return None
        return _window(obj.get("used_percentage"), _finite_number(obj.get("resets_at")), claude_capture, seconds)
    extra_name, extra5, extra7 = "", None, None
    for key, obj in claude.items():
        if key in ("five_hour", "seven_day", "_captured_at") or not isinstance(obj, dict): continue
        base_name = key.replace("five_hour_", "").replace("seven_day_", "")
        win = _window(obj.get("used_percentage"), _finite_number(obj.get("resets_at")), claude_capture,
                      5 * 3600 if key.startswith("five_hour") else 7 * 86400)
        if win is None: continue
        if extra_name and extra_name != base_name: continue
        extra_name = base_name
        if key.startswith("five_hour"): extra5 = win
        else: extra7 = win
    claude_quota = {"five_hour": claude_window("five_hour", 5 * 3600), "seven_day": claude_window("seven_day", 7 * 86400),
                    "secondary_name": extra_name, "secondary_five_hour": extra5, "secondary_seven_day": extra7}
    codex_quota, codex_tier, codex_capture, codex_account = _codex_quotas(home, now, include_identity=True)
    grok_window, grok_tier = _grok_quota(home)
    agy_quota, agy_capture = _agy_quotas(home)
    def row(tier="", quota=None, captured=None, note=None):
        result = {"tier": tier or "", "sessions": 0, "quota": quota or {}}
        if captured is not None: result["captured_at"] = captured
        if note: result["note"] = note
        return result
    has_agy_quota = bool(agy_quota and any(agy_quota.get(k) is not None for k in
                         ("five_hour", "seven_day", "secondary_five_hour", "secondary_seven_day")))
    rows = {"claude": row(quota=claude_quota, captured=claude_capture),
            "codex": row(tier=codex_tier, quota=codex_quota, captured=codex_capture),
            "grok": row(tier=grok_tier, quota={"seven_day": grok_window}, captured=grok_window.get("captured_at") if grok_window else None),
            "agy": row(tier="已登录" if has_agy_quota else "", quota=agy_quota or {}, captured=agy_capture)}
    glm = _glm_quota(home, now)
    if glm:
        rows["glm"] = glm
    rows["codex"].update(codex_account)
    rows["claude"].update(_claude_quota_identity(home, claude))
    for key in rows:
        rows[key]["sessions"] = sessions.get(key, 0)
        if not sessions_ok: rows[key]["note"] = "session_count_unavailable"
    return rows

# Passive Linux process state. Never read another process's environment or connect
# to a Codex server. Only already-open rollout files are eligible; no home walk.
_PROCESS_MAX_FDS = 4096
_PROCESS_MAX_LOGS = 64
_PROCESS_MAX_BYTES = 4 * 1024 * 1024
_PROCESS_TAIL_BYTES = 128 * 1024
_PROCESS_HEAD_BYTES = 32 * 1024

def _process_read(path, limit):
    with open(path, "rb") as fh:
        data = fh.read(limit + 1)
    if len(data) > limit:
        raise ValueError("metadata limit")
    return data

def _process_stat(path):
    data = _process_read(path, 8192)
    # comm can contain spaces and parentheses. All fields after its last ')' are numeric/status.
    fields = data[data.rfind(b")") + 2:].split()
    if len(fields) < 22:
        raise ValueError("short process stat")
    return {"status": fields[0], "ppid": int(fields[1]), "ticks": int(fields[19]), "rss": max(0, int(fields[21]))}

def _process_executable_name(executable):
    # An in-use binary remains valid after a package upgrade unlinks its inode.
    return os.path.basename(executable[:-10] if executable.endswith(" (deleted)") else executable)

def _process_role(path, executable):
    base = _process_executable_name(executable)
    if base not in ("codex", "codex.js", "node", "nodejs", "bun"):
        return None
    # Read one argument at a time, stopping at the command position; never decode
    # prompts, config values, tool arguments or the remaining command line.
    with open(path, "rb") as fh:
        used = [0]
        def arg():
            value = bytearray()
            while used[0] < 8192 and len(value) <= 4096:
                byte = fh.read(1); used[0] += 1
                if not byte or byte == b"\0": return bytes(value)
                value.extend(byte)
            raise ValueError("argument limit")
        arg()  # argv[0] already identified through /proc/PID/exe.
        if base in ("node", "nodejs", "bun"):
            script = arg()
            if script.rsplit(b"/", 1)[-1] not in (b"codex", b"codex.js"):
                return None
        values = (b"-c", b"--config", b"-m", b"--model", b"-p", b"--profile", b"-s", b"--sandbox",
                  b"-a", b"--ask-for-approval", b"-C", b"--cd", b"--add-dir", b"--enable", b"--disable",
                  b"-i", b"--image", b"--local-provider")
        for _ in range(64):
            token = arg()
            if token in (b"--version", b"-V", b"--help", b"-h"): return None
            if token in values: arg(); continue
            if token.startswith(b"-"): continue
            if token in (b"mcp-server", b"mcp", b"login", b"logout", b"completion", b"completions", b"features", b"debug"):
                return None
            if token == b"exec-server": return "worker"
            return "appServer" if token == b"app-server" else "cli"
    return None

def _process_fields(data):
    """Select metadata slices; skip unrelated JSON without deserializing its values."""
    wanted = (b'"type"', b'"timestamp"', b'"payload"', b'"cwd"')
    i, size, result = 0, len(data), {}
    def ws(pos):
        while pos < size and data[pos] in b" \t\r\n": pos += 1
        return pos
    def string_end(pos):
        if pos >= size or data[pos] != 34: raise ValueError("string")
        pos += 1
        while pos < size:
            if data[pos] == 92: pos += 2; continue
            if data[pos] == 34: return pos + 1
            if data[pos] < 32: raise ValueError("control character")
            pos += 1
        raise ValueError("unterminated string")
    def value_end(pos):
        if pos >= size: raise ValueError("value")
        if data[pos] == 34: return string_end(pos)
        if data[pos] in (123, 91):
            stack = [125 if data[pos] == 123 else 93]; pos += 1
            while pos < size and stack:
                byte = data[pos]
                if byte == 34: pos = string_end(pos); continue
                if byte in (123, 91):
                    if len(stack) >= 128: raise ValueError("nesting limit")
                    stack.append(125 if byte == 123 else 93)
                elif byte in (125, 93):
                    if byte != stack.pop(): raise ValueError("mismatched JSON")
                pos += 1
            if stack: raise ValueError("unterminated value")
            return pos
        end = pos
        while end < size and data[end] not in b",]} \t\r\n": end += 1
        if end == pos: raise ValueError("empty value")
        return end
    try:
        i = ws(i)
        if i >= size or data[i] != 123: return None
        i = ws(i + 1)
        if i < size and data[i] == 125: return {} if ws(i + 1) == size else None
        while i < size:
            start = i; end = string_end(i); key = data[start:end]
            i = ws(end)
            if i >= size or data[i] != 58: return None
            start = ws(i + 1); end = value_end(start)
            if key in wanted:
                if key in result: return None  # ambiguous duplicate metadata
                result[key] = data[start:end]
            i = ws(end)
            if i < size and data[i] == 125:
                return result if ws(i + 1) == size else None
            if i >= size or data[i] != 44: return None
            i = ws(i + 1)
    except (ValueError, IndexError):
        pass
    return None

def _process_text(raw):
    if not raw or len(raw) > 8192 or raw[:1] != b'"': return None
    try:
        value = json.loads(raw.decode("utf-8"))
        return value if isinstance(value, str) and not any(ord(c) < 32 or ord(c) == 127 for c in value) else None
    except (UnicodeError, ValueError):
        return None

def _process_time(value):
    match = _ISO_RE.fullmatch(value) if isinstance(value, str) and len(value) <= 64 else None
    if not match: return None
    try:
        datetime.datetime(*(int(match.group(i)) for i in range(1, 7)))
        zone = (match.group(7) or "Z")[1:].replace(":", "")
        if zone and (int(zone[:2]) > 23 or int(zone[2:] or "0") > 59): return None
        return _iso_epoch(value)
    except (ValueError, OverflowError):
        return None

def _process_session_id(path):
    name = os.path.basename(path)
    if not name.startswith("rollout-") or not name.endswith(".jsonl"): return None
    try: return str(uuid.UUID(name[-42:-6]))
    except (ValueError, AttributeError): return None

def _process_session(fd_path, session_id, birth, now, budget):
    session = {"id": session_id, "cwd": None, "state": "unknown", "basis": "noLifecycleEvidence", "observed_at": None}
    if budget[0] <= 0:
        session["basis"] = "partialObservation"
        return session, True
    try:
        # Opening the process's existing FD binds to its actual inode, not a path
        # that could be replaced between readlink and open. A new offset is used.
        fd = os.open(fd_path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0))
        with os.fdopen(fd, "rb") as fh:
            before = os.fstat(fh.fileno())
            if not stat.S_ISREG(before.st_mode): raise ValueError("not a regular rollout")
            count = min(_PROCESS_HEAD_BYTES, budget[0])
            head = fh.read(count); budget[0] -= len(head)
            if b"\n" in head:
                fields = _process_fields(head.split(b"\n", 1)[0]) or {}
                if _process_text(fields.get(b'"type"')) == "session_meta":
                    session["cwd"] = _process_text((_process_fields(fields.get(b'"payload"', b"")) or {}).get(b'"cwd"'))
            count = min(_PROCESS_TAIL_BYTES, budget[0])
            start = max(0, before.st_size - count)
            fh.seek(start); tail = fh.read(count); budget[0] -= len(tail)
            after = os.fstat(fh.fileno())
            # A concurrent write/truncation or an incomplete final JSON record can
            # hide a later turn end/start. Do not return a stale active/idle state.
            limited = after.st_size != before.st_size or after.st_mtime_ns != before.st_mtime_ns or bool(tail and not tail.endswith(b"\n"))
            if count <= 0: limited = True
            lines = tail.split(b"\n")[:-1]
            if start and lines: lines = lines[1:]
            event = None
            for line in lines:
                fields = _process_fields(line)
                if fields is None:
                    event = None; limited = True; continue
                if _process_text(fields.get(b'"type"')) != "event_msg": continue
                payload = _process_fields(fields.get(b'"payload"', b"")) or {}
                kind = _process_text(payload.get(b'"type"'))
                if kind not in ("task_started", "task_complete", "task_completed", "turn_aborted"): continue
                at = _process_time(_process_text(fields.get(b'"timestamp"')))
                if at is not None and birth <= at <= now + 5:
                    event = ("active" if kind == "task_started" else "idle", at)
            if event is not None and not limited:
                session.update(state=event[0], basis="turnStarted" if event[0] == "active" else "turnEnded", observed_at=event[1])
            elif limited or start:
                session["basis"] = "partialObservation"
                limited = True
            return session, limited
    except (OSError, ValueError, OverflowError):
        session["basis"] = "partialObservation"
        return session, True

def _process_aggregate(row):
    if row["state"] in ("stopped", "unresponsive"): return
    states = [s["state"] for s in row["sessions"]]
    row["state"] = "active" if "active" in states else "idle" if states and not row["observation_limited"] and all(s == "idle" for s in states) else "unknown"
    row["basis"] = "turnStarted" if row["state"] == "active" else "turnEnded" if row["state"] == "idle" else "partialObservation" if row["observation_limited"] else "noLifecycleEvidence"

def collect_codex_processes(home, proc_root="/proc", now=None):
    """Return (optional inventory, partial); nil is not a successful empty list."""
    now = time.time() if now is None else now
    try:
        boot = str(uuid.UUID(_process_read(os.path.join(proc_root, "sys/kernel/random/boot_id"), 128).decode().strip()))
        boot_time = None
        for line in _process_read(os.path.join(proc_root, "stat"), 1024 * 1024).splitlines():
            if line.startswith(b"btime "): boot_time = int(line.split()[1]); break
        hz, page = os.sysconf("SC_CLK_TCK"), os.sysconf("SC_PAGE_SIZE")
        if boot_time is None or hz <= 0 or page <= 0: return None, True
        roots = [os.path.realpath(os.path.join(home, ".codex", "sessions")) + os.sep]
        if os.environ.get("CODEX_HOME"):
            roots.append(os.path.realpath(os.path.join(os.path.expanduser(os.environ["CODEX_HOME"]), "sessions")) + os.sep)
        candidates, parents, limited = {}, {}, False
        deadline = time.monotonic() + 2
        with os.scandir(proc_root) as entries:
            for index, entry in enumerate(entries):
                if index >= 32768 or time.monotonic() > deadline:
                    limited = True; break
                if not entry.name.isdigit(): continue
                pid = int(entry.name)
                is_candidate = False
                try:
                    if entry.stat().st_uid != os.getuid(): continue
                    meta = _process_stat(os.path.join(entry.path, "stat")); parents[pid] = meta["ppid"]
                    exe = os.readlink(os.path.join(entry.path, "exe"))
                    is_candidate = _process_executable_name(exe) in ("codex", "codex.js", "node", "nodejs", "bun")
                    role = _process_role(os.path.join(entry.path, "cmdline"), exe)
                    if role is not None:
                        candidates[pid] = (meta, role, exe)
                        if len(candidates) >= 256: limited = True; break
                except (OSError, ValueError) as exc:
                    # Non-Codex processes routinely exit during /proc enumeration.
                    if is_candidate or isinstance(exc, ValueError) or isinstance(exc, OSError) and exc.errno in (1, 13): limited = True
                    continue
        wrappers = set(pid for pid, (_m, _r, exe) in candidates.items() if _process_executable_name(exe) in ("node", "nodejs", "bun") and
                       any(meta["ppid"] == pid for meta, _role, _exe in candidates.values()))
        result, budget, fd_budget = [], [_PROCESS_MAX_BYTES], 32768
        metadata_deadline = time.monotonic() + 4
        for pid, (meta, role, exe) in sorted(candidates.items()):
            if pid in wrappers: continue
            path, parent, seen = os.path.join(proc_root, str(pid)), meta["ppid"], set()
            while parent > 1 and parent not in seen and len(seen) < 32:
                if parent in candidates and parent not in wrappers:
                    if role != "appServer": role = "worker"
                    break
                seen.add(parent); parent = parents.get(parent, 0)
            birth = boot_time + meta["ticks"] / float(hz)
            if meta["ticks"] <= 0 or birth > now: limited = True; continue
            row = {"device_id": "", "source": "linuxProc", "instance_id": "%d:%s:%d" % (pid, boot, meta["ticks"]),
                   "pid": pid, "parent_pid": meta["ppid"], "role": role, "cwd": None, "started_at": birth,
                   "sampled_at": now, "mem_mb": meta["rss"] * page / 1048576.0,
                   "state": "unknown", "basis": "noLifecycleEvidence", "sessions": [], "observation_limited": False}
            try:
                row["cwd"] = os.readlink(os.path.join(path, "cwd"))
            except OSError: row["observation_limited"] = True
            session_fds = {}
            try:
                with os.scandir(os.path.join(path, "fd")) as entries:
                    for index, entry in enumerate(entries):
                        if index >= _PROCESS_MAX_FDS or fd_budget <= 0 or time.monotonic() > metadata_deadline:
                            row["observation_limited"] = True; break
                        fd_budget -= 1
                        try: target = os.readlink(entry.path)
                        except OSError: row["observation_limited"] = True; continue
                        sid = _process_session_id(target)
                        if sid and any(target.startswith(root) for root in roots):
                            session_fds[sid] = entry.path
                            if len(session_fds) >= _PROCESS_MAX_LOGS:
                                row["observation_limited"] = True; break
            except OSError: row["observation_limited"] = True
            for sid, fd_path in sorted(session_fds.items()):
                session, partial = _process_session(fd_path, sid, birth, now, budget)
                row["sessions"].append(session)
                row["observation_limited"] = row["observation_limited"] or partial
            try:
                after = _process_stat(os.path.join(path, "stat"))
                if after["ticks"] != meta["ticks"] or os.readlink(os.path.join(path, "exe")) != exe:
                    limited = True; continue
            except (OSError, ValueError): limited = True; continue
            if after["status"] in (b"T", b"t"):
                row.update(state="stopped", basis="kernelStopped")
            elif after["status"] == b"Z":
                row.update(state="unresponsive", basis="kernelZombie")
            _process_aggregate(row)
            result.append(row)
        counts = collections.Counter(s["id"] for row in result for s in row["sessions"])
        for row in result:
            # Shared/inherited FDs do not prove which process owns the turn.
            if any(counts[s["id"]] > 1 for s in row["sessions"]):
                row["sessions"] = [s for s in row["sessions"] if counts[s["id"]] == 1]
                row["observation_limited"] = True
                _process_aggregate(row)
        return result, limited or any(row["observation_limited"] for row in result)
    except Exception:
        # The optional snapshot must not take unrelated usage/quota collection down.
        return None, True

# Current sign-in is independent of historical session/quota account provenance.
# Only status commands are invoked. Credential values are structurally skipped,
# never JSON-decoded, logged, returned or sent to a provider.
def _presence_fields(data, wanted):
    if not isinstance(data, bytes): return None
    size = len(data)
    def ws(i):
        while i < size and data[i] in b" \t\r\n": i += 1
        return i
    def string_end(i):
        if i >= size or data[i] != 34: raise ValueError("JSON string")
        i += 1
        while i < size:
            byte = data[i]
            if byte == 34: return i + 1
            if byte < 32: raise ValueError("JSON control")
            if byte == 92:
                i += 1
                if i >= size: raise ValueError("JSON escape")
                if data[i] == 117:
                    if i + 4 >= size or any(c not in b"0123456789abcdefABCDEF" for c in data[i+1:i+5]): raise ValueError("JSON unicode")
                    i += 4
                elif data[i] not in b'"\\/bfnrt': raise ValueError("JSON escape")
            i += 1
        raise ValueError("JSON unterminated string")
    def value_end(i, depth=0):
        if depth > 64 or i >= size: raise ValueError("JSON limit")
        if data[i] == 34: return string_end(i)
        if data[i] in (123, 91):
            is_object = data[i] == 123
            close = 125 if is_object else 93
            i = ws(i + 1)
            if i < size and data[i] == close: return i + 1
            while i < size:
                if is_object:
                    i = ws(string_end(i))
                    if i >= size or data[i] != 58: raise ValueError("JSON colon")
                    i = ws(i + 1)
                i = ws(value_end(i, depth + 1))
                if i < size and data[i] == close: return i + 1
                if i >= size or data[i] != 44: raise ValueError("JSON comma")
                i = ws(i + 1)
            raise ValueError("JSON unterminated value")
        for literal in (b"true", b"false", b"null"):
            if data.startswith(literal, i): return i + len(literal)
        match = re.match(rb"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?", data[i:])
        if match: return i + match.end()
        raise ValueError("JSON value")
    try:
        i, result = ws(0), {}
        if i >= size or data[i] != 123: return None
        i = ws(i + 1)
        if i < size and data[i] == 125: return {} if ws(i + 1) == size else None
        while i < size:
            start = i; end = string_end(i); key = data[start:end]
            i = ws(end)
            if i >= size or data[i] != 58: return None
            start = ws(i + 1); end = value_end(start)
            if key in wanted:
                if key in result: return None
                result[key] = data[start:end]
            i = ws(end)
            if i < size and data[i] == 125: return result if ws(i + 1) == size else None
            if i >= size or data[i] != 44: return None
            i = ws(i + 1)
    except (ValueError, IndexError):
        pass
    return None

def _presence_text(raw):
    # Called only for explicitly selected non-secret metadata/status primitives.
    if not raw or raw[:1] != b'"' or len(raw) > 4096: return None
    try:
        value = json.loads(raw.decode("utf-8"))
        return value if isinstance(value, str) else None
    except (ValueError, UnicodeError): return None

def _presence_file(path):
    try: return _process_read(path, 512 * 1024)
    except (OSError, ValueError): return None

def _presence_identity(provider, subject, workspace=None):
    if not isinstance(subject, str) or len(subject.encode("utf-8")) > 512: return None
    if workspace is not None and (not isinstance(workspace, str) or len(workspace.encode("utf-8")) > 512): return None
    row = _identity(provider, subject, workspace)
    if not row: return None
    identity = {"provider": row["account_provider"], "accountID": row["account_id"]}
    if "account_workspace" in row: identity["workspaceID"] = row["account_workspace"]
    return identity

def _presence_codex_metadata(path):
    fields = _presence_fields(_presence_file(path), (b'"auth_mode"', b'"tokens"'))
    if fields is None: return None
    mode = _presence_text(fields.get(b'"auth_mode"'))
    if b'"auth_mode"' in fields and fields[b'"auth_mode"'] != b"null" and mode is None: return None
    tokens = _presence_fields(fields.get(b'"tokens"'), (b'"account_id"',)) or {}
    account = _presence_identity("openai", _presence_text(tokens.get(b'"account_id"')))
    if mode not in (None, "chatgpt", "chatgptAuthTokens"): account = None
    return mode, account

def _presence_claude_metadata(path):
    fields = _presence_fields(_presence_file(path), (b'"oauthAccount"',)) or {}
    oauth = _presence_fields(fields.get(b'"oauthAccount"'), (b'"accountUuid"', b'"organizationUuid"')) or {}
    return _presence_identity("anthropic", _presence_text(oauth.get(b'"accountUuid"')), _presence_text(oauth.get(b'"organizationUuid"')))

def _presence_credential_store(path, capture=False):
    data = _presence_file(path)
    def finish(mode): return (mode, data) if capture else mode
    if data is None:
        try: os.lstat(path)
        except FileNotFoundError: return finish("file")
        except OSError: return finish(None)
        return finish(None)
    found = None
    key = b"cli_auth_credentials_store"
    for raw in data.splitlines():
        line = raw.lstrip(b" \t")
        if not line or line.startswith(b"#"): continue
        # Support ordinary bare/quoted keys, but never treat an unsupported
        # escaped/dotted/inline/multiline storage declaration as the file default.
        if b'"""' in line or b"'''" in line or b"\\u" in line or b"\\U" in line: return finish(None)
        match = re.fullmatch(rb"(?:cli_auth_credentials_store|\"cli_auth_credentials_store\"|'cli_auth_credentials_store')\s*=\s*(['\"])(file|keyring|auto|ephemeral)\1\s*(?:#.*)?", line)
        if not match:
            if key in line: return finish(None)
            continue
        mode = match.group(2).decode("ascii")
        if found is not None and found != mode: return finish(None)
        found = mode
    return finish(found or "file")

def _presence_profile_path(path, home):
    if path == "~": path = home
    elif path.startswith("~/"): path = os.path.join(home, path[2:])
    else: path = os.path.expanduser(path)
    return os.path.abspath(path if os.path.isabs(path) else os.path.join(home, path))

def _presence_executable(name, home, environment):
    path = shutil.which(name, path=environment.get("PATH", os.defpath))
    if path: return os.path.realpath(path)
    for folder in (os.path.join(home, ".local", "bin"), os.path.join(home, ".npm-global", "bin"), "/usr/local/bin", "/usr/bin", "/opt/homebrew/bin"):
        path = os.path.join(folder, name)
        if os.path.isfile(path) and os.access(path, os.X_OK): return os.path.realpath(path)
    return None

def _presence_status(executable, arguments, home, environment, include_stderr):
    if executable is None: return None
    process, reader = None, None
    try:
        process = subprocess.Popen([executable] + arguments, cwd=home, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT if include_stderr else subprocess.DEVNULL)
        reader = selectors.DefaultSelector(); reader.register(process.stdout, selectors.EVENT_READ)
        deadline, output = time.monotonic() + 5, bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0: return None
            if not reader.select(min(remaining, 0.2)): continue
            data = os.read(process.stdout.fileno(), 4096)
            if not data: break
            if len(output) + len(data) > 64 * 1024: return None
            output.extend(data)
        code = process.wait(timeout=max(0.001, deadline - time.monotonic()))
        return code, bytes(output)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    finally:
        if reader is not None: reader.close()
        if process is not None:
            if process.stdout is not None: process.stdout.close()
            if process.poll() is None:
                # Only this newly-created status child, never an existing runtime.
                try:
                    process.terminate(); process.wait(timeout=0.2)
                except subprocess.TimeoutExpired:
                    try: process.kill(); process.wait(timeout=0.2)
                    except (OSError, subprocess.SubprocessError): pass
                except OSError: pass

def _presence_row(tool, now, state="unknown", account=None, basis="statusUnavailable", method=None):
    return {"device_id": "", "tool": tool, "state": state, "account": account, "sampled_at": now, "basis": basis, "method": method}

def _presence_codex(status, account, profile_matches, now):
    if status is None: return _presence_row("Codex", now)
    code, output = status
    lines = [line.lstrip(b" \t\r") for line in output.split(b"\n")]
    chatgpt = any(line.startswith(b"Logged in using ChatGPT") for line in lines)
    api_key = any(line.startswith((b"Logged in using an API key", b"Logged in using API key")) for line in lines)
    logged_out = any(line.startswith(b"Not logged in") for line in lines)
    if sum((chatgpt, api_key, logged_out)) != 1: return _presence_row("Codex", now)
    if logged_out and code != 0: return _presence_row("Codex", now, "loggedOut", basis="cliStatus")
    if code != 0 or logged_out: return _presence_row("Codex", now)
    identity = account if chatgpt and profile_matches else None
    basis = "profileMismatch" if chatgpt and not profile_matches else "cliStatus" if identity else "identityUnavailable"
    return _presence_row("Codex", now, "loggedIn", identity, basis, "chatgpt" if chatgpt else "apiKey")

def _presence_claude(status, account, profile_matches, now):
    if status is None: return _presence_row("Claude", now)
    code, output = status
    fields = _presence_fields(output, (b'"loggedIn"', b'"authMethod"', b'"apiProvider"'))
    if fields is None or fields.get(b'"loggedIn"') not in (b"true", b"false"): return _presence_row("Claude", now)
    logged_in = fields[b'"loggedIn"'] == b"true"
    auth = _presence_text(fields.get(b'"authMethod"')); provider = _presence_text(fields.get(b'"apiProvider"'))
    if not logged_in and auth == "none" and code != 0: return _presence_row("Claude", now, "loggedOut", basis="cliStatus")
    if not logged_in or code != 0: return _presence_row("Claude", now)
    oauth = auth in ("claude.ai", "oauth", "claudeAi") and provider == "firstParty"
    if oauth: method = "claudeAi"
    elif provider == "firstParty" and auth in ("api_key", "apiKey", "api-key"): method = "apiKey"
    elif provider is not None and provider != "firstParty": method = "external"
    elif provider == "firstParty" and auth not in (None, "", "none"):
        # Keep the explicit sign-in fact, without guessing the new method or
        # adopting OAuth metadata that might belong to another credential path.
        return _presence_row("Claude", now, "loggedIn", basis="identityUnavailable")
    else: return _presence_row("Claude", now)
    identity = account if oauth and profile_matches else None
    basis = "profileMismatch" if oauth and not profile_matches else "cliStatus" if identity else "identityUnavailable"
    return _presence_row("Claude", now, "loggedIn", identity, basis, method)

def collect_account_presence(home, now=None, environment=None):
    now = time.time() if now is None else now
    environment = dict(os.environ if environment is None else environment)
    environment.update(HOME=home, CI="1", NO_COLOR="1")
    result = []
    try:
        codex_home = _presence_profile_path(environment.get("CODEX_HOME") or os.path.join(home, ".codex"), home)
        environment["CODEX_HOME"] = codex_home
        auth_path, config_path = os.path.join(codex_home, "auth.json"), os.path.join(codex_home, "config.toml")
        before, store_before = _presence_codex_metadata(auth_path), _presence_credential_store(config_path, capture=True)
        status = _presence_status(_presence_executable("codex", home, environment), ["login", "status"], home, environment, True)
        after, store_after = _presence_codex_metadata(auth_path), _presence_credential_store(config_path, capture=True)
        # Environment credential overrides cannot be attached to old file identity.
        matches = store_before == store_after and store_before[0] == "file" and before == after and not any(k in environment for k in ("OPENAI_API_KEY", "CODEX_API_KEY"))
        result.append(_presence_codex(status, after[1] if after else None, matches, now))
    except Exception:
        result.append(_presence_row("Codex", now))
    try:
        custom = environment.get("CLAUDE_CONFIG_DIR")
        matches = not custom or os.path.realpath(_presence_profile_path(custom, home)) == os.path.realpath(os.path.join(home, ".claude"))
        matches = matches and not any(k in environment for k in ("CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"))
        path = os.path.join(home, ".claude.json")
        before = _presence_claude_metadata(path)
        status = _presence_status(_presence_executable("claude", home, environment), ["auth", "status", "--json"], home, environment, False)
        after = _presence_claude_metadata(path)
        result.append(_presence_claude(status, after, matches and before == after, now))
    except Exception:
        result.append(_presence_row("Claude", now))
    return result

def run_summary():
    # 只打一行 __summary__ + 哨兵；任何异常转失败哨兵，绝不写文件
    try:
        start_ms, home = _today_start_ms(), os.path.expanduser("~")
        recs, _ = collect_records(home, start_ms - 1)
        today = dict((k, v) for k, v in (
            ("opencode", _collect_opencode(start_ms)),
            ("claude", _today_totals([r for r in recs if r["k"] == "claude"], start_ms / 1000.0)),
            ("codex", _today_totals([r for r in recs if r["k"] == "codex"], start_ms / 1000.0)),
        ) if v)
        processes, processes_limited = collect_codex_processes(home)
        sys.stdout.write(json.dumps({"__summary__": {"today": today, "claude_usage": _read_claude_usage(home),
                                                       "platforms": collect_platform_quotas(home),
                                                       "codex_processes": processes,
                                                       "codex_processes_limited": processes_limited,
                                                       "account_presence": collect_account_presence(home)}}, separators=(",", ":")) + "\n")
        sys.stdout.write(json.dumps({"__ok__": True, "count": len(today), "max_u": 0}, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        return 0
    except Exception as exc:
        emit_fail("%s: %s" % (type(exc).__name__, exc))
        return 1

def run_quotas():
    # 额度刷新不扫描 Claude/Codex 全量逐条用量文件。
    try:
        platforms = collect_platform_quotas(os.path.expanduser("~"))
        sys.stdout.write(json.dumps({"__summary__": {"platforms": platforms}}, separators=(",", ":")) + "\n")
        sys.stdout.write(json.dumps({"__ok__": True, "count": len(platforms), "max_u": 0}, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        return 0
    except Exception as exc:
        emit_fail("%s: quota collection failed" % type(exc).__name__)
        return 1

# ---- 逐条记录模式：Claude / Codex 的每次请求（给 Mac 端算按天、按模型、按金额）----
# 口径与 Mac 端 UsageHistory 一致：
#   Claude：同一 requestId 取 token 最多的那条；1h 缓存写入单列；speed=fast 记 fast 档；跳过 synthetic / API 错误行
#   Codex：有 token_usage_record 就只认它（response_id 去重）；否则用 token_count 的 last_token_usage（累计没前进不算）
#          sessions/ 与 archived_sessions/ 同名文件只算一次；旧版 fork 开头 1 秒内的重放串只当基线

def _claude_roots(home):
    roots = []
    env = os.environ.get("CLAUDE_CONFIG_DIR", "")
    for item in [x.strip() for x in env.split(",") if x.strip()]:
        roots.append(os.path.join(os.path.expanduser(item), "projects"))
    roots += [os.path.join(home, ".config", "claude", "projects"), os.path.join(home, ".claude", "projects")]
    seen, out = set(), []
    for r in roots:
        if r not in seen and os.path.isdir(r):
            seen.add(r); out.append(r)
    return out

def _codex_files(home):
    base = os.environ.get("CODEX_HOME") or os.path.join(home, ".codex")
    picked = {}
    for sub in ("sessions", "archived_sessions"):     # sessions 优先
        root = os.path.join(base, sub)
        for dp, _d, names in os.walk(root, onerror=lambda _e: None):
            for nm in names:
                if nm.endswith(".jsonl") and nm not in picked:
                    picked[nm] = os.path.join(dp, nm)
    return list(picked.values())

def _claude_files(home):
    out = []
    for root in _claude_roots(home):
        for dp, _d, names in os.walk(root, onerror=lambda _e: None):
            for nm in names:
                if nm.endswith(".jsonl"):
                    out.append(os.path.join(dp, nm))
    return out

def _mtime_ms(p):
    try:
        return int(os.path.getmtime(p) * 1000)
    except OSError:
        return -1

def _read_lines(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return []

def _add_seconds(rec, seconds, output=None):
    """与本机 CLI 估算同一门槛，wire 字段始终可选。"""
    if seconds is not None and math.isfinite(seconds) and 1 <= seconds <= 600 and (rec["out"] if output is None else output) >= 50:
        rec["seconds"] = seconds


def _claude_entry(o):
    # 子代理进度行：完整的 assistant 记录包在 data.message 里
    entry = o
    if (o.get("type") != "assistant" or not isinstance(o.get("message"), dict)) and isinstance(o.get("data"), dict):
        inner = o["data"].get("message")
        if isinstance(inner, dict) and isinstance(inner.get("message"), dict):
            entry = inner
    return entry

def _claude_record(o, session):
    entry = _claude_entry(o)
    if entry.get("type", "assistant") != "assistant" or entry.get("isApiErrorMessage"):
        return None
    m = entry.get("message")
    u = m.get("usage") if isinstance(m, dict) else None
    if not isinstance(u, dict):
        return None
    model = m.get("model") or "?"
    if "synthetic" in model:
        return None
    ts = _iso_epoch(entry.get("timestamp"))
    rid = entry.get("requestId") or (m.get("id") if isinstance(m.get("id"), str) else "") or entry.get("uuid") or ""
    if ts is None or not rid:
        return None
    i, r, w = (to_num(u.get(k)) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    cc = u.get("cache_creation") if isinstance(u.get("cache_creation"), dict) else {}
    rec = {"k": "claude", "id": rid, "t": ts, "m": model, "in": i + r + w, "cr": r, "cw": w,
           "c1": min(w, to_num(cc.get("ephemeral_1h_input_tokens"))), "out": to_num(u.get("output_tokens")), "th": 0, "s": session}
    if str(u.get("speed") or "").lower() == "fast":
        rec["tier"] = "fast"
    return rec

def _codex_usage(d):
    if not isinstance(d, dict) or "input_tokens" not in d or "output_tokens" not in d:
        return None
    inp = to_num(d.get("input_tokens"))
    cr = min(to_num(d.get("cached_input_tokens")), inp)
    cw = min(to_num(d.get("cache_write_input_tokens")), inp - cr)
    return {"in": inp, "cr": cr, "cw": cw, "out": to_num(d.get("output_tokens")), "th": to_num(d.get("reasoning_output_tokens"))}

def _codex_file_records(path, include_metadata=False):
    name = os.path.basename(path)
    model, tier, prev, has_tur, forked = "?", None, None, False, False
    burst_last, burst_first, burst_done = None, None, False
    previous_event, latest_response = None, None
    recs = collections.OrderedDict()
    account = _codex_session_identity(path)
    turns, turn_models, turn_starts, turn_errors = {}, {}, {}, set()
    for n, line in enumerate(_read_lines(path)):
        if not any(k in line for k in ('"token_count"', '"turn_context"', '"session_meta"', '"token_usage_record"', '"thread_settings_applied"', '"user_message"', '"function_call_output"', '"task_started"', '"task_complete"', '"turn_aborted"', '"error"')):
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        p = o.get("payload") if isinstance(o.get("payload"), dict) else {}
        t = o.get("type")
        ts = _iso_epoch(o.get("timestamp"))
        turn_id = p.get("turn_id")
        if include_metadata and isinstance(turn_id, str) and turn_id:
            event_type = p.get("type")
            if t == "turn_context" and isinstance(p.get("model"), str) and p["model"]:
                # First explicitly turn-associated context, never the last session model.
                turn_models.setdefault(turn_id, p["model"])
            if t == "event_msg" and event_type == "task_started" and ts is not None:
                turn_starts.setdefault(turn_id, ts)
            if p.get("error") is not None or event_type in ("error", "turn_aborted"):
                turn_errors.add(turn_id)
            if t == "event_msg" and event_type == "task_complete":
                ttft = _finite_number(p.get("time_to_first_token_ms"))
                if ts is not None and ttft is not None and ttft >= 0:
                    metric = dict(account, k="codex_turn", turn_id=turn_id, t=ts, ttft_ms=ttft,
                                  failed=p.get("error") is not None or turn_id in turn_errors or p.get("status") in ("failed", "error", "cancelled", "interrupted"))
                    started_at = _finite_number(p.get("started_at")) or (_iso_epoch(p.get("started_at")) if isinstance(p.get("started_at"), str) else None) or turn_starts.get(turn_id)
                    if started_at is not None and 0 < started_at <= ts: metric["started_at"] = started_at
                    if turn_id in turn_models: metric["m"] = turn_models[turn_id]
                    turns[turn_id] = metric
        start = previous_event
        if p.get("type") in ("user_message", "function_call_output", "token_count") and ts is not None:
            previous_event = ts
        if t == "session_meta":
            forked = bool(p.get("forked_from_id"))
            if p.get("model"):
                model = p["model"]
        elif t == "turn_context":
            if p.get("model"):
                model = p["model"]
        elif t == "token_usage_record":
            u = _codex_usage(p.get("usage"))
            ts = _iso_epoch(o.get("timestamp"))
            if u is None or ts is None:
                continue
            if not has_tur:
                has_tur = True
                recs = collections.OrderedDict((k, v) for k, v in recs.items() if k.startswith("resp"))
            if u["in"] + u["out"] <= 0:
                continue
            rid = p.get("response_id") or ("resp-%s:%d" % (name, n))
            rec = dict(u, k="codex", id=rid, t=ts, m=model, s=name)
            if tier:
                rec["tier"] = tier
            old_record = recs.get(rid)
            if old_record is not None and dict((k, v) for k, v in old_record.items() if k != "seconds") == rec and "seconds" in old_record:
                rec["seconds"] = old_record["seconds"]
            recs[rid] = rec
            latest_response = rid
        elif t == "event_msg":
            et = p.get("type")
            if et == "thread_settings_applied":
                st = (p.get("thread_settings") or {}).get("service_tier")
                if isinstance(st, str):
                    tier = st.lower()
                continue
            if et != "token_count" or not isinstance(p.get("info"), dict):
                continue
            info = p["info"]
            total = _codex_usage(info.get("total_token_usage"))
            last = _codex_usage(info.get("last_token_usage"))
            old = prev
            if total is not None:
                prev = total
                if total == old:
                    continue
            if last is None:
                if total is None:
                    continue
                last = dict((k, total[k] - (old or {}).get(k, 0)) for k in total)
                if any(v < 0 for v in last.values()):
                    continue
            if has_tur:
                rec = recs.get(latest_response)
                latest_response = None
                exact = _codex_usage(info.get("last_token_usage"))
                if rec is not None and exact is not None and ts is not None and start is not None and rec["t"] <= ts and rec["out"] == exact["out"] and rec["in"] == exact["in"]:
                    _add_seconds(rec, ts - start)
                continue
            if last["in"] + last["out"] <= 0:
                continue
            ts = _iso_epoch(o.get("timestamp"))
            if ts is None:
                continue
            rid = "%s:%d" % (name, n)
            if forked and not burst_done:
                if burst_last is not None:
                    if ts - burst_last <= 1.0:
                        if burst_first is not None:
                            recs.pop(burst_first, None); burst_first = None
                        burst_last = ts
                        continue
                    burst_done = True
                else:
                    burst_last, burst_first = ts, rid
            rec = dict(last, k="codex", id=rid, t=ts, m=p.get("model") or model, s=name)
            if start is not None and _codex_usage(info.get("last_token_usage")) is not None:
                _add_seconds(rec, ts - start)
            if tier:
                rec["tier"] = tier
            recs[rid] = rec
    for record in recs.values(): record.update(account)
    result = list(recs.values())
    if include_metadata:
        if account: result.append(dict(account, k="account_session", cli="codex", s=name))
        result.extend(turns.values())
    return result

_DSH_DAYS = 35

def _dsh_files(home, cutoff_ms):
    root = os.path.join(home, ".dsh", "sessions")
    out = []
    for dp, _d, names in os.walk(root, onerror=lambda _e: None):
        for nm in names:
            if nm.startswith("session.") and (nm.endswith(".jsonl.zstd") or nm.endswith(".jsonl")):
                p = os.path.join(dp, nm)
                if _mtime_ms(p) > cutoff_ms:
                    out.append(p)
    return out

def _dsh_lines(path, zstd):
    if not path.endswith(".zstd"):
        return _read_lines(path)
    if not zstd:
        return []
    try:
        proc = subprocess.run([zstd, "-dcq", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return []
    return proc.stdout.decode("utf-8", "replace").splitlines() if proc.returncode == 0 else []

def _model_free(model):
    m = model.lower()
    return m.endswith("-free") or ":free" in m or "-free/" in m or "zen-free" in m

def _dsh_records(home, since_ms, now=None):
    """DeepSeek's DSH: one record per assistant message from its zstd session logs. Its cost-meter ledger can stop
    recording days (seen on WSL since 2026-08-30), so the logs are the source. Free relay models cost 0."""
    now = time.time() if now is None else now
    cutoff = max(since_ms, int((now - _DSH_DAYS * 86400) * 1000))
    zstd = shutil.which("zstd")
    out, max_m = [], 0
    for path in _dsh_files(home, -1):
        mt = _mtime_ms(path)
        max_m = max(max_m, mt)
        if mt <= cutoff:
            continue
        session = os.path.basename(os.path.dirname(path))
        for line in _dsh_lines(path, zstd):
            if '"assistant/message"' not in line or '"usage"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            data = o.get("data") if isinstance(o, dict) else None
            usage = data.get("usage") if isinstance(data, dict) else None
            msg = data.get("message") if isinstance(data, dict) else None
            if not isinstance(usage, dict) or not isinstance(msg, dict):
                continue
            src = msg.get("source") if isinstance(msg.get("source"), dict) else {}
            t = _finite_number(o.get("time"))
            rid = msg.get("id")
            if t is None or not isinstance(rid, str) or not rid:
                continue
            fresh, cr = to_num(usage.get("inputTokens")), to_num(usage.get("cacheReadTokens"))
            cw, th = to_num(usage.get("cacheWriteTokens")), to_num(usage.get("reasoningTokens"))
            outp = to_num(usage.get("outputTokens"))
            if fresh + cr + cw + outp <= 0:
                continue
            model = to_str(src.get("model")) or "?"
            # "deepseek/deepseek-flash" → priced as deepseek-flash; relay prefixes stay for free models
            priced = model.split("/", 1)[1] if model.lower().startswith("deepseek/") else model
            rec = {"k": "dsh", "id": rid, "t": t / 1000.0, "m": priced, "p": to_str(src.get("provider")),
                   "in": fresh + cr + cw, "cr": cr, "cw": cw, "out": outp + th, "th": th, "s": session}
            if _model_free(model):
                rec["c"], rec["cur"] = 0, "USD"
            out.append(rec)
    return out, max_m

def _grok_records(home, since_ms):
    """Grok CLI: per-turn usage from each session's usage.json, with xAI's own cost (1 USD = 1e10 ticks)."""
    root = os.path.join(home, ".grok", "sessions")
    out, max_m = [], 0
    for dp, _d, names in os.walk(root, onerror=lambda _e: None):
        if "usage.json" not in names:
            continue
        path = os.path.join(dp, "usage.json")
        mt = _mtime_ms(path)
        max_m = max(max_m, mt)
        if mt <= since_ms:
            continue
        obj = _read_json_bounded([path], 4 * 1024 * 1024)
        if not isinstance(obj, dict):
            continue
        session = to_str(obj.get("sessionId")) or os.path.basename(dp)
        for turn in obj.get("turns") or []:
            if not isinstance(turn, dict):
                continue
            t = _iso_epoch(turn.get("endedAt"))
            n = turn.get("turnNumber")
            if t is None or not isinstance(n, int):
                continue
            inp, outp = to_num(turn.get("inputTokens")), to_num(turn.get("outputTokens"))
            if inp + outp <= 0:
                continue
            rec = {"k": "grok", "id": "%s:%d" % (session, n), "t": t, "m": to_str(turn.get("primaryModelId")) or "?",
                   "in": inp, "cr": min(inp, to_num(turn.get("cachedReadTokens"))),
                   "cw": to_num(turn.get("cacheCreationTokens")), "out": outp,
                   "th": min(outp, to_num(turn.get("reasoningTokens"))), "s": session}
            ticks = _finite_number(turn.get("costUsdTicks"))
            if ticks is not None and ticks >= 0:
                rec["c"], rec["cur"] = ticks / 1e10, "USD"
            out.append(rec)
    return out, max_m

_CPA_DBS = ("/opt/cpa-usage-keeper/data/app.db", "~/cpa-usage-keeper/data/app.db", "~/.cpa-usage-keeper/data/app.db")
_CPA_PROVIDERS = {"codex": "openai", "openai": "openai", "claude": "anthropic", "anthropic": "anthropic"}

def _cpa_db(home):
    override = os.environ.get("VIBEDECK_CPA_DB")
    for raw in ([override] if override else []) + list(_CPA_DBS):
        path = raw.replace("~", home, 1) if raw.startswith("~") else raw
        if os.path.isfile(path) and os.access(path, os.R_OK):
            return path
    return None

def _cpa_records(home, since_ms, now=None):
    """CLIProxyAPI usage as kept by cpa-usage-keeper (SQLite, opened read-only): one record per request, with the
    upstream account it used. Token fields follow Codex: input includes cached, output includes reasoning."""
    path = _cpa_db(home)
    if path is None:
        return [], 0
    import sqlite3
    now = time.time() if now is None else now
    max_m = max(_mtime_ms(path), _mtime_ms(path + "-wal"))
    if max_m <= since_ms:
        return [], max_m
    # Keeper can file a request a little after it happened; an hour of overlap is deduplicated by id.
    cutoff = max(since_ms / 1000.0 - 3600, now - _DSH_DAYS * 86400)
    out = []
    db = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=5)
    try:
        rows = db.execute("SELECT e.event_key, e.request_id, e.timestamp, e.model, e.provider, e.input_tokens, e.cached_tokens, "
                          "e.cache_creation_tokens, e.output_tokens, e.reasoning_tokens, e.service_tier, i.account_id "
                          "FROM usage_events e LEFT JOIN usage_identities i ON i.identity = e.auth_index")
        for key, rid, stamp, model, provider, inp, cached, created, outp, reasoning, tier, account in rows:
            t = _iso_epoch(stamp)
            if t is None or t < cutoff:
                continue
            inp, outp = to_num(inp), to_num(outp)
            if inp + outp <= 0:
                continue
            cr = min(to_num(cached), inp)
            rec = {"k": "cpa", "id": to_str(key) or to_str(rid), "t": t, "m": to_str(model) or "?", "in": inp, "cr": cr,
                   "cw": min(to_num(created), inp - cr), "out": outp, "th": min(to_num(reasoning), outp)}
            if not rec["id"]:
                continue
            if tier in ("priority", "flex"):
                rec["tier"] = tier
            account_provider = _CPA_PROVIDERS.get((to_str(provider) or "").lower())
            if account_provider and to_str(account):
                rec["account_provider"], rec["account_id"] = account_provider, to_str(account)
            out.append(rec)
    finally:
        db.close()
    return out, max_m

def collect_records(home, since_ms, include_metadata=False, include_identity_backfill=False, tools_since_ms=None):
    """返回 (记录列表, 最大 mtime 毫秒)。只看 mtime > since_ms 的文件。"""
    out, max_m = [], 0
    claude = {}
    # First assistant entry after each prompt / tool result: an approximate first-response time for
    # Claude Code, whose logs carry no first-token field. Kept separate from Codex's native metric.
    claude_first = {}
    recent_cutoff = time.time() - 86400
    for p in _claude_files(home):
        mt = _mtime_ms(p)
        max_m = max(max_m, mt)
        if mt <= since_ms:
            continue
        session = os.path.splitext(os.path.basename(p))[0]
        ancestors = {}
        for line in _read_lines(p):
            if '"usage"' not in line and '"parentUuid"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            entry = _claude_entry(o)
            ts = _iso_epoch(entry.get("timestamp"))
            parent_start = ancestors.get(entry.get("parentUuid"))
            start = ts if entry.get("type") == "user" else parent_start
            if isinstance(entry.get("uuid"), str) and start is not None:
                ancestors[entry["uuid"]] = start
                if len(ancestors) > 512:
                    ancestors = dict(sorted(ancestors.items(), key=lambda pair: pair[1], reverse=True)[:256])
                    ancestors[entry["uuid"]] = start
            rec = _claude_record(o, session)
            if rec is None:
                continue
            if include_metadata and parent_start is not None and ts is not None and ts >= recent_cutoff:
                key = "%s:%.3f" % (session, parent_start)
                ms = (ts - parent_start) * 1000.0
                if key not in claude_first and 0 <= ms <= 600000:
                    metric = dict(k="claude_turn", turn_id=key, t=ts, ttft_ms=ms, started_at=parent_start)
                    if rec.get("m"): metric["m"] = rec["m"]
                    claude_first[key] = metric
            old = claude.get(rec["id"])
            # 最大用量 + 最后 assistant 时间，末块 output=0 也不丢失计时。
            seconds = rec["t"] - parent_start if parent_start is not None else None
            if old is not None:
                if old["t"] > rec["t"] or (old["t"] == rec["t"] and seconds is None):
                    seconds = old.get("seconds")
                latest = max(old["t"], rec["t"])
                if old["in"] + old["out"] > rec["in"] + rec["out"]:
                    rec = dict(old)
                rec["t"] = latest
            rec.pop("seconds", None)
            _add_seconds(rec, seconds)
            claude[rec["id"]] = rec
    out.extend(claude.values())
    out.extend(claude_first.values())
    for p in _codex_files(home):
        mt = _mtime_ms(p)
        max_m = max(max_m, mt)
        if mt <= since_ms:
            if include_identity_backfill:
                account = _codex_session_identity(p)
                if account: out.append(dict(account, k="account_session", cli="codex", s=os.path.basename(p)))
            continue
        out.extend(_codex_file_records(p, include_metadata=include_metadata))
    for collect in (_dsh_records, _grok_records, _cpa_records):
        try:
            recs, newest = collect(home, since_ms if tools_since_ms is None else tools_since_ms)
        except Exception:
            continue
        out.extend(recs)
        max_m = max(max_m, newest)
    return out, max_m

def run_records(since, gz, include_identity_backfill=False, tools_since=None):
    try:
        recs, max_m = collect_records(os.path.expanduser("~"), since, include_metadata=True, include_identity_backfill=include_identity_backfill,
                                      tools_since_ms=tools_since)
        lines = [json.dumps(r, separators=(",", ":")) for r in recs]
        lines.append(json.dumps({"__ok__": True, "count": sum(r.get("k") in ("claude", "codex", "dsh", "grok", "cpa") for r in recs), "max_mtime": max_m}, separators=(",", ":")))
        text = "\n".join(lines) + "\n"
        if gz:
            co = zlib.compressobj(6, zlib.DEFLATED, -15)     # 原始 DEFLATE，Mac 端用 Foundation 直接解
            blob = co.compress(text.encode("utf-8")) + co.flush()
            sys.stdout.write(base64.b64encode(blob).decode("ascii") + "\n")
        else:
            sys.stdout.write(text)
        sys.stdout.flush()
        return 0
    except Exception as exc:
        emit_fail("%s: %s" % (type(exc).__name__, exc))
        return 1

def _today_totals(recs, start_s):
    acc = dict.fromkeys(("ctx", "cache_read", "cache_write", "out", "think", "requests"), 0)
    for r in recs:
        if r["t"] < start_s:
            continue
        acc["ctx"] += r["in"]; acc["cache_read"] += r["cr"]; acc["cache_write"] += r["cw"]
        acc["out"] += r["out"]; acc["think"] += r.get("th", 0); acc["requests"] += 1
    return acc if acc["requests"] > 0 else None

def _process_selftest(tmp):
    import shutil, io, contextlib
    tmp = os.path.realpath(tmp)
    home, proc = os.path.join(tmp, "process-home"), os.path.join(tmp, "proc")
    root = os.path.join(home, ".codex", "sessions", "2026", "09", "18")
    os.makedirs(root)
    os.makedirs(os.path.join(proc, "sys", "kernel", "random"))
    boot_id = "00000000-0000-0000-0000-000000000001"
    with open(os.path.join(proc, "sys", "kernel", "random", "boot_id"), "w") as fh: fh.write(boot_id)
    now = _process_time("2026-09-18T12:00:00Z")
    with open(os.path.join(proc, "stat"), "w") as fh: fh.write("btime %d\n" % (now - 100))
    def process(pid, parent=1, command=b"codex\0", exe="/opt/vendor/codex", status="S", ticks=100):
        path = os.path.join(proc, str(pid)); os.makedirs(os.path.join(path, "fd"))
        fields = ["0"] * 22
        fields[0], fields[1], fields[19], fields[21] = status, str(parent), str(ticks), "1024"
        with open(os.path.join(path, "stat"), "w") as fh: fh.write("%d (codex ) comm) %s\n" % (pid, " ".join(fields)))
        with open(os.path.join(path, "cmdline"), "wb") as fh: fh.write(command)
        os.symlink(exe, os.path.join(path, "exe")); os.symlink("/fixture/project", os.path.join(path, "cwd"))
        return path
    def rollout(suffix, event=None, extra=b"", timestamp="2026-09-18T11:59:50Z"):
        sid = "00000000-0000-0000-0000-%012d" % suffix
        path = os.path.join(root, "rollout-2026-09-18T11-59-00-%s.jsonl" % sid)
        with open(path, "wb") as fh:
            fh.write(b'{"type":"session_meta","payload":{"cwd":"/fixture/project","instructions":"PRIVATE_INSTRUCTIONS"}}\n')
            if event:
                fh.write(json.dumps({"type": "event_msg", "timestamp": timestamp,
                                     "payload": {"type": event, "last_agent_message": "PRIVATE_RESPONSE"}}).encode() + b"\n")
            fh.write(extra)
        return path, sid
    def attach(path, target, name="3"): os.symlink(target, os.path.join(path, "fd", name))
    server = process(100, command=b"codex\0-c\0key=value\0app-server\0")
    cli = process(101, parent=100, command=b"codex\0exec\0PRIVATE_PROMPT\0")
    native = process(103, parent=102)
    process(102, command=b"node\0/usr/lib/codex.js\0", exe="/usr/bin/node")
    process(104, command=b"codex\0--version\0")
    process(105, command=b"python3\0-c\0codex\0", exe="/usr/bin/python3")
    process(106, command=b"node\0/fixture/not-codex.js\0", exe="/usr/bin/node")
    process(108, parent=42, command=b"codex\0-c\0key=value\0exec-server\0--remote\0fixture-host\0")
    assert _process_executable_name("/opt/vendor/codex (deleted)") == "codex"
    open_log, open_id = rollout(1, "task_started")
    idle_log, _ = rollout(2, "task_complete")
    attach(server, open_log); attach(cli, idle_log)
    old_env = os.environ.pop("CODEX_HOME", None)
    try:
        # Decoding is allowed only for selected primitive metadata strings.
        saved_loads = json.loads
        def metadata_only(value, *args, **kwargs):
            assert "PRIVATE_" not in value
            return saved_loads(value, *args, **kwargs)
        json.loads = metadata_only
        try: rows, partial = collect_codex_processes(home, proc, now)
        finally: json.loads = saved_loads
        by_pid = dict((r["pid"], r) for r in rows)
        assert set(by_pid) == {100, 101, 103, 108} and not partial
        assert by_pid[100]["role"] == "appServer" and by_pid[100]["state"] == "active"
        assert by_pid[101]["role"] == "worker" and by_pid[101]["state"] == "idle"
        assert by_pid[103]["role"] == "cli" and by_pid[103]["state"] == "unknown"
        assert by_pid[108]["role"] == "worker" and by_pid[108]["parent_pid"] == 42
        assert by_pid[100]["instance_id"] == "100:%s:100" % boot_id
        assert by_pid[100]["sessions"][0]["id"] == open_id
        assert "PRIVATE_" not in json.dumps(rows)
        # A different process holding the same rollout does not duplicate a session.
        attach(native, open_log)
        rows, partial = collect_codex_processes(home, proc, now)
        assert partial
        assert all(not r["sessions"] and r["state"] == "unknown" for r in rows if r["pid"] in (100, 103))
        os.unlink(os.path.join(native, "fd", "3"))
        # Each explicit end event is idle; pre-birth, malformed or future times are unknown.
        for kind in ("task_complete", "task_completed", "turn_aborted"):
            path, sid = rollout(3, kind)
            with open(path, "rb") as fh:
                session, partial = _process_session(path, sid, now - 90, now, [1024 * 1024])
            assert session["state"] == "idle" and not partial
        path, sid = rollout(3, "task_started", timestamp="2026-09-18T11:58:00Z")
        assert _process_session(path, sid, now - 90, now, [1024 * 1024])[0]["state"] == "unknown"
        for stamp in ("2026-09-18T12:00:06Z", "2026-09-18T12:00:00Z garbage", "2026-02-30T12:00:00Z"):
            path, sid = rollout(3, "task_started", timestamp=stamp)
            assert _process_session(path, sid, now - 90, now, [1024 * 1024])[0]["state"] == "unknown"
        path, sid = rollout(3, "task_started", extra=b'{"type":"event_msg"')
        session, partial = _process_session(path, sid, now - 90, now, [1024 * 1024])
        assert session["state"] == "unknown" and partial
        assert _process_session(path, sid, now - 90, now, [0])[1]
        # A truncated tail without a lifecycle marker cannot imply idle.
        path, sid = rollout(3, "task_started", extra=b'{"type":"response_item","payload":{"message":"' + b"x" * (_PROCESS_TAIL_BYTES + 100) + b'"}}\n')
        session, partial = _process_session(path, sid, now - 90, now, [1024 * 1024])
        assert session["state"] == "unknown" and partial
        assert _process_fields(b'{"type":"event_msg","type":"session_meta"}') is None
        assert _process_fields(b'{"type":"event_msg"} junk') is None
        assert _process_fields(b'{"payload":{"type":"task_started"],"type":"event_msg"}') is None
        # PID incarnation changes during collection must remove the old sample.
        saved_stat = globals()["_process_stat"]; calls = collections.Counter()
        def reused(path):
            value = saved_stat(path)
            if path == os.path.join(server, "stat"):
                calls[path] += 1
                if calls[path] > 1: value["ticks"] += 1
            return value
        globals()["_process_stat"] = reused
        try:
            rows, partial = collect_codex_processes(home, proc, now)
            assert partial and 100 not in [r["pid"] for r in rows]
        finally: globals()["_process_stat"] = saved_stat
        # Unreadable /proc is unavailable, not a successful empty inventory.
        assert collect_codex_processes(home, os.path.join(tmp, "absent"), now) == (None, True)
        shutil.rmtree(os.path.join(cli, "fd"))
        rows, partial = collect_codex_processes(home, proc, now)
        assert partial and next(r for r in rows if r["pid"] == 101)["state"] == "unknown"
        process(107, status="T")
        rows, partial = collect_codex_processes(home, proc, now)
        stopped = next(r for r in rows if r["pid"] == 107)
        assert stopped["state"] == "stopped" and stopped["basis"] == "kernelStopped"
        # Successful empty and unsupported inventories stay distinct. Optional
        # process data cannot add usage requests or change summary's sentinel.
        empty_proc = os.path.join(tmp, "empty-proc")
        shutil.copytree(os.path.join(proc, "sys"), os.path.join(empty_proc, "sys"))
        shutil.copy(os.path.join(proc, "stat"), os.path.join(empty_proc, "stat"))
        assert collect_codex_processes(home, empty_proc, now) == ([], False)
        names = ("_today_start_ms", "collect_records", "_collect_opencode", "_read_claude_usage", "collect_platform_quotas", "collect_codex_processes", "collect_account_presence")
        saved = dict((name, globals()[name]) for name in names)
        globals().update(_today_start_ms=lambda: int(now * 1000),
                         collect_records=lambda *_a: ([{"k": "codex", "t": now, "in": 7, "cr": 0, "cw": 0, "out": 1}], 0),
                         _collect_opencode=lambda *_a: None, _read_claude_usage=lambda *_a: None,
                         collect_platform_quotas=lambda *_a: {}, collect_codex_processes=lambda *_a: (None, True), collect_account_presence=lambda *_a: [])
        try:
            output = io.StringIO()
            with contextlib.redirect_stdout(output): assert run_summary() == 0
            wire, sentinel = [json.loads(line) for line in output.getvalue().splitlines()]
            assert wire["__summary__"]["codex_processes"] is None and wire["__summary__"]["codex_processes_limited"]
            assert wire["__summary__"]["today"]["codex"]["requests"] == 1 and sentinel["count"] == 1 and sentinel["__ok__"]
        finally: globals().update(saved)
    finally:
        if old_env is not None: os.environ["CODEX_HOME"] = old_env

def _presence_selftest(tmp):
    home = os.path.join(os.path.realpath(tmp), "presence-home")
    os.makedirs(os.path.join(home, ".codex"))
    auth_path, config_path = os.path.join(home, ".codex", "auth.json"), os.path.join(home, ".codex", "config.toml")
    claude_path = os.path.join(home, ".claude.json")
    def auth(subject="fixture-current"):
        with open(auth_path, "w") as fh:
            json.dump({"auth_mode": "chatgpt", "tokens": {"account_id": subject, "access_token": {"SECRET_TOKEN": 42}, "id_token": ["SECRET_JWT"]}, "OPENAI_API_KEY": "SECRET_API_KEY"}, fh)
    auth()
    with open(claude_path, "w") as fh:
        json.dump({"oauthAccount": {"accountUuid": "fixture-claude", "organizationUuid": "fixture-org"}, "email": "SECRET_EMAIL", "accessToken": "SECRET_TOKEN"}, fh)
    signed_in = (0, b"Logged in using ChatGPT\n")
    claude_in = (0, b'{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"SECRET_EMAIL"}')
    assert _presence_codex(None, {"accountID": "stale"}, True, 100)["state"] == "unknown"
    assert _presence_codex((1, b"Not logged in\n"), None, True, 100)["state"] == "loggedOut"
    assert _presence_codex((0, b"Not logged in\n"), None, True, 100)["state"] == "unknown"
    assert _presence_codex((1, b"Logged in using ChatGPT\n"), None, True, 100)["state"] == "unknown"
    assert _presence_codex((0, b"Logged in using ChatGPT\nNot logged in\n"), None, True, 100)["state"] == "unknown"
    key = _presence_codex((0, b"Logged in using an API key - SECRET_SUFFIX\n"), {"accountID": "stale"}, True, 100)
    assert key["state"] == "loggedIn" and key["method"] == "apiKey" and key["account"] is None
    assert _presence_claude((1, b'{"loggedIn":false,"authMethod":"none"}'), None, True, 100)["state"] == "loggedOut"
    assert _presence_claude((0, b'{"loggedIn":false,"authMethod":"none"}'), None, True, 100)["state"] == "unknown"
    assert _presence_claude((0, b'{"loggedIn":true,"loggedIn":false}'), None, True, 100)["state"] == "unknown"
    new_method = _presence_claude((0, b'{"loggedIn":true,"authMethod":"future-method","apiProvider":"firstParty"}'), {"accountID": "stale"}, True, 100)
    assert new_method["state"] == "loggedIn" and new_method["account"] is None and new_method["method"] is None and new_method["basis"] == "identityUnavailable"
    for raw in (b'{"loggedIn":true,"apiProvider":"firstParty"}', b'{"loggedIn":true,"authMethod":"none","apiProvider":"firstParty"}',
                b'{"loggedIn":true,"authMethod":"","apiProvider":"firstParty"}'):
        assert _presence_claude((0, raw), None, True, 100)["state"] == "unknown"
    assert _presence_claude((1, b'{"loggedIn":true,"authMethod":"future-method","apiProvider":"firstParty"}'), None, True, 100)["state"] == "unknown"
    external = _presence_claude((0, b'{"loggedIn":true,"authMethod":"api_key","apiProvider":"thirdParty"}'), {"accountID": "stale"}, True, 100)
    assert external["method"] == "external" and external["account"] is None
    assert _presence_fields(b'{"tokens":{"account_id":"a"],"auth_mode":"chatgpt"}', (b'"tokens"',)) is None
    assert _presence_fields(b'{"tokens":{"account_id":"a"},"tokens":{}}', (b'"tokens"',)) is None
    saved_status, saved_executable, saved_loads = _presence_status, _presence_executable, json.loads
    def safe_loads(value, *args, **kwargs):
        assert "SECRET_" not in value
        return saved_loads(value, *args, **kwargs)
    def executable(name, _home, _env): return "/fixture/" + name
    def status(path, arguments, _home, _env, include_stderr):
        if path.endswith("codex"):
            assert arguments == ["login", "status"] and include_stderr
            return signed_in
        assert arguments == ["auth", "status", "--json"] and not include_stderr
        return claude_in
    globals()["_presence_status"], globals()["_presence_executable"], json.loads = status, executable, safe_loads
    try:
        rows = collect_account_presence(home, now=100, environment={"PATH": os.defpath})
        by_tool = dict((r["tool"], r) for r in rows)
        assert by_tool["Codex"]["account"]["accountID"] == "fixture-current"
        assert by_tool["Claude"]["account"]["accountID"] == "fixture-claude"
        assert all(r["state"] == "loggedIn" and r["basis"] == "cliStatus" for r in rows)
        assert "SECRET_" not in json.dumps(rows)
        assert collect_account_presence(home, now=100, environment={"CODEX_HOME": ".codex"})[0]["account"]["accountID"] == "fixture-current"
        # Explicit alternate storage/profile or credential overrides block stale IDs.
        for store in ("keyring", "auto", "ephemeral"):
            for key in ("cli_auth_credentials_store", '"cli_auth_credentials_store"', "'cli_auth_credentials_store'"):
                with open(config_path, "w") as fh: fh.write('%s = "%s"\n' % (key, store))
                assert _presence_credential_store(config_path) == store
                codex = collect_account_presence(home, now=100, environment={})[0]
                assert codex["state"] == "loggedIn" and codex["account"] is None and codex["basis"] == "profileMismatch"
        for config in ('cli_auth_credentials_store = "file"\n', '"cli_auth_credentials_store" = "file"\n', "'cli_auth_credentials_store' = 'file'\n"):
            with open(config_path, "w") as fh: fh.write(config)
            assert collect_account_presence(home, now=100, environment={})[0]["account"]["accountID"] == "fixture-current"
        for config in ('cli_auth_credentials_store = "file"\n[profiles.other]\n"cli_auth_credentials_store" = "keyring"\n',
                       'profiles.other.cli_auth_credentials_store = "keyring"\n',
                       '"cli_auth_cred\\u0065ntials_store" = "keyring"\n',
                       'description = """\ncli_auth_credentials_store = "keyring"\n"""\n'):
            with open(config_path, "w") as fh: fh.write(config)
            assert _presence_credential_store(config_path) is None
            assert collect_account_presence(home, now=100, environment={})[0]["account"] is None
        os.unlink(config_path)
        for variable in ("OPENAI_API_KEY", "CODEX_API_KEY"):
            codex = collect_account_presence(home, now=100, environment={variable: "SECRET_KEY"})[0]
            assert codex["account"] is None and codex["basis"] == "profileMismatch"
        for env in ({"CLAUDE_CONFIG_DIR": "/fixture/other-profile"}, {"CLAUDE_CODE_OAUTH_TOKEN": "SECRET_TOKEN"}):
            claude = collect_account_presence(home, now=100, environment=env)[1]
            assert claude["state"] == "loggedIn" and claude["account"] is None and claude["basis"] == "profileMismatch"
        os.unlink(auth_path)
        codex = collect_account_presence(home, now=100, environment={})[0]
        assert codex["state"] == "loggedIn" and codex["account"] is None
        auth()
        def changed(path, *args):
            if path.endswith("codex"): auth("fixture-switched")
            return status(path, *args)
        globals()["_presence_status"] = changed
        codex = collect_account_presence(home, now=100, environment={})[0]
        assert codex["state"] == "loggedIn" and codex["account"] is None and codex["basis"] == "profileMismatch"
        auth()
        def changed_config(path, *args):
            if path.endswith("codex"):
                with open(config_path, "w") as fh: fh.write('"cli_auth_credentials_store" = "keyring"\n')
            return status(path, *args)
        globals()["_presence_status"] = changed_config
        codex = collect_account_presence(home, now=100, environment={})[0]
        assert codex["state"] == "loggedIn" and codex["account"] is None and codex["basis"] == "profileMismatch"
        os.unlink(config_path)
        globals()["_presence_status"] = lambda *_a: None
        assert all(r["state"] == "unknown" and r["account"] is None for r in collect_account_presence(home, now=100, environment={}))
        # The normal bounded child path is exercised with an owned, inert fixture CLI.
        fixture = os.path.join(home, "fixture-status")
        with open(fixture, "w") as fh:
            fh.write('#!/usr/bin/python3\nimport sys\nassert sys.argv[1:] == ["login", "status"]\nprint("Logged in using ChatGPT")\n')
        os.chmod(fixture, 0o700)
        captured = saved_status(fixture, ["login", "status"], home, {"PATH": os.defpath}, True)
        assert captured == signed_in
    finally:
        globals()["_presence_status"], globals()["_presence_executable"], json.loads = saved_status, saved_executable, saved_loads

def _cpa_selftest(tmp):
    import sqlite3
    path = os.path.join(tmp, "cpa.db")
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE usage_events (event_key text, request_id text, timestamp text, model text, provider text, auth_index text, "
               "input_tokens int, cached_tokens int, cache_creation_tokens int, output_tokens int, reasoning_tokens int, service_tier text)")
    db.execute("CREATE TABLE usage_identities (identity text, account_id text)")
    db.execute("INSERT INTO usage_identities VALUES ('auth-1', 'ACCOUNT-CPA')")
    db.execute("INSERT INTO usage_events VALUES ('ev-1', 'r1', '2026-10-27T12:56:20.5+08:00', 'gpt-6.1-sol', 'codex', 'auth-1', 1000, 900, 0, 50, 20, 'auto')")
    db.execute("INSERT INTO usage_events VALUES ('ev-2', 'r2', '2026-10-27T12:57:00+08:00', 'gpt-6.1-sol', 'codex', 'other', 0, 0, 0, 0, 0, 'auto')")
    db.commit(); db.close()
    os.environ["VIBEDECK_CPA_DB"] = path
    try:
        recs, newest = _cpa_records(tmp, 0, now=_iso_epoch("2026-10-27T13:00:00+08:00"))
    finally:
        del os.environ["VIBEDECK_CPA_DB"]
    assert newest > 0 and len(recs) == 1, recs
    r = recs[0]
    assert r["k"] == "cpa" and r["id"] == "ev-1" and r["in"] == 1000 and r["cr"] == 900 and r["out"] == 50 and r["th"] == 20
    assert r["account_provider"] == "openai" and r["account_id"] == "ACCOUNT-CPA" and "tier" not in r

def selftest():
    global _session_counts, collect_platform_quotas
    import tempfile, shutil, contextlib, io
    tmp = tempfile.mkdtemp(prefix="vg-collector-")
    try:
        _presence_selftest(tmp)
        _process_selftest(tmp)
        _cpa_selftest(tmp)
        def w(rel, rows):
            p = os.path.join(tmp, rel)
            if not os.path.isdir(os.path.dirname(p)):
                os.makedirs(os.path.dirname(p))
            with open(p, "w") as fh:
                fh.write("\n".join(json.dumps(r) for r in rows) + "\n")
        a = lambda rid, out, ts="2026-09-18T10:00:00Z", **extra: dict({"type": "assistant", "timestamp": ts, "requestId": rid, "message": {"model": "claude-opus-5", "id": "m" + rid,
            "usage": {"input_tokens": 10, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 5, "output_tokens": out,
                      "cache_creation": {"ephemeral_1h_input_tokens": 5}}}}, **extra)
        w(".claude/projects/p/s1.jsonl", [a("r1", 3), a("r1", 9), a("r2", 4), a("r3", 1, isApiErrorMessage=True)])
        w(".claude/projects/p/s2.jsonl", [a("r1", 9)])
        usage = lambda i, c, o: {"input_tokens": i, "cached_input_tokens": c, "cache_write_input_tokens": 0, "output_tokens": o, "reasoning_output_tokens": 0}
        tur = lambda rid, u, ts: {"type": "token_usage_record", "timestamp": ts, "payload": {"response_id": rid, "usage": u}}
        tc = lambda total, last, ts: {"type": "event_msg", "timestamp": ts, "payload": {"type": "token_count", "info": {"total_token_usage": total, "last_token_usage": last}}}
        rows = [{"type": "session_meta", "payload": {"id": "x"}}, {"type": "turn_context", "payload": {"model": "gpt-6-sol"}},
                {"type": "event_msg", "timestamp": "2026-09-18T10:00:00Z", "payload": {"type": "thread_settings_applied", "thread_settings": {"service_tier": "priority"}}},
                tur("resp_1", usage(100, 40, 10), "2026-09-18T10:00:01Z"), tc(usage(100, 40, 10), usage(100, 40, 10), "2026-09-18T10:00:01Z"),
                tur("resp_2", usage(50, 10, 5), "2026-09-18T10:00:09Z"), tc(usage(150, 50, 15), usage(50, 10, 5), "2026-09-18T10:00:09Z"),
                tc(usage(150, 50, 15), usage(50, 10, 5), "2026-09-18T10:00:10Z")]
        w(".codex/sessions/2026/09/18/rollout-a.jsonl", rows)
        w(".codex/archived_sessions/rollout-a.jsonl", rows)
        old = [{"type": "turn_context", "payload": {"model": "gpt-5.6-sol"}},
               tc(usage(10, 0, 1), usage(10, 0, 1), "2026-09-18T11:00:00Z"), tc(usage(10, 0, 1), usage(10, 0, 1), "2026-09-18T11:00:05Z"),
               tc(usage(30, 5, 3), usage(20, 5, 2), "2026-09-18T11:00:09Z")]
        w(".codex/sessions/2026/09/18/rollout-b.jsonl", old)
        # The host may set CODEX_HOME to a real, large log tree; tests stay fixture-only.
        saved_codex_home = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = os.path.join(tmp, ".codex")
        recs, max_m = collect_records(tmp, 0)
        cl = [r for r in recs if r["k"] == "claude"]
        cx = [r for r in recs if r["k"] == "codex"]
        assert len(cl) == 2, cl
        assert [r["out"] for r in cl if r["id"] == "r1"] == [9], "同一 requestId 取 token 最多的那条"
        assert cl[0]["c1"] == 5 and cl[0]["in"] == 35
        assert len(cx) == 4, cx
        assert sorted(r["id"] for r in cx if r["id"].startswith("resp")) == ["resp_1", "resp_2"], "有 token_usage_record 就只认它，归档副本不重复"
        assert all(r.get("tier") == "priority" for r in cx if r["id"].startswith("resp"))
        assert sorted(r["in"] for r in cx if not r["id"].startswith("resp")) == [10, 20], "旧格式：累计没前进的重复行不算"
        assert max_m > 0
        recs2, _ = collect_records(tmp, max_m)
        assert recs2 == [], "游标之后没有新文件就不重发"
        if saved_codex_home is None: os.environ.pop("CODEX_HOME", None)
        else: os.environ["CODEX_HOME"] = saved_codex_home
        today = _today_totals(recs, 0)
        assert today["requests"] == 6
        # CLI timing fixtures: same request retains max usage and final timestamp;
        # parent/tool_result chains, millisecond precision, and missing parents.
        timing_home = os.path.join(tmp, "timing")
        user = lambda uid, parent, ts: {"type": "user", "uuid": uid, "parentUuid": parent, "timestamp": ts}
        w("timing/.claude/projects/p/t.jsonl", [
            user("u", None, "2026-09-18T10:00:00.250Z"),
            a("timed", 100, "2026-09-18T10:00:02.250Z", uuid="a", parentUuid="u"),
            a("timed", 200, "2026-09-18T10:00:04.750Z", uuid="b", parentUuid="a"),
            a("timed", 0, "2026-09-18T10:00:05.250Z", uuid="c", parentUuid="b"),
            user("tool", "c", "2026-09-18T10:00:10.250Z"),
            a("tool-timed", 100, "2026-09-18T10:00:12.750Z", uuid="d", parentUuid="tool"),
            a("missing", 100, "2026-09-18T10:00:15Z", uuid="e", parentUuid="absent")])
        # A copied file without its parent must not erase an existing timing.
        w("timing/.claude/projects/p/copy.jsonl", [a("timed", 200, "2026-09-18T10:00:05.250Z")])
        old_cx = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = os.path.join(timing_home, ".codex")
        event = lambda kind, ts: {"type": "event_msg" if kind == "user_message" else "response_item", "timestamp": ts, "payload": {"type": kind}}
        w("timing/.codex/sessions/old.jsonl", [
            event("user_message", "2026-09-18T10:00:00Z"),
            tc(usage(100, 0, 200), usage(100, 0, 200), "2026-09-18T10:00:04Z"),
            tc(usage(100, 0, 200), usage(100, 0, 200), "2026-09-18T10:00:05Z"),
            event("function_call_output", "2026-09-18T10:00:10Z"),
            tc(usage(200, 0, 300), usage(100, 0, 100), "2026-09-18T10:00:12Z")])
        w("timing/.codex/sessions/new.jsonl", [
            event("user_message", "2026-09-18T10:00:00Z"),
            tur("resp-timed", usage(100, 0, 200), "2026-09-18T10:00:04Z"),
            tc(usage(100, 0, 200), usage(100, 0, 200), "2026-09-18T10:00:04Z")])
        try:
            timed, _ = collect_records(timing_home, 0)
        finally:
            if old_cx is None: os.environ.pop("CODEX_HOME", None)
            else: os.environ["CODEX_HOME"] = old_cx
        by_id = dict((r["id"], r) for r in timed)
        assert by_id["timed"]["out"] == 200 and by_id["timed"]["seconds"] == 5
        assert by_id["tool-timed"]["seconds"] == 2.5 and "seconds" not in by_id["missing"]
        assert by_id["resp-timed"]["seconds"] == 4
        replay_path = os.path.join(timing_home, ".codex/sessions/new.jsonl")
        with open(replay_path, "a") as fh:
            fh.write(json.dumps(tur("resp-timed", usage(100, 0, 200), "2026-09-18T10:00:04Z")) + "\n")
            fh.write(json.dumps(tc(usage(100, 0, 200), usage(100, 0, 200), "2026-09-18T10:00:04Z")) + "\n")
        replayed = _codex_file_records(replay_path)
        assert len(replayed) == 1 and replayed[0]["seconds"] == 4, "identical precise replay retains timing"
        assert sorted(r["seconds"] for r in timed if r["k"] == "codex") == [2, 4, 4]
        for output, seconds in ((49, 2), (100, 0.9), (100, 601), (100, -1), (100, float("nan"))):
            rec = {"out": output}; _add_seconds(rec, seconds)
            assert "seconds" not in rec
        for seconds in (1, 600):
            rec = {"out": 50}; _add_seconds(rec, seconds)
            assert rec["seconds"] == seconds
        if sqlite3 is not None:
            db_path = os.path.join(tmp, "timing.db")
            conn = sqlite3.connect(db_path)
            conn.execute("CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT)")
            for rid, timing in (("oc-timed", {"created": 1000250, "completed": 1002750}), ("oc-old", {}), ("oc-long", {"created": 1000, "completed": 602000})):
                data = {"role": "assistant", "time": timing, "tokens": {"input": 10, "output": 80, "reasoning": 20}}
                conn.execute("INSERT INTO message VALUES(?,?,?,?,?)", (rid, "session", 1000000, 1003000, json.dumps(data)))
            conn.commit(); conn.close()
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                assert run(db_path, 0) == 0
            oc = dict((r["id"], r) for r in map(json.loads, captured.getvalue().splitlines()) if "id" in r)
            assert oc["oc-timed"]["seconds"] == 2.5
            assert "seconds" not in oc["oc-old"] and "seconds" not in oc["oc-long"]
        # 配额 fixtures: 用户字段不外传，时间/窗口规范化，坏缺文件保持未知。
        quota_home = os.path.join(tmp, "quota-home")
        os.makedirs(os.path.join(quota_home, ".config", "claude"))
        with open(os.path.join(quota_home, ".config", "claude", "claude-usage.json"), "w") as fh:
            json.dump({"_captured_at": 1780000000, "five_hour": {"used_percentage": 31.5, "resets_at": 1780000300},
                       "seven_day": {"used_percentage": 120}, "account_email": "must-not-leak"}, fh)
        custom_claude = os.path.join(quota_home, "custom-claude")
        os.makedirs(custom_claude)
        with open(os.path.join(custom_claude, "claude-usage.json"), "w") as fh:
            json.dump({"_captured_at": 1780000100, "five_hour": {"used_percentage": 12}}, fh)
        old_claude_config = os.environ.get("CLAUDE_CONFIG_DIR")
        os.environ["CLAUDE_CONFIG_DIR"] = custom_claude
        assert _read_claude_usage(quota_home)["five_hour"]["used_percentage"] == 12
        if old_claude_config is None: os.environ.pop("CLAUDE_CONFIG_DIR", None)
        else: os.environ["CLAUDE_CONFIG_DIR"] = old_claude_config
        with open(os.path.join(quota_home, ".claude.json"), "w") as fh:
            json.dump({"cachedUsageUtilization": {"fetchedAtMs": 1780000010000, "accountUuid": "must-not-leak",
                "utilization": {"five_hour": {"utilization": 42, "resets_at": "2026-05-29T13:00:00Z"},
                                "seven_day": {"utilization": 67, "resets_at": "2026-06-05T12:00:00Z"},
                                "malformed": {"utilization": True}}}, "email": "must-not-leak"}, fh)
        os.makedirs(os.path.join(quota_home, ".grok", "logs"))
        grok = {"ts": "2026-05-29T12:00:00Z", "message": "billing: fetched credits config",
                "ctx": {"subscriptionTier": "SuperGrok", "config": {"creditUsagePercent": 44,
                "currentPeriod": {"start": "2026-05-22T12:00:00Z", "end": "2026-05-29T12:00:00Z"}}}}
        with open(os.path.join(quota_home, ".grok", "logs", "unified.jsonl"), "w") as fh: fh.write(json.dumps(grok) + "\n")
        os.makedirs(os.path.join(quota_home, ".cache", "agy-hud"))
        with open(os.path.join(quota_home, ".cache", "agy-hud", "quota_cache.json"), "w") as fh:
            json.dump({"updated_at": 1780000001, "pools": {"gemini": {"5h": {"remaining_fraction": 0.25, "reset_at": 1780001000}},
                "3p": {"weekly": {"remaining_fraction": 0.5, "recorded_at": 1780000000}}}}, fh)
        codex_day = datetime.datetime.fromtimestamp(time.time()).strftime("%Y/%m/%d")
        codex_dir = os.path.join(quota_home, ".codex", "sessions", codex_day)
        os.makedirs(codex_dir)
        with open(os.path.join(codex_dir, "quota.jsonl"), "w") as fh:
            fh.write(json.dumps({"timestamp": "2026-05-29T12:00:00Z", "payload": {"rate_limits": {
                "limit_id": "codex", "plan_type": "pro", "primary": {"used_percent": 22, "window_minutes": 300,
                "resets_at": 1780000400}, "secondary": {"used_percent": 77, "window_minutes": 10080,
                "resets_at": 1780600000}}}}) + "\n")
            # A newer Spark bucket must not replace the main Codex platform quota.
            fh.write(json.dumps({"timestamp": "2026-05-29T12:01:00Z", "payload": {"rate_limits": {
                "limit_id": "codex_spark", "plan_type": "spark", "primary": {"used_percent": 99,
                "window_minutes": 300}, "secondary": {"used_percent": 98, "window_minutes": 10080}}}}) + "\n")
        old_home = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = os.path.join(quota_home, ".codex")
        old_count = _session_counts
        _session_counts = lambda: (dict((k, 0) for k in ("claude", "codex", "grok", "agy")), False)
        try:
            platforms = collect_platform_quotas(quota_home, now=time.time())
        finally:
            _session_counts = old_count
            if old_home is None: os.environ.pop("CODEX_HOME", None)
            else: os.environ["CODEX_HOME"] = old_home
        assert set(platforms) == {"claude", "codex", "grok", "agy"}
        assert platforms["claude"]["quota"]["five_hour"]["used_percentage"] == 42
        assert platforms["claude"]["quota"]["five_hour"]["resets_at"] == _iso_epoch("2026-05-29T13:00:00Z")
        assert platforms["claude"]["quota"]["seven_day"]["used_percentage"] == 67
        assert platforms["claude"]["captured_at"] == 1780000010
        claude_safe = _read_claude_usage(quota_home)
        assert "accountUuid" not in claude_safe and "email" not in claude_safe
        assert "malformed" not in claude_safe and "account_email" not in claude_safe
        assert claude_safe["_captured_at"] - 1780000000 == 10
        assert platforms["grok"]["tier"] == "SuperGrok"
        assert platforms["grok"]["quota"]["seven_day"]["window_seconds"] == 604800
        assert platforms["agy"]["quota"]["five_hour"]["used_percentage"] == 75
        assert platforms["agy"]["quota"]["secondary_seven_day"]["used_percentage"] == 50
        assert platforms["codex"]["tier"] == "pro"
        assert platforms["codex"]["quota"]["five_hour"]["used_percentage"] == 22
        assert platforms["codex"]["quota"]["seven_day"]["used_percentage"] == 77
        assert "secondary_seven_day" not in platforms["codex"]["quota"]
        assert platforms["agy"]["note"] == "session_count_unavailable"
        # Older or malformed cached sources must leave the newer applicable snapshot intact.
        cache_path = os.path.join(quota_home, ".claude.json")
        with open(cache_path, "w") as fh:
            json.dump({"cachedUsageUtilization": {"fetchedAtMs": 1779999999000,
                "utilization": {"five_hour": {"utilization": 88}}}}, fh)
        assert _read_claude_usage(quota_home)["five_hour"]["used_percentage"] == 31.5
        with open(cache_path, "w") as fh:
            json.dump({"cachedUsageUtilization": {"fetchedAtMs": 1780000020000, "accountUuid": "ignored",
                "utilization": {"five_hour": {"utilization": True}}}}, fh)
        assert _read_claude_usage(quota_home)["five_hour"]["used_percentage"] == 31.5
        assert _read_claude_usage(os.path.join(tmp, "missing")) is None
        legacy_home = os.path.join(tmp, "legacy")
        legacy_dir = os.path.join(legacy_home, ".codex", "sessions", codex_day)
        os.makedirs(legacy_dir)
        with open(os.path.join(legacy_dir, "legacy.jsonl"), "w") as fh:
            fh.write(json.dumps({"timestamp": "2026-05-29T12:00:00Z", "payload": {"rate_limits": {
                "plan_type": "legacy", "primary": {"used_percent": 31, "window_minutes": 300},
                "secondary": {"used_percent": 61, "window_minutes": 10080}}}}) + "\n")
        legacy_old_codex_home = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = os.path.join(legacy_home, ".codex")
        try:
            legacy_quota, legacy_plan, _legacy_capture = _codex_quotas(legacy_home, time.time())
        finally:
            if legacy_old_codex_home is None: os.environ.pop("CODEX_HOME", None)
            else: os.environ["CODEX_HOME"] = legacy_old_codex_home
        assert legacy_plan == "legacy" and legacy_quota["five_hour"]["used_percentage"] == 31
        assert legacy_quota["seven_day"]["used_percentage"] == 61
        for platform in platforms.values():
            assert {"tier", "sessions", "quota"}.issubset(platform)
            assert isinstance(platform["sessions"], int)
            for window in platform["quota"].values():
                if isinstance(window, dict) and "used_percentage" in window:
                    assert 0 <= window["used_percentage"] <= 100
                    assert set(window).issubset({"used_percentage", "resets_at", "captured_at", "window_seconds"})
        class FakeProc:
            def __init__(self, output): self.stdout = io.BytesIO(output)
            def wait(self, timeout=None): return 0
        ps_rows = (b"100 10 /usr/local/bin/claude\n101 100 /usr/local/bin/claude\n"
                   b"102 10 /usr/local/bin/codex\n103 10 /usr/local/bin/grok\n104 10 /usr/local/bin/agy\n"
                   b"105 10 /bin/zsh -lc 'codex --version'\n106 1 /usr/local/bin/claude\n"
                   b"107 10 /usr/bin/python3 -c 'task prompt mentions codex'\n")
        saved_popen = subprocess.Popen
        subprocess.Popen = lambda *_a, **_k: FakeProc(ps_rows)
        try:
            counted, ok = _session_counts()
        finally:
            subprocess.Popen = saved_popen
        assert ok and counted == {"claude": 1, "codex": 1, "grok": 1, "agy": 1}
        assert _read_claude_usage(os.path.join(tmp, "missing")) is None
        assert _grok_quota(os.path.join(tmp, "missing")) == (None, "")
        assert _agy_quotas(os.path.join(tmp, "missing")) == (None, None)
        assert _pct("bad") is None and _pct(float("nan")) is None and _pct(-3) == 0 and _pct(123) == 100
        saved_collect = collect_platform_quotas
        captured_out, captured_err = io.StringIO(), io.StringIO()
        collect_platform_quotas = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("fixture failure"))
        try:
            with contextlib.redirect_stdout(captured_out), contextlib.redirect_stderr(captured_err):
                assert run_quotas() == 1
        finally:
            collect_platform_quotas = saved_collect
        failure = json.loads(captured_out.getvalue().splitlines()[0])
        assert failure.get("__ok__") is False and failure.get("error", "").startswith("RuntimeError")
        # Account/session metadata and true turn-level TTFT never add usage requests.
        isolated = os.path.join(tmp, "account-home")
        account_path = os.path.join(isolated, ".codex", "sessions", "fixture.jsonl")
        os.makedirs(os.path.dirname(account_path))
        identity_fields = {"model_provider": "openai", "creator_account_id": "ACCOUNT-A"}
        task = lambda tid, value, **extra: {"type": "event_msg", "timestamp": "2026-09-18T12:00:09Z", "payload": dict(
            type="task_complete", turn_id=tid, root_turn_id="shared-root", time_to_first_token_ms=value, **extra)}
        fixture = [{"type": "session_meta", "payload": identity_fields},
                   {"type": "turn_context", "payload": {"turn_id": "turn-a", "model": "first-model"}},
                   {"type": "turn_context", "payload": {"turn_id": "turn-a", "model": "last-model"}},
                   tur("resp_account", usage(50, 10, 5), "2026-09-18T12:00:01Z"),
                   task("turn-a", 1250.5, started_at=1789732800), task("turn-zero", 0),
                   task("turn-error", 30, error={"message": "fixture"}),
                   task("turn-null-error", 31, error=None), task("turn-negative", -1),
                   task("turn-nan", float("nan")), task("turn-inf", float("inf")), task("turn-bool", True),
                   task("turn-missing", None)]
        with open(account_path, "w") as fh: fh.write("\n".join(json.dumps(row) for row in fixture) + "\n")
        legacy = _codex_file_records(account_path)
        auxiliary = _codex_file_records(account_path, include_metadata=True)
        assert len(legacy) == 1 and legacy[0]["account_id"] == "ACCOUNT-A"
        assert [r for r in auxiliary if r["k"] == "codex"] == legacy
        metrics = {r["turn_id"]: r for r in auxiliary if r["k"] == "codex_turn"}
        assert set(metrics) == {"turn-a", "turn-zero", "turn-error", "turn-null-error"}
        assert metrics["turn-a"]["ttft_ms"] == 1250.5 and metrics["turn-a"]["m"] == "first-model"
        assert metrics["turn-zero"]["ttft_ms"] == 0 and "m" not in metrics["turn-zero"]
        assert metrics["turn-error"]["failed"] and not metrics["turn-null-error"]["failed"]
        assert _codex_session_identity(account_path) == _identity("codex", "ACCOUNT-A")
        assert _codex_session_identity(os.path.join(isolated, "missing.jsonl")) == {}
        import builtins
        old_open = builtins.open
        def denied(path, *args, **kwargs):
            if path == account_path: raise PermissionError("fixture access denied")
            return old_open(path, *args, **kwargs)
        builtins.open = denied
        try: assert _codex_session_identity(account_path) == {}
        finally: builtins.open = old_open
        assert _claude_quota_identity(os.path.join(isolated, "missing"), {}) == {}
        old_env = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = os.path.join(isolated, ".codex")
        try:
            once, cursor = collect_records(isolated, 0, include_metadata=True)
            backfill, cursor2 = collect_records(isolated, cursor, include_metadata=True, include_identity_backfill=True)
            assert cursor == cursor2
            assert len(backfill) == 1 and backfill[0]["k"] == "account_session"
            assert sum(r["k"] in ("codex", "claude") for r in once) == 1
            # Wire sentinel count excludes metadata and completed turns, with identical gzip cursor.
            old_expanduser = os.path.expanduser
            os.path.expanduser = lambda value: isolated if value == "~" else old_expanduser(value)
            try:
                output = io.StringIO()
                with contextlib.redirect_stdout(output): assert run_records(0, True) == 0
                wire = zlib.decompress(base64.b64decode(output.getvalue()), -15).decode()
                sentinel = json.loads(wire.splitlines()[-1])
                assert sentinel["__ok__"] and sentinel["count"] == 1 and sentinel["max_mtime"] == cursor
            finally: os.path.expanduser = old_expanduser
        finally:
            if old_env is None: os.environ.pop("CODEX_HOME", None)
            else: os.environ["CODEX_HOME"] = old_env
        # Cross-device identity is provider/account/workspace, not a host or label.
        assert _identity("CODEX", " ACCOUNT-A ") == _identity("openai", "ACCOUNT-A")
        assert _identity("anthropic", "account", "org-one") != _identity("anthropic", "account", "org-two")
        assert _identity("openai", "\x00bad") == {}
        claude_profile = os.path.join(tmp, "identity-claude")
        os.makedirs(os.path.join(claude_profile, ".claude"))
        state_path = os.path.join(claude_profile, ".claude.json")
        with open(state_path, "w") as fh: json.dump({"oauthAccount": {"accountUuid": "subject", "organizationUuid": "org"}}, fh)
        stamp = os.path.getmtime(state_path)
        old_config, old_base = os.environ.pop("CLAUDE_CONFIG_DIR", None), os.environ.pop("ANTHROPIC_BASE_URL", None)
        try:
            assert _claude_quota_identity(claude_profile, {"_captured_at": stamp + 1})["account_workspace"] == "org"
            assert _claude_quota_identity(claude_profile, {"_captured_at": stamp - 1}) == {}
            assert _claude_quota_identity(claude_profile, {"five_hour": {"used_percentage": 1}}) == {}
            os.environ["CLAUDE_CONFIG_DIR"] = "/fixture/other-profile"
            assert _claude_quota_identity(claude_profile, {"_captured_at": stamp + 1}) == {}
            os.environ.pop("CLAUDE_CONFIG_DIR", None)
            os.environ["ANTHROPIC_BASE_URL"] = "https://anthropic.com.example.invalid"
            assert _claude_quota_identity(claude_profile, {"_captured_at": stamp + 1}) == {}
        finally:
            if old_config is not None: os.environ["CLAUDE_CONFIG_DIR"] = old_config
            else: os.environ.pop("CLAUDE_CONFIG_DIR", None)
            if old_base is not None: os.environ["ANTHROPIC_BASE_URL"] = old_base
            else: os.environ.pop("ANTHROPIC_BASE_URL", None)
        old_records = globals()["collect_records"]
        globals()["collect_records"] = lambda *_a, **_k: (_ for _ in ()).throw(PermissionError("fixture access denied"))
        try:
            failed_output = io.StringIO()
            with contextlib.redirect_stdout(failed_output), contextlib.redirect_stderr(io.StringIO()):
                assert run_records(0, True) == 1
            assert json.loads(failed_output.getvalue())["__ok__"] is False
        finally: globals()["collect_records"] = old_records
        # 压缩往返
        co = zlib.compressobj(6, zlib.DEFLATED, -15)
        blob = co.compress(b"hello") + co.flush()
        assert zlib.decompress(blob, -15) == b"hello"
        print("collector selftest OK: 记录去重/游标/压缩 + Claude/Codex/OpenCode 计时 + 账号元数据/turn TTFT + 四平台额度窗口/缺失与脱敏 + Codex 进程元数据 + 当前登录 presence fixtures")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

def main(argv):
    parser = argparse.ArgumentParser(description="VibeDeck remote opencode usage collector")
    parser.add_argument("--db", default=None, help="opencode.db 路径")
    parser.add_argument("--since", type=int, default=0, help="只输出 time_updated > MS 的行")
    parser.add_argument("--summary", action="store_true", help="输出今日各 CLI 用量汇总（单行 JSON）")
    parser.add_argument("--quotas", action="store_true", help="只输出平台额度与会话数，不扫描历史用量记录")
    parser.add_argument("--records", action="store_true", help="输出 Claude / Codex 逐条请求用量（mtime > --since 的文件）")
    parser.add_argument("--identity-backfill", action="store_true", help="另读 Codex session header 身份，不重拉旧用量")
    parser.add_argument("--gz", action="store_true", help="--records 输出压缩成一行 base64(raw deflate)")
    parser.add_argument("--tools-since", type=int, default=None, help="DSH / Grok 记录单独的 mtime 游标（首次补采用 0）")
    parser.add_argument("--selftest", action="store_true", help="用临时目录自测解析口径")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    if args.records:
        return run_records(args.since, args.gz, args.identity_backfill, args.tools_since)
    if args.quotas:
        return run_quotas()
    if args.summary:
        return run_summary()
    return run(resolve_db(args.db), args.since)

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
