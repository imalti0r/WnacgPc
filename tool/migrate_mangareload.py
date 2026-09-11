# 把 mangareload 的下载（E:/Folders/Python/NovelDownload/wnacg，纯标题命名）
# 迁移为 WNACG 的 <aid>-<净化标题>.zip 格式并注册进 downloads.json。
#
# mangareload 未持久化 aid，因此先爬站点分类列表页建立 标题→(aid,封面,日期,张数)
# 字典，再按净化后的标题匹配本地文件；同名歧义用官方直链 HEAD 长度与本地大小
# 比对消歧。文件在 E 盘原地改名（零拷贝），注册表用绝对 zipPath。
#
# 用法：
#   python tool/migrate_mangareload.py crawl   # 爬两个分类全部列表页（带缓存）
#   python tool/migrate_mangareload.py match   # 匹配并生成 migrate_plan.json + 报告
#   python tool/migrate_mangareload.py apply   # 改名 + 合并注册表（先关应用！）
#   python tool/migrate_mangareload.py report  # 打印上次匹配报告
import html
import http.client
import io
import json
import os
import re
import shutil
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
MR_ROOT = "E:/Folders/Python/NovelDownload/wnacg"
CACHE = os.path.join(HERE, "migrate_cache.json")
PLAN = os.path.join(HERE, "migrate_plan.json")
BASE = "https://www.wn10.cfd/"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
CATEGORIES = [("写真&Cosplay", 3), ("单行本-汉化", 9)]
IMG = re.compile(r"\.(jpe?g|png|webp|gif|bmp|avif)$", re.I)

REG_PATH = os.path.expandvars(
    r"%APPDATA%/com.wnacg/wnacg_pc/downloads/downloads.json")


def fetch(url, timeout=20):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


def key_of(title):
    """mangareload 文件名来源 = sanitize_filename(?n=标题)。
    ①标题属性里 &nbsp; 等实体是双重转义（&amp;nbsp;），需两次 unescape；
    ②?n= 是 query 参数：站点标题里的 + 在 query 解码时变成空格，
    所以比较时两侧都把 + 当空格。"""
    t = unicodedata.normalize("NFC", title)
    t = html.unescape(html.unescape(t))
    t = t.replace("+", " ")
    t = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", t)
    t = t.strip(". ")
    t = re.sub(r"\s+", " ", t).strip().casefold()
    return t


def wnacg_zip_stem(title):
    """与 DownloadService.zipPathFor 完全一致的文件名净化（不含 aid 前缀）"""
    name = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", title)
    name = re.sub(r"\s+", " ", name).strip()
    if len(name) > 60:
        name = name[:60].strip()
    return name or "wnacg"


def parse_list_page(html):
    items = []
    for block in re.split(r"<li[^>]*gallary_item", html)[1:]:
        am = re.search(r'photos-index-aid-(\d+)\.html', block)
        if not am:
            continue
        aid = am.group(1)
        tm = (re.search(r'<a[^>]*title="([^"]+)"', block)
              or re.search(r'class="title"[^>]*>\s*<a[^>]*>([^<]+)</a>', block))
        title = tm.group(1).strip() if tm else ""
        im = re.search(r'<img[^>]+src="([^"]+)"', block)
        cover = im.group(1) if im else ""
        if cover.startswith("//"):
            cover = "https:" + cover
        cm = re.search(r"(\d+)\s*張圖片", block)
        dm = re.search(r"創建於(\d{4}-\d{2}-\d{2})", block)
        items.append({
            "aid": aid,
            "title": title,
            "cover": cover,
            "count": int(cm.group(1)) if cm else 0,
            "date": dm.group(1) if dm else "",
        })
    return items


def _conn():
    return http.client.HTTPSConnection("www.wn10.cfd", timeout=25)


def fetch_keepalive(conn, path, timeout=25):
    """复用连接取一页；429/异常时抛给上层做退避"""
    conn.request("GET", path, headers=UA)
    r = conn.getresponse()
    body = r.read()
    if r.status == 429:
        raise RateLimited()
    if r.status != 200:
        raise OSError(f"HTTP {r.status}")
    return body.decode("utf-8", "ignore")


class RateLimited(Exception):
    pass


def crawl():
    cache = {}
    if os.path.exists(CACHE):
        cache = json.load(io.open(CACHE, encoding="utf-8"))
    conn = _conn()
    for name, cate in CATEGORIES:
        first = f"/albums-index-cate-{cate}.html"
        html = fetch_keepalive(conn, first)
        pages = sorted(set(int(m) for m in
                           re.findall(rf"albums-index-page-(\d+)-cate-{cate}", html)))
        total = max(pages) if pages else 1
        done = cache.get(str(cate), {}).get("pages", {})
        if not done:
            probe = parse_list_page(html)
            if not probe:
                raise SystemExit(f"cate {cate} 首页解析为 0 条，解析器需修复")
            print(f"[{name}] 解析自检 OK：{len(probe)} 条", flush=True)
        print(f"[{name}] cate={cate} 总页数={total} 已缓存={len(done)}",
              flush=True)
        items = dict(done)
        todo = [p for p in range(1, total + 1) if str(p) not in done]
        since_save, fails = 0, 0
        for n, p in enumerate(todo):
            path = first if p == 1 else f"/albums-index-page-{p}-cate-{cate}.html"
            got = False
            for attempt in range(1, 6):
                try:
                    its = parse_list_page(fetch_keepalive(conn, path))
                    if its:
                        items[str(p)] = its
                    got = True
                    break
                except RateLimited:
                    wait = 45 * attempt
                    print(f"  429 限流，退避 {wait}s（页 {p} 第 {attempt} 次）",
                          flush=True)
                    try:
                        conn.close()
                    except Exception:
                        pass
                    time.sleep(wait)
                    conn = _conn()
                except Exception as e:
                    try:
                        conn.close()
                    except Exception:
                        pass
                    time.sleep(2 * attempt)
                    conn = _conn()
                    if attempt == 5:
                        print(f"  页 {p} 五次失败: {e}", flush=True)
            since_save += 1
            if got:
                fails = 0
            else:
                fails += 1
                if fails >= 30:
                    print("  连续 30 页失败，中止本分类", flush=True)
                    break
            if since_save >= 25:
                since_save = 0
                cache[str(cate)] = {"name": name, "pages": items}
                json.dump(cache, io.open(CACHE, "w", encoding="utf-8"),
                          ensure_ascii=False)
            if (n + 1) % 100 == 0:
                print(f"  进度 {n+1}/{len(todo)}", flush=True)
            time.sleep(1.2)
        cache[str(cate)] = {"name": name, "pages": items}
        json.dump(cache, io.open(CACHE, "w", encoding="utf-8"),
                  ensure_ascii=False)
        print(f"[{name}] 完成：{len(items)} 页，"
              f"{sum(len(v) for v in items.values())} 条", flush=True)
    try:
        conn.close()
    except Exception:
        pass


def local_zips():
    out = []
    for name, cate in CATEGORIES:
        d = os.path.join(MR_ROOT, name)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if fn.lower().endswith(".zip"):
                out.append((name, cate, os.path.join(d, fn), fn[:-4]))
    return out


def zip_pages(path):
    try:
        with zipfile.ZipFile(path) as z:
            return sum(1 for n in z.namelist()
                       if not n.endswith("/") and IMG.search(n))
    except Exception:
        return -1


def head_len(url):
    try:
        # ?n= 带空格/括号，必须编码
        q = urllib.parse.quote(url, safe=":/?&=%.~-_[]")
        req = urllib.request.Request(q, headers=UA, method="HEAD")
        with urllib.request.urlopen(req, timeout=20) as r:
            return int(r.headers.get("Content-Length", -1))
    except Exception:
        return -2


def dl_url_of(aid):
    """解析 download-index 页拿官方直链（HEAD 校验用）"""
    html = fetch(f"{BASE}download-index-aid-{aid}.html")
    m = re.search(r'class="ads"\s+href="([^"]+)"', html)
    if not m:
        return None
    u = m.group(1).replace("&amp;", "&")
    if u.startswith("//"):
        u = "https:" + u
    return u


def build_title_index(cache):
    """key -> [(cate, item)...]"""
    idx = {}
    for cate, data in cache.items():
        for page, items in data["pages"].items():
            for it in items:
                if it["title"]:
                    idx.setdefault(key_of(it["title"]), []).append((cate, it))
    return idx


def match():
    cache = json.load(io.open(CACHE, encoding="utf-8"))
    idx = build_title_index(cache)
    reg = []
    if os.path.exists(REG_PATH):
        reg = json.load(io.open(REG_PATH, encoding="utf-8"))
    known = {e["item"]["aid"] for e in reg}

    plan, unmatched, dup_in_reg = [], [], []
    for name, cate, path, stem in local_zips():
        k = key_of(stem)
        cands = idx.get(k, [])
        entry = {"file": path, "title": stem, "cate": name}
        same = [it for c, it in cands if str(c) == str(cate)]
        other = [it for c, it in cands if str(c) != str(cate)]
        if len(same) == 1:
            entry["item"] = same[0]
            entry["need_verify"] = len(other) > 0
            plan.append(entry)
        elif len(same) > 1:
            entry["cands"] = same  # HEAD 消歧
            plan.append(entry)
        elif len(other) == 1:
            entry["item"] = other[0]  # 跨分类唯一命中（分类目录名仅作参考）
            entry["need_verify"] = True
            plan.append(entry)
        elif len(other) > 1:
            entry["cands"] = other
            plan.append(entry)
        else:
            entry["reason"] = "标题未命中"
            unmatched.append(entry)
    # 已在注册表/需要 HEAD 校验的处理
    verified, to_verify, skip_reg = [], [], []
    for e in plan:
        if "item" not in e:
            to_verify.append(e)
            continue
        if e["item"]["aid"] in known:
            e["reason"] = "WNACG 注册表已有该 aid"
            skip_reg.append(e)
            continue
        if e.get("need_verify"):
            to_verify.append(e)
        else:
            verified.append(e)
    print(f"本地 zip={len(local_zips())} 标题唯一命中={len(verified)} "
          f"需大小校验={len(to_verify)} 未命中={len(unmatched)} "
          f"已在库={len(skip_reg)}")
    json.dump({"verified": verified, "to_verify": to_verify,
               "unmatched": unmatched, "skip": skip_reg},
              io.open(PLAN, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def resolve_by_size():
    """对 to_verify（多候选/跨分类/需复核）用官方直链 HEAD 长度比对本地大小"""
    p = json.load(io.open(PLAN, encoding="utf-8"))
    tv = p["to_verify"]
    print(f"HEAD 校验 {len(tv)} 个…")
    ok, fail = [], []
    for i, e in enumerate(tv):
        size = os.path.getsize(e["file"])
        cands = e.get("cands") or [e["item"]]
        hit = None
        for it in cands:
            u = dl_url_of(it["aid"])
            if u and head_len(u) == size:
                hit = it
                break
            time.sleep(0.1)
        if hit:
            e["item"] = hit
            e.pop("cands", None)
            ok.append(e)
        else:
            e["reason"] = "候选大小均不符或直链不可达"
            fail.append(e)
        if (i + 1) % 20 == 0:
            print(f"  {i+1}/{len(tv)} 命中={len(ok)} 未中={len(fail)}")
    p["to_verify"] = []
    p["verified"] += ok
    p["unmatched"] += fail
    json.dump(p, io.open(PLAN, "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(f"校验完成：命中 {len(ok)}，未中 {len(fail)}")


def resolve_by_search():
    """未命中兜底：站点搜索标题，结果里找净化后精确同名者，HEAD 大小确认"""
    p = json.load(io.open(PLAN, encoding="utf-8"))
    reg = json.load(io.open(REG_PATH, encoding="utf-8"))
    known = {e["item"]["aid"] for e in reg}
    um = [e for e in p["unmatched"]
          if not e.get("reason", "").startswith("搜索")]
    print(f"搜索兜底 {len(um)} 个…")
    ok, fail = [], []
    for i, e in enumerate(um):
        q = e["title"]
        # 跳过截断/兜底名（太短或无有效信息）
        if len(key_of(q)) < 6 or q in ("wnacg_download",):
            e["reason"] = "搜索跳过：文件名无有效信息"
            fail.append(e)
            continue
        try:
            url = f"{BASE}search/index.php?q={urllib.parse.quote(q)}"
            html = fetch(url)
        except Exception as ex:
            e["reason"] = f"搜索失败 {ex}"
            fail.append(e)
            time.sleep(1.5)
            continue
        cands = {it["aid"]: it for it in parse_list_page(html)}
        strip = lambda s: re.sub(r"<[^>]+>", "", s or "")
        try:
            exact = [it for it in cands.values()
                     if key_of(strip(it["title"])) == key_of(q)
                     and it["aid"] not in known]
            hit = None
            for it in exact:
                u = dl_url_of(it["aid"])
                if u and head_len(u) == os.path.getsize(e["file"]):
                    hit = it
                    break
                time.sleep(0.1)
        except Exception as ex:
            e["reason"] = f"校验异常 {ex}"
            fail.append(e)
            time.sleep(1.5)
            continue
        if hit:
            e["item"] = hit
            e.pop("cands", None)
            e.pop("reason", None)
            ok.append(e)
        else:
            e["reason"] = "搜索无精确同名或大小不符"
            fail.append(e)
        time.sleep(1.5)
        if (i + 1) % 10 == 0:
            print(f"  {i+1}/{len(um)} 命中={len(ok)} 未中={len(fail)}", flush=True)
    p["unmatched"] = fail
    p["verified"] += ok
    json.dump(p, io.open(PLAN, "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(f"搜索兜底完成：命中 {len(ok)}，仍未中 {len(fail)}")


def resolve_by_prefix():
    """最后兜底：在已爬索引里找前缀匹配（截断文件名），HEAD 大小确认；
    精确同名唯一时直接采用（站点可能已删该专辑，HEAD 不可达也算命中）。"""
    p = json.load(io.open(PLAN, encoding="utf-8"))
    cache = json.load(io.open(CACHE, encoding="utf-8"))
    idx = build_title_index(cache)
    reg = json.load(io.open(REG_PATH, encoding="utf-8"))
    known = {e["item"]["aid"] for e in reg}
    ok, fail = [], []
    for e in p["unmatched"]:
        k = key_of(e["title"])
        if len(k) < 5 or "download_file" in k:
            e["reason"] = "文件名无有效信息"
            fail.append(e)
            continue
        # 前缀候选（同分类优先），精确同名优先
        cands = []
        for key, lst in idx.items():
            rel = (key.startswith(k) or k.startswith(key)) and key != k
            if not rel:
                continue
            for c, it in lst:
                if it["aid"] in known:
                    continue
                cands.append((0 if key == k else
                              (1 if str(c) == str(e["cate"]) else 2), key, it))
        cands.sort(key=lambda x: (x[0], x[1]))
        size = os.path.getsize(e["file"])
        hit, exact_unique = None, False
        exacts = [it for pri, key, it in cands if key == k]
        if len(exacts) == 1:
            hit, exact_unique = exacts[0], True
        else:
            for pri, key, it in cands[:20]:
                try:
                    u = dl_url_of(it["aid"])
                except Exception:
                    continue
                if u and head_len(u) == size:
                    hit = it
                    break
                time.sleep(0.2)
        if hit:
            e["item"] = hit
            e.pop("reason", None)
            e.pop("cands", None)
            ok.append(e)
            tag = "精确(未验大小)" if exact_unique else "前缀+大小验证"
            print(f"  命中[{tag}] {e['title'][:36]} → {hit['aid']}", flush=True)
        else:
            e["reason"] = f"前缀候选{len(cands)}个均不符/超上限"
            fail.append(e)
    p["unmatched"] = fail
    p["verified"] += ok
    json.dump(p, io.open(PLAN, "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(f"前缀兜底完成：命中 {len(ok)}，仍未中 {len(fail)}")


def report():
    p = json.load(io.open(PLAN, encoding="utf-8"))
    for k in ("verified", "to_verify", "unmatched", "skip"):
        print(f"== {k}: {len(p[k])}")
    for e in (p["unmatched"] + p["skip"])[:30]:
        print("  -", os.path.basename(e["file"]), "|", e.get("reason", ""))


def apply():
    p = json.load(io.open(PLAN, encoding="utf-8"))
    reg = json.load(io.open(REG_PATH, encoding="utf-8"))
    backup = REG_PATH + ".bak-migrate41"
    shutil.copy2(REG_PATH, backup)
    print(f"注册表已备份 → {backup}")
    known = {e["item"]["aid"] for e in reg}
    renamed, errors = 0, []
    for e in p["verified"]:
        it = e["item"]
        aid = it["aid"]
        if aid in known:
            continue
        pages = zip_pages(e["file"])
        if pages <= 0:
            errors.append((e["file"], "zip 打开失败"))
            continue
        # 与 Dart html 解析一致：属性值单次反转义；顺带去残余标签
        clean_title = html.unescape(re.sub(r"<[^>]+>", "", it["title"]))
        stem = wnacg_zip_stem(clean_title)
        target = os.path.join(os.path.dirname(e["file"]), f"{aid}-{stem}.zip")
        if os.path.abspath(target) != os.path.abspath(e["file"]):
            if os.path.exists(target):
                errors.append((e["file"], f"目标已存在 {target}"))
                continue
            os.rename(e["file"], target)
        reg.append({
            "item": {"aid": aid, "title": clean_title, "cover": it["cover"],
                     "count": it["count"], "date": it["date"]},
            "dir": os.path.dirname(target).replace("\\", "/"),
            "count": pages,
            "isZip": True,
            "zipPath": target.replace("\\", "/"),
            "official": True,
        })
        known.add(aid)
        renamed += 1
    json.dump(reg, io.open(REG_PATH, "w", encoding="utf-8"),
              ensure_ascii=False)
    print(f"迁移完成：改名+注册 {renamed} 个；错误 {len(errors)}")
    for f, why in errors[:20]:
        print("  !", os.path.basename(f), "|", why)
    if errors:
        json.dump(errors, io.open(os.path.join(HERE, "migrate_errors.json"),
                                  "w", encoding="utf-8"), ensure_ascii=False)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "crawl":
        crawl()
    elif cmd == "match":
        match()
    elif cmd == "resolve":
        resolve_by_size()
    elif cmd == "search":
        resolve_by_search()
    elif cmd == "prefix":
        resolve_by_prefix()
    elif cmd == "apply":
        apply()
    elif cmd == "report":
        report()
    else:
        print(__doc__)
