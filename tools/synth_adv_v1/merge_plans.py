"""Verify agent-written plans against the packet facts; keep the ones that pass.
  python -m tools.synth_adv_v1.merge_plans
-> synth_adv_v1/plans_verified.json {job: plan}, plans_rejected.jsonl
"""
import glob, json, re
from tools.synth_adv_v1.bank_adv import OUT

ID = re.compile(r"\b[RB]_[A-Z]{2,3}_\d+\b")
NUM = re.compile(r"-?\d+")


def check(plan, job):
    why = []
    if not isinstance(plan, str) or not plan.strip():
        return ["empty"]
    if len(plan) > 300:
        why.append("len>300")
    if "\n" in plan:
        why.append("newline")
    src = job["state"] + json.dumps(job["answer"], ensure_ascii=False) + job.get("prior_plan", "")
    ids = set(ID.findall(src))
    bad_ids = [x for x in ID.findall(plan) if x not in ids]
    if bad_ids:
        why.append("unknown ids %s" % bad_ids[:3])
    nums = set(NUM.findall(src)) | {str(job["turn"])}
    bad_n = [n for n in NUM.findall(plan) if n.lstrip("-") not in {x.lstrip("-") for x in nums} and not ID.search(n)]
    # numbers inside unit ids are already covered by the id check
    plan_wo_ids = ID.sub("", plan)
    bad_n = [n for n in NUM.findall(plan_wo_ids) if n.lstrip("-") not in {x.lstrip("-") for x in nums}]
    if bad_n:
        why.append("unseen numbers %s" % bad_n[:4])
    return why


def main():
    jobs = {}
    for l in (OUT / "plan_jobs.jsonl").read_text(encoding="utf-8").splitlines():
        j = json.loads(l); jobs[j["job"]] = j
    ok, rej, seen = {}, [], set()
    for f in sorted(glob.glob(str(OUT / "plan_batches" / "out_*.jsonl"))):
        for l in open(f, encoding="utf-8"):
            if not l.strip():
                continue
            try:
                r = json.loads(l)
            except ValueError:
                rej.append({"file": f, "why": ["bad json line"]}); continue
            j = jobs.get(r.get("job"))
            if j is None:
                rej.append({"job": r.get("job"), "why": ["unknown job"]}); continue
            seen.add(r["job"])
            why = check(r.get("plan"), j)
            if why:
                rej.append({"job": r["job"], "plan": r.get("plan"), "why": why})
            else:
                ok[r["job"]] = r["plan"].strip()
    (OUT / "plans_verified.json").write_text(json.dumps(ok, ensure_ascii=False, indent=1), encoding="utf-8")
    (OUT / "plans_rejected.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in rej), encoding="utf-8")
    print("jobs", len(jobs), "returned", len(seen), "verified", len(ok), "rejected", len(rej))
    for x in rej[:6]:
        print(" ", x.get("job"), x["why"], (x.get("plan") or "")[:100])


if __name__ == "__main__":
    main()
