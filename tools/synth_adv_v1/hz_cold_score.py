import json, sys
from tools.synth_adv_v1.hz_pipeline import HZ, student_turns
from tools.synth_adv_v1.hz_teacher_bench import analyse
ans = json.loads(open(sys.argv[1], encoding="utf-8").read())
key = {k["item"]: k for k in json.loads((HZ / "cold_prompts_hz_key.json").read_text(encoding="utf-8"))}
turns = {("%s|%s" % (s, t), n): c for s, t, n, c in student_turns()}
same = 0; clean = 0
for a in ans:
    k = key[a["item"]]; c = turns[(k["game"], k["turn"])]
    o = a["answer"]["orders"]; ref = json.loads(k["reference"])
    pr = analyse(c["state"], o, a["answer"].get("plan"))
    orig = json.loads(c.get("raw").split("</think>")[-1]) if False else None
    ident = (o == ref.get("orders") and a["answer"].get("plan") == ref.get("plan"))
    same += ident; clean += not pr
    print(a["item"], k["game"].split("|")[0], "T%s" % k["turn"], "problems", pr[:3], "IDENTICAL_TO_KEY" if ident else "")
print("clean %d/%d, identical to reference %d/%d" % (clean, len(ans), same, len(ans)))
