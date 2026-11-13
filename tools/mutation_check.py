#!/usr/bin/env python3
"""Mutation check: break the source on purpose and confirm the test-suite notices.

For every mutation a private copy of the project is created, ONE textual change is applied to
src/, the suite is run, and the mutation counts as KILLED if the suite fails (or errors).
A SURVIVED mutation means the tests do not constrain that behaviour.

Usage: python tools/mutation_check.py [workdir]
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (label, file, old, new)
M = [
    ("engine: ignore degraded connection", "engine.lua", "    if degraded then\n      outcome, reason = \"unconfirmed\", \"degraded:\"", "    if false then\n      outcome, reason = \"unconfirmed\", \"degraded:\""),
    ("engine: ignore timer lateness (stall)", "engine.lua", "if not degraded and (t - shot.deadline) > cfg.timer_late_tol then", "if false then"),
    ("engine: remove causal floor", "engine.lua", "      if (t - s.t) < floor then", "      if false then"),
    ("engine: no burst coalescing", "engine.lua", "if b and t >= b.last and (t - b.last) <= cfg.burst_gap and (t - b.first) <= cfg.burst_gap * 3\n     and not self:_newer_shot(uid, b.first, t) then", "if false then"),
    ("engine: no overlap ambiguity", "engine.lua", "        o.overlap_hit = true", "        o.overlap_hit = false"),
    ("engine: no duplicate-attempt filter", "engine.lua", "if last ~= nil and (t - last) < cfg.dedupe_eps then", "if false then"),
    ("engine: context changes ignored", "engine.lua", "if not s.ctx then s.ctx = reason end", "s.ctx = nil"),
    ("engine: no late-damage re-classification", "engine.lua", "(t - m.deadline) <= cfg.late_grace * m.window then", "false then"),
    ("engine: miss allowed with no observable target", "engine.lua", "if shot.ncand == 0 then", "if false then"),
    ("engine: target_lost does nothing", "engine.lua", "      s.nlive = s.nlive - 1", "      s.nlive = s.nlive"),
    ("engine: ammo-before-activation not matched", "engine.lua", "if pf ~= nil and (t - pf) >= 0 and (t - pf) <= cfg.same_frame_eps then", "if false then"),
    ("engine: damage before the shot attributable", "engine.lua", "if not s.burst and is_cand(s, uid) and t >= s.t then", "if not s.burst and is_cand(s, uid) then"),
    ("engine: later pellets not added to bucket damage", "engine.lua", "if s.state == \"resolved\" and s.outcome == \"hit\" then self:_apply(s, \"damage\", amount) end", ""),
    ("engine: expiry timer not cancelled on hit", "engine.lua", "    pcall(self.timers.cancel, shot.timer)\n    shot.timer = nil\n  end\n  shot.state = \"resolved\"", "    shot.timer = nil\n  end\n  shot.state = \"resolved\""),
    ("engine: reset keeps old state", "engine.lua", "  self:_cancel_all()\n  self:_init_state()\n  self.on_change()", "  self:_cancel_all()\n  self.on_change()"),
    ("engine: not_fired never produced", "engine.lua", "elseif shot.ammo_tracked and not shot.fire then", "elseif false then"),
    ("world: Humanoid.Died connection key not released", "world.lua", "key .. \"hdied\"", "key .. \"died\""),
    ("util: Bag.set does not replace existing key", "util.lua", "function Bag:set(key, signal, fn)\n  self:drop(key)", "function Bag:set(key, signal, fn)"),
    ("world: duplicate equip not filtered", "world.lua", "  if self.current and self.current.tool == inst then return end   -- duplicate ChildAdded\n", ""),
    ("world: unequip of a stale tool clears current", "world.lua", "if not (self.current and self.current.tool == inst) then return end", "if not self.current then return end"),
    ("world: respawn context not recorded", "world.lua", "  self.engine:note_context(\"respawn\")\n", ""),
    ("world: health increase counted as damage", "world.lua", "if last ~= nil and health < last and self.cfg.enabled then", "if last ~= nil and health ~= last and self.cfg.enabled then"),
    ("world: unobservable players counted as candidates", "world.lua", "  for uid, tg in pairs(self.targets) do\n    if tg.hum then", "  for uid, tg in pairs(self.targets) do\n    if true then"),
    ("world: sampler flag set before spawn succeeds", "world.lua", "    self.sampler_on = false\n    self.sampler_gen = self.sampler_gen + 1\n    error(\"sampler could not start", "    error(\"sampler could not start"),
    ("host: read-only flag guard removed", "host.lua", "if type(name) ~= \"string\" or string.sub(name, 1, #H.FLAG_PREFIX) ~= H.FLAG_PREFIX then", "if false then"),
    ("host: ping validation removed", "host.lua", "if not U.is_finite(v) or v <= 0 or v > 1e6 then", "if false then"),
    ("ui: menu sync fires handlers", "ui.lua", "if self.dead or self.syncing then return end", "if self.dead then return end"),
    ("ui: HUD rewrites unchanged lines", "ui.lua", "if h.text ~= lines[i] then", "if true then"),
    ("ui: flags rewritten every flush", "ui.lua", "if self.flag_cache[name] ~= v then", "if true then"),
    ("diag: spike detection off", "diag.lua", "spike = ms > math.max(base * cfg.spike_ratio, base + cfg.spike_min_ms)", "spike = false"),
    ("diag: learn_window ignored (always learns)", "diag.lua", "if cfg.learn_window and self.lat:size() >= cfg.window_emp_min then", "if self.lat:size() >= cfg.window_emp_min then"),
    ("config: upper clamp removed", "config.lua", "if v > hi then return hi, \"clamped down to \" .. tostring(hi) end", "if v > hi then return v end"),
    ("config: bound-dragging removed", "config.lua", "  if key == \"window_min\" and v.window_min > v.window_max then\n    v.window_max = U.clamp(v.window_min, 0.1, 10)", "  if false then\n    v.window_max = U.clamp(v.window_min, 0.1, 10)"),
    ("main: unload hook not registered", "main.lua", "    host.juju.on_unload(function() inst.shutdown(\"unload\") end)\n", ""),
    ("main: old instance not shut down on reload", "main.lua", "    pcall(prev.shutdown, \"reload\")\n", ""),
    ("automode: degraded connection ignored", "automode.lua", "elseif self.ctx.degraded then", "elseif false then"),
    ("automode: SUSPENDED shots not tagged auto", "automode.lua", "if self.state == \"ACTIVE\" or self.state == \"SUSPENDED\" then return \"auto\" end", "if self.state == \"ACTIVE\" then return \"auto\" end"),
    ("weapon: 'mag' matches inside words again", "weapon.lua", "if string.sub(w, 1, #p) == p or (#w >= #p and string.sub(w, -#p) == p) then return true end", "if string.find(w, p, 1, true) then return true end"),

    # ---- added after the independent review
    ("engine: orphan burst may swallow a newer shot's damage", "engine.lua", "\n     and not self:_newer_shot(uid, b.first, t) then", " then"),
    ("engine: bursts unbounded in length", "engine.lua", " and (t - b.first) <= cfg.burst_gap * 3", ""),
    ("engine: hit credited without fire evidence", "engine.lua", "if chosen.ammo_tracked and not chosen.fire then", "if false then"),
    ("engine: deferred hit never confirmed by late ammo", "engine.lua", "      if s.deferred then\n        s.deferred = nil\n        self:_finish(s, \"hit\", nil, t)\n      end\n", ""),
    ("engine: window below causal floor not detected", "engine.lua", "elseif cfg.causal_check and shot.ping and shot.window <= (shot.ping / 1000) * cfg.causal_ratio then", "elseif false then"),
    ("engine: damage just past the deadline ignored", "engine.lua", "elseif late_pending == nil and (t - s.deadline) <= cfg.late_grace * s.window then", "elseif false then"),
    ("engine: no connection sample at expiry", "engine.lua", "    pcall(self.diag.sample, self.diag, \"expiry\", false)       -- a spike that began mid-window shows up now\n", ""),
    ("engine: invariant checker blind to leaked shots", "engine.lua", "if derived ~= #self.pending then", "if false then"),
    ("world: unvalidated ammo source trusted", "world.lua", "ammo_tracked = (cur.ammo_kind ~= nil and cur.ammo_validated == true),", "ammo_tracked = cur.ammo_kind ~= nil,"),
    ("world: late local Humanoid not hooked", "world.lua", "    self:_maybe_local_humanoid(c)\n", ""),
    ("world: clock self-check removed", "world.lua", "        self:_check_clock(c0, waited)\n", ""),
    ("weapon: constant-style names accepted", "weapon.lua", "local NOT_LIVE = { \"max\", \"size\", \"capacity\", \"speed\", \"damage\", \"rate\", \"reserve\", \"total\", \"spare\",\n  \"stock\", \"limit\" }", "local NOT_LIVE = { \"max\" }"),
    ("ui: callbacks during element creation act", "ui.lua", "  self.syncing = true      -- ignore any callback the host fires while elements are being created\n", ""),
    ("ui: Drawing object leaked on config failure", "ui.lua", "        pcall(function() obj:Remove() end)        -- never leave a half-configured object on screen\n", ""),
    ("ui: momentary button ignores a click reporting false", "ui.lua", "    E.reset = self:_add(left, { name = \"Reset stats\", type = \"toggle\" }, function()\n", "    E.reset = self:_add(left, { name = \"Reset stats\", type = \"toggle\" }, function(v)\n      if v ~= true then return end\n"),
    ("main: stale jhc_loaded flag after unload", "main.lua", "    pcall(host.set_flag, \"jhc_loaded\", false)       -- other addons must not see a stale \"loaded\"\n", ""),
    ("main: handler error log not rate limited", "main.lua", "if n <= 3 or n % 100 == 0 then", "if true then"),
    ("config: late_grace upper bound loosened", "config.lua", "late_grace = { \"number\", 0, 2 },", "late_grace = { \"number\", 0, 5 },"),
    ("config: timer_late_tol may be 0", "config.lua", "timer_late_tol = { \"number\", 0.02, 2 },", "timer_late_tol = { \"number\", 0, 2 },"),

    # ---- added after the first live run
    ("engine: Juju confirmation never corroborates a hit", "engine.lua", "if not h.juju_confirmed and h.victim == uid and t >= h.hit_t and (t - h.hit_t) <= cfg.confirm_match then", "if false then"),
    ("engine: confirmation pellets not de-duplicated", "engine.lua", "if cb and t >= cb.last and (t - cb.last) <= cfg.burst_gap then", "if false then"),
    ("engine: confirmation cannot resolve a pending shot", "engine.lua", "if not s.burst and t >= s.t and t <= s.deadline + cfg.late_grace * s.window + ZERO then", "if false then"),
    ("engine: deferred hit not released by confirmation", "engine.lua", "if s.deferred and s.victim == uid then", "if false then"),
    ("host: nil from create_connection trusted (no fallback)", "host.lua", "        if okd and d ~= nil then return conn end", "        return conn"),
    ("host: connects-but-returns-nil not flagged", "host.lua", "        host.dup_risk = true\n", "        host.dup_risk = false\n"),
    ("ui: menu reported OK with zero controls", "ui.lua", "  self.menu_ok = created > 0", "  self.menu_ok = true"),
    ("world: use_juju_signals=false ignored", "world.lua", "  if not self.cfg.use_juju_signals then return end\n", ""),

    # ---- trusted-latency window (second live run)
    ("diag: trusted latencies ignored by the window", "diag.lua", "  if trusted then\n    emp = trusted * cfg.window_emp_mult", "  if false then\n    emp = trusted * cfg.window_emp_mult"),
    ("diag: untrusted latencies also trusted", "diag.lua", "  if trusted then self.tlat:push(sec) end", "  self.tlat:push(sec)"),
    ("diag: trusted term needs no minimum sample count", "diag.lua", "  if self.tlat:size() < self.cfg.window_emp_min then return nil end\n", ""),
    ("engine: hit latency always marked trusted", "engine.lua", "self.diag, lat, shot.juju_confirmed == true)", "self.diag, lat, true)"),
    ("engine: corroboration does not teach the window", "engine.lua", "      if h.latency then pcall(self.diag.note_latency, self.diag, h.latency, true) end\n", ""),
    ("diag: reset keeps trusted latencies", "diag.lua", "self.lat:clear(); self.tlat:clear()", "self.lat:clear()"),

    # ---- gun shot source (third live run)
    ("world: bullet signal not hooked", "world.lua", "  self:_hook_bullet_signal()\n", ""),
    ("world: use_bullet_signal=false ignored", "world.lua", "  if not self.cfg.use_bullet_signal then return end\n", ""),
    ("world: bullets invent shots with no weapon", "world.lua", "  if cur == nil then return end                      -- weapon unknown: do not invent a shot", "  if false then return end"),
    ("engine: pellets not coalesced into one shot", "engine.lua", "  if self.engine:add_pellet(t, cur.weapon.key) then return end   -- same trigger pull\n", ""),
    ("engine: pellet window unbounded", "engine.lua", "  if last == nil or (t - last) > self.cfg.pellet_gap then return false end", "  if last == nil then return false end"),
    ("engine: pellet after a fast hit opens a new shot", "engine.lua", "  -- the shot already resolved (a fast hit): still its pellet, do not open a new shot\n  return true", "  return false"),
]


def run_suite(work):
    cmd = [sys.executable, "-I", os.path.join(work, "tools", "run_lua.py"), "--engine", "obs",
           os.path.join(work, "tests", "run_all.lua")]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    out = p.stdout + p.stderr
    return p.returncode, out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--only=")]
    only = None
    for a in sys.argv[1:]:
        if a.startswith("--only="):
            only = {int(x) for x in a[7:].split(",") if x}
    base = args[0] if args else tempfile.mkdtemp(prefix="jhc_mut_")
    os.makedirs(base, exist_ok=True)
    killed, survived, broken = [], [], []
    for n, (label, fname, old, new) in enumerate(M, 1):
        if only is not None and n not in only:
            continue
        work = os.path.join(base, "w%02d" % n)
        if os.path.exists(work):
            shutil.rmtree(work)
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns("__pycache__", "_driver.lua", ".git"))
        path = os.path.join(work, "src", fname)
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        if src.count(old) != 1:
            broken.append((label, "pattern occurs %d times" % src.count(old)))
            print("[%02d] PATTERN? %s (%d matches)" % (n, label, src.count(old)), flush=True)
            continue
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(src.replace(old, new))
        rc, out = run_suite(work)
        m = re.search(r"TOTAL (\d+) tests: (\d+) passed, (\d+) failed", out)
        failed = [l.strip() for l in out.splitlines() if l.startswith("FAIL [")]
        if rc != 0:
            killed.append(label)
            first = failed[0][5:] if failed else ("rc=%d" % rc)
            print("[%02d] killed   %-58s by: %s%s" % (n, label, first[:70], (" (+%d more)" % (len(failed) - 1)) if len(failed) > 1 else ""), flush=True)
        else:
            survived.append(label)
            print("[%02d] SURVIVED %s" % (n, label), flush=True)
        shutil.rmtree(work, ignore_errors=True)
    print()
    print("mutations: %d   killed: %d   survived: %d   pattern errors: %d" %
          (len(M), len(killed), len(survived), len(broken)))
    for s in survived:
        print("  SURVIVED:", s)
    for b in broken:
        print("  PATTERN ERROR:", b)
    return 0 if not survived and not broken else 1


if __name__ == "__main__":
    sys.exit(main())
