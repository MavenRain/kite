"""Check native runtime oracles against buildable mutants in disposable copies."""

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
MUTANTS = [
    (
        "heartbeat-bypass", "runtime/cluster.ml",
        "active && host.lock_held && now - host.heartbeat < cfg.timeout",
        "active && host.lock_held && (now - host.heartbeat < cfg.timeout || true)",
        "cluster", "heartbeat-boundary-expired",
    ),
    (
        "epoch-fence-bypass", "runtime/cluster.ml",
        "current_epoch <= 0 || current_epoch <> plan.plan_epoch",
        "current_epoch <= 0 || (current_epoch <> plan.plan_epoch && false)",
        "cluster", "epoch-fence",
    ),
    (
        "pod-lock-reservation-bypass", "runtime/cluster.ml",
        "placements locks in", "placements (Locks.diff locks locks) in",
        "cluster", "release-before-replace",
    ),
    (
        "pod-lock-grant-bypass", "runtime/kubelet.ml",
        "if granted && available state && w.incarnation = state.current.incarnation",
        "if (granted || true) && available state && w.incarnation = state.current.incarnation",
        "kubelet", "lock-denied",
    ),
    (
        "pending-epoch-cancel-bypass", "runtime/kubelet.ml",
        "| Starting -> stop_worker w", "| Starting -> (w, [])",
        "kubelet", "epoch-cancels-pending",
    ),
    (
        "delayed-node-release-bypass", "runtime/kubelet.ml",
        "| Frozen -> Ok (state, [ Release_node incarnation ])",
        "| Frozen -> Ok (state, [])",
        "kubelet", "late-node-acquisition",
    ),
]


def run(root, args):
    return subprocess.run(args, cwd=root, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, check=False, timeout=60)


def build(root):
    return run(root, ["zsh", str(root / "dev/pin-dune.sh"), "dune", "build", "@all"])


def main():
    with tempfile.TemporaryDirectory(prefix="kite-runtime-mutants-") as scratch:
        copy = Path(scratch) / "kite"
        shutil.copytree(ROOT, copy, ignore=shutil.ignore_patterns(
            ".git", "_build", ".gatework", "*.kir", "__pycache__"))
        baseline = build(copy)
        if baseline.returncode != 0:
            print("MUTATION-FAIL baseline-build\n" + baseline.stdout)
            return 1
        for suite in ["cluster", "kubelet"]:
            outcome = run(copy, [str(copy / f"_build/default/test/{suite}.exe")])
            if outcome.returncode != 0:
                print("MUTATION-FAIL baseline-tests\n" + outcome.stdout)
                return 1
            print(outcome.stdout.strip())
        killed = 0
        for name, relative, before, after, suite, case in MUTANTS:
            path = copy / relative
            original = path.read_text()
            if original.count(before) != 1:
                print(f"MUTATION-FAIL {name} anchor-count={original.count(before)}")
                return 1
            path.write_text(original.replace(before, after))
            compilation = build(copy)
            if compilation.returncode != 0:
                print(f"MUTATION-FAIL {name} unbuildable\n{compilation.stdout}")
                return 1
            outcome = run(copy, [str(copy / f"_build/default/test/{suite}.exe"), case])
            path.write_text(original)
            expected = f"RUNTIME-FAIL {suite} {case}"
            if outcome.returncode != 1 or expected not in outcome.stdout.splitlines():
                print(f"MUTATION-FAIL {name} exit={outcome.returncode}\n{outcome.stdout}")
                return 1
            killed += 1
            print(f"MUTATION-KILLED {name} suite={suite} case={case} build=0 test=1")
        print(f"MUTATIONS tests={len(MUTANTS)} killed={killed} survived=0 unbuildable=0")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
