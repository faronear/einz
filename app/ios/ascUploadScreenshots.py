#!/usr/bin/env python3
# ASC 截图上传（2026-10-21）：把 app/screenshots/iphone_6_9 的英文截图按
# 02→03→04→05 顺序传到 App Store Connect 的 6.9"（en-US）截图集。
# 仅传截图，不打包不传 IPA（包走 GitHub CI → TestFlight，老板定）。
#
# 用法：python3 app/ios/ascUploadScreenshots.py [--dir app/screenshots/iphone_6_9]
# 凭据：~/private_keys/AuthKey_333XP37M8H.p8（ASC Team Key「einz-ci-upload」，App Manager）。
#
# 踩坑记录：手搓 JWT 必须 ES256 **raw r||s** 签名（JWS 标准）。openssl dgst
# -sign 输出 DER，转 raw 时要先 lstrip 去掉 r/s 的 leading zero 再 rjust(32)——
# 不 strip 会产出 65/66 字节的坏签名（约 3/4 的签名带 leading zero），
# ASC 一律 401 NOT_AUTHORIZED。altool 内部实现正确，故同 key 能过。
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

KEY_ID = "333XP37M8H"
ISSUER = "69a6de88-4ef9-47e3-e053-5b8c7c11a4d1"
BUNDLE = "cc.tic.einz"
API = "https://api.appstoreconnect.apple.com"
P8 = os.path.expanduser(f"~/private_keys/AuthKey_{KEY_ID}.p8")
LOCALE = "en-US"
# 上传顺序 = ASC 槽位展示顺序（appStoreSubmission §4.6「内容定稿」）
ORDER = ["02_space_kind", "03_chat_main", "04_burn_settings", "05_pin_setup"]


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_sig_to_raw(der: bytes) -> bytes:
    """openssl dgst -sign 的 DER ECDSA → JWS 要求的 raw r||s（各 32B）。"""
    assert der[0] == 0x30, "not a DER SEQUENCE"
    idx = 2 + (der[1] & 0x7F) if der[1] & 0x80 else 2  # 跳过（可能的长格式）长度字节
    assert der[idx] == 0x02
    r_len = der[idx + 1]
    r = der[idx + 2:idx + 2 + r_len]
    idx += 2 + r_len
    assert der[idx] == 0x02
    s_len = der[idx + 1]
    s = der[idx + 2:idx + 2 + s_len]
    r = r.lstrip(b"\x00").rjust(32, b"\x00")  # 先去 leading zero 再补齐 32B
    s = s.lstrip(b"\x00").rjust(32, b"\x00")
    return r + s


def make_jwt() -> str:
    now = int(time.time())
    header = b64u(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"},
                             separators=(",", ":")).encode())
    payload = b64u(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 1199,
                               "aud": "appstoreconnect-v1"},
                              separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", P8],
                         input=signing_input, capture_output=True, check=True).stdout
    assert len(der) <= 72, f"unexpected DER sig length {len(der)}"
    return f"{header}.{payload}.{b64u(der_sig_to_raw(der))}"


if not os.path.isfile(P8):
    sys.exit(f"❌ 找不到私钥 {P8}")
TOKEN = make_jwt()


def req(method: str, path: str, body: dict | None = None):
    """ASC REST 调用；非 2xx 打印错误并退出。"""
    r = urllib.request.Request(
        API + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {TOKEN}",
                 "Content-Type": "application/json"})
    try:
        resp = urllib.request.urlopen(r)
        code, raw = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        code, raw = e.code, e.read()
    txt = raw.decode()
    if code >= 300:
        sys.exit(f"❌ {method} {path} → {code}\n{txt[:900]}")
    return json.loads(txt) if txt.strip() else {}


def soft_patch(path: str, body: dict):
    """容错 PATCH（截图 commit 可能 409=已处理，不算失败）。"""
    r = urllib.request.Request(
        API + path, method="PATCH", data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {TOKEN}",
                 "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(r)
        return True
    except urllib.error.HTTPError as e:
        print(f"  （commit 返回 {e.code}，多半已自动处理，忽略）")
        return False


def main():
    shot_dir = "app/screenshots/iphone_6_9"
    if "--dir" in sys.argv:
        shot_dir = sys.argv[sys.argv.index("--dir") + 1]
    files = [os.path.join(shot_dir, n + ".png") for n in ORDER]
    for f in files:
        if not os.path.isfile(f):
            sys.exit(f"❌ 缺截图 {f}")

    # 1) app
    app = req("GET", f"/v1/apps?filter%5BbundleId%5D={BUNDLE}")["data"][0]
    app_id = app["id"]
    print(f"▶ app={app_id}（{app['attributes']['name']}，主语言 "
          f"{app['attributes'].get('primaryLocale', '?')}）")

    # 2) 可编辑版本（PREPARE_FOR_SUBMISSION）；没有就按最新构建的版本号建一个
    vers = req("GET", f"/v1/apps/{app_id}/appStoreVersions"
                      "?filter%5BappStoreState%5D=PREPARE_FOR_SUBMISSION"
                      "&filter%5Bplatform%5D=IOS")["data"]
    if vers:
        ver_id = vers[0]["id"]
        print(f"▶ 版本 {vers[0]['attributes']['versionString']}（待提交）ver={ver_id}")
    else:
        builds = req("GET", f"/v1/builds?filter%5Bapp%5D={app_id}"
                            "&sort=-uploadedDate&limit=1")["data"]
        version_string = (builds[0]["attributes"]["version"] if builds
                          else time.strftime("1.0.%H%M", time.gmtime()))
        ver = req("POST", "/v1/appStoreVersions", {
            "data": {"type": "appStoreVersions",
                     "attributes": {"platform": "IOS",
                                    "versionString": version_string},
                     "relationships": {"app": {"data": {
                         "type": "apps", "id": app_id}}}}})
        ver_id = ver["data"]["id"]
        print(f"▶ 无待提交版本 → 新建 {version_string} ver={ver_id}")

    # 3) en-US 本地化
    locs = req("GET", f"/v1/appStoreVersions/{ver_id}"
                      "/appStoreVersionLocalizations")["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
    if loc is None:
        loc = req("POST", "/v1/appStoreVersionLocalizations", {
            "data": {"type": "appStoreVersionLocalizations",
                     "attributes": {"locale": LOCALE,
                                    "description": "Einz — Your Secret Realm."},
                     "relationships": {"appStoreVersion": {"data": {
                         "type": "appStoreVersions", "id": ver_id}}}}})
        print(f"▶ 新建 {LOCALE} 本地化")
    loc_id = loc["id"]
    print(f"▶ 本地化={LOCALE} loc={loc_id}")

    # 4) 6.9" 截图集（enum 名带 6_9 即目标；没有就建）
    sets = req("GET", f"/v1/appStoreVersionLocalizations/{loc_id}"
                      "/appScreenshotSets")["data"]
    target = next((s for s in sets
                   if "6_9" in s["attributes"]["screenshotDisplayType"]), None)
    if target is None:
        target = req("POST", "/v1/appScreenshotSets", {
            "data": {"type": "appScreenshotSets",
                     "attributes": {"screenshotDisplayType":
                                    "APP_IPHONE_69"},
                     "relationships": {"appStoreVersionLocalization": {
                         "data": {"type": "appStoreVersionLocalizations",
                                  "id": loc_id}}}}})
        print("▶ 新建 6.9\" 截图集")
    set_id = target["id"]
    print(f"▶ 截图集={target['attributes']['screenshotDisplayType']} set={set_id}")

    # 5) 清空集内旧图（保证 4 张的顺序就是槽位顺序）
    old = req("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots"
                     "?limit=200")["data"]
    for s in old:
        req("DELETE", f"/v1/appScreenshots/{s['id']}")
        print(f"  已删旧图 {s['attributes']['fileName']}")
    if old:
        time.sleep(3)  # 等 ASC 侧删除生效，避免文件名冲突

    # 6) 逐张上传：创建 reservation → 按 uploadOperations 分块 PATCH → commit
    for name in ORDER:
        path = os.path.join(shot_dir, name + ".png")
        content = open(path, "rb").read()
        size = len(content)
        res = req("POST", "/v1/appScreenshots", {
            "data": {"type": "appScreenshots",
                     "attributes": {"fileName": name + ".png", "fileSize": size},
                     "relationships": {"appScreenshotSet": {"data": {
                         "type": "appScreenshotSets", "id": set_id}}}}})
        shot = res["data"]
        for op in shot["attributes"]["uploadOperations"]:
            chunk = content[op["offset"]:op["offset"] + op["length"]]
            headers = {"Content-Type": "image/png"}
            headers.update(op.get("requestHeaders") or {})
            r = urllib.request.Request(op["url"], data=chunk,
                                       headers=headers,
                                       method=op.get("method", "PATCH"))
            urllib.request.urlopen(r)  # 签名 URL，错误直接抛
        md5 = base64.b64encode(hashlib.md5(content).digest()).decode()
        soft_patch(f"/v1/appScreenshots/{shot['id']}",
                   {"data": {"type": "appScreenshots", "id": shot["id"],
                             "attributes": {"sourceFileChecksum": md5}}})
        print(f"✓ {name}.png（{size}B，id={shot['id']}）")

    # 7) 验证：回读集合内容与状态
    print("▶ 回读验证：")
    final = req("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots"
                       "?limit=200")["data"]
    for i, s in enumerate(final, 1):
        print(f"  槽位{i}: {s['attributes']['fileName']}"
              f"（{s['attributes']['assetDeliveryState'].get('state', '?')}）")
    print(f"✅ 共 {len(final)} 张，顺序即上传顺序。"
          "ASC 网页几秒后可见（处理中的图会短暂显示 Processing）。")


if __name__ == "__main__":
    main()
