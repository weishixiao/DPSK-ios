#!/usr/bin/env node
// jb.mjs — DSH Go 引擎里的越狱代理客户端
//
// 引擎跑在 App 沙盒内：Node 可用、fetch 可用，但 child_process 被禁用，
// 也看不到 /var/jb。所以所有真正要落地的动作都交给 jbhelper 守护进程。
//
// 用法（在 bash 工具里跑）：
//   node DSH-Go/jb/proxy/jb.mjs health
//   node DSH-Go/jb/proxy/jb.mjs inspect com.hole.io.attack.battle
//   node DSH-Go/jb/proxy/jb.mjs write ./local.m  /var/jb/build/HoleNoAds/Tweak.x
//   node DSH-Go/jb/proxy/jb.mjs exec -- /var/jb/usr/bin/make -C /var/jb/build/HoleNoAds package
//   node DSH-Go/jb/proxy/jb.mjs install /var/jb/build/HoleNoAds/.theos/_/debs/*.deb
//   node DSH-Go/jb/proxy/jb.mjs kill 黑洞入侵

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

// 工作区路径里有空格（Application Support），必须用 fileURLToPath 而不是 URL.pathname
const HERE = path.dirname(fileURLToPath(import.meta.url));
const CFG_PATH = path.join(HERE, "..", "config.json");

function loadCfg() {
  try {
    const c = JSON.parse(fs.readFileSync(CFG_PATH, "utf8"));
    return { host: c.host ?? "127.0.0.1", port: c.port ?? 8787, token: c.token ?? "", timeoutMs: c.timeoutMs ?? 600000 };
  } catch {
    console.error(`读不到 ${CFG_PATH}，先按 README 建一个：{"host":"127.0.0.1","port":8787,"token":"…"}`);
    process.exit(2);
  }
}

const cfg = loadCfg();

async function call(pathname, body) {
  const url = `http://${cfg.host}:${cfg.port}${pathname}`;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), cfg.timeoutMs + 15000);
  let res;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", "x-jb-token": cfg.token },
      body: JSON.stringify(body ?? {}),
      signal: ac.signal,
    });
  } catch (e) {
    console.error(`连不上 jbhelper (${url})：${e.cause?.code ?? e.message}`);
    console.error("检查：守护进程是否在跑（launchctl list | grep jbhelper）、config.json 的端口是否正确。");
    process.exit(3);
  } finally {
    clearTimeout(timer);
  }
  const txt = await res.text();
  try {
    return JSON.parse(txt);
  } catch {
    return { ok: false, error: `非 JSON 响应 (HTTP ${res.status}): ${txt.slice(0, 200)}` };
  }
}

function printExec(r) {
  if (r.stdout) process.stdout.write(r.stdout);
  if (!r.ok) {
    if (r.error) console.error(`[jbhelper] ${r.error}`);
    if (r.timedOut) console.error("[jbhelper] 超时被强杀");
  }
}

function fmtSize(n) {
  if (!Number.isFinite(n)) return "?";
  const u = ["B", "KB", "MB", "GB"];
  let i = 0, v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return v.toFixed(v >= 10 || i === 0 ? 0 : 1) + u[i];
}

function printInspect(r) {
  const scan = r.executable?.scan ?? {};
  const archs = (scan.archs ?? []).map(a => a.cpu ?? "?").join(", ") || "?";
  const lock = scan.encrypted ? "🔒 加密" : "✅ 未加密";
  console.log(`目标   ${r.displayName || ""} (${r.bundleID})`);
  console.log(`路径   ${r.bundlePath}`);
  console.log(`主件   ${r.executable?.name} [${archs}] ${scan.ok ? lock : "⚠️ 读不出来"}`
    + (scan.ok && scan.hasEncryptionInfo ? ` (cryptid=${scan.cryptid})` : " (无 LC_ENCRYPTION_INFO，即未加密)")
    + (scan.size ? ` ${fmtSize(scan.size)}` : ""));

  const linked = scan.dylibs ?? [];
  if (linked.length) {
    const ads = linked.filter(d => /(ad|sdk|pangle|unity|applovin|ironsource|vungle|chartboost|mintegral|topon|gdt|admob|unityads)/i.test(d));
    console.log(`链接   ${linked.length} 个 dylib`);
    for (const d of (ads.length ? ads : linked).slice(0, 12)) console.log(`         ${d}`);
    if (ads.length && ads.length < linked.length) console.log(`         …（其余 ${linked.length - ads.length} 个略）`);
  }

  const fw = r.frameworks ?? [];
  const plain = fw.filter(f => !f.encrypted);
  console.log(`框架   ${fw.length} 个，其中未加密 ${plain.length} 个`);
  for (const f of plain.slice(0, 10)) console.log(`         ✅ ${f.name} ${fmtSize(f.size)}`);
  const enc = fw.length - plain.length;
  if (enc > 0) console.log(`         其余 ${enc} 个已加密`);

  console.log(`\n结论   ${r.verdict}`);
  if (r.injectableCount > 10) {
    console.log(`       可静态注入的候选（前 10）：${(r.injectableNames ?? []).slice(0, 10).join(", ")}`);
  }
  const viaTweak = r.verdict.includes("ElleKit") || r.verdict.includes("tweak");
  console.log(`       下一步：${viaTweak ? "用 ElleKit tweak（进程内注入，与加密无关）" : "可考虑静态改包，但仍需 CoreTrust bypass"}`);
}

const [cmd, ...rest] = process.argv.slice(2);

switch (cmd) {
  case "health": {
    const r = await call("/health", {});
    console.log(JSON.stringify(r));
    process.exit(r.ok ? 0 : 1);
    break;
  }
  case "exec": {
    const argv = rest[0] === "--" ? rest.slice(1) : rest;
    if (!argv.length) {
      console.error("用法: node jb.mjs exec -- <程序> [参数…]");
      process.exit(2);
    }
    const r = await call("/exec", { argv, timeoutMs: cfg.timeoutMs });
    printExec(r);
    process.exit(r.ok ? 0 : 1);
    break;
  }
  case "write": {
    const [local, remote] = rest;
    if (!local || !remote) {
      console.error("用法: node jb.mjs write <本地文件> <设备路径>");
      process.exit(2);
    }
    const data = fs.readFileSync(local);
    const r = await call("/write", { path: remote, base64: data.toString("base64"), mode: (fs.statSync(local).mode & 0o777) || 0o644 });
    if (!r.ok) console.error(`[jbhelper] ${r.error}`);
    else console.log(`写入 ${remote}（${r.bytes} 字节）`);
    process.exit(r.ok ? 0 : 1);
    break;
  }
  case "read": {
    const [remote, local] = rest;
    const r = await call("/read", { path: remote });
    if (!r.ok) {
      console.error(`[jbhelper] ${r.error}`);
      process.exit(1);
    }
    const buf = Buffer.from(r.base64, "base64");
    if (local) fs.writeFileSync(local, buf);
    else process.stdout.write(buf);
    process.exit(0);
    break;
  }
  case "install": {
    const [deb] = rest;
    if (!deb) {
      console.error("用法: node jb.mjs install <deb 路径>");
      process.exit(2);
    }
    const r = await call("/exec", {
      argv: ["/var/jb/usr/bin/dpkg", "-i", deb],
      timeoutMs: 180000,
    });
    printExec(r);
    process.exit(r.ok ? 0 : 1);
    break;
  }
  case "kill": {
    const [name] = rest;
    if (!name) {
      console.error("用法: node jb.mjs kill <进程名或 bundle id>");
      process.exit(2);
    }
    const r = await call("/exec", { argv: ["/var/jb/usr/bin/killall", "-9", name] });
    printExec(r);
    process.exit(r.ok ? 0 : 1);
    break;
  }
  case "inspect": {
    const target = rest[0];
    if (!target) {
      console.error("用法: node jb.mjs inspect <bundle id | /path/to/App.app>");
      process.exit(2);
    }
    const payload = target.includes("/") ? { path: target } : { bundle: target };
    const r = await call("/inspect", payload);
    if (!r.ok) {
      console.error(`[jbhelper] ${r.error}`);
      process.exit(1);
    }
    printInspect(r);
    process.exit(0);
    break;
  }
  case "respring": {
    const r = await call("/exec", { argv: ["/var/jb/usr/bin/killall", "-9", "SpringBoard"] });
    printExec(r);
    process.exit(r.ok ? 0 : 1);
    break;
  }
  default:
    console.error(`用法: node jb.mjs <health|inspect|exec|write|read|install|kill|respring> …`);
    process.exit(2);
}
