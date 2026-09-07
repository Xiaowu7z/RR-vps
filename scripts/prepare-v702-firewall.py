#!/usr/bin/env python3
"""Plan and apply only the observed RR 7.0.2 legacy INPUT-rule migration."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

FAMILIES = ("iptables", "ip6tables")
MARK = "argo-rr-managed"
REQUIRED = (("tcp", 443), ("tcp", 80), ("tcp", 20382), ("tcp", 22049))
NEW = (("tcp", 28759), ("udp", 15551), ("udp", 24747), ("tcp", 14640))
BARE = (("tcp", 12609), ("udp", 29001), ("udp", 17252), ("tcp", 10817), ("tcp", 443))


def rule(proto, port, marked=True):
    args = ["-p", proto, "-m", proto, "--dport", str(port)]
    return args + (["-m", "comment", "--comment", MARK] if marked else []) + ["-j", "ACCEPT"]


def render(lines):
    return "\n".join(lines) + "\n"


def alter(text, args):
    lines = text.splitlines()
    positions = [i for i, line in enumerate(lines) if line.startswith("-A INPUT ")]
    if args[:2] == ["-I", "INPUT"]:
        rank = int(args[2]) - 1
        if not 0 <= rank <= len(positions):
            raise ValueError("invalid INPUT insertion position")
        offset = positions[rank] if rank < len(positions) else positions[-1] + 1
        lines.insert(offset, " ".join(["-A", "INPUT"] + args[3:]))
    elif args[:2] == ["-D", "INPUT"]:
        target = " ".join(["-A", "INPUT"] + args[2:])
        if lines.count(target) != 1:
            raise ValueError("deletion target is not unique")
        lines.remove(target)
    else:
        raise ValueError("unsupported operation")
    return render(lines)


def build_family(text, family):
    if not text or len(text) > 1024 * 1024 or "\r" in text or "\0" in text:
        raise ValueError("invalid filter listing")
    lines = text.splitlines()
    if text != render(lines) or lines.count("-P INPUT ACCEPT") != 1:
        raise ValueError("INPUT must have exactly one ACCEPT policy")
    allowed = {tuple(rule(*item)): item for item in REQUIRED + NEW}
    bare = BARE + ((("tcp", 18035),) if family == "ip6tables" else ())
    allowed.update({tuple(rule(*item, marked=False)): item for item in bare})
    seen = set()
    for line in lines:
        tokens = shlex.split(line)
        if len(tokens) < 2:
            raise ValueError("invalid filter rule")
        if tokens[1] != "INPUT":
            continue
        if line == "-P INPUT ACCEPT":
            continue
        identity = tuple(tokens[2:])
        if tokens[0] != "-A" or identity not in allowed or identity in seen:
            raise ValueError("unknown or duplicate INPUT rule")
        if line != " ".join(tokens):
            raise ValueError("noncanonical INPUT rule")
        seen.add(identity)
    if any(tuple(rule(*item)) not in seen for item in REQUIRED):
        raise ValueError("required original RR allow rule is missing")
    current, operations = text, []
    for item in NEW:
        if tuple(rule(*item)) in seen:
            continue
        args = ["-I", "INPUT", "1"] + rule(*item)
        after = alter(current, args)
        operations.append(dict(args=args, undo=["-D", "INPUT"] + rule(*item), before=current, after=after))
        current = after
    old = rule("tcp", 443, marked=False)
    if tuple(old) in seen:
        inputs = [line for line in current.splitlines() if line.startswith("-A INPUT ")]
        position = inputs.index(" ".join(["-A", "INPUT"] + old)) + 1
        args = ["-D", "INPUT"] + old
        after = alter(current, args)
        operations.append(dict(args=args, undo=["-I", "INPUT", str(position)] + old, before=current, after=after))
        current = after
    return dict(before=text, after=current, operations=operations)


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def runner(family, args):
    return subprocess.run([family, "-w", "5", "-t", "filter"] + args,
                          check=True, text=True, capture_output=True, timeout=15).stdout


def expected(plan, journal):
    states = {family: plan[family]["before"] for family in FAMILIES}
    for family, index in journal["completed"]:
        states[family] = plan[family]["operations"][index]["after"]
    return states


def check(states, run):
    for family in FAMILIES:
        if run(family, ["-S"]) != states[family]:
            raise ValueError("live filter state changed: " + family)


def resolve_pending(plan, journal, path, run):
    pending = journal.get("pending")
    if pending is None:
        return
    family, index = pending["entry"]
    operation = plan[family]["operations"][index]
    live = run(family, ["-S"])
    if live not in (operation["before"], operation["after"]):
        raise ValueError("pending operation has unexpected live state")
    if pending["direction"] == "forward" and live == operation["after"]:
        journal["completed"].append(pending["entry"])
    elif pending["direction"] == "reverse" and live == operation["before"]:
        journal["completed"].pop()
    journal["pending"] = None
    check(expected(plan, journal), run)
    write_json(path, journal)


def execute(action, directory, run=runner):
    directory = Path(directory)
    plan_path, journal_path = directory / "plan.json", directory / "journal.json"
    if action == "plan":
        if plan_path.exists() or journal_path.exists():
            raise ValueError("existing plan or journal must be retained")
        plan = {family: build_family((directory / (family + ".before")).read_text(), family)
                for family in FAMILIES}
        write_json(plan_path, {"families": plan})
        return
    plan = json.loads(plan_path.read_text())["families"]
    if action == "verify":
        check({family: plan[family]["after"] for family in FAMILIES}, run)
        return
    if action == "apply":
        if journal_path.exists():
            raise ValueError("existing journal requires rollback or review")
        journal = {"completed": [], "pending": None}
        check(expected(plan, journal), run)
        write_json(journal_path, journal)
        entries = [(family, i) for family in FAMILIES for i in range(len(plan[family]["operations"]))]
    elif action == "rollback":
        if not journal_path.exists():
            check({family: plan[family]["before"] for family in FAMILIES}, run)
            return
        journal = json.loads(journal_path.read_text())
        resolve_pending(plan, journal, journal_path, run)
        entries = list(reversed(journal["completed"]))
    else:
        raise ValueError("unknown action")
    for family, index in entries:
        check(expected(plan, journal), run)
        operation = plan[family]["operations"][index]
        journal["pending"] = {"direction": "forward" if action == "apply" else "reverse", "entry": [family, index]}
        write_json(journal_path, journal)
        run(family, operation["args" if action == "apply" else "undo"])
        if run(family, ["-S"]) != operation["after" if action == "apply" else "before"]:
            raise ValueError("operation did not produce the expected filter state")
        resolve_pending(plan, journal, journal_path, run)
    check(expected(plan, journal), run)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: prepare-v702-firewall.py plan|apply|rollback|verify BACKUPDIR")
        execute(sys.argv[1], sys.argv[2])
        print("FIREWALL_" + sys.argv[1].upper() + "_OK")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("FIREWALL_PREPARATION_STOP: " + str(error), file=sys.stderr)
        sys.exit(1)
