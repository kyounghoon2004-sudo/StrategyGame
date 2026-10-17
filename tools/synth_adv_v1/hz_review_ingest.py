import json, glob
from tools.synth_adv_v1.hz_pipeline import HZ
n = 0
with open(HZ / "reviews.jsonl", "a", encoding="utf-8") as fh:
    for p in sorted(glob.glob(str(HZ / "review_*" / "answers_*.json"))):
        for a in json.load(open(p, encoding="utf-8")):
            src, tag, turn = a["item"].split("|")
            ans = {k: a[k] for k in ("decision", "reason", "response") if k in a}
            fh.write(json.dumps({"src": src, "tag": tag, "turn": int(turn), "bad": True, "answer": json.dumps(ans, ensure_ascii=False),
                                 "s": 0, "tokens": {}, "by": "external_agent"}, ensure_ascii=False) + "\n"); n += 1
print("ingested", n)
